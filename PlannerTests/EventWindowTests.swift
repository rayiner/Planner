import XCTest
@testable import Planner

final class EventWindowTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar? = nil) -> Date {
        (calendar ?? self.calendar)
            .date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func weekday(of date: Date, calendar: Calendar) -> Int {
        calendar.component(.weekday, from: date)
    }

    func testWindowStartsAndEndsOnMonday() {
        let calendar = calendar
        // 2026-08-14 is a Friday.
        let window = EventWindow.current(now: date(2026, 8, 14), calendar: calendar)
        XCTAssertEqual(weekday(of: window.lowerBound, calendar: calendar), 2, "lower bound must be a Monday")
        XCTAssertEqual(weekday(of: window.upperBound, calendar: calendar), 2, "upper bound must be a Monday")
    }

    func testBoundsAreStartOfDay() {
        let calendar = calendar
        let window = EventWindow.current(now: date(2026, 8, 14), calendar: calendar)
        XCTAssertEqual(window.lowerBound, calendar.startOfDay(for: window.lowerBound))
        XCTAssertEqual(window.upperBound, calendar.startOfDay(for: window.upperBound))
    }

    func testSpansTwoMonthsBackAndThreeForward() {
        let calendar = calendar
        let now = date(2026, 8, 14)
        let window = EventWindow.current(now: now, calendar: calendar)

        // Two months back lands on 2026-06-14; its week starts Monday 2026-06-08.
        XCTAssertLessThanOrEqual(window.lowerBound, calendar.startOfDay(for: date(2026, 6, 14)))
        XCTAssertGreaterThan(window.lowerBound, calendar.startOfDay(for: date(2026, 6, 7)))

        // Three months forward lands on 2026-11-14; its whole week must be inside.
        XCTAssertGreaterThan(window.upperBound, calendar.startOfDay(for: date(2026, 11, 14)))
    }

    func testTodayIsAlwaysInsideTheWindow() {
        let calendar = calendar
        for day in 1...28 {
            let now = date(2026, 2, day)
            let window = EventWindow.current(now: now, calendar: calendar)
            XCTAssertTrue(
                window.contains(calendar.startOfDay(for: now)),
                "today must be inside the window (2026-02-\(day))"
            )
        }
    }

    /// Month arithmetic on the 31st has to survive landing in a short month.
    func testMonthEndsClampWithoutSkippingAMonth() {
        let calendar = calendar
        // 2026-12-31 minus two months is October 31; plus three is March 31.
        let window = EventWindow.current(now: date(2026, 12, 31), calendar: calendar)
        XCTAssertLessThanOrEqual(window.lowerBound, calendar.startOfDay(for: date(2026, 10, 31)))
        XCTAssertGreaterThan(window.upperBound, calendar.startOfDay(for: date(2027, 3, 31)))

        // 2026-03-31 minus two months must not fall through February into January.
        let short = EventWindow.current(now: date(2026, 3, 31), calendar: calendar)
        XCTAssertGreaterThan(short.lowerBound, calendar.startOfDay(for: date(2026, 1, 18)))
    }

    /// The bounds are start-of-day in local time, so a DST transition inside the
    /// span must not shift them off midnight or off Monday.
    func testSurvivesDaylightSavingTransition() {
        let calendar = calendar
        // US DST ends 2026-11-01; a window anchored in October spans it.
        let window = EventWindow.current(now: date(2026, 10, 15), calendar: calendar)
        XCTAssertEqual(weekday(of: window.lowerBound, calendar: calendar), 2)
        XCTAssertEqual(weekday(of: window.upperBound, calendar: calendar), 2)
        XCTAssertEqual(window.upperBound, calendar.startOfDay(for: window.upperBound))
    }

    func testWindowSlidesWithTheDay() {
        let calendar = calendar
        let monday = EventWindow.current(now: date(2026, 8, 17), calendar: calendar)
        let nextMonday = EventWindow.current(now: date(2026, 8, 24), calendar: calendar)
        XCTAssertEqual(
            calendar.dateComponents([.day], from: monday.lowerBound, to: nextMonday.lowerBound).day,
            7
        )
    }
}
