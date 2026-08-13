import Foundation

enum SelectionField: String {
    case node, day, visibleMonth
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
    private(set) var selectedNodeUUID: UUID?
    private(set) var selectedDay: Date?
    private(set) var visibleMonth: Date

    private let calendar: Calendar

    init(now: Date = Date(), calendar: Calendar = .current) {
        self.calendar = calendar
        visibleMonth = calendar.startOfMonth(for: now)
    }

    func selectNode(uuid: UUID?) {
        guard selectedNodeUUID != uuid else { return }
        selectedNodeUUID = uuid
        post(changed: [.node])
    }

    func selectDay(_ date: Date?) {
        let normalized = date.map { calendar.startOfDay(for: $0) }
        guard selectedDay != normalized else { return }
        selectedDay = normalized
        post(changed: [.day])
    }

    func setVisibleMonth(_ date: Date) {
        let normalized = calendar.startOfMonth(for: date)
        guard visibleMonth != normalized else { return }
        visibleMonth = normalized
        post(changed: [.visibleMonth])
    }

    private func post(changed: Set<SelectionField>) {
        NotificationCenter.default.post(
            name: .plannerSelectionDidChange,
            object: self,
            userInfo: [SelectionUserInfoKey.changedFields: Set(changed.map(\.rawValue))]
        )
    }
}
