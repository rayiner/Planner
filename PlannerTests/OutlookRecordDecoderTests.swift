import XCTest
@testable import Planner

/// Exercises the decoder against payloads shaped exactly like the ones observed
/// coming out of ScriptingBridge on 2026-08-14 (Outlook 16.103.2).
///
/// The **structure** is captured from a real fetch — key names, value classes,
/// which keys are absent versus `NSNull`, the four-character codes. The
/// **content** is synthetic: the calendar those payloads came from is a working
/// law practice's, and subjects, organizers and locations have no business in a
/// repository.
final class OutlookRecordDecoderTests: XCTestCase {
    private typealias F = OutlookFixtures
    private let calendar = OutlookFixtures.calendar

    /// Enum properties arrive wrapped like this, never as strings.
    private func code(_ fourChar: String) -> NSAppleEventDescriptor {
        var value: OSType = 0
        for byte in fourChar.unicodeScalars { value = (value << 8) | (OSType(byte.value) & 0xFF) }
        return NSAppleEventDescriptor(enumCode: value)
    }

    private func days(_ selected: [String]) -> [AnyHashable: Any] {
        // Outlook sends all seven flags every time, not just the true ones.
        var record: [AnyHashable: Any] = [:]
        for day in OutlookScripting.DayKey.ordered {
            record[day] = NSNumber(value: selected.contains(day))
        }
        return record
    }

    /// A plain (non-recurring) event, with `location` as `NSNull` — which is
    /// what Outlook actually sends for an event with no location, rather than
    /// omitting the key.
    private func plainPayload() -> [AnyHashable: Any] {
        [
            "id": NSNumber(value: 3243),
            "subject": "Team sync",
            "startTime": F.at(2026, 8, 14, 14, 0),
            "endTime": F.at(2026, 8, 14, 15, 0),
            "location": NSNull(),
            "organizer": "someone@example.com",
            "allDayFlag": NSNumber(value: false),
            "isRecurring": NSNumber(value: false),
            "isOccurrence": NSNumber(value: false),
            "recurrence": NSNull(),
            "recurrenceId": NSNull(),
            "master": NSNull(),
            "freeBusyStatus": code("eSTe"),
            "icalendarData": "BEGIN:VCALENDAR\r\nUID:UID-PLAIN-1\r\nEND:VCALENDAR",
            "timezone": ["name": "US/Eastern", "offset": NSNumber(value: -14400)],
        ]
    }

    /// A weekly master. Note `ordinal`, `dayOfMonth` and `monthNumber` are
    /// **absent**, not null — Outlook omits keys its pattern does not use.
    private func masterPayload(
        recurrence: [AnyHashable: Any]? = nil,
        ics: String = "BEGIN:VCALENDAR\r\nUID:UID-SERIES-1\r\nEND:VCALENDAR"
    ) -> [AnyHashable: Any] {
        [
            "id": NSNumber(value: 2665),
            "subject": "Weekly review",
            "startTime": F.at(2026, 8, 4, 9, 0),
            "endTime": F.at(2026, 8, 4, 9, 30),
            "location": NSNull(),
            "organizer": NSNull(),
            "allDayFlag": NSNumber(value: false),
            "isRecurring": NSNumber(value: true),
            "isOccurrence": NSNumber(value: false),
            "recurrenceId": NSNull(),
            "icalendarData": ics,
            "recurrence": recurrence ?? [
                "recurrenceType": code("eRwp"),
                "occurrenceInterval": NSNumber(value: 1),
                "daysOfWeek": days(["tuesday"]),
                "startDate": F.at(2026, 8, 4),
                "endDate": ["endType": code("eNEt")],
            ],
        ]
    }

    // MARK: - Scalars

    func testNSNullIsTreatedAsAbsent() {
        XCTAssertNil(OutlookRecordDecoder.string(NSNull()))
        XCTAssertNil(OutlookRecordDecoder.date(NSNull()))
        XCTAssertNil(OutlookRecordDecoder.int(NSNull()))
        XCTAssertNil(OutlookRecordDecoder.identifier(NSNull()))
        XCTAssertFalse(OutlookRecordDecoder.bool(NSNull()))
    }

    func testEmptyAndWhitespaceStringsCollapseToNil() {
        XCTAssertNil(OutlookRecordDecoder.string(""))
        XCTAssertNil(OutlookRecordDecoder.string("   "))
        XCTAssertEqual(OutlookRecordDecoder.string("  Team sync  "), "Team sync")
    }

    func testIdentifiersComeBackAsNumbersNotStrings() {
        XCTAssertEqual(OutlookRecordDecoder.identifier(NSNumber(value: 2665)), "2665")
        XCTAssertEqual(OutlookRecordDecoder.identifier("abc"), "abc")
        XCTAssertNil(OutlookRecordDecoder.identifier(nil))
    }

    func testBooleansArriveAsNSNumber() {
        XCTAssertTrue(OutlookRecordDecoder.bool(NSNumber(value: true)))
        XCTAssertFalse(OutlookRecordDecoder.bool(NSNumber(value: false)))
        XCTAssertFalse(OutlookRecordDecoder.bool(nil))
    }

    func testFourCharCodeIsReadFromTheDescriptor() {
        XCTAssertEqual(OutlookRecordDecoder.fourCharCode(code("eRwp")), "eRwp")
        XCTAssertEqual(OutlookRecordDecoder.fourCharCode(code("eNEt")), "eNEt")
        XCTAssertNil(OutlookRecordDecoder.fourCharCode("eRwp"), "a bare string is not what arrives")
        XCTAssertNil(OutlookRecordDecoder.fourCharCode(NSNull()))
    }

    func testTypeCodeDescriptorsAlsoDecode() {
        var value: OSType = 0
        for byte in "cEvt".unicodeScalars { value = (value << 8) | (OSType(byte.value) & 0xFF) }
        XCTAssertEqual(
            OutlookRecordDecoder.fourCharCode(NSAppleEventDescriptor(typeCode: value)), "cEvt"
        )
    }

    // MARK: - Day mask

    func testDayMaskReadsTheIndividualFlags() {
        XCTAssertEqual(OutlookRecordDecoder.dayMask(days(["tuesday"])), .tuesday)
        XCTAssertEqual(
            OutlookRecordDecoder.dayMask(days(["monday", "wednesday"])), [.monday, .wednesday]
        )
        XCTAssertEqual(OutlookRecordDecoder.dayMask(days(["sunday"])), .sunday)
        XCTAssertEqual(OutlookRecordDecoder.dayMask(days(["saturday"])), .saturday)
    }

    /// An all-false record is "unspecified", not "never fires" — the rule then
    /// falls back to the anchor's weekday.
    func testAnAllFalseDayMaskDecodesToNil() {
        XCTAssertNil(OutlookRecordDecoder.dayMask(days([])))
        XCTAssertNil(OutlookRecordDecoder.dayMask(NSNull()))
    }

    /// Not observed in practice — Outlook expands them — but declared in the
    /// sdef, so the decoder honours them rather than silently dropping a rule.
    func testAggregateDayKeysAreHonouredIfPresent() {
        var record = days([])
        record[OutlookScripting.DayKey.weekdays] = NSNumber(value: true)
        XCTAssertEqual(OutlookRecordDecoder.dayMask(record), .weekdays)

        var weekend = days([])
        weekend[OutlookScripting.DayKey.weekends] = NSNumber(value: true)
        XCTAssertEqual(OutlookRecordDecoder.dayMask(weekend), .weekends)
    }

    // MARK: - Rules

    func testWeeklyRuleDecodes() {
        let rule = OutlookRecordDecoder.rule(masterPayload()["recurrence"])
        XCTAssertEqual(rule?.pattern, .weekly)
        XCTAssertEqual(rule?.interval, 1)
        XCTAssertEqual(rule?.daysOfWeek, .tuesday)
        XCTAssertEqual(rule?.end, .never)
        XCTAssertNil(rule?.ordinal, "absent keys must decode as nil, not zero")
        XCTAssertNil(rule?.dayOfMonth)
        XCTAssertNil(rule?.monthNumber)
    }

    func testUntilDateRuleDecodes() {
        let rule = OutlookRecordDecoder.rule([
            "recurrenceType": code("eRwp"),
            "occurrenceInterval": NSNumber(value: 2),
            "daysOfWeek": days(["tuesday"]),
            "endDate": ["endType": code("eEDt"), "data": F.at(2026, 12, 31)],
        ])
        XCTAssertEqual(rule?.interval, 2)
        XCTAssertEqual(rule?.end, .on(F.at(2026, 12, 31)))
    }

    func testCountLimitedRuleDecodes() {
        let rule = OutlookRecordDecoder.rule([
            "recurrenceType": code("eRdp"),
            "occurrenceInterval": NSNumber(value: 1),
            "endDate": ["endType": code("eENt"), "data": NSNumber(value: 10)],
        ])
        XCTAssertEqual(rule?.pattern, .daily)
        XCTAssertEqual(rule?.end, .after(10))
    }

    func testRelativeMonthlyRuleDecodesItsOrdinal() {
        let rule = OutlookRecordDecoder.rule([
            "recurrenceType": code("eRrm"),
            "occurrenceInterval": NSNumber(value: 3),
            "ordinal": NSNumber(value: 2),
            "daysOfWeek": days(["wednesday"]),
            "endDate": ["endType": code("eNEt")],
        ])
        XCTAssertEqual(rule?.pattern, .relativeMonthly)
        XCTAssertEqual(rule?.ordinal, 2)
        XCTAssertEqual(rule?.interval, 3)
    }

    func testAnUnrecognisedPatternCodeDegradesRatherThanFailing() {
        let rule = OutlookRecordDecoder.rule([
            "recurrenceType": code("zzzz"),
            "occurrenceInterval": NSNumber(value: 1),
        ])
        XCTAssertEqual(rule?.pattern, .unknown)
    }

    func testAMissingRecurrenceRecordIsNotARule() {
        XCTAssertNil(OutlookRecordDecoder.rule(NSNull()))
        XCTAssertNil(OutlookRecordDecoder.rule(nil))
    }

    func testEndDataOfTheWrongTypeFallsBackToNever() {
        XCTAssertEqual(
            OutlookRecordDecoder.endRule(["endType": code("eEDt"), "data": NSNumber(value: 5)]),
            .never,
            "an until-date carrying a count is malformed, not a series ending now"
        )
        XCTAssertEqual(
            OutlookRecordDecoder.endRule(["endType": code("eENt"), "data": F.at(2026, 1, 1)]),
            .never
        )
        XCTAssertEqual(OutlookRecordDecoder.endRule(["endType": code("eENt")]), .never)
        XCTAssertEqual(OutlookRecordDecoder.endRule(NSNull()), .never)
    }

    // MARK: - Events

    func testPlainEventDecodes() {
        let event = OutlookRecordDecoder.rawEvent(plainPayload(), calendar: calendar)
        XCTAssertEqual(event?.id, "3243")
        XCTAssertEqual(event?.uid, "UID-PLAIN-1")
        XCTAssertEqual(event?.subject, "Team sync")
        XCTAssertNil(event?.location, "NSNull is not a location")
        XCTAssertEqual(event?.organizer, "someone@example.com")
        XCTAssertFalse(event?.isAllDay ?? true)
        XCTAssertNil(event?.rule)
        XCTAssertNil(event?.recurrenceId)
        XCTAssertTrue(event?.exDates.isEmpty ?? false)
    }

    func testMasterDecodesItsRuleAndExDates() {
        let ics = [
            "BEGIN:VCALENDAR",
            "UID:UID-SERIES-1",
            "EXDATE;TZID=\"Eastern Standard Time\":20260901T090000",
            "END:VCALENDAR",
        ].joined(separator: "\r\n")
        let event = OutlookRecordDecoder.rawEvent(masterPayload(ics: ics), calendar: calendar)
        XCTAssertEqual(event?.uid, "UID-SERIES-1")
        XCTAssertEqual(event?.rule?.pattern, .weekly)
        XCTAssertEqual(event?.exDates, [F.at(2026, 9, 1, 9, 0)])
    }

    /// Parsing iCalendar text for every plain event would be wasted work, so
    /// only masters get their EXDATEs read.
    func testExDatesAreOnlyReadForMasters() {
        var payload = plainPayload()
        payload["icalendarData"] = "UID:UID-PLAIN-1\r\nEXDATE:20260901T090000"
        let event = OutlookRecordDecoder.rawEvent(payload, calendar: calendar)
        XCTAssertTrue(event?.exDates.isEmpty ?? false)
    }

    func testExceptionDecodesItsRecurrenceId() {
        var payload = plainPayload()
        payload["isOccurrence"] = NSNumber(value: true)
        payload["recurrenceId"] = F.at(2026, 8, 11, 14, 0)
        payload["icalendarData"] = "UID:UID-SERIES-1"
        let event = OutlookRecordDecoder.rawEvent(payload, calendar: calendar)
        XCTAssertEqual(event?.recurrenceId, F.at(2026, 8, 11, 14, 0))
        XCTAssertEqual(event?.uid, "UID-SERIES-1", "the UID is how it finds its master")
    }

    // MARK: - Malformed input

    /// Outlook's "On My Computer" calendars store NSNull for `account`.
    /// Calling `value(forKey:)` on that would raise and kill the fetch.
    func testAccountIDIgnoresNullAndMissingAccounts() {
        XCTAssertNil(OutlookRecordDecoder.accountID(NSNull()))
        XCTAssertNil(OutlookRecordDecoder.accountID(nil))
    }

    func testAccountIDReadsANestedRecord() {
        XCTAssertEqual(
            OutlookRecordDecoder.accountID([OutlookScripting.Key.id: NSNumber(value: 7)]),
            7
        )
    }

    func testAccountIDReadsAnObjectWithAnIDKey() {
        let account = FakeAccount(id: 42)
        XCTAssertEqual(OutlookRecordDecoder.accountID(account), 42)
    }

    func testARecordWithoutAnIDOrStartIsSkippedNotInvented() {
        var noID = plainPayload()
        noID["id"] = NSNull()
        XCTAssertNil(OutlookRecordDecoder.rawEvent(noID, calendar: calendar))

        var noStart = plainPayload()
        noStart["startTime"] = NSNull()
        XCTAssertNil(OutlookRecordDecoder.rawEvent(noStart, calendar: calendar))
    }

    func testAMissingSubjectGetsAPlaceholderRatherThanBeingDropped() {
        var payload = plainPayload()
        payload["subject"] = NSNull()
        XCTAssertEqual(OutlookRecordDecoder.rawEvent(payload, calendar: calendar)?.subject, "(No subject)")
    }

    func testAMissingEndBecomesAZeroLengthEvent() {
        var payload = plainPayload()
        payload["endTime"] = NSNull()
        let event = OutlookRecordDecoder.rawEvent(payload, calendar: calendar)
        XCTAssertEqual(event?.end, event?.start)
    }

    /// One bad record must not fail the whole refresh.
    func testABadRecordIsSkippedWithoutLosingTheGoodOnes() {
        var broken = plainPayload()
        broken["id"] = NSNull()
        let decoded = OutlookRecordDecoder.rawEvents(
            [plainPayload(), broken, masterPayload()], calendar: calendar
        )
        XCTAssertEqual(decoded.count, 2)
    }

    func testAnEmptyPayloadDecodesToNothing() {
        XCTAssertTrue(OutlookRecordDecoder.rawEvents([], calendar: calendar).isEmpty)
        XCTAssertNil(OutlookRecordDecoder.rawEvent([:], calendar: calendar))
    }

    // MARK: - End to end, no Outlook involved

    /// The full path a real fetch takes, minus the Apple events: decode three
    /// payload groups, then merge and expand them.
    func testDecodedPayloadsFeedTheAgenda() {
        let master = OutlookRecordDecoder.rawEvent(masterPayload(), calendar: calendar)!
        let plain = OutlookRecordDecoder.rawEvent(plainPayload(), calendar: calendar)!
        let events = OutlookAgenda.build(
            OutlookSnapshot(calendarName: "Calendar", plain: [plain], masters: [master]),
            in: F.at(2026, 8, 1)..<F.at(2026, 9, 1),
            calendar: calendar
        )
        // Weekly Tuesdays from Aug 4, plus the one plain event on Aug 14.
        XCTAssertEqual(
            F.days(events),
            ["2026-08-04", "2026-08-11", "2026-08-14", "2026-08-18", "2026-08-25"]
        )
        XCTAssertEqual(events.filter(\.isRecurring).count, 4)
    }
}

/// Stands in for the ScriptingBridge account object that lives under a
/// calendar's `account` key — KVC for `id`, nothing else.
private final class FakeAccount: NSObject {
    @objc let id: NSNumber
    init(id: Int) { self.id = NSNumber(value: id) }
}
