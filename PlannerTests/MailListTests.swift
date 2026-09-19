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
            selection: selection,
            mail: coordinator,
            calendar: listCalendar,
            now: { anchor }
        )
        reader = MailReaderViewController(
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
        isRead: Bool = false,
        isHidden: Bool = false,
        categoryIDs: Set<Int64> = [],
        preview: String = ""
    ) -> MailMessage {
        MailMessage(
            id: id,
            subject: subject,
            senderName: sender,
            senderAddress: address,
            receivedAt: listCalendar.date(byAdding: .hour, value: hour, to: day(dayOffset))!,
            isRead: isRead,
            isHidden: isHidden,
            categoryIDs: categoryIDs,
            preview: preview
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

    func testARowShowsOneLineOfTheBody() async throws {
        await load([message(id: 1, dayOffset: 0, preview: "The deposition is moved to Friday.")])
        let row = try XCTUnwrap(list.test_rows.first)
        XCTAssertEqual(list.test_previewLine(for: row), "The deposition is moved to Friday.")
    }

    /// The line is dropped rather than shown blank, so an empty field never
    /// reads as a body that failed to load.
    func testARowWithNoBodyHidesThePreviewLine() async throws {
        await load([message(id: 1, dayOffset: 0)])
        let row = try XCTUnwrap(list.test_rows.first)
        XCTAssertNil(list.test_previewLine(for: row))
    }

    func testHiddenMessagesAreOmittedFromRecentMailByDefault() async {
        await load([
            message(id: 1, dayOffset: 0),
            message(id: 2, dayOffset: -1, isHidden: true),
        ])
        XCTAssertEqual(list.test_rows.map(\.message.id), [1])

        coordinator.setShowsHiddenMessages(true)
        list.reload()

        XCTAssertEqual(list.test_rows.map(\.message.id), [1, 2])
    }

    func testHidingHiddenMailAgainDropsAHiddenSelection() async {
        await load([
            message(id: 1, dayOffset: 0),
            message(id: 2, dayOffset: -1, isHidden: true),
        ])
        coordinator.setShowsHiddenMessages(true)
        list.reload()
        selection.selectMessage(.recent(2))

        coordinator.setShowsHiddenMessages(false)
        list.reload()

        XCTAssertEqual(list.test_rows.map(\.message.id), [1])
        XCTAssertTrue(selection.messages.isEmpty)
    }

    func testQuickSearchMailboxExecutesItsStoredQuery() async throws {
        await load([message(id: 1, dayOffset: 0)])
        let saved = try XCTUnwrap(coordinator.saveQuickSearch(name: "Work", query: "work"))

        selection.selectMailbox(.quickSearch(saved.id))
        await settle { self.source.pendingSearchCount == 1 }
        XCTAssertEqual(source.requestedSearchQueries, ["work"])
        source.finishSearch(with: [message(id: 2, dayOffset: -20)])
        await settle { self.list.test_rows.map(\.message.id) == [2] }
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
        XCTAssertEqual(list.messageToSelectAfterMoving(.recent(1)), .recent(2))
        XCTAssertEqual(list.messageToSelectAfterMoving(.recent(2)), .recent(3))
        XCTAssertEqual(list.messageToSelectAfterMoving(.recent(3)), .recent(2))
    }

    func testTheNeighbourAfterTheOnlyRowIsNothing() async {
        await load([message(id: 1, dayOffset: 0)])
        XCTAssertNil(list.messageToSelectAfterMoving(.recent(1)))
    }

    func testSelectingMultipleRowsPublishesEveryMessage() async {
        await load([
            message(id: 1, dayOffset: 0),
            message(id: 2, dayOffset: 0, hour: 8),
            message(id: 3, dayOffset: -1),
        ])
        let first = list.outlineView.row(forItem: list.test_rows[0])
        let second = list.outlineView.row(forItem: list.test_rows[1])
        list.outlineView.selectRowIndexes(IndexSet([first, second]), byExtendingSelection: false)
        XCTAssertEqual(Set(selection.messages), [.recent(1), .recent(2)])
        XCTAssertEqual(selection.message, .recent(2))
    }

    func testTheNeighbourAfterARemovedRangeIsTheNextRemaining() async {
        await load([
            message(id: 1, dayOffset: 0, hour: 14),
            message(id: 2, dayOffset: 0, hour: 9),
            message(id: 3, dayOffset: -1),
        ])
        XCTAssertEqual(
            list.messageToSelectAfterMoving([.recent(1), .recent(2)]),
            .recent(3)
        )
    }

    func testAModelSelectionRevealsEverySelectedRow() async {
        await load([
            message(id: 1, dayOffset: 0),
            message(id: 2, dayOffset: -1),
            message(id: 3, dayOffset: -2),
        ])
        selection.selectMessages([.recent(1), .recent(3)])
        let selected = list.outlineView.selectedRowIndexes.compactMap {
            (list.outlineView.item(atRow: $0) as? MailListRow)?.message.id
        }
        XCTAssertEqual(Set(selected), [1, 3])
    }

    // MARK: - Empty states

    func testEmptyRecentMailNamesTheWindowLength() async {
        await load([])
        XCTAssertTrue(list.test_isEmptyStateVisible)
        XCTAssertEqual(list.test_emptyStateText, "No mail in the last 3 days.")
    }

    func testEmptyRecentMailIsUnchangedWhenTheOnlyMessagesAreHidden() async {
        await load([message(id: 1, dayOffset: 0, isHidden: true)])
        XCTAssertTrue(list.test_isEmptyStateVisible)
        XCTAssertEqual(list.test_emptyStateText, "No mail in the last 3 days.")
    }

    func testEmptyQuickSearchReportsNoMatches() async throws {
        await load([message(id: 1, dayOffset: 0)])
        let saved = try XCTUnwrap(coordinator.saveQuickSearch(name: "Work", query: "work"))
        selection.selectMailbox(.quickSearch(saved.id))
        await settle { self.source.pendingSearchCount == 1 }
        source.finishSearch(with: [])
        await settle { self.coordinator.searchState == .loaded([]) }
        XCTAssertTrue(list.test_isEmptyStateVisible)
        XCTAssertEqual(list.test_emptyStateText, MailLabels.emptySearch)
    }

    /// A null source is a different fact from an empty inbox, and only one of
    /// them is worth acting on.
    func testWithNoMailSourceTheEmptyStateExplainsWhatThePaneIsFor() {
        let coordinator = MailCoordinator(source: NullMailSource(), defaults: defaults)
        let list = MailListViewController(
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

    /// The header lists filenames so a click can open the file.
    func testTheReaderNamesAttachments() async {
        await load([message(id: 3, dayOffset: 0)])
        selection.selectMessage(.recent(3))
        await settle { self.source.pendingDetailCount > 0 }
        source.finishDetail(.fixture(
            id: 3,
            hasAttachments: true,
            attachmentNames: "brief.pdf\nexhibit.png"
        ))
        await settle { !self.reader.test_attachments.isEmpty }

        XCTAssertEqual(reader.test_attachments, ["brief.pdf", "exhibit.png"])
        XCTAssertEqual(reader.test_attachmentEnabled, [true, true])
    }

    /// A rights-protected message refuses its attachment list but still flags
    /// the header; the indicator must not vanish with the names.
    func testAnUnreadableAttachmentListStillShowsTheIndicator() async {
        await load([message(id: 3, dayOffset: 0)])
        selection.selectMessage(.recent(3))
        await settle { self.source.pendingDetailCount > 0 }
        source.finishDetail(.fixture(id: 3, hasAttachments: true, attachmentNames: nil))
        await settle { !self.reader.test_attachments.isEmpty }

        XCTAssertEqual(reader.test_attachments, ["📎 Has attachments"])
    }

    func testAMessageWithoutAttachmentsShowsNoIndicator() async {
        await load([message(id: 3, dayOffset: 0)])
        selection.selectMessage(.recent(3))
        await settle { self.source.pendingDetailCount > 0 }
        source.finishDetail(.fixture(id: 3))
        await settle { !self.reader.test_body.isEmpty }

        XCTAssertEqual(reader.test_attachments, [])
    }

    func testClickingAnAttachmentOpensItInTheDefaultViewer() async {
        var opened: [URL] = []
        reader.openURL = { url in
            opened.append(url)
            return true
        }
        let payload = Data("pdf-bytes".utf8)
        source.setAttachmentData(payload, sha256: "sha-brief.pdf")

        await load([message(id: 3, dayOffset: 0)])
        selection.selectMessage(.recent(3))
        await settle { self.source.pendingDetailCount > 0 }
        source.finishDetail(.fixture(
            id: 3,
            hasAttachments: true,
            attachmentNames: "brief.pdf"
        ))
        await settle { self.reader.test_attachments == ["brief.pdf"] }

        reader.test_openAttachment(named: "brief.pdf")
        await settle { !opened.isEmpty }

        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened[0].lastPathComponent.hasSuffix("brief.pdf"), true)
        XCTAssertEqual(try? Data(contentsOf: opened[0]), payload)
    }

    func testAnUnstoredAttachmentCannotBeOpened() async {
        var opened: [URL] = []
        reader.openURL = { url in
            opened.append(url)
            return true
        }
        await load([message(id: 3, dayOffset: 0)])
        selection.selectMessage(.recent(3))
        await settle { self.source.pendingDetailCount > 0 }
        source.finishDetail(.fixture(
            id: 3,
            attachments: [
                MailAttachment(
                    id: 9,
                    filename: "huge.zip",
                    sha256: "abc",
                    stored: false
                )
            ]
        ))
        await settle { self.reader.test_attachments == ["huge.zip"] }

        XCTAssertEqual(reader.test_attachmentEnabled, [false])
        reader.test_openAttachment(named: "huge.zip")
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(opened.isEmpty)
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
        XCTAssertEqual(reader.test_expiryText, "Leaves Recent Mail tomorrow.")
    }

    /// On day one of a three-day window the banner would just be noise.
    func testATodayMessageSaysNothingAboutExpiry() async {
        await load([message(id: 1, dayOffset: 0, hour: 9)])
        selection.selectMessage(.recent(1))
        XCTAssertNil(reader.test_expiryText)
    }

    func testHiddenMessageStillShowsRecentMailExpiryBannerWhenShown() async {
        await load([message(id: 1, dayOffset: -2, hour: 9, isHidden: true)])
        coordinator.setShowsHiddenMessages(true)
        list.reload()
        selection.selectMessage(.recent(1))
        XCTAssertEqual(reader.test_expiryText, "Leaves Recent Mail tomorrow.")
    }

    // MARK: - Search

    func testTheSearchFieldIsShownOnlyForSearchMailbox() {
        XCTAssertTrue(list.test_searchFieldIsHidden)
        selection.selectMailbox(.search)
        XCTAssertFalse(list.test_searchFieldIsHidden)
        XCTAssertEqual(list.test_searchFieldMaximumRecents, 0)
    }

    func testSearchMailboxStartsEmptyEvenWhenRecentMailIsLoaded() async {
        await load([message(id: 1, dayOffset: 0)])
        selection.selectMailbox(.search)

        XCTAssertTrue(list.test_rows.isEmpty)
        XCTAssertEqual(list.test_emptyStateText, MailLabels.emptySearchPrompt)
        XCTAssertEqual(source.pendingSearchCount, 0)
    }

    func testSearchExecutesOnlyWhenSubmittedAndGroupsWholeIndexHits() async {
        await load([
            message(id: 1, dayOffset: 0, subject: "Other"),
        ])
        selection.selectMailbox(.search)
        list.test_searchField.stringValue = "body:deposition"
        XCTAssertEqual(source.pendingSearchCount, 0)

        list.test_applySearch("body:deposition")
        await settle { self.source.pendingSearchCount == 1 }
        XCTAssertEqual(source.requestedSearchQueries, ["body:deposition"])
        XCTAssertTrue(list.test_isEmptyStateVisible)
        XCTAssertEqual(list.test_emptyStateText, MailLabels.searching)

        source.finishSearch(with: [message(id: 2, dayOffset: -30, subject: "Deposition")])
        await settle { self.list.test_rows.map(\.message.id) == [2] }

        XCTAssertEqual(list.test_groupTitles, ["Wednesday, July 8"])
        XCTAssertFalse(list.test_isEmptyStateVisible)
    }

    func testCompletedSearchCanBeSavedWithAName() async throws {
        await load([])
        selection.selectMailbox(.search)
        list.test_applySearch("from:ada")
        await settle { self.source.pendingSearchCount == 1 }
        source.finishSearch(with: [])
        await settle { self.list.test_saveSearchIsEnabled }

        list.test_saveSearch(name: "Ada")

        let saved = try XCTUnwrap(coordinator.quickSearches.first)
        XCTAssertEqual(saved.name, "Ada")
        XCTAssertEqual(saved.query, "from:ada")
        XCTAssertEqual(selection.mailbox, .quickSearch(saved.id))
    }

    func testSearchMissAndFailureHaveDifferentEmptyStates() async {
        await load([message(id: 1, dayOffset: 0)])
        selection.selectMailbox(.search)

        list.test_applySearch("no-such-token")
        await settle { self.source.pendingSearchCount == 1 }
        source.finishSearch(with: [])
        await settle { self.list.test_emptyStateText == MailLabels.emptySearch }

        list.test_applySearch("bad:")
        await settle { self.source.pendingSearchCount == 1 }
        source.finishSearch(throwing: OlSyncMailError.querySyntax("bad query"))
        await settle { self.list.test_emptyStateText == MailLabels.searchFailed }
    }

    func testSearchClearsASelectionThatIsNotAHit() async {
        await load([message(id: 1, dayOffset: 0), message(id: 2, dayOffset: 0, hour: 8)])
        selection.selectMailbox(.search)
        selection.selectMessage(.recent(1))

        list.test_applySearch("second")
        await settle { self.source.pendingSearchCount == 1 }
        source.finishSearch(with: [message(id: 2, dayOffset: 0, hour: 8)])
        await settle { self.selection.message == nil }

        XCTAssertEqual(list.test_rows.map(\.message.id), [2])
    }

    func testClearingSearchReturnsSearchMailboxToItsEmptyPrompt() async {
        await load([
            message(id: 1, dayOffset: 0),
            message(id: 2, dayOffset: -1),
        ])
        selection.selectMailbox(.search)
        list.test_applySearch("first")
        await settle { self.source.pendingSearchCount == 1 }
        source.finishSearch(with: [message(id: 1, dayOffset: 0)])
        await settle { self.list.test_rows.count == 1 }

        list.test_applySearch("")
        XCTAssertTrue(list.test_rows.isEmpty)
        XCTAssertEqual(list.test_emptyStateText, MailLabels.emptySearchPrompt)
        XCTAssertEqual(coordinator.searchState, .idle)
    }

}
