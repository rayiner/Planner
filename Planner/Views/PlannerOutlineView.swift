import AppKit

final class PlannerOutlineView: NSOutlineView {
    var pendingRenameRow: Int = -1

    override func mouseDown(with event: NSEvent) {
        (delegate as? OutlineViewController)?.cancelPendingRename()
        let row = row(at: convert(event.locationInWindow, from: nil))
        snapshotPendingRename(row: row, clickCount: event.clickCount, modifiers: event.modifierFlags)
        super.mouseDown(with: event)
    }

    func snapshotPendingRename(row: Int, clickCount: Int, modifiers: NSEvent.ModifierFlags) {
        let renameModifiers = modifiers.intersection([.command, .shift, .option])
        pendingRenameRow =
            (row >= 0 && row == selectedRow && clickCount == 1 && renameModifiers.isEmpty)
            ? row : -1
    }

    override func mouseDragged(with event: NSEvent) {
        pendingRenameRow = -1
        (delegate as? OutlineViewController)?.cancelPendingRename()
        super.mouseDragged(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers
        let isReturn = chars == "\r" || chars == "\u{3}"
        if currentEditor() == nil, selectedRow >= 0, isReturn {
            (delegate as? OutlineViewController)?.beginEditingSelectedTitle()
            return
        }
        super.keyDown(with: event)
    }

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
                    ("Rename", #selector(MainSplitViewController.renameSelected(_:))),
                    ("Delete\u{2026}", #selector(MainSplitViewController.deleteSelected(_:))),
                ])
            case is TaskItem:
                return Self.makeMenu([
                    ("New Subtask", #selector(MainSplitViewController.newSubtask(_:))),
                    ("Rename", #selector(MainSplitViewController.renameSelected(_:))),
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
