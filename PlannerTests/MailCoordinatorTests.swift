import XCTest
@testable import Planner

@MainActor
final class MailCoordinatorTests: XCTestCase {
    private var source: StubMailSource!
    private var coordinator: MailCoordinator!
    private var defaults: UserDefaults!

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private let anchor = Date(timeIntervalSince1970: 1_786_100_000)   // 2026-08-15

    override func setUp() {
        super.setUp()
        source = StubMailSource()
        defaults = UserDefaults(suiteName: "MailCoordinatorTests.\(UUID().uuidString)")!
        let now = anchor
        coordinator = MailCoordinator(
            source: source,
            calendar: calendar,
            now: { now },
            defaults: defaults
        )
    }

    override func tearDown() {
        coordinator?.cancel()
        source?.drain()
        coordinator = nil
        source = nil
        defaults = nil
        super.tearDown()
    }

    private func message(id: Int64, hoursAgo: Int, subject: String = "Subject") -> MailMessage {
        MailMessage(
            id: id,
            subject: subject,
            senderName: "Ada Lovelace",
            senderAddress: "ada@example.com",
            receivedAt: calendar.date(byAdding: .hour, value: -hoursAgo, to: anchor)!,
            isRead: false
        )
    }

    // The source runs off the main actor, so nothing here can be settled by
    // yielding — these poll the condition instead of guessing at a delay.

    private func waitUntil(
        _ description: String,
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for \(description)", file: file, line: line)
    }

    private func waitForRequests(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil("\(count) sweep(s)", { self.source.pendingCount >= count }, file: file, line: line)
    }

    private func waitForDetailRequests(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil("\(count) body request(s)", { self.source.pendingDetailCount >= count }, file: file, line: line)
    }

    // MARK: - Async population

    func testStartsIdleWithNoMessages() {
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertTrue(coordinator.messages.isEmpty)
    }

    func testRefreshIsAsynchronousAndDoesNotBlock() async {
        coordinator.refresh()
        XCTAssertEqual(coordinator.state, .loading)
        XCTAssertTrue(coordinator.messages.isEmpty)
        await waitForRequests(1)
        source.finish(with: [message(id: 1, hoursAgo: 1)])
        await waitUntil("loaded", { if case .loaded = self.coordinator.state { return true }; return false })
        XCTAssertEqual(coordinator.messages.map(\.id), [1])
    }

    func testMessagesAreOrderedNewestFirstRegardlessOfSourceOrder() async {
        coordinator.refresh()
        await waitForRequests(1)
        source.finish(with: [
            message(id: 1, hoursAgo: 10),
            message(id: 2, hoursAgo: 1),
            message(id: 3, hoursAgo: 5),
        ])
        await waitUntil("loaded", { !self.coordinator.messages.isEmpty })
        XCTAssertEqual(coordinator.messages.map(\.id), [2, 3, 1])
    }

    /// Two messages that arrived in the same second must not swap places
    /// between refreshes, or the list reshuffles under the user's cursor.
    func testTiesBreakOnIdSoOrderIsStable() async {
        let sameInstant = calendar.date(byAdding: .hour, value: -2, to: anchor)!
        coordinator.refresh()
        await waitForRequests(1)
        source.finish(with: [
            MailMessage.fixture(id: 7, receivedAt: sameInstant),
            MailMessage.fixture(id: 9, receivedAt: sameInstant),
        ])
        await waitUntil("loaded", { !self.coordinator.messages.isEmpty })
        XCTAssertEqual(coordinator.messages.map(\.id), [9, 7])
    }

    func testRequestedRangeIsTheRollingWindow() async {
        coordinator.refresh()
        await waitForRequests(1)
        XCTAssertEqual(
            source.requestedRanges.first,
            MailWindow.current(days: MailWindow.defaultDays, now: anchor, calendar: calendar)
        )
    }

    // MARK: - Consent

    func testAutomaticRefreshIsNotUserInitiated() async {
        coordinator.refresh()
        await waitForRequests(1)
        XCTAssertEqual(source.userInitiatedFlags, [false])
    }

    func testExplicitRefreshIsUserInitiated() async {
        coordinator.refresh(userInitiated: true)
        await waitForRequests(1)
        XCTAssertEqual(source.userInitiatedFlags, [true])
    }

    // MARK: - Superseded refreshes

    func testALateReplyFromASupersededRefreshNeverPaints() async {
        coordinator.refresh()
        await waitForRequests(1)
        coordinator.refresh()
        await waitForRequests(2)

        source.finishLatest(with: [message(id: 2, hoursAgo: 1)])
        await waitUntil("second sweep applied", { !self.coordinator.messages.isEmpty })
        XCTAssertEqual(coordinator.messages.map(\.id), [2])

        // The stale first sweep now answers with something else entirely.
        source.finish(with: [message(id: 99, hoursAgo: 2)])
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(coordinator.messages.map(\.id), [2], "a superseded sweep painted over newer data")
    }

    // MARK: - Failure

    func testAFailedRefreshKeepsWhateverWasAlreadyLoaded() async {
        coordinator.refresh()
        await waitForRequests(1)
        source.finish(with: [message(id: 1, hoursAgo: 1)])
        await waitUntil("loaded", { !self.coordinator.messages.isEmpty })

        coordinator.refresh()
        await waitForRequests(1)
        source.finish(throwing: MailSourceError.messageUnavailable)
        await waitUntil("failed", { if case .failed = self.coordinator.state { return true }; return false })

        XCTAssertEqual(coordinator.messages.map(\.id), [1], "a failed refresh blanked the list")
    }

    func testFailureCarriesTheSettingsURLWhenTheUserMustFixItOutside() async {
        coordinator.refresh()
        await waitForRequests(1)
        source.finish(throwing: OutlookError.permissionDenied)
        await waitUntil("failed", { if case .failed = self.coordinator.state { return true }; return false })
        XCTAssertEqual(coordinator.failureSettingsURL, OutlookError.automationSettingsURL)
    }

    func testANewRefreshClearsTheStaleSettingsURL() async {
        coordinator.refresh()
        await waitForRequests(1)
        source.finish(throwing: OutlookError.permissionDenied)
        await waitUntil("failed", { self.coordinator.failureSettingsURL != nil })
        coordinator.refresh()
        XCTAssertNil(coordinator.failureSettingsURL)
    }

    func testAHungSourceStillLeavesLoading() async {
        coordinator.test_timeoutSeconds(0)
        coordinator.refresh()
        await waitUntil("timed out", { if case .failed = self.coordinator.state { return true }; return false })
        if case let .failed(message) = coordinator.state {
            XCTAssertTrue(message.contains("didn’t respond"), message)
        }
    }

    // MARK: - Day rollover

    func testDayRolloverReSweeps() async {
        coordinator.refresh()
        await waitForRequests(1)
        source.finish(with: [])
        await waitUntil("loaded", { if case .loaded = self.coordinator.state { return true }; return false })

        coordinator.test_dayDidChange()
        await waitForRequests(1)
        XCTAssertEqual(source.requestedRanges.count, 2)
        XCTAssertEqual(source.userInitiatedFlags.last, false, "the rollover must not raise a consent dialog")
    }

    // MARK: - Window length

    func testWindowDaysComeFromDefaults() {
        defaults.set(5, forKey: MailWindow.daysDefaultsKey)
        let coordinator = MailCoordinator(
            source: source,
            calendar: calendar,
            now: { self.anchor },
            defaults: defaults
        )
        XCTAssertEqual(coordinator.windowDays, 5)
        coordinator.cancel()
    }

    func testChangingWindowDaysPersistsAndReSweeps() async {
        coordinator.setWindowDays(7)
        XCTAssertEqual(coordinator.windowDays, 7)
        XCTAssertEqual(defaults.integer(forKey: MailWindow.daysDefaultsKey), 7)
        await waitForRequests(1)
        XCTAssertEqual(
            source.requestedRanges.last,
            MailWindow.current(days: 7, now: anchor, calendar: calendar)
        )
    }

    func testSettingTheSameWindowLengthDoesNotReSweep() async {
        coordinator.setWindowDays(MailWindow.defaultDays)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(source.requestedRanges.isEmpty)
    }

    func testWindowDaysAreClampedBeforeBeingStored() {
        coordinator.setWindowDays(99)
        XCTAssertEqual(coordinator.windowDays, MailWindow.maximumDays)
        XCTAssertEqual(defaults.integer(forKey: MailWindow.daysDefaultsKey), MailWindow.maximumDays)
    }

    // MARK: - Bodies

    func testAskingForABodyStartsExactlyOneFetch() async {
        XCTAssertEqual(coordinator.detailState(for: 42), .loading)
        XCTAssertEqual(coordinator.detailState(for: 42), .loading)
        await waitForDetailRequests(1)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(source.requestedDetailIDs, [42])
    }

    func testALoadedBodyIsCachedAndNotRefetched() async {
        _ = coordinator.detailState(for: 42)
        await waitForDetailRequests(1)
        source.finishDetail(.fixture(id: 42, body: "Hello"))
        await waitUntil("body loaded", { self.coordinator.cachedDetail(for: 42) != nil })

        XCTAssertEqual(coordinator.detailState(for: 42), .loaded(.fixture(id: 42, body: "Hello")))
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(source.requestedDetailIDs, [42], "a cached body was fetched twice")
    }

    func testABodyCacheSurvivesARefresh() async {
        _ = coordinator.detailState(for: 42)
        await waitForDetailRequests(1)
        source.finishDetail(.fixture(id: 42))
        await waitUntil("body loaded", { self.coordinator.cachedDetail(for: 42) != nil })

        coordinator.refresh()
        await waitForRequests(1)
        source.finish(with: [message(id: 42, hoursAgo: 1)])
        await waitUntil("loaded", { !self.coordinator.messages.isEmpty })
        XCTAssertNotNil(coordinator.cachedDetail(for: 42), "the session body cache was dropped on refresh")
    }

    func testAFailedBodyIsRetriedOnTheNextAsk() async {
        _ = coordinator.detailState(for: 42)
        await waitForDetailRequests(1)
        source.finishDetail(id: 42, throwing: MailSourceError.messageUnavailable)
        await waitUntil("body failed", {
            if case .failed = self.coordinator.detailState(for: 42, load: false) { return true }
            return false
        })
        XCTAssertEqual(coordinator.detailState(for: 42), .loading)
        await waitUntil("retried", { self.source.requestedDetailIDs.count == 2 })
    }

    func testAHungBodyFetchStillLeavesLoading() async {
        coordinator.test_detailTimeoutSeconds(0)
        _ = coordinator.detailState(for: 42)
        await waitUntil("body timed out", {
            if case .failed = self.coordinator.detailState(for: 42, load: false) { return true }
            return false
        })
    }

    func testLoadDetailReturnsTheCachedCopyWithoutAFetch() async throws {
        _ = coordinator.detailState(for: 42)
        await waitForDetailRequests(1)
        source.finishDetail(.fixture(id: 42, body: "cached"))
        await waitUntil("body loaded", { self.coordinator.cachedDetail(for: 42) != nil })

        let detail = try await coordinator.loadDetail(for: 42)
        XCTAssertEqual(detail.body, "cached")
        XCTAssertEqual(source.requestedDetailIDs, [42])
    }

    // MARK: - Reveal

    func testRevealForwardsToTheSource() async throws {
        try await coordinator.reveal(messageID: 7)
        XCTAssertEqual(source.revealedIDs, [7])
    }

    // MARK: - Expiry

    func testExpiryDayUsesTheCurrentWindowLength() {
        let message = message(id: 1, hoursAgo: 1)
        XCTAssertEqual(
            coordinator.expiryDay(for: message),
            MailWindow.expiryDay(for: message.receivedAt, days: MailWindow.defaultDays, calendar: calendar)
        )
    }

    // MARK: - Notifications

    func testARefreshPostsAChangeNotification() async {
        let expectation = expectation(forNotification: .plannerMailDidChange, object: coordinator)
        coordinator.refresh()
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testALoadedBodyPostsItsOwnNotificationNamingTheMessage() async {
        let expectation = expectation(forNotification: .plannerMailDetailDidChange, object: coordinator) { note in
            note.userInfo?[MailChangeUserInfoKey.messageID] as? Int64 == 42
        }
        _ = coordinator.detailState(for: 42)
        await waitForDetailRequests(1)
        source.finishDetail(.fixture(id: 42))
        await fulfillment(of: [expectation], timeout: 1)
    }
}
