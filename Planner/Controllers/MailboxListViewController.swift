import AppKit
import CoreData

/// Stands in for "Recent Mail" in the sidebar's item list.
///
/// `NSOutlineView` addresses rows by object identity, and Recent Mail is not a
/// row in the store — it is a view over a foreign feed. A singleton sentinel
/// keeps the data source honest about that rather than inventing a placeholder
/// `MailFolder` that would then have to be excluded from every fetch.
final class RecentMailbox: NSObject {
    static let shared = RecentMailbox()
    private override init() { super.init() }
}

/// The mail sidebar: Recent Mail, then the user's folders.
///
/// Shaped like `OutlineViewController` — source-list style, delayed-click and
/// Return-to-rename, inline editing through `TitleTextField` — but flat. A mail
/// folder has no parent and no children: nesting would be a second tree to keep
/// honest, and triage does not need one.
final class MailboxListViewController: NSViewController {
    let persistence: PersistenceController
    let model: ModelController
    let selection: SelectionModel
    let mail: MailCoordinator
    let outlineView = MailboxOutlineView()

    private let emptyStateLabel = NSTextField(labelWithString: "No Folders — ⇧⌘N to add one.")
    private var folders: [MailFolder] = []
    private var isApplyingProgrammaticSelection = false
    private var renameTimer: Timer?
    private(set) var renameGeneration = 0
    private weak var editingField: TitleTextField?
    private var isCancellingTitleEdit = false

    /// Tests observe begin-edit attempts; `editColumn` requires a window.
    var beginEditingNameHandler: ((MailFolder) -> Void)?

    init(
        persistence: PersistenceController,
        model: ModelController,
        selection: SelectionModel,
        mail: MailCoordinator
    ) {
        self.persistence = persistence
        self.model = model
        self.selection = selection
        self.mail = mail
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

        let headerLabel = NSTextField(labelWithString: "Mailboxes")
        headerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        // The sidebar split item supplies the vibrant material; a plain host
        // view lets it through instead of stacking a second effect view on it.
        let root = NSView()
        root.addSubview(headerLabel)
        root.addSubview(scrollView)
        root.addSubview(emptyStateLabel)
        view = root

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 4),
            headerLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 3),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            // Below Recent Mail rather than centred: there is always one row, so
            // a centred message would collide with it.
            emptyStateLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyStateLabel.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 44),
            emptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 16),
            emptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureOutlineView()
        startObserving()
        reloadFromStore()
    }

    private func configureOutlineView() {
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .custom
        outlineView.rowHeight = 24
        outlineView.intercellSpacing = NSSize(width: 17, height: 2)
        outlineView.headerView = nil
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.indentationPerLevel = 0
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = false
        outlineView.floatsGroupRows = false
        outlineView.focusRingType = .none
        outlineView.backgroundColor = .clear
        outlineView.action = #selector(singleClicked)
        outlineView.target = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Name"))
        column.title = "Name"
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
    }

    private func startObserving() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(contextDidSave(_:)),
            name: .NSManagedObjectContextDidSave,
            object: persistence.viewContext
        )
        center.addObserver(
            self,
            selector: #selector(contextObjectsDidChange(_:)),
            name: .NSManagedObjectContextObjectsDidChange,
            object: persistence.viewContext
        )
        center.addObserver(
            self,
            selector: #selector(plannerSelectionDidChange(_:)),
            name: .plannerSelectionDidChange,
            object: selection
        )
        // The Recent Mail row carries a count, so it has to redraw when the
        // sweep lands.
        center.addObserver(
            self,
            selector: #selector(mailDidChange(_:)),
            name: .plannerMailDidChange,
            object: mail
        )
    }

    // MARK: - Store → sidebar

    func reloadFromStore() {
        folders = model.mailFolders()
        isApplyingProgrammaticSelection = true
        outlineView.reloadData()
        revealSelection(makeFirstResponder: false)
        isApplyingProgrammaticSelection = false
        updateEmptyState()
    }

    private func updateEmptyState() {
        emptyStateLabel.isHidden = !folders.isEmpty
    }

    /// Folder rows carry a message count, so a save that only moved messages
    /// still changes what the sidebar says.
    @objc private func contextDidSave(_ notification: Notification) {
        reloadFromStore()
    }

    @objc private func contextObjectsDidChange(_ notification: Notification) {
        guard outlineView.currentEditor() == nil else { return }
        let changed = objects(in: notification, key: NSUpdatedObjectsKey)
            + objects(in: notification, key: NSRefreshedObjectsKey)
        for object in changed where object is MailFolder || object is SavedMessage {
            reloadRows()
            return
        }
    }

    @objc private func mailDidChange(_ notification: Notification) {
        let row = outlineView.row(forItem: RecentMailbox.shared)
        guard row >= 0 else { return }
        outlineView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
    }

    private func reloadRows() {
        let selected = outlineView.selectedRowIndexes
        outlineView.reloadData()
        outlineView.selectRowIndexes(selected, byExtendingSelection: false)
    }

    private func objects(in notification: Notification, key: String) -> [NSManagedObject] {
        guard let set = notification.userInfo?[key] as? Set<NSManagedObject> else { return [] }
        return Array(set)
    }

    // MARK: - Selection

    @objc private func plannerSelectionDidChange(_ notification: Notification) {
        let fields = notification.userInfo?[SelectionUserInfoKey.changedFields] as? Set<String> ?? []
        guard fields.contains(SelectionField.mailbox.rawValue) else { return }
        isApplyingProgrammaticSelection = true
        revealSelection(makeFirstResponder: true)
        isApplyingProgrammaticSelection = false
    }

    private func revealSelection(makeFirstResponder: Bool) {
        let item: Any
        if let uuid = selection.selectedFolderUUID,
           let folder = folders.first(where: { $0.uuid == uuid }) {
            item = folder
        } else {
            item = RecentMailbox.shared
        }
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        if makeFirstResponder {
            view.window?.makeFirstResponder(outlineView)
        }
    }

    private func publishSelection() {
        guard !isApplyingProgrammaticSelection else { return }
        switch outlineView.item(atRow: outlineView.selectedRow) {
        case let folder as MailFolder:
            selection.selectMailbox(.folder(folder.uuid))
        default:
            // Including nothing selected: the sidebar always has a mailbox, and
            // Recent Mail is the one that is always there.
            selection.selectMailbox(.recent)
        }
    }

    var selectedFolder: MailFolder? {
        outlineView.item(atRow: outlineView.selectedRow) as? MailFolder
    }

    func folder(uuid: UUID) -> MailFolder? {
        folders.first { $0.uuid == uuid }
    }

    // MARK: - Inline rename

    @objc private func singleClicked() {
        defer { outlineView.pendingRenameRow = -1 }
        guard let event = NSApp.currentEvent, event.clickCount == 1 else { return }
        let clickLocation = outlineView.convert(event.locationInWindow, from: nil)
        if outlineView.hasDraggedPastThreshold(to: clickLocation) {
            outlineView.cancelPendingRenameGesture()
            return
        }
        let row = outlineView.clickedRow
        guard outlineView.pendingRenameRow == row,
              row >= 0,
              outlineView.item(atRow: row) is MailFolder,
              outlineView.currentEditor() == nil,
              isClickInsideNameField(row: row)
        else { return }

        scheduleDelayedRename(at: row)
    }

    func scheduleDelayedRename(at row: Int) {
        cancelPendingRename()
        let generation = renameGeneration
        renameTimer = Timer.scheduledTimer(withTimeInterval: Self.renameDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.renameTimerFired(row: row, generation: generation)
            }
        }
    }

    func renameTimerFired(row: Int, generation: Int) {
        guard generation == renameGeneration else { return }
        renameTimer = nil
        guard outlineView.currentEditor() == nil,
              row >= 0,
              row == outlineView.selectedRow,
              let folder = outlineView.item(atRow: row) as? MailFolder
        else { return }
        beginEditingName(of: folder)
    }

    private static var renameDelay: TimeInterval {
        max(0.5, NSEvent.doubleClickInterval + 0.05)
    }

    private func isClickInsideNameField(row: Int) -> Bool {
        guard let event = NSApp.currentEvent,
              let field = nameField(atRow: row, makeIfNecessary: false)
        else { return false }
        let locationInOutline = outlineView.convert(event.locationInWindow, from: nil)
        let locationInField = field.convert(locationInOutline, from: outlineView)
        return field.bounds.contains(locationInField)
    }

    func cancelPendingRename() {
        renameGeneration += 1
        renameTimer?.invalidate()
        renameTimer = nil
    }

    func beginEditingSelectedName() {
        guard let folder = selectedFolder else { return }
        beginEditingName(of: folder)
    }

    /// Recent Mail is not renamable, so the caller passes a folder.
    func beginEditingName(of folder: MailFolder) {
        cancelPendingRename()
        beginEditingNameHandler?(folder)
        let row = outlineView.row(forItem: folder)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        guard let field = nameField(atRow: row, makeIfNecessary: true) else { return }
        field.allowsFirstResponder = true
        editingField = field
        outlineView.editColumn(0, row: row, with: nil, select: true)
        if outlineView.currentEditor() == nil {
            endNameEditing()
        }
    }

    func endNameEditing() {
        editingField?.allowsFirstResponder = false
        editingField = nil
        for row in 0..<outlineView.numberOfRows {
            nameField(atRow: row, makeIfNecessary: false)?.allowsFirstResponder = false
        }
    }

    private func nameField(atRow row: Int, makeIfNecessary: Bool) -> TitleTextField? {
        (outlineView.view(atColumn: 0, row: row, makeIfNecessary: makeIfNecessary) as? NSTableCellView)?
            .textField as? TitleTextField
    }

    private func folder(for field: NSView) -> MailFolder? {
        let row = outlineView.row(for: field)
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? MailFolder
    }
}

extension MailboxListViewController: NSOutlineViewDataSource {
    /// One flat level: Recent Mail, then the folders in list order.
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? folders.count + 1 : 0
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        index == 0 ? RecentMailbox.shared : folders[index - 1]
    }
}

extension MailboxListViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("MailboxCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? MailboxCellView
            ?? makeMailboxCell(identifier: identifier)
        (cell.textField as? TitleTextField)?.allowsFirstResponder = false

        if let folder = item as? MailFolder {
            cell.apply(
                name: folder.name,
                symbol: "folder",
                count: folder.messages.count,
                isEditable: true
            )
        } else {
            cell.apply(
                name: MailLabels.recentMailName,
                symbol: "tray",
                count: mail.messages.count,
                isEditable: false
            )
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        cancelPendingRename()
        publishSelection()
    }

    private func makeMailboxCell(identifier: NSUserInterfaceItemIdentifier) -> MailboxCellView {
        let cell = MailboxCellView()
        cell.identifier = identifier

        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .controlAccentColor
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
        ])

        let field = TitleTextField()
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.cell?.sendsActionOnEndEditing = true
        field.allowsFirstResponder = false
        field.delegate = self

        // Trailing count, the way a mail sidebar always carries one: it is the
        // only thing that says whether filing is working.
        let countLabel = NSTextField(labelWithString: "")
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.lineBreakMode = .byClipping
        countLabel.refusesFirstResponder = true
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView(views: [icon, field, countLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        cell.textField = field
        cell.iconView = icon
        cell.countLabel = countLabel

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

private final class MailboxCellView: NSTableCellView {
    var iconView: NSImageView!
    var countLabel: NSTextField!
    private var count = 0

    func apply(name: String, symbol: String, count: Int, isEditable: Bool) {
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        textField?.stringValue = name
        textField?.isEditable = isEditable
        self.count = count
        refreshCount()
        setAccessibilityLabel(MailLabels.mailboxAccessibilityLabel(name: name, count: count))
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { refreshCount() }
    }

    private func refreshCount() {
        countLabel.stringValue = count == 0 ? "" : "\(count)"
        // On an emphasized row the accent fill sits behind the text, so the
        // secondary grey would be unreadable.
        countLabel.textColor = backgroundStyle == .emphasized
            ? .alternateSelectedControlTextColor
            : .secondaryLabelColor
    }
}

extension MailboxListViewController: NSTextFieldDelegate {
    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        let trimmed = fieldEditor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            NSSound.beep()
            return false
        }
        return true
    }

    func controlTextDidEndEditing(_ note: Notification) {
        defer { endNameEditing() }
        guard !isCancellingTitleEdit,
              let field = note.object as? TitleTextField,
              let folder = folder(for: field)
        else { return }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != folder.name else { return }
        try? model.renameMailFolder(folder, to: trimmed)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard commandSelector == #selector(cancelOperation(_:)) else { return false }
        isCancellingTitleEdit = true
        control.abortEditing()
        if let field = control as? TitleTextField, let folder = folder(for: field) {
            field.stringValue = folder.name
        }
        endNameEditing()
        isCancellingTitleEdit = false
        return true
    }
}

extension MailboxListViewController {
    var test_isEmptyStateVisible: Bool { !emptyStateLabel.isHidden }
}
