import XCTest
@testable import Planner

/// Ported from CalendarList's `exdates.test.js`, plus the UID extraction that
/// replaces its per-exception `master.id` query.
final class ICalendarTests: XCTestCase {
    private typealias F = OutlookFixtures
    private let calendar = OutlookFixtures.calendar

    private func stamps(_ dates: [Date]) -> [String] {
        dates.map { date in
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            return String(
                format: "%04d-%02d-%02d %02d:%02d",
                parts.year!, parts.month!, parts.day!, parts.hour!, parts.minute!
            )
        }
    }

    private func exDates(_ ics: String) -> [String] {
        stamps(ICalendar.exDates(in: ics, calendar: calendar))
    }

    // MARK: - EXDATE

    func testNoICalendarTextYieldsNoDates() {
        XCTAssertTrue(ICalendar.exDates(in: "", calendar: calendar).isEmpty)
    }

    func testAnExDateIsReadAsLocalWallClockTime() {
        let ics = [
            "BEGIN:VEVENT",
            "EXDATE;TZID=\"Eastern Standard Time\":20260512T100000",
            "END:VEVENT",
        ].joined(separator: "\r\n")
        XCTAssertEqual(exDates(ics), ["2026-05-12 10:00"])
    }

    func testSeveralExDateLinesAllCount() {
        let ics = [
            "EXDATE;TZID=\"Eastern Standard Time\":20260512T100000",
            "EXDATE;TZID=\"Eastern Standard Time\":20260707T100000",
        ].joined(separator: "\r\n")
        XCTAssertEqual(exDates(ics), ["2026-05-12 10:00", "2026-07-07 10:00"])
    }

    func testACommaSeparatedExDateListIsSplit() {
        let ics = "EXDATE;TZID=\"Eastern Standard Time\":20260512T100000,20260707T100000"
        XCTAssertEqual(exDates(ics), ["2026-05-12 10:00", "2026-07-07 10:00"])
    }

    /// iCalendar wraps at 75 characters and marks the continuation with a
    /// leading space. Matching before unfolding silently loses the tail of a
    /// long EXDATE run, which is a deleted occurrence coming back to life.
    func testAFoldedExDateLineIsRejoinedBeforeParsing() {
        let ics = [
            "EXDATE;TZID=\"Eastern Standard Time\":20260512T100000,2026070",
            " 7T100000",
        ].joined(separator: "\r\n")
        XCTAssertEqual(exDates(ics), ["2026-05-12 10:00", "2026-07-07 10:00"])
    }

    func testATabFoldedLineIsAlsoRejoined() {
        let ics = "EXDATE:20260512T100000,2026070\r\n\t7T100000"
        XCTAssertEqual(exDates(ics), ["2026-05-12 10:00", "2026-07-07 10:00"])
    }

    func testADateOnlyExDateLandsAtMidnight() {
        XCTAssertEqual(exDates("EXDATE;VALUE=DATE:20260512"), ["2026-05-12 00:00"])
    }

    func testLinesOtherThanExDateAreIgnored() {
        let ics = [
            "DTSTART;TZID=\"Eastern Standard Time\":20260106T100000",
            "RRULE:FREQ=WEEKLY;UNTIL=20261231T235959;INTERVAL=2;BYDAY=TU",
            "EXDATE;TZID=\"Eastern Standard Time\":20260512T100000",
            "SUMMARY:IT Call",
        ].joined(separator: "\r\n")
        XCTAssertEqual(exDates(ics), ["2026-05-12 10:00"])
    }

    func testBareNewlinesAreHandledAsWellAsCRLF() {
        XCTAssertEqual(
            exDates("EXDATE:20260512T100000\nEXDATE:20260707T100000"),
            ["2026-05-12 10:00", "2026-07-07 10:00"]
        )
    }

    func testAUTCDesignatorIsIgnoredRatherThanConverted() {
        // Deliberate: Outlook's zones here are inconsistent, and the tolerant
        // slot matching absorbs the offset. Converting would be a guess.
        XCTAssertEqual(exDates("EXDATE:20260512T100000Z"), ["2026-05-12 10:00"])
    }

    func testMalformedTokensAreSkippedNotGuessedAt() {
        XCTAssertTrue(ICalendar.exDates(in: "EXDATE:nonsense", calendar: calendar).isEmpty)
        XCTAssertTrue(ICalendar.exDates(in: "EXDATE:2026", calendar: calendar).isEmpty)
        XCTAssertEqual(exDates("EXDATE:nonsense,20260512T100000"), ["2026-05-12 10:00"])
    }

    // MARK: - UID

    func testUIDIsExtracted() {
        let ics = [
            "BEGIN:VEVENT",
            "UID:040000008200E00074C5B7101A82E00800000000",
            "SUMMARY:Standup",
            "END:VEVENT",
        ].joined(separator: "\r\n")
        XCTAssertEqual(ICalendar.uid(in: ics), "040000008200E00074C5B7101A82E00800000000")
    }

    func testAFoldedUIDIsRejoined() {
        let ics = "UID:04000000820\r\n 0E00074C5B710"
        XCTAssertEqual(ICalendar.uid(in: ics), "040000008200E00074C5B710")
    }

    func testMissingOrEmptyUIDIsNil() {
        XCTAssertNil(ICalendar.uid(in: "SUMMARY:Standup"))
        XCTAssertNil(ICalendar.uid(in: "UID:"))
        XCTAssertNil(ICalendar.uid(in: ""))
    }
}
