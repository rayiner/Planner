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

    let sourceID = "outlook"
    var displayName: String { configuration.accountName ?? "Inbox" }

    private let configuration: Configuration
    /// Apple events block the caller, so this needs a thread of its own, and
    /// serializing means two refreshes can never interleave inside Outlook.
    /// The same shape `OutlookEventSource` uses, for the same reasons.
    private let queue = DispatchQueue(label: "com.rihscb.Planner.outlook.mail", qos: .utility)

    init(configuration: Configuration = .fromDefaults()) {
        self.configuration = configuration
    }

    // MARK: - MailSource

    func envelopes(in range: Range<Date>, userInitiated: Bool) async throws -> [MailMessage] {
        try await onQueue { [configuration] in
            try Self.fetchEnvelopes(
                in: range,
                configuration: configuration,
                userInitiated: userInitiated
            )
        }
    }

    func detail(forMessageID id: Int64) async throws -> MailMessageDetail {
        try await onQueue {
            try Self.preflight(userInitiated: true)
            let payload = try Self.runOnMessage(OutlookMailScripting.detail(messageID: id))
            return OutlookMailDecoder.detail(payload, id: id)
        }
    }

    func reveal(messageID id: Int64) async throws {
        try await onQueue {
            try Self.preflight(userInitiated: true)
            _ = try Self.runOnMessage(OutlookMailScripting.reveal(messageID: id))
        }
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
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

    private static func fetchEnvelopes(
        in range: Range<Date>,
        configuration: Configuration,
        userInitiated: Bool
    ) throws -> [MailMessage] {
        try preflight(userInitiated: userInitiated)

        let started = Date()
        let calendar = Calendar.current
        let accountIndex = try resolveAccountIndex(configuration: configuration)

        // Step one: how far back does the window reach into the list? The
        // collection is newest-first, so this is a count, not a filter.
        let countPayload = try run(OutlookMailScripting.windowCount(
            accountIndex: accountIndex,
            since: range.lowerBound,
            calendar: calendar
        ))
        let matched = Int(OutlookMailDecoder.identifier(countPayload) ?? 0)
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

        // Step two: five columns, one Apple event each.
        let payload = try run(OutlookMailScripting.envelopes(
            accountIndex: accountIndex,
            count: count
        ))
        let decoded = try OutlookMailDecoder.envelopes(payload)
        // The count query only bounds the *older* edge. A message dated in the
        // future — a clock skew upstream, or a draft-like oddity — would sit at
        // the head of the list and belongs nowhere in a "last N days" window.
        let messages = decoded.filter { range.contains($0.receivedAt) }

        // Counts and timings only. Subjects, senders and bodies are someone
        // else's correspondence and never reach the log.
        PlannerLog.mail.info(
            """
            Outlook mail sweep: \(matched, privacy: .public) in window, \
            \(decoded.count, privacy: .public) decoded, \
            \(messages.count, privacy: .public) kept \
            in \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public)ms
            """
        )
        return messages
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
