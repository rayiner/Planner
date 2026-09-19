import AppKit

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

    init(message: MailMessage) {
        self.message = message
    }
}

/// The message list: the selected mail field strictly chronologically, newest
/// first.
///
/// **No threading here, deliberately.** Recent Mail is a timeline you sweep,
/// and threading it would collapse the ordering that makes the sweep work.
final class MailListViewController: NSViewController {
    let selection: SelectionModel
    let mail: MailCoordinator
    let outlineView = MailListOutlineView()

    /// Three lines — sender and time, subject, one line of body — plus padding.
    private static let messageRowHeight: CGFloat = 72

    private let calendar: Calendar
    private let now: () -> Date
    private let emptyStateLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()
    private let saveSearchButton = NSButton(title: "Save…", target: nil, action: nil)
    private let searchHeader = NSView()
    private var groups: [MailDateGroup] = []
    private var isApplyingProgrammaticSelection = false

    private var searchQuery = ""
    private var manualSearchQuery = ""

    private var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(
        selection: SelectionModel,
        mail: MailCoordinator,
        calendar: Calendar = .current,
        now: @escaping () -> Date = { Date() }
    ) {
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
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)

        searchField.controlSize = .small
        searchField.sendsWholeSearchString = true
        searchField.sendsSearchStringImmediately = false
        searchField.placeholderString = MailLabels.searchPlaceholder
        searchField.maximumRecents = 0
        searchField.target = self
        searchField.action = #selector(searchFieldAction)
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        saveSearchButton.controlSize = .small
        saveSearchButton.bezelStyle = .rounded
        saveSearchButton.target = self
        saveSearchButton.action = #selector(saveQuickSearchAction)
        saveSearchButton.toolTip = "Save this query as a Quick Search"
        saveSearchButton.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        searchHeader.translatesAutoresizingMaskIntoConstraints = false
        searchHeader.addSubview(searchField)
        searchHeader.addSubview(saveSearchButton)
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
        stack.distribution = .fill
        stack.spacing = 0
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false

        let root = MailListPaneView()
        root.list = self
        root.addSubview(stack)
        root.addSubview(emptyStateLabel)
        view = root

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: searchHeader.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: saveSearchButton.leadingAnchor, constant: -6),
            searchField.topAnchor.constraint(equalTo: searchHeader.topAnchor, constant: 6),
            searchField.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -6),
            saveSearchButton.trailingAnchor.constraint(equalTo: searchHeader.trailingAnchor, constant: -8),
            saveSearchButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
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
        outlineView.rowHeight = Self.messageRowHeight
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.headerView = nil
        outlineView.usesAlternatingRowBackgroundColors = false
        // Date groups are structure, not hierarchy.
        outlineView.indentationPerLevel = 0
        outlineView.allowsMultipleSelection = true
        outlineView.allowsEmptySelection = true
        // The whole point of modelling days as parents: AppKit pins the group
        // row to the top of the scroll view while its day is on screen.
        outlineView.floatsGroupRows = true
        outlineView.focusRingType = .none
        outlineView.backgroundColor = .clear
        outlineView.target = self
        outlineView.doubleAction = #selector(openClickedMessage)

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
            selector: #selector(mailSearchDidChange(_:)),
            name: .plannerMailSearchDidChange,
            object: mail
        )
        center.addObserver(
            self,
            selector: #selector(plannerSelectionDidChange(_:)),
            name: .plannerSelectionDidChange,
            object: selection
        )
    }

    @objc private func mailDidChange(_ notification: Notification) { reload() }

    @objc private func mailSearchDidChange(_ notification: Notification) {
        switch selection.mailbox {
        case .search, .quickSearch: break
        case .recent: return
        }
        reload()
        guard isSearching, !selection.messages.isEmpty else { return }
        switch mail.searchState {
        case .loaded, .failed:
            let visible = Set(groups.lazy.flatMap(\.rows).map(\.message.id))
            let kept = selection.messages.filter {
                guard case let .recent(id) = $0 else { return false }
                return visible.contains(id)
            }
            if kept.count != selection.messages.count {
                selection.selectMessages(kept)
            }
        case .idle, .loading:
            break
        }
    }

    @objc private func plannerSelectionDidChange(_ notification: Notification) {
        let fields = notification.userInfo?[SelectionUserInfoKey.changedFields] as? Set<String> ?? []
        if fields.contains(SelectionField.mailbox.rawValue) {
            activateSelectedMailbox()
            reload(preservingScroll: false)
            return
        }
        guard fields.contains(SelectionField.message.rawValue) else { return }
        revealSelection()
    }

    // MARK: - Contents

    func reload(preservingScroll: Bool = true) {
        outlineView.indentationPerLevel = 0
        updateSearchHeaderVisibility()
        updateSaveSearchButton()
        let clipView = outlineView.enclosingScrollView?.contentView
        let savedOrigin = preservingScroll ? clipView?.bounds.origin : nil

        groups = makeGroups()
        isApplyingProgrammaticSelection = true
        outlineView.reloadData()
        for group in groups { outlineView.expandItem(group) }
        // Don't scrollRowToVisible here: reloadData already jumped the clip
        // view, and the caller is about to put it back. A reveal-driven
        // scroll is what `plannerSelectionDidChange` is for.
        revealSelection(scroll: false)
        isApplyingProgrammaticSelection = false
        pruneInvisibleSelection()
        if let clipView, let savedOrigin {
            clipView.scroll(to: savedOrigin)
            outlineView.enclosingScrollView?.reflectScrolledClipView(clipView)
        } else if !preservingScroll, let clipView {
            // reloadData keeps the origin when the row count does not change.
            clipView.scroll(to: .zero)
            outlineView.enclosingScrollView?.reflectScrolledClipView(clipView)
        }
        updateEmptyState()
    }

    private func makeGroups() -> [MailDateGroup] {
        var groups: [MailDateGroup] = []
        var currentDay: Date?
        var currentRows: [MailListRow] = []

        // The coordinator already sorted newest-first, so one pass is enough
        // and the list can never disagree with it about order.
        let messages: [MailMessage]
        switch selection.mailbox {
        case .recent: messages = mail.messages
        case .search: messages = isSearching ? mail.searchResults : []
        case .quickSearch: messages = mail.searchResults
        }
        for message in messages {
            let day = calendar.startOfDay(for: message.receivedAt)
            if day != currentDay {
                if let currentDay, !currentRows.isEmpty {
                    groups.append(makeGroup(day: currentDay, rows: currentRows))
                }
                currentDay = day
                currentRows = []
            }
            currentRows.append(MailListRow(message: message))
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
        let isEmpty = groups.allSatisfy { $0.rows.isEmpty }
        emptyStateLabel.isHidden = !isEmpty
        guard isEmpty else { return }
        let isSearchMailbox: Bool = {
            switch selection.mailbox {
            case .search, .quickSearch: return true
            case .recent: return false
            }
        }()
        if selection.mailbox == .search, !isSearching {
            emptyStateLabel.stringValue = MailLabels.emptySearchPrompt
        } else if isSearchMailbox, mail.searchState == .loading {
            emptyStateLabel.stringValue = MailLabels.searching
        } else if isSearchMailbox {
            switch mail.searchState {
            case .failed:
                emptyStateLabel.stringValue = MailLabels.searchFailed
            case .idle, .loading, .loaded:
                emptyStateLabel.stringValue = MailLabels.emptySearch
            }
        } else {
            emptyStateLabel.stringValue = MailLabels.emptyRecentMail(
                days: mail.windowDays,
                hasSource: mail.sourceID != NullMailSource().sourceID
            )
        }
    }

    var messageCount: Int { groups.reduce(0) { $0 + $1.rows.count } }

    /// A Hide, or turning Hidden back off, can drop the selected rows out of
    /// the list. Keep the model in step so the reader does not stay on a
    /// message that is no longer on screen. Skip this while a search is in
    /// flight: the list is empty only because the hits have not arrived yet.
    private func pruneInvisibleSelection() {
        guard !selection.messages.isEmpty else { return }
        switch selection.mailbox {
        case .search, .quickSearch:
            if mail.searchState == .loading { return }
        case .recent:
            break
        }
        let visibleIDs = Set(groups.lazy.flatMap(\.rows).map(\.message.id))
        let kept = selection.messages.filter {
            guard case let .recent(id) = $0 else { return false }
            return visibleIDs.contains(id)
        }
        if kept.count != selection.messages.count {
            selection.selectMessages(kept)
        }
    }

    // MARK: - Selection

    /// The row that should stay selected after `current` leaves the list.
    /// Next remaining, then previous, then nothing — so Delete can be hit
    /// again and keep walking down the list.
    func messageToSelectAfterMoving(_ current: MessageSelection) -> MessageSelection? {
        messageToSelectAfterMoving([current])
    }

    func messageToSelectAfterMoving(_ current: [MessageSelection]) -> MessageSelection? {
        let ordered = visibleMessageSelections()
        let removed = Set(current)
        guard let lastIndex = current.compactMap({ ordered.firstIndex(of: $0) }).max() else {
            return nil
        }
        if let next = ordered[(lastIndex + 1)...].first(where: { !removed.contains($0) }) {
            return next
        }
        return ordered[..<lastIndex].last(where: { !removed.contains($0) })
    }

    /// Selectable messages in visual order. Date headers are not destinations.
    private func visibleMessageSelections() -> [MessageSelection] {
        return groups.flatMap(\.rows).map { .recent($0.message.id) }
    }

    private func revealSelection(scroll: Bool = true) {
        let wasApplying = isApplyingProgrammaticSelection
        isApplyingProgrammaticSelection = true
        defer { if !wasApplying { isApplyingProgrammaticSelection = false } }
        let ids = Set(selection.messages.compactMap { item -> Int64? in
            guard case let .recent(id) = item else { return nil }
            return id
        })
        guard !ids.isEmpty else {
            outlineView.deselectAll(nil)
            return
        }
        var indexes = IndexSet()
        var primaryIndex: Int?
        for row in groups.flatMap(\.rows) {
            guard ids.contains(row.message.id) else { continue }
            let index = outlineView.row(forItem: row)
            guard index >= 0 else { continue }
            indexes.insert(index)
            if case let .recent(id)? = selection.message, row.message.id == id {
                primaryIndex = index
            }
        }
        outlineView.selectRowIndexes(indexes, byExtendingSelection: false)
        if scroll, let primaryIndex {
            outlineView.scrollRowToVisible(primaryIndex)
        }
    }

    private func publishSelection() {
        guard !isApplyingProgrammaticSelection else { return }
        var ordered: [MessageSelection] = []
        for row in outlineView.selectedRowIndexes.sorted() {
            guard let item = outlineView.item(atRow: row) as? MailListRow else { continue }
            ordered.append(.recent(item.message.id))
        }
        if outlineView.selectedRow >= 0,
           let item = outlineView.item(atRow: outlineView.selectedRow) as? MailListRow {
            let lastClicked = MessageSelection.recent(item.message.id)
            if let index = ordered.firstIndex(of: lastClicked) {
                ordered.remove(at: index)
                ordered.append(lastClicked)
            }
        }
        selection.selectMessages(ordered)
    }

    // MARK: - Search

    private func updateSearchHeaderVisibility() {
        searchHeader.isHidden = selection.mailbox != .search
    }

    private func activateSelectedMailbox() {
        switch selection.mailbox {
        case .search:
            searchQuery = manualSearchQuery
            mail.search(manualSearchQuery)
        case let .quickSearch(id):
            let query = mail.quickSearch(id: id)?.query ?? ""
            searchQuery = query
            mail.search(query)
        case .recent:
            searchQuery = ""
            mail.search("")
        }
    }

    @objc private func searchFieldAction(_ sender: NSSearchField) {
        // Return / search button / cancel only — sendsWholeSearchString is true,
        // so this is not a keystroke.
        applySearch(sender.stringValue)
    }

    private func applySearch(_ raw: String) {
        guard selection.mailbox == .search else { return }
        let next = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard next != current else {
            searchQuery = raw
            return
        }
        searchQuery = raw
        manualSearchQuery = raw
        mail.search(raw)
        reload(preservingScroll: false)
    }

    private func updateSaveSearchButton() {
        guard selection.mailbox == .search, isSearching else {
            saveSearchButton.isEnabled = false
            return
        }
        if case .loaded = mail.searchState {
            saveSearchButton.isEnabled = true
        } else {
            saveSearchButton.isEnabled = false
        }
    }

    @objc private func saveQuickSearchAction() {
        guard saveSearchButton.isEnabled, let window = view.window else { return }
        let nameField = NSTextField(string: "")
        nameField.placeholderString = "Name"
        nameField.frame.size = NSSize(width: 280, height: 24)

        let alert = NSAlert()
        alert.messageText = "Save Quick Search"
        alert.informativeText = "Choose a name for this search."
        alert.accessoryView = nameField
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self, weak nameField] response in
            guard response == .alertFirstButtonReturn, let self, let name = nameField?.stringValue else {
                return
            }
            MainActor.assumeIsolated {
                self.saveSearch(named: name)
            }
        }
        window.makeFirstResponder(nameField)
    }

    private func saveSearch(named name: String) {
        guard let saved = mail.saveQuickSearch(name: name, query: manualSearchQuery) else {
            NSSound.beep()
            return
        }
        selection.selectMailbox(.quickSearch(saved.id))
    }

    func clearSearch(resigning: Bool) {
        searchField.stringValue = ""
        applySearch("")
        if resigning {
            view.window?.makeFirstResponder(outlineView)
        }
    }

    func focusSearchField() {
        view.window?.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    /// The field itself or its (stock) field editor. Used so Find / Remove
    /// validation can see that Search is focused without a custom editor class.
    func isSearchFieldResponder(_ responder: NSResponder?) -> Bool {
        responder === searchField || responder === searchField.currentEditor()
    }

    /// ⌘F while the field is editing selects all. The window’s field editor
    /// would otherwise open Find on this one-line field.
    func handleFindKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, event.charactersIgnoringModifiers == "f" else { return false }
        guard searchField.currentEditor() != nil else { return false }
        searchField.currentEditor()?.selectAll(nil)
        return true
    }

    /// Outline Escape. Returns false so an empty query still reaches `super.keyDown`.
    func clearSearchFromOutline() -> Bool {
        guard isSearching else { return false }
        clearSearch(resigning: false)
        return true
    }
}

extension MailListViewController: NSSearchFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField,
              commandSelector == #selector(cancelOperation(_:)),
              searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        clearSearch(resigning: true)
        return true
    }
}

extension MailListViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return groups.count }
        switch item {
        case let group as MailDateGroup: return group.rows.count
        default: return 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is MailDateGroup
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else { return groups[index] }
        switch item {
        case let group as MailDateGroup: return group.rows[index]
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
    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        !(item is MailDateGroup)
    }

    /// The triangle is gone, but collapse has other doors (double-click, ⌘←).
    /// A collapsed day with no way to reopen it reads as lost mail.
    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        !(item is MailDateGroup)
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        switch item {
        // 18 matches the calendar's day-header band, so the two modes' headers
        // read as the same weight of chrome.
        case is MailDateGroup: return 18
        default: return Self.messageRowHeight
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
        default:
            return nil
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        publishSelection()
    }

    @objc private func openClickedMessage() {
        let row = outlineView.clickedRow
        guard row >= 0, outlineView.item(atRow: row) is MailListRow else { return }
        NSApp.sendAction(#selector(MainSplitViewController.openMailWindow(_:)), to: nil, from: self)
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

/// One message: an unread dot, sender and time, then subject, then one line of
/// the body.
private final class MessageRowView: NSTableCellView {
    private let unreadDot = NSView()
    private let senderField = NSTextField(labelWithString: "")
    private let timeField = NSTextField(labelWithString: "")
    private let subjectField = NSTextField(labelWithString: "")
    private let previewField = NSTextField(labelWithString: "")

    func build() {
        unreadDot.wantsLayer = true
        unreadDot.layer?.cornerRadius = 4
        unreadDot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        unreadDot.translatesAutoresizingMaskIntoConstraints = false

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

        previewField.font = .systemFont(ofSize: 12)
        previewField.textColor = .secondaryLabelColor
        previewField.lineBreakMode = .byTruncatingTail
        previewField.maximumNumberOfLines = 1

        let topRow = NSStackView(views: [senderField, timeField])
        topRow.orientation = .horizontal
        topRow.alignment = .firstBaseline
        topRow.spacing = 8
        topRow.distribution = .fill

        let lines = NSStackView(views: [topRow, subjectField, previewField])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 2
        lines.detachesHiddenViews = true

        let leadingSlot = NSView()
        leadingSlot.translatesAutoresizingMaskIntoConstraints = false
        leadingSlot.addSubview(unreadDot)

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
        // A message with no text part gets no placeholder line: the row keeps
        // its height either way, and an empty third line reads as a blank field
        // rather than as "this message has no body".
        previewField.stringValue = message.preview
        previewField.isHidden = message.preview.isEmpty
        unreadDot.isHidden = message.isRead
        alphaValue = 1
        refreshColors()

        setAccessibilityLabel(MailLabels.messageAccessibilityLabel(
            sender: message.senderDisplayName,
            subject: message.subject,
            receivedAt: message.receivedAt,
            isRead: message.isRead,
            calendar: calendar
        ))
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { refreshColors() }
    }

    var test_previewLine: String? {
        previewField.isHidden ? nil : previewField.stringValue
    }

    private func refreshColors() {
        let emphasized = backgroundStyle == .emphasized
        senderField.textColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
        subjectField.textColor = emphasized
            ? .alternateSelectedControlTextColor
            : .labelColor
        timeField.textColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        previewField.textColor = emphasized
            ? .alternateSelectedControlTextColor
            : .secondaryLabelColor
        unreadDot.layer?.backgroundColor = (emphasized ? NSColor.alternateSelectedControlTextColor : .controlAccentColor).cgColor
    }
}

extension MailListViewController {
    var test_isEmptyStateVisible: Bool { !emptyStateLabel.isHidden }
    var test_emptyStateText: String { emptyStateLabel.stringValue }
    var test_groupTitles: [String] { groups.map(\.title) }
    var test_rows: [MailListRow] { groups.flatMap(\.rows) }
    var test_indentationPerLevel: CGFloat { outlineView.indentationPerLevel }
    var test_scrollOrigin: NSPoint {
        outlineView.enclosingScrollView?.contentView.bounds.origin ?? .zero
    }
    func test_rowHeight(for item: Any) -> CGFloat {
        self.outlineView(outlineView, heightOfRowByItem: item)
    }
    /// The body line as the row renders it, or nil when the row hides it.
    func test_previewLine(for row: MailListRow) -> String? {
        let cell = self.outlineView(outlineView, viewFor: nil, item: row) as? MessageRowView
        return cell?.test_previewLine
    }
    var test_searchFieldIsHidden: Bool { searchHeader.isHidden }
    var test_searchQuery: String { searchQuery }
    var test_searchFieldMaximumRecents: Int { searchField.maximumRecents }
    var test_searchField: NSSearchField { searchField }
    var test_saveSearchIsEnabled: Bool { saveSearchButton.isEnabled }
    func test_applySearch(_ raw: String) { applySearch(raw) }
    func test_saveSearch(name: String) { saveSearch(named: name) }
    func test_clearSearch(resigning: Bool) { clearSearch(resigning: resigning) }
    func test_focusSearchField() { focusSearchField() }
}

/// Intercepts ⌘F before the stock field editor can open Find on the search field.
private final class MailListPaneView: NSView {
    weak var list: MailListViewController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if list?.handleFindKeyEquivalent(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}
