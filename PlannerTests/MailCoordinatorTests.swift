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

    private func message(
        id: Int64,
        hoursAgo: Int,
        subject: String = "Subject",
        isHidden: Bool = false,
        categoryIDs: Set<Int64> = [],
        accountUID: Int64 = 1
    ) -> MailMessage {
        MailMessage(
            id: id,
            subject: subject,
            senderName: "Ada Lovelace",
            senderAddress: "ada@example.com",
            receivedAt: calendar.date(byAdding: .hour, value: -hoursAgo, to: anchor)!,
            isRead: false,
            isHidden: isHidden,
            categoryIDs: categoryIDs,
            accountUID: accountUID
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

    private func waitForSearchRequests(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil("\(count) search(es)", { self.source.pendingSearchCount >= count }, file: file, line: line)
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

    func testOutlookHideCategoryPartitionsTheWindow() async {
        coordinator.refresh()
        await waitForRequests(1)
        source.finish(with: [
            message(id: 1, hoursAgo: 1),
            message(id: 2, hoursAgo: 2, isHidden: true),
        ])
        await waitUntil("loaded", { if case .loaded = self.coordinator.state { return true }; return false })

        XCTAssertEqual(coordinator.messages.map(\.id), [1])
        XCTAssertEqual(coordinator.hiddenMessages.map(\.id), [2])
        XCTAssertEqual(coordinator.allMessages.map(\.id), [1, 2])
        XCTAssertFalse(coordinator.showsHiddenMessages)
    }

    func testShowingHiddenMailPutsHiddenMessagesBackInTheList() async {
        coordinator.refresh()
        await waitForRequests(1)
        source.finish(with: [
            message(id: 1, hoursAgo: 1),
            message(id: 2, hoursAgo: 2, isHidden: true),
        ])
        await waitUntil("loaded", { if case .loaded = self.coordinator.state { return true }; return false })

        coordinator.setShowsHiddenMessages(true)

        XCTAssertEqual(coordinator.messages.map(\.id), [1, 2])
        XCTAssertTrue(defaults.bool(forKey: MailCoordinator.showsHiddenMessagesDefaultsKey))
    }

    func testHideWritesOutlookThenMovesTheEnvelope() async throws {
        coordinator.refresh()
        await waitForRequests(1)
        let visible = message(id: 1, hoursAgo: 1)
        source.finish(with: [visible])
        await waitUntil("loaded", { !self.coordinator.messages.isEmpty })

        try await coordinator.setHidden(true, message: visible)

        XCTAssertEqual(source.hiddenChanges.count, 1)
        XCTAssertEqual(source.hiddenChanges.first?.id, 1)
        XCTAssertEqual(source.hiddenChanges.first?.hidden, true)
        XCTAssertTrue(coordinator.messages.isEmpty)
        XCTAssertEqual(coordinator.hiddenMessages.map(\.id), [1])
    }

    func testUnhideWritesOutlookThenRestoresRecentMail() async throws {
        coordinator.refresh()
        await waitForRequests(1)
        let hidden = message(id: 2, hoursAgo: 1, isHidden: true)
        source.finish(with: [hidden])
        await waitUntil("loaded", { !self.coordinator.hiddenMessages.isEmpty })

        try await coordinator.setHidden(false, message: hidden)

        XCTAssertEqual(source.hiddenChanges.first?.hidden, false)
        XCTAssertEqual(coordinator.messages.map(\.id), [2])
        XCTAssertTrue(coordinator.hiddenMessages.isEmpty)
    }

    func testFailedOutlookWriteDoesNotMoveTheEnvelope() async {
        coordinator.refresh()
        await waitForRequests(1)
        let visible = message(id: 3, hoursAgo: 1)
        source.finish(with: [visible])
        await waitUntil("loaded", { !self.coordinator.messages.isEmpty })
        source.failHiddenChanges(with: OutlookError.permissionDenied)

        do {
            try await coordinator.setHidden(true, message: visible)
            XCTFail("expected Outlook failure")
        } catch {
            XCTAssertEqual(error as? OutlookError, .permissionDenied)
        }

        XCTAssertEqual(coordinator.messages.map(\.id), [3])
        XCTAssertTrue(coordinator.hiddenMessages.isEmpty)
    }

    func testHideMovesEveryRequestedEnvelope() async throws {
        coordinator.refresh()
        await waitForRequests(1)
        let first = message(id: 1, hoursAgo: 1)
        let second = message(id: 2, hoursAgo: 2)
        source.finish(with: [first, second])
        await waitUntil("loaded", { self.coordinator.messages.count == 2 })

        try await coordinator.setHidden(true, messages: [first, second])

        XCTAssertEqual(source.hiddenChanges.map(\.id), [1, 2])
        XCTAssertTrue(coordinator.messages.isEmpty)
        XCTAssertEqual(coordinator.hiddenMessages.map(\.id), [1, 2])
    }

    func testAPartialHideKeepsSuccessfulWrites() async {
        coordinator.refresh()
        await waitForRequests(1)
        let first = message(id: 1, hoursAgo: 1)
        let second = message(id: 2, hoursAgo: 2)
        source.finish(with: [first, second])
        await waitUntil("loaded", { self.coordinator.messages.count == 2 })
        source.failHiddenChange(id: 2, with: OutlookError.permissionDenied)

        do {
            try await coordinator.setHidden(true, messages: [first, second])
            XCTFail("expected Outlook failure")
        } catch {
            XCTAssertEqual(error as? OutlookError, .permissionDenied)
        }

        XCTAssertEqual(coordinator.messages.map(\.id), [2])
        XCTAssertEqual(coordinator.hiddenMessages.map(\.id), [1])
    }

    func testCategoryCatalogExcludesHideAndCategoryFolderExcludesHiddenMail() async {
        source.setAvailableCategories([
            OutlookCategory(id: 10, name: "Hide"),
            OutlookCategory(id: 12, name: "personal"),
            OutlookCategory(id: 11, name: "Work"),
        ])
        coordinator.refresh()
        await waitForRequests(1)
        source.finish(with: [
            message(id: 1, hoursAgo: 1, categoryIDs: [11]),
            message(id: 2, hoursAgo: 2, isHidden: true, categoryIDs: [10, 11]),
            message(id: 3, hoursAgo: 3, categoryIDs: [12]),
        ])
        await waitUntil("loaded", { if case .loaded = self.coordinator.state { return true }; return false })

        XCTAssertEqual(coordinator.categories.map(\.name), ["personal", "Work"])
        XCTAssertEqual(coordinator.messages(categoryID: 11).map(\.id), [1])
    }

    func testApplyingCategorySkipsMessagesThatAlreadyHaveIt() async throws {
        source.setAvailableCategories([OutlookCategory(id: 11, name: "Work")])
        coordinator.refresh()
        await waitForRequests(1)
        let first = message(id: 1, hoursAgo: 1)
        let alreadyTagged = message(id: 2, hoursAgo: 2, categoryIDs: [11])
        source.finish(with: [first, alreadyTagged])
        await waitUntil("loaded", { self.coordinator.messages.count == 2 })

        try await coordinator.setCategory(11, present: true, messages: [first, alreadyTagged])

        XCTAssertEqual(source.categoryChanges.map(\.id), [1])
        XCTAssertEqual(coordinator.messages(categoryID: 11).map(\.id), [1, 2])
    }

    func testPartialCategoryApplyKeepsSuccessfulWrites() async {
        source.setAvailableCategories([OutlookCategory(id: 11, name: "Work")])
        coordinator.refresh()
        await waitForRequests(1)
        let first = message(id: 1, hoursAgo: 1)
        let second = message(id: 2, hoursAgo: 2)
        source.finish(with: [first, second])
        await waitUntil("loaded", { self.coordinator.messages.count == 2 })
        source.failCategoryChange(id: 2, with: OutlookError.permissionDenied)

        do {
            try await coordinator.setCategory(11, present: true, messages: [first, second])
            XCTFail("expected Outlook failure")
        } catch {
            XCTAssertEqual(error as? OutlookError, .permissionDenied)
        }

        XCTAssertEqual(coordinator.messages(categoryID: 11).map(\.id), [1])
        XCTAssertFalse(coordinator.message(id: 2)?.categoryIDs.contains(11) ?? true)
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

    func testRebuildIndexRunsBeforeTheSweep() async {
        coordinator.rebuildIndex()
        await waitForRequests(1)
        XCTAssertEqual(source.rebuildCount, 1)
        XCTAssertEqual(source.userInitiatedFlags, [true])
        XCTAssertEqual(coordinator.state, .loading)
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

    func testTheMonthLongWindowSweepsThirtyDays() async {
        coordinator.setWindowDays(30)
        XCTAssertEqual(coordinator.windowDays, 30)
        await waitForRequests(1)
        XCTAssertEqual(
            source.requestedRanges.last,
            MailWindow.current(days: 30, now: anchor, calendar: calendar)
        )
    }

    /// A length between the menu's entries narrows to the entry below it, so
    /// the stored value is always one the menu can show as current.
    func testAnUnlistedWindowLengthSnapsOntoAChoice() {
        coordinator.setWindowDays(20)
        XCTAssertEqual(coordinator.windowDays, 7)
        XCTAssertEqual(defaults.integer(forKey: MailWindow.daysDefaultsKey), 7)
    }

    // MARK: - Search

    func testFoldersComeFromTheSource() async throws {
        source.setFolders([
            MailFolder(name: "Inbox", messageCount: 4),
            MailFolder(name: "Drafts", messageCount: 1),
        ])
        let folders = try await coordinator.folders()
        XCTAssertEqual(folders.map(\.name), ["Inbox", "Drafts"])
        XCTAssertEqual(folders.map(\.messageCount), [4, 1])
    }

    func testQuickSearchesPersistByNameAndQuery() throws {
        let saved = try XCTUnwrap(coordinator.saveQuickSearch(name: "  Ada  ", query: " from:ada "))

        let restored = MailCoordinator(
            source: NullMailSource(),
            calendar: calendar,
            now: { self.anchor },
            defaults: defaults
        )
        defer { restored.cancel() }

        XCTAssertEqual(restored.quickSearches, [
            MailQuickSearch(id: saved.id, name: "Ada", query: "from:ada"),
        ])
    }

    func testSavingTheSameQuickSearchNameUpdatesRatherThanDuplicates() throws {
        let first = try XCTUnwrap(coordinator.saveQuickSearch(name: "Ada", query: "from:ada"))
        let updated = try XCTUnwrap(coordinator.saveQuickSearch(name: "ada", query: "to:ada"))

        XCTAssertEqual(updated.id, first.id)
        XCTAssertEqual(coordinator.quickSearches.count, 1)
        XCTAssertEqual(coordinator.quickSearches[0].query, "to:ada")
    }

    func testQuickSearchCanBeDeleted() throws {
        let saved = try XCTUnwrap(coordinator.saveQuickSearch(name: "Ada", query: "from:ada"))

        coordinator.deleteQuickSearch(id: saved.id)

        XCTAssertTrue(coordinator.quickSearches.isEmpty)
        XCTAssertNil(defaults.data(forKey: MailCoordinator.quickSearchesDefaultsKey).flatMap {
            try? JSONDecoder().decode([MailQuickSearch].self, from: $0).first
        })
    }

    func testSearchPublishesSourceResults() async {
        coordinator.search("deposition")
        await waitForSearchRequests(1)
        XCTAssertEqual(source.requestedSearchQueries, ["deposition"])
        source.finishSearch(with: [message(id: 7, hoursAgo: 1, subject: "Deposition")])
        await waitUntil("search results", { self.coordinator.searchResults.map(\.id) == [7] })

        XCTAssertEqual(coordinator.searchState, .loaded(coordinator.searchResults))
    }

    func testSearchResultsCoverTheWholeIndexAndOmitHiddenMatchesByDefault() async {
        coordinator.search("brief")
        await waitForSearchRequests(1)
        source.finishSearch(with: [
            message(id: 1, hoursAgo: 1, categoryIDs: [11]),
            message(id: 2, hoursAgo: 2, isHidden: true, categoryIDs: [10, 11]),
            message(id: 3, hoursAgo: 24 * 90, categoryIDs: [12]),
        ])
        await waitUntil("search results", {
            if case .loaded = self.coordinator.searchState { return true }
            return false
        })

        XCTAssertEqual(Set(coordinator.searchResults.map(\.id)), [1, 3])

        coordinator.setShowsHiddenMessages(true)
        XCTAssertEqual(Set(coordinator.searchResults.map(\.id)), [1, 2, 3])
    }

    func testClearingSearchReturnsToIdle() async {
        coordinator.search("deposition")
        await waitForSearchRequests(1)
        coordinator.search("  ")

        XCTAssertEqual(coordinator.searchState, .idle)
        XCTAssertTrue(coordinator.searchResults.isEmpty)
    }

    func testALateSupersededSearchNeverPaints() async {
        coordinator.search("first")
        await waitForSearchRequests(1)
        coordinator.search("second")
        await waitForSearchRequests(2)

        source.finishLatestSearch(with: [message(id: 2, hoursAgo: 1)])
        await waitUntil("second search", { self.coordinator.searchResults.map(\.id) == [2] })
        source.finishSearch(with: [message(id: 1, hoursAgo: 1)])
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(coordinator.searchResults.map(\.id), [2])
    }

    func testSearchFailureIsDistinctFromNoHits() async {
        coordinator.search("bad")
        await waitForSearchRequests(1)
        source.finishSearch(throwing: OlSyncMailError.querySyntax("bad query"))
        await waitUntil("failed search", {
            if case .failed = self.coordinator.searchState { return true }
            return false
        })

        XCTAssertEqual(coordinator.searchState, .failed("bad query"))
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
