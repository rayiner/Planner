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

    func testGridFetchIncludesSpilloverDays() throws {
        let calendar = testCalendar
        let project = try model.createProject()
        let august = date(year: 2026, month: 8, day: 15, calendar: calendar)
        let days = calendar.daysInMonthGrid(for: august)
        XCTAssertEqual(days.count, 42)

        let leading = try makeTask(in: project, deadline: days[0], calendar: calendar)
        let trailing = try makeTask(in: project, deadline: days[41], calendar: calendar)
        let inMonth = try makeTask(in: project, deadline: date(year: 2026, month: 8, day: 13), calendar: calendar)
        let outside = try makeTask(
            in: project,
            deadline: calendar.date(byAdding: .day, value: -1, to: days[0])!,
            calendar: calendar
        )

        let grid = try model.tasks(deadlineInGridOf: august, calendar: calendar)
        let gridIDs = Set(grid.map(\.uuid))
        XCTAssertEqual(gridIDs, [leading.uuid, trailing.uuid, inMonth.uuid])
        XCTAssertFalse(gridIDs.contains(outside.uuid))

        let month = try model.tasks(deadlineInMonthOf: august, calendar: calendar)
        let monthIDs = Set(month.map(\.uuid))
        XCTAssertEqual(monthIDs, [inMonth.uuid])
        XCTAssertFalse(monthIDs.contains(leading.uuid))
        XCTAssertFalse(monthIDs.contains(trailing.uuid))
    }

    func testCompletedTasksWithDeadlineAreStillFetched() throws {
        let calendar = testCalendar
        let project = try model.createProject()
        let august = date(year: 2026, month: 8, day: 15, calendar: calendar)
        let task = try makeTask(in: project, deadline: date(year: 2026, month: 8, day: 20), calendar: calendar)
        try model.setCompleted(true, on: task)

        let month = try model.tasks(deadlineInMonthOf: august, calendar: calendar)
        let grid = try model.tasks(deadlineInGridOf: august, calendar: calendar)
        XCTAssertEqual(month.map(\.uuid), [task.uuid])
        XCTAssertEqual(grid.map(\.uuid), [task.uuid])
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

    private func makeTask(in project: Project, deadline: Date, calendar: Calendar) throws -> TaskItem {
        let task = try model.createTask(in: project)
        try model.setDeadline(task, date: deadline, calendar: calendar)
        return task
    }
}
