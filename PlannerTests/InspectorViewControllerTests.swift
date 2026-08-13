import CoreData
import XCTest
@testable import Planner

@MainActor
final class InspectorViewControllerTests: PersistenceTestCase {
    func testEmptySelectionShowsPlaceholder() {
        let inspector = makeInspector()

        XCTAssertEqual(inspector.test_title, "Select a task")
        XCTAssertFalse(inspector.test_titleEnabled)
        XCTAssertTrue(inspector.test_completedHidden)
        XCTAssertTrue(inspector.test_deadlineRowHidden)
        XCTAssertTrue(inspector.test_notesHidden)
        XCTAssertFalse(inspector.test_notesEditable)
        XCTAssertTrue(inspector.test_captionHidden)
    }

    func testTaskSelectionShowsFields() throws {
        let selection = SelectionModel()
        let inspector = makeInspector(selection: selection)
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        try model.setNote(task, "existing")
        try model.setCompleted(true, on: task)

        selection.selectNode(uuid: task.uuid)

        XCTAssertEqual(inspector.test_title, task.title)
        XCTAssertTrue(inspector.test_titleEnabled)
        XCTAssertFalse(inspector.test_completedHidden)
        XCTAssertEqual(inspector.test_completedState, .on)
        XCTAssertFalse(inspector.test_deadlineRowHidden)
        XCTAssertEqual(inspector.test_hasDeadlineState, .off)
        XCTAssertFalse(inspector.test_datePickerEnabled)
        XCTAssertFalse(inspector.test_notesHidden)
        XCTAssertTrue(inspector.test_notesEditable)
        XCTAssertEqual(inspector.test_notes, "existing")
        XCTAssertTrue(inspector.test_captionHidden)
    }

    func testProjectSelectionHidesTaskFieldsAndShowsCaption() throws {
        let selection = SelectionModel()
        let inspector = makeInspector(selection: selection)
        let project = try model.createProject()
        try model.setTitle(project, "Garden")
        let parent = try model.createTask(in: project)
        try model.createSubtask(under: parent)

        selection.selectNode(uuid: project.uuid)

        XCTAssertEqual(inspector.test_title, "Garden")
        XCTAssertTrue(inspector.test_titleEnabled)
        XCTAssertTrue(inspector.test_completedHidden)
        XCTAssertTrue(inspector.test_deadlineRowHidden)
        XCTAssertTrue(inspector.test_notesHidden)
        XCTAssertFalse(inspector.test_notesEditable)
        XCTAssertFalse(inspector.test_captionHidden)
        XCTAssertEqual(inspector.test_caption, "2 tasks")
    }

    func testVisibleMonthChangeDoesNotRebindOrFlush() throws {
        let selection = SelectionModel()
        let inspector = makeInspector(selection: selection)
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        selection.selectNode(uuid: task.uuid)

        inspector.test_setNotes("draft")
        let later = Calendar.current.date(byAdding: .month, value: 1, to: selection.visibleMonth)!
        selection.setVisibleMonth(later)

        XCTAssertNil(task.note)
        XCTAssertEqual(inspector.test_notes, "draft")
        XCTAssertEqual(inspector.test_title, task.title)
    }

    func testCompletedCheckboxMirrorsAndWritesSetCompleted() throws {
        let selection = SelectionModel()
        let inspector = makeInspector(selection: selection)
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        selection.selectNode(uuid: task.uuid)

        XCTAssertEqual(inspector.test_completedState, .off)

        inspector.test_clickCompleted()
        XCTAssertTrue(task.isCompleted)
        XCTAssertEqual(inspector.test_completedState, .on)

        try model.setCompleted(false, on: task)
        XCTAssertEqual(inspector.test_completedState, .off)
    }

    func testHasDeadlineCheckboxSetsAndClearsDeadline() throws {
        let selection = SelectionModel()
        let inspector = makeInspector(selection: selection)
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        selection.selectNode(uuid: task.uuid)

        XCTAssertNil(task.deadline)
        XCTAssertFalse(inspector.test_datePickerEnabled)

        inspector.test_clickHasDeadline()
        XCTAssertNotNil(task.deadline)
        XCTAssertEqual(inspector.test_hasDeadlineState, .on)
        XCTAssertTrue(inspector.test_datePickerEnabled)
        XCTAssertEqual(
            task.deadline,
            Calendar.current.startOfDay(for: inspector.test_datePickerValue)
        )

        let nextWeek = Calendar.current.date(byAdding: .day, value: 7, to: Date())!
        inspector.test_setDatePicker(nextWeek)
        XCTAssertEqual(task.deadline, Calendar.current.startOfDay(for: nextWeek))

        inspector.test_clickHasDeadline()
        XCTAssertNil(task.deadline)
        XCTAssertEqual(inspector.test_hasDeadlineState, .off)
        XCTAssertFalse(inspector.test_datePickerEnabled)
    }

    func testSelectionChangeFlushesPreviousTaskThenBinds() throws {
        let selection = SelectionModel()
        let inspector = makeInspector(selection: selection)
        let project = try model.createProject()
        let first = try model.createTask(in: project)
        let second = try model.createTask(in: project)
        try model.setNote(second, "second")
        selection.selectNode(uuid: first.uuid)

        inspector.test_setNotes("from first")
        selection.selectNode(uuid: second.uuid)

        XCTAssertEqual(first.note, "from first")
        XCTAssertEqual(inspector.test_notes, "second")
        XCTAssertEqual(inspector.test_title, second.title)
    }

    func testEmptyNoteStoresNil() throws {
        let selection = SelectionModel()
        let inspector = makeInspector(selection: selection)
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        try model.setNote(task, "keep")
        selection.selectNode(uuid: task.uuid)

        inspector.test_setNotes("")
        inspector.flushPendingNote()

        XCTAssertNil(task.note)
    }

    func testNoteUndoManagerIsDedicatedAndResetsOnNodeChange() throws {
        let selection = SelectionModel()
        let inspector = makeInspector(selection: selection)
        let project = try model.createProject()
        let first = try model.createTask(in: project)
        let second = try model.createTask(in: project)
        selection.selectNode(uuid: first.uuid)

        let firstManager = inspector.test_noteUndoManager
        XCTAssertTrue(firstManager !== persistence.viewContext.undoManager)

        let viaDelegate = inspector.textView(NSTextView(), undoManagerForTextView: NSTextView())
        XCTAssertTrue(viaDelegate === firstManager)

        selection.selectNode(uuid: second.uuid)
        XCTAssertTrue(inspector.test_noteUndoManager !== firstManager)
        XCTAssertTrue(inspector.test_noteUndoManager !== persistence.viewContext.undoManager)
    }

    func testTimerIgnoresMismatchedObjectID() throws {
        let selection = SelectionModel()
        let inspector = makeInspector(selection: selection)
        let project = try model.createProject()
        let first = try model.createTask(in: project)
        let second = try model.createTask(in: project)
        selection.selectNode(uuid: first.uuid)

        inspector.test_setNotes("stale")
        inspector.test_saveNoteIfMatching(second.objectID)

        XCTAssertNil(first.note)
        XCTAssertNil(second.note)
    }

    func testFlushDoesNotWriteWhenNoteUnchanged() throws {
        let selection = SelectionModel()
        let inspector = makeInspector(selection: selection)
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        try model.setNote(task, "same")
        let updatedAt = task.updatedAt
        selection.selectNode(uuid: task.uuid)

        inspector.flushPendingNote()

        XCTAssertEqual(task.note, "same")
        XCTAssertEqual(task.updatedAt, updatedAt)
    }

    private func makeInspector(selection: SelectionModel = SelectionModel()) -> InspectorViewController {
        let inspector = InspectorViewController(
            persistence: persistence,
            model: model,
            selection: selection
        )
        inspector.loadViewIfNeeded()
        return inspector
    }
}
