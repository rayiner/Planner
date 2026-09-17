import Foundation
import SQLite3

/// Wire types and helpers for the `olsyncmail daemon` NDJSON protocol.
///
/// One JSON object per line. The daemon speaks snake_case field names, as
/// documented in mailindex's `DAEMON_PROTOCOL.md`. Encoding lives here so the
/// process client stays a pipe, and so the mapping onto Planner's mail types
/// can be tested against captured lines with no helper running.
nonisolated enum OlSyncMailProtocol {
    /// Bumped only on incompatible changes. `hello` reports it; refuse a
    /// daemon that answers something else.
    static let version: UInt32 = 1

    static let databaseFileName = "olsyncmail.sqlite"

    /// `~/Library/Application Support/Planner/olsyncmail.sqlite`, matching the
    /// envelope and dismissal sidecars. Created on first open; the daemon
    /// owns the schema.
    static func databaseURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory = base.appendingPathComponent("Planner", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(databaseFileName)
    }

    /// Recent Mail is still the Inbox window. Dates are Unix seconds, which
    /// `after:` / `before:` accept once they are larger than 10_000_000.
    static func windowQuery(in range: Range<Date>, folder: String = "Inbox") -> String {
        let after = Int64(range.lowerBound.timeIntervalSince1970)
        let before = Int64(range.upperBound.timeIntervalSince1970)
        return "folder:\(folder) after:\(after) before:\(before)"
    }

    static func requestLine(id: UInt64, method: String, params: [String: Any]? = nil) throws -> Data {
        var object: [String: Any] = ["id": NSNumber(value: id), "method": method]
        if let params {
            object["params"] = jsonValue(params)
        }
        guard JSONSerialization.isValidJSONObject(object) else {
            throw OlSyncMailError.badRequest("request was not JSON")
        }
        var data = try JSONSerialization.data(withJSONObject: object, options: [])
        data.append(0x0A)
        return data
    }

    /// `JSONSerialization` only accepts property-list numbers, not `Int64`.
    static func jsonValue(_ value: Any) -> Any {
        switch value {
        case let number as Int64: return NSNumber(value: number)
        case let number as UInt64: return NSNumber(value: number)
        case let dictionary as [String: Any]:
            return dictionary.mapValues { jsonValue($0) }
        case let array as [Any]:
            return array.map { jsonValue($0) }
        default:
            return value
        }
    }

    static func decodeIncoming(_ line: String) throws -> Incoming {
        guard let data = line.data(using: .utf8) else {
            throw OlSyncMailError.badRequest("unreadable line")
        }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw OlSyncMailError.badRequest("line was not an object")
        }
        if let event = dictionary["event"] as? String {
            return .event(try Event(name: event, dictionary: dictionary))
        }
        let id = uint64(dictionary["id"]) ?? 0
        if let error = dictionary["error"] as? [String: Any] {
            let code = error["code"] as? String ?? "internal"
            let message = error["message"] as? String ?? "unknown error"
            return .response(id: id, result: .failure(OlSyncMailError.from(code: code, message: message)))
        }
        let payload: Data
        if let ok = dictionary["ok"] {
            payload = try JSONSerialization.data(withJSONObject: jsonValue(ok))
        } else {
            payload = Data("{}".utf8)
        }
        return .response(id: id, result: .success(payload))
    }

    static func parseMailbox(_ raw: String?) -> (name: String, address: String) {
        guard let raw, !raw.isEmpty else { return ("", "") }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = trimmed.lastIndex(of: "<"),
           let end = trimmed.lastIndex(of: ">"),
           start < end {
            let address = String(trimmed[trimmed.index(after: start)..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var name = String(trimmed[..<start]).trimmingCharacters(in: .whitespacesAndNewlines)
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
                name = String(name.dropFirst().dropLast())
            }
            return (name, address)
        }
        if trimmed.contains("@") { return ("", trimmed) }
        return (trimmed, "")
    }

    /// mbox `Status:` — `R` means read. Missing is treated as unread, matching
    /// Outlook's own default for a flag we have not seen.
    static func isRead(status: String?) -> Bool {
        guard let status else { return false }
        return status.uppercased().contains("R")
    }

    static func envelope(
        hit: [String: Any],
        isRead: Bool
    ) -> MailMessage? {
        let recordID = int64(hit["record_id"])
        let messageID = int64(hit["message_id"])
        guard let id = recordID ?? messageID else { return nil }
        let mailbox = parseMailbox(hit["from"] as? String)
        let date = int64(hit["date"]).map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date()
        return MailMessage(
            id: id,
            subject: hit["subject"] as? String ?? "",
            senderName: mailbox.name,
            senderAddress: mailbox.address,
            receivedAt: date,
            isRead: isRead
        )
    }

    static func detail(from object: [String: Any], fallbackID: Int64) -> MailMessageDetail {
        let id = int64(object["record_id"]) ?? int64(object["message_id"]) ?? fallbackID
        let headerPairs = (object["headers"] as? [[Any]]) ?? []
        let block = headerPairs.compactMap { pair -> String? in
            guard pair.count >= 2, let name = pair[0] as? String else { return nil }
            let value = pair[1] as? String ?? ""
            return "\(name): \(value)"
        }.joined(separator: "\r")
        let parsed = MailHeaders.parse(block.isEmpty ? nil : block)
        let attachments = (object["attachments"] as? [[String: Any]]) ?? []
        let names = attachments.compactMap { $0["filename"] as? String }.filter { !$0.isEmpty }
        let to = object["to"] as? String
        let cc = object["cc"] as? String
        let recipients = [to, cc].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        let html = nonempty(object["body_html"] as? String)
        let rfc822 = object["rfc822_message_id"] as? String
        return MailMessageDetail(
            id: id,
            body: object["body_text"] as? String ?? "",
            html: html,
            messageID: parsed.messageID ?? bracketed(rfc822),
            inReplyTo: parsed.inReplyTo,
            references: parsed.references,
            recipients: recipients.isEmpty ? parsed.recipients : recipients,
            hasAttachments: !names.isEmpty || parsed.hasAttachments,
            attachmentNames: names.isEmpty ? nil : names.joined(separator: "\n")
        )
    }

    static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let number as Int64: return number
        case let number as Int: return Int64(number)
        case let number as NSNumber: return number.int64Value
        case let text as String: return Int64(text)
        default: return nil
        }
    }

    static func bool(_ value: Any?) -> Bool {
        switch value {
        case let flag as Bool: return flag
        case let number as NSNumber: return number.boolValue
        default: return false
        }
    }

    static func uint64(_ value: Any?) -> UInt64? {
        switch value {
        case let number as UInt64: return number
        case let number as Int: return UInt64(number)
        case let number as NSNumber: return number.uint64Value
        default: return nil
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func bracketed(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if value.contains("<") { return MailThreading.referenceIDs(from: value).first }
        return "<\(value)>"
    }

    enum Incoming {
        case response(id: UInt64, result: Result<Data, Error>)
        case event(Event)
    }

    enum Event: Sendable {
        case progress(job: UInt64, phase: String, done: Int, total: Int)
        case jobDone(job: UInt64, cancelled: Bool, selected: Int, indexed: Int, failed: Int)
        case jobFailed(job: UInt64, message: String)

        init(name: String, dictionary: [String: Any]) throws {
            let job = OlSyncMailProtocol.uint64(dictionary["job"]) ?? 0
            switch name {
            case "progress":
                self = .progress(
                    job: job,
                    phase: dictionary["phase"] as? String ?? "",
                    done: Int(OlSyncMailProtocol.int64(dictionary["done"]) ?? 0),
                    total: Int(OlSyncMailProtocol.int64(dictionary["total"]) ?? 0)
                )
            case "job_done":
                self = .jobDone(
                    job: job,
                    cancelled: OlSyncMailProtocol.bool(dictionary["cancelled"]),
                    selected: Int(OlSyncMailProtocol.int64(dictionary["selected"]) ?? 0),
                    indexed: Int(OlSyncMailProtocol.int64(dictionary["indexed"]) ?? 0),
                    failed: Int(OlSyncMailProtocol.int64(dictionary["failed"]) ?? 0)
                )
            case "job_failed":
                self = .jobFailed(job: job, message: dictionary["message"] as? String ?? "sync failed")
            default:
                throw OlSyncMailError.badRequest("unknown event \(name)")
            }
        }
    }
}

/// Read flags are not on the search hit. They are in the `Status` header the
/// indexer stored, and the protocol already expects the client to open the
/// database read-only (that is how attachment bytes are read). WAL mode means
/// this is safe while a sync is writing.
nonisolated enum OlSyncMailReadFlags {
    static func load(database: URL, recordIDs: [Int64]) -> [Int64: Bool] {
        guard !recordIDs.isEmpty else { return [:] }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(database.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            return [:]
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 250)
        _ = sqlite3_exec(handle, "PRAGMA query_only = ON", nil, nil, nil)

        var flagsByID: [Int64: Bool] = [:]
        let chunkSize = 200
        var start = 0
        while start < recordIDs.count {
            let chunk = Array(recordIDs[start..<min(start + chunkSize, recordIDs.count)])
            start += chunkSize
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql = """
            SELECT m.record_id, h.value
              FROM headers h
              JOIN messages m ON m.id = h.message_id
             WHERE lower(h.name) = 'status'
               AND m.record_id IN (\(placeholders))
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                continue
            }
            defer { sqlite3_finalize(statement) }
            for (index, id) in chunk.enumerated() {
                sqlite3_bind_int64(statement, Int32(index + 1), id)
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = sqlite3_column_int64(statement, 0)
                let text = sqlite3_column_text(statement, 1).map { String(cString: $0) }
                flagsByID[id] = OlSyncMailProtocol.isRead(status: text)
            }
        }
        return flagsByID
    }
}

nonisolated enum OlSyncMailError: LocalizedError, Equatable, ExternallyResolvableError {
    case helperMissing
    case protocolMismatch(UInt32)
    case noDatabase
    case profileUnavailable(String)
    case schemaMismatch(String)
    case databaseUnavailable(String)
    case busy
    case querySyntax(String)
    case badRequest(String)
    case daemonExited
    case failed(String)

    static let fullDiskAccessSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )

    static func from(code: String, message: String) -> OlSyncMailError {
        switch code {
        case "query_syntax": return .querySyntax(message)
        case "no_database": return .noDatabase
        case "profile_unavailable": return .profileUnavailable(message)
        case "schema_mismatch": return .schemaMismatch(message)
        case "database_unavailable": return .databaseUnavailable(message)
        case "busy": return .busy
        case "bad_request": return .badRequest(message)
        default: return .failed(message)
        }
    }

    var settingsURL: URL? {
        switch self {
        case .profileUnavailable: return Self.fullDiskAccessSettingsURL
        default: return nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            return "Planner couldn’t find olsyncmail."
        case let .protocolMismatch(version):
            return "olsyncmail speaks protocol \(version), which this build of Planner does not understand."
        case .noDatabase:
            return "The mail index is not open."
        case let .profileUnavailable(message):
            return message.isEmpty ? "Outlook’s profile isn’t readable." : message
        case .schemaMismatch:
            return "The mail index is from an older olsyncmail and needs to be rebuilt."
        case let .databaseUnavailable(message):
            return message.isEmpty ? "The mail index could not be opened." : message
        case .busy:
            return "A mail sync is already running."
        case let .querySyntax(message):
            return message
        case let .badRequest(message):
            return message
        case .daemonExited:
            return "The mail indexer quit unexpectedly."
        case let .failed(message):
            return message
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .helperMissing:
            return "Build olsyncmail and keep it next to Planner, or on your PATH."
        case .profileUnavailable:
            return "Allow Planner under System Settings → Privacy & Security → Full Disk Access, then refresh."
        case .schemaMismatch:
            return "Refresh to rebuild the index. Recent Mail will refill from Outlook."
        case .daemonExited, .databaseUnavailable, .failed, .busy, .noDatabase, .badRequest:
            return "Try refreshing."
        case .protocolMismatch:
            return "Update Planner and olsyncmail together."
        case .querySyntax:
            return nil
        }
    }
}
