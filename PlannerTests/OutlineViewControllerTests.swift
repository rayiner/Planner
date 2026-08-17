import CoreData
import XCTest
@testable import Planner

@MainActor
final class OutlineViewControllerTests: PersistenceTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "Planner.OutlineViewControllerTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testCreateSaveRowForItemRemainsValidAfterProcessPendingChanges() throws {
        let outline = makeOutline()
        let project = try model.createProject()

        XCTAssertFalse(project.objectID.isTemporaryID)
        let row = outline.outlineView.row(forItem: project)
        XCTAssertGreaterThanOrEqual(row, 0)

        persistence.viewContext.processPendingChanges()
        XCTAssertEqual(outline.outlineView.row(forItem: project), row)

        let task = try model.createTask(in: project)
        XCTAssertFalse(task.objectID.isTemporaryID)
        outline.outlineView.expandItem(project)
        let taskRow = outline.outlineView.row(forItem: task)
        XCTAssertGreaterThanOrEqual(taskRow, 0)

        persistence.viewContext.processPendingChanges()
        XCTAssertEqual(outline.outlineView.row(forItem: task), taskRow)
    }

    func testSelectionModelNodeChangeRevealsRow() throws {
        let selection = SelectionModel()
        let outline = makeOutline(selection: selection)
        let project = try model.createProject()
        let task = try model.createTask(in: project)

        selection.selectNode(uuid: task.uuid)

        let row = outline.outlineView.row(forItem: task)
        XCTAssertGreaterThanOrEqual(row, 0)
        XCTAssertEqual(outline.outlineView.selectedRow, row)
        XCTAssertTrue(outline.outlineView.isItemExpanded(project))
    }

    func testContextMenuSelectsRowAndIncludesRename() throws {
        let outline = makeOutline()
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        outline.outlineView.expandItem(project)

        let projectRow = outline.outlineView.row(forItem: project)
        let projectMenu = outline.outlineView.menu(forRow: projectRow)
        XCTAssertEqual(outline.outlineView.selectedRow, projectRow)
        XCTAssertEqual(projectMenu.items.map(\.title), ["New Task", "Rename", "Delete\u{2026}"])
        XCTAssertEqual(projectMenu.items.map(\.action), [
            #selector(MainSplitViewController.newTask(_:)),
            #selector(MainSplitViewController.renameSelected(_:)),
            #selector(MainSplitViewController.deleteSelected(_:)),
        ])

        let taskRow = outline.outlineView.row(forItem: task)
        let taskMenu = outline.outlineView.menu(forRow: taskRow)
        XCTAssertEqual(outline.outlineView.selectedRow, taskRow)
        XCTAssertEqual(taskMenu.items.map(\.title), ["New Task", "Rename", "Get Info", "Delete\u{2026}"])
        XCTAssertEqual(taskMenu.items.map(\.action), [
            #selector(MainSplitViewController.newTask(_:)),
            #selector(MainSplitViewController.renameSelected(_:)),
            #selector(MainSplitViewController.showTaskInfo(_:)),
            #selector(MainSplitViewController.deleteSelected(_:)),
        ])

        let backgroundMenu = outline.outlineView.menu(forRow: -1)
        XCTAssertEqual(backgroundMenu.items.map(\.title), ["New Project", "New Folder"])
        XCTAssertEqual(backgroundMenu.items.first?.action, #selector(MainSplitViewController.newProject(_:)))
    }

    func testCompleteCheckboxHiddenOnProjectAndTogglesTask() throws {
        let outline = makeOutline()
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        outline.outlineView.expandItem(project)

        let projectRow = outline.outlineView.row(forItem: project)
        let projectCell = outline.outlineView.view(atColumn: 0, row: projectRow, makeIfNecessary: true)!
        let projectButton = completeButton(in: projectCell)
        XCTAssertNotNil(projectButton)
        XCTAssertTrue(projectButton?.isHidden == true)

        let taskRow = outline.outlineView.row(forItem: task)
        let taskCell = outline.outlineView.view(atColumn: 0, row: taskRow, makeIfNecessary: true) as! NSTableCellView
        let taskButton = completeButton(in: taskCell)
        XCTAssertNotNil(taskButton)
        XCTAssertFalse(taskButton?.isHidden == true)
        XCTAssertEqual(taskButton?.state, .off)

        let titleField = try XCTUnwrap(taskCell.textField as? TitleTextField)
        XCTAssertTrue(titleField.isEditable)
        XCTAssertTrue(titleField.isSelectable)
        XCTAssertFalse(titleField.allowsFirstResponder)
        XCTAssertFalse(titleField.acceptsFirstResponder)

        taskButton?.state = .on
        _ = taskButton?.sendAction(taskButton?.action, to: taskButton?.target)
        XCTAssertTrue(task.isCompleted)

        let reloaded = outline.outlineView.view(atColumn: 0, row: taskRow, makeIfNecessary: true)!
        XCTAssertEqual(completeButton(in: reloaded)?.state, .on)
    }

    func testCompleteCheckboxDoesNotRollUpParentOrChild() throws {
        let outline = makeOutline()
        let project = try model.createProject()
        let parent = try model.createTask(in: project)
        let child = try model.createSubtask(under: parent)
        outline.outlineView.expandItem(project)
        outline.outlineView.expandItem(parent)

        let parentRow = outline.outlineView.row(forItem: parent)
        let parentButton = completeButton(
            in: outline.outlineView.view(atColumn: 0, row: parentRow, makeIfNecessary: true)!
        )
        parentButton?.state = .on
        _ = parentButton?.sendAction(parentButton?.action, to: parentButton?.target)
        XCTAssertTrue(parent.isCompleted)
        XCTAssertFalse(child.isCompleted)

        let childRow = outline.outlineView.row(forItem: child)
        let childCell = outline.outlineView.view(atColumn: 0, row: childRow, makeIfNecessary: true)!
        XCTAssertEqual(completeButton(in: childCell)?.state, .off)

        try model.setCompleted(false, on: parent)
        let childButton = completeButton(in: childCell)
        childButton?.state = .on
        _ = childButton?.sendAction(childButton?.action, to: childButton?.target)
        XCTAssertTrue(child.isCompleted)
        XCTAssertFalse(parent.isCompleted)
        let parentReloaded = outline.outlineView.view(atColumn: 0, row: parentRow, makeIfNecessary: true)!
        XCTAssertEqual(completeButton(in: parentReloaded)?.state, .off)
    }

    func testCompleteSaveFailedRestoresCheckbox() throws {
        let outline = makeOutline()
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        outline.outlineView.expandItem(project)

        let row = outline.outlineView.row(forItem: task)
        let button = completeButton(
            in: outline.outlineView.view(atColumn: 0, row: row, makeIfNecessary: true)!
        )
        XCTAssertEqual(button?.state, .off)

        persistence.failNextSave = true
        button?.state = .on
        _ = button?.sendAction(button?.action, to: button?.target)

        XCTAssertFalse(task.isCompleted)
        XCTAssertEqual(button?.state, .off)
        let reloaded = outline.outlineView.view(atColumn: 0, row: row, makeIfNecessary: true)!
        XCTAssertEqual(completeButton(in: reloaded)?.state, .off)
    }

    func testDeletingLastSubtaskRemovesDisclosureTriangle() throws {
        let selection = SelectionModel()
        let outline = makeOutline(selection: selection)
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        let subtask = try model.createSubtask(under: task)
        outline.outlineView.expandItem(project)
        outline.outlineView.expandItem(task)
        XCTAssertTrue(outline.outlineView.isExpandable(task))

        selection.selectNode(uuid: subtask.uuid)
        try model.delete(subtask)

        XCTAssertFalse(outline.outlineView.isExpandable(task))
        XCTAssertEqual(outline.outlineView.row(forItem: subtask), -1)
    }

    func testTitleTextFieldGatesFirstResponder() {
        let field = TitleTextField()
        field.isEditable = true
        field.isSelectable = true
        XCTAssertFalse(field.allowsFirstResponder)
        XCTAssertFalse(field.acceptsFirstResponder)
        field.allowsFirstResponder = true
        XCTAssertTrue(field.acceptsFirstResponder)
    }

    func testViewForClearsAllowsFirstResponder() throws {
        let outline = makeOutline()
        let project = try model.createProject()
        let row = outline.outlineView.row(forItem: project)
        let cell = outline.outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as! NSTableCellView
        let field = try XCTUnwrap(cell.textField as? TitleTextField)
        field.allowsFirstResponder = true

        outline.outlineView.reloadItem(project)
        let reloaded = outline.outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as! NSTableCellView
        let reloadedField = try XCTUnwrap(reloaded.textField as? TitleTextField)
        XCTAssertFalse(reloadedField.allowsFirstResponder)
        XCTAssertFalse(reloadedField.acceptsFirstResponder)
    }

    func testBeginEditingTitleClearsFlagWhenEditColumnFails() throws {
        let outline = makeOutline()
        let project = try model.createProject()
        var began: UUID?
        outline.beginEditingTitleHandler = { began = $0.uuid }

        outline.beginEditingTitle(of: project)

        XCTAssertEqual(began, project.uuid)
        XCTAssertNil(outline.outlineView.currentEditor())
        let row = outline.outlineView.row(forItem: project)
        let cell = outline.outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as! NSTableCellView
        let field = try XCTUnwrap(cell.textField as? TitleTextField)
        XCTAssertFalse(field.allowsFirstResponder)
    }

    func testMouseDownSnapshotsAlreadySelectedRow() throws {
        let outline = makeOutline()
        let project = try model.createProject()
        let other = try model.createProject()
        let row = outline.outlineView.row(forItem: project)
        let otherRow = outline.outlineView.row(forItem: other)
        outline.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

        outline.outlineView.snapshotPendingRename(row: row, clickCount: 1, modifiers: [])
        XCTAssertEqual(outline.outlineView.pendingRenameRow, row)

        outline.outlineView.snapshotPendingRename(row: otherRow, clickCount: 1, modifiers: [])
        XCTAssertEqual(outline.outlineView.pendingRenameRow, -1)

        outline.outlineView.snapshotPendingRename(row: row, clickCount: 2, modifiers: [])
        XCTAssertEqual(outline.outlineView.pendingRenameRow, -1)

        outline.outlineView.snapshotPendingRename(row: row, clickCount: 1, modifiers: .command)
        XCTAssertEqual(outline.outlineView.pendingRenameRow, -1)
    }

    func testMouseDraggedCancelsPendingRename() throws {
        let outline = makeOutline()
        let project = try model.createProject()
        let row = outline.outlineView.row(forItem: project)
        outline.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.outlineView.snapshotPendingRename(row: row, clickCount: 1, modifiers: [])
        XCTAssertEqual(outline.outlineView.pendingRenameRow, row)

        outline.outlineView.mouseDragged(with: NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )!)
        XCTAssertEqual(outline.outlineView.pendingRenameRow, -1)
    }

    func testDragPastThresholdCancelsPendingRename() throws {
        let outline = makeOutline()
        let project = try model.createProject()
        let row = outline.outlineView.row(forItem: project)
        outline.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.outlineView.snapshotPendingRename(row: row, clickCount: 1, modifiers: [])
        outline.outlineView.mouseDownLocationInView = NSPoint(x: 10, y: 10)

        XCTAssertFalse(outline.outlineView.hasDraggedPastThreshold(to: NSPoint(x: 12, y: 10)))
        XCTAssertTrue(outline.outlineView.hasDraggedPastThreshold(
            to: NSPoint(x: 10 + PlannerOutlineView.dragThreshold, y: 10)
        ))

        var began = false
        outline.beginEditingTitleHandler = { _ in began = true }
        outline.scheduleDelayedRename(at: row)
        let generation = outline.renameGeneration
        outline.outlineView.cancelPendingRenameGesture()
        outline.renameTimerFired(row: row, generation: generation)
        XCTAssertFalse(began)
        XCTAssertEqual(outline.outlineView.pendingRenameRow, -1)
    }

    func testReturnAndKeypadEnterBeginEditingSelectedTitle() throws {
        let outline = makeOutline()
        let project = try model.createProject()
        let row = outline.outlineView.row(forItem: project)
        outline.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

        var began: [UUID] = []
        outline.beginEditingTitleHandler = { began.append($0.uuid) }

        outline.outlineView.keyDown(with: keyEvent(characters: "\r", keyCode: 36))
        outline.outlineView.keyDown(with: keyEvent(characters: "\u{3}", keyCode: 76))
        XCTAssertEqual(began, [project.uuid, project.uuid])
    }

    func testEmptyTitleRefusesEndEditing() throws {
        let outline = makeOutline()
        let project = try model.createProject()
        let field = try titleField(in: outline, for: project)
        let emptyEditor = NSTextView()
        emptyEditor.string = "   "
        XCTAssertFalse(outline.control(field, textShouldEndEditing: emptyEditor))

        let okEditor = NSTextView()
        okEditor.string = "Inbox"
        XCTAssertTrue(outline.control(field, textShouldEndEditing: okEditor))
    }

    func testControlTextDidEndEditingSavesTrimmedTitle() throws {
        let outline = makeOutline()
        let project = try model.createProject()
        let field = try titleField(in: outline, for: project)
        field.stringValue = "  Inbox  "
        outline.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification, object: field)
        )
        XCTAssertEqual(project.title, "Inbox")
        XCTAssertFalse(field.allowsFirstResponder)
    }

    func testControlTextDidEndEditingIgnoresUnchangedAndEmpty() throws {
        let outline = makeOutline()
        let project = try model.createProject()
        try model.setTitle(project, "Inbox")
        let field = try titleField(in: outline, for: project)

        field.stringValue = "Inbox"
        outline.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification, object: field)
        )
        XCTAssertEqual(project.title, "Inbox")

        field.stringValue = "   "
        outline.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification, object: field)
        )
        XCTAssertEqual(project.title, "Inbox")
    }

    func testEscapeRestoresTitleWithoutSaving() throws {
        let outline = makeOutline()
        let project = try model.createProject()
        try model.setTitle(project, "Inbox")
        let field = try titleField(in: outline, for: project)
        field.stringValue = "Changed"

        let handled = outline.control(
            field,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        )
        XCTAssertTrue(handled)
        XCTAssertEqual(field.stringValue, "Inbox")
        XCTAssertEqual(project.title, "Inbox")
        XCTAssertFalse(field.allowsFirstResponder)
    }

    func testEscapeRestoresCompletedStrikethrough() throws {
        let outline = makeOutline()
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        try model.setTitle(task, "Milk")
        try model.setCompleted(true, on: task)
        outline.outlineView.expandItem(project)
        let field = try titleField(in: outline, for: task)
        field.stringValue = "Changed"

        XCTAssertTrue(outline.control(
            field,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        ))
        XCTAssertEqual(field.stringValue, "Milk")
        XCTAssertEqual(task.title, "Milk")
        let attributes = field.attributedStringValue.attributes(at: 0, effectiveRange: nil)
        XCTAssertEqual(attributes[.strikethroughStyle] as? Int, NSUnderlineStyle.single.rawValue)
    }

    func testBeginEditingTitleCancelsPendingDelayedRename() throws {
        let outline = makeOutline()
        let project = try model.createProject()
        let row = outline.outlineView.row(forItem: project)
        outline.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

        var began = 0
        outline.beginEditingTitleHandler = { _ in began += 1 }
        outline.scheduleDelayedRename(at: row)
        let generation = outline.renameGeneration
        outline.beginEditingTitle(of: project)
        XCTAssertEqual(began, 1)

        outline.renameTimerFired(row: row, generation: generation)
        XCTAssertEqual(began, 1)
    }

    func testContextMenuCancelsPendingRename() throws {
        let outline = makeOutline()
        let project = try model.createProject()
        let row = outline.outlineView.row(forItem: project)
        outline.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

        var began = false
        outline.beginEditingTitleHandler = { _ in began = true }
        outline.scheduleDelayedRename(at: row)
        outline.outlineView.snapshotPendingRename(row: row, clickCount: 1, modifiers: [])
        let generation = outline.renameGeneration
        _ = outline.outlineView.menu(forRow: row)

        XCTAssertEqual(outline.outlineView.pendingRenameRow, -1)
        outline.renameTimerFired(row: row, generation: generation)
        XCTAssertFalse(began)
    }

    func testSelectionChangeCancelsRenameTimer() throws {
        let outline = makeOutline()
        let project = try model.createProject()
        let other = try model.createProject()
        var began = false
        outline.beginEditingTitleHandler = { _ in began = true }

        let projectRow = outline.outlineView.row(forItem: project)
        outline.outlineView.selectRowIndexes(IndexSet(integer: projectRow), byExtendingSelection: false)
        outline.scheduleDelayedRename(at: projectRow)
        let generation = outline.renameGeneration
        outline.outlineView.selectRowIndexes(
            IndexSet(integer: outline.outlineView.row(forItem: other)),
            byExtendingSelection: false
        )

        outline.renameTimerFired(row: projectRow, generation: generation)
        XCTAssertFalse(began)
        XCTAssertNotEqual(generation, outline.renameGeneration)
    }

    private func titleField(in outline: OutlineViewController, for node: OutlineNode) throws -> TitleTextField {
        let row = outline.outlineView.row(forItem: node)
        XCTAssertGreaterThanOrEqual(row, 0)
        let cell = outline.outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as! NSTableCellView
        return try XCTUnwrap(cell.textField as? TitleTextField)
    }

    private func keyEvent(characters: String, keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    func testNestedSelectionExpandsAncestorsSelectsAndPersists() throws {
        let selection = SelectionModel()
        let outline = makeOutline(selection: selection)
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        let subtask = try model.createSubtask(under: task)
        outline.outlineView.collapseItem(project)
        XCTAssertFalse(outline.outlineView.isItemExpanded(project))

        selection.selectNode(uuid: subtask.uuid)

        XCTAssertTrue(outline.outlineView.isItemExpanded(project))
        XCTAssertTrue(outline.outlineView.isItemExpanded(task))
        let row = outline.outlineView.row(forItem: subtask)
        XCTAssertGreaterThanOrEqual(row, 0)
        XCTAssertEqual(outline.outlineView.selectedRow, row)
        let stored = Set(defaults.stringArray(forKey: OutlineViewController.expandedUUIDsKey) ?? [])
        XCTAssertTrue(stored.contains(project.uuid.uuidString))
        XCTAssertTrue(stored.contains(task.uuid.uuidString))
    }

    func testUnknownSelectionClearsOutlineRow() throws {
        let selection = SelectionModel()
        let outline = makeOutline(selection: selection)
        let project = try model.createProject()
        selection.selectNode(uuid: project.uuid)
        XCTAssertEqual(outline.outlineView.selectedRow, outline.outlineView.row(forItem: project))

        selection.selectNode(uuid: UUID())
        XCTAssertEqual(outline.outlineView.selectedRow, -1)
    }

    func testStaleCacheRevealHidesEmptyState() throws {
        let selection = SelectionModel()
        let outline = makeOutline(selection: selection)
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        outline.test_simulateStaleEmptyProjectsCache()
        XCTAssertTrue(outline.test_isEmptyStateVisible)
        XCTAssertEqual(outline.outlineView.row(forItem: task), -1)

        selection.selectNode(uuid: task.uuid)

        let row = outline.outlineView.row(forItem: task)
        XCTAssertGreaterThanOrEqual(row, 0)
        XCTAssertEqual(outline.outlineView.selectedRow, row)
        XCTAssertTrue(outline.outlineView.isItemExpanded(project))
        XCTAssertFalse(outline.test_isEmptyStateVisible)
    }

    private func completeButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton { return button }
        for subview in view.subviews {
            if let found = completeButton(in: subview) { return found }
        }
        return nil
    }

    private func makeOutline(selection: SelectionModel = SelectionModel()) -> OutlineViewController {
        let outline = OutlineViewController(
            persistence: persistence,
            model: model,
            selection: selection,
            mail: MailCoordinator(source: NullMailSource(), defaults: defaults),
            userDefaults: defaults
        )
        outline.loadViewIfNeeded()
        return outline
    }
}
