import XCTest
@testable import Planner

/// The feed's visible chrome, and the command that drives it.
@MainActor
final class EventStatusTests: XCTestCase {
    private var source: StubEventSource!
    private var coordinator: EventCoordinator!
    private var status: EventStatusView!

    // `setUp()` is nonisolated even in a @MainActor class; the async override
    // inherits the isolation, which the AppKit view needs.
    override func setUp() async throws {
        source = StubEventSource()
        coordinator = EventCoordinator(source: source)
        status = EventStatusView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
    }

    override func tearDown() async throws {
        coordinator?.cancel()
        source?.drain()
        status = nil
        coordinator = nil
        source = nil
    }

    private func apply(_ state: EventCoordinator.State, settingsURL: URL? = nil) {
        status.apply(state, settingsURL: settingsURL, detail: "Calendar\nEvents shown: Jun 8 – Nov 15")
    }

    private func waitUntil(_ description: String, _ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for \(description)")
    }

    // MARK: - Visibility

    /// A planner has no use for a permanent "everything is fine" light.
    func testTheControlIsInvisibleWhenThereIsNothingToSay() {
        apply(.idle)
        XCTAssertTrue(status.isHidden)
        apply(.loaded(Date()))
        XCTAssertTrue(status.isHidden)
        XCTAssertNil(status.test_toolTip)
    }

    func testLoadingShowsASpinner() {
        apply(.loading)
        XCTAssertFalse(status.isHidden)
        XCTAssertTrue(status.test_isSpinning)
        XCTAssertFalse(status.test_isShowingError)
    }

    func testFailureShowsAnErrorRatherThanASpinner() {
        apply(.failed("Microsoft Outlook isn’t running."))
        XCTAssertFalse(status.isHidden)
        XCTAssertTrue(status.test_isShowingError)
        XCTAssertFalse(status.test_isSpinning)
    }

    func testRecoveringFromAFailureClearsTheError() {
        apply(.failed("Microsoft Outlook isn’t running."))
        apply(.loading)
        XCTAssertFalse(status.test_isShowingError)
        apply(.loaded(Date()))
        XCTAssertTrue(status.isHidden)
    }

    // MARK: - Tooltip

    /// The window bounds have to be discoverable from somewhere, and the grid
    /// deliberately shows nothing outside them.
    func testTheLoadingTooltipNamesTheSourceAndTheRange() {
        apply(.loading)
        let tooltip = status.test_toolTip ?? ""
        XCTAssertTrue(tooltip.contains("Calendar"), tooltip)
        XCTAssertTrue(tooltip.contains("Jun 8"), tooltip)
        XCTAssertTrue(tooltip.contains("Nov 15"), tooltip)
    }

    func testTheErrorTooltipCarriesTheMessageAndWhatClickingDoes() {
        apply(.failed("Microsoft Outlook isn’t running."))
        let tooltip = status.test_toolTip ?? ""
        XCTAssertTrue(tooltip.contains("isn’t running"), tooltip)
        XCTAssertTrue(tooltip.contains("try again"), tooltip)
    }

    func testAConsentFailureOffersSettingsInsteadOfARetry() {
        apply(.failed("Planner isn’t allowed to control Microsoft Outlook."),
              settingsURL: OutlookError.automationSettingsURL)
        XCTAssertTrue(status.test_opensSettings)
        XCTAssertTrue(status.test_toolTip?.contains("Privacy & Security") ?? false)
    }

    // MARK: - Click routing

    /// Retrying into a consent refusal just refuses again, so the two failures
    /// must not share a button action.
    func testClickingRoutesToRetryOrToSettingsButNeverBoth() {
        var retries = 0
        var settingsOpened = 0
        status.onRetry = { retries += 1 }
        status.onOpenAutomationSettings = { settingsOpened += 1 }

        apply(.failed("Microsoft Outlook isn’t running."))
        status.test_clickError()
        XCTAssertEqual(retries, 1)
        XCTAssertEqual(settingsOpened, 0)

        apply(.failed("Planner isn’t allowed to control Microsoft Outlook."),
              settingsURL: OutlookError.automationSettingsURL)
        status.test_clickError()
        XCTAssertEqual(retries, 1)
        XCTAssertEqual(settingsOpened, 1)
    }

    // MARK: - Coordinator plumbing

    func testTheCoordinatorRecordsWhenAFailureNeedsSystemSettings() async {
        coordinator.refresh()
        await waitUntil("request") { self.source.pendingCount >= 1 }
        source.finish(throwing: OutlookError.permissionDenied)
        await waitUntil("failure") {
            if case .failed = self.coordinator.state { return true }
            return false
        }
        XCTAssertEqual(coordinator.failureSettingsURL, OutlookError.automationSettingsURL)
    }

    func testAnOrdinaryFailureCarriesNoSettingsURL() async {
        coordinator.refresh()
        await waitUntil("request") { self.source.pendingCount >= 1 }
        source.finish(throwing: OutlookError.notRunning)
        await waitUntil("failure") {
            if case .failed = self.coordinator.state { return true }
            return false
        }
        XCTAssertNil(coordinator.failureSettingsURL)
    }

    func testAFreshRefreshClearsAPreviousSettingsURL() async {
        coordinator.refresh()
        await waitUntil("request") { self.source.pendingCount >= 1 }
        source.finish(throwing: OutlookError.permissionDenied)
        await waitUntil("failure") { self.coordinator.failureSettingsURL != nil }

        coordinator.refresh()
        XCTAssertNil(coordinator.failureSettingsURL, "a new attempt is not still refused")
    }

    // MARK: - Toolbar slot

    /// Hiding only the inner view leaves an empty pill sitting in the toolbar,
    /// which reads as a broken control rather than as nothing.
    func testTheToolbarSlotItselfGoesAwayWhenThereIsNothingToSay() async {
        let persistence = PersistenceController(inMemory: true)
        let split = MainSplitViewController(
            persistence: persistence,
            model: ModelController(persistence: persistence),
            selection: SelectionModel(defaults: isolatedDefaults()),
            events: coordinator,
            mail: MailCoordinator(source: NullMailSource(), defaults: isolatedDefaults()),
            userDefaults: isolatedDefaults()
        )
        XCTAssertFalse(split.test_isEventStatusVisible, "idle shows nothing")

        // Loading the view brings up the calendar controller, which refreshes.
        split.loadViewIfNeeded()
        await waitUntil("initial request") { self.source.pendingCount >= 1 }
        XCTAssertTrue(split.test_isEventStatusVisible, "a refresh in flight shows the spinner")

        source.finishLatest(with: [])
        await waitUntil("loaded") {
            if case .loaded = self.coordinator.state { return true }
            return false
        }
        XCTAssertFalse(split.test_isEventStatusVisible, "success is silent")

        coordinator.refresh()
        await waitUntil("second request") { self.source.pendingCount >= 1 }
        source.finishLatest(throwing: OutlookError.notRunning)
        await waitUntil("failed") {
            if case .failed = self.coordinator.state { return true }
            return false
        }
        XCTAssertTrue(split.test_isEventStatusVisible, "a failure has something to say")
    }

    // MARK: - Day rollover

    /// The window is anchored on today, so an app left open overnight would
    /// otherwise keep yesterday's range.
    func testADayRolloverTriggersARefresh() async {
        coordinator.refresh()
        await waitUntil("first request") { self.source.pendingCount >= 1 }
        source.finish(with: [])
        await waitUntil("loaded") {
            if case .loaded = self.coordinator.state { return true }
            return false
        }
        XCTAssertEqual(source.requestedRanges.count, 1)

        coordinator.test_dayDidChange()
        await waitUntil("second request") { self.source.requestedRanges.count >= 2 }
        XCTAssertEqual(coordinator.state, .loading)
        XCTAssertEqual(source.userInitiatedFlags, [false, false], "rollover must not raise a consent dialog")
    }

    func testLoadingTheSplitStartsAnAutomaticRefresh() async {
        let persistence = PersistenceController(inMemory: true)
        let split = MainSplitViewController(
            persistence: persistence,
            model: ModelController(persistence: persistence),
            selection: SelectionModel(defaults: isolatedDefaults()),
            events: coordinator,
            mail: MailCoordinator(source: NullMailSource(), defaults: isolatedDefaults()),
            userDefaults: isolatedDefaults()
        )
        split.loadViewIfNeeded()
        await waitUntil("launch refresh") { self.source.pendingCount >= 1 }
        XCTAssertEqual(source.userInitiatedFlags, [false], "launch must not raise a consent dialog")
    }
}
