import Foundation

/// Recent Mail, filled from the `olsyncmail` daemon rather than Apple events.
///
/// Planner owns one daemon process, talks NDJSON on its stdin/stdout, and
/// keeps the index at `~/Library/Application Support/Planner/olsyncmail.sqlite`.
/// Envelope lists and bodies come from that database after a `sync` of every
/// non-hidden Outlook message. The Recent Mail window only filters the list;
/// search and MCP see the whole index. Opening a message and changing its
/// `Hide` category are user-initiated Apple events.
nonisolated final class OutlookMailSource: MailSource, @unchecked Sendable {
    struct Configuration: Sendable, Equatable {
        /// `nil` means "whichever Exchange account Outlook lists first" — kept
        /// so an existing `defaults write` does not become a dead key, even
        /// though the indexer currently reads the default Outlook profile.
        var accountName: String?
        /// A hand-set flat ceiling on one Recent Mail window. `nil` — the
        /// normal case — scales the ceiling with the window instead; see
        /// `messageLimit(for:)`.
        var maximumMessages: Int?

        /// A ceiling on one Recent Mail window, so a firehose inbox cannot
        /// stall the list. The index itself is not capped.
        ///
        /// Per day, because the window runs from one day to a month: a flat
        /// number with comfortable headroom over three days is a silent
        /// truncation over thirty, and a truncated window is worse than a slow
        /// one — the list simply stops mid-month with nothing saying why. The
        /// value is about three times the busiest mailbox measured (~50
        /// messages a day), so it stays a backstop rather than a limit.
        static let defaultMaximumMessagesPerDay = 150

        static let accountDefaultsKey = "mail.accountName"
        static let maximumDefaultsKey = "mail.maximumMessages"

        static func fromDefaults(_ defaults: UserDefaults = .standard) -> Configuration {
            let account = defaults.string(forKey: accountDefaultsKey)?
                .trimmingCharacters(in: .whitespaces)
            let maximum = defaults.integer(forKey: maximumDefaultsKey)
            return Configuration(
                accountName: (account?.isEmpty ?? true) ? nil : account,
                maximumMessages: maximum > 0 ? maximum : nil
            )
        }

        /// Whole days, rounded, so a window that crosses a daylight-saving
        /// boundary is still the number of days the user asked for.
        func messageLimit(for range: Range<Date>) -> Int {
            if let maximumMessages { return maximumMessages }
            let span = range.upperBound.timeIntervalSince(range.lowerBound) / 86_400
            let days = max(1, Int(span.rounded()))
            return days * Self.defaultMaximumMessagesPerDay
        }
    }

    let sourceID = "outlook"
    var displayName: String { configuration.accountName ?? "Inbox" }

    private let configuration: Configuration
    private let session: OlSyncOutlookSession?
    private let lock = NSLock()
    /// Outlook record id → indexer row id. `message` is addressed by the
    /// latter; Recent Mail and reveal still use the former.
    private var rowIDs: [Int64: Int64] = [:]
    private var categoryCatalog: [OutlookCategory] = []

    init(
        configuration: Configuration = .fromDefaults(),
        databaseURL: URL = OlSyncMailProtocol.databaseURL(),
        daemon: OlSyncMailDaemon? = nil,
        session: OlSyncOutlookSession? = nil
    ) {
        self.configuration = configuration
        if let session {
            self.session = session
        } else if let daemon {
            self.session = OlSyncOutlookSession(daemon: daemon, databaseURL: databaseURL)
        } else if let executable = OlSyncMailDaemon.resolveExecutable() {
            self.session = OlSyncOutlookSession(
                daemon: OlSyncMailDaemon(executable: executable),
                databaseURL: databaseURL
            )
        } else {
            self.session = nil
        }
    }

    // MARK: - MailSource

    func envelopes(in range: Range<Date>, userInitiated: Bool) async throws -> [MailMessage] {
        try await envelopes(in: range, known: [], userInitiated: userInitiated)
    }

    func envelopes(
        in range: Range<Date>,
        known _: [MailMessage],
        userInitiated: Bool
    ) async throws -> [MailMessage] {
        let session = try helper()
        try await synchronize(session: session, userInitiated: userInitiated)
        return try await loadEnvelopes(session: session, in: range)
    }

    func folders() async throws -> [MailFolder] {
        let session = try helper()
        return try await session.folders()
    }

    func search(query: String) async throws -> [MailMessage] {
        let session = try helper()
        let pageSize = 500
        var hits: [[String: Any]] = []
        while true {
            let page = try await session.search(
                query: query,
                limit: pageSize,
                offset: hits.count
            )
            hits.append(contentsOf: page.map(\.value))
            if page.count < pageSize { break }
        }
        let categories = try await session.categories()
        return messages(from: hits, categories: categories)
    }

    func availableCategories() async throws -> [OutlookCategory] {
        lock.withLock { categoryCatalog }
    }

    func detail(forMessageID id: Int64) async throws -> MailMessageDetail {
        let session = try helper()
        let rowID = lock.withLock { rowIDs[id] } ?? id
        do {
            let object = try await session.message(id: rowID).value
            return OlSyncMailProtocol.detail(from: object, fallbackID: id)
        } catch let error as OlSyncMailError {
            if case .failed(let message) = error, message.contains("no message") {
                throw MailSourceError.messageUnavailable
            }
            throw error
        }
    }

    func fileURL(for attachment: MailAttachment) async throws -> URL {
        try await helper().fileURL(for: attachment)
    }

    func reveal(messageID id: Int64) async throws {
        try Self.runOnMessage(OutlookMailScripting.reveal(messageID: id))
    }

    func setHidden(_ hidden: Bool, messageID id: Int64) async throws {
        try Self.runOSAScript(OutlookMailScripting.setHidden(hidden, messageID: id))
    }

    func setCategory(_ categoryID: Int64, present: Bool, messageID id: Int64) async throws {
        guard let recordID = lock.withLock({
            categoryCatalog.first { $0.id == categoryID }?.outlookRecordID
        }) else {
            throw OlSyncMailError.badRequest("Unknown Outlook category.")
        }
        try Self.runOSAScript(
            OutlookMailScripting.setCategory(recordID, present: present, messageID: id)
        )
    }

    // MARK: - Session

    private func helper() throws -> OlSyncOutlookSession {
        guard let session else { throw OlSyncMailError.helperMissing }
        return session
    }

    private func synchronize(
        session: OlSyncOutlookSession,
        userInitiated: Bool
    ) async throws {
        let pending: [String: Any]
        do {
            pending = try await session.refresh().value
        } catch {
            // No prior sync: refresh still needs Outlook's profile. Fall
            // through to `sync`, which reports the same permission errors.
            pending = [:]
            PlannerLog.mail.info("olsyncmail refresh skipped: \(error.localizedDescription, privacy: .public)")
        }
        let changed = OlSyncMailProtocol.int64(pending["changed_since_last_sync"]) ?? 1
        let indexed = OlSyncMailProtocol.int64(pending["indexed_messages"]) ?? 0
        let lastSync = OlSyncMailProtocol.int64(pending["last_sync"])
        guard userInitiated || lastSync == nil || indexed == 0 || changed > 0 else {
            PlannerLog.mail.info("olsyncmail: index is current")
            return
        }
        // The Recent Mail window only filters the list. Search and MCP read
        // this index, so a launch sync has to take every non-hidden message.
        try await session.syncMail()
    }

    func rebuildIndex() async throws {
        try await helper().fullResync()
    }

    private func loadEnvelopes(
        session: OlSyncOutlookSession,
        in range: Range<Date>
    ) async throws -> [MailMessage] {
        let query = OlSyncMailProtocol.windowQuery(in: range)
        let limit = configuration.messageLimit(for: range)
        let hits = try await session.search(query: query, limit: limit).map(\.value)
        let categories = try await session.categories()
        let messages = messages(from: hits, categories: categories, in: range)
        PlannerLog.mail.info(
            "olsyncmail search kept \(messages.count, privacy: .public) of \(hits.count, privacy: .public) hits"
        )
        return messages
    }

    /// Converts search hits and remembers the daemon's internal row ids so a
    /// selected hit can immediately ask `message` for its body.
    private func messages(
        from hits: [[String: Any]],
        categories: [OutlookCategory],
        in range: Range<Date>? = nil
    ) -> [MailMessage] {
        let hiddenCategoryIDs = Set(categories.compactMap {
            $0.name.caseInsensitiveCompare(OutlookCategory.hiddenName) == .orderedSame ? $0.id : nil
        })
        let availableCategories = categories.filter {
            $0.name.caseInsensitiveCompare(OutlookCategory.hiddenName) != .orderedSame
        }
        var mapping: [Int64: Int64] = [:]
        let messages: [MailMessage] = hits.compactMap { hit in
            let recordID = OlSyncMailProtocol.int64(hit["record_id"])
            let rowID = OlSyncMailProtocol.int64(hit["message_id"])
            if let recordID, let rowID {
                mapping[recordID] = rowID
            }
            let categoryIDs = OlSyncMailProtocol.categoryIDs(fromHit: hit)
            guard let message = OlSyncMailProtocol.envelope(
                hit: hit,
                isHidden: !categoryIDs.isDisjoint(with: hiddenCategoryIDs),
                categoryIDs: categoryIDs
            ) else { return nil }
            if let range, !range.contains(message.receivedAt) { return nil }
            return message
        }
        lock.withLock {
            rowIDs.merge(mapping, uniquingKeysWith: { _, new in new })
            categoryCatalog = availableCategories
        }
        return messages
    }

    private static func runOnMessage(_ source: String) throws {
        guard let script = NSAppleScript(source: source) else {
            throw OutlookError.scriptingUnavailable
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            let mapped = OutlookError.fromAppleScript(error)
            if mapped.isMissingObject { throw MailSourceError.messageUnavailable }
            throw mapped
        }
    }

    private static func runOSAScript(_ source: String) throws {
        let process = Process()
        let input = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"]
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw OutlookError.scriptingUnavailable
        }
        input.fileHandleForWriting.write(Data(source.utf8))
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return }

        let text = String(
            data: errors.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let code = text
            .split(whereSeparator: { !$0.isNumber && $0 != "-" })
            .compactMap { Int($0) }
            .last
        let mapped = code.map(OutlookError.fromAppleEvent(code:)) ?? .scriptingUnavailable
        if mapped.isMissingObject { throw MailSourceError.messageUnavailable }
        throw mapped
    }
}
