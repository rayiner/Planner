import AppKit
import Foundation

/// Reads recent mail from the Microsoft Outlook already running on this Mac.
///
/// Strictly read-only and strictly local: nothing here files, flags, marks read
/// or deletes, and Planner never contacts Exchange or Microsoft 365. The one
/// command that is not a read is `open`, and that is the user asking to work on
/// a message in Outlook, reachable only from an explicit action.
///
/// Three shapes of query, and the reasons for each are in
/// `OutlookMailScripting`: one binary search for the window's edge, one
/// five-column range read for the envelopes, and a per-id read for a body.
/// `NSAppleScript` rather than `SBApplication` because only AppleScript can
/// express a range specifier, which is the whole performance story.
nonisolated final class OutlookMailSource: MailSource {
    struct Configuration: Sendable, Equatable {
        /// `nil` means "whichever Exchange account Outlook lists first".
        var accountName: String?
        /// A ceiling on one sweep, so a firehose inbox cannot stall the fetch.
        /// At ~60ms a message this is about half a minute in the worst case,
        /// which the coordinator's backstop is set to survive.
        var maximumMessages: Int

        static let defaultMaximumMessages = 400

        static let accountDefaultsKey = "mail.accountName"
        static let maximumDefaultsKey = "mail.maximumMessages"

        /// Overridable through `defaults write`, pending a settings UI — the
        /// same convention `events.accountName` follows.
        static func fromDefaults(_ defaults: UserDefaults = .standard) -> Configuration {
            let account = defaults.string(forKey: accountDefaultsKey)?
                .trimmingCharacters(in: .whitespaces)
            let maximum = defaults.integer(forKey: maximumDefaultsKey)
            return Configuration(
                accountName: (account?.isEmpty ?? true) ? nil : account,
                maximumMessages: maximum > 0 ? maximum : defaultMaximumMessages
            )
        }
    }

    /// How many messages one envelope Apple event covers. A click that wants
    /// a body is queued as a `.detail` and can only run *between* events, so
    /// a full refresh is walked in slices rather than one 10-second tell.
    static let envelopeChunkSize = 40

    let sourceID = "outlook"
    var displayName: String { configuration.accountName ?? "Inbox" }

    private let configuration: Configuration
    /// Serialises Apple events. Details jump ahead of sweep slices so
    /// opening a message is not stuck behind `messages 1 thru N`.
    private let events = MailAppleEventQueue()

    init(configuration: Configuration = .fromDefaults()) {
        self.configuration = configuration
    }

    // MARK: - MailSource

    func envelopes(in range: Range<Date>, userInitiated: Bool) async throws -> [MailMessage] {
        try await envelopes(in: range, known: [], userInitiated: userInitiated)
    }

    func envelopes(
        in range: Range<Date>,
        known: [MailMessage],
        userInitiated: Bool
    ) async throws -> [MailMessage] {
        try await fetchEnvelopes(in: range, known: known, userInitiated: userInitiated)
    }

    func detail(forMessageID id: Int64) async throws -> MailMessageDetail {
        try await events.submit(priority: .detail) {
            try Self.preflight(userInitiated: true)
            let payload = try Self.runOnMessage(OutlookMailScripting.detail(messageID: id))
            return OutlookMailDecoder.detail(payload, id: id)
        }
    }

    func reveal(messageID id: Int64) async throws {
        try await events.submit(priority: .detail) {
            try Self.preflight(userInitiated: true)
            _ = try Self.runOnMessage(OutlookMailScripting.reveal(messageID: id))
        }
    }

    // MARK: - Preflight

    /// `NSAppleScript` sends the event that raises the TCC dialog, so an
    /// automatic refresh must not reach it while consent is undetermined. The
    /// running check matters just as much: sending would otherwise *launch*
    /// Outlook merely because Planner opened.
    private static func preflight(userInitiated: Bool) throws {
        guard OutlookEventSource.isOutlookRunning else { throw OutlookError.notRunning }
        try OutlookEventSource.allowFetch(
            permission: OutlookEventSource.automationPermission(),
            userInitiated: userInitiated
        )
    }

    // MARK: - The fetch

    private func fetchEnvelopes(
        in range: Range<Date>,
        known: [MailMessage],
        userInitiated: Bool
    ) async throws -> [MailMessage] {
        let started = Date()
        let configuration = configuration
        let accountIndex = try await events.submit(priority: .sweep) {
            try Self.preflight(userInitiated: userInitiated)
            return try Self.resolveAccountIndex(configuration: configuration)
        }

        let matched = try await events.submit(priority: .sweep) { () -> Int in
            let payload = try Self.run(OutlookMailScripting.windowCount(
                accountIndex: accountIndex,
                since: range.lowerBound,
                calendar: Calendar.current
            ))
            return Int(OutlookMailDecoder.identifier(payload) ?? 0)
        }
        guard matched > 0 else {
            PlannerLog.mail.info("Outlook mail sweep: window is empty")
            return []
        }
        let count = min(matched, configuration.maximumMessages)
        if count < matched {
            PlannerLog.mail.info(
                """
                Outlook mail sweep capped at \(count, privacy: .public) \
                of \(matched, privacy: .public) messages in the window
                """
            )
        }

        let messages: [MailMessage]
        if userInitiated || known.isEmpty {
            messages = try await readFullEnvelopes(accountIndex: accountIndex, count: count)
            logSweep(kind: "full", matched: matched, kept: messages.count, started: started)
        } else {
            messages = try await readIncrementalEnvelopes(
                accountIndex: accountIndex,
                count: count,
                known: known,
                matched: matched,
                started: started
            )
        }

        // The count query only bounds the *older* edge. A message dated in the
        // future — a clock skew upstream, or a draft-like oddity — would sit at
        // the head of the list and belongs nowhere in a "last N days" window.
        return messages.filter { range.contains($0.receivedAt) }
    }

    private func readIncrementalEnvelopes(
        accountIndex: Int,
        count: Int,
        known: [MailMessage],
        matched: Int,
        started: Date
    ) async throws -> [MailMessage] {
        let scan: [(id: Int64, isRead: Bool)]
        do {
            scan = try await events.submit(priority: .sweep) {
                let payload = try Self.run(OutlookMailScripting.indexScan(
                    accountIndex: accountIndex,
                    count: count
                ))
                return try OutlookMailDecoder.indexScan(payload)
            }
        } catch {
            PlannerLog.mail.error(
                "Outlook mail index scan failed; falling back to a full sweep"
            )
            let messages = try await readFullEnvelopes(accountIndex: accountIndex, count: count)
            logSweep(kind: "full-fallback", matched: matched, kept: messages.count, started: started)
            return messages
        }

        let currentIDs = scan.map(\.id)
        let knownIDs = Set(known.map(\.id))
        switch MailEnvelopeSweep.plan(currentIDs: currentIDs, knownIDs: knownIDs) {
        case .full:
            let messages = try await readFullEnvelopes(accountIndex: accountIndex, count: count)
            logSweep(kind: "full-tail", matched: matched, kept: messages.count, started: started)
            return messages
        case .reuse:
            let assembled = MailEnvelopeSweep.assemble(
                currentIDs: currentIDs,
                isRead: Dictionary(uniqueKeysWithValues: scan.map { ($0.id, $0.isRead) }),
                known: Dictionary(uniqueKeysWithValues: known.map { ($0.id, $0) }),
                fresh: []
            )
            logSweep(kind: "reuse", matched: matched, kept: assembled.count, started: started)
            return assembled
        case let .prefix(prefixCount):
            let fresh = try await readFullEnvelopes(accountIndex: accountIndex, count: prefixCount)
            let assembled = MailEnvelopeSweep.assemble(
                currentIDs: currentIDs,
                isRead: Dictionary(uniqueKeysWithValues: scan.map { ($0.id, $0.isRead) }),
                known: Dictionary(uniqueKeysWithValues: known.map { ($0.id, $0) }),
                fresh: fresh
            )
            logSweep(kind: "prefix-\(prefixCount)", matched: matched, kept: assembled.count, started: started)
            return assembled
        }
    }

    /// Walks `1 thru count` in slices so a `.detail` item queued mid-sweep
    /// can run at a slice boundary rather than after the whole window.
    private func readFullEnvelopes(accountIndex: Int, count: Int) async throws -> [MailMessage] {
        var collected: [MailMessage] = []
        var start = 1
        while start <= count {
            let end = min(start + Self.envelopeChunkSize - 1, count)
            let sliceStart = start
            let sliceEnd = end
            let batch = try await events.submit(priority: .sweep) {
                let payload = try Self.run(OutlookMailScripting.envelopes(
                    accountIndex: accountIndex,
                    from: sliceStart,
                    through: sliceEnd
                ))
                return try OutlookMailDecoder.envelopes(payload)
            }
            collected.append(contentsOf: batch)
            start = end + 1
        }
        return collected
    }

    private func logSweep(kind: String, matched: Int, kept: Int, started: Date) {
        PlannerLog.mail.info(
            """
            Outlook mail sweep (\(kind, privacy: .public)): \
            \(matched, privacy: .public) in window, \
            \(kept, privacy: .public) kept \
            in \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public)ms
            """
        )
    }

    /// Which Exchange account to read, as an index into Outlook's own list.
    ///
    /// An index rather than a name substituted into the script: the scripts
    /// then contain nothing but numbers, so there is no quoting to get wrong
    /// and no account name that can change what a script means.
    private static func resolveAccountIndex(configuration: Configuration) throws -> Int {
        let payload = try run(OutlookMailScripting.accountNames)
        let names = OutlookMailDecoder.list(payload).map {
            OutlookMailDecoder.string($0) ?? ""
        }
        guard !names.isEmpty else { throw OutlookError.noExchangeAccounts }

        guard let wanted = configuration.accountName else { return 1 }
        guard let index = names.firstIndex(of: wanted) else {
            throw OutlookError.accountNotFound(name: wanted, available: names.filter { !$0.isEmpty })
        }
        return index + 1   // AppleScript indexes from one.
    }

    // MARK: - Running scripts

    /// Compiles and runs one script, mapping its failure onto `OutlookError`.
    ///
    /// Compiled per call rather than cached: `NSAppleScript` is not `Sendable`
    /// and a compiled script holds a connection to its target, so keeping one
    /// alive across an Outlook restart is a stale-handle bug waiting to happen.
    /// Compilation is microseconds against Apple events measured in seconds.
    private static func run(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else {
            throw OutlookError.scriptingUnavailable
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error { throw OutlookError.fromAppleScript(error) }
        return result
    }

    /// The same, for scripts addressed at one message by id — where "no such
    /// object" is an ordinary outcome rather than a fault. The message may have
    /// been filed, archived or deleted upstream since the sweep saw it, and the
    /// reader should say that rather than report an Apple event number.
    private static func runOnMessage(_ source: String) throws -> NSAppleEventDescriptor {
        do {
            return try run(source)
        } catch let error as OutlookError where error.isMissingObject {
            throw MailSourceError.messageUnavailable
        }
    }
}

/// Serialises Apple events to Outlook. A `.detail` item is always taken
/// before a `.sweep` slice, so a click that wants a body runs at the next
/// event boundary instead of after the rest of the window.
nonisolated final class MailAppleEventQueue: @unchecked Sendable {
    enum Priority {
        case detail
        case sweep
    }

    private let lock = NSLock()
    private var pending: [(priority: Priority, work: () -> Void)] = []
    private var running = false
    private let runner = DispatchQueue(
        label: "com.rihscb.Planner.outlook.mail",
        qos: .userInitiated
    )

    func submit<T: Sendable>(
        priority: Priority,
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            enqueue(priority: priority) {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    func enqueue(priority: Priority, _ work: @escaping () -> Void) {
        lock.lock()
        pending.append((priority, work))
        let start = !running
        if start { running = true }
        lock.unlock()
        if start {
            runner.async { self.drain() }
        }
    }

    private func drain() {
        while true {
            lock.lock()
            let next: (() -> Void)?
            if let index = pending.firstIndex(where: { $0.priority == .detail }) {
                next = pending.remove(at: index).work
            } else if !pending.isEmpty {
                next = pending.removeFirst().work
            } else {
                running = false
                lock.unlock()
                return
            }
            lock.unlock()
            next?()
        }
    }
}
