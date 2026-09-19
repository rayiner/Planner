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
        selection: SelectionModel? = nil,
        mail: MailCoordinator? = nil
    ) -> (MainSplitViewController, SelectionModel) {
        let selection = selection ?? SelectionModel(defaults: defaults)
        let split = MainSplitViewController(
            persistence: persistence,
            model: model,
            selection: selection,
            events: EventCoordinator(source: NullEventSource()),
            mail: mail ?? MailCoordinator(source: NullMailSource(), defaults: defaults),
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

    private func settleMail(
        source: StubMailSource,
        mail: MailCoordinator,
        messages: [MailMessage]
    ) async {
        let before = source.requestedRanges.count
        if mail.state == .idle { mail.refresh() }
        for _ in 0..<400 {
            if source.requestedRanges.count > before || source.pendingCount > 0 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        source.finishAll(with: messages)
        for _ in 0..<400 {
            if !mail.isLoading { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func logicalItems(_ split: MainSplitViewController) -> [NSSplitViewItem] {
        [split.splitViewItems[0]] + split.test_contentSplitItems
    }

    private func setMiddleDivider(_ split: MainSplitViewController, position: CGFloat) {
        split.test_contentSplitViewController.splitView.setPosition(position, ofDividerAt: 0)
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

    /// Mode is the kind of sidebar row that is selected.
    func testSelectingRecentMailEntersMailMode() {
        let selection = SelectionModel(defaults: defaults)
        XCTAssertEqual(selection.mode, .tasks)
        selection.selectMail()
        XCTAssertEqual(selection.mode, .mail)
    }

    func testSelectingMultipleMessagesRemembersTheWholeSet() {
        let selection = SelectionModel(defaults: defaults)
        selection.selectMail()
        selection.selectMessage(.recent(7))
        selection.selectMessages([.recent(7), .recent(8)])
        XCTAssertEqual(selection.messages, [.recent(7), .recent(8)])
        XCTAssertEqual(selection.message, .recent(8))
    }

    func testSelectingSearchClearsMessage() {
        let selection = SelectionModel(defaults: defaults)
        selection.selectMail()
        selection.selectMessage(.recent(7))

        selection.selectMailbox(.search)

        XCTAssertEqual(selection.mode, .mail)
        XCTAssertEqual(selection.mailbox, .search)
        XCTAssertNil(selection.message)
        XCTAssertTrue(selection.messages.isEmpty)
    }

    func testSelectingQuickSearchClearsMessageSelection() {
        let selection = SelectionModel(defaults: defaults)
        selection.selectMail()
        selection.selectMessages([.recent(7), .recent(8)])
        let id = UUID()

        selection.selectMailbox(.quickSearch(id))

        XCTAssertEqual(selection.mailbox, .quickSearch(id))
        XCTAssertTrue(selection.messages.isEmpty)
    }

    func testSidebarContainsRecentAndSearchMailboxes() {
        let (split, _) = makeSplit()
        let controller = split.outlineViewController
        let outline = controller.outlineView
        XCTAssertEqual(
            controller.outlineView(outline, numberOfChildrenOfItem: SidebarSection.mail),
            2
        )
        XCTAssertTrue(
            controller.outlineView(outline, child: 0, ofItem: SidebarSection.mail) is RecentMailbox
        )
        XCTAssertTrue(
            controller.outlineView(outline, child: 1, ofItem: SidebarSection.mail) is SearchMailbox
        )
    }

    func testSidebarOrdersNamedQuickSearchesBetweenRecentAndSearch() async {
        let source = StubMailSource()
        let mail = MailCoordinator(source: source, defaults: defaults)
        _ = mail.saveQuickSearch(name: "Patent", query: "patent")
        _ = mail.saveQuickSearch(name: "Ada", query: "from:ada")
        let (split, selection) = makeSplit(mail: mail)
        defer { source.drain(); mail.cancel() }
        selection.setMode(.mail)
        await settleMail(source: source, mail: mail, messages: [])

        let controller = split.outlineViewController
        let outline = controller.outlineView
        let children = (0..<controller.outlineView(
            outline,
            numberOfChildrenOfItem: SidebarSection.mail
        )).map {
            controller.outlineView(outline, child: $0, ofItem: SidebarSection.mail)
        }
        XCTAssertTrue(children[0] is RecentMailbox)
        XCTAssertEqual((children[1] as? QuickSearchMailbox)?.name, "Ada")
        XCTAssertEqual((children[2] as? QuickSearchMailbox)?.name, "Patent")
        XCTAssertTrue(children[3] is SearchMailbox)
        XCTAssertEqual(children.count, 4)
    }

    func testRemovingSelectedQuickSearchFallsBackToSearch() async {
        let source = StubMailSource()
        let mail = MailCoordinator(source: source, defaults: defaults)
        let (split, selection) = makeSplit(mail: mail)
        defer { source.drain(); mail.cancel() }
        selection.setMode(.mail)
        await settleMail(source: source, mail: mail, messages: [])
        let saved = try! XCTUnwrap(mail.saveQuickSearch(name: "Patent", query: "patent"))
        selection.selectMailbox(.quickSearch(saved.id))

        let outline = split.outlineViewController.outlineView
        let row = (0..<outline.numberOfRows).first {
            (outline.item(atRow: $0) as? QuickSearchMailbox)?.id == saved.id
        }
        let menu = outline.menu(forRow: try! XCTUnwrap(row))
        XCTAssertEqual(menu.items.map(\.title), ["Delete Quick Search"])
        split.deleteQuickSearch(nil)

        XCTAssertEqual(selection.mailbox, .search)
        XCTAssertTrue(mail.quickSearches.isEmpty)
    }

    func testSelectingANodeEntersTasksMode() {
        let selection = SelectionModel(defaults: defaults)
        selection.setMode(.mail)
        selection.selectNode(uuid: UUID())
        XCTAssertEqual(selection.mode, .tasks)
    }

    func testClearingTheNodeDoesNotChangeMode() {
        let selection = SelectionModel(defaults: defaults)
        selection.selectNode(uuid: UUID())
        XCTAssertEqual(selection.mode, .tasks)
        selection.selectNode(uuid: nil)
        XCTAssertEqual(selection.mode, .tasks)
    }

    // MARK: - The split

    func testTasksModeUsesTheNestedSidebarCalendarTerminalLayout() {
        let (split, _) = makeSplit()
        XCTAssertEqual(split.splitViewItems.count, 2)
        XCTAssertTrue(split.splitViewItems[0].viewController is OutlineViewController)
        XCTAssertEqual(split.test_rightSplitViewController.splitViewItems.count, 2)
        XCTAssertEqual(split.test_contentSplitItems.count, 1, "the calendar fills the split alone")
        XCTAssertTrue(split.test_contentSplitItems[0].viewController is CalendarViewController)
        XCTAssertTrue(
            split.test_rightSplitViewController.splitViewItems[1].viewController
                is TerminalViewController
        )
    }

    func testSwitchingToMailReplacesBothTrailingPanes() {
        let (split, selection) = makeSplit()
        selection.setMode(.mail)

        XCTAssertEqual(split.test_contentSplitItems.count, 2)
        XCTAssertTrue(split.test_contentSplitItems[0].viewController is MailListViewController)
        XCTAssertTrue(split.test_contentSplitItems[1].viewController is MailReaderViewController)
    }

    func testSwitchingBackRestoresTheCalendarPane() {
        let (split, selection) = makeSplit()
        selection.setMode(.mail)
        selection.setMode(.tasks)

        XCTAssertEqual(split.test_contentSplitItems.count, 1)
        XCTAssertTrue(split.test_contentSplitItems[0].viewController is CalendarViewController)
    }

    /// The unified sidebar serves both modes, so the item *and* its content
    /// survive the switch — only the trailing pair changes.
    func testTheUnifiedSidebarSurvivesTheSwitch() {
        let (split, selection) = makeSplit()
        let before = split.splitViewItems[0]
        selection.setMode(.mail)
        XCTAssertTrue(split.splitViewItems[0] === before)
        XCTAssertTrue(split.splitViewItems[0].viewController is OutlineViewController)
    }

    func testLaunchingIntoMailModeBuildsTheMailPanes() {
        defaults.set(PlannerMode.mail.rawValue, forKey: SelectionModel.modeDefaultsKey)
        let (split, _) = makeSplit()
        XCTAssertTrue(split.splitViewItems[0].viewController is OutlineViewController)
        XCTAssertTrue(split.test_contentSplitItems[0].viewController is MailListViewController)
    }

    func testNestedSplitOrientationsAndTerminalStartHidden() {
        let (split, _) = makeSplit()
        XCTAssertTrue(split.splitView.isVertical, "outer split is sidebar/right")
        XCTAssertFalse(
            split.test_rightSplitViewController.splitView.isVertical,
            "right split is content above terminal"
        )
        XCTAssertTrue(
            split.test_contentSplitViewController.splitView.isVertical,
            "top split is middle/trailing"
        )
        XCTAssertFalse(split.test_terminalIsVisible)
    }

    func testTerminalTogglePersistsVisibilityWithoutChangingMode() {
        let (split, selection) = makeSplit()
        split.toggleTerminal(nil)
        split.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(split.test_terminalIsVisible)
        XCTAssertTrue(defaults.bool(forKey: "terminalPaneVisible"))
        XCTAssertEqual(selection.mode, .tasks)

        split.toggleTerminal(nil)
        split.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(split.test_terminalIsVisible)
        XCTAssertFalse(defaults.bool(forKey: "terminalPaneVisible"))
    }

    func testSidebarFooterTerminalButtonUsesToggleAction() {
        let (split, _) = makeSplit()
        let button = split.outlineViewController.test_terminalButton
        XCTAssertEqual(button.action, #selector(MainSplitViewController.toggleTerminal(_:)))
        XCTAssertEqual(button.image?.accessibilityDescription, "Show or Hide Terminal (⌘⌃T)")
    }

    func testRestartTerminalMenuItemSitsBesideShowTerminal() throws {
        var objects: NSArray?
        let bundle = Bundle(for: MainSplitViewController.self)
        XCTAssertTrue(bundle.loadNibNamed("MainMenu", owner: nil, topLevelObjects: &objects))
        let menu = try XCTUnwrap(objects?.compactMap { $0 as? NSMenu }.first { $0.title == "Main Menu" })
        let view = try XCTUnwrap(menu.items.first { $0.title == "View" }?.submenu)
        let titles = view.items.map(\.title)
        let show = try XCTUnwrap(titles.firstIndex(of: "Show Terminal"))
        let restart = try XCTUnwrap(titles.firstIndex(of: "Restart Terminal"))
        XCTAssertEqual(restart, show + 1)

        let item = view.items[restart]
        XCTAssertEqual(item.action, #selector(MainSplitViewController.restartTerminal(_:)))
        XCTAssertEqual(item.keyEquivalent, "r")
        XCTAssertTrue(item.keyEquivalentModifierMask.contains(.command))
        XCTAssertTrue(item.keyEquivalentModifierMask.contains(.control))
    }

    func testRestartTerminalMenuItemIsAlwaysEnabled() {
        let (split, _) = makeSplit()
        let item = NSMenuItem(
            title: "",
            action: #selector(MainSplitViewController.restartTerminal(_:)),
            keyEquivalent: ""
        )
        XCTAssertTrue(split.validateMenuItem(item))
        split.toggleTerminal(nil)
        XCTAssertTrue(split.validateMenuItem(item))
    }

    func testOutlookStatusPrefersLoadingThenFailureThenOldestSuccess() {
        XCTAssertEqual(
            OutlookSyncPresentation(
                events: .failed("events failed"),
                mail: .loading
            ).text,
            "Syncing Outlook…"
        )
        let failed = OutlookSyncPresentation(
            events: .failed("events failed"),
            mail: .loaded(Date(timeIntervalSince1970: 200))
        )
        XCTAssertEqual(failed.text, "Outlook sync failed")
        XCTAssertTrue(failed.toolTip?.contains("events failed") == true)

        let updated = OutlookSyncPresentation(
            events: .loaded(Date(timeIntervalSince1970: 100)),
            mail: .loaded(Date(timeIntervalSince1970: 200))
        )
        XCTAssertTrue(updated.text.hasPrefix("Outlook updated "))
        XCTAssertTrue(updated.toolTip?.contains("Mail and calendar data are current") == true)

        let progress = OutlookSyncPresentation(
            events: .loading,
            mail: .idle,
            progress: OutlookSyncProgress(phase: "indexing", done: 4120, total: 25000)
        )
        XCTAssertEqual(progress.text, "Syncing Outlook… \(4120.formatted()) of \(25000.formatted())")
        XCTAssertTrue(progress.toolTip?.contains("4120") == true || progress.toolTip?.contains(4120.formatted()) == true)
    }

    // MARK: - Geometry

    /// Mail's reader cannot collapse, so mail's minimum sum is the mail
    /// window's hard floor — it must not exceed tasks', or switching into mail
    /// could be the thing that forces the window wider. The other direction is
    /// covered without matching sums: switching into tasks at a narrower
    /// window sheds the inspector (its resize collapse) rather than growing.
    /// Tasks is the narrower mode now that nothing trails the calendar, so the
    /// invariant that keeps a mode switch from growing the window is that both
    /// modes fit inside the window's own content minimum.
    func testNeitherModesPanesExceedTheWindowContentMinimum() {
        let (split, selection) = makeSplit()
        let tasksMinimum = logicalItems(split).reduce(0) { $0 + $1.minimumThickness }
        selection.setMode(.mail)
        let mailMinimum = logicalItems(split).reduce(0) { $0 + $1.minimumThickness }

        let ceiling = MainSplitViewController.windowContentMinimumWidth
        XCTAssertLessThanOrEqual(tasksMinimum, ceiling)
        XCTAssertLessThanOrEqual(mailMinimum, ceiling)
    }

    func testHoldingPrioritiesStayBelowWindowResizePriorityInBothModes() {
        let (split, selection) = makeSplit()
        for item in logicalItems(split) {
            XCTAssertLessThan(item.holdingPriority.rawValue, 500)
        }
        selection.setMode(.mail)
        for item in logicalItems(split) {
            XCTAssertLessThan(item.holdingPriority.rawValue, 500)
        }
    }

    /// Mail's proportions are the calendar's inverted: the list keeps its width
    /// and the reader takes the slack.
    func testTheMailListResistsResizingAndTheReaderAbsorbsIt() {
        let (split, selection) = makeSplit()
        selection.setMode(.mail)
        XCTAssertGreaterThan(
            split.test_contentSplitItems[0].holdingPriority.rawValue,
            split.test_contentSplitItems[1].holdingPriority.rawValue
        )
    }

    /// `sidebarWithViewController:` installs a 250-pt automatic max, tighter
    /// than the 480 the user may drag to. Left in place, fullscreen or a
    /// fitting-size change clamps a widened sidebar back.
    func testTheSidebarHasNoAutomaticMaximumBelowTheUserMaximum() {
        let (split, _) = makeSplit()
        let sidebar = split.splitViewItems[0]
        XCTAssertEqual(sidebar.automaticMaximumThickness, NSSplitViewItem.unspecifiedDimension)
        XCTAssertEqual(sidebar.maximumThickness, 480)
    }

    /// `contentListWithViewController:` installs a 576 automatic max and a
    /// 0.33 fraction (the no-sidebar default). The list is created before it
    /// sits next to the sidebar, so those have to be replaced explicitly.
    func testTheMailListHasNoAutomaticMaximumAndUsesTheDefaultListFraction() {
        let (split, selection) = makeSplit()
        selection.setMode(.mail)
        let list = split.test_contentSplitItems[0]
        XCTAssertEqual(list.automaticMaximumThickness, NSSplitViewItem.unspecifiedDimension)
        XCTAssertEqual(list.preferredThicknessFraction, 420.0 / 1100.0, accuracy: 0.0001)
        XCTAssertEqual(list.maximumThickness, NSSplitViewItem.unspecifiedDimension)
    }

    /// A long subject used to report a several-thousand-point fitting width
    /// and, at compression 490, beat every pane's holding priority — so
    /// clicking between messages walked the sidebar and the list. After a
    /// user drag, both dividers must stay put.
    func testSelectingMailItemsDoesNotMoveDividersAfterADrag() async {
        let source = StubMailSource()
        let mail = MailCoordinator(source: source, defaults: defaults)
        let selection = SelectionModel(defaults: defaults)
        selection.setMode(.mail)
        let (split, _) = makeSplit(selection: selection, mail: mail)
        defer { source.drain(); mail.cancel() }

        windows[0].setContentSize(NSSize(width: 1100, height: 720))
        split.view.layoutSubtreeIfNeeded()

        let short = MailMessage.fixture(id: 1, subject: "Hi")
        let long = MailMessage.fixture(
            id: 2,
            subject: String(repeating: "LongSubjectWord ", count: 30),
            senderName: String(repeating: "Very Long Sender Name ", count: 8)
        )
        await settleMail(source: source, mail: mail, messages: [short, long])

        split.splitView.setPosition(400, ofDividerAt: 0)
        split.view.layoutSubtreeIfNeeded()
        setMiddleDivider(split, position: 450)
        split.view.layoutSubtreeIfNeeded()
        let afterDrag = split.test_paneWidths
        XCTAssertEqual(afterDrag[0], 400, accuracy: 1, "the sidebar drag did not take")
        XCTAssertEqual(afterDrag[1], 450, accuracy: 2, "the list drag did not take")

        selection.selectMessage(.recent(1))
        split.mailReaderViewController.rebind()
        split.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(split.test_paneWidths[0], afterDrag[0], accuracy: 1)
        XCTAssertEqual(split.test_paneWidths[1], afterDrag[1], accuracy: 1)

        selection.selectMessage(.recent(2))
        split.mailReaderViewController.rebind()
        split.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(split.test_paneWidths[0], afterDrag[0], accuracy: 1, "the sidebar moved on a long subject")
        XCTAssertEqual(split.test_paneWidths[1], afterDrag[1], accuracy: 1, "the list moved on a long subject")
        XCTAssertEqual(split.mailReaderViewController.test_subject, long.subject)

        for _ in 0..<400 {
            if source.pendingDetailCount > 0 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        source.finishDetail(.fixture(
            id: 2,
            body: "Body",
            recipients: String(repeating: "counsel@example.com, ", count: 40)
        ))
        for _ in 0..<400 {
            if split.mailReaderViewController.test_recipients != nil { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        split.view.layoutSubtreeIfNeeded()
        XCTAssertNotNil(split.mailReaderViewController.test_recipients)
        XCTAssertEqual(split.test_paneWidths[0], afterDrag[0], accuracy: 1, "the sidebar moved on a long To: line")
        XCTAssertEqual(split.test_paneWidths[1], afterDrag[1], accuracy: 1, "the list moved on a long To: line")

        selection.selectMessage(.recent(1))
        split.mailReaderViewController.rebind()
        split.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(split.test_paneWidths[0], afterDrag[0], accuracy: 1)
        XCTAssertEqual(split.test_paneWidths[1], afterDrag[1], accuracy: 1)
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

    /// The inspector can collapse from the menu, not from a window resize.
    func testEachModeKeepsItsOwnDividerPosition() {
        let (split, selection) = makeSplit()
        setMiddleDivider(split, position: 460)
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
        setMiddleDivider(split, position: 440)
        split.view.layoutSubtreeIfNeeded()
        let width = split.test_paneWidths[1]
        // Recorded on the way out, which is also what happens on quit.
        selection.setMode(.tasks)

        let (relaunched, relaunchedSelection) = makeSplit()
        relaunchedSelection.setMode(.mail)
        relaunched.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(relaunched.test_paneWidths[1], width, accuracy: 1)
    }

    /// Mode switches record the divider on the way out; quitting *inside* mail
    /// mode is the same departure and must record too, or the drag reverts.
    func testTheMailDividerPositionSurvivesQuitInsideMailMode() {
        let (split, selection) = makeSplit()
        selection.setMode(.mail)
        setMiddleDivider(split, position: 500)
        split.view.layoutSubtreeIfNeeded()
        let width = split.test_paneWidths[1]

        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)

        let (relaunched, relaunchedSelection) = makeSplit()
        relaunchedSelection.setMode(.mail)
        relaunched.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(relaunched.test_paneWidths[1], width, accuracy: 1)
    }

    /// The reader has no Show command, so a recorded collapse could only
    /// replay an accident forever: it never restores shut, whatever was stored.
    func testTheMailReaderNeverOpensCollapsed() {
        let (split, selection) = makeSplit()
        selection.setMode(.mail)
        split.test_contentSplitItems[1].isCollapsed = true

        selection.setMode(.tasks)
        selection.setMode(.mail)
        XCTAssertFalse(split.test_contentSplitItems[1].isCollapsed, "mail opened with no reading pane")
    }

    /// Tasks is a single pane now, through every mode switch.
    func testTasksStaysASinglePaneAcrossAModeSwitch() {
        let (split, selection) = makeSplit()
        XCTAssertEqual(split.test_contentSplitItems.count, 1)

        selection.setMode(.mail)
        XCTAssertEqual(split.test_contentSplitItems.count, 2)

        selection.setMode(.tasks)
        XCTAssertEqual(split.test_contentSplitItems.count, 1, "tasks grew a trailing pane")
        XCTAssertTrue(split.test_contentSplitItems[0].viewController is CalendarViewController)
    }

    /// A list width stored in a wide window is clamped when it returns in a
    /// narrower one, so the reader keeps its minimum and the sidebar stays put
    /// instead of AppKit squeezing whichever pane is cheapest.
    func testAStoredListWidthTooWideForTheWindowIsClamped() {
        let (split, selection) = makeSplit()
        selection.setMode(.mail)
        split.view.layoutSubtreeIfNeeded()
        let sidebar = split.test_paneWidths[0]
        setMiddleDivider(split, position: 440)
        split.view.layoutSubtreeIfNeeded()
        selection.setMode(.tasks)   // records the 440pt list

        windows[0].setContentSize(NSSize(width: 960, height: 720))
        split.view.layoutSubtreeIfNeeded()
        selection.setMode(.mail)
        split.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(split.test_contentSplitItems[1].isCollapsed)
        XCTAssertGreaterThanOrEqual(
            split.test_paneWidths[2],
            split.test_contentSplitItems[1].minimumThickness - 1,
            "the reader lost its minimum"
        )
        XCTAssertEqual(split.test_paneWidths[0], sidebar, accuracy: 1, "the sidebar moved")
    }

    /// The reader cannot collapse, full stop: `canCollapseFromWindowResize`
    /// proved a trapdoor (AppKit sprang it on transient squeezes mid-resize,
    /// even growing ones, and never reliably reopened a pane with no Show
    /// command). The window refusing to shrink past the minimum sum is the
    /// trade that made a low reader minimum acceptable.
    func testTheMailReaderCannotCollapse() {
        let (split, selection) = makeSplit()
        selection.setMode(.mail)
        XCTAssertFalse(split.test_contentSplitItems[1].canCollapse, "the resize trapdoor is back")
    }

    /// At the panes' minimum sum — the narrowest window mail mode permits —
    /// every pane is open at its minimum; the reader gives width, never itself.
    func testAtTheMinimumWindowWidthTheReaderIsOpenAtItsMinimum() {
        let (split, selection) = makeSplit()
        selection.setMode(.mail)
        let items = logicalItems(split)
        let minimumSum = items.reduce(0) { $0 + $1.minimumThickness }
            + CGFloat(items.count - 1) * split.splitView.dividerThickness

        windows[0].setContentSize(NSSize(width: minimumSum, height: 720))
        split.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(split.test_contentSplitItems[1].isCollapsed, "the reader collapsed instead of holding its minimum")
        XCTAssertEqual(
            split.test_paneWidths[2],
            split.test_contentSplitItems[1].minimumThickness,
            accuracy: 1,
            "the reader is not at its minimum in a minimum-width window"
        )
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
        XCTAssertTrue(tasks.contains(.today))
        XCTAssertFalse(tasks.contains(.mailTitle))

        selection.setMode(.mail)
        let mail = split.toolbarDefaultItemIdentifiers(NSToolbar(identifier: "test"))
        XCTAssertTrue(mail.contains(.mailTitle))
        XCTAssertFalse(mail.contains(.addProject))
        XCTAssertFalse(mail.contains(.today))

        // The reader's actions are toolbar items over its pane, mail-mode only.
        for action: NSToolbarItem.Identifier in
            [.hideMessage, .categorizeMessage, .openInOutlook] {
            XCTAssertTrue(mail.contains(action), "\(action.rawValue) missing from mail mode")
            XCTAssertFalse(tasks.contains(action), "\(action.rawValue) leaked into tasks mode")
        }

        // Tasks has no divider 1 any more, so nothing of divider 1's is in it.
        XCTAssertFalse(tasks.contains(.inspectorSeparator))
    }

    func testMailToolbarHasOneFinderStyleCategoryMenuExcludingHide() async throws {
        let source = StubMailSource()
        source.setAvailableCategories([
            OutlookCategory(id: 10, name: "Hide", accountUID: 1),
            OutlookCategory(id: 11, name: "Work", accountUID: 1),
        ])
        let mail = MailCoordinator(source: source, defaults: defaults)
        let (split, selection) = makeSplit(mail: mail)
        defer { source.drain(); mail.cancel() }
        selection.setMode(.mail)
        await settleMail(source: source, mail: mail, messages: [MailMessage.fixture(id: 1, accountUID: 1)])
        selection.selectMessages([.recent(1)])

        let identifiers = split.identifiers(for: .mail)
        let hideIndex = try XCTUnwrap(identifiers.firstIndex(of: .hideMessage))
        let categoryIndex = try XCTUnwrap(identifiers.firstIndex(of: .categorizeMessage))
        let outlookIndex = try XCTUnwrap(identifiers.firstIndex(of: .openInOutlook))
        XCTAssertEqual(hideIndex, categoryIndex + 1)
        XCTAssertEqual(outlookIndex, hideIndex + 1)

        let item = try XCTUnwrap(try toolbarItem(split, .categorizeMessage) as? NSMenuToolbarItem)
        XCTAssertNotNil(item.image)
        XCTAssertEqual(item.menu.items.map(\.title), ["Work"])
        XCTAssertEqual(
            (item.menu.items.first?.representedObject as? NSNumber)?.int64Value,
            11
        )
    }

    /// Outlook offers categories per account, and its built-in set belongs to
    /// no account at all, so the menu is the selected message's own account's
    /// list and nothing else.
    func testCategoryMenuOffersOnlyTheSelectedMessagesAccount() async throws {
        let source = StubMailSource()
        source.setAvailableCategories([
            OutlookCategory(id: 1, name: "Family", accountUID: 0),
            OutlookCategory(id: 11, name: "Filed to ND", accountUID: 60_129_542_145),
            OutlookCategory(id: 12, name: "Note", accountUID: 60_129_542_145),
            OutlookCategory(id: 21, name: "Red category", accountUID: 60_129_542_146),
        ])
        let mail = MailCoordinator(source: source, defaults: defaults)
        let (split, selection) = makeSplit(mail: mail)
        defer { source.drain(); mail.cancel() }
        selection.setMode(.mail)
        await settleMail(source: source, mail: mail, messages: [
            MailMessage.fixture(id: 1, accountUID: 60_129_542_145),
            MailMessage.fixture(id: 2, accountUID: 60_129_542_146),
        ])

        selection.selectMessages([.recent(1)])
        let first = try XCTUnwrap(try toolbarItem(split, .categorizeMessage) as? NSMenuToolbarItem)
        XCTAssertEqual(first.menu.items.map(\.title), ["Filed to ND", "Note"])
        XCTAssertTrue(split.validateToolbarItem(first))

        selection.selectMessages([.recent(2)])
        let second = try XCTUnwrap(try toolbarItem(split, .categorizeMessage) as? NSMenuToolbarItem)
        XCTAssertEqual(second.menu.items.map(\.title), ["Red category"])

        // A category is defined in one account, so a selection spanning two
        // has nothing that could be applied to all of it.
        selection.selectMessages([.recent(1), .recent(2)])
        let both = try XCTUnwrap(try toolbarItem(split, .categorizeMessage) as? NSMenuToolbarItem)
        XCTAssertTrue(both.menu.items.isEmpty)
        XCTAssertFalse(split.validateToolbarItem(both))
    }

    func testCategoryMenuAppliesToSelectedMessagesThatLackIt() async throws {
        let source = StubMailSource()
        source.setAvailableCategories([OutlookCategory(id: 11, name: "Work", accountUID: 1)])
        let mail = MailCoordinator(source: source, defaults: defaults)
        let (split, selection) = makeSplit(mail: mail)
        defer { source.drain(); mail.cancel() }
        selection.setMode(.mail)
        let first = MailMessage.fixture(id: 1)
        let alreadyTagged = MailMessage.fixture(id: 2, categoryIDs: [11])
        await settleMail(source: source, mail: mail, messages: [first, alreadyTagged])
        selection.selectMessages([.recent(1), .recent(2)])

        let item = try XCTUnwrap(try toolbarItem(split, .categorizeMessage) as? NSMenuToolbarItem)
        let work = try XCTUnwrap(item.menu.items.first)
        XCTAssertTrue(split.validateToolbarItem(item))
        XCTAssertTrue(split.validateMenuItem(work))
        XCTAssertEqual(work.state, .mixed)
        split.applyCategoryToSelectedMessages(work)
        for _ in 0..<400 {
            if source.categoryChanges.count == 1,
               mail.messages(categoryID: 11).count == 2 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(source.categoryChanges.map(\.id), [1])
        XCTAssertEqual(Set(mail.messages(categoryID: 11).map(\.id)), [1, 2])
        XCTAssertTrue(split.validateToolbarItem(item))
        XCTAssertTrue(split.validateMenuItem(work))
        XCTAssertEqual(work.state, .on)

        split.applyCategoryToSelectedMessages(work)
        for _ in 0..<400 {
            if source.categoryChanges.count == 3,
               mail.messages(categoryID: 11).isEmpty { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(source.categoryChanges.map(\.present), [true, false, false])
        XCTAssertTrue(mail.messages(categoryID: 11).isEmpty)
        XCTAssertTrue(split.validateMenuItem(work))
        XCTAssertEqual(work.state, .off)
    }

    /// Both modes keep the sidebar slot and divider 0's separator. Divider 1
    /// is mail's alone now: tasks is a single pane, and a tracking separator
    /// with no divider to track gets parked over the wrong one.
    func testBothModesKeepTheSidebarSlotAndDividerZerosSeparator() {
        let (split, _) = makeSplit()
        for mode in [PlannerMode.tasks, .mail] {
            let identifiers = split.identifiers(for: mode)
            XCTAssertTrue(identifiers.contains(.sidebarMode), "\(mode) lost the sidebar slot")
            XCTAssertTrue(identifiers.contains(.paneSeparator), "\(mode) lost divider 0's separator")
        }
        XCTAssertTrue(split.identifiers(for: .mail).contains(.inspectorSeparator))
        XCTAssertFalse(split.identifiers(for: .tasks).contains(.inspectorSeparator))
    }

    /// The range pop-up and the refresh button are gone from the toolbar; both
    /// live in the View menu now, which is why the mail section is narrow
    /// enough for the list to hold it at the pane's minimum width.
    func testTheRangeAndRefreshButtonsAreNotInTheToolbar() {
        let (split, _) = makeSplit()
        let identifiers = split.identifiers(for: .mail) + split.identifiers(for: .tasks)
        XCTAssertFalse(identifiers.contains(.windowRange))
        XCTAssertFalse(identifiers.contains(.refreshMail))
    }

    /// Everything between the two tracking separators is confined to the middle
    /// pane's width, so a pane narrower than its own toolbar section pushes
    /// those items into the overflow menu — the title first, which is the
    /// pane's only label.
    func testTheMailListCannotBeNarrowerThanItsToolbarSection() {
        let (split, selection) = makeSplit()
        selection.setMode(.mail)
        XCTAssertGreaterThanOrEqual(
            split.test_contentSplitItems[0].minimumThickness,
            MainSplitViewController.mailToolbarSectionMinimum,
            "the list's minimum is narrower than the toolbar it has to hold"
        )
    }

    /// The floor is real at runtime, not just in the constant: squeezing the
    /// window as far as it goes leaves the list at or above that width.
    func testSqueezingTheWindowNeverTakesTheListBelowItsToolbarSection() {
        let (split, selection) = makeSplit()
        selection.setMode(.mail)
        windows[0].setContentSize(NSSize(width: 200, height: 720))
        split.view.layoutSubtreeIfNeeded()

        XCTAssertGreaterThanOrEqual(
            split.test_paneWidths[1],
            MainSplitViewController.mailToolbarSectionMinimum - 1,
            "the list was squeezed below its toolbar section"
        )
    }

    /// With the sidebar shut, divider 0 does not exist: its tracking separator
    /// (and the leading space that hugs it) must leave the toolbar, or AppKit
    /// parks the separator — and everything laid out against it — over the
    /// wrong divider.
    func testHidingTheSidebarDropsDividerZerosToolbarPieces() {
        let (split, selection) = makeSplit()
        selection.setMode(.mail)
        XCTAssertTrue(split.wantedToolbarIdentifiers().contains(.paneSeparator))
        XCTAssertEqual(split.wantedToolbarIdentifiers().first, .flexibleSpace)

        split.toggleSidebar(nil)
        XCTAssertFalse(split.wantedToolbarIdentifiers().contains(.paneSeparator))
        XCTAssertNotEqual(split.wantedToolbarIdentifiers().first, .flexibleSpace)
        XCTAssertTrue(
            split.wantedToolbarIdentifiers().contains(.inspectorSeparator),
            "divider 1 still exists and keeps its separator"
        )

        split.toggleSidebar(nil)
        XCTAssertTrue(split.wantedToolbarIdentifiers().contains(.paneSeparator))
        XCTAssertEqual(split.wantedToolbarIdentifiers().first, .flexibleSpace)
    }

    /// The sidebar slot is Hide / Show Sidebar, not a mode menu. Mode
    /// follows the selected sidebar row.
    func testTheSidebarSlotTogglesTheSidebar() throws {
        let (split, _) = makeSplit()
        let item = try toolbarItem(split, .sidebarMode)
        XCTAssertFalse(item is NSMenuToolbarItem)
        XCTAssertNotNil(item.image)
        XCTAssertEqual(item.action, #selector(NSSplitViewController.toggleSidebar(_:)))
    }

    /// The toggle item names the direction it would go, as Preview's does.
    func testTheSidebarMenuToggleItemNamesItsDirection() throws {
        let (split, _) = makeSplit()
        let toggle = NSMenuItem(title: "", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "")

        XCTAssertTrue(split.validateMenuItem(toggle))
        XCTAssertEqual(toggle.title, "Hide Sidebar")

        split.toggleSidebar(nil)
        XCTAssertTrue(split.validateMenuItem(toggle))
        XCTAssertEqual(toggle.title, "Show Sidebar")
    }

    /// New Task needs the outline's task context, so it stays tasks-only.
    func testOnlyNewTaskIsModeGated() throws {
        let (split, selection) = makeSplit()
        let project = try model.createProject()
        selection.selectNode(uuid: project.uuid)

        let newTask = NSMenuItem(title: "", action: #selector(MainSplitViewController.newTask(_:)), keyEquivalent: "")
        let newProject = NSMenuItem(title: "", action: #selector(MainSplitViewController.newProject(_:)), keyEquivalent: "")
        XCTAssertTrue(split.validateMenuItem(newTask))
        XCTAssertTrue(split.validateMenuItem(newProject))

        selection.setMode(.mail)
        XCTAssertFalse(split.validateMenuItem(newTask))
        XCTAssertTrue(split.validateMenuItem(newProject))
    }

    /// New Project from mail mode has to land somewhere the user can see it.
    func testNewProjectFromMailModeSwitchesToTasks() {
        let (split, selection) = makeSplit()
        selection.setMode(.mail)
        split.newProject(nil)
        XCTAssertEqual(selection.mode, .tasks)
        XCTAssertEqual(try? model.allProjects().count, 1)
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

    func testFullOutlookResyncStartsARebuild() async {
        let source = StubMailSource()
        let mail = MailCoordinator(source: source, defaults: defaults)
        let (split, _) = makeSplit(mail: mail)
        defer { source.drain(); mail.cancel() }

        split.resyncOutlookIndex(nil)
        for _ in 0..<400 {
            if source.rebuildCount == 1 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(source.rebuildCount, 1)
        XCTAssertTrue(split.mail.isLoading)
        let item = NSMenuItem(
            title: "",
            action: #selector(MainSplitViewController.resyncOutlookIndex(_:)),
            keyEquivalent: ""
        )
        XCTAssertFalse(split.validateMenuItem(item), "resync stayed enabled mid-flight")
    }

    func testShowHiddenMailIsAViewMenuToggleEnabledInMailMode() {
        let (split, selection) = makeSplit()
        let item = NSMenuItem(
            title: "",
            action: #selector(MainSplitViewController.toggleShowsHiddenMail(_:)),
            keyEquivalent: ""
        )

        XCTAssertFalse(split.validateMenuItem(item))
        selection.setMode(.mail)
        XCTAssertTrue(split.validateMenuItem(item))
        XCTAssertEqual(item.title, MailLabels.hiddenMailVisibilityTitle(showing: false))

        split.toggleShowsHiddenMail(item)
        XCTAssertTrue(split.mail.showsHiddenMessages)
        XCTAssertTrue(split.validateMenuItem(item))
        XCTAssertEqual(item.title, MailLabels.hiddenMailVisibilityTitle(showing: true))
    }

    // MARK: - Titles

    func testSelectingRecentMailFocusesTheTimeline() throws {
        let (split, selection) = makeSplit()
        selection.selectMail()
        split.view.layoutSubtreeIfNeeded()

        let window = try XCTUnwrap(split.view.window)
        XCTAssertTrue(
            window.firstResponder === split.mailListViewController.outlineView,
            "mode switch landed focus on \(String(describing: window.firstResponder))"
        )
    }

    func testTheWindowTitleFollowsTheMode() {
        let (split, selection) = makeSplit()
        let tasksTitle = split.test_windowTitle
        selection.setMode(.mail)
        XCTAssertEqual(split.test_windowTitle, MailLabels.recentMailName)
        XCTAssertNotEqual(split.test_windowTitle, tasksTitle)
    }

    func testTheMailTitleFollowsTheSelectedMailbox() {
        let (split, selection) = makeSplit()
        selection.selectMailbox(.search)
        XCTAssertEqual(split.test_windowTitle, MailLabels.searchMailName)
    }
}
