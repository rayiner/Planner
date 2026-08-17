import AppKit
import CoreData

/// One day's worth of messages, and the sticky header over them.
///
/// A parent item rather than an interleaved header row: `NSOutlineView` already
/// knows how to float a group row as the list scrolls, and getting that for
/// free is worth modelling the days explicitly.
final class MailDateGroup: NSObject {
    let day: Date
    let title: String
    let rows: [MailListRow]

    init(day: Date, title: String, rows: [MailListRow]) {
        self.day = day
        self.title = title
        self.rows = rows
    }
}

/// One row in the list. `MailMessage` is a value and `NSOutlineView` addresses
/// rows by identity, so the value gets a box.
final class MailListRow: NSObject {
    let message: MailMessage
    /// The folder already holding a copy, if any — the "Saved to X" chip, and
    /// the reason the row is dimmed.
    let savedFolderName: String?

    init(message: MailMessage, savedFolderName: String?) {
        self.message = message
        self.savedFolderName = savedFolderName
    }
}

/// A conversation inside a folder: a parent row that expands in place.
///
/// Only built when there is more than one message. A one-message conversation
/// is just a message, and wrapping it in a thread row would make the common
/// case cost an extra click to read.
final class MailThreadRow: NSObject {
    let subject: String
    let participants: String
    let latest: Date
    let rows: [SavedMessageRow]

    init(subject: String, participants: String, latest: Date, rows: [SavedMessageRow]) {
        self.subject = subject
        self.participants = participants
        self.latest = latest
        self.rows = rows
    }
}

/// One saved message in a folder.
final class SavedMessageRow: NSObject {
    let message: SavedMessage

    init(message: SavedMessage) {
        self.message = message
    }
}

/// The message list: Recent Mail strictly chronologically, newest first.
///
/// **No threading here, deliberately.** Recent Mail is a timeline you sweep,
/// and threading it would collapse the very ordering that makes the sweep work.
/// Threading is what a *folder* gets, once the user has decided the messages
/// are worth keeping.
final class MailListViewController: NSViewController {
    let persistence: PersistenceController
    let model: ModelController
    let selection: SelectionModel
    let mail: MailCoordinator
    let outlineView = MailListOutlineView()

    private let calendar: Calendar
    private let now: () -> Date
    private let emptyStateLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()
    private let searchHeader = NSView()
    private var groups: [MailDateGroup] = []
    /// Top-level rows in folder mode: thread parents and lone messages, mixed,
    /// ordered by their newest message.
    private var folderRows: [NSObject] = []
    private var isApplyingProgrammaticSelection = false
    /// Enough that a conversation's messages sit under the header rather than
    /// in the same column, without crowding the subject in a 300pt pane.
    static let conversationIndent: CGFloat = 16

    private var isShowingFolder: Bool { !selection.isRecentMailSelected }

    private var searchQuery = ""
    private var searchDebounce: Task<Void, Never>?
    /// Distinct from an empty hit set so the empty state can name a failed fetch.
    private var searchFetchFailed = false
    var conversationChromeNeedsRefresh: (() -> Void)?

    private var isSearching: Bool {
        isShowingFolder && !SavedMessageSearch.tokens(in: searchQuery).isEmpty
    }

    init(
        persistence: PersistenceController,
        model: ModelController,
        selection: SelectionModel,
        mail: MailCoordinator,
        calendar: Calendar = .current,
        now: @escaping () -> Date = { Date() }
    ) {
        self.persistence = persistence
        self.model = model
        self.selection = selection
        self.mail = mail
        self.calendar = calendar
        self.now = now
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        searchDebounce?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        searchField.controlSize = .small
        searchField.sendsWholeSearchString = true
        searchField.sendsSearchStringImmediately = false
        searchField.placeholderString = MailLabels.searchPlaceholder
        searchField.maximumRecents = 0
        searchField.target = self
        searchField.action = #selector(searchFieldAction)
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        searchHeader.translatesAutoresizingMaskIntoConstraints = false
        searchHeader.addSubview(searchField)
        searchHeader.addSubview(separator)
        searchHeader.setContentHuggingPriority(.required, for: .vertical)
        searchHeader.setContentCompressionResistancePriority(.required, for: .vertical)

        emptyStateLabel.font = .systemFont(ofSize: 13, weight: .regular)
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.alignment = .center
        emptyStateLabel.maximumNumberOfLines = 0
        emptyStateLabel.lineBreakMode = .byWordWrapping
        emptyStateLabel.refusesFirstResponder = true
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [searchHeader, scrollView])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(stack)
        root.addSubview(emptyStateLabel)
        view = root

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: searchHeader.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: searchHeader.trailingAnchor, constant: -8),
            searchField.topAnchor.constraint(equalTo: searchHeader.topAnchor, constant: 6),
            searchField.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -6),
            separator.leadingAnchor.constraint(equalTo: searchHeader.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: searchHeader.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: searchHeader.bottomAnchor),
            stack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.bottomAnchor),
            emptyStateLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: -20),
            emptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 24),
            emptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -24),
        ])
        updateSearchHeaderVisibility()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureOutlineView()
        startObserving()
        reload()

        // The first sweep happens here rather than at launch, and this view is
        // only built when mail mode is first entered — so a session spent
        // entirely in tasks mode never pays the ten seconds. Not user-initiated:
        // arriving in mail mode must not raise a consent dialog.
        if mail.state == .idle { mail.refresh() }
    }

    private func configureOutlineView() {
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.style = .inset
        outlineView.rowSizeStyle = .custom
        outlineView.rowHeight = 54
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.headerView = nil
        outlineView.usesAlternatingRowBackgroundColors = false
        // Folder conversations indent their children; Recent Mail days must
        // not, or the triangle sits on the date title. `reload` picks the
        // value for the open mailbox.
        outlineView.indentationPerLevel = 0
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        // The whole point of modelling days as parents: AppKit pins the group
        // row to the top of the scroll view while its day is on screen.
        outlineView.floatsGroupRows = true
        outlineView.focusRingType = .none
        outlineView.backgroundColor = .clear

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Message"))
        column.title = "Message"
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
    }

    private func startObserving() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(mailDidChange(_:)),
            name: .plannerMailDidChange,
            object: mail
        )
        center.addObserver(
            self,
            selector: #selector(plannerSelectionDidChange(_:)),
            name: .plannerSelectionDidChange,
            object: selection
        )
        // Saving a message dims its Recent Mail row and gives it a chip.
        center.addObserver(
            self,
            selector: #selector(contextDidSave(_:)),
            name: .NSManagedObjectContextDidSave,
            object: persistence.viewContext
        )
    }

    @objc private func mailDidChange(_ notification: Notification) { reload() }
    @objc private func contextDidSave(_ notification: Notification) { reload() }

    @objc private func plannerSelectionDidChange(_ notification: Notification) {
        let fields = notification.userInfo?[SelectionUserInfoKey.changedFields] as? Set<String> ?? []
        if fields.contains(SelectionField.mailbox.rawValue) {
            // A different mailbox is a different list. Keeping the previous
            // clip origin would land in the middle of the new one.
            reload(preservingScroll: false)
            updateSearchHeaderVisibility()
            return
        }
        guard fields.contains(SelectionField.message.rawValue) else { return }
        revealSelection()
    }

    // MARK: - Contents

    func reload(preservingScroll: Bool = true) {
        // Days in Recent Mail are outline parents only so they can float;
        // indenting them would look like a hierarchy the timeline is not.
        // A conversation *is* a hierarchy, so folder mode turns indent on.
        outlineView.indentationPerLevel = (isShowingFolder && !isSearching) ? Self.conversationIndent : 0
        updateSearchHeaderVisibility()
        // Which conversations were open, so a reload — one arrives on every
        // save — does not collapse the thread the user is reading.
        let expanded = Set(folderRows.compactMap { row -> String? in
            guard let thread = row as? MailThreadRow, outlineView.isItemExpanded(thread) else {
                return nil
            }
            return thread.rows.first?.message.uuid.uuidString
        })

        let clipView = outlineView.enclosingScrollView?.contentView
        let savedOrigin = preservingScroll ? clipView?.bounds.origin : nil

        groups = makeGroups()
        folderRows = makeFolderRows()
        isApplyingProgrammaticSelection = true
        outlineView.reloadData()
        for group in groups { outlineView.expandItem(group) }
        for row in folderRows {
            guard let thread = row as? MailThreadRow,
                  let key = thread.rows.first?.message.uuid.uuidString,
                  expanded.contains(key)
            else { continue }
            outlineView.expandItem(thread)
        }
        // Don't scrollRowToVisible here: reloadData already jumped the clip
        // view, and the caller is about to put it back. A reveal-driven
        // scroll is what `plannerSelectionDidChange` is for.
        revealSelection(scroll: false)
        isApplyingProgrammaticSelection = false
        if let clipView, let savedOrigin {
            clipView.scroll(to: savedOrigin)
            outlineView.enclosingScrollView?.reflectScrolledClipView(clipView)
        } else if !preservingScroll, let clipView {
            // reloadData keeps the origin when the row count does not change.
            clipView.scroll(to: .zero)
            outlineView.enclosingScrollView?.reflectScrolledClipView(clipView)
        }
        updateEmptyState()
        if isShowingFolder {
            conversationChromeNeedsRefresh?()
        }
    }

    /// A folder's messages, threaded. Recomputed on every reload rather than
    /// stored: threading is a *view* of a folder, and a stored membership
    /// would need repairing on every save, move and remove.
    private func makeFolderRows() -> [NSObject] {
        guard let uuid = selection.selectedFolderUUID,
              let folder = model.mailFolders().first(where: { $0.uuid == uuid })
        else { return [] }

        let messages: [SavedMessage]
        do {
            messages = try model.messages(in: folder, matching: searchQuery)
            searchFetchFailed = false
        } catch {
            searchFetchFailed = true
            return []
        }
        if isSearching {
            return messages.map(SavedMessageRow.init)
        }

        let byUUID = Dictionary(uniqueKeysWithValues: messages.map { ($0.uuid, $0) })
        let threads = MailThreading.threads(messages.map(\.threadingMessage))

        return threads.compactMap { thread in
            let rows = thread.messages.compactMap { byUUID[$0.id].map(SavedMessageRow.init) }
            guard !rows.isEmpty else { return nil }
            // A conversation of one is just a message.
            guard rows.count > 1 else { return rows[0] }
            return MailThreadRow(
                subject: thread.subject,
                participants: MailLabels.threadParticipants(
                    rows.map(\.message.senderDisplayName)
                ),
                latest: thread.latestDate,
                rows: rows
            )
        }
    }

    private func makeGroups() -> [MailDateGroup] {
        guard selection.isRecentMailSelected else { return [] }
        let saved = model.foldersByOutlookID()
        var groups: [MailDateGroup] = []
        var currentDay: Date?
        var currentRows: [MailListRow] = []

        // The coordinator already sorted newest-first, so one pass is enough
        // and the list can never disagree with it about order.
        for message in mail.messages {
            let day = calendar.startOfDay(for: message.receivedAt)
            if day != currentDay {
                if let currentDay, !currentRows.isEmpty {
                    groups.append(makeGroup(day: currentDay, rows: currentRows))
                }
                currentDay = day
                currentRows = []
            }
            currentRows.append(MailListRow(
                message: message,
                savedFolderName: saved[message.id]?.name
            ))
        }
        if let currentDay, !currentRows.isEmpty {
            groups.append(makeGroup(day: currentDay, rows: currentRows))
        }
        return groups
    }

    private func makeGroup(day: Date, rows: [MailListRow]) -> MailDateGroup {
        MailDateGroup(
            day: day,
            title: MailLabels.dateGroupTitle(for: day, now: now(), calendar: calendar),
            rows: rows
        )
    }

    private func updateEmptyState() {
        let isEmpty = isShowingFolder
            ? folderRows.isEmpty
            : groups.allSatisfy { $0.rows.isEmpty }
        emptyStateLabel.isHidden = !isEmpty
        guard isEmpty else { return }
        switch selection.mailbox {
        case .recent:
            emptyStateLabel.stringValue = MailLabels.emptyRecentMail(
                days: mail.windowDays,
                hasSource: mail.sourceID != NullMailSource().sourceID
            )
        case .folder where searchFetchFailed:
            emptyStateLabel.stringValue = MailLabels.searchFailed
        case .folder where isSearching:
            emptyStateLabel.stringValue = MailLabels.emptySearch
        case .folder:
            emptyStateLabel.stringValue = MailLabels.emptyFolder(name: selectedFolderName ?? "")
        }
    }

    private var selectedFolderName: String? {
        guard let uuid = selection.selectedFolderUUID else { return nil }
        return model.mailFolders().first { $0.uuid == uuid }?.name
    }

    var messageCount: Int { groups.reduce(0) { $0 + $1.rows.count } }

    // MARK: - Selection

    /// The row that should stay selected after `current` leaves the list.
    /// Next remaining, then previous, then nothing — so Delete can be hit
    /// again and keep walking down the list.
    func messageToSelectAfterRemoving(_ current: MessageSelection) -> MessageSelection? {
        let ordered = visibleMessageSelections()
        guard let index = ordered.firstIndex(of: current) else { return nil }
        if index + 1 < ordered.count { return ordered[index + 1] }
        if index > 0 { return ordered[index - 1] }
        return nil
    }

    /// Selectable messages in visual order: Recent Mail newest-first, a
    /// folder in thread order. Date headers and conversation headings are
    /// not destinations, so they are not in this list.
    private func visibleMessageSelections() -> [MessageSelection] {
        if isShowingFolder {
            return folderRows.flatMap { row -> [MessageSelection] in
                switch row {
                case let saved as SavedMessageRow:
                    return [.saved(saved.message.uuid)]
                case let thread as MailThreadRow:
                    return thread.rows.map { .saved($0.message.uuid) }
                default:
                    return []
                }
            }
        }
        return groups.flatMap(\.rows).map { .recent($0.message.id) }
    }

    private func revealSelection(scroll: Bool = true) {
        switch selection.message {
        case nil:
            outlineView.deselectAll(nil)
        case let .recent(id)?:
            guard let row = groups.lazy.flatMap(\.rows).first(where: { $0.message.id == id }) else {
                return
            }
            select(item: row, scroll: scroll)
        case let .saved(uuid)?:
            guard let row = savedRow(uuid: uuid) else { return }
            // A message inside a collapsed conversation has no row until the
            // conversation opens, so revealing it opens the conversation.
            if let thread = thread(containing: row) { outlineView.expandItem(thread) }
            select(item: row, scroll: scroll)
        }
    }

    private func select(item: Any, scroll: Bool = true) {
        let index = outlineView.row(forItem: item)
        guard index >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        if scroll { outlineView.scrollRowToVisible(index) }
    }

    private func savedRow(uuid: UUID) -> SavedMessageRow? {
        for row in folderRows {
            if let saved = row as? SavedMessageRow, saved.message.uuid == uuid { return saved }
            if let thread = row as? MailThreadRow,
               let match = thread.rows.first(where: { $0.message.uuid == uuid }) {
                return match
            }
        }
        return nil
    }

    private func thread(containing row: SavedMessageRow) -> MailThreadRow? {
        folderRows.compactMap { $0 as? MailThreadRow }.first { $0.rows.contains(row) }
    }

    /// Selecting a conversation opens its newest message: a thread row is a
    /// heading, and landing on a heading with an empty reader would be a step
    /// backwards from clicking the message directly.
    private func publishSelection() {
        guard !isApplyingProgrammaticSelection else { return }
        switch outlineView.item(atRow: outlineView.selectedRow) {
        case let row as MailListRow:
            selection.selectMessage(.recent(row.message.id))
        case let row as SavedMessageRow:
            selection.selectMessage(.saved(row.message.uuid))
        case let thread as MailThreadRow:
            selection.selectMessage(.saved(thread.rows[0].message.uuid))
        default:
            selection.selectMessage(nil)
        }
    }

    /// The conversation the reader's "message k of n" line counts against.
    func conversation(containing uuid: UUID) -> [SavedMessage] {
        guard let row = savedRow(uuid: uuid) else { return [] }
        guard let thread = thread(containing: row) else { return [row.message] }
        return thread.rows.map(\.message)
    }

    // MARK: - Search

    private func updateSearchHeaderVisibility() {
        searchHeader.isHidden = selection.isRecentMailSelected
    }

    @objc private func searchFieldAction(_ sender: NSSearchField) {
        // Return / search button / cancel only — sendsWholeSearchString is true,
        // so this is not a keystroke.
        searchDebounce?.cancel()
        applySearch(sender.stringValue)
    }

    private func scheduleSearchApply(_ raw: String) {
        searchDebounce?.cancel()
        if SavedMessageSearch.tokens(in: raw).isEmpty {
            applySearch(raw)
            return
        }
        searchDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.applySearch(raw)
        }
    }

    private func applySearch(_ raw: String) {
        let nextTokens = SavedMessageSearch.tokens(in: raw)
        let currentTokens = SavedMessageSearch.tokens(in: searchQuery)
        // Raw `"ada"` → `"ada "` is the same predicate. Comparing strings would
        // still reload(preservingScroll: false) and jump the clip view.
        guard nextTokens != currentTokens else {
            searchQuery = raw
            return
        }
        searchQuery = raw
        reload(preservingScroll: false)
        if isSearching, case let .saved(uuid)? = selection.message, savedRow(uuid: uuid) == nil {
            selection.selectMessage(nil)
        }
    }

    func clearSearch(resigning: Bool) {
        searchDebounce?.cancel()
        searchField.stringValue = ""
        applySearch("")
        if resigning {
            view.window?.makeFirstResponder(outlineView)
        }
    }
}

extension MailListViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === searchField else { return }
        scheduleSearchApply(searchField.stringValue)
    }
}

extension MailListViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return isShowingFolder ? folderRows.count : groups.count }
        switch item {
        case let group as MailDateGroup: return group.rows.count
        case let thread as MailThreadRow: return thread.rows.count
        default: return 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is MailDateGroup || item is MailThreadRow
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else { return isShowingFolder ? folderRows[index] : groups[index] }
        switch item {
        case let group as MailDateGroup: return group.rows[index]
        case let thread as MailThreadRow: return thread.rows[index]
        default: preconditionFailure("unknown mail list item")
        }
    }
}

extension MailListViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is MailDateGroup
    }

    /// Group rows are labels, not destinations: arrowing through the list
    /// should move between messages.
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        !(item is MailDateGroup)
    }

    /// No disclosure triangle on a day header: with zero indentation it draws
    /// over the title, and it offers a collapse the timeline never wants.
    /// Conversations keep theirs — expanding in place is their whole point.
    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        !(item is MailDateGroup)
    }

    /// The triangle is gone, but collapse has other doors (double-click, ⌘←).
    /// A collapsed day with no way to reopen it reads as lost mail.
    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        !(item is MailDateGroup)
    }

    /// Two heights, because some rows carry a third line and some do not: a
    /// "Saved to X" chip and a conversation's message count both sit under the
    /// subject, and a fixed height tall enough for them would leave every plain
    /// row padded.
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        switch item {
        // 18 matches the calendar's day-header band, so the two modes' headers
        // read as the same weight of chrome.
        case is MailDateGroup: return 18
        case let row as MailListRow: return row.savedFolderName == nil ? 54 : 68
        case is MailThreadRow: return 68
        default: return 54
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? MailDateGroup {
            let identifier = NSUserInterfaceItemIdentifier("DateGroup")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? DateGroupCellView
                ?? makeDateGroupCell(identifier: identifier)
            cell.textField?.stringValue = group.title
            // The line divides a day from the one above; the first day has
            // nothing above it to divide from.
            cell.separator.isHidden = group === groups.first
            return cell
        }

        let identifier = NSUserInterfaceItemIdentifier("MessageRow")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? MessageRowView
            ?? makeMessageRowCell(identifier: identifier)

        switch item {
        case let row as MailListRow:
            cell.apply(row, calendar: calendar)
        case let thread as MailThreadRow:
            cell.apply(thread, calendar: calendar)
        case let row as SavedMessageRow:
            cell.apply(row, calendar: calendar, inConversation: thread(containing: row) != nil)
        default:
            return nil
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        publishSelection()
    }

    private func makeDateGroupCell(identifier: NSUserInterfaceItemIdentifier) -> DateGroupCellView {
        let cell = DateGroupCellView()
        cell.identifier = identifier
        cell.build()
        return cell
    }

    private func makeMessageRowCell(identifier: NSUserInterfaceItemIdentifier) -> MessageRowView {
        let cell = MessageRowView()
        cell.identifier = identifier
        cell.build()
        return cell
    }
}

/// A day's sticky header: the title, with a hairline along the top that
/// separates the day from the one before it as the list scrolls.
private final class DateGroupCellView: NSTableCellView {
    let separator = NSBox()

    func build() {
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 11, weight: .semibold)
        field.textColor = .secondaryLabelColor
        field.refusesFirstResponder = true
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        textField = field

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}

/// One message: an unread dot, the sender and time on the first line, the
/// subject on the second, and a "Saved to X" chip on the third when there is
/// one.
///
/// No preview snippet, which the mock shows and the envelope cannot supply:
/// the M0 spike put a message's body behind a per-message fetch, so a snippet
/// per row would mean a round trip per visible row. The subject is what the
/// sweep is read on anyway.
private final class MessageRowView: NSTableCellView {
    private let unreadDot = NSView()
    /// Vertical tick in the unread-dot slot, for a message that belongs to
    /// the conversation header above it. Saved rows have no unread state, so
    /// the slot is free.
    private let conversationTick = NSView()
    private let senderField = NSTextField(labelWithString: "")
    private let timeField = NSTextField(labelWithString: "")
    private let subjectField = NSTextField(labelWithString: "")
    private let savedChip = NSTextField(labelWithString: "")
    /// The subject is what the sweep is read on, so message rows show it in
    /// the primary label color. A thread row reuses the field for its
    /// participants, which stay secondary — the subject is already on top.
    private var subjectIsSecondary = false

    func build() {
        unreadDot.wantsLayer = true
        unreadDot.layer?.cornerRadius = 4
        unreadDot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        unreadDot.translatesAutoresizingMaskIntoConstraints = false

        conversationTick.wantsLayer = true
        conversationTick.layer?.cornerRadius = 1
        conversationTick.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        conversationTick.isHidden = true
        conversationTick.translatesAutoresizingMaskIntoConstraints = false

        senderField.font = .systemFont(ofSize: 13, weight: .semibold)
        senderField.lineBreakMode = .byTruncatingTail
        senderField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Tabular figures so a column of times does not shimmer as it scrolls.
        timeField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeField.textColor = .secondaryLabelColor
        timeField.alignment = .right
        timeField.setContentHuggingPriority(.required, for: .horizontal)
        timeField.setContentCompressionResistancePriority(.required, for: .horizontal)

        subjectField.font = .systemFont(ofSize: 13)
        subjectField.lineBreakMode = .byTruncatingTail

        savedChip.font = .systemFont(ofSize: 11, weight: .medium)
        savedChip.textColor = .secondaryLabelColor
        savedChip.lineBreakMode = .byTruncatingTail

        let topRow = NSStackView(views: [senderField, timeField])
        topRow.orientation = .horizontal
        topRow.alignment = .firstBaseline
        topRow.spacing = 8
        topRow.distribution = .fill

        let lines = NSStackView(views: [topRow, subjectField, savedChip])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 2
        lines.detachesHiddenViews = true

        let leadingSlot = NSView()
        leadingSlot.translatesAutoresizingMaskIntoConstraints = false
        leadingSlot.addSubview(unreadDot)
        leadingSlot.addSubview(conversationTick)

        let stack = NSStackView(views: [leadingSlot, lines])
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 6
        // A hidden dot keeps its slot: read and unread rows then share one
        // leading edge, instead of read rows sliding left by the dot's width.
        stack.detachesHiddenViews = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        textField = subjectField

        NSLayoutConstraint.activate([
            leadingSlot.widthAnchor.constraint(equalToConstant: 8),
            unreadDot.widthAnchor.constraint(equalToConstant: 8),
            unreadDot.heightAnchor.constraint(equalToConstant: 8),
            unreadDot.topAnchor.constraint(equalTo: leadingSlot.topAnchor, constant: 4),
            unreadDot.centerXAnchor.constraint(equalTo: leadingSlot.centerXAnchor),
            conversationTick.widthAnchor.constraint(equalToConstant: 2),
            conversationTick.heightAnchor.constraint(equalToConstant: 28),
            conversationTick.topAnchor.constraint(equalTo: leadingSlot.topAnchor),
            conversationTick.centerXAnchor.constraint(equalTo: leadingSlot.centerXAnchor),
            leadingSlot.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            // Pinned to the cell's trailing edge rather than left at its natural
            // width: a stack is only as wide as its widest line, which would put
            // the time at a different x in every row. Full width plus the
            // right-aligned time field is what makes the times a column.
            lines.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            topRow.widthAnchor.constraint(equalTo: lines.widthAnchor),
        ])
    }

    func apply(_ row: MailListRow, calendar: Calendar) {
        let message = row.message
        senderField.stringValue = message.senderDisplayName
        timeField.stringValue = MailLabels.listTime(for: message.receivedAt, calendar: calendar)
        subjectField.stringValue = message.subject.isEmpty ? "(No subject)" : message.subject
        subjectIsSecondary = false
        unreadDot.isHidden = message.isRead
        conversationTick.isHidden = true

        if let folder = row.savedFolderName {
            savedChip.stringValue = MailLabels.savedChip(folderName: folder)
            savedChip.isHidden = false
        } else {
            savedChip.isHidden = true
        }

        // Already-saved messages dim rather than disappear: the point of the
        // list is a timeline you sweep, and a hole in it loses your place.
        let dimmed = row.savedFolderName != nil
        alphaValue = dimmed ? 0.55 : 1
        refreshColors()

        setAccessibilityLabel(MailLabels.messageAccessibilityLabel(
            sender: message.senderDisplayName,
            subject: message.subject,
            receivedAt: message.receivedAt,
            isRead: message.isRead,
            savedFolderName: row.savedFolderName,
            calendar: calendar
        ))
    }

    /// A conversation heading: subject on top, participants below, the count
    /// where the unread dot would be, and the latest date on the right.
    func apply(_ thread: MailThreadRow, calendar: Calendar) {
        senderField.stringValue = thread.subject
        timeField.stringValue = MailLabels.listTime(for: thread.latest, calendar: calendar)
        subjectField.stringValue = thread.participants
        subjectIsSecondary = true
        unreadDot.isHidden = true
        conversationTick.isHidden = true
        savedChip.stringValue = MailLabels.messageCount(thread.rows.count)
        savedChip.isHidden = false
        alphaValue = 1
        refreshColors()
        setAccessibilityLabel(MailLabels.threadAccessibilityLabel(
            subject: thread.subject,
            count: thread.rows.count,
            latest: thread.latest
        ))
    }

    /// A saved message. No unread dot — Planner never learns whether a saved
    /// copy has been read, and inventing one would be a claim it cannot make.
    /// A row under a conversation header gets a tick in that slot instead,
    /// so it reads as part of the thread and not as another top-level message.
    func apply(_ row: SavedMessageRow, calendar: Calendar, inConversation: Bool) {
        let message = row.message
        senderField.stringValue = message.senderDisplayName
        timeField.stringValue = MailLabels.listTime(for: message.receivedAt, calendar: calendar)
        subjectField.stringValue = message.subject.isEmpty ? "(No subject)" : message.subject
        subjectIsSecondary = false
        unreadDot.isHidden = true
        conversationTick.isHidden = !inConversation
        savedChip.isHidden = true
        alphaValue = 1
        refreshColors()
        var label = MailLabels.messageAccessibilityLabel(
            sender: message.senderDisplayName,
            subject: message.subject,
            receivedAt: message.receivedAt,
            isRead: true,
            savedFolderName: nil,
            calendar: calendar
        )
        if inConversation {
            label = "In conversation. \(label)"
        }
        setAccessibilityLabel(label)
    }

    var test_showsConversationTick: Bool { !conversationTick.isHidden }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { refreshColors() }
    }

    private func refreshColors() {
        let emphasized = backgroundStyle == .emphasized
        senderField.textColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
        subjectField.textColor = emphasized
            ? .alternateSelectedControlTextColor
            : (subjectIsSecondary ? .secondaryLabelColor : .labelColor)
        timeField.textColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        savedChip.textColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        unreadDot.layer?.backgroundColor = (emphasized ? NSColor.alternateSelectedControlTextColor : .controlAccentColor).cgColor
        conversationTick.layer?.backgroundColor = (emphasized
            ? NSColor.alternateSelectedControlTextColor
            : NSColor.tertiaryLabelColor).cgColor
    }
}

extension MailListViewController {
    var test_isEmptyStateVisible: Bool { !emptyStateLabel.isHidden }
    var test_emptyStateText: String { emptyStateLabel.stringValue }
    var test_groupTitles: [String] { groups.map(\.title) }
    var test_rows: [MailListRow] { groups.flatMap(\.rows) }
    var test_folderRows: [NSObject] { folderRows }
    var test_threadSubjects: [String] {
        folderRows.compactMap { ($0 as? MailThreadRow)?.subject }
    }
    var test_indentationPerLevel: CGFloat { outlineView.indentationPerLevel }
    var test_scrollOrigin: NSPoint {
        outlineView.enclosingScrollView?.contentView.bounds.origin ?? .zero
    }
    func test_showsConversationTick(for item: Any) -> Bool {
        let row = outlineView.row(forItem: item)
        guard row >= 0,
              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? MessageRowView
        else { return false }
        return cell.test_showsConversationTick
    }
    var test_searchFieldIsHidden: Bool { searchHeader.isHidden }
    var test_searchQuery: String { searchQuery }
    var test_searchFetchFailed: Bool { searchFetchFailed }
    var test_searchFieldMaximumRecents: Int { searchField.maximumRecents }
    func test_applySearch(_ raw: String) { applySearch(raw) }
    func test_clearSearch(resigning: Bool) { clearSearch(resigning: resigning) }
}
