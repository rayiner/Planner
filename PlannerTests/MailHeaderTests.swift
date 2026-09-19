import XCTest
@testable import Planner

final class MailHeaderTests: XCTestCase {
    /// Shaped like the real payload the M0 spike captured: CR line endings and
    /// folded continuations, which is what a naive split gets wrong.
    private let captured = [
        "Received: from DS3PR03MB989169.namprd03.prod.outlook.com (::1) by",
        " BLAPR03MB5458.namprd03.prod.outlook.com with HTTPS; Sat, 15 Aug 2026 19:56:06 +0000",
        "From: \"Looper, Jared\" <jlooper@mololamken.com>",
        "To: \"Hashem, Rayiner\" <rhashem@mololamken.com>",
        "Cc: \"Fischell, Jennifer\" <jfischell@mololamken.com>",
        "Subject: Celerity - Objections to Marking and FRAND Damages Orders",
        "Message-ID:",
        " <BLAPR03MB54090FA814FE4907319D3146D5D92@BLAPR03MB5409.namprd03.prod.outlook.com>",
        "In-Reply-To: <0CB6B068-D474-484A-BFF2-90D0C855BD85@mololamken.com>",
        "References: <0CB6B068-D474-484A-BFF2-90D0C855BD85@mololamken.com>",
        "\t<A11B1111-2222-3333-4444-555555555555@mololamken.com>",
        "X-MS-Has-Attach: yes",
    ].joined(separator: "\r")

    // MARK: - Unfolding

    /// The bug this exists for: Outlook's headers are CR-terminated, so
    /// splitting on newlines alone finds one enormous line.
    func testCarriageReturnsSeparateLines() {
        let lines = MailHeaders.unfold("A: one\rB: two")
        XCTAssertEqual(lines, ["A: one", "B: two"])
    }

    func testLineFeedsAndCRLFAlsoSeparateLines() {
        XCTAssertEqual(MailHeaders.unfold("A: one\nB: two"), ["A: one", "B: two"])
        XCTAssertEqual(MailHeaders.unfold("A: one\r\nB: two"), ["A: one", "B: two"])
    }

    func testFoldedContinuationsJoinOntoTheirHeader() {
        let lines = MailHeaders.unfold("Subject: a very\r long subject\rTo: you")
        XCTAssertEqual(lines, ["Subject: a very long subject", "To: you"])
    }

    func testTabFoldedContinuationsAlsoJoin() {
        let lines = MailHeaders.unfold("References: <a@x>\r\t<b@x>")
        XCTAssertEqual(lines, ["References: <a@x> <b@x>"])
    }

    /// A continuation with nothing above it is malformed; dropping it beats
    /// crashing on an empty array.
    func testALeadingContinuationIsDiscarded() {
        XCTAssertEqual(MailHeaders.unfold(" orphan\rA: one"), ["A: one"])
    }

    // MARK: - Lookup

    func testLookupIsCaseInsensitive() {
        let lines = MailHeaders.unfold("MESSAGE-ID: <a@x>")
        XCTAssertEqual(MailHeaders.value(of: "message-id", in: lines), "<a@x>")
        XCTAssertEqual(MailHeaders.value(of: "Message-ID", in: lines), "<a@x>")
    }

    func testAnEmptyValueReadsAsAbsent() {
        let lines = MailHeaders.unfold("X-MS-Has-Attach:")
        XCTAssertNil(MailHeaders.value(of: "x-ms-has-attach", in: lines))
    }

    func testAMissingHeaderIsNil() {
        XCTAssertNil(MailHeaders.value(of: "references", in: MailHeaders.unfold("To: you")))
    }

    // MARK: - Parsing

    func testParsesTheCapturedPayload() {
        let parsed = MailHeaders.parse(captured)
        XCTAssertEqual(
            parsed.messageID,
            "<BLAPR03MB54090FA814FE4907319D3146D5D92@BLAPR03MB5409.namprd03.prod.outlook.com>"
        )
        XCTAssertEqual(parsed.inReplyTo, "<0CB6B068-D474-484A-BFF2-90D0C855BD85@mololamken.com>")
        XCTAssertEqual(
            MailHeaders.referenceIDs(from: parsed.references).count,
            2,
            "the folded second reference was lost"
        )
        XCTAssertTrue(parsed.hasAttachments)
        XCTAssertEqual(
            parsed.recipients,
            "\"Hashem, Rayiner\" <rhashem@mololamken.com>, \"Fischell, Jennifer\" <jfischell@mololamken.com>"
        )
    }

    func testNoAttachmentHeaderMeansNoAttachments() {
        XCTAssertFalse(MailHeaders.parse("To: you\rSubject: hi").hasAttachments)
    }

    /// Exchange writes the header with an empty value on a message with none,
    /// so presence alone is not the answer.
    func testAnEmptyAttachmentHeaderMeansNoAttachments() {
        XCTAssertFalse(MailHeaders.parse("X-MS-Has-Attach:\rTo: you").hasAttachments)
    }

    func testMissingRecipientsAreNil() {
        XCTAssertNil(MailHeaders.parse("Subject: hi").recipients)
    }

    func testCcAloneStillCounts() {
        XCTAssertEqual(MailHeaders.parse("Cc: them@x").recipients, "them@x")
    }

    /// A bare Message-ID would never match a `References` entry, which always
    /// carries brackets.
    func testAnUnbracketedMessageIDGrowsBrackets() {
        XCTAssertEqual(MailHeaders.parse("Message-ID: abc@x").messageID, "<abc@x>")
    }

    func testEmptyHeadersParseToNothing() {
        let parsed = MailHeaders.parse(nil)
        XCTAssertNil(parsed.messageID)
        XCTAssertNil(parsed.recipients)
        XCTAssertFalse(parsed.hasAttachments)
        XCTAssertEqual(MailHeaders.parse(""), parsed)
    }
}
