import XCTest
@testable import Planner

@MainActor
final class MainSplitViewControllerTests: PersistenceTestCase {
    func testNewProjectSelectsCreatedProjectAndBeginsEditingOnNextRunLoop() async {
        let selection = SelectionModel(defaults: isolatedDefaults())
        let (split, outline) = makeSplit(selection: selection)
        var began: UUID?
        outline.beginEditingTitleHandler = { began = $0.uuid }

        split.newProject(nil)

        XCTAssertEqual(try model.allProjects().count, 1)
        let project = try! model.allProjects()[0]
        XCTAssertEqual(selection.selectedNodeUUID, project.uuid)
        XCTAssertGreaterThanOrEqual(outline.outlineView.row(forItem: project), 0)
        XCTAssertEqual(outline.outlineView.selectedRow, outline.outlineView.row(forItem: project))
        XCTAssertNil(began)
        XCTAssertEqual(project.title, "Untitled Project")

        let scheduled = expectation(description: "begin edit")
        DispatchQueue.main.async { scheduled.fulfill() }
        await fulfillment(of: [scheduled], timeout: 1)
        XCTAssertEqual(began, project.uuid)
        XCTAssertNil(outline.outlineView.currentEditor())
    }

    func testNewTaskOnProjectCreatesAndSelectsTask() async throws {
        let selection = SelectionModel(defaults: isolatedDefaults())
        let (split, outline) = makeSplit(selection: selection)
        let project = try model.createProject()
        selection.selectNode(uuid: project.uuid)

        var began: UUID?
        outline.beginEditingTitleHandler = { began = $0.uuid }
        split.newTask(nil)

        let task = try XCTUnwrap(try fetchAllTasks().first)
        XCTAssertEqual(task.project, project)
        XCTAssertEqual(selection.selectedNodeUUID, task.uuid)
        XCTAssertTrue(outline.outlineView.isItemExpanded(project))
        XCTAssertGreaterThanOrEqual(outline.outlineView.row(forItem: task), 0)
        XCTAssertNil(began)

        let scheduled = expectation(description: "begin edit")
        DispatchQueue.main.async { scheduled.fulfill() }
        await fulfillment(of: [scheduled], timeout: 1)
        XCTAssertEqual(began, task.uuid)
        XCTAssertNil(outline.outlineView.currentEditor())
    }

    func testNewTaskOnTaskCreatesChildAndExpandsParent() async throws {
        let selection = SelectionModel(defaults: isolatedDefaults())
        let (split, outline) = makeSplit(selection: selection)
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        selection.selectNode(uuid: task.uuid)

        var began: UUID?
        outline.beginEditingTitleHandler = { began = $0.uuid }
        split.newTask(nil)

        let child = try XCTUnwrap(try fetchAllTasks().first { $0.parentTask == task })
        XCTAssertNil(child.project)
        XCTAssertEqual(selection.selectedNodeUUID, child.uuid)
        XCTAssertTrue(outline.outlineView.isItemExpanded(task))
        XCTAssertGreaterThanOrEqual(outline.outlineView.row(forItem: child), 0)
        XCTAssertNil(began)

        let scheduled = expectation(description: "begin edit")
        DispatchQueue.main.async { scheduled.fulfill() }
        await fulfillment(of: [scheduled], timeout: 1)
        XCTAssertEqual(began, child.uuid)
        XCTAssertNil(outline.outlineView.currentEditor())
    }

    func testCreateSaveFailedDoesNotChangeSelection() throws {
        let selection = SelectionModel(defaults: isolatedDefaults())
        let (split, _) = makeSplit(selection: selection)
        let project = try model.createProject()
        selection.selectNode(uuid: project.uuid)

        persistence.failNextSave = true
        split.newTask(nil)

        XCTAssertEqual(selection.selectedNodeUUID, project.uuid)
        XCTAssertTrue(try fetchAllTasks().isEmpty)
    }

    /// Structural undo only reaches the outline through a save: the outline
    /// reacts to did-save, and an unsaved undo would also be lost on quit.
    func testUndoOfCreateIsSavedAndRemovesTheOutlineRow() throws {
        let (split, outline) = makeSplit()
        _ = split
        let project = try model.createProject()
        XCTAssertGreaterThanOrEqual(outline.outlineView.row(forItem: project), 0)
        let undoManager = try XCTUnwrap(persistence.viewContext.undoManager)

        undoManager.undo()

        XCTAssertFalse(persistence.viewContext.hasChanges, "the undone create is saved")
        XCTAssertEqual(outline.outlineView.row(forItem: project), -1)
        XCTAssertTrue(try model.allProjects().isEmpty)

        undoManager.redo()

        XCTAssertFalse(persistence.viewContext.hasChanges, "the redone create is saved")
        let row = outline.outlineView.row(forItem: project)
        XCTAssertGreaterThanOrEqual(row, 0)
        XCTAssertEqual((outline.outlineView.item(atRow: row) as? Project)?.uuid, project.uuid)
    }

    func testUndoOfDeleteIsSavedAndRestoresTheOutlineRow() throws {
        let selection = SelectionModel(defaults: isolatedDefaults())
        let (split, outline) = makeSplit(selection: selection)
        let project = try model.createProject()
        let uuid = project.uuid
        selection.selectNode(uuid: uuid)
        let undoManager = try XCTUnwrap(persistence.viewContext.undoManager)
        // In the app the create and the delete are separate user events and so
        // separate by-event undo groups; in a test they share one run-loop
        // cycle. Drop the create from the stack so undo targets the delete.
        undoManager.removeAllActions()

        split.deleteSelected(confirmed: true)
        XCTAssertEqual(outline.outlineView.row(forItem: project), -1)

        undoManager.undo()

        XCTAssertFalse(persistence.viewContext.hasChanges, "the undone delete is saved")
        let row = outline.outlineView.row(forItem: project)
        XCTAssertGreaterThanOrEqual(row, 0)
        XCTAssertEqual((outline.outlineView.item(atRow: row) as? Project)?.uuid, uuid)
    }

    func testDeleteSelectsPreviousSiblingThenParent() throws {
        let selection = SelectionModel(defaults: isolatedDefaults())
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
        let selection = SelectionModel(defaults: isolatedDefaults())
        let (split, _) = makeSplit(selection: selection)
        let project = try model.createProject()
        selection.selectNode(uuid: project.uuid)

        split.deleteSelected(confirmed: true)

        XCTAssertNil(selection.selectedNodeUUID)
        XCTAssertTrue(try model.allProjects().isEmpty)
    }

    func testDeleteCancelLeavesTreeUnchanged() throws {
        let selection = SelectionModel(defaults: isolatedDefaults())
        let (split, _) = makeSplit(selection: selection)
        let project = try model.createProject()
        selection.selectNode(uuid: project.uuid)

        split.deleteSelected(confirmed: false)

        XCTAssertEqual(selection.selectedNodeUUID, project.uuid)
        XCTAssertNotNil(try model.project(uuid: project.uuid))
    }

    func testDeleteSaveFailedDoesNotChangeSelection() throws {
        let selection = SelectionModel(defaults: isolatedDefaults())
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
        let selection = SelectionModel(defaults: isolatedDefaults())
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
        let selection = SelectionModel(defaults: isolatedDefaults())
        let (split, _) = makeSplit(selection: selection)

        XCTAssertTrue(split.validateMenuItem(menuItem(#selector(MainSplitViewController.newProject(_:)))))
        XCTAssertFalse(split.validateMenuItem(menuItem(#selector(MainSplitViewController.newTask(_:)))))
        XCTAssertFalse(split.validateMenuItem(menuItem(#selector(MainSplitViewController.renameSelected(_:)))))
        XCTAssertFalse(split.validateMenuItem(menuItem(#selector(MainSplitViewController.deleteSelected(_:)))))
        XCTAssertFalse(split.validateMenuItem(menuItem(#selector(MainSplitViewController.showTaskInfo(_:)))))
        XCTAssertTrue(split.validateMenuItem(menuItem(#selector(MainSplitViewController.revealToday(_:)))))

        let addTask = toolbarItem(.addTask, action: #selector(MainSplitViewController.newTask(_:)))
        XCTAssertFalse(split.validateToolbarItem(addTask))
        XCTAssertTrue(split.validateToolbarItem(toolbarItem(.today, action: #selector(MainSplitViewController.revealToday(_:)))))
        XCTAssertTrue(split.validateToolbarItem(toolbarItem(.addProject, action: #selector(MainSplitViewController.newProject(_:)))))

        let project = try model.createProject()
        selection.selectNode(uuid: project.uuid)
        XCTAssertTrue(split.validateMenuItem(menuItem(#selector(MainSplitViewController.newTask(_:)))))
        XCTAssertTrue(split.validateMenuItem(menuItem(#selector(MainSplitViewController.renameSelected(_:)))))
        XCTAssertTrue(split.validateMenuItem(menuItem(#selector(MainSplitViewController.deleteSelected(_:)))))
        XCTAssertFalse(split.validateMenuItem(menuItem(#selector(MainSplitViewController.showTaskInfo(_:)))))
        XCTAssertTrue(split.validateToolbarItem(addTask))

        let task = try model.createTask(in: project)
        selection.selectNode(uuid: task.uuid)
        XCTAssertTrue(split.validateMenuItem(menuItem(#selector(MainSplitViewController.newTask(_:)))))
        XCTAssertTrue(split.validateMenuItem(menuItem(#selector(MainSplitViewController.renameSelected(_:)))))
        XCTAssertTrue(split.validateMenuItem(menuItem(#selector(MainSplitViewController.deleteSelected(_:)))))
        XCTAssertTrue(split.validateMenuItem(menuItem(#selector(MainSplitViewController.showTaskInfo(_:)))))
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
        let selection = SelectionModel(defaults: isolatedDefaults())
        let (split, _) = makeSplit(selection: selection)
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        selection.selectNode(uuid: task.uuid)

        split.firstResponderForValidation = NSTextView()

        XCTAssertTrue(split.validateMenuItem(menuItem(#selector(MainSplitViewController.newProject(_:)))))
        XCTAssertFalse(split.validateMenuItem(menuItem(#selector(MainSplitViewController.newTask(_:)))))
        XCTAssertFalse(split.validateMenuItem(menuItem(#selector(MainSplitViewController.renameSelected(_:)))))
        XCTAssertFalse(split.validateMenuItem(menuItem(#selector(MainSplitViewController.deleteSelected(_:)))))
        XCTAssertFalse(split.validateToolbarItem(
            toolbarItem(.addTask, action: #selector(MainSplitViewController.newTask(_:)))
        ))

        split.deleteSelected(nil)
        XCTAssertNotNil(try model.task(uuid: task.uuid))

        split.firstResponderForValidation = nil
        XCTAssertTrue(split.validateMenuItem(menuItem(#selector(MainSplitViewController.deleteSelected(_:)))))
        XCTAssertTrue(split.validateMenuItem(menuItem(#selector(MainSplitViewController.renameSelected(_:)))))
    }

    func testRenameSelectedBeginsEditing() throws {
        let selection = SelectionModel(defaults: isolatedDefaults())
        let (split, outline) = makeSplit(selection: selection)
        let project = try model.createProject()
        selection.selectNode(uuid: project.uuid)

        var began: UUID?
        outline.beginEditingTitleHandler = { began = $0.uuid }
        split.renameSelected(nil)
        XCTAssertEqual(began, project.uuid)
    }

    func testCreateSaveFailedDoesNotBeginEditing() async throws {
        let selection = SelectionModel(defaults: isolatedDefaults())
        let (split, outline) = makeSplit(selection: selection)
        let project = try model.createProject()
        selection.selectNode(uuid: project.uuid)

        var began = false
        outline.beginEditingTitleHandler = { _ in began = true }
        persistence.failNextSave = true
        split.newTask(nil)

        let scheduled = expectation(description: "next run loop")
        DispatchQueue.main.async { scheduled.fulfill() }
        await fulfillment(of: [scheduled], timeout: 1)
        XCTAssertFalse(began)
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
            "Delete “Shopping” and all of its tasks?"
        )
    }

    func testRevealTodaySetsVisibleWeekToToday() {
        let selection = SelectionModel(defaults: isolatedDefaults())
        let past = Calendar.current.date(byAdding: .day, value: -70, to: Date())!
        selection.setVisibleWeekStart(past)
        XCTAssertNotEqual(selection.visibleWeekStart, Calendar.current.startOfDay(for: Date()))

        let (split, _) = makeSplit(selection: selection)
        split.revealToday(nil)
        XCTAssertEqual(selection.visibleWeekStart, Calendar.current.startOfDay(for: Date()))
    }

    func testPreviousAndNextWeekShiftVisibleWeekByColumnCount() {
        let selection = SelectionModel(defaults: isolatedDefaults())
        let start = selection.visibleWeekStart
        let (split, _) = makeSplit(selection: selection)
        let calendar = Calendar.current
        let step = split.test_visibleColumnCount

        split.goToNextWeek(nil)
        XCTAssertEqual(selection.visibleWeekStart, calendar.date(byAdding: .day, value: step, to: start)!)

        split.goToPreviousWeek(nil)
        XCTAssertEqual(selection.visibleWeekStart, start)

        split.goToPreviousWeek(nil)
        XCTAssertEqual(selection.visibleWeekStart, calendar.date(byAdding: .day, value: -step, to: start)!)

        XCTAssertTrue(split.validateMenuItem(menuItem(#selector(MainSplitViewController.goToNextWeek(_:)))))
        XCTAssertTrue(split.validateMenuItem(menuItem(#selector(MainSplitViewController.goToPreviousWeek(_:)))))
    }

    func testSidebarStartsExpandedAndOnlyCollapsesOnPurpose() {
        let (split, _) = makeSplit()
        let sidebar = split.splitViewItems[0]
        XCTAssertFalse(sidebar.isCollapsed)
        XCTAssertTrue(sidebar.canCollapse, "the toolbar carries a Hide Sidebar button")
        // The outline is the only place to create a project, so it must never
        // vanish just because the window got narrow.
        XCTAssertFalse(sidebar.canCollapseFromWindowResize)
        split.viewDidAppear()
        XCTAssertFalse(sidebar.isCollapsed)
    }

    func testToggleSidebarHidesAndRestoresTheOutline() {
        let (split, _) = makeSplit()
        XCTAssertTrue(split.isSidebarVisible)
        XCTAssertTrue(split.validateMenuItem(menuItem(#selector(NSSplitViewController.toggleSidebar(_:)))))

        split.toggleSidebar(nil)
        XCTAssertFalse(split.isSidebarVisible)

        split.toggleSidebar(nil)
        XCTAssertTrue(split.isSidebarVisible)
    }

    func testCollapsingTheSidebarHidesItsToolbarItems() throws {
        let (split, _) = makeSplit()
        let toolbar = NSToolbar(identifier: "test")
        let addProject = try XCTUnwrap(split.toolbar(
            toolbar, itemForItemIdentifier: .addProject, willBeInsertedIntoToolbar: true
        ))
        let addTask = try XCTUnwrap(split.toolbar(
            toolbar, itemForItemIdentifier: .addTask, willBeInsertedIntoToolbar: true
        ))

        XCTAssertFalse(addProject.isHidden)
        XCTAssertFalse(addTask.isHidden)

        split.toggleSidebar(nil)
        XCTAssertFalse(split.isSidebarVisible)
        XCTAssertTrue(addProject.isHidden, "New Project acts on the hidden outline")
        XCTAssertTrue(addTask.isHidden)

        split.toggleSidebar(nil)
        XCTAssertTrue(split.isSidebarVisible)
        XCTAssertFalse(addProject.isHidden)
        XCTAssertFalse(addTask.isHidden)
    }

    func testToolbarItemsBuiltWhileCollapsedStartHidden() throws {
        let (split, _) = makeSplit()
        split.toggleSidebar(nil)

        // Items are created lazily by the toolbar, so one built while the sidebar
        // is already shut must not appear until it reopens.
        let addProject = try XCTUnwrap(split.toolbar(
            NSToolbar(identifier: "test"), itemForItemIdentifier: .addProject, willBeInsertedIntoToolbar: true
        ))
        XCTAssertTrue(addProject.isHidden)

        split.toggleSidebar(nil)
        XCTAssertFalse(addProject.isHidden)
    }

    func testToolbarPutsTheSidebarGroupAgainstTheFirstDivider() {
        let (split, _) = makeSplit()
        let toolbar = NSToolbar(identifier: "test")
        let identifiers = split.toolbarDefaultItemIdentifiers(toolbar)

        let leadingSpace = try! XCTUnwrap(identifiers.firstIndex(of: .flexibleSpace))
        let addProject = try! XCTUnwrap(identifiers.firstIndex(of: .addProject))
        let sidebarMode = try! XCTUnwrap(identifiers.firstIndex(of: .sidebarMode))
        let paneSeparator = try! XCTUnwrap(identifiers.firstIndex(of: .paneSeparator))

        // flexible space, then the group, then the divider: that ordering is what
        // pushes the group up against the splitter instead of the window edge.
        XCTAssertLessThan(leadingSpace, addProject)
        XCTAssertLessThan(addProject, sidebarMode)
        XCTAssertLessThan(sidebarMode, paneSeparator)
    }

    func testSplitPanesHaveMinimumThickness() {
        let (split, _) = makeSplit()
        XCTAssertEqual(split.splitViewItems.count, 3, "sidebar, calendar, trailing inspector")

        let sidebar = split.splitViewItems[0]
        XCTAssertGreaterThanOrEqual(sidebar.minimumThickness, 220)
        XCTAssertEqual(sidebar.maximumThickness, sidebar.minimumThickness * 2)
        XCTAssertGreaterThanOrEqual(split.splitViewItems[1].minimumThickness, 420)

        let inspector = split.splitViewItems[2]
        XCTAssertGreaterThanOrEqual(inspector.minimumThickness, 240)
        XCTAssertLessThanOrEqual(inspector.maximumThickness, 420)
        XCTAssertFalse(inspector.canCollapse, "the notes pane must never disappear")
    }

    func testSplitPaneHoldingPrioritiesStayBelowWindowResizePriority() {
        let (split, _) = makeSplit()
        // Above 500 a pane outranks the window's own resize priority, which turns
        // its restored thickness into a hard, self-growing window minimum.
        for item in split.splitViewItems {
            XCTAssertLessThan(item.holdingPriority.rawValue, 500)
        }
    }

    /// The inspector is the notes pane and, like the mail reader, cannot
    /// collapse — so the toggle command is dead, not merely tasks-only.
    func testTheInspectorCannotCollapseAndHasNoToggle() {
        let (split, _) = makeSplit()
        XCTAssertTrue(split.isInspectorVisible)
        XCTAssertFalse(split.splitViewItems[2].canCollapse)
        XCTAssertFalse(split.validateMenuItem(menuItem(#selector(MainSplitViewController.toggleInspector(_:)))))
    }

    /// Get Info no longer has a collapse to undo; what is left to gate is the
    /// command itself, which targets things that own a note.
    func testGetInfoValidatesOnlyForANoteEditableSelection() throws {
        let selection = SelectionModel(defaults: isolatedDefaults())
        let (split, _) = makeSplit(selection: selection)
        let getInfo = menuItem(#selector(MainSplitViewController.showTaskInfo(_:)))

        let project = try model.createProject()
        selection.selectNode(uuid: project.uuid)
        XCTAssertFalse(split.validateMenuItem(getInfo), "Get Info targets tasks, not projects")

        let task = try model.createTask(in: project)
        selection.selectNode(uuid: task.uuid)
        XCTAssertTrue(split.validateMenuItem(getInfo))
    }

    func testFindPanelActionsValidateByTagNotIsCommandEnabled() throws {
        let selection = SelectionModel(defaults: isolatedDefaults())
        selection.setMode(.mail)
        let (split, _) = makeSplit(selection: selection)
        split.mailListViewController.loadViewIfNeeded()
        split.mailReaderViewController.loadViewIfNeeded()

        let show = findItem(.showFindPanel)
        let next = findItem(.next)
        XCTAssertFalse(split.test_isCommandEnabled(for: show.action))

        let folder = try model.createMailFolder(name: "Celerity")
        selection.selectMailbox(.folder(folder.uuid))
        split.firstResponderForValidation = split.mailListViewController.outlineView
        XCTAssertTrue(split.validateMenuItem(show))
        XCTAssertFalse(split.validateMenuItem(next))

        split.firstResponderForValidation = split.mailListViewController.test_searchField
        XCTAssertTrue(split.validateMenuItem(show))
        XCTAssertFalse(split.validateMenuItem(next))

        split.firstResponderForValidation = split.mailListViewController.test_searchField.searchEditor
        XCTAssertTrue(split.validateMenuItem(show))
        XCTAssertFalse(split.validateMenuItem(next))

        split.firstResponderForValidation = split.mailReaderViewController.test_bodyView
        XCTAssertTrue(split.validateMenuItem(show))
        XCTAssertTrue(split.validateMenuItem(next))
        XCTAssertTrue(split.validateMenuItem(findItem(.previous)))
        XCTAssertTrue(split.validateMenuItem(findItem(.setFindString)))
    }

    private func findItem(_ action: NSFindPanelAction) -> NSMenuItem {
        let item = NSMenuItem(
            title: "",
            action: #selector(NSTextView.performFindPanelAction(_:)),
            keyEquivalent: ""
        )
        item.tag = Int(action.rawValue)
        return item
    }

    private func makeSplit(
        selection: SelectionModel? = nil
    ) -> (MainSplitViewController, OutlineViewController) {
        let defaults = isolatedDefaults()
        let split = MainSplitViewController(
            persistence: persistence,
            model: model,
            selection: selection ?? SelectionModel(defaults: defaults),
            events: EventCoordinator(source: NullEventSource()),
            mail: MailCoordinator(source: NullMailSource(), defaults: defaults),
            userDefaults: defaults
        )
        split.loadViewIfNeeded()
        let outline = split.outlineViewController
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
