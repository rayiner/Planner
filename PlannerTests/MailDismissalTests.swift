import XCTest
@testable import Planner

@MainActor
final class MailDismissalTests: XCTestCase {
    private var source: StubMailSource!
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
        defaults = UserDefaults(suiteName: "MailDismissalTests.\(UUID().uuidString)")!
    }

    override func tearDown() {
        source?.drain()
        source = nil
        defaults = nil
        super.tearDown()
    }

    private func message(id: Int64, hoursAgo: Int) -> MailMessage {
        MailMessage(
            id: id,
            subject: "S\(id)",
            senderName: "Ada Lovelace",
            senderAddress: "ada@example.com",
            receivedAt: calendar.date(byAdding: .hour, value: -hoursAgo, to: anchor)!,
            isRead: false
        )
    }

    private func makeCoordinator(
        envelopes: MailEnvelopeStore = .disabled,
        dismissals: MailDismissalStore = .disabled
    ) -> MailCoordinator {
        let now = anchor
        return MailCoordinator(
            source: source,
            calendar: calendar,
            now: { now },
            defaults: defaults,
            envelopeStore: envelopes,
            dismissalStore: dismissals
        )
    }

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

    private func load(_ coordinator: MailCoordinator, _ messages: [MailMessage]) async {
        coordinator.refresh()
        await waitForRequests(1)
        source.finish(with: messages)
        await waitUntil("loaded", { if case .loaded = coordinator.state { return true }; return false })
    }

    // MARK: - The membership set

    func testADismissalMatchesTheSameMessage() {
        var set = MailDismissalSet()
        set.insert(message(id: 7, hoursAgo: 2))
        XCTAssertTrue(set.contains(message(id: 7, hoursAgo: 2)))
    }

    /// The reason the date is part of the key: Outlook record ids are unique
    /// only inside one local database, so a rebuild can hand id 7 to something
    /// else entirely. That message must not inherit the dismissal.
    func testADismissalDoesNotMatchAReusedIDWithADifferentDate() {
        var set = MailDismissalSet()
        set.insert(message(id: 7, hoursAgo: 2))
        XCTAssertFalse(set.contains(message(id: 7, hoursAgo: 40)))
    }

    /// Dates arrive from two directions — decoded from JSON and decoded from an
    /// Apple event — and a row that silently returns because the last bits
    /// differ would be a bug with no visible cause.
    func testSubSecondNoiseStillMatches() {
        let exact = message(id: 7, hoursAgo: 2)
        let noisy = MailMessage(
            id: exact.id,
            subject: exact.subject,
            senderName: exact.senderName,
            senderAddress: exact.senderAddress,
            receivedAt: exact.receivedAt.addingTimeInterval(0.0004),
            isRead: exact.isRead
        )
        var set = MailDismissalSet()
        set.insert(exact)
        XCTAssertTrue(set.contains(noisy))
    }

    func testRemoveOnlyClearsTheMatchingDismissal() {
        var set = MailDismissalSet()
        set.insert(message(id: 7, hoursAgo: 2))
        set.remove(message(id: 7, hoursAgo: 40))
        XCTAssertTrue(set.contains(message(id: 7, hoursAgo: 2)), "a non-matching remove cleared the entry")
        set.remove(message(id: 7, hoursAgo: 2))
        XCTAssertTrue(set.isEmpty)
    }

    func testPruningDropsWhatCanNeverReturnAndKeepsTheRest() {
        var set = MailDismissalSet()
        set.insert(message(id: 1, hoursAgo: 2))
        set.insert(message(id: 2, hoursAgo: 24 * 30))
        let cutoff = calendar.date(byAdding: .day, value: -MailWindow.maximumDays, to: anchor)!
        XCTAssertEqual(set.pruned(before: cutoff).entries.map(\.id), [1])
    }

    // MARK: - Store round trip

    func testTheStoreRoundTripsARecord() {
        let store = MailDismissalStore.temporary()
        store.save(MailDismissalRecord(sourceID: "stub", dismissals: [
            MailDismissal(id: 3, receivedAt: anchor),
        ]))
        XCTAssertEqual(store.load()?.dismissals.map(\.id), [3])
    }

    // MARK: - The coordinator

    func testDismissingRemovesTheRowFromTheList() async {
        let coordinator = makeCoordinator()
        await load(coordinator, [message(id: 3, hoursAgo: 1), message(id: 2, hoursAgo: 2)])

        coordinator.dismiss(message(id: 3, hoursAgo: 1))
        XCTAssertEqual(coordinator.messages.map(\.id), [2])
        coordinator.cancel()
    }

    func testDismissingSurvivesARefresh() async {
        let coordinator = makeCoordinator()
        let window = [message(id: 3, hoursAgo: 1), message(id: 2, hoursAgo: 2)]
        await load(coordinator, window)
        coordinator.dismiss(message(id: 3, hoursAgo: 1))

        await load(coordinator, window)
        XCTAssertEqual(coordinator.messages.map(\.id), [2], "the refresh brought the dismissed row back")
        coordinator.cancel()
    }

    /// The point of the whole feature: a new coordinator over the same sidecar
    /// is what a relaunch is.
    func testDismissingSurvivesARelaunch() async {
        let store = MailDismissalStore.temporary()
        let first = makeCoordinator(dismissals: store)
        await load(first, [message(id: 3, hoursAgo: 1), message(id: 2, hoursAgo: 2)])
        first.dismiss(message(id: 3, hoursAgo: 1))
        first.cancel()

        let second = makeCoordinator(dismissals: store)
        await load(second, [message(id: 3, hoursAgo: 1), message(id: 2, hoursAgo: 2)])
        XCTAssertEqual(second.messages.map(\.id), [2])
        second.cancel()
    }

    /// A dismissal is painted before Outlook answers, so the row must not flash
    /// up from the envelope cache on the way.
    func testACachedEnvelopeIsFilteredBeforeTheFirstSweep() {
        let envelopes = MailEnvelopeStore.temporary()
        let dismissals = MailDismissalStore.temporary()
        envelopes.save(
            MailEnvelopeRecord(
                sourceID: "stub",
                windowDays: MailWindow.defaultDays,
                fetchedAt: anchor,
                messages: [message(id: 3, hoursAgo: 1), message(id: 2, hoursAgo: 2)]
            )
        )
        dismissals.save(
            MailDismissalRecord(sourceID: "stub", dismissals: [
                MailDismissal(id: 3, receivedAt: message(id: 3, hoursAgo: 1).receivedAt),
            ])
        )
        let painted = makeCoordinator(envelopes: envelopes, dismissals: dismissals)
        XCTAssertEqual(painted.messages.map(\.id), [2])
        painted.cancel()
    }

    func testDismissalsFromAnotherSourceAreIgnored() {
        let store = MailDismissalStore.temporary()
        store.save(MailDismissalRecord(sourceID: "outlook", dismissals: [
            MailDismissal(id: 3, receivedAt: message(id: 3, hoursAgo: 1).receivedAt),
        ]))
        XCTAssertEqual(makeCoordinator(dismissals: store).dismissedCount, 0)
    }

    /// The regression this design exists to prevent. `MailEnvelopeSweep.plan`
    /// asks which ids we already hold envelopes for; if a dismissed message
    /// stopped counting, it would read as an unknown id in the tail and force
    /// every later refresh down the full re-read path.
    func testADismissedMessageIsStillOfferedToTheIncrementalSweep() async {
        let coordinator = makeCoordinator()
        let window = [message(id: 3, hoursAgo: 1), message(id: 2, hoursAgo: 2)]
        await load(coordinator, window)
        coordinator.dismiss(message(id: 3, hoursAgo: 1))

        coordinator.refresh()
        await waitForRequests(1)
        XCTAssertEqual(
            coordinator.allMessages.map(\.id),
            [3, 2],
            "the dismissed envelope was thrown away instead of kept"
        )
        XCTAssertEqual(
            source.knownIDsPerRequest.last?.sorted(),
            [2, 3],
            "the dismissed id was withheld from the sweep, forcing a full re-read"
        )
        source.finish(with: window)
        coordinator.cancel()
    }

    func testTheEnvelopeCacheKeepsDismissedMessages() async {
        let envelopes = MailEnvelopeStore.temporary()
        let coordinator = makeCoordinator(envelopes: envelopes)
        await load(coordinator, [message(id: 3, hoursAgo: 1), message(id: 2, hoursAgo: 2)])
        coordinator.dismiss(message(id: 3, hoursAgo: 1))

        await load(coordinator, [message(id: 3, hoursAgo: 1), message(id: 2, hoursAgo: 2)])
        XCTAssertEqual(envelopes.load()?.messages.map(\.id), [3, 2])
        coordinator.cancel()
    }

    func testRestoringBringsTheRowBackWithoutASweep() async {
        let coordinator = makeCoordinator()
        await load(coordinator, [message(id: 3, hoursAgo: 1), message(id: 2, hoursAgo: 2)])
        let dismissed = message(id: 3, hoursAgo: 1)
        coordinator.dismiss(dismissed)
        let sweeps = source.requestedRanges.count

        coordinator.restore(dismissed)
        XCTAssertEqual(coordinator.messages.map(\.id), [3, 2])
        XCTAssertEqual(source.requestedRanges.count, sweeps, "restoring went back to the source")
        coordinator.cancel()
    }

    func testDismissingTwiceIsHarmless() async {
        let coordinator = makeCoordinator()
        await load(coordinator, [message(id: 3, hoursAgo: 1)])
        coordinator.dismiss(message(id: 3, hoursAgo: 1))
        coordinator.dismiss(message(id: 3, hoursAgo: 1))
        XCTAssertEqual(coordinator.dismissedCount, 1)
        XCTAssertTrue(coordinator.messages.isEmpty)
        coordinator.cancel()
    }
}
