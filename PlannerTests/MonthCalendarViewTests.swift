import XCTest
@testable import Planner

@MainActor
final class CalendarMonthTests: XCTestCase {
    func testEndOfMonthIsStartOfNextMonth() {
        let calendar = utcCalendar
        let august = date(year: 2026, month: 8, day: 13, calendar: calendar)
        XCTAssertEqual(
            calendar.endOfMonth(for: august),
            calendar.startOfMonth(for: date(year: 2026, month: 9, day: 1, calendar: calendar))
        )
    }

    func testMonthYearString() {
        var calendar = utcCalendar
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let august = date(year: 2026, month: 8, day: 13, calendar: calendar)
        XCTAssertEqual(calendar.monthYearString(for: august), "August 2026")
    }

    func testDaysInMonthGridIsAlways42AndRespectsFirstWeekday() {
        var calendar = utcCalendar
        calendar.firstWeekday = 2
        let august = date(year: 2026, month: 8, day: 15, calendar: calendar)
        let days = calendar.daysInMonthGrid(for: august)
        XCTAssertEqual(days.count, 42)
        XCTAssertEqual(calendar.component(.weekday, from: days[0]), 2)
        XCTAssertEqual(days[0], calendar.startOfDay(for: days[0]))
        XCTAssertEqual(days[41], calendar.startOfDay(for: days[41]))
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 1
        return calendar
    }

    private func date(year: Int, month: Int, day: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 15))!
    }
}

@MainActor
final class MonthCalendarViewTests: XCTestCase {
    func testGridIsAlwaysSevenBySixAndWeekdaysFollowFirstWeekday() {
        let view = makeView()
        let calendar = Calendar.current
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        let expected = Array(symbols[first...]) + Array(symbols[..<first])

        XCTAssertEqual(view.test_dayCount, 42)
        XCTAssertEqual(view.test_days.count, 42)
        XCTAssertEqual(view.test_weekdaySymbols, expected)
        XCTAssertEqual(view.test_days, calendar.daysInMonthGrid(for: view.visibleMonth))
        XCTAssertEqual(calendar.component(.weekday, from: view.test_days[0]), calendar.firstWeekday)
        XCTAssertEqual(
            view.test_weekdaySymbols[0],
            calendar.veryShortWeekdaySymbols[calendar.firstWeekday - 1]
        )
    }

    func testVisibleMonthSetterDoesNotFireDelegate() {
        let view = makeView()
        let recorder = RecordingDelegate()
        view.delegate = recorder
        let next = Calendar.current.date(byAdding: .month, value: 1, to: view.visibleMonth)!

        view.visibleMonth = next

        XCTAssertEqual(view.visibleMonth, Calendar.current.startOfMonth(for: next))
        XCTAssertTrue(recorder.taskIDs.isEmpty)
        XCTAssertTrue(recorder.days.isEmpty)
        XCTAssertTrue(recorder.months.isEmpty)
        XCTAssertEqual(view.test_title, Calendar.current.monthYearString(for: next))
    }

    func testPrevNextAndTodayCallDelegateOnly() {
        let view = makeView()
        let recorder = RecordingDelegate()
        view.delegate = recorder
        let original = view.visibleMonth
        let originalTitle = view.test_title

        view.test_clickNextMonth()
        view.test_clickPreviousMonth()
        view.test_clickToday()

        XCTAssertEqual(view.visibleMonth, original)
        XCTAssertEqual(view.test_title, originalTitle)
        XCTAssertEqual(recorder.months.count, 3)
        XCTAssertEqual(
            Calendar.current.startOfMonth(for: recorder.months[0]),
            Calendar.current.startOfMonth(for: Calendar.current.date(byAdding: .month, value: 1, to: original)!)
        )
        XCTAssertEqual(
            Calendar.current.startOfMonth(for: recorder.months[1]),
            Calendar.current.startOfMonth(for: Calendar.current.date(byAdding: .month, value: -1, to: original)!)
        )
        XCTAssertEqual(Calendar.current.startOfMonth(for: recorder.months[2]), Calendar.current.startOfMonth(for: Date()))
        XCTAssertTrue(recorder.taskIDs.isEmpty)
        XCTAssertTrue(recorder.days.isEmpty)
    }

    func testChipClickSelectsTaskAndDayWithoutChangingMonth() {
        let view = makeView()
        let recorder = RecordingDelegate()
        view.delegate = recorder
        let original = view.visibleMonth
        let day = inMonthDay(of: view)
        let chip = TaskDeadlineChip(uuid: UUID(), title: "Write tests", day: day, isCompleted: false)
        view.deadlines = [chip]
        let index = view.test_days.firstIndex { Calendar.current.isDate($0, inSameDayAs: day) }!

        view.test_clickChip(at: index, chip: 0)

        XCTAssertEqual(recorder.taskIDs, [chip.uuid])
        XCTAssertEqual(recorder.days.count, 1)
        XCTAssertTrue(Calendar.current.isDate(recorder.days[0], inSameDayAs: day))
        XCTAssertTrue(recorder.months.isEmpty)
        XCTAssertEqual(view.visibleMonth, original)
    }

    func testDayAndOverflowClickSelectDayOnly() {
        let view = makeView()
        let recorder = RecordingDelegate()
        view.delegate = recorder
        let day = inMonthDay(of: view)
        let chips = (0..<5).map { offset in
            TaskDeadlineChip(uuid: UUID(), title: "Task \(offset)", day: day, isCompleted: false)
        }
        view.deadlines = chips
        let index = view.test_days.firstIndex { Calendar.current.isDate($0, inSameDayAs: day) }!

        XCTAssertEqual(view.test_visibleChips(at: index).map(\.uuid), chips.prefix(3).map(\.uuid))
        XCTAssertEqual(view.test_overflowCount(at: index), 2)

        view.test_clickDay(at: index)
        view.test_clickOverflow(at: index)

        XCTAssertTrue(recorder.taskIDs.isEmpty)
        XCTAssertEqual(recorder.days.count, 2)
        XCTAssertTrue(recorder.days.allSatisfy { Calendar.current.isDate($0, inSameDayAs: day) })
        XCTAssertTrue(recorder.months.isEmpty)
    }

    func testSpilloverDayShowsChipsAndNavigatesMonth() {
        let view = makeView()
        let recorder = RecordingDelegate()
        view.delegate = recorder
        let days = view.test_days
        guard let spilloverIndex = days.indices.first(where: { view.test_isSpillover(at: $0) }) else {
            XCTFail("Expected a spillover day in the 42-day grid")
            return
        }
        let spilloverDay = days[spilloverIndex]
        let chip = TaskDeadlineChip(uuid: UUID(), title: "Spillover", day: spilloverDay, isCompleted: false)
        view.deadlines = [chip]

        XCTAssertEqual(view.test_visibleChips(at: spilloverIndex).map(\.uuid), [chip.uuid])

        view.test_clickDay(at: spilloverIndex)

        XCTAssertEqual(recorder.days.count, 1)
        XCTAssertTrue(Calendar.current.isDate(recorder.days[0], inSameDayAs: spilloverDay))
        XCTAssertEqual(recorder.months.count, 1)
        XCTAssertEqual(
            Calendar.current.startOfMonth(for: recorder.months[0]),
            Calendar.current.startOfMonth(for: spilloverDay)
        )
        XCTAssertTrue(recorder.taskIDs.isEmpty)
        XCTAssertEqual(view.visibleMonth, Calendar.current.startOfMonth(for: Date()))
    }

    func testDayNumberMouseDownSelectsDay() {
        let view = makeView()
        let recorder = RecordingDelegate()
        view.delegate = recorder
        let day = inMonthDay(of: view)
        let index = view.test_days.firstIndex { Calendar.current.isDate($0, inSameDayAs: day) }!

        XCTAssertFalse(view.test_dayNumberHitView(at: index) is NSTextField)
        view.test_mouseDownOnDayNumber(at: index)

        XCTAssertEqual(recorder.days.count, 1)
        XCTAssertTrue(Calendar.current.isDate(recorder.days[0], inSameDayAs: day))
        XCTAssertTrue(recorder.taskIDs.isEmpty)
        XCTAssertTrue(recorder.months.isEmpty)
    }

    func testChipMouseDownDoesNotTreatSpilloverAsDayNavigation() {
        let view = makeView()
        let recorder = RecordingDelegate()
        view.delegate = recorder
        let days = view.test_days
        guard let spilloverIndex = days.indices.first(where: { view.test_isSpillover(at: $0) }) else {
            XCTFail("Expected a spillover day in the 42-day grid")
            return
        }
        let chip = TaskDeadlineChip(
            uuid: UUID(),
            title: "Spillover chip",
            day: days[spilloverIndex],
            isCompleted: false
        )
        view.deadlines = [chip]
        view.layoutSubtreeIfNeeded()

        view.test_mouseDownOnChip(at: spilloverIndex, chip: 0)

        XCTAssertEqual(recorder.taskIDs, [chip.uuid])
        XCTAssertEqual(recorder.days.count, 1)
        XCTAssertTrue(recorder.months.isEmpty)
    }

    func testAccessibilityPressSelectsDayAndChip() {
        let view = makeView()
        let recorder = RecordingDelegate()
        view.delegate = recorder
        let day = inMonthDay(of: view)
        let done = TaskDeadlineChip(uuid: UUID(), title: "Done", day: day, isCompleted: true)
        let open = TaskDeadlineChip(uuid: UUID(), title: "Open", day: day, isCompleted: false)
        view.deadlines = [done, open]
        let index = view.test_days.firstIndex { Calendar.current.isDate($0, inSameDayAs: day) }!

        XCTAssertEqual(view.test_chipAccessibilityLabel(at: index, chip: 0), "Done, Completed")
        XCTAssertEqual(view.test_chipAccessibilityLabel(at: index, chip: 1), "Open")
        XCTAssertTrue(view.test_performDayAccessibilityPress(at: index))
        XCTAssertTrue(view.test_performChipAccessibilityPress(at: index, chip: 1))

        XCTAssertEqual(recorder.days.count, 2)
        XCTAssertEqual(recorder.taskIDs, [open.uuid])
        XCTAssertTrue(recorder.months.isEmpty)
    }

    func testCompletedChipsAreDimmedAndStruck() {
        let view = makeView()
        let day = inMonthDay(of: view)
        view.deadlines = [
            TaskDeadlineChip(uuid: UUID(), title: "Done", day: day, isCompleted: true),
            TaskDeadlineChip(uuid: UUID(), title: "Open", day: day, isCompleted: false),
        ]
        let index = view.test_days.firstIndex { Calendar.current.isDate($0, inSameDayAs: day) }!

        let completed = view.test_chipAppearance(at: index, chip: 0)
        let open = view.test_chipAppearance(at: index, chip: 1)
        XCTAssertEqual(completed?.color, .tertiaryLabelColor)
        XCTAssertEqual(completed?.isStruck, true)
        XCTAssertEqual(completed?.isSelected, false)
        XCTAssertEqual(open?.color, .labelColor)
        XCTAssertEqual(open?.isStruck, false)
        XCTAssertEqual(open?.isSelected, false)
    }

    func testSelectedChipUsesAccentColor() {
        let view = makeView()
        let day = inMonthDay(of: view)
        let selected = TaskDeadlineChip(uuid: UUID(), title: "Selected", day: day, isCompleted: false)
        let other = TaskDeadlineChip(uuid: UUID(), title: "Other", day: day, isCompleted: false)
        view.deadlines = [selected, other]
        let index = view.test_days.firstIndex { Calendar.current.isDate($0, inSameDayAs: day) }!

        view.selectedTaskID = selected.uuid

        let selectedAppearance = view.test_chipAppearance(at: index, chip: 0)
        let otherAppearance = view.test_chipAppearance(at: index, chip: 1)
        XCTAssertEqual(selectedAppearance?.color, .controlAccentColor)
        XCTAssertEqual(selectedAppearance?.isStruck, false)
        XCTAssertEqual(selectedAppearance?.isSelected, true)
        XCTAssertEqual(otherAppearance?.color, .labelColor)
        XCTAssertEqual(otherAppearance?.isStruck, false)
        XCTAssertEqual(otherAppearance?.isSelected, false)
    }

    func testCompletedSelectedChipStaysDimmedAndStruck() {
        let view = makeView()
        let day = inMonthDay(of: view)
        let done = TaskDeadlineChip(uuid: UUID(), title: "Done", day: day, isCompleted: true)
        view.deadlines = [done]
        let index = view.test_days.firstIndex { Calendar.current.isDate($0, inSameDayAs: day) }!

        view.selectedTaskID = done.uuid

        let appearance = view.test_chipAppearance(at: index, chip: 0)
        XCTAssertEqual(appearance?.color, .tertiaryLabelColor)
        XCTAssertEqual(appearance?.isStruck, true)
        XCTAssertEqual(appearance?.isSelected, true)
    }

    func testEmptyMonthMessageWhenCivilMonthHasNoChips() {
        let view = makeView()
        XCTAssertTrue(view.test_isEmptyMonthVisible)
        XCTAssertEqual(view.test_emptyMonthText, "No deadlines this month.")

        let day = inMonthDay(of: view)
        view.deadlines = [TaskDeadlineChip(uuid: UUID(), title: "Due", day: day, isCompleted: false)]
        XCTAssertFalse(view.test_isEmptyMonthVisible)

        view.deadlines = []
        XCTAssertTrue(view.test_isEmptyMonthVisible)
    }

    func testEmptyMonthShownWhenOnlySpilloverChips() {
        let view = makeView()
        let days = view.test_days
        guard let spilloverIndex = days.indices.first(where: { view.test_isSpillover(at: $0) }) else {
            XCTFail("Expected a spillover day in the 42-day grid")
            return
        }
        view.deadlines = [
            TaskDeadlineChip(uuid: UUID(), title: "Spillover", day: days[spilloverIndex], isCompleted: false),
        ]

        XCTAssertTrue(view.test_isEmptyMonthVisible)
        XCTAssertEqual(view.test_emptyMonthText, "No deadlines this month.")
        XCTAssertEqual(view.test_visibleChips(at: spilloverIndex).count, 1)
    }

    private func makeView() -> MonthCalendarView {
        let view = MonthCalendarView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func inMonthDay(of view: MonthCalendarView) -> Date {
        let calendar = Calendar.current
        return view.test_days.first { calendar.isDate($0, equalTo: view.visibleMonth, toGranularity: .month) }!
    }
}

@MainActor
final class CalendarViewControllerTests: PersistenceTestCase {
    func testObserverAppliesVisibleMonthFromSelectionModel() {
        let selection = SelectionModel()
        let calendarVC = makeCalendar(selection: selection)
        let originalTitle = calendarVC.test_title
        let next = Calendar.current.date(byAdding: .month, value: 1, to: selection.visibleMonth)!

        selection.setVisibleMonth(next)

        XCTAssertEqual(calendarVC.monthView.visibleMonth, Calendar.current.startOfMonth(for: next))
        XCTAssertEqual(calendarVC.test_title, Calendar.current.monthYearString(for: next))
        XCTAssertNotEqual(calendarVC.test_title, originalTitle)
    }

    func testGesturesWriteSelectionThenViewUpdatesFromObserver() {
        let selection = SelectionModel()
        let calendarVC = makeCalendar(selection: selection)
        let original = selection.visibleMonth
        let originalNode = selection.selectedNodeUUID

        calendarVC.monthView.test_clickNextMonth()

        let expected = Calendar.current.startOfMonth(
            for: Calendar.current.date(byAdding: .month, value: 1, to: original)!
        )
        XCTAssertEqual(selection.visibleMonth, expected)
        XCTAssertEqual(calendarVC.monthView.visibleMonth, expected)
        XCTAssertEqual(selection.selectedNodeUUID, originalNode)
    }

    func testChipClickSelectsNodeAndDayWithoutChangingMonth() throws {
        let selection = SelectionModel()
        let calendarVC = makeCalendar(selection: selection)
        let project = try model.createProject()
        let day = inMonthDay(of: calendarVC.monthView)
        let task = try makeTask(in: project, title: "Deadline", deadline: day)
        let originalMonth = selection.visibleMonth
        let index = calendarVC.monthView.test_days.firstIndex { Calendar.current.isDate($0, inSameDayAs: day) }!

        XCTAssertEqual(calendarVC.monthView.test_visibleChips(at: index).map(\.uuid), [task.uuid])

        calendarVC.monthView.test_clickChip(at: index, chip: 0)

        XCTAssertEqual(selection.selectedNodeUUID, task.uuid)
        XCTAssertEqual(selection.selectedDay.map { Calendar.current.startOfDay(for: $0) }, Calendar.current.startOfDay(for: day))
        XCTAssertEqual(selection.visibleMonth, originalMonth)
        XCTAssertEqual(calendarVC.monthView.selectedTaskID, task.uuid)
        XCTAssertEqual(calendarVC.monthView.selectedDay, Calendar.current.startOfDay(for: day))
        let appearance = calendarVC.monthView.test_chipAppearance(at: index, chip: 0)
        XCTAssertEqual(appearance?.color, .controlAccentColor)
        XCTAssertEqual(appearance?.isSelected, true)
    }

    func testDayClickSelectsDayWithoutClearingOutlineSelection() throws {
        let selection = SelectionModel()
        let calendarVC = makeCalendar(selection: selection)
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        selection.selectNode(uuid: task.uuid)
        let day = inMonthDay(of: calendarVC.monthView)
        let index = calendarVC.monthView.test_days.firstIndex { Calendar.current.isDate($0, inSameDayAs: day) }!

        calendarVC.monthView.test_clickDay(at: index)

        XCTAssertEqual(selection.selectedNodeUUID, task.uuid)
        XCTAssertEqual(selection.selectedDay, Calendar.current.startOfDay(for: day))
        XCTAssertEqual(calendarVC.monthView.selectedDay, Calendar.current.startOfDay(for: day))
    }

    func testFetchIncludesCompletedAndSpilloverTasksButNotProjectsOrNilDeadlines() throws {
        let selection = SelectionModel()
        let calendar = Calendar.current
        let month = calendar.startOfMonth(for: Date())
        selection.setVisibleMonth(month)
        let calendarVC = makeCalendar(selection: selection)
        let project = try model.createProject()
        try model.setTitle(project, "Garden")

        let days = calendar.daysInMonthGrid(for: month)
        let inMonth = days.first { calendar.isDate($0, equalTo: month, toGranularity: .month) }!
        let leading = days[0]
        let trailing = days[41]
        let outside = calendar.date(byAdding: .day, value: -1, to: leading)!

        let open = try makeTask(in: project, title: "Open", deadline: inMonth)
        let done = try makeTask(in: project, title: "Done", deadline: inMonth)
        try model.setCompleted(true, on: done)
        let leadingTask = try makeTask(in: project, title: "Leading", deadline: leading)
        let trailingTask = try makeTask(in: project, title: "Trailing", deadline: trailing)
        _ = try makeTask(in: project, title: "Outside", deadline: outside)
        _ = try model.createTask(in: project)

        let chips = calendarVC.monthView.deadlines
        let ids = Set(chips.map(\.uuid))
        XCTAssertEqual(ids, [open.uuid, done.uuid, leadingTask.uuid, trailingTask.uuid])
        XCTAssertTrue(chips.contains { $0.uuid == done.uuid && $0.isCompleted })
        XCTAssertFalse(chips.contains { $0.title == "Garden" })

        let leadingIndex = 0
        let trailingIndex = 41
        XCTAssertTrue(calendarVC.monthView.test_visibleChips(at: leadingIndex).map(\.uuid).contains(leadingTask.uuid))
        XCTAssertTrue(calendarVC.monthView.test_visibleChips(at: trailingIndex).map(\.uuid).contains(trailingTask.uuid))
    }

    func testEmptyMonthLabelFollowsCivilMonthDeadlines() throws {
        let selection = SelectionModel()
        let calendarVC = makeCalendar(selection: selection)
        XCTAssertTrue(calendarVC.monthView.test_isEmptyMonthVisible)
        XCTAssertEqual(calendarVC.monthView.test_emptyMonthText, "No deadlines this month.")

        let project = try model.createProject()
        let day = inMonthDay(of: calendarVC.monthView)
        _ = try makeTask(in: project, title: "Due", deadline: day)
        XCTAssertFalse(calendarVC.monthView.test_isEmptyMonthVisible)
    }

    func testSpilloverDayClickWritesMonthAndDay() {
        let selection = SelectionModel()
        let calendarVC = makeCalendar(selection: selection)
        let days = calendarVC.monthView.test_days
        guard let spilloverIndex = days.indices.first(where: { calendarVC.monthView.test_isSpillover(at: $0) }) else {
            XCTFail("Expected a spillover day")
            return
        }
        let spilloverDay = days[spilloverIndex]
        let originalNode = UUID()
        selection.selectNode(uuid: originalNode)

        calendarVC.monthView.test_clickDay(at: spilloverIndex)

        XCTAssertEqual(selection.selectedNodeUUID, originalNode)
        XCTAssertEqual(selection.selectedDay, Calendar.current.startOfDay(for: spilloverDay))
        XCTAssertEqual(selection.visibleMonth, Calendar.current.startOfMonth(for: spilloverDay))
        XCTAssertEqual(calendarVC.monthView.visibleMonth, Calendar.current.startOfMonth(for: spilloverDay))
    }

    private func makeCalendar(selection: SelectionModel) -> CalendarViewController {
        let calendarVC = CalendarViewController(
            persistence: persistence,
            model: model,
            selection: selection
        )
        calendarVC.loadViewIfNeeded()
        calendarVC.view.frame = NSRect(x: 0, y: 0, width: 720, height: 480)
        calendarVC.view.layoutSubtreeIfNeeded()
        return calendarVC
    }

    private func makeTask(in project: Project, title: String, deadline: Date) throws -> TaskItem {
        let task = try model.createTask(in: project)
        try model.setTitle(task, title)
        try model.setDeadline(task, date: deadline)
        return task
    }

    private func inMonthDay(of view: MonthCalendarView) -> Date {
        let calendar = Calendar.current
        return view.test_days.first { calendar.isDate($0, equalTo: view.visibleMonth, toGranularity: .month) }!
    }
}

@MainActor
private final class RecordingDelegate: MonthCalendarViewDelegate {
    var taskIDs: [UUID] = []
    var days: [Date] = []
    var months: [Date] = []

    func monthCalendar(_ view: MonthCalendarView, didSelectTaskID uuid: UUID) {
        taskIDs.append(uuid)
    }

    func monthCalendar(_ view: MonthCalendarView, didSelectDay date: Date) {
        days.append(date)
    }

    func monthCalendar(_ view: MonthCalendarView, didChangeVisibleMonth date: Date) {
        months.append(date)
    }
}
