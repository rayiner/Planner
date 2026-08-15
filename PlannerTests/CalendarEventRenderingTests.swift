import XCTest
@testable import Planner

/// How events sit in the grid alongside deadlines.
@MainActor
final class CalendarEventRenderingTests: XCTestCase {
    private func makeView(weeks: Int = 4) -> WeekCalendarView {
        let view = WeekCalendarView(frame: NSRect(x: 0, y: 0, width: 720, height: 520))
        view.test_setWeekCount(weeks)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func event(
        _ title: String,
        day: Date,
        hour: Int? = 9,
        isAllDay: Bool = false,
        id: String = UUID().uuidString
    ) -> CalendarEventChip {
        let start = hour.flatMap {
            Calendar.current.date(bySettingHour: $0, minute: 0, second: 0, of: day)
        }
        return CalendarEventChip(
            id: id,
            title: title,
            day: Calendar.current.startOfDay(for: day),
            startTime: isAllDay ? nil : start,
            endTime: isAllDay ? nil : start?.addingTimeInterval(3600),
            isAllDay: isAllDay,
            continuesFromPreviousDay: false,
            continuesToNextDay: false,
            location: nil,
            organizer: nil,
            calendarName: "Work",
            isRecurring: false,
            isRescheduled: false
        )
    }

    private func task(_ title: String, day: Date) -> TaskDeadlineChip {
        TaskDeadlineChip(uuid: UUID(), title: title, day: day, isCompleted: false)
    }

    // MARK: - Placement

    func testEventsAppearOnTheirOwnDay() {
        let view = makeView()
        let day = view.test_days[3]
        view.events = [event("Standup", day: day)]

        XCTAssertEqual(view.test_visibleEvents(at: 3).map(\.title), ["Standup"])
        XCTAssertTrue(view.test_visibleEvents(at: 4).isEmpty)
    }

    /// A retitled event keeps its id across refreshes, so the row must update
    /// in place rather than only when the event set changes.
    func testEventRowUpdatesInPlaceWhenTitleChangesUnderTheSameID() {
        let view = makeView()
        let day = view.test_days[3]
        view.events = [event("Standup", day: day, id: "e1")]
        XCTAssertEqual(view.test_eventToolTip(at: 3, event: 0)?.contains("Standup"), true)

        view.events = [event("Weekly sync", day: day, id: "e1")]

        XCTAssertEqual(view.test_visibleEvents(at: 3).map(\.title), ["Weekly sync"])
        XCTAssertEqual(view.test_eventToolTip(at: 3, event: 0)?.contains("Weekly sync"), true)
        XCTAssertEqual(view.test_eventAccessibility(at: 3, event: 0)?.label?.contains("Weekly sync"), true)
    }

    /// This is a task planner: a meeting-heavy day must not push a deadline out
    /// of sight.
    func testTasksAreLaidOutAboveEvents() {
        let view = makeView()
        let day = view.test_days[3]
        view.deadlines = [task("Brief due", day: day)]
        view.events = [event("Standup", day: day)]
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.test_rowKinds(at: 3), ["task", "event"])
        let taskFrame = view.test_chipFrame(at: 3, chip: 0)
        let eventFrame = view.test_eventRowFrame(at: 3, event: 0)
        XCTAssertNotNil(taskFrame)
        XCTAssertNotNil(eventFrame)
        XCTAssertLessThan(taskFrame!.minY, eventFrame!.minY, "the task row must sit above the event")
    }

    func testEventRowsAreShorterThanTaskChips() {
        let view = makeView()
        let day = view.test_days[3]
        view.deadlines = [task("Brief due", day: day)]
        view.events = [event("Standup", day: day)]
        view.layoutSubtreeIfNeeded()

        XCTAssertLessThan(
            view.test_eventRowFrame(at: 3, event: 0)!.height,
            view.test_chipFrame(at: 3, chip: 0)!.height
        )
    }

    func testRowsDoNotOverlap() {
        let view = makeView()
        let day = view.test_days[3]
        view.deadlines = [task("A", day: day), task("B", day: day)]
        view.events = [event("C", day: day), event("D", day: day)]
        view.layoutSubtreeIfNeeded()

        var frames = (0..<view.test_visibleChips(at: 3).count).compactMap {
            view.test_chipFrame(at: 3, chip: $0)
        }
        frames += (0..<view.test_visibleEvents(at: 3).count).compactMap {
            view.test_eventRowFrame(at: 3, event: $0)
        }
        let sorted = frames.sorted { $0.minY < $1.minY }
        for (above, below) in zip(sorted, sorted.dropFirst()) {
            XCTAssertLessThanOrEqual(above.maxY, below.minY, "\(above) overlaps \(below)")
        }
    }

    // MARK: - Overflow

    /// One `+K more` covers both kinds; two counters would be nonsense.
    func testOverflowCountsHiddenTasksAndEventsTogether() {
        let view = makeView()
        let day = view.test_days[3]
        view.deadlines = (0..<4).map { task("Task \($0)", day: day) }
        view.events = (0..<6).map { event("Event \($0)", day: day, id: "e\($0)") }
        view.layoutSubtreeIfNeeded()

        let shown = view.test_visibleChips(at: 3).count + view.test_visibleEvents(at: 3).count
        XCTAssertEqual(shown + view.test_overflowCount(at: 3), 10)
        XCTAssertGreaterThan(view.test_overflowCount(at: 3), 0)
    }

    func testEventsOverflowBeforeTasksDo() {
        let view = makeView()
        let day = view.test_days[3]
        view.deadlines = (0..<2).map { task("Task \($0)", day: day) }
        view.events = (0..<8).map { event("Event \($0)", day: day, id: "e\($0)") }
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.test_visibleChips(at: 3).count, 2, "both deadlines must survive")
        XCTAssertGreaterThan(view.test_overflowCount(at: 3), 0)
    }

    /// A half-height weekend row barely fits one line; showing the row matters
    /// more than showing the count.
    func testAWeekendRowStillShowsSomething() {
        let view = makeView()
        let saturday = view.test_days[5]
        XCTAssertTrue(view.test_isWeekend(at: 5))
        view.deadlines = [task("Weekend task", day: saturday)]
        view.events = (0..<3).map { event("Event \($0)", day: saturday, id: "w\($0)") }
        view.layoutSubtreeIfNeeded()

        let shown = view.test_visibleChips(at: 5).count + view.test_visibleEvents(at: 5).count
        XCTAssertGreaterThanOrEqual(shown, 1)
        XCTAssertEqual(shown + view.test_overflowCount(at: 5), 4)
    }

    func testAnEventOnlyDayStillRenders() {
        let view = makeView()
        let day = view.test_days[3]
        view.events = [event("Standup", day: day)]
        view.layoutSubtreeIfNeeded()

        XCTAssertTrue(view.test_visibleChips(at: 3).isEmpty)
        XCTAssertEqual(view.test_visibleEvents(at: 3).count, 1)
        XCTAssertEqual(view.test_overflowCount(at: 3), 0)
    }

    // MARK: - Interaction

    /// `PlannerSelection` holds a node or a day, and an event is neither.
    func testClickingAnEventSelectsItsDayAndNeverATask() {
        let view = makeView()
        let recorder = EventRecordingDelegate()
        view.delegate = recorder
        let day = view.test_days[3]
        view.events = [event("Standup", day: day)]
        view.layoutSubtreeIfNeeded()

        view.test_clickEvent(at: 3, event: 0)

        XCTAssertTrue(recorder.taskIDs.isEmpty, "an event is not a selectable node")
        XCTAssertEqual(recorder.days.count, 1)
        XCTAssertTrue(Calendar.current.isDate(recorder.days[0], inSameDayAs: day))
        XCTAssertTrue(recorder.weekStarts.isEmpty)
    }

    func testAnEventRowIsHitTestable() {
        let view = makeView()
        let day = view.test_days[3]
        view.deadlines = [task("Brief due", day: day)]
        view.events = [event("Standup", day: day)]
        view.layoutSubtreeIfNeeded()
        XCTAssertNotNil(view.test_eventRowFrame(at: 3, event: 0))
    }

    // MARK: - Accessibility and tooltips

    func testAnEventRowIsStaticTextNotAButton() {
        let view = makeView()
        let day = view.test_days[3]
        view.events = [event("Standup", day: day)]
        view.layoutSubtreeIfNeeded()

        let accessibility = view.test_eventAccessibility(at: 3, event: 0)
        XCTAssertEqual(accessibility?.role, .staticText)
        XCTAssertTrue(accessibility?.label?.hasSuffix("Event") ?? false, "\(accessibility as Any)")
        XCTAssertTrue(accessibility?.label?.contains("Standup") ?? false)
    }

    func testAnEventRowCarriesTheFullDetailAsATooltip() {
        let view = makeView()
        let day = view.test_days[3]
        view.events = [event("Standup", day: day)]
        view.layoutSubtreeIfNeeded()

        let tooltip = view.test_eventToolTip(at: 3, event: 0) ?? ""
        XCTAssertTrue(tooltip.contains("Standup"), tooltip)
        XCTAssertTrue(tooltip.contains("Work"), tooltip)
    }

    // MARK: - Updates

    func testClearingEventsRemovesTheirRows() {
        let view = makeView()
        let day = view.test_days[3]
        view.events = [event("Standup", day: day)]
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.test_visibleEvents(at: 3).count, 1)

        view.events = []
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.test_visibleEvents(at: 3).isEmpty)
        XCTAssertNil(view.test_eventRowFrame(at: 3, event: 0))
    }

    func testChangingDeadlinesLeavesEventsAlone() {
        let view = makeView()
        let day = view.test_days[3]
        view.events = [event("Standup", day: day)]
        view.deadlines = [task("Brief due", day: day)]
        view.layoutSubtreeIfNeeded()

        view.deadlines = [task("Brief due", day: day), task("Second", day: day)]
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.test_visibleEvents(at: 3).map(\.title), ["Standup"])
    }

    func testEventsSurviveAWeekCountChange() {
        let view = makeView()
        let day = view.test_days[3]
        view.events = [event("Standup", day: day)]
        view.test_setWeekCount(6)
        view.layoutSubtreeIfNeeded()

        let index = view.test_days.firstIndex { Calendar.current.isDate($0, inSameDayAs: day) }
        XCTAssertNotNil(index)
        XCTAssertEqual(view.test_visibleEvents(at: index!).map(\.title), ["Standup"])
    }
}

private final class EventRecordingDelegate: WeekCalendarViewDelegate {
    var taskIDs: [UUID] = []
    var days: [Date] = []
    var weekStarts: [Date] = []

    func weekCalendar(_ view: WeekCalendarView, didSelectTaskID uuid: UUID) { taskIDs.append(uuid) }
    func weekCalendar(_ view: WeekCalendarView, didSelectDay date: Date) { days.append(date) }
    func weekCalendar(_ view: WeekCalendarView, didChangeVisibleWeekStart date: Date) {
        weekStarts.append(date)
    }
    func weekCalendar(_ view: WeekCalendarView, didChangeVisibleWeekCount count: Int) {}
}
