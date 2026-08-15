import XCTest
@testable import Planner

/// Exercises the decode and script-generation halves of the Outlook mail
/// source, which is everything that does not require Outlook to be running.
///
/// The descriptors here are built the way `NSAppleScript` builds them, so the
/// tests fail for the same reasons a real reply would.
final class OutlookMailSourceTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    // MARK: - Descriptor fixtures

    private func list(_ items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let descriptor = NSAppleEventDescriptor.list()
        for (index, item) in items.enumerated() {
            descriptor.insert(item, at: index + 1)
        }
        return descriptor
    }

    private func sender(name: String?, address: String?) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        if let name {
            record.setDescriptor(.init(string: name), forKeyword: OutlookMailScripting.SenderKey.name)
        }
        if let address {
            record.setDescriptor(.init(string: address), forKeyword: OutlookMailScripting.SenderKey.address)
        }
        return record
    }

    private func envelopePayload(
        ids: [NSAppleEventDescriptor],
        subjects: [NSAppleEventDescriptor],
        times: [NSAppleEventDescriptor],
        read: [NSAppleEventDescriptor],
        senders: [NSAppleEventDescriptor]
    ) -> NSAppleEventDescriptor {
        list([list(ids), list(subjects), list(times), list(read), list(senders)])
    }

    private func date(_ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: day, hour: 9))!
    }

    // MARK: - Envelopes

    func testDecodesTheFiveColumns() throws {
        let payload = envelopePayload(
            ids: [.init(int32: 101), .init(int32: 102)],
            subjects: [.init(string: "First"), .init(string: "Second")],
            times: [.init(date: date(15)), .init(date: date(14))],
            read: [.init(boolean: false), .init(boolean: true)],
            senders: [
                sender(name: "Ada Lovelace", address: "ada@example.com"),
                sender(name: nil, address: "grace@example.com"),
            ]
        )

        let messages = try OutlookMailDecoder.envelopes(payload)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].id, 101)
        XCTAssertEqual(messages[0].subject, "First")
        XCTAssertEqual(messages[0].senderName, "Ada Lovelace")
        XCTAssertEqual(messages[0].senderAddress, "ada@example.com")
        XCTAssertEqual(messages[0].receivedAt, date(15))
        XCTAssertFalse(messages[0].isRead)
        XCTAssertTrue(messages[1].isRead)
        // A sender with no display name falls back to the address, so a row
        // never reads as blank.
        XCTAssertEqual(messages[1].senderDisplayName, "grace@example.com")
    }

    /// The whole reason parallel columns are safe here is that AppleScript
    /// keeps them aligned. If that ever stops being true, every row after the
    /// first gap is attributed to the wrong message — so it fails loudly.
    func testMismatchedColumnLengthsFailRatherThanShuffleRows() {
        let payload = envelopePayload(
            ids: [.init(int32: 1), .init(int32: 2)],
            subjects: [.init(string: "Only one")],
            times: [.init(date: date(15)), .init(date: date(14))],
            read: [.init(boolean: false), .init(boolean: false)],
            senders: [sender(name: "A", address: "a@x"), sender(name: "B", address: "b@x")]
        )
        XCTAssertThrowsError(try OutlookMailDecoder.envelopes(payload)) { error in
            XCTAssertEqual(error as? OutlookError, .misalignedPayload)
        }
    }

    func testAReplyWithTheWrongShapeIsRejected() {
        XCTAssertThrowsError(try OutlookMailDecoder.envelopes(list([.init(string: "nope")])))
    }

    /// A record missing the two fields every message must have is skipped
    /// rather than invented; it never fails the sweep.
    func testARecordWithNoDateIsSkipped() throws {
        let payload = envelopePayload(
            ids: [.init(int32: 1), .init(int32: 2)],
            subjects: [.init(string: "Good"), .init(string: "Bad")],
            times: [.init(date: date(15)), .null()],
            read: [.init(boolean: false), .init(boolean: false)],
            senders: [sender(name: "A", address: "a@x"), sender(name: "B", address: "b@x")]
        )
        XCTAssertEqual(try OutlookMailDecoder.envelopes(payload).map(\.id), [1])
    }

    func testAMissingSubjectDecodesToEmptyRatherThanFailing() throws {
        let payload = envelopePayload(
            ids: [.init(int32: 1)],
            subjects: [.null()],
            times: [.init(date: date(15))],
            read: [.init(boolean: false)],
            senders: [sender(name: "A", address: "a@x")]
        )
        XCTAssertEqual(try OutlookMailDecoder.envelopes(payload).first?.subject, "")
    }

    func testAnEmptyWindowDecodesToNoMessages() throws {
        let payload = envelopePayload(ids: [], subjects: [], times: [], read: [], senders: [])
        XCTAssertTrue(try OutlookMailDecoder.envelopes(payload).isEmpty)
    }

    // MARK: - Detail

    func testDecodesBodyHeadersAndAttachments() {
        let payload = list([
            .init(string: "The body\n\nwith blank lines"),
            .init(string: "Message-ID: <a@x>\rTo: you@x\rX-MS-Has-Attach: yes"),
            list([.init(string: "brief.pdf"), .init(string: "exhibit.png")]),
        ])

        let detail = OutlookMailDecoder.detail(payload, id: 7)
        XCTAssertEqual(detail.id, 7)
        XCTAssertEqual(detail.body, "The body\n\nwith blank lines")
        XCTAssertEqual(detail.messageID, "<a@x>")
        XCTAssertEqual(detail.recipients, "you@x")
        XCTAssertTrue(detail.hasAttachments)
        XCTAssertEqual(detail.attachmentNames, "brief.pdf\nexhibit.png")
    }

    /// A rights-protected message can refuse its attachment list, and a
    /// partially downloaded one can refuse its body. Neither is a failure.
    func testAMessageThatRefusesItsPartsStillDecodes() {
        let detail = OutlookMailDecoder.detail(list([.init(string: ""), .init(string: ""), list([])]), id: 7)
        XCTAssertEqual(detail.body, "")
        XCTAssertNil(detail.messageID)
        XCTAssertFalse(detail.hasAttachments)
        XCTAssertNil(detail.attachmentNames)
    }

    /// The Exchange header is the fallback when the attachment list could not
    /// be enumerated at all.
    func testTheAttachmentHeaderStandsInForAnUnreadableList() {
        let detail = OutlookMailDecoder.detail(
            list([.init(string: ""), .init(string: "X-MS-Has-Attach: yes"), list([])]),
            id: 7
        )
        XCTAssertTrue(detail.hasAttachments)
        XCTAssertNil(detail.attachmentNames)
    }

    /// Bodies keep their whitespace: it is content, not noise.
    func testTheBodyIsNotTrimmed() {
        let detail = OutlookMailDecoder.detail(
            list([.init(string: "  leading and trailing  "), .init(string: ""), list([])]),
            id: 1
        )
        XCTAssertEqual(detail.body, "  leading and trailing  ")
    }

    // MARK: - Script generation

    /// Every generated script must contain numbers only where a value goes:
    /// that is what makes them impossible to break with an odd account name or
    /// a locale Outlook does not share.
    func testTheDateLiteralIsBuiltFieldByField() {
        let script = OutlookMailScripting.dateLiteral(
            named: "cutoff",
            for: calendar.date(from: DateComponents(year: 2026, month: 8, day: 13, hour: 0))!,
            calendar: calendar
        )
        XCTAssertTrue(script.contains("set year of cutoff to 2026"), script)
        XCTAssertTrue(script.contains("set month of cutoff to 8"), script)
        XCTAssertTrue(script.contains("set day of cutoff to 13"), script)
        XCTAssertTrue(script.contains("set time of cutoff to 0"), script)
        // day 1 first, or setting day 31 in a short month rolls the date over.
        let firstDay = try! XCTUnwrap(script.range(of: "set day of cutoff to 1\n"))
        let year = try! XCTUnwrap(script.range(of: "set year of cutoff to"))
        XCTAssertLessThan(firstDay.lowerBound, year.lowerBound)
    }

    func testTheDateLiteralCarriesTheTimeOfDay() {
        let script = OutlookMailScripting.dateLiteral(
            named: "cutoff",
            for: calendar.date(from: DateComponents(year: 2026, month: 8, day: 13, hour: 1, minute: 2, second: 3))!,
            calendar: calendar
        )
        XCTAssertTrue(script.contains("set time of cutoff to \(3600 + 120 + 3)"), script)
    }

    /// The binary search runs inside the script, not as a series of round
    /// trips: fifteen probes at ~32ms each is half a second of Apple events for
    /// something Outlook can do in one.
    func testTheWindowCountScriptSearchesInPlace() {
        let script = OutlookMailScripting.windowCount(
            accountIndex: 1,
            since: date(13),
            calendar: calendar
        )
        XCTAssertTrue(script.contains("repeat while lo < hi"), script)
        XCTAssertTrue(script.contains("div 2"), script)
        XCTAssertFalse(script.contains("whose"), "the whose clause costs 23s a call")
    }

    func testTheEnvelopeScriptUsesARangeAndNotProperties() {
        let script = OutlookMailScripting.envelopes(accountIndex: 2, count: 164)
        XCTAssertTrue(script.contains("messages 1 thru 164"), script)
        XCTAssertTrue(script.contains("exchange account 2"), script)
        XCTAssertFalse(script.contains("properties"), "a single message's properties is 2.4 MB")
        // Five columns, in the order the decoder reads them.
        XCTAssertTrue(script.contains("return {theIDs, theSubjects, theTimes, theRead, theSenders}"), script)
    }

    func testTheDetailScriptAddressesOneMessageByIdAndToleratesMissingParts() {
        let script = OutlookMailScripting.detail(messageID: 181_121)
        XCTAssertTrue(script.contains("message id 181121"), script)
        XCTAssertTrue(script.contains("plain text content of m"), script)
        XCTAssertFalse(script.contains("to content of m"), "HTML content is never read")
        XCTAssertEqual(script.components(separatedBy: "try").count - 1, 6, "each read is wrapped")
    }

    // MARK: - Configuration

    func testConfigurationDefaults() {
        let suite = UserDefaults(suiteName: "OutlookMailSourceTests.\(UUID().uuidString)")!
        var configuration = OutlookMailSource.Configuration.fromDefaults(suite)
        XCTAssertNil(configuration.accountName)
        XCTAssertEqual(configuration.maximumMessages, OutlookMailSource.Configuration.defaultMaximumMessages)

        suite.set("  work@example.com  ", forKey: OutlookMailSource.Configuration.accountDefaultsKey)
        suite.set(50, forKey: OutlookMailSource.Configuration.maximumDefaultsKey)
        configuration = OutlookMailSource.Configuration.fromDefaults(suite)
        XCTAssertEqual(configuration.accountName, "work@example.com")
        XCTAssertEqual(configuration.maximumMessages, 50)
    }

    func testABlankAccountNameMeansTheFirstAccount() {
        let suite = UserDefaults(suiteName: "OutlookMailSourceTests.\(UUID().uuidString)")!
        suite.set("   ", forKey: OutlookMailSource.Configuration.accountDefaultsKey)
        XCTAssertNil(OutlookMailSource.Configuration.fromDefaults(suite).accountName)
    }

    // MARK: - Errors

    func testAppleScriptFailuresMapOntoOutlookErrors() {
        func mapped(_ code: Int) -> OutlookError {
            OutlookError.fromAppleScript([NSAppleScript.errorNumber: code] as NSDictionary)
        }
        XCTAssertEqual(mapped(-1743), .permissionDenied)
        XCTAssertEqual(mapped(-600), .notRunning)
        XCTAssertEqual(mapped(-609), .notRunning)
        XCTAssertEqual(mapped(-1728), .appleEvent(code: -1728))
    }

    /// "That one message is gone" is an ordinary outcome, not a broken
    /// connection, and the reader says so in plain words.
    func testAMissingObjectIsDistinguishedFromABrokenConnection() {
        XCTAssertTrue(OutlookError.appleEvent(code: -1728).isMissingObject)
        XCTAssertTrue(OutlookError.appleEvent(code: -1719).isMissingObject)
        XCTAssertFalse(OutlookError.appleEvent(code: -1712).isMissingObject)
        XCTAssertFalse(OutlookError.permissionDenied.isMissingObject)
    }

    func testMisalignmentReadsAsSomethingToRetry() {
        XCTAssertNotNil(OutlookError.misalignedPayload.errorDescription)
        XCTAssertNotNil(OutlookError.misalignedPayload.recoverySuggestion)
        XCTAssertNil(OutlookError.misalignedPayload.settingsURL)
    }
}
