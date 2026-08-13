import AppKit

final class PlannerOutlineView: NSOutlineView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        return menu(forRow: row(at: location))
    }

    func menu(forRow row: Int) -> NSMenu {
        if row >= 0 {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            window?.makeFirstResponder(self)
            switch item(atRow: row) {
            case is Project:
                return Self.makeMenu([
                    ("New Task", #selector(MainSplitViewController.newTask(_:))),
                    ("Delete\u{2026}", #selector(MainSplitViewController.deleteSelected(_:))),
                ])
            case is TaskItem:
                return Self.makeMenu([
                    ("New Subtask", #selector(MainSplitViewController.newSubtask(_:))),
                    ("Delete\u{2026}", #selector(MainSplitViewController.deleteSelected(_:))),
                ])
            default:
                break
            }
        }
        return Self.makeMenu([
            ("New Project", #selector(MainSplitViewController.newProject(_:))),
        ])
    }

    private static func makeMenu(_ items: [(String, Selector)]) -> NSMenu {
        let menu = NSMenu()
        for (title, action) in items {
            menu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: ""))
        }
        return menu
    }
}
