import AppKit

final class TitleTextField: NSTextField {
    var allowsFirstResponder = false

    override var acceptsFirstResponder: Bool {
        allowsFirstResponder && super.acceptsFirstResponder
    }
}
