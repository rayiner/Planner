import Foundation

extension Notification.Name {
    /// Posted when one message's summary changes state — queued, in flight,
    /// landed, or failed. Carries `MailChangeUserInfoKey.messageID` so the
    /// list can redraw one row instead of rebuilding itself.
    static let plannerMailSummaryDidChange = Notification.Name("plannerMailSummaryDidChange")
}

/// Produces a one-line summary of every message in Recent Mail with the
/// on-device model, one message at a time, newest first, visible rows first.
///
/// Asynchronous by construction: a summary costs a body fetch from Outlook
/// (~10-100ms) plus a model reply (seconds), and a seven-day window can hold
/// a couple of hundred messages. So nothing here blocks anything. The list
/// paints subjects as soon as the envelopes land, reserves a line under each,
/// and fills the lines in as answers arrive — the same keep-the-UI-honest
/// shape as `MailCoordinator` and `EventCoordinator`.
///
/// **One request in flight at a time.** The model is a single shared system
/// resource; a second concurrent request queues behind the first inside the
/// framework anyway, and would only add a second body fetch to Outlook's
/// queue while the user may be trying to open a message.
///
/// Summaries are keyed by Outlook's stable message id and remembered in a
/// sidecar, so a relaunch shows yesterday's summaries with yesterday's cached
/// envelopes rather than starting over.
@MainActor
final class MailSummaryCoordinator {
    enum State: Equatable {
        /// Never asked, or the model was unavailable when the window landed.
        case idle
        /// Waiting its turn.
        case queued
        /// Body fetch or model reply in progress.
        case loading
        case loaded(String)
        /// Not retried this session: the failures worth retrying (rate limit,
        /// timeout) are re-queued on the next window change instead.
        case failed(String)
    }

    /// A body read plus a reply from a warm model is a few seconds; a cold
    /// model's first reply can take tens. Past this, something is stuck.
    static let timeoutSeconds = 90
    /// How many on-screen rows may jump the queue. Bounded so a fast scroll
    /// through the whole list does not simply reorder the entire queue.
    static let priorityLimit = 40

    private let model: OnDeviceLanguageModel
    private let store: MailSummaryStore
    private let sourceID: String
    private let calendar: Calendar
    private let now: @MainActor () -> Date
    private var timeoutSeconds: Int

    /// Set by the owning `MailCoordinator`: bodies go through its shared
    /// per-message fetch so a summary and the reader never ask Outlook twice.
    var detailLoader: (@MainActor (Int64) async throws -> MailMessageDetail)?

    private var states: [Int64: State] = [:]
    private var receivedAt: [Int64: Date] = [:]
    /// The envelopes `update` was last handed, for the prompt's header. Read
    /// when the body arrives rather than captured at enqueue time, so a
    /// stale subject is impossible.
    private var envelopes: [Int64: MailMessage] = [:]
    /// Newest first: the order the window arrives in.
    private var queue: [Int64] = []
    /// Ids a row has drawn, in draw order. Served before `queue`.
    private var priority: [Int64] = []
    private var inFlight: [Int64: Task<Void, Never>] = [:]
    /// Read once per window change and cached until the next: the model's
    /// availability is a system property, and asking it per row is wasteful.
    private(set) var availability: OnDeviceModelAvailability

    init(
        model: OnDeviceLanguageModel,
        store: MailSummaryStore = .disabled,
        sourceID: String,
        calendar: Calendar = .current,
        now: @escaping @MainActor () -> Date = { Date() },
        timeoutSeconds: Int = MailSummaryCoordinator.timeoutSeconds
    ) {
        self.model = model
        self.store = store
        self.sourceID = sourceID
        self.calendar = calendar
        self.now = now
        self.timeoutSeconds = timeoutSeconds
        availability = model.availability
        restore()
    }

    deinit {
        for task in inFlight.values { task.cancel() }
    }

    /// Whether the list should reserve a summary line at all. False on a Mac
    /// without Apple Intelligence, where the rows keep their two-line shape.
    var isAvailable: Bool { availability.isAvailable }

    func summary(for id: Int64) -> String? {
        if case let .loaded(text) = states[id] { return text }
        return nil
    }

    func state(for id: Int64) -> State { states[id] ?? .idle }

    // MARK: - The window

    /// Brings the queue in line with the messages currently in Recent Mail.
    ///
    /// Called by `MailCoordinator` on every republish: after a sweep, a
    /// dismissal, a restore. Messages that left take their place in the queue
    /// with them; new ones join in window order, so new mail is summarized
    /// before old. Anything already answered is left alone.
    func update(messages: [MailMessage]) {
        availability = model.availability
        for message in messages {
            receivedAt[message.id] = message.receivedAt
            envelopes[message.id] = message
        }
        let ids = Set(messages.map(\.id))
        queue.removeAll { !ids.contains($0) }
        priority.removeAll { !ids.contains($0) }
        for id in Array(states.keys) where !ids.contains(id) {
            if case .queued = states[id] { states[id] = .idle }
        }

        guard isAvailable else { return }
        var changed: [Int64] = []
        for message in messages {
            switch states[message.id] ?? .idle {
            case .idle:
                states[message.id] = .queued
                queue.append(message.id)
                changed.append(message.id)
            case let .failed(reason) where Self.isRetryable(reason):
                states[message.id] = .queued
                queue.append(message.id)
                changed.append(message.id)
            case .queued, .loading, .loaded, .failed:
                break
            }
        }
        // Window order, not arrival order: an id that was already queued
        // stays newest-first relative to the ones that just joined.
        let position = Dictionary(uniqueKeysWithValues: messages.enumerated().map { ($1.id, $0) })
        queue.sort { (position[$0] ?? .max) < (position[$1] ?? .max) }
        prune()
        for id in changed { postChange(id: id) }
        pump()
    }

    /// A row for `id` just came on screen. Its summary is what the user is
    /// waiting for, so it goes ahead of the rest of the window.
    func prioritize(_ id: Int64) {
        guard case .queued = states[id] else { return }
        priority.removeAll { $0 == id }
        priority.append(id)
        if priority.count > Self.priorityLimit { priority.removeFirst() }
        pump()
    }

    func cancel() {
        for (id, task) in inFlight {
            task.cancel()
            states[id] = .queued
            queue.insert(id, at: 0)
        }
        inFlight.removeAll()
    }

    // MARK: - The worker

    private func nextID() -> Int64? {
        if let id = priority.first(where: { queue.contains($0) }) { return id }
        return queue.first
    }

    private func pump() {
        guard inFlight.isEmpty, detailLoader != nil, let id = nextID() else { return }
        queue.removeAll { $0 == id }
        priority.removeAll { $0 == id }
        states[id] = .loading
        postChange(id: id)

        let seconds = timeoutSeconds
        inFlight[id] = Task { [weak self] in
            do {
                guard let self, let detailLoader = self.detailLoader else { return }
                let detail = try await detailLoader(id)
                guard let message = self.message(id: id) else { throw CancellationError() }
                let summary = try await self.summarize(message, detail: detail, seconds: seconds)
                guard !Task.isCancelled else { return }
                self.finish(id: id, with: .loaded(summary))
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                PlannerLog.mail.error(
                    "Summary failed for message \(id, privacy: .public): \(reason, privacy: .public)"
                )
                self?.finish(id: id, with: .failed(reason))
            }
        }
    }

    private func message(id: Int64) -> MailMessage? { envelopes[id] }

    private func summarize(_ message: MailMessage, detail: MailMessageDetail, seconds: Int) async throws -> String {
        let body = MailSummaryPrompt.plainBody(from: detail)
        let model = model
        do {
            return try await Self.ask(model, MailSummaryPrompt.request(for: message, body: body), seconds: seconds)
        } catch let error as OnDeviceModelError where Self.deservesShorterRetry(error, bodyLength: body.count) {
            // Two long-body failures get one shorter retry. The body cap is
            // sized for the smallest context the model has shipped with, but
            // tokens per character vary by language, so it can still overflow;
            // and on some long bodies the model answers with an invented tool
            // call rather than a sentence. Less body fixes both often enough
            // to be worth one more round trip before giving up.
            let request = MailSummaryPrompt.request(
                for: message,
                body: body,
                bodyLimit: MailSummaryPrompt.shortBodyLimit
            )
            return try await Self.ask(model, request, seconds: seconds)
        }
    }

    private static func deservesShorterRetry(_ error: OnDeviceModelError, bodyLength: Int) -> Bool {
        guard bodyLength > MailSummaryPrompt.shortBodyLimit else { return false }
        switch error {
        case .promptTooLong: return true
        case .failed(let reason): return reason == unusableReplyReason
        default: return false
        }
    }

    static let unusableReplyReason = "Apple Intelligence didn’t return a usable summary."

    private static func ask(
        _ model: OnDeviceLanguageModel,
        _ request: OnDeviceModelRequest,
        seconds: Int
    ) async throws -> String {
        let raw = try await withMailTimeout(seconds: seconds) {
            try await model.respond(to: request)
        }
        guard let cleaned = MailSummaryPrompt.cleaned(raw) else {
            throw OnDeviceModelError.failed(unusableReplyReason)
        }
        return cleaned
    }

    private func finish(id: Int64, with state: State) {
        inFlight[id] = nil
        states[id] = state
        if case .loaded = state { persist() }
        postChange(id: id)
        pump()
    }

    /// Rate limits and timeouts clear on their own; a refusal or an
    /// unavailable model does not, and re-asking would loop.
    private static func isRetryable(_ reason: String) -> Bool {
        reason == OnDeviceModelError.rateLimited.errorDescription
            || reason.hasPrefix("Outlook didn’t respond")
    }

    // MARK: - Persistence

    private func restore() {
        guard let record = store.load(), record.sourceID == sourceID else { return }
        for entry in record.entries {
            states[entry.id] = .loaded(entry.summary)
            receivedAt[entry.id] = entry.receivedAt
        }
    }

    private func persist() {
        let entries = states.compactMap { id, state -> MailSummaryEntry? in
            guard case let .loaded(summary) = state, let date = receivedAt[id] else { return nil }
            return MailSummaryEntry(id: id, receivedAt: date, summary: summary)
        }.sorted { $0.receivedAt > $1.receivedAt }
        store.save(MailSummaryRecord(sourceID: sourceID, entries: entries))
    }

    /// Forgets summaries for messages that can no longer re-enter the window.
    /// Uses the maximum window, like dismissals, so widening the window later
    /// does not re-run the model over mail that was summarized while narrow.
    private func prune() {
        let today = calendar.startOfDay(for: now())
        let cutoff = calendar.date(byAdding: .day, value: -MailWindow.maximumDays, to: today) ?? .distantPast
        var dropped = false
        for (id, date) in receivedAt where date < cutoff {
            guard inFlight[id] == nil else { continue }
            states[id] = nil
            receivedAt[id] = nil
            envelopes[id] = nil
            dropped = true
        }
        if dropped { persist() }
    }

    private func postChange(id: Int64) {
        NotificationCenter.default.post(
            name: .plannerMailSummaryDidChange,
            object: self,
            userInfo: [MailChangeUserInfoKey.messageID: id]
        )
    }

    // MARK: - Test hooks

    var test_queuedIDs: [Int64] { queue }
    var test_inFlightIDs: Set<Int64> { Set(inFlight.keys) }
    func test_timeoutSeconds(_ seconds: Int) { timeoutSeconds = seconds }
}
