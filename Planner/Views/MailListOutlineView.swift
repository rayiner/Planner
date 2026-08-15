import AppKit

/// The message list's outline view.
///
/// It exists for one thing: a context menu that offers what the row under the
/// cursor can actually have done to it. Recent Mail's rows can be saved; a
/// folder's rows can be moved or removed; a conversation heading is a heading.
final class MailListOutlineView: NSOutlineView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        return menu(forRow: row(at: location))
    }

    func menu(forRow row: Int) -> NSMenu? {
        guard row >= 0 else { return nil }
        // Right-clicking a row acts on that row, so it takes the selection
        // first — the commands all read the selection, and acting on something
        // other than what was clicked is the classic context-menu bug.
        if item(atRow: row) is MailListRow || item(atRow: row) is SavedMessageRow {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            window?.makeFirstResponder(self)
        }

        switch item(atRow: row) {
        case is MailListRow:
            return Self.makeMenu([
                ("Save to Folder\u{2026}", #selector(MainSplitViewController.saveMessageToFolder(_:))),
                ("New Task from Message", #selector(MainSplitViewController.newTaskFromMessage(_:))),
                ("Open in Outlook", #selector(MainSplitViewController.openMessageInOutlook(_:))),
            ])
        case is SavedMessageRow:
            return Self.makeMenu([
                ("Move to Folder\u{2026}", #selector(MainSplitViewController.moveMessageToFolder(_:))),
                ("New Task from Message", #selector(MainSplitViewController.newTaskFromMessage(_:))),
                ("Open in Outlook", #selector(MainSplitViewController.openMessageInOutlook(_:))),
                ("Remove\u{2026}", #selector(MainSplitViewController.removeSavedMessage(_:))),
            ])
        default:
            // A date header or a conversation heading: nothing to act on.
            return nil
        }
    }

    private static func makeMenu(_ items: [(String, Selector)]) -> NSMenu {
        let menu = NSMenu()
        for (title, action) in items {
            menu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: ""))
        }
        return menu
    }
}
