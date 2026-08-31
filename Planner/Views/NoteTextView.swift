import AppKit

/// The notes editor. Rich text is allowed, but only the traits the product
/// supports: everything arriving by paste or drop is run through
/// `NoteFormatting.sanitized` first, so a colour or font size pasted from a
/// browser never reaches the buffer — and therefore never reaches the store.
final class NoteTextView: NSTextView {
    /// Notified when the caret moves or formatting changes, so a format bar can
    /// re-sync. Selection alone does not go through `textDidChange`.
    var onFormattingStateChange: (() -> Void)?

    // No initialisers: every one of `NSTextView`'s is inherited, so the view is
    // always built by AppKit's own path, which is what creates the TextKit 2
    // stack — and the only path that creates a stack at all. Overriding
    // `init(frame:textContainer:)` to pass a nil container left text storage,
    // container and layout all nil: the note drew nothing and swallowed every
    // click. Per-view policy such as `usesFindBar` belongs with the owner's
    // other configuration, not in an initialiser here.
    //
    // Note for future work: reading `layoutManager` anywhere on this view drops
    // it to TextKit 1 for good. `textStorage` and `textContainer`, which the
    // formatting code below uses throughout, are safe in either mode.

    // MARK: - Formatting commands

    @objc func toggleBold(_ sender: Any?) {
        toggle(trait: .bold, actionName: "Bold")
    }

    @objc func toggleItalic(_ sender: Any?) {
        toggle(trait: .italic, actionName: "Italic")
    }

    @objc func toggleUnderline(_ sender: Any?) {
        let range = selectedRange()
        let turningOn = !selectionIsUnderlined

        if range.length == 0 {
            var attributes = typingAttributes
            if turningOn {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            } else {
                attributes.removeValue(forKey: .underlineStyle)
            }
            typingAttributes = attributes
            onFormattingStateChange?()
            return
        }

        guard let storage = textStorage,
              shouldChangeText(in: range, replacementString: nil)
        else { return }
        undoManager?.setActionName("Underline")
        storage.beginEditing()
        if turningOn {
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        } else {
            storage.removeAttribute(.underlineStyle, range: range)
        }
        storage.endEditing()
        didChangeText()
        onFormattingStateChange?()
    }

    /// Empty selection flips the typing attributes so the *next* characters pick
    /// the trait up; a real selection restyles what is already there.
    private func toggle(trait: NSFontDescriptor.SymbolicTraits, actionName: String) {
        let range = selectedRange()
        let turningOn = !selectionHasTrait(trait)

        if range.length == 0 {
            var attributes = typingAttributes
            let current = (attributes[.font] as? NSFont) ?? NoteFormatting.bodyFont
            attributes[.font] = NoteFormatting.font(current, setting: trait, on: turningOn)
            typingAttributes = attributes
            onFormattingStateChange?()
            return
        }

        guard let storage = textStorage,
              shouldChangeText(in: range, replacementString: nil)
        else { return }
        undoManager?.setActionName(actionName)
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            let current = (value as? NSFont) ?? NoteFormatting.bodyFont
            storage.addAttribute(
                .font,
                value: NoteFormatting.font(current, setting: trait, on: turningOn),
                range: subrange
            )
        }
        storage.endEditing()
        didChangeText()
        onFormattingStateChange?()
    }

    // MARK: - List commands

    @objc func toggleBulletList(_ sender: Any?) {
        editList(actionName: "Bulleted List") { storage, selection in
            NoteListEditing.toggle(.bullet, in: storage, selection: selection)
        }
    }

    @objc func toggleNumberedList(_ sender: Any?) {
        editList(actionName: "Numbered List") { storage, selection in
            NoteListEditing.toggle(.numbered, in: storage, selection: selection)
        }
    }

    @objc func increaseListIndent(_ sender: Any?) {
        editList(actionName: "Increase Indent") { storage, selection in
            NoteListEditing.changeDepth(by: 1, in: storage, selection: selection)
        }
    }

    @objc func decreaseListIndent(_ sender: Any?) {
        editList(actionName: "Decrease Indent") { storage, selection in
            NoteListEditing.changeDepth(by: -1, in: storage, selection: selection)
        }
    }

    /// List edits are attribute-only — TextKit draws the markers — so the text
    /// normally never changes, ranges stay valid and the caret does not move.
    ///
    /// TextKit renders markers from **storage only**, never from typing
    /// attributes (verified by offscreen rendering: an empty final paragraph
    /// draws no marker whatever the typing attributes say). So a caret
    /// paragraph without characters — an empty note, or the caret past the
    /// trailing newline, which is exactly where Return leaves it when a list
    /// grows at the end of the note — cannot show the edit. When the edit
    /// leaves the paragraph in a list, the paragraph is materialised: it gets
    /// a newline to carry the style, caret kept in front, and the marker
    /// appears. When the edit leaves the list there is no marker to show, and
    /// typing attributes remain enough.
    private func editList(
        actionName: String,
        _ transform: (NSMutableAttributedString, NSRange) -> Void
    ) {
        guard let storage = textStorage else { return }

        if selectedRange().length == 0, caretParagraphIsCharless {
            if resultingLists(of: transform).isEmpty {
                applyToTypingAttributes(transform)
                return
            }
            guard materializeCaretParagraph() else { return }
        }

        let selection = selectedRange()
        let paragraphs = NoteListEditing.paragraphRanges(of: storage, covering: selection)
        guard let first = paragraphs.first, let last = paragraphs.last else { return }
        let affected = NSRange(location: first.location, length: NSMaxRange(last) - first.location)

        guard shouldChangeText(in: affected, replacementString: nil) else { return }
        undoManager?.setActionName(actionName)
        storage.beginEditing()
        transform(storage, selection)
        storage.endEditing()
        didChangeText()
        syncTypingParagraphStyle()
        onFormattingStateChange?()
    }

    /// True when the caret's paragraph has no characters at all: the note is
    /// empty, or the caret sits past a trailing newline.
    private var caretParagraphIsCharless: Bool {
        guard let storage = textStorage else { return false }
        if storage.length == 0 { return true }
        return selectedRange().location >= storage.length
            && (storage.string as NSString).hasSuffix("\n")
    }

    /// Runs the transform against a scratch copy of the typing attributes and
    /// reports the list stack it would leave behind.
    private func resultingLists(
        of transform: (NSMutableAttributedString, NSRange) -> Void
    ) -> [NSTextList] {
        let scratch = NSMutableAttributedString(string: " ", attributes: typingAttributes)
        transform(scratch, NSRange(location: 0, length: 1))
        let style = scratch.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        return style?.textLists ?? []
    }

    /// Gives the caret's charless paragraph a newline to carry its paragraph
    /// style, keeping the caret in front of it. This is the one place list
    /// editing writes a character — a newline, never a marker glyph — because
    /// a paragraph with no characters cannot render a marker at all.
    @discardableResult
    private func materializeCaretParagraph() -> Bool {
        let caret = selectedRange().location
        let range = NSRange(location: caret, length: 0)
        guard shouldChangeText(in: range, replacementString: "\n") else { return false }
        textStorage?.replaceCharacters(
            in: range,
            with: NSAttributedString(string: "\n", attributes: typingAttributes)
        )
        didChangeText()
        setSelectedRange(NSRange(location: caret, length: 0))
        return true
    }

    /// Runs the same transform against a one-character scratch buffer and keeps
    /// only the resulting paragraph style, so typing picks the list up.
    private func applyToTypingAttributes(_ transform: (NSMutableAttributedString, NSRange) -> Void) {
        let scratch = NSMutableAttributedString(string: " ", attributes: typingAttributes)
        transform(scratch, NSRange(location: 0, length: 1))
        var attributes = typingAttributes
        attributes[.paragraphStyle] =
            scratch.attribute(.paragraphStyle, at: 0, effectiveRange: nil) ?? NSParagraphStyle.default
        typingAttributes = attributes
        onFormattingStateChange?()
    }

    /// Keeps typing in step with the paragraph the caret ended up in.
    private func syncTypingParagraphStyle() {
        guard let storage = textStorage, storage.length > 0 else { return }
        let index = min(max(0, selectedRange().location), storage.length - 1)
        guard let style = storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) else { return }
        var attributes = typingAttributes
        attributes[.paragraphStyle] = style
        typingAttributes = attributes
    }

    /// Paragraph containing the insertion point, zero-length when the caret sits
    /// on a blank line or past the final newline.
    private func insertionParagraph() -> NSRange {
        guard let storage = textStorage, storage.length > 0 else {
            return NSRange(location: 0, length: 0)
        }
        let text = storage.string as NSString
        let location = selectedRange().location
        if location >= text.length {
            return text.hasSuffix("\n")
                ? NSRange(location: location, length: 0)
                : text.paragraphRange(for: NSRange(location: text.length - 1, length: 0))
        }
        let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
        return NoteListEditing.contentRange(inParagraph: paragraph, of: storage).length == 0
            ? NSRange(location: paragraph.location, length: 0)
            : paragraph
    }

    /// The list kind at the caret, if any — drives the format bar and menu ticks.
    var selectionListKind: NoteListKind? {
        guard let innermost = effectiveLists.last else { return nil }
        return NoteListKind.kind(of: innermost)
    }

    /// The list stack in force: the storage under a real selection, otherwise
    /// the typing attributes, which is where an empty line's list lives.
    private var effectiveLists: [NSTextList] {
        let selection = selectedRange()
        if selection.length > 0, let storage = textStorage, storage.length > 0 {
            return NoteListEditing.lists(inParagraphAt: selection.location, of: storage)
        }
        return (typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.textLists ?? []
    }

    private var caretParagraph: NSRange? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let text = storage.string as NSString
        let location = min(selectedRange().location, text.length - 1)
        return text.paragraphRange(for: NSRange(location: location, length: 0))
    }

    private var isInList: Bool { !effectiveLists.isEmpty }

    // MARK: - Key handling inside lists

    /// Tab only means "indent" inside a list; elsewhere it keeps its usual job.
    override func insertTab(_ sender: Any?) {
        guard isInList, selectedRange().length == 0 else {
            super.insertTab(sender)
            return
        }
        increaseListIndent(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        guard isInList else {
            super.insertBacktab(sender)
            return
        }
        decreaseListIndent(sender)
    }

    /// Return on an empty item outdents instead of adding another empty one, and
    /// leaves the list altogether at level 1. Otherwise the new paragraph simply
    /// inherits the list style, and TextKit numbers it. A real selection always
    /// takes the normal path: Return must replace it, not outdent.
    override func insertNewline(_ sender: Any?) {
        guard isInList,
              selectedRange().length == 0,
              let storage = textStorage,
              let paragraph = caretParagraph
        else {
            super.insertNewline(sender)
            return
        }

        if insertionParagraph().length == 0
            || NoteListEditing.isEmptyListItem(paragraph: paragraph, in: storage) {
            decreaseListIndent(sender)
            return
        }
        super.insertNewline(sender)
        // Return at the end of the note leaves the caret on a charless
        // paragraph, which cannot render its marker; give the new item its
        // newline now so the bullet shows before anything is typed.
        if isInList, caretParagraphIsCharless {
            materializeCaretParagraph()
        }
        onFormattingStateChange?()
    }

    /// Backspace at the very start of an item outdents rather than merging it
    /// into the item above.
    override func deleteBackward(_ sender: Any?) {
        guard isInList,
              selectedRange().length == 0,
              let paragraph = caretParagraph,
              selectedRange().location == paragraph.location
        else {
            super.deleteBackward(sender)
            return
        }
        decreaseListIndent(sender)
    }

    // MARK: - Formatting state

    /// True only when the **whole** selection carries the trait, so a mixed
    /// selection reads as off and the first press turns it on throughout.
    func selectionHasTrait(_ trait: NSFontDescriptor.SymbolicTraits) -> Bool {
        let range = selectedRange()
        guard range.length > 0 else {
            return NoteFormatting.hasTrait(trait, typingAttributes[.font] as? NSFont)
        }
        guard let storage = textStorage else { return false }
        var uniform = true
        storage.enumerateAttribute(.font, in: range, options: []) { value, _, stop in
            if !NoteFormatting.hasTrait(trait, value as? NSFont) {
                uniform = false
                stop.pointee = true
            }
        }
        return uniform
    }

    var selectionIsUnderlined: Bool {
        let range = selectedRange()
        guard range.length > 0 else {
            return (typingAttributes[.underlineStyle] as? Int ?? 0) != 0
        }
        guard let storage = textStorage else { return false }
        var uniform = true
        storage.enumerateAttribute(.underlineStyle, in: range, options: []) { value, _, stop in
            if (value as? Int ?? 0) == 0 {
                uniform = false
                stop.pointee = true
            }
        }
        return uniform
    }

    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        onFormattingStateChange?()
    }

    // MARK: - Validation

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(toggleBold(_:)), #selector(toggleItalic(_:)), #selector(toggleUnderline(_:)),
             #selector(toggleBulletList(_:)), #selector(toggleNumberedList(_:)):
            if let menuItem = item as? NSMenuItem {
                menuItem.state = state(for: menuItem.action) ? .on : .off
            }
            return isEditable
        case #selector(increaseListIndent(_:)), #selector(decreaseListIndent(_:)):
            return isEditable && isInList
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    private func state(for action: Selector?) -> Bool {
        switch action {
        case #selector(toggleBold(_:)): return selectionHasTrait(.bold)
        case #selector(toggleItalic(_:)): return selectionHasTrait(.italic)
        case #selector(toggleUnderline(_:)): return selectionIsUnderlined
        case #selector(toggleBulletList(_:)): return selectionListKind == .bullet
        case #selector(toggleNumberedList(_:)): return selectionListKind == .numbered
        default: return false
        }
    }

    // MARK: - Pasting

    /// The flavors this view will read, in preference order. Restricting the
    /// list — rather than intercepting each rich type one by one — closes the
    /// drop path: AppKit picks the flavor *before* `readSelection` runs, so a
    /// WebArchive or RTFD drop would otherwise arrive as a type the sanitiser
    /// never sees and go in raw.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.rtf, .html, .string]
    }

    override func paste(_ sender: Any?) {
        // No super fallback: whatever cannot be decoded here stays out, which
        // is the invariant this class exists for.
        guard let incoming = incomingContent(from: .general) else { return }
        insertSanitized(incoming)
    }

    /// Paste and Match Style already discards everything; route it normally.
    override func pasteAsPlainText(_ sender: Any?) {
        super.pasteAsPlainText(sender)
    }

    /// Decodes the richest supported flavor. RTF first so bold/italic survive
    /// a copy from another note; then HTML, which is the only rich flavor
    /// browsers actually put on the pasteboard — most provide no RTF at all,
    /// so without this a paste from Safari silently lost its formatting.
    private func incomingContent(from pasteboard: NSPasteboard) -> NSAttributedString? {
        if let data = pasteboard.data(forType: .rtf),
           let rich = NSAttributedString(rtf: data, documentAttributes: nil) {
            return rich
        }
        if let data = pasteboard.data(forType: .html),
           let rich = try? NSAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.html],
               documentAttributes: nil
           ) {
            return rich
        }
        if let plain = pasteboard.string(forType: .string) {
            return NSAttributedString(
                string: plain,
                attributes: NoteFormatting.typingAttributes
            )
        }
        return nil
    }

    private func insertSanitized(_ incoming: NSAttributedString) {
        let sanitized = NoteFormatting.sanitized(incoming)
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: sanitized.string) else { return }
        textStorage?.replaceCharacters(in: range, with: sanitized)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + sanitized.length, length: 0))
    }

    /// Drag-and-drop is the other way foreign attributes get in. A board whose
    /// content cannot be decoded is refused outright rather than handed to
    /// `super`, which would insert it unsanitised.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let incoming = incomingContent(from: pboard) else { return false }
        insertSanitized(incoming)
        return true
    }
}
