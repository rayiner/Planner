import AppKit
import XCTest
@testable import Planner

@MainActor
final class ModeSwitchTests: PersistenceTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = isolatedDefaults()
    }

    override func tearDown() {
        for window in windows { window.contentViewController = nil }
        windows = []
        defaults = nil
        super.tearDown()
    }

    /// Windows are kept for the lifetime of the test: a split view resolves its
    /// pane thicknesses against a window, and one measured outside a window
    /// reports numbers that have nothing to do with what ships.
    private var windows: [NSWindow] = []

    private func makeSplit(
        selection: SelectionModel? = nil
    ) -> (MainSplitViewController, SelectionModel) {
        let selection = selection ?? SelectionModel(defaults: defaults)
        let split = MainSplitViewController(
            persistence: persistence,
            model: model,
            selection: selection,
            events: EventCoordinator(source: NullEventSource()),
            mail: MailCoordinator(source: NullMailSource(), defaults: defaults),
            userDefaults: defaults
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = split
        windows.append(window)
        split.loadViewIfNeeded()
        split.view.layoutSubtreeIfNeeded()
        return (split, selection)
    }

    // MARK: - The selection model's contract

    /// The whole reason adding fields is safe: every existing observer already
    /// inspects `changedFields` and no-ops on ones it does not know.
    func testAModeFlipPostsOnlyTheModeField() {
        let selection = SelectionModel(defaults: defaults)
        var posted: [Set<String>] = []
        let token = NotificationCenter.default.addObserver(
            forName: .plannerSelectionDidChange,
            object: selection,
            queue: nil
        ) { note in
            posted.append(note.userInfo?[SelectionUserInfoKey.changedFields] as? Set<String> ?? [])
        }
        defer { NotificationCenter.default.removeObserver(token) }

        selection.setMode(.mail)
        XCTAssertEqual(posted, [[SelectionField.mode.rawValue]])
    }

    func testSettingTheSameModeDoesNotPost() {
        let selection = SelectionModel(defaults: defaults)
        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: .plannerSelectionDidChange,
            object: selection,
            queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        selection.setMode(.tasks)
        XCTAssertEqual(posts, 0)
    }

    func testSwitchingModesLeavesTheTaskSelectionAlone() throws {
        let selection = SelectionModel(defaults: defaults)
        let project = try model.createProject()
        selection.selectNode(uuid: project.uuid)

        selection.setMode(.mail)
        selection.setMode(.tasks)
        XCTAssertEqual(selection.selectedNodeUUID, project.uuid)
    }

    func testModePersistsAndIsRestored() {
        let selection = SelectionModel(defaults: defaults)
        selection.setMode(.mail)
        XCTAssertEqual(SelectionModel(defaults: defaults).mode, .mail)
    }

    func testSelectingAMailboxClearsTheOpenMessage() {
        let selection = SelectionModel(defaults: defaults)
        selection.selectMessage(.recent(42))
        var posted: Set<String> = []
        let token = NotificationCenter.default.addObserver(
            forName: .plannerSelectionDidChange,
            object: selection,
            queue: nil
        ) { note in
            posted = note.userInfo?[SelectionUserInfoKey.changedFields] as? Set<String> ?? []
        }
        defer { NotificationCenter.default.removeObserver(token) }

        selection.selectMailbox(.folder(UUID()))
        XCTAssertNil(selection.message, "the reader kept a message the list no longer holds")
        XCTAssertEqual(posted, [SelectionField.mailbox.rawValue, SelectionField.message.rawValue])
    }

    func testRecentAndFolderMailboxesAreDistinguishable() {
        let selection = SelectionModel(defaults: defaults)
        XCTAssertTrue(selection.isRecentMailSelected)
        XCTAssertNil(selection.selectedFolderUUID)

        let uuid = UUID()
        selection.selectMailbox(.folder(uuid))
        XCTAssertFalse(selection.isRecentMailSelected)
        XCTAssertEqual(selection.selectedFolderUUID, uuid)
    }

    // MARK: - The split

    func testTasksModeIsTheOriginalThreePaneLayout() {
        let (split, _) = makeSplit()
        XCTAssertEqual(split.splitViewItems.count, 3)
        XCTAssertTrue(split.test_sidebarChild is OutlineViewController)
        XCTAssertTrue(split.splitViewItems[1].viewController is CalendarViewController)
        XCTAssertTrue(split.splitViewItems[2].viewController is InspectorViewController)
    }

    func testSwitchingToMailReplacesBothTrailingPanes() {
        let (split, selection) = makeSplit()
        selection.setMode(.mail)

        XCTAssertEqual(split.splitViewItems.count, 3)
        XCTAssertTrue(split.test_sidebarChild is MailboxListViewController)
        XCTAssertTrue(split.splitViewItems[1].viewController is MailListViewController)
        XCTAssertTrue(split.splitViewItems[2].viewController is MailReaderViewController)
    }

    func testSwitchingBackRestoresTheTasksPanes() {
        let (split, selection) = makeSplit()
        selection.setMode(.mail)
        selection.setMode(.tasks)

        XCTAssertTrue(split.test_sidebarChild is OutlineViewController)
        XCTAssertTrue(split.splitViewItems[1].viewController is CalendarViewController)
        XCTAssertTrue(split.splitViewItems[2].viewController is InspectorViewController)
    }

    /// The sidebar item is the one pane that survives, which is what makes the
    /// switch read as "the content changed" rather than "the layout moved".
    func testTheSidebarItemItselfSurvivesTheSwitch() {
        let (split, selection) = makeSplit()
        let before = split.splitViewItems[0]
        selection.setMode(.mail)
        XCTAssertTrue(split.splitViewItems[0] === before)
    }

    func testLaunchingIntoMailModeBuildsTheMailPanes() {
        defaults.set(PlannerMode.mail.rawValue, forKey: SelectionModel.modeDefaultsKey)
        let (split, _) = makeSplit()
        XCTAssertTrue(split.test_sidebarChild is MailboxListViewController)
        XCTAssertTrue(split.splitViewItems[1].viewController is MailListViewController)
    }

    // MARK: - Geometry

    func testBothModesHaveTheSameMinimumWidthSoSwitchingCannotGrowTheWindow() {
        let (split, selection) = makeSplit()
        let tasksMinimum = split.splitViewItems.reduce(0) { $0 + $1.minimumThickness }
        selection.setMode(.mail)
        let mailMinimum = split.splitViewItems.reduce(0) { $0 + $1.minimumThickness }
        XCTAssertEqual(tasksMinimum, mailMinimum)
    }

    func testHoldingPrioritiesStayBelowWindowResizePriorityInBothModes() {
        let (split, selection) = makeSplit()
        for item in split.splitViewItems {
            XCTAssertLessThan(item.holdingPriority.rawValue, 500)
        }
        selection.setMode(.mail)
        for item in split.splitViewItems {
            XCTAssertLessThan(item.holdingPriority.rawValue, 500)
        }
    }

    /// Mail's proportions are the calendar's inverted: the list keeps its width
    /// and the reader takes the slack.
    func testTheMailListResistsResizingAndTheReaderAbsorbsIt() {
        let (split, selection) = makeSplit()
        selection.setMode(.mail)
        XCTAssertGreaterThan(
            split.splitViewItems[1].holdingPriority.rawValue,
            split.splitViewItems[2].holdingPriority.rawValue
        )
    }

    func testTheSidebarDoesNotMoveWhenTheModeChanges() {
        let (split, selection) = makeSplit()
        let before = split.test_paneWidths[0]
        selection.setMode(.mail)
        split.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(split.test_paneWidths[0], before, accuracy: 0.5)
    }

    func testTheSidebarStaysCollapsedAcrossAModeSwitch() {
        let (split, selection) = makeSplit()
        split.toggleSidebar(nil)
        XCTAssertFalse(split.isSidebarVisible)
        selection.setMode(.mail)
        XCTAssertFalse(split.isSidebarVisible, "the sidebar reopened on a mode switch")
    }

    /// A collapsed inspector must not carry over into mail mode: a reading pane
    /// that opens shut reads as broken, not as collapsed.
    func testACollapsedInspectorDoesNotCollapseTheMailReader() {
        let (split, selection) = makeSplit()
        split.toggleInspector(nil)
        XCTAssertFalse(split.isInspectorVisible)

        selection.setMode(.mail)
        XCTAssertFalse(split.splitViewItems[2].isCollapsed, "mail opened with no reading pane")
    }

    func testEachModeKeepsItsOwnDividerPosition() {
        let (split, selection) = makeSplit()
        split.splitView.setPosition(700, ofDividerAt: 1)
        split.view.layoutSubtreeIfNeeded()
        let tasksWidth = split.test_paneWidths[1]

        selection.setMode(.mail)
        split.view.layoutSubtreeIfNeeded()
        XCTAssertNotEqual(split.test_paneWidths[1], tasksWidth, accuracy: 1)

        selection.setMode(.tasks)
        split.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(split.test_paneWidths[1], tasksWidth, accuracy: 1)
    }

    func testTheMailDividerPositionSurvivesRelaunch() {
        let (split, selection) = makeSplit()
        selection.setMode(.mail)
        split.splitView.setPosition(640, ofDividerAt: 1)
        split.view.layoutSubtreeIfNeeded()
        let width = split.test_paneWidths[1]
        // Recorded on the way out, which is also what happens on quit.
        selection.setMode(.tasks)

        let (relaunched, relaunchedSelection) = makeSplit()
        relaunchedSelection.setMode(.mail)
        relaunched.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(relaunched.test_paneWidths[1], width, accuracy: 1)
    }

    // MARK: - Toolbar and menus

    private func toolbarItem(
        _ split: MainSplitViewController,
        _ identifier: NSToolbarItem.Identifier
    ) throws -> NSToolbarItem {
        try XCTUnwrap(split.toolbar(
            NSToolbar(identifier: "test"),
            itemForItemIdentifier: identifier,
            willBeInsertedIntoToolbar: true
        ))
    }

    /// Hidden items still count toward the toolbar's width, so the other
    /// mode's items must be *absent*, not merely invisible — otherwise they
    /// push the real ones into the overflow menu.
    func testEachModeCarriesOnlyItsOwnToolbarItems() {
        let (split, selection) = makeSplit()
        let tasks = split.toolbarDefaultItemIdentifiers(NSToolbar(identifier: "test"))
        XCTAssertTrue(tasks.contains(.addProject))
        XCTAssertTrue(tasks.contains(.weekNavigation))
        XCTAssertFalse(tasks.contains(.newMailFolder))
        XCTAssertFalse(tasks.contains(.mailTitle))

        selection.setMode(.mail)
        let mail = split.toolbarDefaultItemIdentifiers(NSToolbar(identifier: "test"))
        XCTAssertTrue(mail.contains(.newMailFolder))
        XCTAssertTrue(mail.contains(.mailTitle))
        XCTAssertTrue(mail.contains(.windowRange))
        XCTAssertFalse(mail.contains(.addProject))
        XCTAssertFalse(mail.contains(.weekNavigation))
        XCTAssertFalse(mail.contains(.getInfo), "the inspector toggle is tasks-only")
    }

    /// Both modes keep the sidebar slot and both tracking separators, so the
    /// window's chrome does not visibly rearrange around the swap.
    func testBothModesKeepTheSidebarSlotAndBothTrackingSeparators() {
        let (split, _) = makeSplit()
        for mode in [PlannerMode.tasks, .mail] {
            let identifiers = split.identifiers(for: mode)
            XCTAssertTrue(identifiers.contains(.sidebarMode), "\(mode) lost the sidebar slot")
            XCTAssertTrue(identifiers.contains(.paneSeparator), "\(mode) lost divider 0's separator")
            XCTAssertTrue(identifiers.contains(.inspectorSeparator), "\(mode) lost divider 1's separator")
        }
    }

    func testSidebarItemsHideWithTheSidebar() throws {
        let (split, selection) = makeSplit()
        selection.setMode(.mail)
        let newFolder = try toolbarItem(split, .newMailFolder)
        XCTAssertFalse(newFolder.isHidden)

        split.toggleSidebar(nil)
        XCTAssertTrue(newFolder.isHidden, "a sidebar item stayed with the sidebar shut")

        split.toggleSidebar(nil)
        XCTAssertFalse(newFolder.isHidden)
    }

    /// An item built while the sidebar is already shut must start hidden.
    func testSidebarItemsBuiltWhileCollapsedStartHidden() throws {
        let (split, selection) = makeSplit()
        selection.setMode(.mail)
        split.toggleSidebar(nil)
        XCTAssertTrue(try toolbarItem(split, .newMailFolder).isHidden)
    }

    /// The sidebar slot is a custom item now, because the system one cannot
    /// grow a menu — but it must still toggle the sidebar on a plain click.
    func testTheSidebarSlotStillTogglesTheSidebar() throws {
        let (split, _) = makeSplit()
        let item = toolbarItem
        let control = try XCTUnwrap(item(split, .sidebarMode).view as? NSSegmentedControl)
        XCTAssertEqual(control.action, #selector(NSSplitViewController.toggleSidebar(_:)))
        XCTAssertTrue(control.showsMenuIndicator(forSegment: 0))
        XCTAssertEqual(
            control.menu(forSegment: 0)?.items.map(\.action),
            [
                #selector(MainSplitViewController.showTasksMode(_:)),
                #selector(MainSplitViewController.showMailMode(_:)),
            ],
            "the mode menu is not attached"
        )
    }

    func testModeCommandsAreAlwaysAvailableAndShowWhichIsOn() {
        let (split, selection) = makeSplit()
        let tasks = NSMenuItem(title: "", action: #selector(MainSplitViewController.showTasksMode(_:)), keyEquivalent: "")
        let mail = NSMenuItem(title: "", action: #selector(MainSplitViewController.showMailMode(_:)), keyEquivalent: "")

        XCTAssertTrue(split.validateMenuItem(tasks))
        XCTAssertTrue(split.validateMenuItem(mail))
        XCTAssertEqual(tasks.state, .on)
        XCTAssertEqual(mail.state, .off)

        selection.setMode(.mail)
        _ = split.validateMenuItem(tasks)
        _ = split.validateMenuItem(mail)
        XCTAssertEqual(tasks.state, .off)
        XCTAssertEqual(mail.state, .on)
    }

    func testTaskCommandsAreDisabledInMailMode() throws {
        let (split, selection) = makeSplit()
        let project = try model.createProject()
        selection.selectNode(uuid: project.uuid)

        let newTask = NSMenuItem(title: "", action: #selector(MainSplitViewController.newTask(_:)), keyEquivalent: "")
        let newProject = NSMenuItem(title: "", action: #selector(MainSplitViewController.newProject(_:)), keyEquivalent: "")
        let newFolder = NSMenuItem(title: "", action: #selector(MainSplitViewController.newMailFolder(_:)), keyEquivalent: "")
        XCTAssertTrue(split.validateMenuItem(newTask))
        XCTAssertTrue(split.validateMenuItem(newProject))
        XCTAssertFalse(split.validateMenuItem(newFolder))

        selection.setMode(.mail)
        XCTAssertFalse(split.validateMenuItem(newTask))
        XCTAssertFalse(split.validateMenuItem(newProject))
        XCTAssertTrue(split.validateMenuItem(newFolder))
    }

    func testRefreshRoutesToWhicheverFeedTheModeShows() async {
        let (split, selection) = makeSplit()
        let refresh = NSMenuItem(
            title: "",
            action: #selector(MainSplitViewController.refreshCurrentMode(_:)),
            keyEquivalent: ""
        )

        // In tasks mode ⌘R must not touch the mailbox at all — and nothing
        // else has, because the mail panes are not built yet.
        split.refreshCurrentMode(nil)
        XCTAssertEqual(split.mail.state, .idle, "⌘R in tasks mode swept the mailbox")

        // Entering mail mode builds the list, which starts the launch sweep.
        selection.setMode(.mail)
        for _ in 0..<400 {
            guard split.mail.isLoading else { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(split.validateMenuItem(refresh))

        split.refreshCurrentMode(nil)
        XCTAssertTrue(split.mail.isLoading, "⌘R in mail mode did not sweep the mailbox")
        XCTAssertFalse(split.validateMenuItem(refresh), "refresh stayed enabled mid-flight")
    }

    func testNewFolderCreatesAndSelectsAFolder() {
        let (split, selection) = makeSplit()
        selection.setMode(.mail)
        split.newMailFolder(nil)

        let folders = model.mailFolders()
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(selection.selectedFolderUUID, folders.first?.uuid)
    }

    // MARK: - Titles

    func testTheWindowTitleFollowsTheMode() {
        let (split, selection) = makeSplit()
        let tasksTitle = split.test_windowTitle
        selection.setMode(.mail)
        XCTAssertEqual(split.test_windowTitle, MailLabels.recentMailName)
        XCTAssertNotEqual(split.test_windowTitle, tasksTitle)
    }
}
