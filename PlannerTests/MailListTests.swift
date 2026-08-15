import AppKit
import XCTest
@testable import Planner

@MainActor
final class MailListTests: PersistenceTestCase {
    private var defaults: UserDefaults!
    private var source: StubMailSource!
    private var coordinator: MailCoordinator!
    private var selection: SelectionModel!
    private var list: MailListViewController!
    private var reader: MailReaderViewController!

    /// 2026-08-07 06:53:20 in New York — a Friday morning.
    private let anchor = Date(timeIntervalSince1970: 1_786_100_000)

    private var listCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    override func setUp() {
        super.setUp()
        defaults = isolatedDefaults()
        source = StubMailSource()
        selection = SelectionModel(defaults: defaults)
        let anchor = anchor
        coordinator = MailCoordinator(
            source: source,
            calendar: listCalendar,
            now: { anchor },
            defaults: defaults
        )
        list = MailListViewController(
            persistence: persistence,
            model: model,
            selection: selection,
            mail: coordinator,
            calendar: listCalendar,
            now: { anchor }
        )
        reader = MailReaderViewController(
            persistence: persistence,
            model: model,
            selection: selection,
            mail: coordinator,
            calendar: listCalendar,
            now: { anchor }
        )
        list.loadViewIfNeeded()
        reader.loadViewIfNeeded()
    }

    override func tearDown() {
        coordinator?.cancel()
        source?.drain()
        list = nil
        reader = nil
        coordinator = nil
        selection = nil
        source = nil
        defaults = nil
        super.tearDown()
    }

    private func day(_ offset: Int) -> Date {
        listCalendar.date(byAdding: .day, value: offset, to: listCalendar.startOfDay(for: anchor))!
    }

    private func message(
        id: Int64,
        dayOffset: Int,
        hour: Int = 9,
        subject: String = "Subject",
        sender: String = "Ada Lovelace",
        isRead: Bool = false
    ) -> MailMessage {
        MailMessage(
            id: id,
            subject: subject,
            senderName: sender,
            senderAddress: "ada@example.com",
            receivedAt: listCalendar.date(byAdding: .hour, value: hour, to: day(dayOffset))!,
            isRead: isRead
        )
    }

    /// Waits for *this* sweep to reach the source before answering.
    ///
    /// Loading the list view starts a sweep of its own, so a request is
    /// already outstanding when a test begins; waiting on a non-empty queue
    /// would answer that one and leave this one hanging forever. Every pending
    /// sweep is then answered together — the coordinator's generation gate
    /// drops the superseded one, and the runtime traps on a continuation that
    /// is never resumed.
    private func load(_ messages: [MailMessage]) async {
        await sweep { self.coordinator.refresh() } answering: { messages }
        list.reload()
        reader.rebind()
    }

    private func sweep(
        _ trigger: @MainActor () -> Void,
        answering messages: @MainActor () -> [MailMessage]
    ) async {
        let before = source.requestedRanges.count
        trigger()
        await settle { self.source.requestedRanges.count > before }
        source.finishAll(with: messages())
        await settle { !self.coordinator.isLoading }
    }

    private func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Grouping

    func testMessagesAreGroupedByDayNewestFirst() async {
        await load([
            message(id: 1, dayOffset: 0, hour: 14),
            message(id: 2, dayOffset: 0, hour: 9),
            message(id: 3, dayOffset: -1, hour: 16),
            message(id: 4, dayOffset: -2, hour: 8),
        ])

        XCTAssertEqual(list.test_groupTitles, ["Today", "Yesterday", "Wednesday, August 5"])
        XCTAssertEqual(list.test_rows.map(\.message.id), [1, 2, 3, 4])
    }

    func testOneDayIsOneGroup() async {
        await load([
            message(id: 1, dayOffset: 0, hour: 14),
            message(id: 2, dayOffset: 0, hour: 9),
        ])
        XCTAssertEqual(list.test_groupTitles, ["Today"])
    }

    func testGroupRowsAreNotSelectable() async {
        await load([message(id: 1, dayOffset: 0)])
        let outline = list.outlineView
        XCTAssertFalse(list.outlineView(outline, shouldSelectItem: outline.item(atRow: 0)!))
        XCTAssertTrue(list.outlineView(outline, shouldSelectItem: outline.item(atRow: 1)!))
    }

    func testTheListIsNotThreaded() async {
        // Two messages in the same conversation stay two rows, in time order.
        await load([
            message(id: 1, dayOffset: 0, hour: 14, subject: "RE: Deposition prep"),
            message(id: 2, dayOffset: 0, hour: 9, subject: "Deposition prep"),
        ])
        XCTAssertEqual(list.test_rows.count, 2)
    }

    // MARK: - Selection

    func testSelectingARowPublishesTheMessage() async {
        await load([message(id: 7, dayOffset: 0)])
        let row = list.outlineView.row(forItem: list.test_rows[0])
        list.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        XCTAssertEqual(selection.message, .recent(7))
    }

    func testAModelSelectionRevealsTheRow() async {
        await load([message(id: 1, dayOffset: 0), message(id: 2, dayOffset: -1)])
        selection.selectMessage(.recent(2))
        let selected = list.outlineView.item(atRow: list.outlineView.selectedRow) as? MailListRow
        XCTAssertEqual(selected?.message.id, 2)
    }

    // MARK: - Empty states

    func testEmptyRecentMailNamesTheWindowLength() async {
        await load([])
        XCTAssertTrue(list.test_isEmptyStateVisible)
        XCTAssertEqual(list.test_emptyStateText, "No mail in the last 3 days.")
    }

    /// A null source is a different fact from an empty inbox, and only one of
    /// them is worth acting on.
    func testWithNoMailSourceTheEmptyStateExplainsWhatThePaneIsFor() {
        let coordinator = MailCoordinator(source: NullMailSource(), defaults: defaults)
        let list = MailListViewController(
            persistence: persistence,
            model: model,
            selection: selection,
            mail: coordinator,
            calendar: listCalendar,
            now: { self.anchor }
        )
        list.loadViewIfNeeded()
        XCTAssertEqual(list.test_emptyStateText, "Planner shows recent Outlook mail here.")
        coordinator.cancel()
    }

    func testASingleDayWindowSaysToday() async {
        await sweep { self.coordinator.setWindowDays(1) } answering: { [] }
        list.reload()
        XCTAssertEqual(list.test_emptyStateText, "No mail today.")
    }

    // MARK: - Saved messages

    func testAnAlreadySavedMessageCarriesItsFolderName() async throws {
        let folder = try model.createMailFolder(name: "Celerity")
        let envelope = message(id: 5, dayOffset: 0)
        // Saved with no headers, which is what Recent Mail can match on.
        try model.saveMessage(envelope, detail: nil, into: folder)

        await load([envelope])
        XCTAssertEqual(list.test_rows.first?.savedFolderName, "Celerity")
    }

    func testAnUnsavedMessageHasNoChip() async {
        await load([message(id: 5, dayOffset: 0)])
        XCTAssertNil(list.test_rows.first?.savedFolderName)
    }

    // MARK: - The reader

    func testTheReaderStartsEmpty() {
        XCTAssertTrue(reader.test_isEmptyStateVisible)
    }

    func testTheReaderShowsTheEnvelopeImmediately() async {
        await load([message(id: 3, dayOffset: 0, hour: 10, subject: "Deposition prep")])
        selection.selectMessage(.recent(3))

        XCTAssertFalse(reader.test_isEmptyStateVisible)
        XCTAssertEqual(reader.test_subject, "Deposition prep")
        XCTAssertEqual(reader.test_sender, "Ada Lovelace <ada@example.com>")
        XCTAssertFalse(reader.test_date.isEmpty)
        // The body is behind a per-message fetch, so it is not here yet.
        XCTAssertTrue(reader.test_body.isEmpty)
        XCTAssertTrue(reader.test_isBodyLoading)
    }

    func testTheBodyArrivesLater() async {
        await load([message(id: 3, dayOffset: 0)])
        selection.selectMessage(.recent(3))
        await settle { self.source.pendingDetailCount > 0 }
        source.finishDetail(.fixture(id: 3, body: "The body", recipients: "you@example.com"))
        await settle { !self.reader.test_body.isEmpty }

        XCTAssertEqual(reader.test_body, "The body")
        XCTAssertFalse(reader.test_isBodyLoading)
        XCTAssertEqual(reader.test_recipients, "To: you@example.com")
    }

    /// A body that lands after the user has moved on must not paint over the
    /// message now on screen.
    func testABodyForAnotherMessageIsIgnored() async {
        await load([message(id: 1, dayOffset: 0), message(id: 2, dayOffset: 0, hour: 8)])
        selection.selectMessage(.recent(1))
        await settle { self.source.pendingDetailCount > 0 }
        selection.selectMessage(.recent(2))

        source.finishDetail(.fixture(id: 1, body: "First body"))
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(reader.test_displayedMessageID, 2)
        XCTAssertNotEqual(reader.test_body, "First body")
    }

    func testAFailedBodyIsReportedInThePaneRatherThanAsAnAlert() async {
        await load([message(id: 3, dayOffset: 0)])
        selection.selectMessage(.recent(3))
        await settle { self.source.pendingDetailCount > 0 }
        source.finishDetail(id: 3, throwing: MailSourceError.messageUnavailable)
        await settle { self.reader.test_bodyStatus != nil }
        XCTAssertEqual(reader.test_bodyStatus, "That message is no longer in Outlook.")
        XCTAssertFalse(reader.test_isBodyLoading)
    }

    func testDeselectingReturnsToTheEmptyState() async {
        await load([message(id: 3, dayOffset: 0)])
        selection.selectMessage(.recent(3))
        XCTAssertFalse(reader.test_isEmptyStateVisible)
        selection.selectMessage(nil)
        XCTAssertTrue(reader.test_isEmptyStateVisible)
    }

    // MARK: - Expiry

    /// The oldest message in the window is about to age out, and the banner is
    /// how the user finds out before it does.
    func testTheOldestMessageWarnsThatItIsLeaving() async {
        await load([message(id: 1, dayOffset: -2, hour: 9)])
        selection.selectMessage(.recent(1))
        XCTAssertEqual(reader.test_expiryText, "Leaves Recent Mail tomorrow. Save it to keep it.")
    }

    /// On day one of a three-day window the banner would just be noise.
    func testATodayMessageSaysNothingAboutExpiry() async {
        await load([message(id: 1, dayOffset: 0, hour: 9)])
        selection.selectMessage(.recent(1))
        XCTAssertNil(reader.test_expiryText)
    }
}
