import XCTest
@testable import Planner

@MainActor
final class EventCoordinatorTests: XCTestCase {
    private var source: StubEventSource!
    private var coordinator: EventCoordinator!

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private let anchor = Date(timeIntervalSince1970: 1_786_000_000)   // 2026-08-14

    override func setUp() {
        super.setUp()
        source = StubEventSource()
        let now = anchor
        coordinator = EventCoordinator(source: source, calendar: calendar, now: { now })
    }

    override func tearDown() {
        coordinator?.cancel()
        source?.drain()
        coordinator = nil
        source = nil
        super.tearDown()
    }

    private func event(id: String, dayOffset: Int, title: String = "Meeting") -> CalendarEvent {
        let start = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: anchor))!
        return CalendarEvent(
            id: id,
            title: title,
            start: calendar.date(byAdding: .hour, value: 9, to: start)!,
            end: calendar.date(byAdding: .hour, value: 10, to: start)!
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

    /// Waits for the coordinator's task to actually reach the source.
    private func waitForRequests(
        _ count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await waitUntil("\(count) request(s)", { self.source.pendingCount >= count }, file: file, line: line)
    }

    // MARK: - Async population

    func testStartsIdleWithNoChips() {
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertTrue(coordinator.chipsByDay.isEmpty)
    }

    func testRefreshIsAsynchronousAndDoesNotBlock() async {
        coordinator.refresh()
        // The point of the feature: refresh() returns before the slow source does.
        XCTAssertEqual(coordinator.state, .loading)
        XCTAssertTrue(coordinator.chipsByDay.isEmpty)

        await waitForRequests(1)
        source.finish(with: [event(id: "a", dayOffset: 0)])
        await waitUntil("loaded") { if case .loaded = self.coordinator.state { return true }; return false }

        XCTAssertEqual(coordinator.chips(forDay: anchor).count, 1)
    }

    func testRefreshRequestsTheCurrentWindow() async {
        coordinator.refresh()
        await waitForRequests(1)
        XCTAssertEqual(source.requestedRanges.count, 1)
        XCTAssertEqual(source.requestedRanges.first, coordinator.window)
    }

    func testChipsAreLookedUpByStartOfDay() async {
        coordinator.refresh()
        await waitForRequests(1)
        source.finish(with: [event(id: "a", dayOffset: 0)])
        await waitUntil("chips") { !self.coordinator.chipsByDay.isEmpty }

        let noon = calendar.date(byAdding: .hour, value: 12, to: calendar.startOfDay(for: anchor))!
        XCTAssertEqual(coordinator.chips(forDay: noon).count, 1, "any instant in the day must resolve")
    }

    // MARK: - Supersede

    func testSecondRefreshDiscardsTheFirstsLateResult() async {
        coordinator.refresh()
        await waitForRequests(1)
        coordinator.refresh()
        await waitForRequests(2)

        // The second call answers first; the first is stale and must not paint.
        source.finishLatest(with: [event(id: "second", dayOffset: 1, title: "Second")])
        await waitUntil("second result applied") { !self.coordinator.chipsByDay.isEmpty }

        source.finish(with: [event(id: "first", dayOffset: 0, title: "First")])
        // Give the superseded reply every chance to land before asserting it did not.
        try? await Task.sleep(for: .milliseconds(100))

        let day1 = calendar.date(byAdding: .day, value: 1, to: anchor)!
        XCTAssertEqual(coordinator.chips(forDay: day1).map(\.title), ["Second"])
        XCTAssertTrue(
            coordinator.chips(forDay: anchor).isEmpty,
            "the superseded refresh must not paint over newer data"
        )
    }

    func testCancelStopsAnInFlightRefreshFromPainting() async {
        coordinator.refresh()
        await waitForRequests(1)
        coordinator.cancel()
        source.finish(with: [event(id: "a", dayOffset: 0)])
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(coordinator.chipsByDay.isEmpty)
    }

    // MARK: - Failure

    func testAppleEventFailureKeepsPreviousChips() async {
        coordinator.refresh()
        await waitForRequests(1)
        source.finish(with: [event(id: "a", dayOffset: 0, title: "Kept")])
        await waitUntil("first load") { !self.coordinator.chipsByDay.isEmpty }

        coordinator.refresh()
        await waitForRequests(1)
        source.finish(throwing: OutlookError.appleEvent(code: -1712))
        await waitUntil("failed") { if case .failed = self.coordinator.state { return true }; return false }

        XCTAssertEqual(
            coordinator.chips(forDay: anchor).map(\.title),
            ["Kept"],
            "a failed send must not blank the grid as a successful empty fetch"
        )
    }

    /// The source wraps a blocking Apple event that never observes cancellation,
    /// so the coordinator's timer has to fire without waiting for it.
    func testHungSourceTimesOutAndKeepsPreviousChips() async {
        coordinator.refresh()
        await waitForRequests(1)
        source.finish(with: [event(id: "a", dayOffset: 0, title: "Kept")])
        await waitUntil("first load") { !self.coordinator.chipsByDay.isEmpty }

        coordinator.test_timeoutSeconds(0)
        coordinator.refresh()
        await waitForRequests(1)
        await waitUntil("timed out") { if case .failed = self.coordinator.state { return true }; return false }

        guard case let .failed(message) = coordinator.state else {
            return XCTFail("expected .failed, got \(coordinator.state)")
        }
        XCTAssertTrue(message.contains("did not respond"), message)
        XCTAssertEqual(
            coordinator.chips(forDay: anchor).map(\.title),
            ["Kept"],
            "timing out must leave the last good chips in place"
        )
    }

    /// The timer only unblocks the spinner. A late real result for the same
    /// generation is still the truth and should paint.
    func testLateResultAfterTimeoutStillApplies() async {
        coordinator.test_timeoutSeconds(0)
        coordinator.refresh()
        await waitForRequests(1)
        await waitUntil("timed out") { if case .failed = self.coordinator.state { return true }; return false }

        source.finish(with: [event(id: "late", dayOffset: 0, title: "Arrived")])
        await waitUntil("late apply") { !self.coordinator.chipsByDay.isEmpty }

        XCTAssertEqual(coordinator.chips(forDay: anchor).map(\.title), ["Arrived"])
        guard case .loaded = coordinator.state else {
            return XCTFail("expected .loaded after the late result, got \(coordinator.state)")
        }
    }

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

    func testFailureSetsFailedStateAndKeepsPreviousChips() async {
        coordinator.refresh()
        await waitForRequests(1)
        source.finish(with: [event(id: "a", dayOffset: 0, title: "Kept")])
        await waitUntil("first load") { !self.coordinator.chipsByDay.isEmpty }
        XCTAssertEqual(coordinator.chips(forDay: anchor).count, 1)

        coordinator.refresh()
        await waitForRequests(1)
        source.finish(throwing: EventSourceError.timedOut(seconds: 30))
        await waitUntil("failed") { if case .failed = self.coordinator.state { return true }; return false }

        guard case let .failed(message) = coordinator.state else {
            return XCTFail("expected .failed, got \(coordinator.state)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(
            coordinator.chips(forDay: anchor).map(\.title),
            ["Kept"],
            "a transient failure must not blank the grid"
        )
    }

    // MARK: - Window enforcement

    func testEventsOutsideTheWindowAreFilteredOut() async {
        coordinator.refresh()
        await waitForRequests(1)

        let farPast = CalendarEvent(
            id: "old",
            title: "Ancient",
            start: calendar.date(byAdding: .year, value: -3, to: anchor)!,
            end: calendar.date(byAdding: .year, value: -3, to: anchor)!.addingTimeInterval(3600)
        )
        let farFuture = CalendarEvent(
            id: "new",
            title: "Distant",
            start: calendar.date(byAdding: .year, value: 3, to: anchor)!,
            end: calendar.date(byAdding: .year, value: 3, to: anchor)!.addingTimeInterval(3600)
        )
        source.finish(with: [farPast, farFuture, event(id: "ok", dayOffset: 0)])
        await waitUntil("load") { if case .loaded = self.coordinator.state { return true }; return false }

        let titles = coordinator.chipsByDay.values.flatMap { $0 }.map(\.title)
        XCTAssertEqual(titles, ["Meeting"], "a source returning out-of-range events must not leak them")
    }

    // MARK: - Notification

    func testPostsOnLoadingAndOnLoaded() async {
        var posts = 0
        // queue: nil so delivery is synchronous with the post; an OperationQueue
        // would make the count a race.
        let token = NotificationCenter.default.addObserver(
            forName: .plannerEventsDidChange,
            object: coordinator,
            queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        coordinator.refresh()
        XCTAssertEqual(posts, 1, "entering .loading is itself a change the toolbar renders")

        await waitForRequests(1)
        source.finish(with: [event(id: "a", dayOffset: 0)])
        await waitUntil("loaded") { if case .loaded = self.coordinator.state { return true }; return false }
        XCTAssertEqual(posts, 2)
    }
}
