import XCTest
@testable import Planner

final class EventChipTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    private func window(_ from: Date, _ to: Date) -> Range<Date> {
        calendar.startOfDay(for: from)..<calendar.startOfDay(for: to)
    }

    private func event(
        id: String = "e1",
        title: String = "Design review",
        start: Date,
        end: Date,
        allDay: Bool = false
    ) -> CalendarEvent {
        CalendarEvent(id: id, title: title, start: start, end: end, isAllDay: allDay)
    }

    // MARK: - Single day

    func testTimedEventProducesOneChipCarryingItsStartTime() {
        let start = at(2026, 8, 14, 9, 30)
        let chips = CalendarEventChip.chips(
            for: event(start: start, end: at(2026, 8, 14, 10, 30)),
            in: window(at(2026, 8, 10), at(2026, 8, 24)),
            calendar: calendar
        )
        XCTAssertEqual(chips.count, 1)
        XCTAssertEqual(chips[0].day, calendar.startOfDay(for: start))
        XCTAssertEqual(chips[0].startTime, start)
        XCTAssertEqual(chips[0].endTime, at(2026, 8, 14, 10, 30))
        XCTAssertFalse(chips[0].continuesFromPreviousDay)
        XCTAssertFalse(chips[0].continuesToNextDay)
    }

    func testAllDayEventCarriesNoStartTime() {
        let chips = CalendarEventChip.chips(
            for: event(start: at(2026, 8, 14), end: at(2026, 8, 15), allDay: true),
            in: window(at(2026, 8, 10), at(2026, 8, 24)),
            calendar: calendar
        )
        XCTAssertEqual(chips.count, 1, "a one-day all-day event must not bleed into the next day")
        XCTAssertNil(chips[0].startTime)
        XCTAssertTrue(chips[0].isAllDay)
    }

    /// An exclusive end at midnight belongs to the previous day; treating it as
    /// inclusive lights up a day the event does not touch.
    func testEndAtMidnightDoesNotLightTheNextDay() {
        let chips = CalendarEventChip.chips(
            for: event(start: at(2026, 8, 14, 22, 0), end: at(2026, 8, 15, 0, 0)),
            in: window(at(2026, 8, 10), at(2026, 8, 24)),
            calendar: calendar
        )
        XCTAssertEqual(chips.map(\.day), [calendar.startOfDay(for: at(2026, 8, 14))])
    }

    func testEndPastMidnightDoesLightTheNextDay() {
        let chips = CalendarEventChip.chips(
            for: event(start: at(2026, 8, 14, 22, 0), end: at(2026, 8, 15, 0, 30)),
            in: window(at(2026, 8, 10), at(2026, 8, 24)),
            calendar: calendar
        )
        XCTAssertEqual(chips.count, 2)
    }

    // MARK: - Multi-day

    func testThreeDayEventExpandsWithContinuationFlags() {
        let chips = CalendarEventChip.chips(
            for: event(start: at(2026, 8, 12), end: at(2026, 8, 15), allDay: true),
            in: window(at(2026, 8, 10), at(2026, 8, 24)),
            calendar: calendar
        )
        XCTAssertEqual(chips.count, 3)
        XCTAssertEqual(chips.map(\.continuesFromPreviousDay), [false, true, true])
        XCTAssertEqual(chips.map(\.continuesToNextDay), [true, true, false])
    }

    func testContinuationDaysCarryNoStartTime() {
        let chips = CalendarEventChip.chips(
            for: event(start: at(2026, 8, 12, 14, 0), end: at(2026, 8, 14, 16, 0)),
            in: window(at(2026, 8, 10), at(2026, 8, 24)),
            calendar: calendar
        )
        XCTAssertEqual(chips.count, 3)
        XCTAssertEqual(chips[0].startTime, at(2026, 8, 12, 14, 0))
        XCTAssertNil(chips[1].startTime, "a continuation day has no start time to show")
        XCTAssertNil(chips[1].endTime)
        XCTAssertNil(chips[2].startTime)
    }

    func testChipIdsAreDistinctPerDay() {
        let chips = CalendarEventChip.chips(
            for: event(start: at(2026, 8, 12), end: at(2026, 8, 15), allDay: true),
            in: window(at(2026, 8, 10), at(2026, 8, 24)),
            calendar: calendar
        )
        XCTAssertEqual(Set(chips.map(\.id)).count, chips.count)
    }

    // MARK: - Window clamping

    func testEventStartingBeforeTheWindowIsClampedNotDropped() {
        let chips = CalendarEventChip.chips(
            for: event(start: at(2026, 8, 8), end: at(2026, 8, 13), allDay: true),
            in: window(at(2026, 8, 10), at(2026, 8, 24)),
            calendar: calendar
        )
        XCTAssertEqual(chips.first?.day, calendar.startOfDay(for: at(2026, 8, 10)))
        XCTAssertTrue(chips.first?.continuesFromPreviousDay ?? false)
    }

    func testEventEntirelyOutsideTheWindowProducesNothing() {
        let chips = CalendarEventChip.chips(
            for: event(start: at(2026, 7, 1), end: at(2026, 7, 2)),
            in: window(at(2026, 8, 10), at(2026, 8, 24)),
            calendar: calendar
        )
        XCTAssertTrue(chips.isEmpty)
    }

    /// The upper bound is exclusive, so the last day on screen is the one before it.
    func testWindowUpperBoundIsExclusive() {
        let chips = CalendarEventChip.chips(
            for: event(start: at(2026, 8, 24), end: at(2026, 8, 24, 10, 0)),
            in: window(at(2026, 8, 10), at(2026, 8, 24)),
            calendar: calendar
        )
        XCTAssertTrue(chips.isEmpty, "an event on the exclusive upper bound is outside the window")
    }

    // MARK: - Ordering

    func testAllDayEventsSortBeforeTimedOnes() {
        let timed = event(id: "timed", title: "Standup", start: at(2026, 8, 14, 9, 0), end: at(2026, 8, 14, 9, 15))
        let allDay = event(id: "allday", title: "Conference", start: at(2026, 8, 14), end: at(2026, 8, 15), allDay: true)
        let index = CalendarEventChip.index(
            [timed, allDay],
            in: window(at(2026, 8, 10), at(2026, 8, 24)),
            calendar: calendar
        )
        let day = index[calendar.startOfDay(for: at(2026, 8, 14))] ?? []
        XCTAssertEqual(day.map(\.title), ["Conference", "Standup"])
    }

    func testTimedEventsSortByStartThenTitle() {
        let late = event(id: "c", title: "Late", start: at(2026, 8, 14, 15, 0), end: at(2026, 8, 14, 16, 0))
        let earlyB = event(id: "b", title: "Beta", start: at(2026, 8, 14, 9, 0), end: at(2026, 8, 14, 10, 0))
        let earlyA = event(id: "a", title: "Alpha", start: at(2026, 8, 14, 9, 0), end: at(2026, 8, 14, 10, 0))
        let index = CalendarEventChip.index(
            [late, earlyB, earlyA],
            in: window(at(2026, 8, 10), at(2026, 8, 24)),
            calendar: calendar
        )
        let day = index[calendar.startOfDay(for: at(2026, 8, 14))] ?? []
        XCTAssertEqual(day.map(\.title), ["Alpha", "Beta", "Late"])
    }

    func testOrderingIsStableAcrossInputPermutations() {
        let events = [
            event(id: "a", title: "Alpha", start: at(2026, 8, 14, 9, 0), end: at(2026, 8, 14, 10, 0)),
            event(id: "b", title: "Beta", start: at(2026, 8, 14, 9, 0), end: at(2026, 8, 14, 10, 0)),
            event(id: "c", title: "Gamma", start: at(2026, 8, 14, 11, 0), end: at(2026, 8, 14, 12, 0)),
        ]
        let span = window(at(2026, 8, 10), at(2026, 8, 24))
        let forward = CalendarEventChip.index(events, in: span, calendar: calendar)
        let reversed = CalendarEventChip.index(events.reversed(), in: span, calendar: calendar)
        let key = calendar.startOfDay(for: at(2026, 8, 14))
        XCTAssertEqual(forward[key]?.map(\.id), reversed[key]?.map(\.id))
    }

    // MARK: - Indexing

    func testIndexBucketsChipsByDay() {
        let events = [
            event(id: "a", start: at(2026, 8, 12, 9, 0), end: at(2026, 8, 12, 10, 0)),
            event(id: "b", start: at(2026, 8, 13, 9, 0), end: at(2026, 8, 13, 10, 0)),
            event(id: "c", start: at(2026, 8, 13, 11, 0), end: at(2026, 8, 13, 12, 0)),
        ]
        let index = CalendarEventChip.index(
            events,
            in: window(at(2026, 8, 10), at(2026, 8, 24)),
            calendar: calendar
        )
        XCTAssertEqual(index[calendar.startOfDay(for: at(2026, 8, 12))]?.count, 1)
        XCTAssertEqual(index[calendar.startOfDay(for: at(2026, 8, 13))]?.count, 2)
        XCTAssertNil(index[calendar.startOfDay(for: at(2026, 8, 14))])
    }

    func testDayKeysAreStartOfDay() {
        let index = CalendarEventChip.index(
            [event(start: at(2026, 8, 14, 23, 30), end: at(2026, 8, 14, 23, 45))],
            in: window(at(2026, 8, 10), at(2026, 8, 24)),
            calendar: calendar
        )
        for key in index.keys {
            XCTAssertEqual(key, calendar.startOfDay(for: key))
        }
    }
}
