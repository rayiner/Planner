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
        XCTAssertEqual(selection.mode, .mail)
        XCTAssertEqual(
            posted,
            [SelectionField.mailbox.rawValue, SelectionField.message.rawValue, SelectionField.mode.rawValue]
        )
    }

    /// Mode is the kind of sidebar row that is selected, so picking a
    /// mailbox from tasks — even the one already stored — must enter mail.
    func testSelectingAMailboxEntersMailMode() {
        let selection = SelectionModel(defaults: defaults)
        XCTAssertEqual(selection.mode, .tasks)
        XCTAssertTrue(selection.isRecentMailSelected)
        selection.selectMailbox(.recent)
        XCTAssertEqual(selection.mode, .mail)
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
        XCTAssertTrue(split.splitViewItems[0].viewController is OutlineViewController)
        XCTAssertTrue(split.splitViewItems[1].viewController is CalendarViewController)
        XCTAssertTrue(split.splitViewItems[2].viewController is InspectorViewController)
    }

    func testSwitchingToMailReplacesBothTrailingPanes() {
        let (split, selection) = makeSplit()
        selection.setMode(.mail)

        XCTAssertEqual(split.splitViewItems.count, 3)
        XCTAssertTrue(split.splitViewItems[1].viewController is MailListViewController)
        XCTAssertTrue(split.splitViewItems[2].viewController is MailReaderViewController)
    }

    func testSwitchingBackRestoresTheTasksPanes() {
        let (split, selection) = makeSplit()
        selection.setMode(.mail)
        selection.setMode(.tasks)

        XCTAssertTrue(split.splitViewItems[1].viewController is CalendarViewController)
        XCTAssertTrue(split.splitViewItems[2].viewController is InspectorViewController)
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
        XCTAssertTrue(split.splitViewItems[1].viewController is MailListViewController)
    }

    // MARK: - Geometry

    /// Mail's reader cannot collapse, so mail's minimum sum is the mail
    /// window's hard floor — it must not exceed tasks', or switching into mail
    /// could be the thing that forces the window wider. The other direction is
    /// covered without matching sums: switching into tasks at a narrower
    /// window sheds the inspector (its resize collapse) rather than growing.
    func testMailsMinimumWidthDoesNotExceedTasksSoSwitchingToMailCannotGrowTheWindow() {
        let (split, selection) = makeSplit()
        let tasksMinimum = split.splitViewItems.reduce(0) { $0 + $1.minimumThickness }
        selection.setMode(.mail)
        let mailMinimum = split.splitViewItems.reduce(0) { $0 + $1.minimumThickness }
        XCTAssertLessThanOrEqual(mailMinimum, tasksMinimum)
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
        let list = split.splitViewItems[1]
        XCTAssertEqual(list.automaticMaximumThickness, NSSplitViewItem.unspecifiedDimension)
        XCTAssertEqual(list.preferredThicknessFraction, 384.0 / 1100.0, accuracy: 0.0001)
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
        split.splitView.setPosition(400 + split.splitView.dividerThickness + 450, ofDividerAt: 1)
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

    /// The inspector is the notes pane: like the reader, it cannot collapse,
    /// from the divider or from a window resize.
    func testTheInspectorCannotCollapse() {
        let (split, _) = makeSplit()
        XCTAssertFalse(split.splitViewItems[2].canCollapse)
        XCTAssertFalse(split.splitViewItems[2].canCollapseFromWindowResize)
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

    /// Mode switches record the divider on the way out; quitting *inside* mail
    /// mode is the same departure and must record too, or the drag reverts.
    func testTheMailDividerPositionSurvivesQuitInsideMailMode() {
        let (split, selection) = makeSplit()
        selection.setMode(.mail)
        split.splitView.setPosition(700, ofDividerAt: 1)
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
        split.splitViewItems[2].isCollapsed = true

        selection.setMode(.tasks)
        selection.setMode(.mail)
        XCTAssertFalse(split.splitViewItems[2].isCollapsed, "mail opened with no reading pane")
    }

    /// Like the reader, the inspector never opens shut: a collapse stored by a
    /// build that allowed one is dropped, not replayed.
    func testTheInspectorNeverOpensCollapsed() {
        let (split, selection) = makeSplit()
        split.splitViewItems[2].isCollapsed = true

        selection.setMode(.mail)
        selection.setMode(.tasks)
        XCTAssertTrue(split.isInspectorVisible, "tasks opened with no notes pane")
    }

    /// A list width stored in a wide window is clamped when it returns in a
    /// narrower one, so the reader keeps its minimum and the sidebar stays put
    /// instead of AppKit squeezing whichever pane is cheapest.
    func testAStoredListWidthTooWideForTheWindowIsClamped() {
        let (split, selection) = makeSplit()
        selection.setMode(.mail)
        split.view.layoutSubtreeIfNeeded()
        let sidebar = split.test_paneWidths[0]
        split.splitView.setPosition(
            sidebar + split.splitView.dividerThickness + 440,
            ofDividerAt: 1
        )
        split.view.layoutSubtreeIfNeeded()
        selection.setMode(.tasks)   // records the 440pt list

        windows[0].setContentSize(NSSize(width: 960, height: 720))
        split.view.layoutSubtreeIfNeeded()
        selection.setMode(.mail)
        split.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(split.splitViewItems[2].isCollapsed)
        XCTAssertGreaterThanOrEqual(
            split.test_paneWidths[2],
            split.splitViewItems[2].minimumThickness - 1,
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
        XCTAssertFalse(split.splitViewItems[2].canCollapse, "the resize trapdoor is back")
    }

    /// At the panes' minimum sum — the narrowest window mail mode permits —
    /// every pane is open at its minimum; the reader gives width, never itself.
    func testAtTheMinimumWindowWidthTheReaderIsOpenAtItsMinimum() {
        let (split, selection) = makeSplit()
        selection.setMode(.mail)
        let minimumSum = split.splitViewItems.reduce(0) { $0 + $1.minimumThickness }
            + CGFloat(split.splitViewItems.count - 1) * split.splitView.dividerThickness

        windows[0].setContentSize(NSSize(width: minimumSum, height: 720))
        split.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(split.splitViewItems[2].isCollapsed, "the reader collapsed instead of holding its minimum")
        XCTAssertEqual(
            split.test_paneWidths[2],
            split.splitViewItems[2].minimumThickness,
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
        XCTAssertTrue(tasks.contains(.weekNavigation))
        XCTAssertFalse(tasks.contains(.newMailFolder))
        XCTAssertFalse(tasks.contains(.mailTitle))

        selection.setMode(.mail)
        let mail = split.toolbarDefaultItemIdentifiers(NSToolbar(identifier: "test"))
        XCTAssertTrue(mail.contains(.newMailFolder))
        XCTAssertTrue(mail.contains(.mailTitle))
        XCTAssertFalse(mail.contains(.addProject))
        XCTAssertFalse(mail.contains(.weekNavigation))

        // The reader's actions are toolbar items over its pane, mail-mode only.
        for action: NSToolbarItem.Identifier in
            [.fileMessage, .removeMessage, .newTaskFromMessage, .openInOutlook] {
            XCTAssertTrue(mail.contains(action), "\(action.rawValue) missing from mail mode")
            XCTAssertFalse(tasks.contains(action), "\(action.rawValue) leaked into tasks mode")
        }

        // The inspector's name (and completion circle) sit past divider 1.
        XCTAssertTrue(tasks.contains(.inspectorTitle))
        XCTAssertFalse(mail.contains(.inspectorTitle))
        let separator = try! XCTUnwrap(tasks.firstIndex(of: .inspectorSeparator))
        let title = try! XCTUnwrap(tasks.firstIndex(of: .inspectorTitle))
        XCTAssertLessThan(separator, title)
    }

    /// A view-backed item that measures as empty becomes AppKit's label
    /// button — the "Info" double chevron that was parking over the calendar.
    func testTheInspectorTitleItemHasARealSize() throws {
        let (split, _) = makeSplit()
        let item = try toolbarItem(split, .inspectorTitle)
        let view = try XCTUnwrap(item.view)
        XCTAssertGreaterThan(view.fittingSize.width, 1)
        XCTAssertGreaterThan(view.intrinsicContentSize.width, 1)
        XCTAssertNotEqual(item.label, "Info")
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
            split.splitViewItems[1].minimumThickness,
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
    /// New Project and New Folder create into sections the unified sidebar
    /// always shows, so they work from either mode and switch to their own.
    func testOnlyNewTaskIsModeGated() throws {
        let (split, selection) = makeSplit()
        let project = try model.createProject()
        selection.selectNode(uuid: project.uuid)

        let newTask = NSMenuItem(title: "", action: #selector(MainSplitViewController.newTask(_:)), keyEquivalent: "")
        let newProject = NSMenuItem(title: "", action: #selector(MainSplitViewController.newProject(_:)), keyEquivalent: "")
        let newFolder = NSMenuItem(title: "", action: #selector(MainSplitViewController.newMailFolder(_:)), keyEquivalent: "")
        XCTAssertTrue(split.validateMenuItem(newTask))
        XCTAssertTrue(split.validateMenuItem(newProject))
        XCTAssertTrue(split.validateMenuItem(newFolder))

        selection.setMode(.mail)
        XCTAssertFalse(split.validateMenuItem(newTask))
        XCTAssertTrue(split.validateMenuItem(newProject))
        XCTAssertTrue(split.validateMenuItem(newFolder))
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

    func testNewFolderCreatesAndSelectsAFolder() {
        let (split, selection) = makeSplit()
        selection.setMode(.mail)
        split.newMailFolder(nil)

        let folders = model.mailFolders()
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(selection.selectedFolderUUID, folders.first?.uuid)
    }

    // MARK: - Titles

    /// The search field is the first descendant of the list pane. Landing
    /// there after Tasks → folder would steal the keyboard from the outline.
    func testSelectingAFolderFromTasksFocusesTheOutlineNotTheSearchField() throws {
        let (split, selection) = makeSplit()
        let folder = try model.createMailFolder(name: "Celerity")
        selection.selectMailbox(.folder(folder.uuid))
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
}
