import Foundation

extension Notification.Name {
    static let plannerMailDidChange = Notification.Name("plannerMailDidChange")
    static let plannerMailSearchDidChange = Notification.Name("plannerMailSearchDidChange")
    /// Posted when one message's body/headers finish loading or fail. Carries
    /// `MailChangeUserInfoKey.messageID`, so a reader showing a different
    /// message can ignore it instead of rebinding.
    static let plannerMailDetailDidChange = Notification.Name("plannerMailDetailDidChange")
}

enum MailChangeUserInfoKey {
    static let messageID = "messageID"
}

nonisolated struct MailQuickSearch: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var query: String
}

/// Owns the Recent Mail feed: when to sweep, what is currently loaded, whether
/// the last attempt worked, and the per-message bodies fetched since launch.
///
/// A near-copy of `EventCoordinator` by design — same generation gate, same
/// keep-stale-on-failure rule, same timeout backstop, same day-rollover
/// refresh — because the two feeds have the same shape: slow, foreign,
/// read-only, and rendered by a view that must stay honest while a fetch is in
/// flight. The window length is a user setting, message bodies are lazy, and
/// explicit hide/unhide commands write Outlook's `Hide` category.
@MainActor
final class MailCoordinator {
    static let quickSearchesDefaultsKey = "mail.quickSearches"
    static let showsHiddenMessagesDefaultsKey = "mail.showsHiddenMessages"

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

    enum SearchState: Equatable {
        case idle
        case loading
        case loaded([MailMessage])
        case failed(String)
    }

    /// Backstop so the UI can always leave `.loading`. A first `olsyncmail`
    /// index of a large mailbox is minutes, not seconds; later refreshes are
    /// incremental and return almost immediately.
    ///
    /// Measured from the last word out of the helper, not from the start of
    /// the sweep: a job still reporting progress is alive, however long it
    /// takes. See `OutlookSyncProgressReporter.waitForSilence(seconds:startedAt:)`.
    static let timeoutSeconds = 300
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
    ///
    /// The Recent Mail window, with Outlook's `Hide` category filtered out
    /// unless `showsHiddenMessages` is on.
    private(set) var messages: [MailMessage] = []
    /// The same window, containing only messages carrying Outlook's `Hide`
    /// category.
    private(set) var hiddenMessages: [MailMessage] = []
    /// Off by default: Hidden is a view filter, not a mailbox.
    private(set) var showsHiddenMessages = false
    /// Outlook's available non-Hide categories, alphabetized by the source.
    private(set) var categories: [OutlookCategory] = []
    /// User-named, whole-index searches persisted in sidebar order.
    private(set) var quickSearches: [MailQuickSearch] = []
    private(set) var searchState: SearchState = .idle
    private var searchQuery = ""
    /// Complete-index results, including messages outside the Recent window.
    private var allSearchResults: [MailMessage] = []
    /// The window as the source reported it, before the Hidden filter.
    private(set) var allMessages: [MailMessage] = []
    /// Set when the last failure is one the user fixes in System Settings, so
    /// the error affordance can offer that instead of a pointless retry.
    private(set) var failureSettingsURL: URL?

    /// Bodies fetched this session, kept across refreshes because ids are
    /// stable. Discarded on quit, like everything else about Recent Mail.
    private var detailCache: [Int64: MailMessageDetail] = [:]
    private var detailStates: [Int64: DetailState] = [:]
    /// One fetch per message, however many callers want it.
    ///
    /// Sharing the task prevents duplicate body reads when multiple callers
    /// request the same selected message.
    private var detailTasks: [Int64: Task<MailMessageDetail, Error>] = [:]

    private var loadTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0
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
        if let data = defaults.data(forKey: Self.quickSearchesDefaultsKey),
           let saved = try? JSONDecoder().decode([MailQuickSearch].self, from: data) {
            quickSearches = saved.sorted(by: Self.quickSearchLessThan)
        }
        showsHiddenMessages = defaults.bool(forKey: Self.showsHiddenMessagesDefaultsKey)
        windowDays = MailWindow.days(from: defaults)
        window = MailWindow.current(days: windowDays, now: now(), calendar: calendar)
        // Recent Mail is anchored on *today*, so at midnight yesterday's window
        // is one day stale. See `EventCoordinator` for why this is the
        // selector form, and why the @objc entry hops to the main actor.
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
        searchTask?.cancel()
        for task in detailTasks.values { task.cancel() }
        NotificationCenter.default.removeObserver(self)
    }

    @objc nonisolated private func dayDidChange() {
        Task { @MainActor [weak self] in
            self?.handleDayRollover()
        }
    }

    private func handleDayRollover() {
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
        let clamped = MailWindow.choice(for: days)
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
        startLoad(userInitiated: userInitiated, rebuildIndex: false)
    }

    /// Re-indexes every Outlook message and event, then reloads Recent Mail.
    func rebuildIndex(userInitiated: Bool = true) {
        startLoad(userInitiated: userInitiated, rebuildIndex: true)
    }

    private func startLoad(userInitiated: Bool, rebuildIndex: Bool) {
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
        // The source's first sync can run for minutes and does not observe
        // cancellation promptly, so a task-group timeout would sit behind it.
        // The timer only flips the UI; a late real result still applies via the
        // generation gate.
        //
        loadTask = Task { [weak self] in
            do {
                if rebuildIndex {
                    try await source.rebuildIndex()
                }
                let messages = try await source.envelopes(in: target, userInitiated: userInitiated)
                let categories = try await source.availableCategories()
                guard !Task.isCancelled else { return }
                self?.apply(
                    messages,
                    categories: categories,
                    window: target,
                    generation: generation
                )
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

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        searchTask?.cancel()
        searchTask = nil
        for task in detailTasks.values { task.cancel() }
        detailTasks.removeAll()
    }

    func message(id: Int64) -> MailMessage? {
        allMessages.first { $0.id == id }
            ?? allSearchResults.first { $0.id == id }
    }

    var searchResults: [MailMessage] {
        guard case let .loaded(messages) = searchState else { return [] }
        return visible(messages)
    }

    /// Hidden messages stay in the index; this only changes whether lists
    /// include them. The default is off, matching a Hide that is meant to
    /// get a message out of the way.
    func setShowsHiddenMessages(_ show: Bool) {
        guard showsHiddenMessages != show else { return }
        showsHiddenMessages = show
        defaults.set(show, forKey: Self.showsHiddenMessagesDefaultsKey)
        republish()
        postChange()
    }

    func messages(categoryID: Int64) -> [MailMessage] {
        messages.filter { $0.categoryIDs.contains(categoryID) }
    }

    func category(id: Int64) -> OutlookCategory? {
        categories.first { $0.id == id }
    }

    /// The categories that may be applied to `messages`.
    ///
    /// Outlook offers categories per account, so a message can only take the
    /// ones its own account defines. Outlook's built-in set (`accountUID` 0)
    /// belongs to no account and is left out: those eight names are the ones
    /// nobody in this profile uses.
    ///
    /// A selection spanning two accounts has nothing in common — a category is
    /// defined in exactly one account — so it offers none rather than an item
    /// that would fail on half the messages.
    func categories(applicableTo messages: [MailMessage]) -> [OutlookCategory] {
        let accounts = Set(messages.map(\.accountUID))
        guard accounts.count == 1, let account = accounts.first, account != 0 else { return [] }
        return categories.filter { $0.accountUID == account }
    }

    func quickSearch(id: UUID) -> MailQuickSearch? {
        quickSearches.first { $0.id == id }
    }

    /// Names are unique case-insensitively. Saving an existing name updates its
    /// query instead of leaving two indistinguishable folders in the sidebar.
    @discardableResult
    func saveQuickSearch(name rawName: String, query rawQuery: String) -> MailQuickSearch? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !query.isEmpty else { return nil }
        let saved: MailQuickSearch
        if let index = quickSearches.firstIndex(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            quickSearches[index].name = name
            quickSearches[index].query = query
            saved = quickSearches[index]
        } else {
            saved = MailQuickSearch(id: UUID(), name: name, query: query)
            quickSearches.append(saved)
        }
        quickSearches.sort(by: Self.quickSearchLessThan)
        persistQuickSearches()
        postChange()
        return saved
    }

    func deleteQuickSearch(id: UUID) {
        guard let index = quickSearches.firstIndex(where: { $0.id == id }) else { return }
        quickSearches.remove(at: index)
        persistQuickSearches()
        postChange()
    }

    private func persistQuickSearches() {
        guard let data = try? JSONEncoder().encode(quickSearches) else { return }
        defaults.set(data, forKey: Self.quickSearchesDefaultsKey)
    }

    private static func quickSearchLessThan(_ lhs: MailQuickSearch, _ rhs: MailQuickSearch) -> Bool {
        let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        return order == .orderedSame
            ? lhs.id.uuidString < rhs.id.uuidString
            : order == .orderedAscending
    }

    /// Distinct folder paths in the local index, for `folder:` search and MCP.
    func folders() async throws -> [MailFolder] {
        try await source.folders()
    }

    /// A complete-index search that waits for the result. MCP uses this so an
    /// agent query is a request/response rather than the sidebar's fire-and-forget
    /// search, and so it does not steal the user's query. Hidden messages follow
    /// the same filter as the rest of the feed.
    func searchIndex(_ rawQuery: String) async throws -> [MailMessage] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let results = try await source.search(query: query)
        let visible = visible(Self.sorted(results))
        remember(visible)
        return visible
    }

    /// Keeps envelopes MCP (or a later open) can address after a search that
    /// did not go through the sidebar's `searchState`.
    func remember(_ messages: [MailMessage]) {
        let known = Set(allMessages.map(\.id)).union(Set(allSearchResults.map(\.id)))
        for message in messages where !known.contains(message.id) {
            allSearchResults.append(message)
        }
    }

    /// Searches the complete index. Generation gating gives a fast second
    /// query ownership over a late first reply.
    func search(_ rawQuery: String) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        searchGeneration &+= 1
        let generation = searchGeneration
        searchQuery = query

        guard !query.isEmpty else {
            allSearchResults = []
            searchState = .idle
            postSearchChange()
            return
        }

        searchState = .loading
        postSearchChange()
        let source = source
        searchTask = Task { [weak self] in
            do {
                let results = try await source.search(query: query)
                guard !Task.isCancelled else { return }
                self?.applySearch(results, query: query, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.failSearch(error, query: query, generation: generation)
            }
        }
    }

    /// The day `message` drops out of the window, for the reader's banner.
    func expiryDay(for message: MailMessage) -> Date? {
        MailWindow.expiryDay(for: message.receivedAt, days: windowDays, calendar: calendar)
    }

    // MARK: - Hidden category

    /// Changes Outlook first, then moves the envelopes between Planner's two
    /// in-memory mailbox partitions. A later failure still keeps the earlier
    /// successes; the thrown error is the first one Outlook reported.
    func setHidden(_ hidden: Bool, messages: [MailMessage]) async throws {
        let targets = messages.filter { $0.isHidden != hidden }
        guard !targets.isEmpty else { return }
        var succeeded: Set<Int64> = []
        var firstError: Error?
        for message in targets {
            do {
                try await source.setHidden(hidden, messageID: message.id)
                succeeded.insert(message.id)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if !succeeded.isEmpty {
            allMessages = allMessages.map {
                succeeded.contains($0.id) ? $0.with(isHidden: hidden) : $0
            }
            allSearchResults = allSearchResults.map {
                succeeded.contains($0.id) ? $0.with(isHidden: hidden) : $0
            }
            republish()
            PlannerLog.mail.info(
                "\(hidden ? "Hid" : "Unhid") \(succeeded.count, privacy: .public) message(s) in Outlook"
            )
            postChange()
        }
        if let firstError { throw firstError }
    }

    func setHidden(_ hidden: Bool, message: MailMessage) async throws {
        try await setHidden(hidden, messages: [message])
    }

    // MARK: - Ordinary categories

    /// Adds or removes one ordinary category, retaining successful writes if a
    /// later message fails. Generic UI only exposes the add direction; remove
    /// exists so Undo can faithfully reverse an application.
    func setCategory(
        _ categoryID: Int64,
        present: Bool,
        messages: [MailMessage]
    ) async throws {
        guard category(id: categoryID) != nil else { return }
        let targets = messages.filter { $0.categoryIDs.contains(categoryID) != present }
        guard !targets.isEmpty else { return }
        var succeeded: Set<Int64> = []
        var firstError: Error?
        for message in targets {
            do {
                try await source.setCategory(
                    categoryID,
                    present: present,
                    messageID: message.id
                )
                succeeded.insert(message.id)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if !succeeded.isEmpty {
            allMessages = allMessages.map {
                succeeded.contains($0.id)
                    ? $0.with(categoryID: categoryID, present: present)
                    : $0
            }
            allSearchResults = allSearchResults.map {
                succeeded.contains($0.id)
                    ? $0.with(categoryID: categoryID, present: present)
                    : $0
            }
            republish()
            PlannerLog.mail.info(
                "\(present ? "Applied" : "Removed") category \(categoryID, privacy: .public) on \(succeeded.count, privacy: .public) message(s)"
            )
            postChange()
        }
        if let firstError { throw firstError }
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

    /// Already-fetched body, without starting a fetch.
    func cachedDetail(for id: Int64) -> MailMessageDetail? { detailCache[id] }

    /// Fetches the body directly rather than through the
    /// cache-and-notify path the reader uses.
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

    /// Copies a stored attachment out of the index so the reader can open it.
    func fileURL(for attachment: MailAttachment) async throws -> URL {
        try await source.fileURL(for: attachment)
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

    private func apply(
        _ messages: [MailMessage],
        categories: [OutlookCategory],
        window applied: Range<Date>,
        generation: Int
    ) {
        // Two gates, because either can be stale on its own: a newer refresh
        // may already have started, or the window may have moved under us.
        guard generation == self.generation, applied == window else { return }
        // Sorted here, once, so the list never re-sorts and cannot reshuffle
        // between refreshes. Newest first; id breaks ties so two messages that
        // arrived in the same second keep a stable order.
        allMessages = Self.sorted(messages)
        self.categories = categories
            .filter {
                $0.name.caseInsensitiveCompare(OutlookCategory.hiddenName) != .orderedSame
            }
            .sorted {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
        republish()
        state = .loaded(now())
        postChange()
        // A refresh may have changed indexed content under an active query.
        if !searchQuery.isEmpty { search(searchQuery) }
    }

    /// The one place Outlook's category flag is applied as a view filter.
    private func republish() {
        messages = visible(allMessages)
        hiddenMessages = allMessages.filter(\.isHidden)
        republishSearch()
    }

    private func visible(_ messages: [MailMessage]) -> [MailMessage] {
        showsHiddenMessages ? messages : messages.filter { !$0.isHidden }
    }

    private func republishSearch() {
        guard case .loaded = searchState else { return }
        searchState = .loaded(allSearchResults)
        postSearchChange()
    }

    private func applySearch(
        _ messages: [MailMessage],
        query: String,
        generation: Int
    ) {
        guard generation == searchGeneration, query == searchQuery else { return }
        allSearchResults = Self.sorted(messages)
        searchState = .loaded(allSearchResults)
        postSearchChange()
    }

    private func failSearch(_ error: Error, query: String, generation: Int) {
        guard generation == searchGeneration, query == searchQuery else { return }
        allSearchResults = []
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        PlannerLog.mail.error("Mail search failed: \(message, privacy: .public)")
        searchState = .failed(message)
        postSearchChange()
    }

    private static func sorted(_ messages: [MailMessage]) -> [MailMessage] {
        messages.sorted {
            $0.receivedAt == $1.receivedAt ? $0.id > $1.id : $0.receivedAt > $1.receivedAt
        }
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

    private func postSearchChange() {
        NotificationCenter.default.post(name: .plannerMailSearchDidChange, object: self)
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
    func test_dayDidChange() { handleDayRollover() }
    /// A hung source can then be observed without waiting a minute.
    func test_timeoutSeconds(_ seconds: Int) { timeoutSeconds = seconds }
    func test_detailTimeoutSeconds(_ seconds: Int) { detailTimeoutSeconds = seconds }
}
