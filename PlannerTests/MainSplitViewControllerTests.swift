import XCTest
@testable import Planner

@MainActor
final class MainSplitViewControllerTests: PersistenceTestCase {
    func testNewProjectSelectsCreatedProjectWithoutEditing() {
        let selection = SelectionModel()
        let (split, outline) = makeSplit(selection: selection)

        split.newProject(nil)

        XCTAssertEqual(try model.allProjects().count, 1)
        let project = try! model.allProjects()[0]
        XCTAssertEqual(selection.selectedNodeUUID, project.uuid)
        XCTAssertGreaterThanOrEqual(outline.outlineView.row(forItem: project), 0)
        XCTAssertEqual(outline.outlineView.selectedRow, outline.outlineView.row(forItem: project))
        XCTAssertNil(outline.outlineView.currentEditor())
        XCTAssertEqual(project.title, "Untitled Project")
    }

    func testNewTaskOnProjectCreatesAndSelectsTask() throws {
        let selection = SelectionModel()
        let (split, outline) = makeSplit(selection: selection)
        let project = try model.createProject()
        selection.selectNode(uuid: project.uuid)

        split.newTask(nil)

        let task = try XCTUnwrap(try fetchAllTasks().first)
        XCTAssertEqual(task.project, project)
        XCTAssertEqual(selection.selectedNodeUUID, task.uuid)
        XCTAssertTrue(outline.outlineView.isItemExpanded(project))
        XCTAssertGreaterThanOrEqual(outline.outlineView.row(forItem: task), 0)
        XCTAssertNil(outline.outlineView.currentEditor())
    }

    func testNewTaskOnTaskCreatesSibling() throws {
        let selection = SelectionModel()
        let (split, _) = makeSplit(selection: selection)
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        selection.selectNode(uuid: task.uuid)

        split.newTask(nil)

        let tasks = try fetchAllTasks()
        XCTAssertEqual(tasks.count, 2)
        let sibling = try XCTUnwrap(tasks.first { $0.uuid != task.uuid })
        XCTAssertEqual(sibling.project, project)
        XCTAssertNil(sibling.parentTask)
        XCTAssertEqual(selection.selectedNodeUUID, sibling.uuid)
    }

    func testNewSubtaskCreatesChildAndExpandsParent() throws {
        let selection = SelectionModel()
        let (split, outline) = makeSplit(selection: selection)
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        selection.selectNode(uuid: task.uuid)

        split.newSubtask(nil)

        let subtask = try XCTUnwrap(try fetchAllTasks().first { $0.parentTask == task })
        XCTAssertEqual(selection.selectedNodeUUID, subtask.uuid)
        XCTAssertTrue(outline.outlineView.isItemExpanded(task))
        XCTAssertGreaterThanOrEqual(outline.outlineView.row(forItem: subtask), 0)
        XCTAssertNil(outline.outlineView.currentEditor())
    }

    func testCreateSaveFailedDoesNotChangeSelection() throws {
        let selection = SelectionModel()
        let (split, _) = makeSplit(selection: selection)
        let project = try model.createProject()
        selection.selectNode(uuid: project.uuid)

        persistence.failNextSave = true
        split.newTask(nil)

        XCTAssertEqual(selection.selectedNodeUUID, project.uuid)
        XCTAssertTrue(try fetchAllTasks().isEmpty)
    }

    func testDeleteSelectsPreviousSiblingThenParent() throws {
        let selection = SelectionModel()
        let (split, outline) = makeSplit(selection: selection)
        let project = try model.createProject()
        let first = try model.createTask(in: project)
        let second = try model.createTask(in: project)
        outline.outlineView.expandItem(project)

        let secondUUID = second.uuid
        selection.selectNode(uuid: second.uuid)
        split.deleteSelected(confirmed: true)
        XCTAssertEqual(selection.selectedNodeUUID, first.uuid)
        XCTAssertNil(try model.task(uuid: secondUUID))

        split.deleteSelected(confirmed: true)
        XCTAssertEqual(selection.selectedNodeUUID, project.uuid)
        XCTAssertTrue(try fetchAllTasks().isEmpty)
    }

    func testDeleteLastProjectClearsSelection() throws {
        let selection = SelectionModel()
        let (split, _) = makeSplit(selection: selection)
        let project = try model.createProject()
        selection.selectNode(uuid: project.uuid)

        split.deleteSelected(confirmed: true)

        XCTAssertNil(selection.selectedNodeUUID)
        XCTAssertTrue(try model.allProjects().isEmpty)
    }

    func testDeleteCancelLeavesTreeUnchanged() throws {
        let selection = SelectionModel()
        let (split, _) = makeSplit(selection: selection)
        let project = try model.createProject()
        selection.selectNode(uuid: project.uuid)

        split.deleteSelected(confirmed: false)

        XCTAssertEqual(selection.selectedNodeUUID, project.uuid)
        XCTAssertNotNil(try model.project(uuid: project.uuid))
    }

    func testDeleteSaveFailedDoesNotChangeSelection() throws {
        let selection = SelectionModel()
        let (split, _) = makeSplit(selection: selection)
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        selection.selectNode(uuid: task.uuid)

        persistence.failNextSave = true
        split.deleteSelected(confirmed: true)

        XCTAssertEqual(selection.selectedNodeUUID, task.uuid)
        XCTAssertNotNil(try model.task(uuid: task.uuid))
    }

    func testDeletingLastSubtaskRemovesDisclosureTriangle() throws {
        let selection = SelectionModel()
        let (split, outline) = makeSplit(selection: selection)
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        let subtask = try model.createSubtask(under: task)
        outline.outlineView.expandItem(project)
        outline.outlineView.expandItem(task)
        XCTAssertTrue(outline.outlineView.isExpandable(task))

        selection.selectNode(uuid: subtask.uuid)
        split.deleteSelected(confirmed: true)

        XCTAssertFalse(outline.outlineView.isExpandable(task))
        XCTAssertEqual(selection.selectedNodeUUID, task.uuid)
    }

    func testValidateMenuAndToolbarItems() throws {
        let selection = SelectionModel()
        let (split, _) = makeSplit(selection: selection)

        XCTAssertTrue(split.validateMenuItem(menuItem(#selector(MainSplitViewController.newProject(_:)))))
        XCTAssertFalse(split.validateMenuItem(menuItem(#selector(MainSplitViewController.newTask(_:)))))
        XCTAssertFalse(split.validateMenuItem(menuItem(#selector(MainSplitViewController.newSubtask(_:)))))
        XCTAssertFalse(split.validateMenuItem(menuItem(#selector(MainSplitViewController.deleteSelected(_:)))))
        XCTAssertTrue(split.validateMenuItem(menuItem(#selector(MainSplitViewController.revealToday(_:)))))

        let addTask = toolbarItem(.addTask, action: #selector(MainSplitViewController.newTask(_:)))
        XCTAssertFalse(split.validateToolbarItem(addTask))
        XCTAssertTrue(split.validateToolbarItem(toolbarItem(.today, action: #selector(MainSplitViewController.revealToday(_:)))))
        XCTAssertTrue(split.validateToolbarItem(toolbarItem(.addProject, action: #selector(MainSplitViewController.newProject(_:)))))

        let project = try model.createProject()
        selection.selectNode(uuid: project.uuid)
        XCTAssertTrue(split.validateMenuItem(menuItem(#selector(MainSplitViewController.newTask(_:)))))
        XCTAssertFalse(split.validateMenuItem(menuItem(#selector(MainSplitViewController.newSubtask(_:)))))
        XCTAssertTrue(split.validateMenuItem(menuItem(#selector(MainSplitViewController.deleteSelected(_:)))))
        XCTAssertTrue(split.validateToolbarItem(addTask))

        let task = try model.createTask(in: project)
        selection.selectNode(uuid: task.uuid)
        XCTAssertTrue(split.validateMenuItem(menuItem(#selector(MainSplitViewController.newTask(_:)))))
        XCTAssertTrue(split.validateMenuItem(menuItem(#selector(MainSplitViewController.newSubtask(_:)))))
        XCTAssertTrue(split.validateMenuItem(menuItem(#selector(MainSplitViewController.deleteSelected(_:)))))
    }

    func testTextInputResponderDetection() {
        XCTAssertFalse(MainSplitViewController.isTextInputResponder(nil))
        XCTAssertTrue(MainSplitViewController.isTextInputResponder(NSTextView()))
        XCTAssertTrue(MainSplitViewController.isTextInputResponder(NSText()))
        let label = NSTextField(labelWithString: "x")
        XCTAssertFalse(MainSplitViewController.isTextInputResponder(label))
        let selectableTitle = NSTextField(labelWithString: "Untitled Task")
        selectableTitle.isSelectable = true
        selectableTitle.isEditable = false
        XCTAssertFalse(MainSplitViewController.isTextInputResponder(selectableTitle))
        let editable = NSTextField(string: "hello")
        editable.isEditable = true
        XCTAssertFalse(MainSplitViewController.isTextInputResponder(editable))
    }

    func testTextInputFirstResponderDisablesMutatingCommands() throws {
        let selection = SelectionModel()
        let (split, _) = makeSplit(selection: selection)
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        selection.selectNode(uuid: task.uuid)

        split.firstResponderForValidation = NSTextView()

        XCTAssertTrue(split.validateMenuItem(menuItem(#selector(MainSplitViewController.newProject(_:)))))
        XCTAssertFalse(split.validateMenuItem(menuItem(#selector(MainSplitViewController.newTask(_:)))))
        XCTAssertFalse(split.validateMenuItem(menuItem(#selector(MainSplitViewController.newSubtask(_:)))))
        XCTAssertFalse(split.validateMenuItem(menuItem(#selector(MainSplitViewController.deleteSelected(_:)))))
        XCTAssertFalse(split.validateToolbarItem(
            toolbarItem(.addTask, action: #selector(MainSplitViewController.newTask(_:)))
        ))

        split.deleteSelected(nil)
        XCTAssertNotNil(try model.task(uuid: task.uuid))

        split.firstResponderForValidation = nil
        XCTAssertTrue(split.validateMenuItem(menuItem(#selector(MainSplitViewController.deleteSelected(_:)))))
    }

    func testDeleteConfirmationMessages() throws {
        let project = try model.createProject()
        try model.setTitle(project, "Inbox")
        XCTAssertEqual(
            MainSplitViewController.deleteConfirmationMessage(for: project),
            "Delete “Inbox” and all of its tasks?"
        )

        let leaf = try model.createTask(in: project)
        try model.setTitle(leaf, "Milk")
        XCTAssertEqual(
            MainSplitViewController.deleteConfirmationMessage(for: leaf),
            "Delete “Milk”?"
        )

        let parent = try model.createTask(in: project)
        try model.setTitle(parent, "Shopping")
        _ = try model.createSubtask(under: parent)
        XCTAssertEqual(
            MainSplitViewController.deleteConfirmationMessage(for: parent),
            "Delete “Shopping” and all of its subtasks?"
        )
    }

    func testRevealTodaySetsVisibleMonth() {
        let selection = SelectionModel()
        let past = Calendar.current.date(byAdding: .month, value: -3, to: Date())!
        selection.setVisibleMonth(past)
        XCTAssertNotEqual(selection.visibleMonth, Calendar.current.startOfMonth(for: Date()))

        let (split, _) = makeSplit(selection: selection)
        split.revealToday(nil)
        XCTAssertEqual(selection.visibleMonth, Calendar.current.startOfMonth(for: Date()))
    }

    private func makeSplit(
        selection: SelectionModel = SelectionModel()
    ) -> (MainSplitViewController, OutlineViewController) {
        let split = MainSplitViewController(
            persistence: persistence,
            model: model,
            selection: selection
        )
        split.loadViewIfNeeded()
        let outline = split.splitViewItems[0].viewController as! OutlineViewController
        outline.loadViewIfNeeded()
        return (split, outline)
    }

    private func menuItem(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "")
    }

    private func toolbarItem(
        _ identifier: NSToolbarItem.Identifier,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.action = action
        return item
    }
}
