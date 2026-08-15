import XCTest
@testable import Planner

/// Ported from CalendarList's `agenda.test.js`.
///
/// One deliberate divergence: `CalendarEvent.end` is **exclusive** throughout
/// Planner, where CalendarList stores an inclusive last day for all-day events
/// and converts back in its renderers. The all-day assertions below are
/// rewritten accordingly.
final class OutlookAgendaTests: XCTestCase {
    private typealias F = OutlookFixtures
    private let calendar = OutlookFixtures.calendar

    private var window: Range<Date> { F.at(2026, 1, 1)..<F.at(2026, 2, 28, 23, 59) }

    private func build(
        plain: [OutlookRawEvent] = [],
        masters: [OutlookRawEvent] = [],
        exceptions: [OutlookRawEvent] = [],
        in window: Range<Date>? = nil
    ) -> [CalendarEvent] {
        OutlookAgenda.build(
            OutlookSnapshot(
                calendarName: "Calendar",
                plain: plain,
                masters: masters,
                exceptions: exceptions
            ),
            in: window ?? self.window,
            calendar: calendar
        )
    }

    /// Weekly on Tuesdays, ending 27 January.
    private func weeklyMaster(exDates: [Date] = []) -> OutlookRawEvent {
        F.master(
            F.at(2026, 1, 6, 10, 0),
            OutlookRecurrenceRule(
                pattern: .weekly,
                daysOfWeek: F.mask("0010000"),
                end: .on(F.at(2026, 1, 27))
            ),
            subject: "Standup",
            exDates: exDates
        )
    }

    private func dayNumbers(_ events: [CalendarEvent]) -> [Int] {
        events.map { calendar.component(.day, from: $0.start) }
    }

    // MARK: - Sources

    func testAPlainEventPassesStraightThrough() {
        let events = build(plain: [F.plain(F.at(2026, 1, 5, 12, 0), F.at(2026, 1, 5, 13, 0))])
        XCTAssertEqual(events.count, 1)
        XCTAssertFalse(events[0].isRecurring)
        XCTAssertEqual(events[0].calendarName, "Calendar")
    }

    func testASeriesExpandsToOneEventPerOccurrence() {
        XCTAssertEqual(
            F.days(build(masters: [weeklyMaster()])),
            ["2026-01-06", "2026-01-13", "2026-01-20", "2026-01-27"]
        )
    }

    func testAMovedOccurrenceIsListedOnceAtItsNewTime() {
        let events = build(
            masters: [weeklyMaster()],
            exceptions: [F.exception(
                recurrenceId: F.at(2026, 1, 13, 10, 0),
                start: F.at(2026, 1, 15, 16, 0),
                end: F.at(2026, 1, 15, 16, 30)
            )]
        )
        XCTAssertEqual(dayNumbers(events), [6, 15, 20, 27])
        XCTAssertTrue(
            events.first { calendar.component(.day, from: $0.start) == 15 }?.isRescheduled ?? false
        )
    }

    func testACancelledOccurrenceDisappearsRatherThanBeingListed() {
        let events = build(
            masters: [weeklyMaster()],
            exceptions: [F.exception(
                recurrenceId: F.at(2026, 1, 20, 10, 0),
                start: F.at(2026, 1, 20, 10, 0),
                end: F.at(2026, 1, 20, 10, 30),
                subject: "Canceled: Standup"
            )]
        )
        XCTAssertEqual(dayNumbers(events), [6, 13, 27])
    }

    func testBothCancellationSpellingsAreRecognised() {
        XCTAssertTrue(OutlookAgenda.isCancelled("Canceled: Standup"))
        XCTAssertTrue(OutlookAgenda.isCancelled("Cancelled: Standup"))
        XCTAssertTrue(OutlookAgenda.isCancelled("CANCELED: Standup"))
        XCTAssertFalse(OutlookAgenda.isCancelled("Standup"))
        XCTAssertFalse(
            OutlookAgenda.isCancelled("Discuss cancelled: contract"),
            "the prefix has to lead, or ordinary subjects vanish"
        )
    }

    /// A deleted occurrence has no event record and no exception — only an
    /// EXDATE — so expansion would otherwise put it back.
    func testADeletedOccurrenceRecordedOnlyAsAnExDateIsDropped() {
        let events = build(masters: [weeklyMaster(exDates: [F.at(2026, 1, 13, 10, 0)])])
        XCTAssertEqual(dayNumbers(events), [6, 20, 27])
    }

    func testAnExDateAndAnExceptionCanRetireDifferentSlotsOfOneSeries() {
        let events = build(
            masters: [weeklyMaster(exDates: [F.at(2026, 1, 6, 10, 0)])],
            exceptions: [F.exception(
                recurrenceId: F.at(2026, 1, 27, 10, 0),
                start: F.at(2026, 1, 27, 10, 0),
                end: F.at(2026, 1, 27, 10, 30),
                subject: "Canceled: Standup"
            )]
        )
        XCTAssertEqual(dayNumbers(events), [13, 20])
    }

    /// This is why the exception query is not bounded by the window.
    func testAnExceptionMovedOutsideTheWindowStillVacatesItsSlot() {
        let events = build(
            masters: [weeklyMaster()],
            exceptions: [F.exception(
                recurrenceId: F.at(2026, 1, 20, 10, 0),
                start: F.at(2026, 6, 1, 10, 0),
                end: F.at(2026, 6, 1, 10, 30)
            )]
        )
        XCTAssertEqual(dayNumbers(events), [6, 13, 27])
    }

    func testAnExceptionOfAnUnknownSeriesIsStillListed() {
        let events = build(
            exceptions: [F.exception(
                recurrenceId: F.at(2026, 1, 20, 10, 0),
                start: F.at(2026, 1, 20, 10, 0),
                end: F.at(2026, 1, 20, 10, 30),
                uid: "not-in-this-fetch"
            )]
        )
        XCTAssertEqual(dayNumbers(events), [20])
    }

    // MARK: - Ordering

    func testEventsAreOrderedByStartAcrossAllSources() {
        let events = build(
            plain: [
                F.plain(F.at(2026, 1, 14, 9, 0), F.at(2026, 1, 14, 10, 0), subject: "Later", id: "p1"),
                F.plain(F.at(2026, 1, 2, 9, 0), F.at(2026, 1, 2, 10, 0), subject: "Earlier", id: "p2"),
            ],
            masters: [weeklyMaster()]
        )
        XCTAssertEqual(events.map(\.start), events.map(\.start).sorted())
    }

    // MARK: - All-day handling

    /// Outlook stores an all-day event as UTC midnight, which arrives as 8pm
    /// the evening before in US Eastern. Left alone it is listed a day early.
    func testAnAllDayEventSnapsToTheDayItActuallyFallsOn() {
        let events = build(plain: [F.plain(
            F.at(2026, 1, 30, 20, 0),
            F.at(2026, 1, 31, 20, 0),
            subject: "Brief due",
            isAllDay: true
        )])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(calendar.component(.day, from: events[0].start), 31, "listed on the 31st")
        XCTAssertEqual(calendar.component(.hour, from: events[0].start), 0, "snapped to midnight")
        XCTAssertEqual(
            events[0].end, F.at(2026, 2, 1),
            "exclusive end: a one-day event ends at the start of the next day"
        )
    }

    func testAnAllDayEventAlreadyAtLocalMidnightIsNotMoved() {
        let events = build(plain: [F.plain(
            F.at(2026, 1, 31), F.at(2026, 2, 1), subject: "Brief due", isAllDay: true
        )])
        XCTAssertEqual(events[0].start, F.at(2026, 1, 31))
        XCTAssertEqual(events[0].end, F.at(2026, 2, 1))
    }

    func testAMultiDayAllDayRunCoversEveryDay() {
        let events = build(plain: [F.plain(
            F.at(2026, 1, 13, 20, 0),
            F.at(2026, 1, 28, 20, 0),
            subject: "Trial",
            isAllDay: true
        )])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].start, F.at(2026, 1, 14))
        XCTAssertEqual(events[0].end, F.at(2026, 1, 29), "exclusive end, so the 28th is included")
    }

    /// The whole point of the snapping: the chips must land on the right days.
    func testAllDayExpansionReachesTheRightChips() {
        let events = build(plain: [F.plain(
            F.at(2026, 1, 13, 20, 0),
            F.at(2026, 1, 16, 20, 0),
            subject: "Trial",
            isAllDay: true
        )])
        let chips = CalendarEventChip.chips(for: events[0], in: window, calendar: calendar)
        XCTAssertEqual(F.days(chips.map(\.day)), ["2026-01-14", "2026-01-15", "2026-01-16"])
        XCTAssertTrue(chips.allSatisfy { $0.startTime == nil })
    }

    /// The storage convention bites a *series* twice: an anchor rendered as
    /// Friday 8pm ET generates Friday slots for a Saturday series, and the
    /// per-occurrence nudge then lands every one of them on Sunday.
    func testAnAllDayWeeklySeriesLandsOnItsOwnWeekday() {
        // Saturdays, stored as UTC midnight = Friday 8pm US Eastern.
        let master = F.master(
            F.at(2026, 1, 2, 20, 0),
            OutlookRecurrenceRule(pattern: .weekly, daysOfWeek: F.mask("0000001")),
            durationMinutes: 1440,
            subject: "Long run",
            isAllDay: true
        )
        let events = build(masters: [master], in: F.at(2026, 1, 1)..<F.at(2026, 2, 1))
        XCTAssertEqual(
            F.days(events),
            ["2026-01-03", "2026-01-10", "2026-01-17", "2026-01-24", "2026-01-31"]
        )
        XCTAssertTrue(
            events.allSatisfy { calendar.component(.hour, from: $0.start) == 0 },
            "occurrences snap to local midnight"
        )
        XCTAssertEqual(events[0].end, F.at(2026, 1, 4), "exclusive end on the next day")
    }

    func testAnAllDayMonthlySeriesKeepsItsDayOfMonth() {
        // The 31st of each month, stored as UTC midnight = the 30th 8pm ET.
        // Un-nudged this expands on the 30th/31st boundary and drifts onto the
        // 1st of the next month.
        let master = F.master(
            F.at(2025, 12, 30, 20, 0),
            OutlookRecurrenceRule(pattern: .absoluteMonthly, dayOfMonth: 31),
            durationMinutes: 1440,
            subject: "Invoice",
            isAllDay: true
        )
        let events = build(masters: [master], in: F.at(2025, 12, 1)..<F.at(2026, 3, 1))
        XCTAssertEqual(
            F.days(events),
            ["2025-12-31", "2026-01-31", "2026-02-28"],
            "short months clamp; nothing lands on the 1st"
        )
    }

    /// Recurrence ids and EXDATEs share the UTC-midnight convention, so they
    /// must keep claiming their slots after the anchor is nudged.
    func testAnAllDaySeriesExceptionAndExDateStillClaimTheirSlots() {
        let master = F.master(
            F.at(2026, 1, 2, 20, 0),
            OutlookRecurrenceRule(pattern: .weekly, daysOfWeek: F.mask("0000001")),
            durationMinutes: 1440,
            subject: "Long run",
            isAllDay: true,
            exDates: [F.at(2026, 1, 16, 20, 0)]   // retires the 17 Jan slot
        )
        let events = build(
            masters: [master],
            exceptions: [F.exception(
                recurrenceId: F.at(2026, 1, 9, 20, 0),   // the 10 Jan slot
                start: F.at(2026, 1, 12, 10, 0),
                end: F.at(2026, 1, 12, 10, 30),
                subject: "Long run"
            )],
            in: F.at(2026, 1, 1)..<F.at(2026, 2, 1)
        )
        XCTAssertEqual(
            F.days(events),
            ["2026-01-03", "2026-01-12", "2026-01-24", "2026-01-31"],
            "the moved slot is listed once at its new day; the EXDATE slot not at all"
        )
    }

    // MARK: - Identity

    func testOccurrenceIdentitiesAreDistinctAndStable() {
        let first = build(masters: [weeklyMaster()])
        let second = build(masters: [weeklyMaster()])
        XCTAssertEqual(Set(first.map(\.id)).count, first.count, "each occurrence needs its own id")
        XCTAssertEqual(first.map(\.id), second.map(\.id), "ids must survive a refetch")
    }

    // MARK: - Window

    func testEventsOutsideTheWindowAreExcluded() {
        let events = build(
            plain: [
                F.plain(F.at(2025, 6, 1, 9, 0), F.at(2025, 6, 1, 10, 0), subject: "Old", id: "p1"),
                F.plain(F.at(2027, 6, 1, 9, 0), F.at(2027, 6, 1, 10, 0), subject: "New", id: "p2"),
                F.plain(F.at(2026, 1, 5, 9, 0), F.at(2026, 1, 5, 10, 0), subject: "Now", id: "p3"),
            ]
        )
        XCTAssertEqual(events.map(\.title), ["Now"])
    }

    func testAPlainEventStraddlingTheWindowStartIsIncluded() {
        let events = build(
            plain: [F.plain(F.at(2025, 12, 31, 22, 0), F.at(2026, 1, 1, 2, 0), subject: "Overnight")],
            in: F.at(2026, 1, 1)..<F.at(2026, 2, 1)
        )
        XCTAssertEqual(events.map(\.title), ["Overnight"], "overlap, not containment")
    }

    func testAnEmptySnapshotProducesNoEvents() {
        XCTAssertTrue(build().isEmpty)
    }
}
