import AppKit

final class MailSearchField: NSSearchField {
    let searchEditor = MailSearchFieldEditor(frame: .zero, textContainer: nil)
}

final class MailSearchFieldEditor: NSTextView {
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        // Without this, Return inserts a newline instead of firing the control action.
        isFieldEditor = true
        isRichText = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func performFindPanelAction(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? Int(NSFindPanelAction.showFindPanel.rawValue)
        guard tag == Int(NSFindPanelAction.showFindPanel.rawValue) else { return }
        selectAll(sender)
    }

    /// Menu items target First Responder; NSTextView would enable Next / Previous / Use Selection.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(performFindPanelAction(_:)) {
            return item.tag == Int(NSFindPanelAction.showFindPanel.rawValue)
        }
        return super.validateUserInterfaceItem(item)
    }
}
