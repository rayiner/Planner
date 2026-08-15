import Foundation

enum SelectionField: String {
    case node, day, visibleWeek
}

/// What currently holds the selection. A task (or project) in the outline and a
/// day in the calendar are mutually exclusive: selecting one clears the other,
/// so exactly one thing is ever active across the two panes.
enum PlannerSelection: Equatable {
    case node(UUID)
    case day(Date)
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
    private(set) var selection: PlannerSelection?
    /// First visible Monday. The calendar pages a week at a time.
    private(set) var visibleWeekStart: Date

    var selectedNodeUUID: UUID? {
        if case let .node(uuid) = selection { return uuid }
        return nil
    }

    var selectedDay: Date? {
        if case let .day(date) = selection { return date }
        return nil
    }

    private let calendar: Calendar

    init(now: Date = Date(), calendar: Calendar = .current) {
        self.calendar = calendar
        visibleWeekStart = calendar.startOfWeek(for: now)
    }

    func selectNode(uuid: UUID?) {
        apply(uuid.map { PlannerSelection.node($0) })
    }

    func selectDay(_ date: Date?) {
        apply(date.map { PlannerSelection.day(calendar.startOfDay(for: $0)) })
    }

    func clearSelection() {
        apply(nil)
    }

    /// Posts `.node` and/or `.day` according to which of the two derived values
    /// actually changed, so observers that only care about one keep working
    /// even though a single write can move the selection between them.
    private func apply(_ new: PlannerSelection?) {
        guard selection != new else { return }
        let previousNode = selectedNodeUUID
        let previousDay = selectedDay
        selection = new

        var changed: Set<SelectionField> = []
        if selectedNodeUUID != previousNode { changed.insert(.node) }
        if selectedDay != previousDay { changed.insert(.day) }
        guard !changed.isEmpty else { return }
        post(changed: changed)
    }

    func setVisibleWeekStart(_ date: Date) {
        let normalized = calendar.startOfWeek(for: date)
        guard visibleWeekStart != normalized else { return }
        visibleWeekStart = normalized
        post(changed: [.visibleWeek])
    }

    private func post(changed: Set<SelectionField>) {
        NotificationCenter.default.post(
            name: .plannerSelectionDidChange,
            object: self,
            userInfo: [SelectionUserInfoKey.changedFields: Set(changed.map(\.rawValue))]
        )
    }
}
