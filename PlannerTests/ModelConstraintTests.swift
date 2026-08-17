import CoreData
import XCTest
@testable import Planner

@MainActor
final class ModelConstraintTests: PersistenceTestCase {
    func testCreateTaskSetsExactlyOneParent() throws {
        let project = try model.createProject()
        let task = try model.createTask(in: project)

        XCTAssertEqual(task.project, project)
        XCTAssertNil(task.parentTask)
        XCTAssertFalse(task.isCompleted)
        XCTAssertEqual(task.title, "Untitled Task")
    }

    func testCreateSubtaskSetsExactlyOneParent() throws {
        let project = try model.createProject()
        let parent = try model.createTask(in: project)
        let subtask = try model.createSubtask(under: parent)

        XCTAssertEqual(subtask.parentTask, parent)
        XCTAssertNil(subtask.project)
        XCTAssertFalse(subtask.isCompleted)
    }

    func testCreateSiblingOfNestedTaskUsesParentTask() throws {
        let project = try model.createProject()
        let root = try model.createTask(in: project)
        let nested = try model.createSubtask(under: root)
        let sibling = try model.createSibling(of: nested)

        XCTAssertEqual(sibling.parentTask, root)
        XCTAssertNil(sibling.project)
        XCTAssertEqual(nested.sortIndex, 0)
        XCTAssertEqual(sibling.sortIndex, 1)
        XCTAssertEqual(root.outlineChildren.map(\.uuid), [nested.uuid, sibling.uuid])
    }

    func testCreateSiblingOfProjectTaskUsesProject() throws {
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        let sibling = try model.createSibling(of: task)

        XCTAssertEqual(sibling.project, project)
        XCTAssertNil(sibling.parentTask)
    }

    func testCreateTaskUnderOutlineNode() throws {
        let project = try model.createProject()
        let inProject = try model.createTask(under: project)
        XCTAssertEqual(inProject.project, project)
        XCTAssertNil(inProject.parentTask)

        let underTask = try model.createTask(under: inProject)
        XCTAssertEqual(underTask.parentTask, inProject)
        XCTAssertNil(underTask.project)
    }

    func testWouldIntroduceCycleForSelfAndLoop() throws {
        let project = try model.createProject()
        let a = try model.createTask(in: project)
        let b = try model.createSubtask(under: a)

        XCTAssertTrue(model.wouldIntroduceCycle(child: a, parent: a))
        XCTAssertTrue(model.wouldIntroduceCycle(child: a, parent: b))
        XCTAssertFalse(model.wouldIntroduceCycle(child: b, parent: a))

        let c = try model.createSubtask(under: b)
        XCTAssertFalse(model.wouldIntroduceCycle(child: c, parent: b))
        XCTAssertEqual(c.parentTask, b)
        XCTAssertNil(c.project)
    }

    func testCreateSubtaskRefusesCycle() throws {
        let project = try model.createProject()
        let a = try model.createTask(in: project)
        let b = try model.createSubtask(under: a)
        // Seed A→B→A so the parent walk is already cyclic.
        a.project = nil
        a.parentTask = b

        let taskCount = try fetchAllTasks().count
        XCTAssertThrowsError(try model.createSubtask(under: b)) { error in
            XCTAssertEqual(error as? ModelError, .cycle)
        }
        XCTAssertEqual(try fetchAllTasks().count, taskCount)
        XCTAssertFalse(persistence.viewContext.registeredObjects.contains { $0.isInserted })
    }

    func testDeleteProjectCascadesTasksAndSubtasks() throws {
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        _ = try model.createSubtask(under: task)

        try model.delete(project)

        XCTAssertTrue(try model.allProjects().isEmpty)
        XCTAssertTrue(try fetchAllTasks().isEmpty)
    }

    func testDeleteTaskCascadesDescendantsAndKeepsSiblings() throws {
        let project = try model.createProject()
        let parent = try model.createTask(in: project)
        let sibling = try model.createTask(in: project)
        let child = try model.createSubtask(under: parent)
        _ = try model.createSubtask(under: child)

        try model.delete(parent)

        XCTAssertEqual(try model.allProjects().map(\.uuid), [project.uuid])
        let remaining = try fetchAllTasks()
        XCTAssertEqual(remaining.map(\.uuid), [sibling.uuid])
        XCTAssertEqual(remaining.first?.project, project)
    }

    func testCreateProjectSortIndexAppends() throws {
        let first = try model.createProject()
        let second = try model.createProject()
        let third = try model.createProject()
        XCTAssertEqual([first, second, third].map(\.sortIndex), [0, 1, 2])
    }

    func testSortIndexAppendsAndUuidTieBreaks() throws {
        let project = try model.createProject()
        let first = try model.createTask(in: project)
        let second = try model.createTask(in: project)
        let third = try model.createTask(in: project)

        XCTAssertEqual([first, second, third].map(\.sortIndex), [0, 1, 2])
        XCTAssertEqual(project.outlineChildren.map(\.uuid), [first.uuid, second.uuid, third.uuid])

        first.sortIndex = 0
        second.sortIndex = 0
        try persistence.saveViewContext(presentingWindow: nil)

        let expected = [first, second].sorted { $0.uuid < $1.uuid } + [third]
        XCTAssertEqual(project.outlineChildren.map(\.uuid), expected.map(\.uuid))
    }

    func testCompletionIsFlagOnlyWithNoRollup() throws {
        let project = try model.createProject()
        let parent = try model.createTask(in: project)
        let child = try model.createSubtask(under: parent)
        XCTAssertFalse(parent.isCompleted)
        XCTAssertFalse(child.isCompleted)

        try model.setCompleted(true, on: parent)
        XCTAssertTrue(parent.isCompleted)
        XCTAssertFalse(child.isCompleted)

        try model.setCompleted(true, on: child)
        try model.setCompleted(false, on: parent)
        XCTAssertFalse(parent.isCompleted)
        XCTAssertTrue(child.isCompleted)

        try model.setCompleted(false, on: child)
        XCTAssertFalse(try model.task(uuid: child.uuid)!.isCompleted)
    }

    func testCreateAssignsDistinctUUIDs() throws {
        let projectA = try model.createProject()
        let projectB = try model.createProject()
        let taskA = try model.createTask(in: projectA)
        let taskB = try model.createTask(in: projectA)

        let uuids = [projectA.uuid, projectB.uuid, taskA.uuid, taskB.uuid]
        XCTAssertEqual(Set(uuids).count, uuids.count)
    }

    func testSuccessfulCreateHasPermanentObjectID() throws {
        let project = try model.createProject()
        XCTAssertFalse(project.objectID.isTemporaryID)

        let task = try model.createTask(in: project)
        XCTAssertFalse(task.objectID.isTemporaryID)
    }

    func testCreateSaveFailureThrowsAndLeavesStoreUnchanged() throws {
        persistence.failNextSave = true
        XCTAssertThrowsError(try model.createProject()) { error in
            XCTAssertEqual(error as? ModelError, .saveFailed)
        }
        XCTAssertTrue(try model.allProjects().isEmpty)
        XCTAssertFalse(persistence.viewContext.registeredObjects.contains { $0.isInserted })
    }

    func testDeleteSaveFailureThrowsAndLeavesTreeUnchanged() throws {
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        let subtask = try model.createSubtask(under: task)

        persistence.failNextSave = true
        XCTAssertThrowsError(try model.delete(project)) { error in
            XCTAssertEqual(error as? ModelError, .saveFailed)
        }

        XCTAssertNotNil(try model.project(uuid: project.uuid))
        XCTAssertNotNil(try model.task(uuid: task.uuid))
        XCTAssertNotNil(try model.task(uuid: subtask.uuid))
        XCTAssertEqual(try fetchAllTasks().count, 2)
    }

    func testUUIDLookup() throws {
        let project = try model.createProject()
        let task = try model.createTask(in: project)

        XCTAssertEqual(try model.project(uuid: project.uuid)?.objectID, project.objectID)
        XCTAssertEqual(try model.task(uuid: task.uuid)?.objectID, task.objectID)
        XCTAssertEqual(try model.node(uuid: project.uuid)?.uuid, project.uuid)
        XCTAssertEqual(try model.node(uuid: task.uuid)?.uuid, task.uuid)

        let unknown = UUID()
        XCTAssertNil(try model.project(uuid: unknown))
        XCTAssertNil(try model.task(uuid: unknown))
        XCTAssertNil(try model.node(uuid: unknown))
    }

    func testEmptyNoteStoresNil() throws {
        let project = try model.createProject()
        let task = try model.createTask(in: project)

        try model.setNote(task, "hello")
        XCTAssertEqual(task.note, "hello")

        try model.setNote(task, "")
        XCTAssertNil(task.note)
        XCTAssertNil(try model.task(uuid: task.uuid)?.note)
    }

    func testSetTitleTrimsAndRejectsEmpty() throws {
        let project = try model.createProject()
        try model.setTitle(project, "  Inbox  ")
        XCTAssertEqual(project.title, "Inbox")

        XCTAssertThrowsError(try model.setTitle(project, "   ")) { error in
            XCTAssertEqual(error as? ModelError, .emptyTitle)
        }
        XCTAssertEqual(project.title, "Inbox")
    }

    func testUndoActionNames() throws {
        let undo = persistence.viewContext.undoManager
        let project = try model.createProject()
        XCTAssertEqual(undo?.undoActionName, "New Project")

        let task = try model.createTask(in: project)
        XCTAssertEqual(undo?.undoActionName, "New Task")

        let subtask = try model.createSubtask(under: task)
        XCTAssertEqual(undo?.undoActionName, "New Task")

        _ = try model.createSibling(of: task)
        XCTAssertEqual(undo?.undoActionName, "New Task")

        try model.setTitle(task, "Buy milk")
        XCTAssertEqual(undo?.undoActionName, "Rename")

        try model.setDeadline(task, date: date(year: 2026, month: 8, day: 13))
        XCTAssertEqual(undo?.undoActionName, "Set Deadline")

        try model.setDeadline(task, date: nil)
        XCTAssertEqual(undo?.undoActionName, "Clear Deadline")

        try model.setCompleted(true, on: task)
        XCTAssertEqual(undo?.undoActionName, "Complete")

        try model.setCompleted(false, on: task)
        XCTAssertEqual(undo?.undoActionName, "Mark Incomplete")

        try model.setNote(task, "x")
        XCTAssertEqual(undo?.undoActionName, "Edit Note")

        try model.delete(subtask)
        XCTAssertEqual(undo?.undoActionName, "Delete")
    }
}

@MainActor
final class SelectionModelTests: XCTestCase {
    func testVisibleWeekStartIsToday() {
        let calendar = Self.utcCalendar
        // 2026-08-13 is a Thursday; the grid opens on that day, not Monday.
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 13, hour: 18))!
        let selection = SelectionModel(now: now, calendar: calendar)
        XCTAssertEqual(selection.visibleWeekStart, calendar.startOfDay(for: now))
        XCTAssertEqual(calendar.component(.day, from: selection.visibleWeekStart), 13)
        XCTAssertEqual(calendar.component(.weekday, from: selection.visibleWeekStart), 5)
        XCTAssertNil(selection.selectedNodeUUID)
        XCTAssertNil(selection.selectedDay)
    }

    func testSelectNodePostsOnlyWhenChanged() {
        let selection = SelectionModel(now: Date(), calendar: Self.utcCalendar)
        let uuid = UUID()
        let fields = observe(selection) {
            selection.selectNode(uuid: uuid)
            selection.selectNode(uuid: uuid)
            selection.selectNode(uuid: nil)
        }
        XCTAssertEqual(fields, [["node"], ["node"]])
        XCTAssertNil(selection.selectedNodeUUID)
    }

    func testTaskAndDaySelectionAreMutuallyExclusive() {
        let calendar = Self.utcCalendar
        let selection = SelectionModel(now: Date(), calendar: calendar)
        let uuid = UUID()
        let day = calendar.date(from: DateComponents(year: 2026, month: 8, day: 14, hour: 9))!

        let toDay = observe(selection) {
            selection.selectNode(uuid: uuid)
            selection.selectDay(day)
        }
        XCTAssertNil(selection.selectedNodeUUID, "the day displaced the node")
        XCTAssertEqual(selection.selectedDay, calendar.startOfDay(for: day))
        // Moving between the two posts both fields, so observers of either react.
        XCTAssertEqual(toDay, [["node"], ["node", "day"]])

        let toNode = observe(selection) {
            selection.selectNode(uuid: uuid)
        }
        XCTAssertEqual(selection.selectedNodeUUID, uuid)
        XCTAssertNil(selection.selectedDay, "the node displaced the day")
        XCTAssertEqual(toNode, [["node", "day"]])
    }

    func testClearSelectionEmptiesWhicheverSideHeldIt() {
        let calendar = Self.utcCalendar
        let selection = SelectionModel(now: Date(), calendar: calendar)
        let day = calendar.date(from: DateComponents(year: 2026, month: 8, day: 14))!

        selection.selectDay(day)
        let fields = observe(selection) {
            selection.clearSelection()
            selection.clearSelection()
        }
        XCTAssertNil(selection.selection)
        XCTAssertEqual(fields, [["day"]], "no post when already empty")
    }

    func testSelectDayNormalizesToStartOfDay() {
        let calendar = Self.utcCalendar
        let selection = SelectionModel(now: Date(), calendar: calendar)
        let raw = calendar.date(from: DateComponents(year: 2026, month: 8, day: 13, hour: 19, minute: 45))!
        let fields = observe(selection) {
            selection.selectDay(raw)
            selection.selectDay(calendar.startOfDay(for: raw))
            selection.selectDay(nil)
        }
        XCTAssertNil(selection.selectedDay)
        XCTAssertEqual(fields, [["day"], ["day"]])
    }

    func testSetVisibleWeekStartNormalizesAndPostsOnlyWhenChanged() {
        let calendar = Self.utcCalendar
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 13))!
        let selection = SelectionModel(now: now, calendar: calendar)
        let midSeptember = calendar.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 8))!
        let fields = observe(selection) {
            selection.setVisibleWeekStart(midSeptember)
            // Same civil day is a no-op; a different day pages.
            selection.setVisibleWeekStart(calendar.startOfDay(for: midSeptember))
            selection.setVisibleWeekStart(calendar.date(byAdding: .day, value: 3, to: midSeptember)!)
        }
        XCTAssertEqual(
            selection.visibleWeekStart,
            calendar.startOfDay(for: calendar.date(byAdding: .day, value: 3, to: midSeptember)!)
        )
        XCTAssertEqual(fields, [["visibleWeek"], ["visibleWeek"]])
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 1
        return calendar
    }

    private func observe(_ selection: SelectionModel, _ body: () -> Void) -> [Set<String>] {
        final class Box: @unchecked Sendable {
            var fields: [Set<String>] = []
        }
        let box = Box()
        let token = NotificationCenter.default.addObserver(
            forName: .plannerSelectionDidChange,
            object: selection,
            queue: nil
        ) { notification in
            box.fields.append(notification.userInfo?[SelectionUserInfoKey.changedFields] as? Set<String> ?? [])
        }
        body()
        NotificationCenter.default.removeObserver(token)
        return box.fields
    }
}
