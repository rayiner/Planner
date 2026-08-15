import AppKit

/// The mailbox sidebar's outline view.
///
/// Carries the same three gestures `PlannerOutlineView` does — cancel a pending
/// rename on any mouse-down, Return to rename the selection, a context menu
/// that first selects the row under the cursor — against a different delegate
/// and a different command set. Separate rather than shared because the two
/// views agree on gestures and on nothing else: this one has no expansion, no
/// completion toggle, and one non-renamable row.
final class MailboxOutlineView: NSOutlineView {
    var pendingRenameRow: Int = -1
    var mouseDownLocationInView: NSPoint?

    private var controller: MailboxListViewController? {
        delegate as? MailboxListViewController
    }

    override func mouseDown(with event: NSEvent) {
        controller?.cancelPendingRename()
        let location = convert(event.locationInWindow, from: nil)
        mouseDownLocationInView = location
        let row = row(at: location)
        snapshotPendingRename(row: row, clickCount: event.clickCount, modifiers: event.modifierFlags)
        super.mouseDown(with: event)
    }

    func snapshotPendingRename(row: Int, clickCount: Int, modifiers: NSEvent.ModifierFlags) {
        let renameModifiers = modifiers.intersection([.command, .shift, .option])
        pendingRenameRow =
            (row >= 0 && row == selectedRow && clickCount == 1 && renameModifiers.isEmpty)
            ? row : -1
    }

    func hasDraggedPastThreshold(to locationInView: NSPoint) -> Bool {
        guard let start = mouseDownLocationInView else { return false }
        return hypot(locationInView.x - start.x, locationInView.y - start.y)
            >= PlannerOutlineView.dragThreshold
    }

    override func mouseDragged(with event: NSEvent) {
        cancelPendingRenameGesture()
        super.mouseDragged(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers
        let isReturn = chars == "\r" || chars == "\u{3}"
        if currentEditor() == nil, selectedRow >= 0, isReturn {
            controller?.beginEditingSelectedName()
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        cancelPendingRenameGesture()
        let location = convert(event.locationInWindow, from: nil)
        return menu(forRow: row(at: location))
    }

    func menu(forRow row: Int) -> NSMenu {
        cancelPendingRenameGesture()
        if row >= 0 {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            window?.makeFirstResponder(self)
            if item(atRow: row) is MailFolder {
                return Self.makeMenu([
                    ("New Folder", #selector(MainSplitViewController.newMailFolder(_:))),
                    ("Rename", #selector(MainSplitViewController.renameSelected(_:))),
                    ("Delete\u{2026}", #selector(MainSplitViewController.deleteSelected(_:))),
                ])
            }
        }
        // Recent Mail and the empty area below the list both offer the one
        // thing that always applies.
        return Self.makeMenu([
            ("New Folder", #selector(MainSplitViewController.newMailFolder(_:))),
        ])
    }

    func cancelPendingRenameGesture() {
        pendingRenameRow = -1
        controller?.cancelPendingRename()
    }

    private static func makeMenu(_ items: [(String, Selector)]) -> NSMenu {
        let menu = NSMenu()
        for (title, action) in items {
            menu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: ""))
        }
        return menu
    }
}
