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
    private var groups: [MailDateGroup] = []
    /// Top-level rows in folder mode: thread parents and lone messages, mixed,
    /// ordered by their newest message.
    private var folderRows: [NSObject] = []
    private var isApplyingProgrammaticSelection = false

    private var isShowingFolder: Bool { !selection.isRecentMailSelected }

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

        emptyStateLabel.font = .systemFont(ofSize: 13, weight: .regular)
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.alignment = .center
        emptyStateLabel.maximumNumberOfLines = 0
        emptyStateLabel.lineBreakMode = .byWordWrapping
        emptyStateLabel.refusesFirstResponder = true
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(scrollView)
        root.addSubview(emptyStateLabel)
        view = root

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyStateLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -20),
            emptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 24),
            emptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
        ])
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
            reload()
            return
        }
        guard fields.contains(SelectionField.message.rawValue) else { return }
        revealSelection()
    }

    // MARK: - Contents

    func reload() {
        // Which conversations were open, so a reload — one arrives on every
        // save — does not collapse the thread the user is reading.
        let expanded = Set(folderRows.compactMap { row -> String? in
            guard let thread = row as? MailThreadRow, outlineView.isItemExpanded(thread) else {
                return nil
            }
            return thread.rows.first?.message.uuid.uuidString
        })

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
        revealSelection()
        isApplyingProgrammaticSelection = false
        updateEmptyState()
    }

    /// A folder's messages, threaded. Recomputed on every reload rather than
    /// stored: threading is a *view* of a folder, and a stored membership
    /// would need repairing on every save, move and remove.
    private func makeFolderRows() -> [NSObject] {
        guard let uuid = selection.selectedFolderUUID,
              let folder = model.mailFolders().first(where: { $0.uuid == uuid })
        else { return [] }

        let messages = model.messages(in: folder)
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

    private func revealSelection() {
        switch selection.message {
        case nil:
            outlineView.deselectAll(nil)
        case let .recent(id)?:
            guard let row = groups.lazy.flatMap(\.rows).first(where: { $0.message.id == id }) else {
                return
            }
            select(item: row)
        case let .saved(uuid)?:
            guard let row = savedRow(uuid: uuid) else { return }
            // A message inside a collapsed conversation has no row until the
            // conversation opens, so revealing it opens the conversation.
            if let thread = thread(containing: row) { outlineView.expandItem(thread) }
            select(item: row)
        }
    }

    private func select(item: Any) {
        let index = outlineView.row(forItem: item)
        guard index >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        outlineView.scrollRowToVisible(index)
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

    /// Two heights, because some rows carry a third line and some do not: a
    /// "Saved to X" chip and a conversation's message count both sit under the
    /// subject, and a fixed height tall enough for them would leave every plain
    /// row padded.
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        switch item {
        case is MailDateGroup: return 24
        case let row as MailListRow: return row.savedFolderName == nil ? 54 : 68
        case is MailThreadRow: return 68
        default: return 54
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? MailDateGroup {
            let identifier = NSUserInterfaceItemIdentifier("DateGroup")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
                ?? makeDateGroupCell(identifier: identifier)
            cell.textField?.stringValue = group.title
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
            cell.apply(row, calendar: calendar)
        default:
            return nil
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        publishSelection()
    }

    private func makeDateGroupCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 11, weight: .semibold)
        field.textColor = .secondaryLabelColor
        field.refusesFirstResponder = true
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            field.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func makeMessageRowCell(identifier: NSUserInterfaceItemIdentifier) -> MessageRowView {
        let cell = MessageRowView()
        cell.identifier = identifier
        cell.build()
        return cell
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
    private let senderField = NSTextField(labelWithString: "")
    private let timeField = NSTextField(labelWithString: "")
    private let subjectField = NSTextField(labelWithString: "")
    private let savedChip = NSTextField(labelWithString: "")

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

        subjectField.font = .systemFont(ofSize: 12)
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

        let stack = NSStackView(views: [unreadDot, lines])
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        textField = subjectField

        NSLayoutConstraint.activate([
            unreadDot.widthAnchor.constraint(equalToConstant: 8),
            unreadDot.heightAnchor.constraint(equalToConstant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            topRow.widthAnchor.constraint(equalTo: lines.widthAnchor),
        ])
    }

    func apply(_ row: MailListRow, calendar: Calendar) {
        let message = row.message
        senderField.stringValue = message.senderDisplayName
        timeField.stringValue = MailLabels.listTime(for: message.receivedAt, calendar: calendar)
        subjectField.stringValue = message.subject.isEmpty ? "(No subject)" : message.subject
        unreadDot.isHidden = message.isRead

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
        unreadDot.isHidden = true
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
    func apply(_ row: SavedMessageRow, calendar: Calendar) {
        let message = row.message
        senderField.stringValue = message.senderDisplayName
        timeField.stringValue = MailLabels.listTime(for: message.receivedAt, calendar: calendar)
        subjectField.stringValue = message.subject.isEmpty ? "(No subject)" : message.subject
        unreadDot.isHidden = true
        savedChip.isHidden = true
        alphaValue = 1
        refreshColors()
        setAccessibilityLabel(MailLabels.messageAccessibilityLabel(
            sender: message.senderDisplayName,
            subject: message.subject,
            receivedAt: message.receivedAt,
            isRead: true,
            savedFolderName: nil,
            calendar: calendar
        ))
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { refreshColors() }
    }

    private func refreshColors() {
        let emphasized = backgroundStyle == .emphasized
        senderField.textColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
        subjectField.textColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        timeField.textColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        savedChip.textColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        unreadDot.layer?.backgroundColor = (emphasized ? NSColor.alternateSelectedControlTextColor : .controlAccentColor).cgColor
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
}
