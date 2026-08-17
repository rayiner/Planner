import Foundation

/// A local JSON file holding one `Codable` record, written whole.
///
/// Both mail sidecars are this shape — the envelope cache and the dismissal
/// list — so the file plumbing lives here once: local rather than CloudKit,
/// overwritten atomically, and an unreadable or absent file treated as "no
/// record" rather than as an error. Neither sidecar is worth failing a launch
/// over; the envelope cache re-fills on the next sweep, and a lost dismissal
/// list only means some rows come back.
///
/// A `nil` url is the test default, so a store built in a test can never write
/// into Application Support.
nonisolated struct MailSidecarFile: Sendable {
    let url: URL?

    static let disabled = MailSidecarFile(url: nil)

    static func inApplicationSupport(named name: String) -> MailSidecarFile {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("Planner", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return MailSidecarFile(url: directory.appendingPathComponent(name))
    }

    static func temporary(prefix: String) -> MailSidecarFile {
        MailSidecarFile(
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("\(prefix)-\(UUID().uuidString).json")
        )
    }

    func load<Record: Decodable>(_ type: Record.Type = Record.self) -> Record? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    func save(_ record: some Encodable) {
        guard let url else { return }
        do {
            try JSONEncoder().encode(record).write(to: url, options: .atomic)
        } catch {
            PlannerLog.mail.error(
                """
                Sidecar write failed for \(url.lastPathComponent, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """
            )
        }
    }
}
