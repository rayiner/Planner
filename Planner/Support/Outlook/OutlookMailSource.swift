import Foundation

/// Recent Mail, filled from the `olsyncmail` daemon rather than Apple events.
///
/// Planner owns one daemon process, talks NDJSON on its stdin/stdout, and
/// keeps the index at `~/Library/Application Support/Planner/olsyncmail.sqlite`.
/// Envelope lists and bodies come from that database after a `sync`; opening a
/// message in Outlook is still a user-initiated Apple event, because that is a
/// command, not a read.
nonisolated final class OutlookMailSource: MailSource, @unchecked Sendable {
    struct Configuration: Sendable, Equatable {
        /// `nil` means "whichever Exchange account Outlook lists first" — kept
        /// so an existing `defaults write` does not become a dead key, even
        /// though the indexer currently reads the default Outlook profile.
        var accountName: String?
        /// A ceiling on one Recent Mail window, so a firehose inbox cannot
        /// stall the list. The index itself is not capped.
        var maximumMessages: Int

        static let defaultMaximumMessages = 400

        static let accountDefaultsKey = "mail.accountName"
        static let maximumDefaultsKey = "mail.maximumMessages"

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
    private let databaseURL: URL
    private let daemon: OlSyncMailDaemon?
    private let lock = NSLock()
    /// Outlook record id → indexer row id. `message` is addressed by the
    /// latter; Recent Mail and reveal still use the former.
    private var rowIDs: [Int64: Int64] = [:]
    private var ready = false

    init(
        configuration: Configuration = .fromDefaults(),
        databaseURL: URL = OlSyncMailProtocol.databaseURL(),
        daemon: OlSyncMailDaemon? = nil
    ) {
        self.configuration = configuration
        self.databaseURL = databaseURL
        if let daemon {
            self.daemon = daemon
        } else if let executable = OlSyncMailDaemon.resolveExecutable() {
            self.daemon = OlSyncMailDaemon(executable: executable)
        } else {
            self.daemon = nil
        }
    }

    deinit {
        daemon?.shutdown()
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
        let daemon = try helper()
        try await prepare(daemon: daemon)
        try await synchronize(daemon: daemon, in: range, userInitiated: userInitiated)
        return try await loadEnvelopes(daemon: daemon, in: range)
    }

    func detail(forMessageID id: Int64) async throws -> MailMessageDetail {
        let daemon = try helper()
        try await prepare(daemon: daemon)
        let rowID = lock.withLock { rowIDs[id] } ?? id
        do {
            let object = try await daemon.message(id: rowID)
            return OlSyncMailProtocol.detail(from: object, fallbackID: id)
        } catch let error as OlSyncMailError {
            if case .failed(let message) = error, message.contains("no message") {
                throw MailSourceError.messageUnavailable
            }
            throw error
        }
    }

    func reveal(messageID id: Int64) async throws {
        try Self.runOnMessage(OutlookMailScripting.reveal(messageID: id))
    }

    // MARK: - Session

    private func helper() throws -> OlSyncMailDaemon {
        guard let daemon else { throw OlSyncMailError.helperMissing }
        return daemon
    }

    private func prepare(daemon: OlSyncMailDaemon) async throws {
        if lock.withLock({ ready }) { return }
        let hello = try await daemon.hello()
        let protocolVersion = UInt32(OlSyncMailProtocol.int64(hello["protocol"]) ?? 0)
        guard protocolVersion == OlSyncMailProtocol.version else {
            throw OlSyncMailError.protocolMismatch(protocolVersion)
        }
        do {
            _ = try await daemon.open(database: databaseURL)
        } catch OlSyncMailError.schemaMismatch {
            try Self.removeDatabase(at: databaseURL)
            _ = try await daemon.open(database: databaseURL)
        }
        lock.withLock { ready = true }
    }

    private func synchronize(
        daemon: OlSyncMailDaemon,
        in range: Range<Date>,
        userInitiated: Bool
    ) async throws {
        let pending: [String: Any]
        do {
            pending = try await daemon.refresh()
        } catch {
            // No prior sync: refresh still needs Outlook's profile. Fall
            // through to `sync`, which reports the same permission errors.
            pending = [:]
            PlannerLog.mail.info("olsyncmail refresh skipped: \(error.localizedDescription, privacy: .public)")
        }
        let changed = OlSyncMailProtocol.int64(pending["changed_since_last_sync"]) ?? 1
        let lastSync = OlSyncMailProtocol.int64(pending["last_sync"])
        guard userInitiated || lastSync == nil || changed > 0 else {
            PlannerLog.mail.info("olsyncmail: index is current")
            return
        }
        let since = Int64(range.lowerBound.timeIntervalSince1970)
        try await daemon.sync(since: since)
    }

    private func loadEnvelopes(daemon: OlSyncMailDaemon, in range: Range<Date>) async throws -> [MailMessage] {
        let query = OlSyncMailProtocol.windowQuery(in: range)
        let limit = configuration.maximumMessages
        let hits = try await daemon.search(query: query, limit: limit)
        let recordIDs = hits.compactMap { OlSyncMailProtocol.int64($0["record_id"]) }
        let readFlags = OlSyncMailReadFlags.load(database: databaseURL, recordIDs: recordIDs)
        var mapping: [Int64: Int64] = [:]
        let messages: [MailMessage] = hits.compactMap { hit in
            let recordID = OlSyncMailProtocol.int64(hit["record_id"])
            let rowID = OlSyncMailProtocol.int64(hit["message_id"])
            if let recordID, let rowID {
                mapping[recordID] = rowID
            }
            let isRead = recordID.flatMap { readFlags[$0] } ?? false
            guard let message = OlSyncMailProtocol.envelope(hit: hit, isRead: isRead) else { return nil }
            return range.contains(message.receivedAt) ? message : nil
        }
        lock.withLock { rowIDs.merge(mapping, uniquingKeysWith: { _, new in new }) }
        PlannerLog.mail.info(
            "olsyncmail search kept \(messages.count, privacy: .public) of \(hits.count, privacy: .public) hits"
        )
        return messages
    }

    private static func removeDatabase(at url: URL) throws {
        let extras = ["", "-wal", "-shm"]
        for extra in extras {
            let file = extra.isEmpty ? url : URL(fileURLWithPath: url.path + extra)
            try? FileManager.default.removeItem(at: file)
        }
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
}
