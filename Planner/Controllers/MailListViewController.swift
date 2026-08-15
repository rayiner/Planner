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
    let outlineView = NSOutlineView()

    private let calendar: Calendar
    private let now: () -> Date
    private let emptyStateLabel = NSTextField(labelWithString: "")
    private var groups: [MailDateGroup] = []
    private var isApplyingProgrammaticSelection = false

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
        groups = makeGroups()
        isApplyingProgrammaticSelection = true
        outlineView.reloadData()
        for group in groups { outlineView.expandItem(group) }
        revealSelection()
        isApplyingProgrammaticSelection = false
        updateEmptyState()
    }

    /// Recent Mail only, for now: a folder's threaded list arrives with saving.
    private func makeGroups() -> [MailDateGroup] {
        guard selection.isRecentMailSelected else { return [] }
        let saved = model.foldersByMessageID()
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
                // The envelope has no Message-ID — headers are lazy — so the
                // synthetic id is the only key Recent Mail can match on. That
                // is also what `saveMessage` stores for a header-less message,
                // so a save made from this list matches itself.
                savedFolderName: saved[ModelController.normalizedMessageID(nil, fallbackFor: message)]?.name
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
        let isEmpty = groups.allSatisfy { $0.rows.isEmpty }
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
        guard case let .recent(id)? = selection.message else {
            if selection.message == nil { outlineView.deselectAll(nil) }
            return
        }
        guard let row = groups.lazy
            .flatMap(\.rows)
            .first(where: { $0.message.id == id })
        else { return }
        let index = outlineView.row(forItem: row)
        guard index >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        outlineView.scrollRowToVisible(index)
    }

    private func publishSelection() {
        guard !isApplyingProgrammaticSelection else { return }
        guard let row = outlineView.item(atRow: outlineView.selectedRow) as? MailListRow else {
            selection.selectMessage(nil)
            return
        }
        selection.selectMessage(.recent(row.message.id))
    }
}

extension MailListViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return groups.count }
        return (item as? MailDateGroup)?.rows.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is MailDateGroup
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else { return groups[index] }
        return (item as! MailDateGroup).rows[index]
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

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        item is MailDateGroup ? 24 : 54
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? MailDateGroup {
            let identifier = NSUserInterfaceItemIdentifier("DateGroup")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
                ?? makeDateGroupCell(identifier: identifier)
            cell.textField?.stringValue = group.title
            return cell
        }

        guard let row = item as? MailListRow else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("MessageRow")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? MessageRowView
            ?? makeMessageRowCell(identifier: identifier)
        cell.apply(row, calendar: calendar)
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
}
