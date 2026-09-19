import Foundation

/// Wire types and helpers for the `olsyncmail daemon` NDJSON protocol.
///
/// One JSON object per line. The daemon speaks snake_case field names, as
/// documented in mailindex's `DAEMON_PROTOCOL.md`. Encoding lives here so the
/// process client stays a pipe, and so the mapping onto Planner's mail types
/// can be tested against captured lines with no helper running.
nonisolated enum OlSyncMailProtocol {
    /// Bumped only on incompatible changes. `hello` reports it; refuse a
    /// daemon that answers something else.
    ///
    /// 2 — the daemon gained `categories` and `category_items`, and `message`
    /// now carries the item's categories.
    /// 3 — search hits and `message` carry `is_read`. The helper ships in this
    /// bundle, so the two move together.
    /// 4 — search hits and `message` carry `account_uid`, which is what says
    /// which categories a message may be given.
    /// 5 — calendar occurrence listing and event sync/open counters.
    static let version: UInt32 = 5

    static let databaseFileName = "olsyncmail.sqlite"

    /// `~/Library/Application Support/Planner/olsyncmail.sqlite`. Created on
    /// first open; the daemon owns the schema.
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
        isHidden: Bool = false,
        categoryIDs: Set<Int64> = []
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
            isRead: bool(hit["is_read"]),
            isHidden: isHidden,
            categoryIDs: categoryIDs,
            accountUID: int64(hit["account_uid"]) ?? 0,
            preview: preview(hit["preview"])
        )
    }

    /// The index stores the snippet with runs of whitespace already collapsed,
    /// but not every indexer pass did, and a stray newline would push the rest
    /// of the line out of a single-line label. Collapse again and cap the length:
    /// a row shows one line, and 255 characters is far more than fits.
    static func preview(_ value: Any?) -> String {
        guard let text = value as? String else { return "" }
        let flattened = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(flattened.prefix(255))
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
        let attachments = attachments(from: object)
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
            hasAttachments: !attachments.isEmpty || parsed.hasAttachments,
            attachments: attachments
        )
    }

    /// Keys the daemon puts on `message`, including whether the payload is
    /// actually in `blobs`. Filenames without a digest still belong in the
    /// list so the reader can say they exist.
    static func attachments(from object: [String: Any]) -> [MailAttachment] {
        (object["attachments"] as? [[String: Any]] ?? []).compactMap { raw in
            let filename = (raw["filename"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let sha256 = (raw["sha256"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let id = int64(raw["attachment_id"]) ?? 0
            guard id != 0 || !filename.isEmpty || !sha256.isEmpty else { return nil }
            return MailAttachment(
                id: id,
                filename: filename,
                contentType: nonempty(raw["content_type"] as? String),
                size: int64(raw["size"]) ?? 0,
                sha256: sha256,
                stored: bool(raw["stored"]),
                isInline: bool(raw["is_inline"]),
                blobRowid: int64(raw["blob_rowid"])
            )
        }
    }

    /// Decode the `categories` reply.
    ///
    /// The daemon groups by account because a category name is unique only
    /// within one — two accounts can each define "Hide" — so the account comes
    /// back with every category and is kept on the way in.
    static func categories(from object: [String: Any]) -> [OutlookCategory] {
        guard let accounts = object["accounts"] as? [[String: Any]] else { return [] }
        var out: [OutlookCategory] = []
        for account in accounts {
            let uid = int64(account["account_uid"]) ?? 0
            let name = nonempty(account["account"] as? String)
            for raw in account["categories"] as? [[String: Any]] ?? [] {
                guard let id = int64(raw["id"]),
                      let categoryName = nonempty(raw["name"] as? String)
                else { continue }
                out.append(OutlookCategory(
                    id: id,
                    name: categoryName,
                    recordID: int64(raw["record_id"]),
                    accountUID: uid,
                    account: name,
                    colorHex: nonempty(raw["color"] as? String)
                ))
            }
        }
        return out
    }

    /// The categories on one message, from the `message` reply.
    static func categories(fromMessage object: [String: Any]) -> [OutlookCategory] {
        (object["categories"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let id = int64(raw["id"]),
                  let name = nonempty(raw["name"] as? String)
            else { return nil }
            return OutlookCategory(
                id: id,
                name: name,
                recordID: nil,
                accountUID: int64(raw["account_uid"]) ?? 0,
                account: nonempty(raw["account"] as? String),
                colorHex: nonempty(raw["color"] as? String)
            )
        }
    }

    /// Decode the `folders` reply: distinct index paths and their counts.
    static func folders(from object: [String: Any]) -> [MailFolder] {
        (object["folders"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let name = nonempty(raw["name"] as? String) else { return nil }
            return MailFolder(name: name, messageCount: Int(int64(raw["message_count"]) ?? 0))
        }
    }

    /// Local category ids carried directly on a daemon search hit.
    static func categoryIDs(fromHit object: [String: Any]) -> Set<Int64> {
        Set((object["category_ids"] as? [Any] ?? []).compactMap(int64))
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
        if value.contains("<") { return MailHeaders.referenceIDs(from: value).first }
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
