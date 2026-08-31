import CoreData
import XCTest
@testable import Planner

@MainActor
final class InspectorViewControllerTests: PersistenceTestCase {
    func testEmptySelectionShowsPlaceholder() {
        let inspector = makeInspector()

        XCTAssertEqual(inspector.test_title, "Select a task to edit its note")
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

    func testDaySelectionShowsANoteWithNoDueDateOrCompletion() throws {
        let selection = SelectionModel()
        let inspector = makeInspector(selection: selection)
        let day = Calendar.current.startOfDay(for: Date())
        try model.setDayNote("groceries", on: day)

        selection.selectDay(day)

        XCTAssertTrue(inspector.test_titleEnabled)
        XCTAssertFalse(inspector.test_notesHidden)
        XCTAssertTrue(inspector.test_notesEditable)
        XCTAssertEqual(inspector.test_notes, "groceries")
        // A day has a note and nothing else.
        XCTAssertTrue(inspector.test_completedHidden)
        XCTAssertTrue(inspector.test_deadlineRowHidden)
        XCTAssertTrue(inspector.test_captionHidden, "Today / Tomorrow do not belong on the day")
        XCTAssertNotEqual(inspector.test_title, "Today")
        XCTAssertNotEqual(inspector.test_title, "Tomorrow")
    }

    func testDayWithNoNoteYetShowsAnEmptyEditableBuffer() {
        let selection = SelectionModel()
        let inspector = makeInspector(selection: selection)
        let day = Calendar.current.startOfDay(for: Date())

        selection.selectDay(day)

        XCTAssertEqual(inspector.test_notes, "")
        XCTAssertTrue(inspector.test_notesEditable)
        XCTAssertNil(model.dayNote(for: day), "binding alone must not create a row")
    }

    func testTypingADayNoteCreatesItAndSwitchingAwayFlushes() throws {
        let selection = SelectionModel()
        let inspector = makeInspector(selection: selection)
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        let day = Calendar.current.startOfDay(for: Date())

        selection.selectDay(day)
        inspector.test_setNotes("call the plumber")
        XCTAssertNil(model.dayNote(for: day), "debounced, not written yet")

        // Selecting a task flushes the day note before rebinding.
        selection.selectNode(uuid: task.uuid)

        XCTAssertEqual(model.dayNote(for: day)?.note, "call the plumber")
        XCTAssertEqual(inspector.test_notes, "")
    }

    func testDayNotesAreKeptSeparateFromTaskNotes() throws {
        let selection = SelectionModel()
        let inspector = makeInspector(selection: selection)
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        try model.setNote(task, "task note")
        let day = Calendar.current.startOfDay(for: Date())
        try model.setDayNote("day note", on: day)

        selection.selectNode(uuid: task.uuid)
        XCTAssertEqual(inspector.test_notes, "task note")

        selection.selectDay(day)
        XCTAssertEqual(inspector.test_notes, "day note")

        selection.selectNode(uuid: task.uuid)
        XCTAssertEqual(inspector.test_notes, "task note")
        XCTAssertEqual(task.note, "task note", "editing one never rewrites the other")
        XCTAssertEqual(model.dayNote(for: day)?.note, "day note")
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
        let later = Calendar.current.date(byAdding: .day, value: 7, to: selection.visibleWeekStart)!
        selection.setVisibleWeekStart(later)

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

    /// The picker already names the date. Today / Tomorrow next to it were
    /// redundant; Overdue stays because a red field is easy to miss.
    func testDueCaptionIsOnlyOverdue() throws {
        let selection = SelectionModel()
        let inspector = makeInspector(selection: selection)
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        selection.selectNode(uuid: task.uuid)

        inspector.test_clickHasDeadline()
        XCTAssertTrue(inspector.test_dueCaptionHidden, "today's due date must not say Today")

        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        inspector.test_setDatePicker(tomorrow)
        XCTAssertTrue(inspector.test_dueCaptionHidden, "tomorrow's due date must not say Tomorrow")

        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        inspector.test_setDatePicker(yesterday)
        XCTAssertFalse(inspector.test_dueCaptionHidden)
        XCTAssertEqual(inspector.test_dueCaption, "Overdue")
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

        XCTAssertTrue(inspector.flushPendingNote())

        XCTAssertEqual(task.note, "same")
        XCTAssertEqual(task.updatedAt, updatedAt)
    }

    func testFlushFailureIsReportedAndKeepsBuffer() throws {
        let selection = SelectionModel()
        let inspector = makeInspector(selection: selection)
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        selection.selectNode(uuid: task.uuid)
        inspector.test_setNotes("unsaved")

        persistence.failNextSave = true
        XCTAssertFalse(inspector.flushPendingNote())

        XCTAssertNil(task.note)
        XCTAssertEqual(inspector.test_notes, "unsaved")
        XCTAssertFalse(persistence.viewContext.hasChanges)
    }

    /// A failed save used to be silent — the buffer stayed dirty and the user
    /// had no idea their note wasn't persisting.
    func testFailedNoteSaveShowsTheErrorUntilASaveSucceeds() throws {
        let selection = SelectionModel()
        let inspector = makeInspector(selection: selection)
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        selection.selectNode(uuid: task.uuid)
        inspector.test_setNotes("unsaved")
        XCTAssertTrue(inspector.test_noteSaveErrorHidden)

        persistence.failNextSave = true
        XCTAssertFalse(inspector.flushPendingNote())
        XCTAssertFalse(inspector.test_noteSaveErrorHidden)

        XCTAssertTrue(inspector.flushPendingNote())
        XCTAssertTrue(inspector.test_noteSaveErrorHidden)
        XCTAssertEqual(task.note, "unsaved")
    }

    func testFailedFlushOnNodeChangeKeepsBufferAndRevertsSelection() throws {
        let selection = SelectionModel()
        let inspector = makeInspector(selection: selection)
        let project = try model.createProject()
        let first = try model.createTask(in: project)
        let second = try model.createTask(in: project)
        selection.selectNode(uuid: first.uuid)
        inspector.test_setNotes("keep me")

        persistence.failNextSave = true
        selection.selectNode(uuid: second.uuid)

        XCTAssertEqual(inspector.test_notes, "keep me")
        XCTAssertEqual(inspector.test_title, first.title)
        XCTAssertEqual(selection.selectedNodeUUID, first.uuid)
        XCTAssertNil(first.note)
        XCTAssertNil(second.note)
    }

    func testUndoOfCompletedRefreshesInspectorWithoutSave() throws {
        let selection = SelectionModel()
        let inspector = makeInspector(selection: selection)
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        selection.selectNode(uuid: task.uuid)

        inspector.test_clickCompleted()
        XCTAssertTrue(task.isCompleted)
        XCTAssertEqual(inspector.test_completedState, .on)

        persistence.viewContext.undoManager?.undo()
        XCTAssertFalse(task.isCompleted)
        XCTAssertEqual(inspector.test_completedState, .off)
    }

    func testFailedFlushKeepsDirtyNotesAfterLaterAttributeSave() throws {
        let selection = SelectionModel()
        let inspector = makeInspector(selection: selection)
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        selection.selectNode(uuid: task.uuid)
        inspector.test_setNotes("unsaved")

        persistence.failNextSave = true
        XCTAssertFalse(inspector.flushPendingNote())
        XCTAssertEqual(inspector.test_notes, "unsaved")

        try model.setCompleted(true, on: task)
        XCTAssertTrue(task.isCompleted)
        XCTAssertEqual(inspector.test_completedState, .on)
        XCTAssertEqual(inspector.test_notes, "unsaved")
        XCTAssertNil(task.note)
    }

    func testSuccessfulFlushDoesNotRewriteNotesOrResetCaret() throws {
        let selection = SelectionModel()
        let inspector = makeInspector(selection: selection)
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        selection.selectNode(uuid: task.uuid)
        inspector.test_setNotes("hello")
        inspector.test_notesSelectedRange = NSRange(location: 5, length: 0)

        XCTAssertTrue(inspector.flushPendingNote())

        XCTAssertEqual(task.note, "hello")
        XCTAssertEqual(inspector.test_notes, "hello")
        XCTAssertEqual(inspector.test_notesSelectedRange.location, 5)
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

@MainActor
final class InspectorNotesLayoutTests: PersistenceTestCase {
    /// A hand-built NSTextView gets a finite default container height, which
    /// silently stops laying out text past it — long notes looked truncated.
    func testNotesContainerHasNoHeightLimit() {
        let inspector = makeLayoutInspector()
        XCTAssertEqual(inspector.test_notesContainerHeight, .greatestFiniteMagnitude)
    }

    func testTheNoteUsesTheFindBarAndTextKit2() {
        let inspector = makeLayoutInspector()
        XCTAssertTrue(inspector.test_notesUsesFindBar)
        // A note built without AppKit's own initialiser has no text stack at
        // all and cannot be edited; TextKit 2 is the proof it went the right way.
        XCTAssertTrue(inspector.test_notesUsesTextKit2)
    }

    func testNotesTakeTheAvailableHeightWhenShownAndYieldItWhenHidden() throws {
        let selection = SelectionModel()
        let inspector = makeLayoutInspector(selection: selection)
        let project = try model.createProject()
        let task = try model.createTask(in: project)

        selection.selectNode(uuid: task.uuid)
        XCTAssertFalse(inspector.test_notesHidden)
        XCTAssertTrue(
            inspector.test_bottomSpacerHidden,
            "with a note showing, the field takes the slack rather than a spacer"
        )

        // A project has no note; the spacer keeps its title at the top.
        selection.selectNode(uuid: project.uuid)
        XCTAssertTrue(inspector.test_notesHidden)
        XCTAssertFalse(inspector.test_bottomSpacerHidden)
    }

    private func makeLayoutInspector(selection: SelectionModel = SelectionModel()) -> InspectorViewController {
        let inspector = InspectorViewController(
            persistence: persistence,
            model: model,
            selection: selection
        )
        inspector.loadViewIfNeeded()
        return inspector
    }
}


@MainActor
final class InspectorNoteClickTests: PersistenceTestCase {
    /// Clicking an empty note has to reach the text view. The placeholder sits
    /// on top of it, at exactly the spot anyone clicks to start typing.
    func testClickingWhereThePlaceholderDrawsReachesTheNote() throws {
        let selection = SelectionModel()
        let inspector = InspectorViewController(persistence: persistence, model: model, selection: selection)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = inspector
        defer { window.contentViewController = nil }

        let project = try model.createProject()
        let task = try model.createTask(in: project)
        selection.selectNode(uuid: task.uuid)
        window.layoutIfNeeded()

        XCTAssertTrue(inspector.test_notesEditable)
        XCTAssertTrue(
            inspector.test_viewHitWhereThePlaceholderDraws() is NoteTextView,
            "the placeholder must not swallow the click that starts editing"
        )

        // And the focused view really takes text, end to end into the store.
        XCTAssertTrue(window.makeFirstResponder(inspector.test_viewHitWhereThePlaceholderDraws()))
        inspector.test_setNotes("typed by hand")
        XCTAssertTrue(inspector.flushPendingNote())
        XCTAssertEqual(model.noteText(of: task).string, "typed by hand")
    }
}
