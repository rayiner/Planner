import AppKit
import XCTest
@testable import Planner

@MainActor
final class MailSummaryTests: PersistenceTestCase {
    private var source: StubMailSource!
    private var llm: StubOnDeviceLanguageModel!
    private var defaults: UserDefaults!
    private var coordinator: MailCoordinator!

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    /// 2026-08-07 06:53:20 in New York.
    private let anchor = Date(timeIntervalSince1970: 1_786_100_000)

    override func setUp() {
        super.setUp()
        source = StubMailSource()
        llm = StubOnDeviceLanguageModel()
        defaults = isolatedDefaults()
    }

    override func tearDown() {
        coordinator?.cancel()
        source?.drain()
        llm?.drain()
        coordinator = nil
        llm = nil
        source = nil
        defaults = nil
        super.tearDown()
    }

    private func makeCoordinator(
        model: OnDeviceLanguageModel? = nil,
        store: MailSummaryStore = .disabled
    ) -> MailCoordinator {
        let anchor = anchor
        return MailCoordinator(
            source: source,
            calendar: calendar,
            now: { anchor },
            defaults: defaults,
            summaryModel: model ?? llm,
            summaryStore: store
        )
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

    /// Answers the sweep and waits for the window to land.
    private func load(_ messages: [MailMessage]) async {
        coordinator.refresh()
        await waitUntil("sweep") { self.source.pendingCount >= 1 }
        source.finishAll(with: messages)
        await waitUntil("window") { !self.coordinator.isLoading }
    }

    // MARK: - Prompt

    func testRequestCarriesEnvelopeAndBody() {
        let request = MailSummaryPrompt.request(
            for: .fixture(subject: "Budget review", senderName: "Grace Hopper"),
            body: "Please send the Q3 numbers by Friday."
        )
        XCTAssertEqual(request.instructions, MailSummaryPrompt.instructions)
        XCTAssertTrue(request.prompt.contains("Subject: Budget review"))
        // The row already names the sender; the prompt does not hand the model
        // a name to repeat, and the instructions carry no worked example for
        // it to parrot.
        XCTAssertFalse(request.prompt.contains("Grace"))
        XCTAssertFalse(request.instructions.contains("Grace"))
        XCTAssertTrue(request.prompt.contains("Q3 numbers by Friday"))
        XCTAssertEqual(request.maximumResponseTokens, MailSummaryPrompt.maximumResponseTokens)
    }

    func testEmptyBodyIsNamedRatherThanBlank() {
        let request = MailSummaryPrompt.request(for: .fixture(subject: ""), body: "   \n ")
        XCTAssertTrue(request.prompt.contains("Subject: (No subject)"))
        XCTAssertTrue(request.prompt.contains("no body text"))
    }

    func testQuotedRepliesAreDropped() {
        let body = """
            Thanks, that works for me. Let's meet at ten and go over the draft together \
            before it goes to the wider group.

            -----Original Message-----
            From: Someone Else
            Sent: Monday
            Here is the thing I sent you before, at great length.
            """
        let trimmed = MailSummaryPrompt.truncated(body)
        XCTAssertTrue(trimmed.contains("meet at ten"))
        XCTAssertFalse(trimmed.contains("great length"))
    }

    func testOutlookStyleReplyHeaderIsDropped() {
        let intro = String(repeating: "Here is the actual reply. ", count: 5)
        let body = intro + "\n\nFrom: Ada Lovelace\nSent: Monday, 3 August 2026\nTo: you\nSubject: RE: thing\n\nOld text."
        let trimmed = MailSummaryPrompt.truncated(body)
        XCTAssertTrue(trimmed.contains("actual reply"))
        XCTAssertFalse(trimmed.contains("Old text"))
    }

    func testForwardThatStartsWithHeadersIsKept() {
        let body = "From: Ada Lovelace\nSent: Monday\nSubject: FW: agenda\n\nThe agenda is attached."
        XCTAssertTrue(MailSummaryPrompt.truncated(body).contains("agenda is attached"))
    }

    func testLongBodyIsCutOnAWordBoundaryWithEllipsis() {
        let body = String(repeating: "word ", count: 2_000)
        let trimmed = MailSummaryPrompt.truncated(body, limit: 100)
        XCTAssertTrue(trimmed.hasSuffix("…"))
        XCTAssertLessThanOrEqual(trimmed.count, 101)
        XCTAssertFalse(trimmed.contains("wor…"))
    }

    func testBlankLineRunsCollapse() {
        let trimmed = MailSummaryPrompt.truncated("one\n\n\n\n\ntwo   \n   \nthree")
        XCTAssertEqual(trimmed, "one\n\ntwo\n\nthree")
    }

    func testHTMLFallbackWhenPlainBodyIsEmpty() {
        let detail = MailMessageDetail.fixture(
            body: "",
            html: "<html><head><style>p{}</style></head><body><p>Hello &amp; welcome</p><br><script>x()</script><div>Bye</div></body></html>"
        )
        XCTAssertEqual(MailSummaryPrompt.plainBody(from: detail), "Hello & welcome\n\nBye")
    }

    func testPlainBodyPreferredOverHTML() {
        let detail = MailMessageDetail.fixture(body: "Plain", html: "<p>Rich</p>")
        XCTAssertEqual(MailSummaryPrompt.plainBody(from: detail), "Plain")
    }

    func testCleanedReplyIsOneTidyLine() {
        XCTAssertEqual(MailSummaryPrompt.cleaned("  \"Asks for the Q3 numbers by Friday.\"  \n\nMore."), "Asks for the Q3 numbers by Friday.")
        XCTAssertEqual(MailSummaryPrompt.cleaned("Summary: Newsletter   about  Swift."), "Newsletter about Swift.")
        XCTAssertEqual(MailSummaryPrompt.cleaned("- Bullet reply"), "Bullet reply")
        XCTAssertNil(MailSummaryPrompt.cleaned("  \n \n"))
    }

    func testAnnouncementOpeningsAreDropped() {
        XCTAssertEqual(MailSummaryPrompt.cleaned("I’m asking you to review the patent details and confirm they are correct."), "Review the patent details and confirm they are correct.")
        XCTAssertEqual(MailSummaryPrompt.cleaned("I'm asking that you call me about Appx20389."), "Call me about Appx20389.")
        XCTAssertEqual(MailSummaryPrompt.cleaned("I’m sharing that Swift 6.4 is released."), "Swift 6.4 is released.")
        XCTAssertEqual(MailSummaryPrompt.cleaned("I wanted to let you know that the office is closed Monday."), "The office is closed Monday.")
        XCTAssertEqual(MailSummaryPrompt.cleaned("I’m writing to ask you to send the numbers."), "Send the numbers.")
        // Questions and plain first-person statements are left alone.
        XCTAssertEqual(MailSummaryPrompt.cleaned("I’m asking if the FWD mentions the SPD."), "I’m asking if the FWD mentions the SPD.")
        XCTAssertEqual(MailSummaryPrompt.cleaned("I need the Q3 numbers by Friday."), "I need the Q3 numbers by Friday.")
        XCTAssertEqual(MailSummaryPrompt.cleaned("I’m asking you to"), "I’m asking you to")
    }

    func testToolCallShapedRepliesAreRejected() {
        XCTAssertNil(MailSummaryPrompt.cleaned(#"tool: extract_text("May it please the Court")"#))
        XCTAssertNil(MailSummaryPrompt.cleaned(#"extract_text_from_email("I would like to focus")"#))
        XCTAssertNil(MailSummaryPrompt.cleaned(#"  Function: summarize(text: "x")"#))
        XCTAssertNil(MailSummaryPrompt.cleaned(#"call summarize(text="x")"#))
        // Parentheses inside prose are not a tool call.
        XCTAssertEqual(MailSummaryPrompt.cleaned("Please review the brief (attached) before Friday."), "Please review the brief (attached) before Friday.")
        XCTAssertEqual(MailSummaryPrompt.cleaned("Check in now for flight DL 1234 (SFO)."), "Check in now for flight DL 1234 (SFO).")
    }

    func testCleanedReplyIsCapped() {
        let long = String(repeating: "x", count: 500)
        let cleaned = MailSummaryPrompt.cleaned(long)!
        XCTAssertEqual(cleaned.count, MailSummaryPrompt.maximumSummaryLength)
        XCTAssertTrue(cleaned.hasSuffix("…"))
    }

    // MARK: - Store

    func testStoreRoundTrips() {
        let store = MailSummaryStore.temporary()
        let record = MailSummaryRecord(
            sourceID: "stub",
            entries: [MailSummaryEntry(id: 7, receivedAt: anchor, summary: "Hello")]
        )
        store.save(record)
        XCTAssertEqual(store.load(), record)
    }

    func testDisabledStoreLoadsNothing() {
        XCTAssertNil(MailSummaryStore.disabled.load())
    }

    // MARK: - Coordinator: availability

    func testUnavailableModelNeverFetchesBodies() async {
        llm.availability = .appleIntelligenceNotEnabled
        coordinator = makeCoordinator()
        await load([message(id: 1, hoursAgo: 1), message(id: 2, hoursAgo: 2)])

        XCTAssertFalse(coordinator.summaries.isAvailable)
        XCTAssertEqual(coordinator.summaries.availability, .appleIntelligenceNotEnabled)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(source.requestedDetailIDs, [])
        XCTAssertEqual(coordinator.summaries.state(for: 1), .idle)
        XCTAssertTrue(coordinator.summaries.test_queuedIDs.isEmpty)
    }

    func testDefaultCoordinatorHasNoModel() async {
        coordinator = MailCoordinator(source: source, calendar: calendar, now: { self.anchor }, defaults: defaults)
        await load([message(id: 1, hoursAgo: 1)])
        XCTAssertFalse(coordinator.summaries.isAvailable)
        XCTAssertEqual(source.requestedDetailIDs, [])
    }

    // MARK: - Coordinator: the queue

    func testSummarizesNewestFirstOneAtATime() async {
        coordinator = makeCoordinator()
        await load([
            message(id: 1, hoursAgo: 3, subject: "Oldest"),
            message(id: 2, hoursAgo: 1, subject: "Newest"),
            message(id: 3, hoursAgo: 2, subject: "Middle"),
        ])

        await waitUntil("first body") { self.source.pendingDetailCount >= 1 }
        XCTAssertEqual(source.requestedDetailIDs, [2])
        XCTAssertEqual(coordinator.summaries.state(for: 2), .loading)
        XCTAssertEqual(coordinator.summaries.state(for: 3), .queued)
        XCTAssertEqual(coordinator.summaries.state(for: 1), .queued)
        XCTAssertEqual(coordinator.summaries.test_queuedIDs, [3, 1])

        source.finishDetail(.fixture(id: 2, body: "Lunch tomorrow?"))
        await waitUntil("model asked") { self.llm.pendingCount >= 1 }
        XCTAssertTrue(llm.requests[0].prompt.contains("Subject: Newest"))
        XCTAssertTrue(llm.requests[0].prompt.contains("Lunch tomorrow?"))
        // Still one at a time: no second body while the model is thinking.
        XCTAssertEqual(source.requestedDetailIDs, [2])

        llm.finish(with: "Asks whether you are free for lunch tomorrow.")
        await waitUntil("summary landed") { self.coordinator.summaries.summary(for: 2) != nil }
        XCTAssertEqual(coordinator.summaries.summary(for: 2), "Asks whether you are free for lunch tomorrow.")

        await waitUntil("second body") { self.source.pendingDetailCount >= 1 }
        XCTAssertEqual(source.requestedDetailIDs, [2, 3])
    }

    func testSummaryPostsAPerMessageNotification() async {
        coordinator = makeCoordinator()
        var seen: [Int64] = []
        let token = NotificationCenter.default.addObserver(
            forName: .plannerMailSummaryDidChange,
            object: coordinator.summaries,
            queue: .main
        ) { notification in
            let id = notification.userInfo?[MailChangeUserInfoKey.messageID] as? Int64
            MainActor.assumeIsolated { if let id { seen.append(id) } }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        await load([message(id: 9, hoursAgo: 1)])
        await waitUntil("body") { self.source.pendingDetailCount >= 1 }
        source.finishDetail(.fixture(id: 9))
        await waitUntil("model") { self.llm.pendingCount >= 1 }
        llm.finish(with: "Done.")
        await waitUntil("loaded") { self.coordinator.summaries.summary(for: 9) != nil }
        // Queued, loading, loaded — the id every time, never anything else.
        XCTAssertEqual(Set(seen), [9])
        XCTAssertGreaterThanOrEqual(seen.count, 3)
    }

    func testPrioritizedRowJumpsTheQueue() async {
        coordinator = makeCoordinator()
        await load([
            message(id: 1, hoursAgo: 1),
            message(id: 2, hoursAgo: 2),
            message(id: 3, hoursAgo: 3),
            message(id: 4, hoursAgo: 4),
        ])
        await waitUntil("first body") { self.source.pendingDetailCount >= 1 }
        XCTAssertEqual(source.requestedDetailIDs, [1])

        // The user scrolled to the bottom: row 4 is on screen.
        coordinator.summaries.prioritize(4)

        source.finishDetail(.fixture(id: 1))
        await waitUntil("model") { self.llm.pendingCount >= 1 }
        llm.finish(with: "One.")
        await waitUntil("next body") { self.source.requestedDetailIDs.count >= 2 }
        XCTAssertEqual(source.requestedDetailIDs, [1, 4])
    }

    func testPrioritizingAnUnqueuedMessageIsHarmless() async {
        coordinator = makeCoordinator()
        await load([message(id: 1, hoursAgo: 1)])
        coordinator.summaries.prioritize(42)
        XCTAssertEqual(coordinator.summaries.state(for: 42), .idle)
    }

    func testDismissedMessageLeavesTheQueue() async {
        coordinator = makeCoordinator()
        let old = message(id: 2, hoursAgo: 2)
        await load([message(id: 1, hoursAgo: 1), old, message(id: 3, hoursAgo: 3)])
        await waitUntil("first body") { self.source.pendingDetailCount >= 1 }
        XCTAssertEqual(coordinator.summaries.test_queuedIDs, [2, 3])

        coordinator.dismiss(old)
        XCTAssertEqual(coordinator.summaries.test_queuedIDs, [3])
        XCTAssertEqual(coordinator.summaries.state(for: 2), .idle)

        coordinator.restore(old)
        XCTAssertEqual(coordinator.summaries.test_queuedIDs, [2, 3])
    }

    func testNewMailGoesAheadOfTheBacklog() async {
        coordinator = makeCoordinator()
        await load([message(id: 1, hoursAgo: 5), message(id: 2, hoursAgo: 6)])
        await waitUntil("first body") { self.source.pendingDetailCount >= 1 }
        XCTAssertEqual(coordinator.summaries.test_queuedIDs, [2])

        await load([message(id: 3, hoursAgo: 1), message(id: 1, hoursAgo: 5), message(id: 2, hoursAgo: 6)])
        XCTAssertEqual(coordinator.summaries.test_queuedIDs, [3, 2])
    }

    // MARK: - Coordinator: failure

    func testRefusalIsRecordedAndNotRetried() async {
        coordinator = makeCoordinator()
        await load([message(id: 1, hoursAgo: 1)])
        await waitUntil("body") { self.source.pendingDetailCount >= 1 }
        source.finishDetail(.fixture(id: 1))
        await waitUntil("model") { self.llm.pendingCount >= 1 }
        llm.finish(throwing: OnDeviceModelError.refused)
        await waitUntil("failed") {
            if case .failed = self.coordinator.summaries.state(for: 1) { return true }
            return false
        }
        XCTAssertNil(coordinator.summaries.summary(for: 1))

        // Another sweep of the same window does not ask again.
        await load([message(id: 1, hoursAgo: 1)])
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(llm.requests.count, 1)
        XCTAssertTrue(coordinator.summaries.test_queuedIDs.isEmpty)
    }

    func testRateLimitIsRetriedOnTheNextSweep() async {
        coordinator = makeCoordinator()
        await load([message(id: 1, hoursAgo: 1)])
        await waitUntil("body") { self.source.pendingDetailCount >= 1 }
        source.finishDetail(.fixture(id: 1))
        await waitUntil("model") { self.llm.pendingCount >= 1 }
        llm.finish(throwing: OnDeviceModelError.rateLimited)
        await waitUntil("failed") {
            if case .failed = self.coordinator.summaries.state(for: 1) { return true }
            return false
        }

        await load([message(id: 1, hoursAgo: 1)])
        await waitUntil("asked again") { self.llm.pendingCount >= 1 }
        XCTAssertEqual(llm.requests.count, 2)
    }

    func testBodyFailureFailsTheSummary() async {
        coordinator = makeCoordinator()
        await load([message(id: 1, hoursAgo: 1)])
        await waitUntil("body") { self.source.pendingDetailCount >= 1 }
        source.finishDetail(id: 1, throwing: MailSourceError.messageUnavailable)
        await waitUntil("failed") {
            if case .failed = self.coordinator.summaries.state(for: 1) { return true }
            return false
        }
        XCTAssertEqual(llm.requests.count, 0)
    }

    func testTooLongPromptIsRetriedShorter() async {
        coordinator = makeCoordinator()
        await load([message(id: 1, hoursAgo: 1)])
        await waitUntil("body") { self.source.pendingDetailCount >= 1 }
        source.finishDetail(.fixture(id: 1, body: String(repeating: "long ", count: 1_000)))
        await waitUntil("model") { self.llm.pendingCount >= 1 }
        let firstLength = llm.requests[0].prompt.count
        llm.finish(throwing: OnDeviceModelError.promptTooLong)
        await waitUntil("retry") { self.llm.requests.count >= 2 }
        XCTAssertLessThan(llm.requests[1].prompt.count, firstLength)
        llm.finish(with: "A long message.")
        await waitUntil("loaded") { self.coordinator.summaries.summary(for: 1) != nil }
    }

    func testEmptyReplyIsAFailure() async {
        coordinator = makeCoordinator()
        await load([message(id: 1, hoursAgo: 1)])
        await waitUntil("body") { self.source.pendingDetailCount >= 1 }
        source.finishDetail(.fixture(id: 1))
        await waitUntil("model") { self.llm.pendingCount >= 1 }
        llm.finish(with: "  \n")
        await waitUntil("failed") {
            if case .failed = self.coordinator.summaries.state(for: 1) { return true }
            return false
        }
        // A short body has nothing to trim, so there is no second ask.
        XCTAssertEqual(llm.requests.count, 1)
    }

    func testToolCallReplyOnALongBodyIsRetriedShorterThenFails() async {
        coordinator = makeCoordinator()
        await load([message(id: 1, hoursAgo: 1)])
        await waitUntil("body") { self.source.pendingDetailCount >= 1 }
        source.finishDetail(.fixture(id: 1, body: String(repeating: "brief ", count: 1_000)))
        await waitUntil("model") { self.llm.pendingCount >= 1 }
        llm.finish(with: #"tool: extract_text("May it please the Court")"#)
        await waitUntil("retry") { self.llm.requests.count >= 2 }
        XCTAssertLessThan(llm.requests[1].prompt.count, llm.requests[0].prompt.count)
        llm.finish(with: #"tool: extract_text("May it please the Court")"#)
        await waitUntil("failed") {
            if case .failed = self.coordinator.summaries.state(for: 1) { return true }
            return false
        }
        XCTAssertEqual(coordinator.summaries.state(for: 1), .failed(MailSummaryCoordinator.unusableReplyReason))
        XCTAssertEqual(llm.requests.count, 2)
    }

    // MARK: - Coordinator: persistence

    func testSummariesSurviveRelaunch() async {
        let store = MailSummaryStore.temporary()
        coordinator = makeCoordinator(store: store)
        await load([message(id: 1, hoursAgo: 1)])
        await waitUntil("body") { self.source.pendingDetailCount >= 1 }
        source.finishDetail(.fixture(id: 1))
        await waitUntil("model") { self.llm.pendingCount >= 1 }
        llm.finish(with: "Remembered.")
        await waitUntil("loaded") { self.coordinator.summaries.summary(for: 1) != nil }
        coordinator.cancel()

        let relaunched = makeCoordinator(store: store)
        XCTAssertEqual(relaunched.summaries.summary(for: 1), "Remembered.")
        relaunched.refresh()
        await waitUntil("sweep") { self.source.pendingCount >= 1 }
        source.finishAll(with: [message(id: 1, hoursAgo: 1)])
        await waitUntil("window") { !relaunched.isLoading }
        try? await Task.sleep(for: .milliseconds(30))
        // Not asked again.
        XCTAssertEqual(llm.requests.count, 1)
        relaunched.cancel()
    }

    func testStoreForAnotherSourceIsIgnored() {
        let store = MailSummaryStore.temporary()
        store.save(MailSummaryRecord(
            sourceID: "someone-else",
            entries: [MailSummaryEntry(id: 1, receivedAt: anchor, summary: "Foreign")]
        ))
        coordinator = makeCoordinator(store: store)
        XCTAssertNil(coordinator.summaries.summary(for: 1))
    }

    func testCancelReturnsInFlightWorkToTheQueue() async {
        coordinator = makeCoordinator()
        await load([message(id: 1, hoursAgo: 1), message(id: 2, hoursAgo: 2)])
        await waitUntil("body") { self.source.pendingDetailCount >= 1 }
        XCTAssertEqual(coordinator.summaries.test_inFlightIDs, [1])
        coordinator.summaries.cancel()
        XCTAssertTrue(coordinator.summaries.test_inFlightIDs.isEmpty)
        XCTAssertEqual(coordinator.summaries.test_queuedIDs, [1, 2])
        XCTAssertEqual(coordinator.summaries.state(for: 1), .queued)
    }

    // MARK: - The list

    func testRowsReserveASummaryLineOnlyWhenTheModelIsAvailable() async {
        coordinator = makeCoordinator()
        let selection = SelectionModel(defaults: defaults)
        let anchor = anchor
        let list = MailListViewController(
            persistence: persistence,
            model: model,
            selection: selection,
            mail: coordinator,
            calendar: calendar,
            now: { anchor }
        )
        list.loadViewIfNeeded()
        await waitUntil("sweep") { self.source.pendingCount >= 1 }
        source.finishAll(with: [message(id: 1, hoursAgo: 1, subject: "Lunch")])
        await waitUntil("window") { !self.coordinator.isLoading }
        list.reload()

        let row = list.test_rows[0]
        XCTAssertEqual(list.test_rowHeight(for: row), 54 + MailListViewController.summaryLineHeight)
        XCTAssertEqual(list.test_summaryLine(for: row), MailLabels.summarizing)

        await waitUntil("body") { self.source.pendingDetailCount >= 1 }
        source.finishDetail(.fixture(id: 1, body: "Free at noon?"))
        await waitUntil("model") { self.llm.pendingCount >= 1 }
        llm.finish(with: "Asks if you are free for lunch at noon.")
        await waitUntil("row updated") { list.test_summaryLine(for: row) != MailLabels.summarizing }
        XCTAssertEqual(list.test_summaryLine(for: row), "Asks if you are free for lunch at noon.")
        // Same row object, same height: the line was reserved from the start.
        XCTAssertEqual(list.test_rowHeight(for: row), 54 + MailListViewController.summaryLineHeight)
    }

    func testRowsKeepTwoLinesWithoutAModel() async {
        llm.availability = .deviceNotEligible
        coordinator = makeCoordinator()
        let selection = SelectionModel(defaults: defaults)
        let anchor = anchor
        let list = MailListViewController(
            persistence: persistence,
            model: model,
            selection: selection,
            mail: coordinator,
            calendar: calendar,
            now: { anchor }
        )
        list.loadViewIfNeeded()
        await waitUntil("sweep") { self.source.pendingCount >= 1 }
        source.finishAll(with: [message(id: 1, hoursAgo: 1)])
        await waitUntil("window") { !self.coordinator.isLoading }
        list.reload()

        let row = list.test_rows[0]
        XCTAssertEqual(list.test_rowHeight(for: row), 54)
        XCTAssertNil(list.test_summaryLine(for: row))
    }

    func testFailedSummaryLeavesTheLineBlank() async {
        coordinator = makeCoordinator()
        let selection = SelectionModel(defaults: defaults)
        let anchor = anchor
        let list = MailListViewController(
            persistence: persistence,
            model: model,
            selection: selection,
            mail: coordinator,
            calendar: calendar,
            now: { anchor }
        )
        list.loadViewIfNeeded()
        await waitUntil("sweep") { self.source.pendingCount >= 1 }
        source.finishAll(with: [message(id: 1, hoursAgo: 1)])
        await waitUntil("window") { !self.coordinator.isLoading }
        list.reload()
        let row = list.test_rows[0]

        await waitUntil("body") { self.source.pendingDetailCount >= 1 }
        source.finishDetail(.fixture(id: 1))
        await waitUntil("model") { self.llm.pendingCount >= 1 }
        llm.finish(throwing: OnDeviceModelError.refused)
        await waitUntil("row updated") { list.test_summaryLine(for: row) != MailLabels.summarizing }
        XCTAssertEqual(list.test_summaryLine(for: row), "")
    }

    func testAccessibilityLabelIncludesTheSummary() {
        let label = MailLabels.messageAccessibilityLabel(
            sender: "Ada",
            subject: "Lunch",
            receivedAt: anchor,
            isRead: true,
            savedFolderName: nil,
            summary: "Asks about lunch.",
            calendar: calendar
        )
        XCTAssertTrue(label.hasPrefix("Ada, Lunch, Asks about lunch., "))
    }
}
