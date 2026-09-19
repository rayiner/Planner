import Foundation
import SQLite3

/// Reads attachment bytes from olsyncmail's SQLite store.
///
/// The daemon protocol never carries payloads. Each `MailAttachment` is a key
/// (`sha256`) into the `blobs` table, which the client opens read-only while
/// a sync may still be writing under WAL.
nonisolated enum OlSyncAttachmentStore {
    static let directoryName = "Planner-Attachments"

    private static let sqliteTransient = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )

    /// Copies the blob to a temp file named for the digest and the original
    /// filename, then returns that URL. The same attachment reuses the file
    /// so Preview is not handed a new copy on every click.
    static func fileURL(
        for attachment: MailAttachment,
        databaseURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard attachment.stored, !attachment.sha256.isEmpty else {
            throw MailSourceError.attachmentUnavailable
        }
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName(for: attachment))
        if fileManager.fileExists(atPath: url.path) {
            return url
        }
        let data = try blob(sha256: attachment.sha256, databaseURL: databaseURL)
        try data.write(to: url, options: .atomic)
        return url
    }

    static func fileName(for attachment: MailAttachment) -> String {
        let prefix = String(attachment.sha256.prefix(16))
        let name = safeFileName(attachment.displayName)
        return prefix.isEmpty ? name : "\(prefix)-\(name)"
    }

    static func safeFileName(_ name: String) -> String {
        let last = (name as NSString).lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_ "))
        let cleaned = String(last.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "attachment" : cleaned
    }

    /// Test helper: create a one-table database and insert a blob.
    static func seedForTesting(databaseURL: URL, sha256: String, content: Data) throws {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw MailSourceError.attachmentUnavailable
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(
            db,
            "CREATE TABLE IF NOT EXISTS blobs (sha256 TEXT PRIMARY KEY, content BLOB NOT NULL)",
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            throw MailSourceError.attachmentUnavailable
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT OR REPLACE INTO blobs(sha256, content) VALUES (?, ?)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw MailSourceError.attachmentUnavailable
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, sha256, -1, sqliteTransient)
        _ = content.withUnsafeBytes { raw in
            sqlite3_bind_blob(
                statement,
                2,
                raw.baseAddress,
                Int32(content.count),
                sqliteTransient
            )
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw MailSourceError.attachmentUnavailable
        }
    }

    private static func blob(sha256: String, databaseURL: URL) throws -> Data {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw MailSourceError.attachmentUnavailable
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5_000)
        sqlite3_exec(db, "PRAGMA query_only = ON", nil, nil, nil)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT content FROM blobs WHERE sha256 = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw MailSourceError.attachmentUnavailable
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, sha256, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw MailSourceError.attachmentUnavailable
        }
        guard let bytes = sqlite3_column_blob(statement, 0) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }
}
