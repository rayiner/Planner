import Foundation

/// One message the user has removed from Recent Mail.
///
/// Recent Mail is a view of Outlook, and Planner never writes to Outlook, so a
/// dismissal cannot be recorded where the message lives. It is recorded here
/// instead: the list is Planner's own, local, and consulted on every sweep.
/// **Nothing about the message in Outlook changes** — dismissing hides a row.
///
/// Identified by Outlook's record id *and* the received date, because the id
/// alone is not safe enough to hide things by. It is unique only within the
/// local Outlook database, so a rebuild or a re-sync can hand the same integer
/// to an unrelated message; pairing it with the date makes that collision
/// vanishingly unlikely, and a pair that fails to match simply shows the
/// message, which is the harmless direction to fail in.
///
/// Keying on the RFC `Message-ID` would be the principled choice and is not
/// available: it lives in the headers, and `MailMessage` carries no headers on
/// purpose — fetching them per message is what makes a window sweep take
/// minutes instead of seconds.
nonisolated struct MailDismissal: Codable, Sendable, Hashable {
    var id: Int64
    var receivedAt: Date
}

/// The dismissal list as it sits on disk. `sourceID` is checked on load for the
/// same reason the envelope cache checks it: ids from one mail source mean
/// nothing to another.
nonisolated struct MailDismissalRecord: Codable, Sendable, Equatable {
    var sourceID: String
    var dismissals: [MailDismissal]
}

/// The dismissal list in memory: a membership test over `MailMessage`.
///
/// Dates are bucketed to the second rather than compared exactly. A dismissal
/// is written from a date that has been through JSON and matched against one
/// freshly decoded from an Apple event, and a hidden row that quietly comes
/// back because two representations of the same instant differ in their last
/// bits is a bug with no visible cause. Outlook reports whole seconds anyway.
nonisolated struct MailDismissalSet: Equatable, Sendable {
    private var secondByID: [Int64: Int64]

    init(_ dismissals: [MailDismissal] = []) {
        secondByID = Dictionary(
            dismissals.map { ($0.id, Self.second(of: $0.receivedAt)) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    var isEmpty: Bool { secondByID.isEmpty }
    var count: Int { secondByID.count }

    /// Newest first, so a hand-read of the file starts with what was just done.
    var entries: [MailDismissal] {
        secondByID
            .map { MailDismissal(id: $0.key, receivedAt: Date(timeIntervalSince1970: TimeInterval($0.value))) }
            .sorted { $0.receivedAt == $1.receivedAt ? $0.id > $1.id : $0.receivedAt > $1.receivedAt }
    }

    func contains(_ message: MailMessage) -> Bool {
        secondByID[message.id] == Self.second(of: message.receivedAt)
    }

    mutating func insert(_ message: MailMessage) {
        secondByID[message.id] = Self.second(of: message.receivedAt)
    }

    /// Only removes the dismissal this exact message put there, so undoing one
    /// dismissal cannot clear a same-id entry that belongs to another message.
    mutating func remove(_ message: MailMessage) {
        guard contains(message) else { return }
        secondByID[message.id] = nil
    }

    /// Drops dismissals that can never be consulted again.
    ///
    /// A message older than the window cannot come back into it, so its
    /// dismissal is dead weight — this is what keeps the file from growing
    /// forever. The caller passes the cutoff for the **maximum** window rather
    /// than the current one: dismissing at a one-day window and later widening
    /// to seven must not resurrect everything that was dismissed in between.
    func pruned(before cutoff: Date) -> MailDismissalSet {
        let bound = Self.second(of: cutoff)
        var copy = self
        copy.secondByID = secondByID.filter { $0.value >= bound }
        return copy
    }

    private static func second(of date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded())
    }
}

/// Where the dismissal sidecar lives.
///
/// A separate file from the envelope cache, not a field inside it. The cache is
/// disposable — overwritten whole on every sweep and discarded outright when
/// the source id changes — while a dismissal is something the user did, and has
/// to outlive any of that. `.disabled` is the test default.
nonisolated struct MailDismissalStore: Sendable {
    private let file: MailSidecarFile

    static let disabled = MailDismissalStore(file: .disabled)

    static var live: MailDismissalStore {
        MailDismissalStore(file: .inApplicationSupport(named: "mail-dismissals.json"))
    }

    static func temporary() -> MailDismissalStore {
        MailDismissalStore(file: .temporary(prefix: "PlannerMailDismissals"))
    }

    init(file: MailSidecarFile) {
        self.file = file
    }

    func load() -> MailDismissalRecord? { file.load() }

    func save(_ record: MailDismissalRecord) { file.save(record) }
}
