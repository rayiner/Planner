import AppKit
import XCTest
@testable import Planner

@MainActor
final class MailStatusTests: PersistenceTestCase {
    private var defaults: UserDefaults!
    private var source: StubMailSource!
    private var split: MainSplitViewController!
    private var selection: SelectionModel!
    private var windows: [NSWindow] = []

    private var coordinator: MailCoordinator { split.mail }
    private var status: EventStatusView { split.test_mailStatusView }

    override func setUp() {
        super.setUp()
        defaults = isolatedDefaults()
        source = StubMailSource()
        selection = SelectionModel(defaults: defaults)
        selection.setMode(.mail)
        split = MainSplitViewController(
            persistence: persistence,
            model: model,
            selection: selection,
            events: EventCoordinator(source: NullEventSource()),
            mail: MailCoordinator(source: source, defaults: defaults),
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
        // The status view's retry hook is wired when the toolbar builds its
        // item, and nothing installs a toolbar on a windowless split.
        _ = split.toolbar(
            NSToolbar(identifier: "test"),
            itemForItemIdentifier: .mailStatus,
            willBeInsertedIntoToolbar: true
        )
    }

    override func tearDown() {
        coordinator.cancel()
        source?.drain()
        for window in windows { window.contentViewController = nil }
        windows = []
        split = nil
        selection = nil
        source = nil
        defaults = nil
        super.tearDown()
    }

    private func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Status

    /// Loading the mail panes starts a sweep of its own, so every test here
    /// begins with one already outstanding; answering all of them lets the
    /// coordinator's generation gate settle on the newest.
    private func sweep(failing error: Error? = nil) async {
        let before = source.requestedRanges.count
        coordinator.refresh(userInitiated: false)
        await settle { self.source.requestedRanges.count > before }
        if let error { source.finishAll(throwing: error) } else { source.finishAll(with: []) }
        await settle { !self.coordinator.isLoading }
        split.test_updateMailStatus()
    }

    /// A planner has no use for a permanent "everything is fine" light; the
    /// absence of this control is the success state.
    func testTheStatusSlotIsEmptyWhenThereIsNothingToSay() async {
        await sweep()
        XCTAssertFalse(status.test_isSpinning)
        XCTAssertFalse(status.test_isShowingError)
    }

    func testASweepInFlightShowsTheSpinner() async {
        let before = source.requestedRanges.count
        coordinator.refresh()
        await settle { self.source.requestedRanges.count > before }
        split.test_updateMailStatus()
        XCTAssertTrue(status.test_isSpinning)
        XCTAssertEqual(status.test_toolTip?.contains("Loading mail…"), true)
        source.finishAll(with: [])
    }

    func testTheTooltipSaysWhatIsShownAndHowFarBack() async {
        let before = source.requestedRanges.count
        coordinator.refresh()
        await settle { self.source.requestedRanges.count > before }
        split.test_updateMailStatus()
        let tooltip = status.test_toolTip ?? ""
        XCTAssertTrue(tooltip.contains("Last 3 Days"), tooltip)
        XCTAssertTrue(tooltip.contains("Stub Mailbox"), tooltip)
        source.finishAll(with: [])
    }

    func testAFailedSweepShowsAWarningWithTheMessage() async {
        await sweep(failing: MailSourceError.messageUnavailable)

        XCTAssertTrue(status.test_isShowingError)
        XCTAssertEqual(status.test_toolTip?.contains("Click to try again."), true)
        XCTAssertFalse(status.test_opensSettings)
    }

    /// Retrying into a consent refusal just refuses again, so the affordance
    /// offers the one thing that can fix it.
    func testAConsentRefusalOffersSettingsRatherThanARetry() async {
        await sweep(failing: OutlookError.permissionDenied)

        XCTAssertTrue(status.test_isShowingError)
        XCTAssertTrue(status.test_opensSettings)
        XCTAssertEqual(status.test_toolTip?.contains("Privacy & Security"), true)
    }

    func testClickingTheWarningRetries() async {
        await sweep(failing: MailSourceError.messageUnavailable)

        let sweeps = source.requestedRanges.count
        status.test_clickError()
        await settle { self.source.requestedRanges.count > sweeps }
        XCTAssertEqual(source.userInitiatedFlags.last, true, "a retry may raise the consent dialog")
    }

    /// Both feeds have the same four states and the same three things to say,
    /// which is what lets one control serve them both.
    func testFeedStatusReducesBothCoordinators() {
        XCTAssertEqual(FeedStatus(EventCoordinator.State.idle), .quiet)
        XCTAssertEqual(FeedStatus(EventCoordinator.State.loaded(Date())), .quiet)
        XCTAssertEqual(FeedStatus(EventCoordinator.State.loading), .loading)
        XCTAssertEqual(FeedStatus(EventCoordinator.State.failed("x")), .failed("x"))

        XCTAssertEqual(FeedStatus(MailCoordinator.State.idle), .quiet)
        XCTAssertEqual(FeedStatus(MailCoordinator.State.loaded(Date())), .quiet)
        XCTAssertEqual(FeedStatus(MailCoordinator.State.loading), .loading)
        XCTAssertEqual(FeedStatus(MailCoordinator.State.failed("x")), .failed("x"))
    }

    // MARK: - The window control

    func testTheRangePopUpCoversOneThroughSevenDays() throws {
        let toolbar = NSToolbar(identifier: "test")
        let item = try XCTUnwrap(split.toolbar(
            toolbar, itemForItemIdentifier: .windowRange, willBeInsertedIntoToolbar: true
        ))
        let button = try XCTUnwrap(item.view as? NSPopUpButton)
        XCTAssertEqual(
            button.itemTitles,
            ["Today", "Last 2 Days", "Last 3 Days", "Last 4 Days",
             "Last 5 Days", "Last 6 Days", "Last 7 Days"]
        )
        XCTAssertEqual(button.selectedTag(), MailWindow.defaultDays)
    }

    /// The window length is a property of Recent Mail; over a folder it would
    /// offer to change something the pane does not show.
    func testTheRangePopUpIsDisabledOverAFolder() throws {
        let toolbar = NSToolbar(identifier: "test")
        let item = try XCTUnwrap(split.toolbar(
            toolbar, itemForItemIdentifier: .windowRange, willBeInsertedIntoToolbar: true
        ))
        let button = try XCTUnwrap(item.view as? NSPopUpButton)
        XCTAssertTrue(button.isEnabled)

        let folder = try model.createMailFolder(name: "Celerity")
        selection.selectMailbox(.folder(folder.uuid))
        XCTAssertFalse(button.isEnabled)
    }

    // MARK: - The keyboard path

    /// Every mail command has a menu item, because a menu you reach by holding
    /// down a toolbar button is not a keyboard path.
    func testEveryMailCommandIsReachableFromTheMenuBar() throws {
        let selectors: [Selector] = [
            #selector(MainSplitViewController.showTasksMode(_:)),
            #selector(MainSplitViewController.showMailMode(_:)),
            #selector(MainSplitViewController.newMailFolder(_:)),
            #selector(MainSplitViewController.saveMessageToFolder(_:)),
            #selector(MainSplitViewController.moveMessageToFolder(_:)),
            #selector(MainSplitViewController.removeSavedMessage(_:)),
            #selector(MainSplitViewController.newTaskFromMessage(_:)),
            #selector(MainSplitViewController.openMessageInOutlook(_:)),
            #selector(MainSplitViewController.refreshCurrentMode(_:)),
        ]
        let menu = try XCTUnwrap(loadMainMenu())
        let actions = Set(allItems(of: menu).compactMap(\.action))
        for selector in selectors {
            XCTAssertTrue(actions.contains(selector), "\(selector) has no menu item")
        }
    }

    /// Two items sharing a key equivalent means one of them silently never
    /// fires. ⌘1/⌘2 and ⇧⌘N were all added at once, so this is worth checking.
    func testNoTwoMenuItemsShareAKeyEquivalent() throws {
        let menu = try XCTUnwrap(loadMainMenu())
        var seen: [String: String] = [:]
        for item in allItems(of: menu) where !item.keyEquivalent.isEmpty {
            let key = "\(item.keyEquivalentModifierMask.rawValue)-\(item.keyEquivalent)"
            if let existing = seen[key] {
                XCTFail("“\(item.title)” and “\(existing)” share a shortcut")
            }
            seen[key] = item.title
        }
    }

    private func loadMainMenu() -> NSMenu? {
        var objects: NSArray?
        let bundle = Bundle(for: MainSplitViewController.self)
        guard bundle.loadNibNamed("MainMenu", owner: nil, topLevelObjects: &objects) else {
            return nil
        }
        return objects?.compactMap { $0 as? NSMenu }.first { $0.title == "Main Menu" }
    }

    private func allItems(of menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item -> [NSMenuItem] in
            [item] + (item.submenu.map(allItems(of:)) ?? [])
        }
    }
}
