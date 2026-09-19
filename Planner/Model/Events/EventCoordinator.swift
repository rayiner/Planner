import Foundation

extension Notification.Name {
    static let plannerEventsDidChange = Notification.Name("plannerEventsDidChange")
}

/// Owns the external event feed: when to fetch, what is currently loaded, and
/// whether the last attempt worked.
///
/// The source may take seconds, so every refresh is asynchronous and the grid
/// simply renders whatever is loaded at the time. Two rules keep that honest:
/// a superseded refresh never paints, and a failed refresh never blanks the
/// grid.
@MainActor
final class EventCoordinator {
    enum State: Equatable {
        case idle
        case loading
        case loaded(Date)
        case failed(String)
    }

    /// Backstop so the UI can always leave `.loading`, even behind a source
    /// that neither returns nor throws. Sources set their own timeouts too;
    /// this one exists because a hung spinner is unrecoverable from the UI.
    ///
    /// Measured from the last word out of the indexer rather than from the
    /// start of the fetch. A calendar refresh queues behind a running mail
    /// index — one sync job at a time — so the wait routinely outlasts thirty
    /// seconds while the helper is plainly working.
    static let timeoutSeconds = 30

    private let source: CalendarEventSource
    private let calendar: Calendar
    private let now: @MainActor () -> Date

    private(set) var state: State = .idle
    private(set) var window: Range<Date>
    private(set) var chipsByDay: [Date: [CalendarEventChip]] = [:]
    /// Set when the last failure is one the user fixes in System Settings, so
    /// the error affordance can offer that instead of a pointless retry.
    private(set) var failureSettingsURL: URL?

    private var loadTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    /// Bumped on every refresh so a late reply from a superseded one is dropped
    /// rather than painted over newer data.
    private var generation = 0
    /// Overridable in tests so a hung source can be observed without waiting 30s.
    private var timeoutSeconds: Int

    init(
        source: CalendarEventSource,
        calendar: Calendar = .current,
        now: @escaping @MainActor () -> Date = { Date() },
        timeoutSeconds: Int = EventCoordinator.timeoutSeconds
    ) {
        self.source = source
        self.calendar = calendar
        self.now = now
        self.timeoutSeconds = timeoutSeconds
        window = EventWindow.current(now: now(), calendar: calendar)

        // The window is anchored on *today*, so at midnight it is one day stale
        // in both directions. Refreshing on the rollover is what keeps an app
        // left open overnight from quietly showing yesterday's range.
        //
        // Selector-based rather than a block with an explicit queue: the token
        // form returns a non-`Sendable` observer that a nonisolated `deinit`
        // cannot release. CF posts this from `__postAndResetMidnight` on a
        // root GCD queue, so the @objc entry is nonisolated and hops here.
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
        NotificationCenter.default.removeObserver(self)
    }

    @objc nonisolated private func dayDidChange() {
        Task { @MainActor [weak self] in
            self?.handleDayRollover()
        }
    }

    private func handleDayRollover() {
        PlannerLog.events.debug("Day rolled over; sliding the event window")
        refresh()
    }

    /// What the feed is, for the status tooltip. The coordinator does not
    /// otherwise care which source it holds.
    var sourceDisplayName: String { source.displayName }

    func chips(forDay day: Date) -> [CalendarEventChip] {
        chipsByDay[calendar.startOfDay(for: day)] ?? []
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
        let target = EventWindow.current(now: now(), calendar: calendar)

        window = target
        state = .loading
        failureSettingsURL = nil
        postChange()

        let source = source
        let seconds = timeoutSeconds
        // The source can be inside an index sync when this task is cancelled.
        // The timer flips the UI independently; a late real result still
        // applies only if the generation gate accepts it.
        loadTask = Task { [weak self] in
            do {
                let events = try await source.events(in: target, userInitiated: userInitiated)
                guard !Task.isCancelled else { return }
                self?.apply(events, window: target, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(error, generation: generation)
            }
        }
        timeoutTask = Task { [weak self] in
            await OutlookSyncProgressReporter.shared.waitForSilence(seconds: seconds)
            guard !Task.isCancelled else { return }
            self?.timeoutIfStillLoading(generation: generation, seconds: seconds)
        }
    }

    /// Test hook: `NSCalendarDayChanged` cannot be provoked on demand.
    func test_dayDidChange() { handleDayRollover() }

    /// Test hook: a hung source can be observed without waiting 30s.
    func test_timeoutSeconds(_ seconds: Int) { timeoutSeconds = seconds }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    // MARK: - Applying results

    private func apply(_ events: [CalendarEvent], window applied: Range<Date>, generation: Int) {
        // Two gates, because either can be stale on its own: a newer refresh
        // may already have started, or the window may have moved under us.
        guard generation == self.generation, applied == window else { return }
        chipsByDay = CalendarEventChip.index(events, in: applied, calendar: calendar)
        state = .loaded(now())
        postChange()
    }

    /// Keeps whatever was already loaded. Blanking the grid because one refresh
    /// failed is worse than showing events from a few minutes ago — the error
    /// is surfaced in the toolbar instead.
    private func fail(_ error: Error, generation: Int) {
        guard generation == self.generation else { return }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        failureSettingsURL = (error as? ExternallyResolvableError)?.settingsURL
        PlannerLog.events.error("Event refresh failed: \(message, privacy: .public)")
        state = .failed(message)
        postChange()
    }

    private func postChange() {
        NotificationCenter.default.post(name: .plannerEventsDidChange, object: self)
    }

    private func timeoutIfStillLoading(generation: Int, seconds: Int) {
        guard generation == self.generation, state == .loading else { return }
        fail(EventSourceError.timedOut(seconds: seconds), generation: generation)
    }
}
