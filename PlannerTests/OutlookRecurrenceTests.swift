import XCTest
@testable import Planner

/// Ported from CalendarList's `recurrence.test.js`. Four of the six rule types
/// have no live-data coverage on the author's calendar (§8.6.7), so these are
/// the only thing standing behind them.
final class OutlookRecurrenceTests: XCTestCase {
    private typealias F = OutlookFixtures
    private let calendar = OutlookFixtures.calendar

    // MARK: - Weekly

    func testWeeklyOnOneDayRepeatsEveryWeek() {
        let master = F.master(
            F.at(2026, 1, 6, 10, 0),
            OutlookRecurrenceRule(pattern: .weekly, daysOfWeek: F.mask("0010000"))   // Tuesday
        )
        XCTAssertEqual(
            F.days(F.expand(master, from: F.at(2026, 1, 1), to: F.at(2026, 2, 1))),
            ["2026-01-06", "2026-01-13", "2026-01-20", "2026-01-27"]
        )
    }

    /// The fortnight is counted from the series start, not from the window.
    func testWeeklyIntervalKeepsAlignmentToTheSeriesStart() {
        let master = F.master(
            F.at(2026, 1, 6, 10, 0),
            OutlookRecurrenceRule(pattern: .weekly, interval: 2, daysOfWeek: F.mask("0010000"))
        )
        XCTAssertEqual(
            F.days(F.expand(master, from: F.at(2026, 8, 1), to: F.at(2026, 8, 31))),
            ["2026-08-04", "2026-08-18"],
            "counting fortnights from Jan 6 lands on the 4th and 18th, not the 11th and 25th"
        )
    }

    func testWeeklyCanSelectSeveralDaysInTheSameWeek() {
        let master = F.master(
            F.at(2026, 3, 2, 9, 0),
            OutlookRecurrenceRule(pattern: .weekly, daysOfWeek: F.mask("0101000"))   // Mon + Wed
        )
        XCTAssertEqual(
            F.days(F.expand(master, from: F.at(2026, 3, 1), to: F.at(2026, 3, 15))),
            ["2026-03-02", "2026-03-04", "2026-03-09", "2026-03-11"]
        )
    }

    // MARK: - Daily

    /// "Every weekday" arrives as a daily rule with a Mon–Fri mask, not a
    /// weekly rule — the mask has to be honoured on the daily path too.
    func testDailyCarryingAWeekdayMaskSkipsTheWeekend() {
        let master = F.master(
            F.at(2026, 3, 5, 9, 0),
            OutlookRecurrenceRule(pattern: .daily, daysOfWeek: F.mask("0111110"))
        )
        XCTAssertEqual(
            F.days(F.expand(master, from: F.at(2026, 3, 1), to: F.at(2026, 3, 11, 23, 59))),
            ["2026-03-05", "2026-03-06", "2026-03-09", "2026-03-10", "2026-03-11"]
        )
    }

    func testDailyWithoutAMaskRunsEveryDay() {
        let master = F.master(F.at(2026, 1, 5, 9, 0), OutlookRecurrenceRule(pattern: .daily))
        XCTAssertEqual(F.expand(master, from: F.at(2026, 1, 5), to: F.at(2026, 1, 9, 23, 59)).count, 5)
    }

    func testDailyIntervalSkipsDays() {
        let master = F.master(
            F.at(2026, 1, 5, 9, 0),
            OutlookRecurrenceRule(pattern: .daily, interval: 3)
        )
        XCTAssertEqual(
            F.days(F.expand(master, from: F.at(2026, 1, 1), to: F.at(2026, 1, 15))),
            ["2026-01-05", "2026-01-08", "2026-01-11", "2026-01-14"]
        )
    }

    // MARK: - Monthly

    func testAbsoluteMonthlyClampsToTheLastDayOfAShortMonth() {
        let master = F.master(
            F.at(2026, 1, 31, 9, 0),
            OutlookRecurrenceRule(pattern: .absoluteMonthly, dayOfMonth: 31)
        )
        XCTAssertEqual(
            F.days(F.expand(master, from: F.at(2026, 1, 1), to: F.at(2026, 4, 30, 23, 59))),
            ["2026-01-31", "2026-02-28", "2026-03-31", "2026-04-30"]
        )
    }

    func testRelativeMonthlyPicksTheNthWeekday() {
        let master = F.master(
            F.at(2026, 8, 12, 12, 0),
            OutlookRecurrenceRule(
                pattern: .relativeMonthly, interval: 3, ordinal: 2, daysOfWeek: F.mask("0001000")
            )
        )
        XCTAssertEqual(
            F.days(F.expand(master, from: F.at(2026, 8, 1), to: F.at(2027, 6, 1))),
            ["2026-08-12", "2026-11-11", "2027-02-10", "2027-05-12"],
            "second Wednesday, every third month"
        )
    }

    func testOrdinalFiveMeansTheLastMatchingWeekday() {
        let mondays = F.mask("0100000")
        // February 2026 starts on a Sunday and has exactly four Mondays.
        XCTAssertEqual(
            calendar.component(.day, from: OutlookRecurrence.nthWeekday(
                year: 2026, month: 2, mask: mondays, ordinal: 5, calendar: calendar
            )!),
            23
        )
        // March 2026 has five.
        XCTAssertEqual(
            calendar.component(.day, from: OutlookRecurrence.nthWeekday(
                year: 2026, month: 3, mask: mondays, ordinal: 5, calendar: calendar
            )!),
            30
        )
    }

    func testOrdinalPastTheEndOfTheMonthClampsToTheLast() {
        let mondays = F.mask("0100000")
        XCTAssertEqual(
            OutlookRecurrence.nthWeekday(year: 2026, month: 2, mask: mondays, ordinal: 5, calendar: calendar),
            OutlookRecurrence.nthWeekday(year: 2026, month: 2, mask: mondays, ordinal: 9, calendar: calendar)
        )
    }

    // MARK: - Yearly

    func testAbsoluteYearlyRepeatsOnceAYear() {
        let master = F.master(
            F.at(2026, 7, 4, 12, 0),
            OutlookRecurrenceRule(pattern: .absoluteYearly, monthNumber: 7, dayOfMonth: 4)
        )
        XCTAssertEqual(
            F.days(F.expand(master, from: F.at(2026, 1, 1), to: F.at(2028, 12, 31))),
            ["2026-07-04", "2027-07-04", "2028-07-04"]
        )
    }

    func testRelativeYearlyPicksTheNthWeekdayOfItsMonth() {
        let master = F.master(
            F.at(2026, 11, 26, 12, 0),
            OutlookRecurrenceRule(
                pattern: .relativeYearly, ordinal: 4, monthNumber: 11, daysOfWeek: F.mask("0000100")
            )
        )
        XCTAssertEqual(
            F.days(F.expand(master, from: F.at(2026, 1, 1), to: F.at(2028, 12, 31))),
            ["2026-11-26", "2027-11-25", "2028-11-23"],
            "fourth Thursday in November"
        )
    }

    // MARK: - Termination

    func testOccurrenceCountIsMeasuredFromTheSeriesStartNotTheWindow() {
        let master = F.master(
            F.at(2026, 1, 1, 9, 0),
            OutlookRecurrenceRule(pattern: .weekly, daysOfWeek: F.mask("0000100"), end: .after(4))
        )
        XCTAssertEqual(
            F.days(F.expand(master, from: F.at(2026, 1, 10), to: F.at(2026, 12, 31))),
            ["2026-01-15", "2026-01-22"],
            "Jan 1 and Jan 8 fall before the window but still consume two of the four"
        )
    }

    /// Outlook reports this Saturday series as ending "Fri Dec 26 at 7pm"; the
    /// half-day nudge recovers the Saturday it really ends on.
    func testSeriesEndDateShiftedBackByATimezoneStillIncludesItsFinalDay() {
        let master = F.master(
            F.at(2025, 12, 6, 10, 30),
            OutlookRecurrenceRule(
                pattern: .weekly,
                daysOfWeek: F.mask("0000001"),
                end: .on(F.at(2025, 12, 26, 19, 0))
            )
        )
        XCTAssertEqual(
            F.days(F.expand(master, from: F.at(2025, 12, 1), to: F.at(2026, 2, 1))),
            ["2025-12-06", "2025-12-13", "2025-12-20", "2025-12-27"]
        )
    }

    func testSeriesEndDateAlreadyAtLocalMidnightIsNotMoved() {
        let master = F.master(
            F.at(2025, 12, 6, 10, 30),
            OutlookRecurrenceRule(
                pattern: .weekly,
                daysOfWeek: F.mask("0000001"),
                end: .on(F.at(2025, 12, 20))
            )
        )
        XCTAssertEqual(
            F.days(F.expand(master, from: F.at(2025, 12, 1), to: F.at(2026, 2, 1))),
            ["2025-12-06", "2025-12-13", "2025-12-20"],
            "a boundary already at local midnight keeps its own day"
        )
    }

    func testSeriesThatEndedBeforeTheWindowYieldsNothing() {
        let master = F.master(
            F.at(2024, 1, 2, 10, 0),
            OutlookRecurrenceRule(
                pattern: .weekly, daysOfWeek: F.mask("0010000"), end: .on(F.at(2024, 3, 5))
            )
        )
        XCTAssertTrue(F.expand(master, from: F.at(2026, 1, 1), to: F.at(2026, 4, 1)).isEmpty)
    }

    func testUnboundedSeriesThatBeganYearsAgoStillReachesTheWindow() {
        let master = F.master(
            F.at(2018, 5, 7, 8, 45),
            OutlookRecurrenceRule(pattern: .relativeMonthly, ordinal: 1, daysOfWeek: F.mask("0100000"))
        )
        XCTAssertEqual(
            F.days(F.expand(master, from: F.at(2026, 8, 1), to: F.at(2026, 10, 26))),
            ["2026-08-03", "2026-09-07", "2026-10-05"]
        )
    }

    // MARK: - Time handling

    func testOccurrencesKeepTheirWallClockTimeAcrossADSTChange() {
        let master = F.master(
            F.at(2026, 3, 1, 9, 0),
            OutlookRecurrenceRule(pattern: .weekly, daysOfWeek: F.mask("1000000"))
        )
        let occurrences = F.expand(master, from: F.at(2026, 3, 1), to: F.at(2026, 3, 31))
        XCTAssertGreaterThanOrEqual(occurrences.count, 4)
        for occurrence in occurrences {
            XCTAssertEqual(
                calendar.component(.hour, from: occurrence.start), 9,
                "\(occurrence.start) should still be 9am local"
            )
        }
    }

    func testEventAlreadyUnderWayAtTheWindowStartIsIncluded() {
        let master = F.master(
            F.at(2026, 1, 5, 22, 0),
            OutlookRecurrenceRule(pattern: .weekly, daysOfWeek: F.mask("0100000")),
            durationMinutes: 240
        )
        let occurrences = F.expand(master, from: F.at(2026, 1, 6, 0, 30), to: F.at(2026, 1, 6, 23, 0))
        XCTAssertEqual(occurrences.count, 1)
        XCTAssertEqual(calendar.component(.day, from: occurrences[0].start), 5)
    }

    // MARK: - Degenerate input

    func testUnknownPatternStillYieldsItsFirstOccurrence() {
        let master = F.master(F.at(2026, 1, 6, 10, 0), OutlookRecurrenceRule(pattern: .unknown))
        XCTAssertEqual(
            F.days(F.expand(master, from: F.at(2026, 1, 1), to: F.at(2026, 2, 1))),
            ["2026-01-06"],
            "a series we cannot expand is better shown as one real event than as nothing"
        )
    }

    func testAnEmptyDayMaskIsTreatedAsUnspecifiedRatherThanNeverFiring() {
        let rule = OutlookRecurrenceRule(pattern: .weekly, daysOfWeek: DayMask())
        XCTAssertNil(rule.daysOfWeek)
        let master = F.master(F.at(2026, 1, 6, 10, 0), rule)
        XCTAssertEqual(
            F.days(F.expand(master, from: F.at(2026, 1, 1), to: F.at(2026, 2, 1))),
            ["2026-01-06", "2026-01-13", "2026-01-20", "2026-01-27"],
            "it should fall back to the anchor's weekday"
        )
    }

    func testIntervalIsFlooredAtOne() {
        XCTAssertEqual(OutlookRecurrenceRule(pattern: .daily, interval: 0).interval, 1)
        XCTAssertEqual(OutlookRecurrenceRule(pattern: .daily, interval: -5).interval, 1)
    }

    /// A daily series and a window centuries apart must terminate, not hang.
    func testExpansionIsBoundedBySlotCap() {
        let master = F.master(F.at(1900, 1, 1, 9, 0), OutlookRecurrenceRule(pattern: .daily))
        let occurrences = F.expand(master, from: F.at(2026, 1, 1), to: F.at(2026, 2, 1))
        XCTAssertTrue(occurrences.isEmpty, "the slot cap is reached long before 2026")
    }

    // MARK: - Enum decoding

    func testPatternCodesDecode() {
        XCTAssertEqual(OutlookRecurrenceRule.Pattern(outlookCode: "eRdp"), .daily)
        XCTAssertEqual(OutlookRecurrenceRule.Pattern(outlookCode: "eRwp"), .weekly)
        XCTAssertEqual(OutlookRecurrenceRule.Pattern(outlookCode: "eRrm"), .relativeMonthly)
        XCTAssertEqual(OutlookRecurrenceRule.Pattern(outlookCode: "eRam"), .absoluteMonthly)
        XCTAssertEqual(OutlookRecurrenceRule.Pattern(outlookCode: "eRry"), .relativeYearly)
        XCTAssertEqual(OutlookRecurrenceRule.Pattern(outlookCode: "eRay"), .absoluteYearly)
        XCTAssertEqual(OutlookRecurrenceRule.Pattern(outlookCode: "nope"), .unknown)
        XCTAssertEqual(OutlookRecurrenceRule.Pattern(outlookCode: nil), .unknown)
    }

    func testEndCodesDecode() {
        XCTAssertEqual(OutlookRecurrenceRule.End.code("eNEt", data: nil), .never)
        XCTAssertEqual(
            OutlookRecurrenceRule.End.code("eEDt", data: F.at(2026, 5, 1)),
            .on(F.at(2026, 5, 1))
        )
        XCTAssertEqual(OutlookRecurrenceRule.End.code("eENt", data: 6), .after(6))
        XCTAssertEqual(
            OutlookRecurrenceRule.End.code("eENt", data: NSNumber(value: 6)), .after(6)
        )
        XCTAssertEqual(
            OutlookRecurrenceRule.End.code("eEDt", data: nil), .never,
            "an until-date with no date is not a series that ends immediately"
        )
    }

    func testDayMaskAggregatesCoverTheirDays() {
        XCTAssertTrue(DayMask.weekdays.contains(weekday: 2))    // Monday
        XCTAssertFalse(DayMask.weekdays.contains(weekday: 1))   // Sunday
        XCTAssertTrue(DayMask.weekends.contains(weekday: 7))    // Saturday
        XCTAssertTrue(DayMask.weekends.contains(weekday: 1))
        for weekday in 1...7 {
            XCTAssertTrue(DayMask.allDays.contains(weekday: weekday))
        }
        XCTAssertFalse(DayMask.allDays.contains(weekday: 0), "out-of-range weekdays never match")
        XCTAssertFalse(DayMask.allDays.contains(weekday: 8))
    }
}
