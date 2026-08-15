import AppKit
import XCTest
@testable import Planner

/// These assert list **structure**, never marker characters: TextKit draws the
/// markers from `textLists`, so the text itself stays clean.
@MainActor
final class NoteListEditingTests: XCTestCase {
    func testTogglingABulletListAddsStructureWithoutTouchingTheText() {
        let storage = make("milk")

        NoteListEditing.toggle(.bullet, in: storage, selection: NSRange(location: 0, length: 4))

        XCTAssertEqual(storage.string, "milk", "markers are drawn, not inserted")
        XCTAssertEqual(depth(storage, at: 0), 1)
        XCTAssertEqual(NoteListEditing.kind(inParagraphAt: 0, of: storage), .bullet)
    }

    func testTogglingOffRemovesTheStructure() {
        let storage = make("milk")
        NoteListEditing.toggle(.bullet, in: storage, selection: NSRange(location: 0, length: 4))

        NoteListEditing.toggle(.bullet, in: storage, selection: NSRange(location: 0, length: 1))

        XCTAssertEqual(storage.string, "milk")
        XCTAssertEqual(depth(storage, at: 0), 0)
    }

    func testAListAppliesToEverySelectedParagraph() {
        let storage = make("one\ntwo\nthree")

        NoteListEditing.toggle(.numbered, in: storage, selection: NSRange(location: 0, length: storage.length))

        XCTAssertEqual(storage.string, "one\ntwo\nthree")
        for location in [0, 4, 8] {
            XCTAssertEqual(depth(storage, at: location), 1)
            XCTAssertEqual(NoteListEditing.kind(inParagraphAt: location, of: storage), .numbered)
        }
    }

    func testSwitchingKindKeepsDepthAndChangesEveryLevel() {
        let storage = make("one\ntwo")
        NoteListEditing.toggle(.bullet, in: storage, selection: NSRange(location: 0, length: storage.length))
        NoteListEditing.changeDepth(by: 1, in: storage, selection: NSRange(location: 4, length: 1))

        NoteListEditing.toggle(.numbered, in: storage, selection: NSRange(location: 0, length: storage.length))

        XCTAssertEqual(NoteListEditing.kind(inParagraphAt: 0, of: storage), .numbered)
        XCTAssertEqual(NoteListEditing.kind(inParagraphAt: 4, of: storage), .numbered)
        XCTAssertEqual(depth(storage, at: 4), 2, "depth is preserved across a kind change")
    }

    // MARK: - Nesting

    func testIndentingIncreasesDepthOfOnlyTheSelectedParagraph() {
        let storage = make("one\ntwo\nthree")
        NoteListEditing.toggle(.numbered, in: storage, selection: NSRange(location: 0, length: storage.length))

        NoteListEditing.changeDepth(by: 1, in: storage, selection: NSRange(location: 4, length: 3))

        XCTAssertEqual(depth(storage, at: 0), 1)
        XCTAssertEqual(depth(storage, at: 4), 2)
        XCTAssertEqual(depth(storage, at: 8), 1)
    }

    func testNestedLevelsCycleMarkerGlyphs() {
        let storage = make("a\nb\nc")
        NoteListEditing.toggle(.bullet, in: storage, selection: NSRange(location: 0, length: storage.length))
        NoteListEditing.changeDepth(by: 1, in: storage, selection: NSRange(location: 2, length: 1))
        NoteListEditing.changeDepth(by: 1, in: storage, selection: NSRange(location: 4, length: 1))
        NoteListEditing.changeDepth(by: 1, in: storage, selection: NSRange(location: 4, length: 1))

        XCTAssertEqual(formats(storage, at: 0), [.disc])
        XCTAssertEqual(formats(storage, at: 2), [.disc, .circle])
        XCTAssertEqual(formats(storage, at: 4), [.disc, .circle, .square])
    }

    func testNumberedNestingCyclesDecimalAlphaRoman() {
        let storage = make("a\nb\nc")
        NoteListEditing.toggle(.numbered, in: storage, selection: NSRange(location: 0, length: storage.length))
        NoteListEditing.changeDepth(by: 1, in: storage, selection: NSRange(location: 2, length: 1))
        NoteListEditing.changeDepth(by: 1, in: storage, selection: NSRange(location: 4, length: 1))
        NoteListEditing.changeDepth(by: 1, in: storage, selection: NSRange(location: 4, length: 1))

        XCTAssertEqual(formats(storage, at: 0), [.decimal])
        XCTAssertEqual(formats(storage, at: 2), [.decimal, .lowercaseAlpha])
        XCTAssertEqual(formats(storage, at: 4), [.decimal, .lowercaseAlpha, .lowercaseRoman])
    }

    func testOutdentingPastLevelOneLeavesTheList() {
        let storage = make("item")
        NoteListEditing.toggle(.bullet, in: storage, selection: NSRange(location: 0, length: 4))

        NoteListEditing.changeDepth(by: -1, in: storage, selection: NSRange(location: 0, length: 1))

        XCTAssertEqual(depth(storage, at: 0), 0)
    }

    func testNestingIsCappedAtTheMaximumDepth() {
        let storage = make("deep")
        NoteListEditing.toggle(.bullet, in: storage, selection: NSRange(location: 0, length: 4))

        for _ in 0..<10 {
            NoteListEditing.changeDepth(by: 1, in: storage, selection: NSRange(location: 0, length: 1))
        }

        XCTAssertEqual(depth(storage, at: 0), NoteFormatting.maximumListDepth)
    }

    func testIndentDepthDrivesTheParagraphIndent() {
        let storage = make("a\nb")
        NoteListEditing.toggle(.bullet, in: storage, selection: NSRange(location: 0, length: storage.length))
        NoteListEditing.changeDepth(by: 1, in: storage, selection: NSRange(location: 2, length: 1))

        let style = storage.attribute(.paragraphStyle, at: 2, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.headIndent, 2 * NoteFormatting.indentPerLevel)
        XCTAssertEqual(style?.firstLineHeadIndent, NoteFormatting.indentPerLevel)
    }

    // MARK: - Empty buffer

    /// The app's real entry point: switching a list on in a brand-new empty note.
    func testTogglingAListOnAnEmptyBufferDoesNotRaise() {
        let storage = NSMutableAttributedString(string: "", attributes: NoteFormatting.typingAttributes)

        NoteListEditing.toggle(.numbered, in: storage, selection: NSRange(location: 0, length: 0))

        XCTAssertEqual(storage.string, "")
    }

    // MARK: - Return handling

    func testEmptyListItemIsDetected() {
        let storage = make("one\n")
        NoteListEditing.toggle(.bullet, in: storage, selection: NSRange(location: 0, length: storage.length))
        storage.append(NSAttributedString(
            string: "",
            attributes: storage.attributes(at: 0, effectiveRange: nil)
        ))

        let text = storage.string as NSString
        let first = text.paragraphRange(for: NSRange(location: 0, length: 0))
        XCTAssertFalse(NoteListEditing.isEmptyListItem(paragraph: first, in: storage))
    }

    func testAParagraphWithOnlyANewlineIsAnEmptyItem() {
        let storage = make("\nsecond")
        NoteListEditing.toggle(.bullet, in: storage, selection: NSRange(location: 0, length: storage.length))

        let text = storage.string as NSString
        let first = text.paragraphRange(for: NSRange(location: 0, length: 0))
        XCTAssertTrue(NoteListEditing.isEmptyListItem(paragraph: first, in: storage))
    }

    // MARK: - Round-trip

    func testNestedListsSurviveTheStoreRoundTrip() throws {
        let storage = make("one\nsub\ntwo")
        NoteListEditing.toggle(.numbered, in: storage, selection: NSRange(location: 0, length: storage.length))
        NoteListEditing.changeDepth(by: 1, in: storage, selection: NSRange(location: 4, length: 3))

        let data = try XCTUnwrap(NoteFormatting.rtf(from: storage))
        let restored = NoteFormatting.attributedString(rtf: data, plain: storage.string)

        XCTAssertEqual(restored.string, "one\nsub\ntwo", "no marker punctuation in the text")
        XCTAssertEqual(NoteListEditing.lists(inParagraphAt: 0, of: restored).count, 1)
        XCTAssertEqual(NoteListEditing.lists(inParagraphAt: 4, of: restored).count, 2)
        XCTAssertEqual(NoteListEditing.lists(inParagraphAt: 8, of: restored).count, 1)
    }

    func testThePlainShadowOfAListIsJustTheText() {
        let storage = make("buy milk\nbuy eggs")
        NoteListEditing.toggle(.numbered, in: storage, selection: NSRange(location: 0, length: storage.length))

        XCTAssertEqual(NoteFormatting.plainText(from: storage), "buy milk\nbuy eggs")
    }

    private func make(_ string: String) -> NSMutableAttributedString {
        NSMutableAttributedString(string: string, attributes: NoteFormatting.typingAttributes)
    }

    private func depth(_ storage: NSAttributedString, at index: Int) -> Int {
        NoteListEditing.lists(inParagraphAt: index, of: storage).count
    }

    private func formats(_ storage: NSAttributedString, at index: Int) -> [NSTextList.MarkerFormat] {
        NoteListEditing.lists(inParagraphAt: index, of: storage).map(\.markerFormat)
    }
}
