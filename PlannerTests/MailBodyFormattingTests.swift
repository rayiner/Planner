import AppKit
import XCTest
@testable import Planner

@MainActor
final class MailBodyFormattingTests: XCTestCase {
    func testPlainTextIsShownAsTyped() {
        let shown = MailBodyFormatting.attributedString(html: nil, plain: "Just text")
        XCTAssertEqual(shown.string, "Just text")
        XCTAssertEqual(
            (shown.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize,
            NoteFormatting.bodyFontSize
        )
    }

    func testHTMLBoldSurvivesAndForeignFontsDoNot() {
        let shown = MailBodyFormatting.attributedString(
            html: #"<p style="font-size: 48px; color: red">Hello <b>there</b></p>"#,
            plain: "Hello there"
        )
        XCTAssertTrue(shown.string.contains("Hello"))
        XCTAssertTrue(shown.string.contains("there"))

        var sawBold = false
        shown.enumerateAttribute(.font, in: NSRange(location: 0, length: shown.length)) { value, _, _ in
            guard let font = value as? NSFont else { return }
            XCTAssertEqual(font.pointSize, NoteFormatting.bodyFontSize)
            if font.fontDescriptor.symbolicTraits.contains(.bold) { sawBold = true }
        }
        XCTAssertTrue(sawBold, "the <b> did not survive sanitising")
    }

    func testHTMLLinksSurvive() {
        let shown = MailBodyFormatting.attributedString(
            html: #"<a href="https://example.com/path">site</a>"#,
            plain: "site"
        )
        var link: URL?
        shown.enumerateAttribute(.link, in: NSRange(location: 0, length: shown.length)) { value, _, stop in
            link = value as? URL
            stop.pointee = true
        }
        XCTAssertEqual(link, URL(string: "https://example.com/path"))
    }

    func testScriptsAndImagesAreStrippedBeforeTheParse() {
        let dirty = """
        <p>Visible</p>
        <script>document.cookie</script>
        <img src="https://tracker.example/pixel.gif">
        <iframe src="https://evil.example"></iframe>
        """
        let cleaned = MailBodyFormatting.stripUnsafe(dirty)
        XCTAssertFalse(cleaned.contains("document.cookie"))
        XCTAssertFalse(cleaned.contains("tracker.example"))
        XCTAssertFalse(cleaned.contains("iframe"))
        XCTAssertTrue(cleaned.contains("Visible"))

        let shown = MailBodyFormatting.attributedString(html: dirty, plain: "Visible")
        XCTAssertTrue(shown.string.contains("Visible"))
        XCTAssertFalse(shown.string.contains("\u{fffc}"), "an image attachment character survived")
    }

    func testUnparseableHTMLFallsBackToPlainText() {
        // A `content` that is not HTML at all still has to show something.
        let shown = MailBodyFormatting.attributedString(html: "", plain: "Fallback")
        XCTAssertEqual(shown.string, "Fallback")
    }
}
