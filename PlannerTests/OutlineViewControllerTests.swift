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

    func testContextMenuSelectsRowAndOmitsRename() throws {
        let outline = makeOutline()
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        outline.outlineView.expandItem(project)

        let projectRow = outline.outlineView.row(forItem: project)
        let projectMenu = outline.outlineView.menu(forRow: projectRow)
        XCTAssertEqual(outline.outlineView.selectedRow, projectRow)
        XCTAssertEqual(projectMenu.items.map(\.title), ["New Task", "Delete\u{2026}"])
        XCTAssertEqual(projectMenu.items.map(\.action), [
            #selector(MainSplitViewController.newTask(_:)),
            #selector(MainSplitViewController.deleteSelected(_:)),
        ])

        let taskRow = outline.outlineView.row(forItem: task)
        let taskMenu = outline.outlineView.menu(forRow: taskRow)
        XCTAssertEqual(outline.outlineView.selectedRow, taskRow)
        XCTAssertEqual(taskMenu.items.map(\.title), ["New Subtask", "Delete\u{2026}"])
        XCTAssertEqual(taskMenu.items.map(\.action), [
            #selector(MainSplitViewController.newSubtask(_:)),
            #selector(MainSplitViewController.deleteSelected(_:)),
        ])

        let backgroundMenu = outline.outlineView.menu(forRow: -1)
        XCTAssertEqual(backgroundMenu.items.map(\.title), ["New Project"])
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

        XCTAssertEqual(taskCell.textField?.isSelectable, false)
        XCTAssertEqual(taskCell.textField?.refusesFirstResponder, true)

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
            userDefaults: defaults
        )
        outline.loadViewIfNeeded()
        return outline
    }
}
