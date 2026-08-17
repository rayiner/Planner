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
}
