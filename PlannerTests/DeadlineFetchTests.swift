import XCTest
@testable import Planner

@MainActor
final class DeadlineFetchTests: PersistenceTestCase {
    func testCivilMonthIncludesLastDayExcludesNextMonthAndNil() throws {
        let calendar = testCalendar
        let project = try model.createProject()
        let lastOfMonth = try makeTask(in: project, deadline: date(year: 2026, month: 8, day: 31), calendar: calendar)
        let firstOfMonth = try makeTask(in: project, deadline: date(year: 2026, month: 8, day: 1), calendar: calendar)
        let nextMonth = try makeTask(in: project, deadline: date(year: 2026, month: 9, day: 1), calendar: calendar)
        let previousMonth = try makeTask(in: project, deadline: date(year: 2026, month: 7, day: 31), calendar: calendar)
        let noDeadline = try model.createTask(in: project)

        let august = date(year: 2026, month: 8, day: 15, calendar: calendar)
        let fetched = try model.tasks(deadlineInMonthOf: august, calendar: calendar)
        let ids = Set(fetched.map(\.uuid))

        XCTAssertEqual(ids, [firstOfMonth.uuid, lastOfMonth.uuid])
        XCTAssertFalse(ids.contains(nextMonth.uuid))
        XCTAssertFalse(ids.contains(previousMonth.uuid))
        XCTAssertFalse(ids.contains(noDeadline.uuid))
    }

    func testWeekFetchCoversEveryVisibleWeekAndStopsAtTheEdges() throws {
        let calendar = testCalendar
        let project = try model.createProject()
        // 2026-08-10 is a Monday; four weeks run through Sunday 2026-09-06.
        let weekStart = date(year: 2026, month: 8, day: 10, calendar: calendar)
        XCTAssertEqual(calendar.startOfWeek(for: weekStart), calendar.startOfDay(for: weekStart))

        let firstDay = try makeTask(in: project, deadline: weekStart, calendar: calendar)
        let lastDay = try makeTask(in: project, deadline: date(year: 2026, month: 9, day: 6), calendar: calendar)
        let middle = try makeTask(in: project, deadline: date(year: 2026, month: 8, day: 21), calendar: calendar)
        let before = try makeTask(in: project, deadline: date(year: 2026, month: 8, day: 9), calendar: calendar)
        let after = try makeTask(in: project, deadline: date(year: 2026, month: 9, day: 7), calendar: calendar)

        let fetched = try model.tasks(deadlineInWeeksFrom: weekStart, count: 4, calendar: calendar)
        let ids = Set(fetched.map(\.uuid))

        XCTAssertEqual(ids, [firstDay.uuid, lastDay.uuid, middle.uuid])
        XCTAssertFalse(ids.contains(before.uuid))
        XCTAssertFalse(ids.contains(after.uuid))
    }

    func testWeekFetchWindowGrowsWithVisibleWeekCount() throws {
        let calendar = testCalendar
        let project = try model.createProject()
        let weekStart = date(year: 2026, month: 8, day: 10, calendar: calendar)
        let farOut = try makeTask(in: project, deadline: date(year: 2026, month: 9, day: 10), calendar: calendar)

        let narrow = try model.tasks(deadlineInWeeksFrom: weekStart, count: 4, calendar: calendar)
        XCTAssertFalse(Set(narrow.map(\.uuid)).contains(farOut.uuid))

        let wide = try model.tasks(deadlineInWeeksFrom: weekStart, count: 6, calendar: calendar)
        XCTAssertTrue(Set(wide.map(\.uuid)).contains(farOut.uuid))
    }

    func testCompletedTasksWithDeadlineAreStillFetched() throws {
        let calendar = testCalendar
        let project = try model.createProject()
        let august = date(year: 2026, month: 8, day: 15, calendar: calendar)
        let task = try makeTask(in: project, deadline: date(year: 2026, month: 8, day: 20), calendar: calendar)
        try model.setCompleted(true, on: task)

        let month = try model.tasks(deadlineInMonthOf: august, calendar: calendar)
        let weeks = try model.tasks(
            deadlineInWeeksFrom: date(year: 2026, month: 8, day: 17, calendar: calendar),
            count: 2,
            calendar: calendar
        )
        XCTAssertEqual(month.map(\.uuid), [task.uuid])
        XCTAssertEqual(weeks.map(\.uuid), [task.uuid])
        XCTAssertTrue(month[0].isCompleted)
    }

    func testSetDeadlineStoresStartOfDay() throws {
        let calendar = testCalendar
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        let raw = date(year: 2026, month: 8, day: 13, hour: 18, minute: 45, calendar: calendar)

        try model.setDeadline(task, date: raw, calendar: calendar)

        XCTAssertEqual(task.deadline, calendar.startOfDay(for: raw))
        XCTAssertNotEqual(task.deadline, raw)
    }

    // MARK: - Day notes

    func testDayNoteIsCreatedOnFirstWriteAndKeyedByStartOfDay() throws {
        let calendar = testCalendar
        let afternoon = date(year: 2026, month: 8, day: 14, hour: 16, minute: 30, calendar: calendar)

        XCTAssertNil(model.dayNote(for: afternoon, calendar: calendar), "browsing a day must not create a row")

        try model.setDayNote("packed day", on: afternoon, calendar: calendar)

        let note = try XCTUnwrap(model.dayNote(for: afternoon, calendar: calendar))
        XCTAssertEqual(note.note, "packed day")
        XCTAssertEqual(note.day, calendar.startOfDay(for: afternoon))
        // Any instant during that day resolves to the same note.
        let morning = date(year: 2026, month: 8, day: 14, hour: 7, calendar: calendar)
        XCTAssertEqual(model.dayNote(for: morning, calendar: calendar)?.uuid, note.uuid)
    }

    func testDayNoteUpdatesInPlaceAndIsDeletedWhenCleared() throws {
        let calendar = testCalendar
        let day = date(year: 2026, month: 8, day: 14, calendar: calendar)

        try model.setDayNote("first", on: day, calendar: calendar)
        let uuid = try XCTUnwrap(model.dayNote(for: day, calendar: calendar)?.uuid)

        try model.setDayNote("second", on: day, calendar: calendar)
        XCTAssertEqual(model.dayNote(for: day, calendar: calendar)?.note, "second")
        XCTAssertEqual(model.dayNote(for: day, calendar: calendar)?.uuid, uuid, "same row, edited in place")

        // Clearing the text removes the row rather than leaving an empty one.
        try model.setDayNote("", on: day, calendar: calendar)
        XCTAssertNil(model.dayNote(for: day, calendar: calendar))
    }

    func testDayNoteCarriesNoDeadlineOrCompletionAndIsNotATask() throws {
        let calendar = testCalendar
        let day = date(year: 2026, month: 8, day: 14, calendar: calendar)
        try model.setDayNote("standalone", on: day, calendar: calendar)

        // A day is not a task: it never appears in the outline or a deadline fetch.
        XCTAssertTrue(try fetchAllTasks().isEmpty)
        XCTAssertTrue(try model.allProjects().isEmpty)
        XCTAssertTrue(try model.tasks(deadlineInWeeksFrom: day, count: 2, calendar: calendar).isEmpty)
    }

    func testDaysWithNotesCoversTheRangeAndIgnoresEmptyNotes() throws {
        let calendar = testCalendar
        let monday = date(year: 2026, month: 8, day: 10, calendar: calendar)
        let inside = date(year: 2026, month: 8, day: 12, calendar: calendar)
        let lastDay = date(year: 2026, month: 8, day: 16, calendar: calendar)
        let outside = date(year: 2026, month: 8, day: 17, calendar: calendar)

        try model.setDayNote("in", on: inside, calendar: calendar)
        try model.setDayNote("edge", on: lastDay, calendar: calendar)
        try model.setDayNote("later", on: outside, calendar: calendar)

        let end = calendar.endOfWeeks(from: monday, count: 1)
        let days = try model.daysWithNotes(from: calendar.startOfWeek(for: monday), to: end)

        XCTAssertEqual(days, [calendar.startOfDay(for: inside), calendar.startOfDay(for: lastDay)])
        XCTAssertFalse(days.contains(calendar.startOfDay(for: outside)))
    }

    private func makeTask(in project: Project, deadline: Date, calendar: Calendar) throws -> TaskItem {
        let task = try model.createTask(in: project)
        try model.setDeadline(task, date: deadline, calendar: calendar)
        return task
    }
}
