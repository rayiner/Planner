import AppKit

/// The message list's outline view.
///
/// It exists for two things: a message context menu and the ⌫ shortcut for the
/// selected mailbox's Hide/Unhide command.
final class MailListOutlineView: NSOutlineView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        return menu(forRow: row(at: location))
    }

    /// Bare ⌫ over a selected message runs the trash's command.
    ///
    /// The menu's Delete is ⌘⌫ and reads as the *sidebar's* delete — it is what
    /// removes a folder. In a list of messages the unmodified key is the
    /// gesture every mail client has trained into the hand, and it has to be
    /// the list's own, because a key equivalent on the menu item would apply
    /// everywhere the menu does. Routed through the responder chain rather than
    /// called directly so it lands on the same command, with the same guards,
    /// that the toolbar button and the context menu use.
    override func keyDown(with event: NSEvent) {
        let isDelete = event.charactersIgnoringModifiers == "\u{8}"
            || event.charactersIgnoringModifiers == "\u{7F}"
        let isBare = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .isDisjoint(with: [.command, .option, .control, .shift])
        if isDelete, isBare, !selectedRowIndexes.isEmpty, sendToResponderChain(Self.hideSelector) {
            return
        }
        // Escape clears an active folder search; an empty query falls through.
        let isEscape = event.keyCode == 53 || event.charactersIgnoringModifiers == "\u{1b}"
        if isEscape, isBare, sendClearSearchIfActive() {
            return
        }
        super.keyDown(with: event)
    }

    private static let hideSelector = #selector(MainSplitViewController.toggleHiddenForSelectedMessage(_:))

    /// Walks up from this view rather than going through `NSApp.sendAction`,
    /// which starts at the *key* window's first responder — true when a person
    /// presses the key, not when a test synthesises one.
    private func sendToResponderChain(_ selector: Selector) -> Bool {
        var responder: NSResponder? = self
        while let current = responder {
            if current !== self, current.responds(to: selector) {
                current.perform(selector, with: self)
                return true
            }
            responder = current.nextResponder
        }
        return false
    }

    /// Same walk as Delete, but typed so an empty query can fall through to `super`.
    private func sendClearSearchIfActive() -> Bool {
        var responder: NSResponder? = self
        while let current = responder {
            if let list = current as? MailListViewController {
                return list.clearSearchFromOutline()
            }
            responder = current.nextResponder
        }
        return false
    }

    override func selectAll(_ sender: Any?) {
        var indexes = IndexSet()
        for row in 0..<numberOfRows {
            if item(atRow: row) is MailListRow {
                indexes.insert(row)
            }
        }
        selectRowIndexes(indexes, byExtendingSelection: false)
    }

    func menu(forRow row: Int) -> NSMenu? {
        guard row >= 0 else { return nil }
        // Right-clicking a row acts on that row. If it is already part of a
        // multi-selection, keep the selection; otherwise select only the click.
        if item(atRow: row) is MailListRow {
            if !selectedRowIndexes.contains(row) {
                selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            window?.makeFirstResponder(self)
        }

        switch item(atRow: row) {
        case is MailListRow:
            let count = selectedRowIndexes.count
            let hideTitle: String = {
                let selected = listController?.selection.messages.compactMap { item -> MailMessage? in
                    guard case let .recent(id) = item else { return nil }
                    return listController?.mail.message(id: id)
                } ?? []
                let unhide = !selected.isEmpty && selected.allSatisfy(\.isHidden)
                return unhide
                    ? MailLabels.unhideActionTitle(count: count)
                    : MailLabels.hideActionTitle(count: count)
            }()
            return Self.makeMenu([
                ("Open in Outlook", #selector(MainSplitViewController.openMessageInOutlook(_:))),
                (hideTitle, #selector(MainSplitViewController.toggleHiddenForSelectedMessage(_:))),
            ])
        default:
            // A date header has nothing to act on.
            return nil
        }
    }

    private var listController: MailListViewController? {
        var responder: NSResponder? = self
        while let current = responder {
            if let list = current as? MailListViewController { return list }
            responder = current.nextResponder
        }
        return nil
    }

    private static func makeMenu(_ items: [(String, Selector)]) -> NSMenu {
        let menu = NSMenu()
        for (title, action) in items {
            menu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: ""))
        }
        return menu
    }
}
