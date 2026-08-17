import Foundation

/// Last successful Recent Mail window, kept on disk so the next launch can
/// paint the list before Outlook answers.
///
/// A sidecar, not Core Data: the store is CloudKit-bound with one writer, and
/// mirroring a foreign feed into it is the reconcile problem DESIGN.md forbids.
/// The file is local, overwritten as a whole, and ignored when the source id
/// does not match.
nonisolated struct MailEnvelopeRecord: Codable, Sendable, Equatable {
    var sourceID: String
    var windowDays: Int
    var fetchedAt: Date
    var messages: [MailMessage]
}

/// Where the envelope sidecar lives. `.disabled` is the test default so a
/// coordinator constructed in a test never writes into Application Support.
nonisolated struct MailEnvelopeStore: Sendable {
    private let file: MailSidecarFile

    static let disabled = MailEnvelopeStore(file: .disabled)

    static var live: MailEnvelopeStore {
        MailEnvelopeStore(file: .inApplicationSupport(named: "mail-envelopes.json"))
    }

    static func temporary() -> MailEnvelopeStore {
        MailEnvelopeStore(file: .temporary(prefix: "PlannerMailEnvelopes"))
    }

    init(file: MailSidecarFile) {
        self.file = file
    }

    func load() -> MailEnvelopeRecord? { file.load() }

    func save(_ record: MailEnvelopeRecord) { file.save(record) }
}

/// Decides how much of the inbox to re-read given the ids Outlook just
/// reported and the envelopes we already have.
///
/// The inbox is newest-first and monotonic, so new mail is a leading prefix
/// and a grown window puts unknowns at the tail. A tail hole cannot use the
/// range specifier for only the missing rows, so that case falls back to a
/// full read.
nonisolated enum MailEnvelopeSweep {
    enum Plan: Equatable {
        /// Re-read every envelope field. New mail is not a clean prefix, or
        /// the caller asked for a full refresh.
        case full
        /// Full fields for `messages 1 thru prefixCount`; the rest come from
        /// the cache, with `isRead` updated from the cheap scan.
        case prefix(Int)
        /// No unknown ids. Reuse the cache and apply the cheap `isRead` flags.
        case reuse
    }

    static func plan(currentIDs: [Int64], knownIDs: Set<Int64>) -> Plan {
        var prefix = 0
        while prefix < currentIDs.count, !knownIDs.contains(currentIDs[prefix]) {
            prefix += 1
        }
        let tailHasUnknowns = currentIDs.dropFirst(prefix).contains { !knownIDs.contains($0) }
        if tailHasUnknowns { return .full }
        if prefix == 0 { return .reuse }
        return .prefix(prefix)
    }

    /// `currentIDs` is the live inbox order (newest first). `fresh` supplies
    /// full envelopes for ids that were just read; everyone else is the
    /// cached row with an updated read flag. Ids that vanished upstream
    /// are simply not in `currentIDs`, so they drop out.
    static func assemble(
        currentIDs: [Int64],
        isRead: [Int64: Bool],
        known: [Int64: MailMessage],
        fresh: [MailMessage]
    ) -> [MailMessage] {
        let fetched = Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, $0) })
        return currentIDs.compactMap { id in
            if let message = fetched[id] { return message }
            guard let cached = known[id] else { return nil }
            let read = isRead[id] ?? cached.isRead
            return cached.with(isRead: read)
        }
    }
}
