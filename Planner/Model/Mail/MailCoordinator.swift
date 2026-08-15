import Foundation

extension Notification.Name {
    static let plannerMailDidChange = Notification.Name("plannerMailDidChange")
    /// Posted when one message's body/headers finish loading or fail. Carries
    /// `MailChangeUserInfoKey.messageID`, so a reader showing a different
    /// message can ignore it instead of rebinding.
    static let plannerMailDetailDidChange = Notification.Name("plannerMailDetailDidChange")
}

enum MailChangeUserInfoKey {
    static let messageID = "messageID"
}

/// Owns the Recent Mail feed: when to sweep, what is currently loaded, whether
/// the last attempt worked, and the per-message bodies fetched since launch.
///
/// A near-copy of `EventCoordinator` by design — same generation gate, same
/// keep-stale-on-failure rule, same timeout backstop, same day-rollover
/// refresh — because the two feeds have the same shape: slow, foreign,
/// read-only, and rendered by a view that must stay honest while a fetch is in
/// flight. Two things are new: the window length is a user setting rather than
/// a constant, and message bodies are lazy, so there is a second, per-message
/// loading state to track.
@MainActor
final class MailCoordinator {
    enum State: Equatable {
        case idle
        case loading
        case loaded(Date)
        case failed(String)
    }

    /// One message's body and headers.
    enum DetailState: Equatable {
        case idle
        case loading
        case loaded(MailMessageDetail)
        case failed(String)
    }

    /// Backstop so the UI can always leave `.loading`. Longer than the
    /// calendar's 30s: M0 measured ~60ms per message, so a 7-day window on a
    /// busy inbox legitimately takes half a minute.
    static let timeoutSeconds = 60
    /// A message body is one small read; if it has not landed in this long,
    /// something is wrong rather than slow.
    static let detailTimeoutSeconds = 20

    private let source: MailSource
    private let calendar: Calendar
    private let now: @MainActor () -> Date
    private let defaults: UserDefaults

    private(set) var state: State = .idle
    private(set) var window: Range<Date>
    private(set) var windowDays: Int
    /// Newest first, which is both the source's order and the list's.
    private(set) var messages: [MailMessage] = []
    /// Set when the last failure is one the user fixes in System Settings, so
    /// the error affordance can offer that instead of a pointless retry.
    private(set) var failureSettingsURL: URL?

    /// Bodies fetched this session, kept across refreshes because ids are
    /// stable. Discarded on quit, like everything else about Recent Mail.
    private var detailCache: [Int64: MailMessageDetail] = [:]
    private var detailStates: [Int64: DetailState] = [:]
    /// One fetch per message, however many callers want it.
    ///
    /// Opening a message and saving it are two different code paths that want
    /// the same body at almost the same moment — the reader asks on selection,
    /// and Save asks again a click later. Two Apple events for one message is
    /// wasteful; worse, whichever reply arrives second finds its caller already
    /// gone. Sharing the task makes the second caller wait for the first.
    private var detailTasks: [Int64: Task<MailMessageDetail, Error>] = [:]

    private var loadTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    /// Bumped on every refresh so a late reply from a superseded one is dropped
    /// rather than painted over newer data.
    private var generation = 0
    /// Overridable in tests so a hung source can be observed without waiting.
    private var timeoutSeconds: Int
    private var detailTimeoutSeconds: Int

    init(
        source: MailSource,
        calendar: Calendar = .current,
        now: @escaping @MainActor () -> Date = { Date() },
        defaults: UserDefaults = .standard,
        timeoutSeconds: Int = MailCoordinator.timeoutSeconds,
        detailTimeoutSeconds: Int = MailCoordinator.detailTimeoutSeconds
    ) {
        self.source = source
        self.calendar = calendar
        self.now = now
        self.defaults = defaults
        self.timeoutSeconds = timeoutSeconds
        self.detailTimeoutSeconds = detailTimeoutSeconds
        windowDays = MailWindow.days(from: defaults)
        window = MailWindow.current(days: windowDays, now: now(), calendar: calendar)

        // Recent Mail is anchored on *today*, so at midnight yesterday's window
        // is one day stale. See `EventCoordinator` for why this is the
        // selector form rather than the block form.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(dayDidChange),
            name: .NSCalendarDayChanged,
            object: nil
        )
    }

    deinit {
        loadTask?.cancel()
        timeoutTask?.cancel()
        for task in detailTasks.values { task.cancel() }
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func dayDidChange() {
        PlannerLog.mail.debug("Day rolled over; sliding the mail window")
        refresh()
    }

    /// What the feed is, for the status tooltip.
    var sourceDisplayName: String { source.displayName }
    /// Which feed it is. The list's empty state depends on it: "no mail in the
    /// last three days" and "Planner shows Outlook mail here" are different
    /// facts, and only one of them is worth acting on.
    var sourceID: String { source.sourceID }

    var isLoading: Bool { state == .loading }

    // MARK: - The window

    /// Changes the window length and re-sweeps. Persisted, so the choice
    /// survives relaunch the way the visible week does.
    func setWindowDays(_ days: Int, userInitiated: Bool = true) {
        let clamped = min(MailWindow.maximumDays, max(MailWindow.minimumDays, days))
        guard clamped != windowDays else { return }
        windowDays = clamped
        defaults.set(clamped, forKey: MailWindow.daysDefaultsKey)
        refresh(userInitiated: userInitiated)
    }

    /// Recomputes the window from today and reloads it. Safe to call at any
    /// time: an in-flight refresh is cancelled first.
    ///
    /// - Parameter userInitiated: Launch and day-rollover must not raise a
    ///   consent dialog; the menu command and the error-button retry may.
    func refresh(userInitiated: Bool = false) {
        loadTask?.cancel()
        timeoutTask?.cancel()
        generation &+= 1
        let generation = generation
        let target = MailWindow.current(days: windowDays, now: now(), calendar: calendar)

        window = target
        state = .loading
        failureSettingsURL = nil
        postChange()

        let source = source
        let seconds = timeoutSeconds
        // The source wraps a blocking Apple event that never observes
        // cancellation, so a task-group timeout would sit behind it. The timer
        // only flips the UI; a late real result still applies via the
        // generation gate.
        loadTask = Task { [weak self] in
            do {
                let messages = try await source.envelopes(in: target, userInitiated: userInitiated)
                guard !Task.isCancelled else { return }
                self?.apply(messages, window: target, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(error, generation: generation)
            }
        }
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.timeoutIfStillLoading(generation: generation, seconds: seconds)
        }
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        for task in detailTasks.values { task.cancel() }
        detailTasks.removeAll()
    }

    func message(id: Int64) -> MailMessage? {
        messages.first { $0.id == id }
    }

    /// The day `message` drops out of the window, for the reader's banner.
    func expiryDay(for message: MailMessage) -> Date? {
        MailWindow.expiryDay(for: message.receivedAt, days: windowDays, calendar: calendar)
    }

    // MARK: - Bodies

    /// The body state of one message, starting a fetch if none has run.
    ///
    /// Reading and requesting are the same call because every caller wants both:
    /// the reader asks what to draw, and "nothing yet" is precisely the moment
    /// to go and get it.
    @discardableResult
    func detailState(for id: Int64, load: Bool = true) -> DetailState {
        if let cached = detailCache[id] { return .loaded(cached) }
        let current = detailStates[id] ?? .idle
        guard load else { return current }
        switch current {
        case .idle, .failed:
            beginLoadingDetail(id: id)
            return .loading
        case .loading, .loaded:
            return current
        }
    }

    /// Already-fetched body, without starting a fetch. Used where a miss is
    /// simply "not yet", e.g. deciding whether saving needs a round trip.
    func cachedDetail(for id: Int64) -> MailMessageDetail? { detailCache[id] }

    /// Fetches the body for a save or a task-creation, returning it directly
    /// rather than through the cache-and-notify path the reader uses. The
    /// caller is a command that can put the failure in an alert, so this one
    /// throws instead of only recording a state.
    func loadDetail(for id: Int64) async throws -> MailMessageDetail {
        if let cached = detailCache[id] { return cached }
        let task = sharedDetailTask(for: id)
        do {
            let detail = try await task.value
            applyDetail(detail, id: id)
            return detail
        } catch {
            failDetail(error, id: id)
            throw error
        }
    }

    func reveal(messageID id: Int64) async throws {
        try await source.reveal(messageID: id)
    }

    private func sharedDetailTask(for id: Int64) -> Task<MailMessageDetail, Error> {
        if let existing = detailTasks[id] { return existing }
        let source = source
        let seconds = detailTimeoutSeconds
        let task = Task<MailMessageDetail, Error> {
            try await withMailTimeout(seconds: seconds) {
                try await source.detail(forMessageID: id)
            }
        }
        detailTasks[id] = task
        return task
    }

    private func beginLoadingDetail(id: Int64) {
        detailStates[id] = .loading
        let task = sharedDetailTask(for: id)
        Task { [weak self] in
            do {
                let detail = try await task.value
                self?.applyDetail(detail, id: id)
            } catch is CancellationError {
                return
            } catch {
                self?.failDetail(error, id: id)
            }
        }
    }

    /// Idempotent: both the reader's observer and a direct `loadDetail` caller
    /// land here for the same reply.
    private func applyDetail(_ detail: MailMessageDetail, id: Int64) {
        detailTasks[id] = nil
        guard detailCache[id] != detail || detailStates[id] != .loaded(detail) else { return }
        detailCache[id] = detail
        detailStates[id] = .loaded(detail)
        postDetailChange(id: id)
    }

    private func failDetail(_ error: Error, id: Int64) {
        // Cleared so the next ask starts a fresh fetch rather than awaiting a
        // task that has already failed.
        detailTasks[id] = nil
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        guard detailStates[id] != .failed(message) else { return }
        PlannerLog.mail.error("Message body failed: \(message, privacy: .public)")
        detailStates[id] = .failed(message)
        postDetailChange(id: id)
    }

    // MARK: - Applying results

    private func apply(_ messages: [MailMessage], window applied: Range<Date>, generation: Int) {
        // Two gates, because either can be stale on its own: a newer refresh
        // may already have started, or the window may have moved under us.
        guard generation == self.generation, applied == window else { return }
        // Sorted here, once, so the list never re-sorts and cannot reshuffle
        // between refreshes. Newest first; id breaks ties so two messages that
        // arrived in the same second keep a stable order.
        self.messages = messages.sorted {
            $0.receivedAt == $1.receivedAt ? $0.id > $1.id : $0.receivedAt > $1.receivedAt
        }
        state = .loaded(now())
        postChange()
    }

    /// Keeps whatever was already loaded. Blanking the list because one refresh
    /// failed is worse than showing mail from a few minutes ago — the error is
    /// surfaced in the toolbar instead.
    private func fail(_ error: Error, generation: Int) {
        guard generation == self.generation else { return }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        failureSettingsURL = (error as? ExternallyResolvableError)?.settingsURL
        PlannerLog.mail.error("Mail refresh failed: \(message, privacy: .public)")
        state = .failed(message)
        postChange()
    }

    private func timeoutIfStillLoading(generation: Int, seconds: Int) {
        guard generation == self.generation, state == .loading else { return }
        fail(MailSourceError.timedOut(seconds: seconds), generation: generation)
    }

    private func postChange() {
        NotificationCenter.default.post(name: .plannerMailDidChange, object: self)
    }

    private func postDetailChange(id: Int64) {
        NotificationCenter.default.post(
            name: .plannerMailDetailDidChange,
            object: self,
            userInfo: [MailChangeUserInfoKey.messageID: id]
        )
    }

    // MARK: - Test hooks

    /// `NSCalendarDayChanged` cannot be provoked on demand.
    func test_dayDidChange() { dayDidChange() }
    /// A hung source can then be observed without waiting a minute.
    func test_timeoutSeconds(_ seconds: Int) { timeoutSeconds = seconds }
    func test_detailTimeoutSeconds(_ seconds: Int) { detailTimeoutSeconds = seconds }
}
