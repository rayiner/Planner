import Foundation

enum SelectionField: String {
    case node, day, visibleWeek, mode, mailbox, message
}

/// Which of the two three-pane layouts the window is showing.
///
/// A mode, not a window: the unified sidebar stays put and the two trailing
/// panes are replaced wholesale. The mode is whichever sidebar row is
/// selected — a project or task shows the calendar, a mailbox shows the
/// reader. There is no separate Tasks / Mail command.
enum PlannerMode: String {
    case tasks, mail
}

/// What currently holds the selection. A task (or project) in the outline and a
/// day in the calendar are mutually exclusive: selecting one clears the other,
/// so exactly one thing is ever active across the two panes.
enum PlannerSelection: Equatable {
    case node(UUID)
    case day(Date)
}

/// Which mailbox the mail sidebar has selected. `recent` is the transient
/// window over Outlook; a folder is Planner's own saved mail.
enum MailboxSelection: Equatable {
    case recent
    case folder(UUID)
}

/// Which message is open in the reader. The two cases are genuinely different
/// things — an Outlook record id that is only valid this session, and a
/// `SavedMessage` UUID that is Planner's own — and conflating them is how a
/// reader ends up showing the wrong message after a save.
enum MessageSelection: Equatable {
    case recent(Int64)
    case saved(UUID)
}

extension Notification.Name {
    static let plannerSelectionDidChange = Notification.Name("plannerSelectionDidChange")
}

enum SelectionUserInfoKey {
    /// `Set<SelectionField>` (boxed as `Set<String>` of raw values) of fields that actually changed.
    static let changedFields = "changedFields"
}

@MainActor
final class SelectionModel {
    static let modeDefaultsKey = "planner.mode"

    private(set) var selection: PlannerSelection?
    /// First visible day on the grid. The calendar pages by one column of days.
    private(set) var visibleWeekStart: Date
    private(set) var mode: PlannerMode
    private(set) var mailbox: MailboxSelection = .recent
    private(set) var message: MessageSelection?

    var selectedNodeUUID: UUID? {
        if case let .node(uuid) = selection { return uuid }
        return nil
    }

    var selectedDay: Date? {
        if case let .day(date) = selection { return date }
        return nil
    }

    var selectedFolderUUID: UUID? {
        if case let .folder(uuid) = mailbox { return uuid }
        return nil
    }

    var isRecentMailSelected: Bool { mailbox == .recent }

    private let calendar: Calendar
    private let defaults: UserDefaults

    init(now: Date = Date(), calendar: Calendar = .current, defaults: UserDefaults = .standard) {
        self.calendar = calendar
        self.defaults = defaults
        visibleWeekStart = calendar.startOfDay(for: now)
        mode = defaults.string(forKey: Self.modeDefaultsKey)
            .flatMap(PlannerMode.init(rawValue:)) ?? .tasks
    }

    func selectNode(uuid: UUID?) {
        apply(uuid.map { PlannerSelection.node($0) }, adopting: uuid == nil ? nil : .tasks)
    }

    func selectDay(_ date: Date?) {
        apply(
            date.map { PlannerSelection.day(calendar.startOfDay(for: $0)) },
            adopting: date == nil ? nil : .tasks
        )
    }

    func clearSelection() {
        apply(nil)
    }

    /// Posts `.node` and/or `.day` according to which of the two derived values
    /// actually changed, so observers that only care about one keep working
    /// even though a single write can move the selection between them. A
    /// concrete node or day also enters tasks mode in the same post: the
    /// trailing panes follow the sidebar (or calendar) row, not a separate
    /// mode command.
    private func apply(_ new: PlannerSelection?, adopting mode: PlannerMode? = nil) {
        let previousNode = selectedNodeUUID
        let previousDay = selectedDay
        if selection != new { selection = new }

        var changed: Set<SelectionField> = []
        if selectedNodeUUID != previousNode { changed.insert(.node) }
        if selectedDay != previousDay { changed.insert(.day) }
        if let mode, adoptMode(mode) { changed.insert(.mode) }
        guard !changed.isEmpty else { return }
        post(changed: changed)
    }

    func setVisibleWeekStart(_ date: Date) {
        let normalized = calendar.startOfDay(for: date)
        guard visibleWeekStart != normalized else { return }
        visibleWeekStart = normalized
        post(changed: [.visibleWeek])
    }

    // MARK: - Mode

    /// Low-level pane swap. Callers that have a sidebar row should select
    /// that row instead — `selectNode` / `selectMailbox` adopt the mode.
    func setMode(_ new: PlannerMode) {
        guard adoptMode(new) else { return }
        post(changed: [.mode])
    }

    @discardableResult
    private func adoptMode(_ new: PlannerMode) -> Bool {
        guard mode != new else { return false }
        mode = new
        defaults.set(new.rawValue, forKey: Self.modeDefaultsKey)
        return true
    }

    // MARK: - Mail

    /// Selecting a mailbox enters mail mode. The open message is cleared
    /// when the mailbox itself changes, so the reader cannot keep showing
    /// something the list no longer contains. Re-selecting the current
    /// mailbox from tasks mode still enters mail — the mailbox field is
    /// unchanged, but the sidebar row is.
    func selectMailbox(_ new: MailboxSelection) {
        var changed: Set<SelectionField> = []
        if mailbox != new {
            mailbox = new
            changed.insert(.mailbox)
            if message != nil {
                message = nil
                changed.insert(.message)
            }
        }
        if adoptMode(.mail) { changed.insert(.mode) }
        guard !changed.isEmpty else { return }
        post(changed: changed)
    }

    func selectMessage(_ new: MessageSelection?) {
        guard message != new else { return }
        message = new
        post(changed: [.message])
    }

    private func post(changed: Set<SelectionField>) {
        NotificationCenter.default.post(
            name: .plannerSelectionDidChange,
            object: self,
            userInfo: [SelectionUserInfoKey.changedFields: Set(changed.map(\.rawValue))]
        )
    }
}
