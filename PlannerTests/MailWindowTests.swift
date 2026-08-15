import XCTest
@testable import Planner

final class MailWindowTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    /// 2026-08-07 06:53:20 in New York — mid-morning, so a window that failed
    /// to snap to day boundaries would show it.
    private let anchor = Date(timeIntervalSince1970: 1_786_100_000)

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: anchor))!
    }

    // MARK: - Shape

    func testDefaultWindowIsThreeWholeDaysEndingTomorrow() {
        let window = MailWindow.current(now: anchor, calendar: calendar)
        XCTAssertEqual(window.lowerBound, day(-2))
        XCTAssertEqual(window.upperBound, day(1))
    }

    func testOneDayWindowIsTodayOnly() {
        let window = MailWindow.current(days: 1, now: anchor, calendar: calendar)
        XCTAssertEqual(window.lowerBound, day(0))
        XCTAssertEqual(window.upperBound, day(1))
    }

    func testSevenDayWindowReachesBackSixDays() {
        let window = MailWindow.current(days: 7, now: anchor, calendar: calendar)
        XCTAssertEqual(window.lowerBound, day(-6))
        XCTAssertEqual(window.upperBound, day(1))
    }

    func testWindowIsClosedOpenAndContainsThisInstant() {
        let window = MailWindow.current(now: anchor, calendar: calendar)
        XCTAssertTrue(window.contains(anchor))
        XCTAssertFalse(window.contains(window.upperBound))
        XCTAssertTrue(window.contains(window.lowerBound))
    }

    /// The window edges are start-of-day in the *display* calendar, so a message
    /// received at 00:30 local time is inside today rather than yesterday.
    func testWindowEdgesAreLocalMidnight() {
        let window = MailWindow.current(now: anchor, calendar: calendar)
        let components = calendar.dateComponents([.hour, .minute, .second], from: window.lowerBound)
        XCTAssertEqual(components.hour, 0)
        XCTAssertEqual(components.minute, 0)
        XCTAssertEqual(components.second, 0)
    }

    // MARK: - Clamping

    func testDaysBelowMinimumClampUp() {
        let window = MailWindow.current(days: 0, now: anchor, calendar: calendar)
        XCTAssertEqual(window.lowerBound, day(0))
    }

    func testDaysAboveMaximumClampDown() {
        let window = MailWindow.current(days: 99, now: anchor, calendar: calendar)
        XCTAssertEqual(window.lowerBound, day(-6))
    }

    func testNegativeDaysClampUpRatherThanInvertingTheRange() {
        let window = MailWindow.current(days: -5, now: anchor, calendar: calendar)
        XCTAssertLessThanOrEqual(window.lowerBound, window.upperBound)
        XCTAssertEqual(window.lowerBound, day(0))
    }

    // MARK: - Defaults

    private func defaults(_ value: Int?) -> UserDefaults {
        let suite = UserDefaults(suiteName: "MailWindowTests.\(UUID().uuidString)")!
        if let value { suite.set(value, forKey: MailWindow.daysDefaultsKey) }
        return suite
    }

    func testUnsetDefaultsGiveTheDefaultWindow() {
        XCTAssertEqual(MailWindow.days(from: defaults(nil)), MailWindow.defaultDays)
    }

    func testStoredDaysAreHonoured() {
        XCTAssertEqual(MailWindow.days(from: defaults(5)), 5)
    }

    /// A hand-edited `defaults write` should narrow the sweep, never break it.
    func testOutOfRangeStoredDaysClampRatherThanThrow() {
        XCTAssertEqual(MailWindow.days(from: defaults(400)), MailWindow.maximumDays)
        XCTAssertEqual(MailWindow.days(from: defaults(-3)), MailWindow.minimumDays)
    }

    // MARK: - Expiry

    func testExpiryIsTheMorningAfterTheLastDayTheMessageSurvives() {
        // Received today, 3-day window: today, tomorrow, the day after — so it
        // is gone on the fourth morning.
        let expiry = MailWindow.expiryDay(for: anchor, days: 3, calendar: calendar)
        XCTAssertEqual(expiry, day(3))
    }

    func testExpiryOfTheOldestMessageInTheWindowIsTomorrow() {
        let oldest = calendar.date(byAdding: .hour, value: 9, to: day(-2))!
        let expiry = MailWindow.expiryDay(for: oldest, days: 3, calendar: calendar)
        XCTAssertEqual(expiry, day(1))
        XCTAssertEqual(expiry, MailWindow.current(days: 3, now: anchor, calendar: calendar).upperBound)
    }

    func testExpiryIgnoresTimeOfDay() {
        let morning = calendar.date(byAdding: .hour, value: 1, to: day(0))!
        let evening = calendar.date(byAdding: .hour, value: 23, to: day(0))!
        XCTAssertEqual(
            MailWindow.expiryDay(for: morning, days: 3, calendar: calendar),
            MailWindow.expiryDay(for: evening, days: 3, calendar: calendar)
        )
    }
}
