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
        address: String = "ada@example.com",
        isRead: Bool = false
    ) -> MailMessage {
        MailMessage(
            id: id,
            subject: subject,
            senderName: sender,
            senderAddress: address,
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

    /// A day header is a pinned label: no disclosure triangle (at zero
    /// indentation it draws over the title) and no way to collapse the day.
    func testGroupRowsShowNoDisclosureAndCannotCollapse() async {
        await load([message(id: 1, dayOffset: 0)])
        let outline = list.outlineView
        let group = outline.item(atRow: 0)!
        XCTAssertFalse(list.outlineView(outline, shouldShowOutlineCellForItem: group))
        XCTAssertFalse(list.outlineView(outline, shouldCollapseItem: group))
        let row = outline.item(atRow: 1)!
        XCTAssertTrue(list.outlineView(outline, shouldCollapseItem: row))
        XCTAssertEqual(list.test_indentationPerLevel, 0, "a day is not a conversation")
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

    /// Delete walks down the list, then up off the last row, then stops.
    func testTheNeighbourAfterARemovedRowIsTheNextThenThePrevious() async {
        await load([
            message(id: 1, dayOffset: 0, hour: 14),
            message(id: 2, dayOffset: 0, hour: 9),
            message(id: 3, dayOffset: -1),
        ])
        XCTAssertEqual(list.messageToSelectAfterRemoving(.recent(1)), .recent(2))
        XCTAssertEqual(list.messageToSelectAfterRemoving(.recent(2)), .recent(3))
        XCTAssertEqual(list.messageToSelectAfterRemoving(.recent(3)), .recent(2))
    }

    func testTheNeighbourAfterTheOnlyRowIsNothing() async {
        await load([message(id: 1, dayOffset: 0)])
        XCTAssertNil(list.messageToSelectAfterRemoving(.recent(1)))
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
        // Saved *with* headers, as a real save is: the row still has to match
        // it, which is why the match is on Outlook's record id.
        try model.saveMessage(envelope, detail: .fixture(id: 5, messageID: "<five@x>"), into: folder)

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

    /// Compression at or below the split holding priorities is what keeps a
    /// long subject from shoving the sidebar. The inspector title already
    /// sits at `.defaultLow`; the reader header must match.
    func testTheReaderHeaderDoesNotOutrankTheSplitHoldingPriorities() {
        XCTAssertEqual(reader.test_headerHorizontalCompressionResistance, 250)
        XCTAssertTrue(reader.test_subjectTruncatesLastVisibleLine)
        XCTAssertEqual(reader.test_recipientsLineBreakMode, .byTruncatingTail)
    }

    func testALongSubjectWrapsAgainstThePaneWidthNotItsUnwrappedLength() {
        reader.view.setFrameSize(NSSize(width: 400, height: 600))
        reader.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(reader.test_subjectPreferredMaxLayoutWidth, 360, accuracy: 0.5)
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

    func testHTMLBodyIsRenderedAsBasicRichText() async {
        await load([message(id: 3, dayOffset: 0)])
        selection.selectMessage(.recent(3))
        await settle { self.source.pendingDetailCount > 0 }
        source.finishDetail(.fixture(
            id: 3,
            body: "Hello there",
            html: #"<p>Hello <b>there</b>. <a href="https://example.com/path">site</a></p>"#
        ))
        await settle { self.reader.test_body.contains("Hello") }

        XCTAssertTrue(reader.test_body.contains("Hello"))
        XCTAssertTrue(reader.test_body.contains("there"))
        XCTAssertTrue(reader.test_bodyHasBold)
        XCTAssertEqual(reader.test_bodyLink, URL(string: "https://example.com/path"))
    }

    /// The header says *that* attachments exist, not what they are: Planner
    /// never opens one, so the names are dead weight in the reader.
    func testTheReaderCountsAttachmentsRatherThanNamingThem() async {
        await load([message(id: 3, dayOffset: 0)])
        selection.selectMessage(.recent(3))
        await settle { self.source.pendingDetailCount > 0 }
        source.finishDetail(.fixture(
            id: 3,
            hasAttachments: true,
            attachmentNames: "brief.pdf\nexhibit.png"
        ))
        await settle { self.reader.test_attachments != nil }

        XCTAssertEqual(reader.test_attachments, "📎 2 attachments")
    }

    /// A rights-protected message refuses its attachment list but still flags
    /// the header; the indicator must not vanish with the names.
    func testAnUnreadableAttachmentListStillShowsTheIndicator() async {
        await load([message(id: 3, dayOffset: 0)])
        selection.selectMessage(.recent(3))
        await settle { self.source.pendingDetailCount > 0 }
        source.finishDetail(.fixture(id: 3, hasAttachments: true, attachmentNames: nil))
        await settle { self.reader.test_attachments != nil }

        XCTAssertEqual(reader.test_attachments, "📎 Has attachments")
    }

    func testAMessageWithoutAttachmentsShowsNoIndicator() async {
        await load([message(id: 3, dayOffset: 0)])
        selection.selectMessage(.recent(3))
        await settle { self.source.pendingDetailCount > 0 }
        source.finishDetail(.fixture(id: 3))
        await settle { !self.reader.test_body.isEmpty }

        XCTAssertNil(reader.test_attachments)
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

    // MARK: - Folder search

    func testTheSearchFieldIsHiddenOnRecentMailAndShownInAFolder() throws {
        XCTAssertTrue(list.test_searchFieldIsHidden)
        XCTAssertEqual(list.test_searchFieldMaximumRecents, 0)

        let folder = try model.createMailFolder(name: "Celerity")
        selection.selectMailbox(.folder(folder.uuid))
        XCTAssertFalse(list.test_searchFieldIsHidden)

        selection.selectMailbox(.recent)
        XCTAssertTrue(list.test_searchFieldIsHidden)
    }

    func testSearchEmptyStatesDistinguishAMissFromAnEmptyFolder() throws {
        let folder = try model.createMailFolder(name: "Celerity")
        selection.selectMailbox(.folder(folder.uuid))
        list.reload()
        XCTAssertTrue(list.test_isEmptyStateVisible)
        XCTAssertEqual(list.test_emptyStateText, MailLabels.emptyFolder(name: "Celerity"))

        try model.saveMessage(
            message(id: 9, dayOffset: 0, subject: "Deposition prep"),
            detail: .fixture(id: 9, messageID: "<nine@x>"),
            into: folder
        )
        list.test_applySearch("no-such-token")
        XCTAssertTrue(list.test_isEmptyStateVisible)
        XCTAssertEqual(list.test_emptyStateText, MailLabels.emptySearch)

        list.test_applySearch("deposition")
        XCTAssertFalse(list.test_isEmptyStateVisible)
    }

    /// Reloads must not wipe the query; a save is the reload that happens
    /// while the user is still looking at these results.
    func testASaveKeepsTheAppliedSearchQuery() throws {
        let folder = try model.createMailFolder(name: "Celerity")
        try model.saveMessage(
            message(id: 1, dayOffset: 0, subject: "Ada report"),
            detail: .fixture(id: 1, messageID: "<one@x>"),
            into: folder
        )
        selection.selectMailbox(.folder(folder.uuid))
        list.reload()
        list.test_applySearch("ada")
        XCTAssertEqual(list.test_searchQuery, "ada")

        try model.saveMessage(
            message(id: 2, dayOffset: 0, subject: "Ada again"),
            detail: .fixture(id: 2, messageID: "<two@x>"),
            into: folder
        )
        XCTAssertEqual(list.test_searchQuery, "ada")
    }

    func testAQueryThatDropsTheOpenMessageClearsSelectionAndAHitKeepsIt() throws {
        let folder = try model.createMailFolder(name: "Celerity")
        let ada = try model.saveMessage(
            message(id: 1, dayOffset: 0, subject: "Ada report"),
            detail: .fixture(id: 1, messageID: "<one@x>"),
            into: folder
        )
        let grace = try model.saveMessage(
            message(
                id: 2,
                dayOffset: 0,
                subject: "Grace notes",
                sender: "Grace Hopper",
                address: "grace@example.com"
            ),
            detail: .fixture(id: 2, messageID: "<two@x>"),
            into: folder
        )
        selection.selectMailbox(.folder(folder.uuid))
        list.reload()

        selection.selectMessage(.saved(grace.uuid))
        list.test_applySearch("ada")
        XCTAssertNil(selection.message)

        selection.selectMessage(.saved(ada.uuid))
        list.test_applySearch("report")
        XCTAssertEqual(selection.message, .saved(ada.uuid))
    }
}
