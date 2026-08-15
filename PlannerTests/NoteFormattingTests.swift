import AppKit
import XCTest
@testable import Planner

@MainActor
final class NoteFormattingTests: XCTestCase {
    // MARK: - Sanitising

    func testSanitiserKeepsBoldAndItalicButForcesTheAppFont() {
        let foreign = NSFont(descriptor:
            NSFont.systemFont(ofSize: 24).fontDescriptor.withSymbolicTraits([.bold, .italic]),
            size: 24
        )!
        let input = NSAttributedString(string: "loud", attributes: [.font: foreign])

        let output = NoteFormatting.sanitized(input)
        let font = try! XCTUnwrap(output.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)

        XCTAssertEqual(font.pointSize, NoteFormatting.bodyFontSize, "pasted size must not survive")
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.italic))
    }

    func testSanitiserStripsColourAndOtherDecoration() {
        let input = NSAttributedString(string: "shouty", attributes: [
            .font: NSFont.systemFont(ofSize: 18),
            .foregroundColor: NSColor.systemPink,
            .backgroundColor: NSColor.systemYellow,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .kern: 4,
        ])

        let output = NoteFormatting.sanitized(input)
        let attributes = output.attributes(at: 0, effectiveRange: nil)

        XCTAssertEqual(attributes[.foregroundColor] as? NSColor, .labelColor)
        XCTAssertNil(attributes[.backgroundColor])
        XCTAssertNil(attributes[.strikethroughStyle])
        XCTAssertNil(attributes[.kern])
        XCTAssertEqual(output.string, "shouty", "text itself is untouched")
    }

    /// A planner note is where ticket and meeting URLs land, so `.link`
    /// survives — the decoration around it still doesn't.
    func testSanitiserKeepsHyperlinks() {
        let url = URL(string: "https://example.com/ticket/42")!
        let input = NSAttributedString(string: "ticket", attributes: [
            .font: NSFont.systemFont(ofSize: 18),
            .foregroundColor: NSColor.systemBlue,
            .link: url,
        ])

        let output = NoteFormatting.sanitized(input)
        let attributes = output.attributes(at: 0, effectiveRange: nil)

        XCTAssertEqual(attributes[.link] as? URL, url)
        XCTAssertEqual(attributes[.foregroundColor] as? NSColor, .labelColor)
    }

    /// HTML decoding hands over string-valued links; the store gets URLs only.
    func testSanitiserNormalisesStringLinksToURLs() {
        let input = NSAttributedString(string: "site", attributes: [.link: "https://example.com"])

        let output = NoteFormatting.sanitized(input)

        XCTAssertEqual(
            output.attribute(.link, at: 0, effectiveRange: nil) as? URL,
            URL(string: "https://example.com")
        )
    }

    /// The attachment attribute is dropped by the whitelist, but its U+FFFC
    /// placeholder character would survive as an invisible box.
    func testSanitiserDropsAttachmentPlaceholderCharacters() {
        let input = NSAttributedString(string: "before \u{fffc} after")

        let output = NoteFormatting.sanitized(input)

        XCTAssertEqual(output.string, "before  after")
    }

    func testSanitiserKeepsUnderlineAsASingleRule() {
        let input = NSAttributedString(string: "note", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .underlineStyle: NSUnderlineStyle.double.rawValue,
        ])

        let output = NoteFormatting.sanitized(input)

        XCTAssertEqual(
            output.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue
        )
    }

    func testSanitiserRecomputesListIndentsFromDepthAndCapsNesting() {
        let style = NSMutableParagraphStyle()
        style.textLists = (0..<8).map { _ in NSTextList(markerFormat: .disc, options: 0) }
        style.firstLineHeadIndent = 999      // nonsense values from elsewhere
        style.headIndent = 999
        style.alignment = .right
        let input = NSAttributedString(string: "item", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .paragraphStyle: style,
        ])

        let output = NoteFormatting.sanitized(input)
        let result = try! XCTUnwrap(
            output.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )

        XCTAssertEqual(result.textLists.count, NoteFormatting.maximumListDepth, "nesting is capped")
        XCTAssertEqual(
            result.headIndent,
            CGFloat(NoteFormatting.maximumListDepth) * NoteFormatting.indentPerLevel,
            "indent is derived from depth, never trusted"
        )
        XCTAssertEqual(result.alignment, NSParagraphStyle.default.alignment, "alignment is not a feature")
    }

    func testSanitiserLeavesNonListParagraphsUnindented() {
        let input = NSAttributedString(string: "plain", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
        ])
        let output = NoteFormatting.sanitized(input)
        let style = output.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.headIndent ?? 0, 0)
        XCTAssertTrue(style?.textLists.isEmpty ?? true)
    }

    // MARK: - Store round-trip

    func testRTFRoundTripPreservesTraits() throws {
        let bold = NSFont(descriptor:
            NoteFormatting.bodyFont.fontDescriptor.withSymbolicTraits(.bold),
            size: NoteFormatting.bodyFontSize
        )!
        let source = NSMutableAttributedString(
            string: "plain and bold",
            attributes: NoteFormatting.typingAttributes
        )
        source.addAttribute(.font, value: bold, range: NSRange(location: 10, length: 4))

        let data = try XCTUnwrap(NoteFormatting.rtf(from: source))
        let restored = NoteFormatting.attributedString(rtf: data, plain: "plain and bold")

        XCTAssertEqual(restored.string, "plain and bold")
        let plainFont = restored.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let boldFont = restored.attribute(.font, at: 10, effectiveRange: nil) as? NSFont
        XCTAssertFalse(plainFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? true)
        XCTAssertTrue(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
    }

    func testEmptyNoteProducesNilInBothColumns() {
        let empty = NSAttributedString(string: "")
        XCTAssertNil(NoteFormatting.rtf(from: empty))
        XCTAssertNil(NoteFormatting.plainText(from: empty))
    }

    func testPlainRowWithoutRTFLoadsAsPlainText() {
        // A note written before rich text existed: `note` set, `noteRTF` nil.
        let restored = NoteFormatting.attributedString(rtf: nil, plain: "legacy note")

        XCTAssertEqual(restored.string, "legacy note")
        XCTAssertEqual(
            restored.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
            NoteFormatting.bodyFont
        )
    }

    func testCorruptRTFFallsBackToThePlainShadow() {
        let restored = NoteFormatting.attributedString(
            rtf: Data("this is not rtf".utf8),
            plain: "shadow wins"
        )
        XCTAssertEqual(restored.string, "shadow wins")
    }
}

@MainActor
final class NoteTextViewFormattingTests: XCTestCase {
    func testTogglingBoldOnASelectionAffectsOnlyThatRange() {
        let view = makeView("hello world")
        view.setSelectedRange(NSRange(location: 0, length: 5))

        view.toggleBold(nil)

        XCTAssertTrue(isBold(view, at: 0))
        XCTAssertFalse(isBold(view, at: 6), "the unselected half is untouched")
        XCTAssertTrue(view.selectionHasTrait(.bold))
    }

    func testTogglingTwiceReturnsToPlain() {
        let view = makeView("hello")
        view.setSelectedRange(NSRange(location: 0, length: 5))

        view.toggleBold(nil)
        view.toggleBold(nil)

        XCTAssertFalse(isBold(view, at: 0))
        XCTAssertEqual(
            view.attributedString().attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
            NoteFormatting.bodyFont
        )
    }

    func testBoldAndItalicCompose() {
        let view = makeView("both")
        view.setSelectedRange(NSRange(location: 0, length: 4))

        view.toggleBold(nil)
        view.toggleItalic(nil)

        XCTAssertTrue(view.selectionHasTrait(.bold))
        XCTAssertTrue(view.selectionHasTrait(.italic))
        // And the size never moves, whatever the traits.
        let font = view.attributedString().attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, NoteFormatting.bodyFontSize)
    }

    func testMixedSelectionReadsAsOffAndOnePressMakesItUniform() {
        let view = makeView("hello world")
        view.setSelectedRange(NSRange(location: 0, length: 5))
        view.toggleBold(nil)

        // Half bold, half not.
        view.setSelectedRange(NSRange(location: 0, length: 11))
        XCTAssertFalse(view.selectionHasTrait(.bold), "a mixed selection is not 'on'")

        view.toggleBold(nil)
        XCTAssertTrue(view.selectionHasTrait(.bold), "one press makes the whole run bold")
        XCTAssertTrue(isBold(view, at: 10))
    }

    func testTogglingWithAnEmptySelectionSetsTypingAttributes() {
        let view = makeView("")
        view.setSelectedRange(NSRange(location: 0, length: 0))

        view.toggleBold(nil)

        XCTAssertTrue(NoteFormatting.hasTrait(.bold, view.typingAttributes[.font] as? NSFont))
        XCTAssertTrue(view.selectionHasTrait(.bold), "state reads from typing attributes")
    }

    func testUnderlineTogglesOnAndOff() {
        let view = makeView("underline me")
        view.setSelectedRange(NSRange(location: 0, length: 12))

        view.toggleUnderline(nil)
        XCTAssertTrue(view.selectionIsUnderlined)

        view.toggleUnderline(nil)
        XCTAssertFalse(view.selectionIsUnderlined)
        XCTAssertNil(view.attributedString().attribute(.underlineStyle, at: 0, effectiveRange: nil))
    }

    func testFormattingCommandsAreDisabledWhenTheNoteIsNotEditable() {
        let view = makeView("text")
        view.isEditable = false

        let item = NSMenuItem(title: "Bold", action: #selector(NoteTextView.toggleBold(_:)), keyEquivalent: "")
        XCTAssertFalse(view.validateUserInterfaceItem(item))

        view.isEditable = true
        XCTAssertTrue(view.validateUserInterfaceItem(item))
    }

    func testMenuValidationReflectsSelectionState() {
        let view = makeView("hello")
        view.setSelectedRange(NSRange(location: 0, length: 5))
        let item = NSMenuItem(title: "Bold", action: #selector(NoteTextView.toggleBold(_:)), keyEquivalent: "")

        _ = view.validateUserInterfaceItem(item)
        XCTAssertEqual(item.state, .off)

        view.toggleBold(nil)
        _ = view.validateUserInterfaceItem(item)
        XCTAssertEqual(item.state, .on, "the menu shows a tick for a bold selection")
    }

    func testFormattingSurvivesTheStoreRoundTrip() throws {
        let view = makeView("bold tail")
        view.setSelectedRange(NSRange(location: 0, length: 4))
        view.toggleBold(nil)
        view.setSelectedRange(NSRange(location: 5, length: 4))
        view.toggleUnderline(nil)

        let data = try XCTUnwrap(NoteFormatting.rtf(from: view.attributedString()))
        let restored = NoteFormatting.attributedString(rtf: data, plain: "bold tail")

        XCTAssertTrue(NoteFormatting.hasTrait(.bold, restored.attribute(.font, at: 0, effectiveRange: nil) as? NSFont))
        XCTAssertFalse(NoteFormatting.hasTrait(.bold, restored.attribute(.font, at: 6, effectiveRange: nil) as? NSFont))
        XCTAssertNotNil(restored.attribute(.underlineStyle, at: 6, effectiveRange: nil))
    }

    // MARK: - Paste and drop intake

    /// AppKit picks the pasteboard flavor before `readSelection` runs, so the
    /// sanitiser can only be airtight if the view refuses to read flavors it
    /// cannot decode (WebArchive, RTFD, …) in the first place.
    func testReadableTypesAreRestrictedToSanitisableFlavors() {
        let view = makeView("")
        XCTAssertEqual(view.readablePasteboardTypes, [.rtf, .html, .string])
    }

    /// Browsers put HTML, not RTF, on the pasteboard — decoding it is what
    /// lets a copied page keep bold while the colour and size still die.
    func testDroppedHTMLIsDecodedAndSanitised() throws {
        let view = makeView("")
        let html = #"<b style="color: red; font-size: 24px">bold</b> plain"#
        let pboard = makePasteboard()
        pboard.declareTypes([.html], owner: nil)
        pboard.setData(Data(html.utf8), forType: .html)

        XCTAssertTrue(view.readSelection(from: pboard, type: .html))

        let text = view.attributedString()
        XCTAssertTrue(text.string.hasPrefix("bold plain"))
        let font = try XCTUnwrap(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(font.pointSize, NoteFormatting.bodyFontSize, "pasted size must not survive")
        XCTAssertEqual(
            text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
            .labelColor
        )
    }

    func testDroppedRTFIsSanitised() throws {
        let view = makeView("")
        let foreign = NSFont(descriptor:
            NSFont.systemFont(ofSize: 24).fontDescriptor.withSymbolicTraits(.bold),
            size: 24
        )!
        let rich = NSAttributedString(string: "loud", attributes: [
            .font: foreign,
            .foregroundColor: NSColor.systemPink,
        ])
        let data = try XCTUnwrap(rich.rtf(
            from: NSRange(location: 0, length: rich.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ))
        let pboard = makePasteboard()
        pboard.declareTypes([.rtf], owner: nil)
        pboard.setData(data, forType: .rtf)

        XCTAssertTrue(view.readSelection(from: pboard, type: .rtf))

        let font = try XCTUnwrap(
            view.attributedString().attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        )
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(font.pointSize, NoteFormatting.bodyFontSize)
        XCTAssertEqual(
            view.attributedString().attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
            .labelColor
        )
    }

    /// Undecodable content is refused, never handed to `super` to insert raw.
    func testAnUndecodableDropIsRefusedRatherThanInsertedRaw() {
        let view = makeView("")
        let pboard = makePasteboard()
        pboard.declareTypes([.tiff], owner: nil)
        pboard.setData(Data([0x00]), forType: .tiff)

        XCTAssertFalse(view.readSelection(from: pboard, type: .tiff))
        XCTAssertEqual(view.string, "")
    }

    // MARK: - List visibility

    // TextKit renders list markers from storage only — never from typing
    // attributes — so every list edit must land in storage to be visible.
    // A paragraph with no characters is materialised: it gets a newline to
    // carry the style, with the caret kept in front of it.

    func testTogglingAListOnAnEmptyNoteShowsAMarkerImmediately() {
        let view = makeView("")

        view.toggleBulletList(nil)

        XCTAssertEqual(view.string, "\n", "the paragraph needs a character to render its marker")
        XCTAssertEqual(NoteListEditing.lists(inParagraphAt: 0, of: view.attributedString()).count, 1)
        XCTAssertEqual(view.selectedRange().location, 0, "the caret stays on the marker line")
    }

    func testTogglingAListPastTheTrailingNewlineMaterialisesOnlyTheLastParagraph() {
        let view = makeView("item\n")
        view.setSelectedRange(NSRange(location: 5, length: 0))

        view.toggleBulletList(nil)

        XCTAssertEqual(view.string, "item\n\n")
        XCTAssertEqual(NoteListEditing.lists(inParagraphAt: 5, of: view.attributedString()).count, 1)
        XCTAssertTrue(NoteListEditing.lists(inParagraphAt: 0, of: view.attributedString()).isEmpty,
                      "the paragraph above is untouched")
        XCTAssertEqual(view.selectedRange().location, 5)
    }

    /// A blank line that owns a newline carries the style on that newline —
    /// no materialisation needed, and the marker renders in place.
    func testTogglingAListOnABlankLineAppliesToItsNewline() {
        let view = makeView("a\n\nb")
        view.setSelectedRange(NSRange(location: 2, length: 0))

        view.toggleBulletList(nil)

        XCTAssertEqual(view.string, "a\n\nb", "no characters are added")
        XCTAssertEqual(NoteListEditing.lists(inParagraphAt: 2, of: view.attributedString()).count, 1)
        XCTAssertTrue(NoteListEditing.lists(inParagraphAt: 0, of: view.attributedString()).isEmpty)
        XCTAssertTrue(NoteListEditing.lists(inParagraphAt: 3, of: view.attributedString()).isEmpty)
    }

    /// The reported defect: Return then Tab at the end of a note — the new
    /// item and its indentation were invisible until another character.
    func testReturnInAListMaterialisesTheNewItemAndTabIndentsItInStorage() {
        let view = makeView("item")
        view.setSelectedRange(NSRange(location: 4, length: 0))
        view.toggleBulletList(nil)

        view.insertNewline(nil)

        XCTAssertEqual(view.string, "item\n\n", "the new item owns a newline so its marker renders")
        XCTAssertEqual(view.selectedRange().location, 5)
        XCTAssertEqual(NoteListEditing.lists(inParagraphAt: 5, of: view.attributedString()).count, 1)

        view.increaseListIndent(nil)

        XCTAssertEqual(NoteListEditing.lists(inParagraphAt: 5, of: view.attributedString()).count, 2)
        XCTAssertEqual(NoteListEditing.lists(inParagraphAt: 0, of: view.attributedString()).count, 1,
                       "the first item keeps its depth")
    }

    /// Return on an empty last item exits the list in storage, so the marker
    /// visibly disappears rather than lingering until the next keystroke.
    func testReturnOnAnEmptyLastItemOutdentsInStorage() {
        let view = makeView("item")
        view.setSelectedRange(NSRange(location: 4, length: 0))
        view.toggleBulletList(nil)
        view.insertNewline(nil)

        view.insertNewline(nil)

        XCTAssertEqual(view.string, "item\n\n", "outdenting is attribute-only")
        XCTAssertTrue(NoteListEditing.lists(inParagraphAt: 5, of: view.attributedString()).isEmpty)
    }

    /// Toggling back off strips the list from the materialised paragraph in
    /// storage — the marker disappears, and the text does not grow again.
    func testTogglingOffOnTheMaterialisedLineStripsWithoutGrowingTheText() {
        let view = makeView("")
        view.toggleBulletList(nil)
        XCTAssertEqual(view.string, "\n")

        view.toggleBulletList(nil)

        XCTAssertEqual(view.string, "\n", "exiting a list must not grow the text")
        XCTAssertTrue(NoteListEditing.lists(inParagraphAt: 0, of: view.attributedString()).isEmpty)
    }

    // MARK: - Key handling

    /// The empty-item outdent must not swallow Return when there is a real
    /// selection: Return replaces the selection, like everywhere else.
    func testReturnWithASelectionStartingOnAnEmptyListItemReplacesTheSelection() {
        let view = makeView("\nsecond")
        view.setSelectedRange(NSRange(location: 0, length: 7))
        view.toggleBulletList(nil)
        view.setSelectedRange(NSRange(location: 0, length: 4))

        view.insertNewline(nil)

        XCTAssertEqual(view.string, "\nond", "Return must replace the selection, not outdent")
    }

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("planner-tests-\(UUID().uuidString)"))
    }

    private func makeView(_ string: String) -> NoteTextView {
        let view = NoteTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.isEditable = true
        view.isRichText = true
        view.typingAttributes = NoteFormatting.typingAttributes
        view.textStorage?.setAttributedString(
            NSAttributedString(string: string, attributes: NoteFormatting.typingAttributes)
        )
        return view
    }

    private func isBold(_ view: NoteTextView, at index: Int) -> Bool {
        NoteFormatting.hasTrait(.bold, view.attributedString().attribute(.font, at: index, effectiveRange: nil) as? NSFont)
    }
}

@MainActor
final class RichNoteStorageTests: PersistenceTestCase {
    func testTaskNoteWritesBothColumnsTogether() throws {
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        let attributed = boldedFirstWord("bold tail")

        try model.setNote(task, attributed)

        XCTAssertEqual(task.note, "bold tail", "plain shadow tracks the attributed text")
        XCTAssertNotNil(task.noteRTF)
        let reloaded = model.noteText(of: task)
        XCTAssertTrue(isBold(reloaded, at: 0))
        XCTAssertFalse(isBold(reloaded, at: 6))
    }

    func testClearingATaskNoteNilsBothColumns() throws {
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        try model.setNote(task, boldedFirstWord("something"))
        XCTAssertNotNil(task.noteRTF)

        try model.setNote(task, NSAttributedString(string: ""))

        XCTAssertNil(task.note)
        XCTAssertNil(task.noteRTF)
    }

    func testPlainStringAPIStillWorksAndLeavesNoTraits() throws {
        let project = try model.createProject()
        let task = try model.createTask(in: project)

        try model.setNote(task, "just words")

        XCTAssertEqual(task.note, "just words")
        XCTAssertFalse(isBold(model.noteText(of: task), at: 0))
    }

    func testDayNoteWritesBothColumnsAndDeletesWhenCleared() throws {
        let day = Calendar.current.startOfDay(for: Date())

        try model.setDayNote(boldedFirstWord("bold day"), on: day)
        let stored = try XCTUnwrap(model.dayNote(for: day))
        XCTAssertEqual(stored.note, "bold day")
        XCTAssertNotNil(stored.noteRTF)
        XCTAssertTrue(isBold(model.dayNoteText(for: day), at: 0))

        try model.setDayNote(NSAttributedString(string: ""), on: day)
        XCTAssertNil(model.dayNote(for: day), "an emptied day note deletes its row")
    }

    func testFormattingOnlyChangeIsStillPersisted() throws {
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        try model.setNote(task, "same words")
        let plainRTF = task.noteRTF

        // Identical characters, different formatting: the plain shadow cannot
        // detect this, which is why the RTF column exists.
        try model.setNote(task, boldedFirstWord("same words"))

        XCTAssertEqual(task.note, "same words")
        XCTAssertNotEqual(task.noteRTF, plainRTF)
        XCTAssertTrue(isBold(model.noteText(of: task), at: 0))
    }

    func testStoredNotesAreSanitisedOnLoad() throws {
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        // Simulate a row written by a build with looser rules.
        let gaudy = NSAttributedString(string: "loud", attributes: [
            .font: NSFont.systemFont(ofSize: 30),
            .foregroundColor: NSColor.systemPink,
        ])
        task.noteRTF = gaudy.rtf(
            from: NSRange(location: 0, length: gaudy.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        task.note = "loud"

        let loaded = model.noteText(of: task)

        let font = try XCTUnwrap(loaded.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, NoteFormatting.bodyFontSize)
        XCTAssertEqual(loaded.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .labelColor)
    }

    private func boldedFirstWord(_ string: String) -> NSAttributedString {
        let bold = NSFont(descriptor:
            NoteFormatting.bodyFont.fontDescriptor.withSymbolicTraits(.bold),
            size: NoteFormatting.bodyFontSize
        )!
        let result = NSMutableAttributedString(
            string: string,
            attributes: NoteFormatting.typingAttributes
        )
        let firstWord = (string as NSString).range(of: " ")
        let length = firstWord.location == NSNotFound ? result.length : firstWord.location
        result.addAttribute(.font, value: bold, range: NSRange(location: 0, length: length))
        return result
    }

    private func isBold(_ attributed: NSAttributedString, at index: Int) -> Bool {
        guard let font = attributed.attribute(.font, at: index, effectiveRange: nil) as? NSFont
        else { return false }
        return font.fontDescriptor.symbolicTraits.contains(.bold)
    }
}
