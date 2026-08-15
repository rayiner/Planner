import XCTest
@testable import Planner

@MainActor
final class EventLabelsTests: XCTestCase {
    private let calendar = OutlookFixtures.calendar

    private func chip(
        title: String = "Design review",
        start: Date? = OutlookFixtures.at(2026, 8, 14, 9, 30),
        end: Date? = OutlookFixtures.at(2026, 8, 14, 10, 0),
        isAllDay: Bool = false,
        continuesFrom: Bool = false,
        continuesTo: Bool = false,
        location: String? = nil,
        organizer: String? = nil,
        calendarName: String? = nil,
        isRecurring: Bool = false,
        isRescheduled: Bool = false
    ) -> CalendarEventChip {
        CalendarEventChip(
            id: "e1|2026-8-14",
            title: title,
            day: OutlookFixtures.at(2026, 8, 14),
            startTime: start,
            endTime: end,
            isAllDay: isAllDay,
            continuesFromPreviousDay: continuesFrom,
            continuesToNextDay: continuesTo,
            location: location,
            organizer: organizer,
            calendarName: calendarName,
            isRecurring: isRecurring,
            isRescheduled: isRescheduled
        )
    }

    // MARK: - Grid label

    /// Planner is not a calendar: the grid shows the subject and nothing else.
    func testTheGridLabelIsJustTheSubject() {
        XCTAssertEqual(EventLabels.title(for: chip()), "Design review")
        XCTAssertEqual(EventLabels.title(for: chip(isAllDay: true)), "Design review")
        XCTAssertEqual(
            EventLabels.title(for: chip(start: nil, end: nil, continuesFrom: true)),
            "Design review"
        )
    }

    /// The detail still exists — it just lives where there is room for it.
    func testTheTimeSurvivesInTheTooltipAndSpokenLabel() {
        let subject = chip()
        XCTAssertTrue(EventLabels.tooltip(for: subject).contains(" to "))
        XCTAssertTrue(EventLabels.accessibilityLabel(for: subject).contains(" to "))
    }









    // MARK: - Tooltip

    func testTheTooltipCarriesWhatTheGridCannotShow() {
        let tooltip = EventLabels.tooltip(for: chip(
            location: "Room 4",
            organizer: "someone@example.com",
            calendarName: "Work",
            isRecurring: true
        ))
        XCTAssertTrue(tooltip.contains("Design review"), tooltip)
        XCTAssertTrue(tooltip.contains("Room 4"), tooltip)
        XCTAssertTrue(tooltip.contains("someone@example.com"), tooltip)
        XCTAssertTrue(tooltip.contains("Work"), tooltip)
        XCTAssertTrue(tooltip.contains("Repeating"), tooltip)
    }

    func testTheTooltipOmitsAbsentDetailRatherThanShowingBlanks() {
        let tooltip = EventLabels.tooltip(for: chip())
        XCTAssertEqual(tooltip.split(separator: "\n").count, 2, tooltip)
        XCTAssertFalse(tooltip.contains("Repeating"), tooltip)
        XCTAssertFalse(tooltip.contains("Moved"), tooltip)
    }

    func testAMovedOccurrenceIsMarked() {
        let tooltip = EventLabels.tooltip(for: chip(isRecurring: true, isRescheduled: true))
        XCTAssertTrue(tooltip.contains("Moved"), tooltip)
    }

    func testAnAllDayTooltipSaysAllDay() {
        XCTAssertTrue(EventLabels.tooltip(for: chip(isAllDay: true)).contains("All day"))
    }

    func testAMultiDayAllDayTooltipSaysItContinues() {
        let tooltip = EventLabels.tooltip(for: chip(isAllDay: true, continuesTo: true))
        XCTAssertTrue(tooltip.contains("continues"), tooltip)
    }

    // MARK: - Accessibility

    /// The leading dot is the only visual cue that this is not a task, and it
    /// says nothing aloud — so the word has to be in the label.
    func testTheAccessibilityLabelAlwaysEndsInEvent() {
        XCTAssertTrue(EventLabels.accessibilityLabel(for: chip()).hasSuffix("Event"))
        XCTAssertTrue(EventLabels.accessibilityLabel(for: chip(isAllDay: true)).hasSuffix("Event"))
        XCTAssertTrue(
            EventLabels.accessibilityLabel(for: chip(start: nil, end: nil, continuesFrom: true))
                .hasSuffix("Event")
        )
    }

    func testTheAccessibilityLabelReadsAsARange() {
        let label = EventLabels.accessibilityLabel(for: chip(calendarName: "Work"))
        XCTAssertTrue(label.contains(" to "), label)
        XCTAssertTrue(label.contains("Design review"), label)
        XCTAssertTrue(label.contains("Work"), label)
    }

    func testAZeroLengthEventReadsAsASingleTime() {
        let instant = OutlookFixtures.at(2026, 8, 14, 9, 30)
        let label = EventLabels.accessibilityLabel(for: chip(start: instant, end: instant))
        XCTAssertFalse(label.contains(" to "), label)
    }

    func testAContinuationDaySaysSoRatherThanInventingATime() {
        let label = EventLabels.accessibilityLabel(
            for: chip(start: nil, end: nil, continuesFrom: true)
        )
        XCTAssertTrue(label.contains("Continues"), label)
    }
}
