import AppKit
import CoreData

/// The one-line summary at the foot of the unified sidebar. It reports the
/// shared Outlook-backed feeds conservatively: "updated" means both mail and
/// calendar have completed, at the older of their two completion times.
struct OutlookSyncPresentation: Equatable {
    let text: String
    let toolTip: String?

    @MainActor
    init(
        events: EventCoordinator.State,
        mail: MailCoordinator.State,
        progress: OutlookSyncProgress? = nil
    ) {
        if Self.isLoading(events) || Self.isLoading(mail) {
            if let progress, progress.total > 0 {
                let done = progress.done.formatted()
                let total = progress.total.formatted()
                text = "Syncing Outlook… \(done) of \(total)"
                toolTip = progress.phase == "starting"
                    ? "Preparing to index \(total) Outlook items."
                    : "Indexed \(done) of \(total) Outlook items."
            } else {
                text = "Syncing Outlook…"
                toolTip = "Refreshing Outlook mail and calendar data."
            }
            return
        }

        let failures = [Self.failure(events), Self.failure(mail)].compactMap { $0 }
        if !failures.isEmpty {
            text = "Outlook sync failed"
            toolTip = failures.joined(separator: "\n")
            return
        }

        if case let .loaded(eventDate) = events,
           case let .loaded(mailDate) = mail
        {
            let date = min(eventDate, mailDate)
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            text = "Outlook updated \(formatter.string(from: date))"
            toolTip = "Mail and calendar data are current as of \(date.formatted(.dateTime))."
            return
        }

        text = "Waiting for Outlook sync"
        toolTip = "Planner has not finished loading both Outlook mail and calendar data."
    }

    @MainActor
    private static func isLoading(_ state: EventCoordinator.State) -> Bool {
        if case .loading = state { return true }
        return false
    }

    @MainActor
    private static func isLoading(_ state: MailCoordinator.State) -> Bool {
        if case .loading = state { return true }
        return false
    }

    @MainActor
    private static func failure(_ state: EventCoordinator.State) -> String? {
        if case let .failed(message) = state { return "Events: \(message)" }
        return nil
    }

    @MainActor
    private static func failure(_ state: MailCoordinator.State) -> String? {
        if case let .failed(message) = state { return "Mail: \(message)" }
        return nil
    }
}

/// A group header in the unified sidebar. `NSOutlineView` addresses rows by
/// object identity, so each section is a singleton.
final class SidebarSection: NSObject {
    static let projects = SidebarSection(title: "Projects")
    static let mail = SidebarSection(title: "Mail")

    let title: String

    private init(title: String) {
        self.title = title
        super.init()
    }
}

/// Stands in for Recent Mail in the sidebar.
final class RecentMailbox: NSObject {
    static let shared = RecentMailbox()
    private override init() { super.init() }
}

/// A whole-index mail search. Its list is empty until a query is executed.
final class SearchMailbox: NSObject {
    static let shared = SearchMailbox()
    private override init() { super.init() }
}

/// A user-named whole-index query.
final class QuickSearchMailbox: NSObject {
    let id: UUID
    var name: String

    init(search: MailQuickSearch) {
        id = search.id
        name = search.name
        super.init()
    }
}

/// A dimmed, unselectable hint shown while the Projects section is empty. A row
/// rather than an overlay label, so it sits exactly where the projects would
/// and never collides with the Mail section below.
final class SidebarPlaceholder: NSObject {
    static let noProjects = SidebarPlaceholder(text: "No Projects — ⌘N to add one.")

    let text: String

    private init(text: String) {
        self.text = text
        super.init()
    }
}

/// Footer separator without an opaque background, so the split item's sidebar
/// material remains continuous behind the status and terminal button.
private final class PlannerSidebarFooterView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

/// The unified navigation sidebar: a Projects section holding the task outline,
/// then a Mail section holding Recent and Hidden fields. One sidebar
/// for both modes — selecting a row switches the trailing panes to whichever
/// mode can show it.
final class OutlineViewController: NSViewController {
    static let expandedUUIDsKey = "outline.expandedUUIDs"

    let persistence: PersistenceController
    let model: ModelController
    let selection: SelectionModel
    let events: EventCoordinator
    let mail: MailCoordinator
    let outlineView = PlannerOutlineView()

    private let userDefaults: UserDefaults
    private let statusLabel = NSTextField(labelWithString: "")
    private let terminalButton = NSButton()
    private static let footerHeight: CGFloat = 32
    private var projects: [Project] = []
    private var quickSearchMailboxes: [QuickSearchMailbox] = []
    private var isApplyingProgrammaticSelection = false
    private var isUpdatingUI = false
    private var renameTimer: Timer?
    private(set) var renameGeneration = 0
    private weak var editingField: TitleTextField?
    private var isCancellingTitleEdit = false

    /// Tests observe begin-edit attempts; `editColumn` requires a window.
    var beginEditingTitleHandler: ((OutlineNode) -> Void)?

    init(
        persistence: PersistenceController,
        model: ModelController,
        selection: SelectionModel,
        events: EventCoordinator,
        mail: MailCoordinator,
        userDefaults: UserDefaults = .standard
    ) {
        self.persistence = persistence
        self.model = model
        self.selection = selection
        self.events = events
        self.mail = mail
        self.userDefaults = userDefaults
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

        // The sidebar split item supplies the vibrant material; a plain host view
        // lets it through instead of stacking a second effect view on top of it.
        // Section headers are group rows inside the outline, not chrome above it.
        let root = NSView()
        let footer = PlannerSidebarFooterView()
        footer.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(statusLabel)

        configureChromeButton(
            terminalButton,
            symbol: "terminal",
            tooltip: "Show or Hide Terminal (⌘⌃T)",
            action: #selector(MainSplitViewController.toggleTerminal(_:))
        )
        footer.addSubview(terminalButton)

        root.addSubview(scrollView)
        root.addSubview(footer)
        view = root

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: Self.footerHeight),

            statusLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            statusLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: terminalButton.leadingAnchor, constant: -4),

            terminalButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -6),
            terminalButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            terminalButton.widthAnchor.constraint(equalToConstant: 28),
            terminalButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureOutlineView()
        startObserving()
        reloadFromStore()
        updateOutlookStatus()
    }

    private func configureChromeButton(
        _ button: NSButton,
        symbol: String,
        tooltip: String,
        action: Selector
    ) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        button.action = action
        button.target = nil
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureOutlineView() {
        outlineView.dataSource = self
        outlineView.delegate = self
        // .sourceList gives the modern inset, rounded, accent-tinted row highlight.
        // Setting `style` is the whole fix; `selectionHighlightStyle = .sourceList`
        // is deprecated since macOS 12 and redundant once `style` is set.
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .custom
        outlineView.rowHeight = 21
        outlineView.intercellSpacing = NSSize(width: 17, height: 2)
        outlineView.headerView = nil
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.indentationPerLevel = 13
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.floatsGroupRows = false
        outlineView.focusRingType = .none
        outlineView.backgroundColor = .clear
        outlineView.action = #selector(outlineSingleClicked)
        outlineView.doubleAction = #selector(toggleClickedRow)
        outlineView.target = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Title"))
        column.title = "Title"
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
        // Both mail rows carry counts, so they redraw when the sweep lands.
        center.addObserver(
            self,
            selector: #selector(mailDidChange(_:)),
            name: .plannerMailDidChange,
            object: mail
        )
        center.addObserver(
            self,
            selector: #selector(eventsDidChange(_:)),
            name: .plannerEventsDidChange,
            object: events
        )
        center.addObserver(
            self,
            selector: #selector(mailDidChange(_:)),
            name: .plannerMailSearchDidChange,
            object: mail
        )
        center.addObserver(
            self,
            selector: #selector(outlookSyncProgressDidChange(_:)),
            name: OutlookSyncProgressReporter.didChangeNotification,
            object: nil
        )
    }

    // MARK: - Store → outline

    private func reloadFromStore() {
        let selectedUUID = selection.selectedNodeUUID
        projects = (try? model.allProjects()) ?? []
        if quickSearchMailboxes.isEmpty {
            quickSearchMailboxes = mail.quickSearches.map { QuickSearchMailbox(search: $0) }
        }
        isApplyingProgrammaticSelection = true
        outlineView.reloadData()
        restoreExpansion()
        if selection.mode == .mail {
            revealMailbox(makeFirstResponder: false)
        } else {
            reveal(uuid: selectedUUID, makeFirstResponder: false)
        }
        isApplyingProgrammaticSelection = false
    }

    @objc private func mailDidChange(_ notification: Notification) {
        updateOutlookStatus()
        let existing = Dictionary(uniqueKeysWithValues: quickSearchMailboxes.map { ($0.id, $0) })
        let updated = mail.quickSearches.map { search -> QuickSearchMailbox in
            if let mailbox = existing[search.id] {
                mailbox.name = search.name
                return mailbox
            }
            return QuickSearchMailbox(search: search)
        }
        let structureChanged = updated.map(\.id) != quickSearchMailboxes.map(\.id)
        quickSearchMailboxes = updated

        if case let .quickSearch(id) = selection.mailbox,
           !quickSearchMailboxes.contains(where: { $0.id == id }) {
            selection.selectMailbox(.search)
        }

        if structureChanged {
            outlineView.reloadItem(SidebarSection.mail, reloadChildren: true)
            outlineView.expandItem(SidebarSection.mail)
            if selection.mode == .mail { revealMailbox(makeFirstResponder: false) }
            return
        }

        let mailboxes = children(of: SidebarSection.mail)
        let rows = mailboxes
            .map { outlineView.row(forItem: $0) }
            .filter { $0 >= 0 }
        guard !rows.isEmpty else { return }
        outlineView.reloadData(
            forRowIndexes: IndexSet(rows),
            columnIndexes: IndexSet(integer: 0)
        )
    }

    @objc private func eventsDidChange(_ notification: Notification) {
        updateOutlookStatus()
    }

    @objc nonisolated private func outlookSyncProgressDidChange(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.updateOutlookStatus()
        }
    }

    private func updateOutlookStatus() {
        let presentation = OutlookSyncPresentation(
            events: events.state,
            mail: mail.state,
            progress: OutlookSyncProgressReporter.shared.current
        )
        statusLabel.stringValue = presentation.text
        statusLabel.toolTip = presentation.toolTip
        statusLabel.setAccessibilityLabel(presentation.text)
    }

    var test_outlookStatusText: String { statusLabel.stringValue }
    var test_outlookStatusToolTip: String? { statusLabel.toolTip }
    var test_terminalButton: NSButton { terminalButton }

    @objc private func contextDidSave(_ notification: Notification) {
        if notification.userInfo?[NSInvalidatedAllObjectsKey] != nil {
            reloadFromStore()
            return
        }

        let inserted = objects(in: notification, key: NSInsertedObjectsKey)
            .filter { !$0.objectID.isTemporaryID }
        let deleted = objects(in: notification, key: NSDeletedObjectsKey)

        let insertedProjects = inserted.compactMap { $0 as? Project }
        let insertedTasks = inserted.compactMap { $0 as? TaskItem }
        let deletedProjects = deleted.compactMap { $0 as? Project }
        let deletedTasks = deleted.compactMap { $0 as? TaskItem }

        if insertedProjects.isEmpty && insertedTasks.isEmpty
            && deletedProjects.isEmpty && deletedTasks.isEmpty {
            return
        }

        let hasInserts = !insertedProjects.isEmpty || !insertedTasks.isEmpty
        let hasDeletes = !deletedProjects.isEmpty || !deletedTasks.isEmpty
        if hasInserts && hasDeletes {
            reloadFromStore()
            return
        }

        if hasDeletes, applySurgicalDeletes(projects: deletedProjects, tasks: deletedTasks) {
            return
        }

        if applySurgicalInserts(
            projects: insertedProjects,
            tasks: insertedTasks,
            deletedProjects: deletedProjects,
            deletedTasks: deletedTasks
        ) {
            return
        }

        reloadFromStore()
    }

    @objc private func contextObjectsDidChange(_ notification: Notification) {
        if notification.userInfo?[NSInvalidatedAllObjectsKey] != nil {
            reloadFromStore()
            return
        }

        let updated = objects(in: notification, key: NSUpdatedObjectsKey)
        for object in updated {
            reloadDisplayIfNeeded(object)
        }
        let refreshed = objects(in: notification, key: NSRefreshedObjectsKey)
        for object in refreshed {
            if object is Project || object is TaskItem {
                outlineView.reloadItem(object)
            }
        }
    }

    private func applySurgicalInserts(
        projects insertedProjects: [Project],
        tasks insertedTasks: [TaskItem],
        deletedProjects: [Project],
        deletedTasks: [TaskItem]
    ) -> Bool {
        guard deletedProjects.isEmpty && deletedTasks.isEmpty else { return false }

        if !insertedProjects.isEmpty && insertedTasks.isEmpty {
            // An empty section shows the placeholder row; swapping it for the
            // first real project needs a section reload, not a row insert.
            guard !projects.isEmpty else { return false }
            for project in insertedProjects.sorted(by: Self.siblingLessThan) {
                let next = (projects + [project]).sorted(by: Self.siblingLessThan)
                guard let index = next.firstIndex(where: { $0.objectID == project.objectID }) else {
                    return false
                }
                projects.insert(project, at: index)
                outlineView.insertItems(
                    at: IndexSet(integer: index),
                    inParent: SidebarSection.projects,
                    withAnimation: []
                )
            }
            return true
        }

        if insertedProjects.isEmpty && !insertedTasks.isEmpty {
            let parents = Set(insertedTasks.compactMap { $0.outlineParent.map { ObjectIdentifier($0) } })
            guard parents.count == 1, let parent = insertedTasks[0].outlineParent else { return false }

            if parent is TaskItem, parent.outlineChildren.count == insertedTasks.count {
                outlineView.reloadItem(parent, reloadChildren: true)
                return true
            }

            for task in insertedTasks.sorted(by: Self.siblingLessThan) {
                guard let index = parent.outlineChildren.firstIndex(where: { $0.uuid == task.uuid }) else {
                    return false
                }
                outlineView.insertItems(at: IndexSet(integer: index), inParent: parent, withAnimation: [])
            }
            return true
        }

        return false
    }

    private func applySurgicalDeletes(projects deletedProjects: [Project], tasks deletedTasks: [TaskItem]) -> Bool {
        if !deletedProjects.isEmpty {
            let indexes = deletedProjects.compactMap { project in
                projects.firstIndex { $0.objectID == project.objectID }
            }
            guard indexes.count == deletedProjects.count else { return false }
            // Emptying the section swaps in the placeholder row, which is a
            // section reload rather than row removals.
            guard indexes.count < projects.count else { return false }
            for index in indexes.sorted(by: >) {
                projects.remove(at: index)
                outlineView.removeItems(
                    at: IndexSet(integer: index),
                    inParent: SidebarSection.projects,
                    withAnimation: []
                )
            }
            return true
        }

        let deletedIDs = Set(deletedTasks.map(\.objectID))
        let roots = deletedTasks.filter { task in
            guard let parent = task.parentTask else { return true }
            return !deletedIDs.contains(parent.objectID)
        }

        var parents: [ObjectIdentifier: OutlineNode] = [:]
        for task in roots {
            guard let parent = task.outlineParent else { return false }
            guard let object = parent as? NSManagedObject, !object.isDeleted else { return false }
            parents[ObjectIdentifier(object)] = parent
        }
        guard !parents.isEmpty else { return false }

        for parent in parents.values {
            outlineView.reloadItem(parent, reloadChildren: true)
        }
        return true
    }

    private func reloadDisplayIfNeeded(_ object: NSManagedObject) {
        let keys = Set(object.changedValues().keys)
        guard keys.contains("title") || keys.contains("isCompleted") || keys.contains("deadline") else { return }
        guard outlineView.currentEditor() == nil else { return }
        if object is Project || object is TaskItem {
            outlineView.reloadItem(object)
        }
    }

    private func objects(in notification: Notification, key: String) -> [NSManagedObject] {
        guard let set = notification.userInfo?[key] as? Set<NSManagedObject> else { return [] }
        return Array(set)
    }

    private static func siblingLessThan<T: OutlineNode>(_ lhs: T, _ rhs: T) -> Bool {
        (lhs.sortIndex, lhs.uuid) < (rhs.sortIndex, rhs.uuid)
    }

    // MARK: - Selection

    /// One highlight: a project or task, or Recent Mail.
    @objc private func plannerSelectionDidChange(_ notification: Notification) {
        let fields = notification.userInfo?[SelectionUserInfoKey.changedFields] as? Set<String> ?? []
        if fields.contains(SelectionField.mode.rawValue) {
            isApplyingProgrammaticSelection = true
            if selection.mode == .mail {
                revealMailbox(makeFirstResponder: false)
            } else {
                reveal(uuid: selection.selectedNodeUUID, makeFirstResponder: false)
            }
            isApplyingProgrammaticSelection = false
            return
        }
        if fields.contains(SelectionField.node.rawValue), selection.mode == .tasks {
            isApplyingProgrammaticSelection = true
            reveal(uuid: selection.selectedNodeUUID, makeFirstResponder: true)
            isApplyingProgrammaticSelection = false
        } else if fields.contains(SelectionField.mailbox.rawValue), selection.mode == .mail {
            isApplyingProgrammaticSelection = true
            revealMailbox(makeFirstResponder: true)
            isApplyingProgrammaticSelection = false
        }
    }

    private func reveal(uuid: UUID?, makeFirstResponder: Bool) {
        guard let uuid, let node = try? model.node(uuid: uuid) else {
            outlineView.deselectAll(nil)
            return
        }
        if selectVisibleRow(for: node, makeFirstResponder: makeFirstResponder) {
            return
        }
        // Chip reveal can race a stale projects cache; refetch once and retry.
        projects = (try? model.allProjects()) ?? []
        outlineView.reloadData()
        restoreExpansion()
        _ = selectVisibleRow(for: node, makeFirstResponder: makeFirstResponder)
    }

    private func revealMailbox(makeFirstResponder: Bool) {
        let item: NSObject
        switch selection.mailbox {
        case .recent:
            item = RecentMailbox.shared
        case .search:
            item = SearchMailbox.shared
        case let .quickSearch(id):
            guard let mailbox = quickSearchMailboxes.first(where: { $0.id == id }) else { return }
            item = mailbox
        }
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        if makeFirstResponder {
            view.window?.makeFirstResponder(outlineView)
        }
    }

    private func selectVisibleRow(for node: OutlineNode, makeFirstResponder: Bool) -> Bool {
        expandAncestors(of: node)
        persistExpansion()
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return false }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        if makeFirstResponder {
            view.window?.makeFirstResponder(outlineView)
        }
        return true
    }

    private func expandAncestors(of node: OutlineNode) {
        var ancestors: [OutlineNode] = []
        var parent = node.outlineParent
        while let current = parent {
            ancestors.append(current)
            parent = current.outlineParent
        }
        for ancestor in ancestors.reversed() {
            outlineView.expandItem(ancestor)
        }
    }

    /// Selecting a row picks the panes that can show it: a project or task
    /// opens the calendar, while Recent Mail opens the reader. Mode is not a separate
    /// command — it is the kind of row that is selected.
    private func publishOutlineSelection() {
        guard !isApplyingProgrammaticSelection else { return }
        switch outlineView.item(atRow: outlineView.selectedRow) {
        case let node as OutlineNode:
            selection.selectNode(uuid: node.uuid)
        case is RecentMailbox:
            selection.selectMailbox(.recent)
        case is SearchMailbox:
            selection.selectMailbox(.search)
        case let mailbox as QuickSearchMailbox:
            selection.selectMailbox(.quickSearch(mailbox.id))
        default:
            // Clicking empty space clears the node in tasks mode; mail always
                // has a selected field, so there the highlight snaps back instead.
            if selection.mode == .tasks {
                selection.selectNode(uuid: nil)
            } else {
                isApplyingProgrammaticSelection = true
                revealMailbox(makeFirstResponder: false)
                isApplyingProgrammaticSelection = false
            }
        }
    }

    @objc private func outlineSingleClicked() {
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
              outlineView.currentEditor() == nil,
              isClickInsideTitleField(row: row)
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
              row == outlineView.selectedRow
        else { return }
        guard let node = outlineView.item(atRow: row) as? OutlineNode else { return }
        beginEditingTitle(of: node)
    }

    @objc private func toggleClickedRow() {
        cancelPendingRename()
        outlineView.pendingRenameRow = -1
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        let item = outlineView.item(atRow: row)
        if let task = item as? TaskItem, task.subtasks.isEmpty {
            selection.selectNode(uuid: task.uuid)
            NSApp.sendAction(#selector(MainSplitViewController.openTaskWindow(_:)), to: nil, from: self)
            return
        }
        if outlineView.isItemExpanded(item) {
            outlineView.collapseItem(item)
        } else {
            outlineView.expandItem(item)
        }
    }

    private static var renameDelay: TimeInterval {
        max(0.5, NSEvent.doubleClickInterval + 0.05)
    }

    private func isClickInsideTitleField(row: Int) -> Bool {
        guard let event = NSApp.currentEvent,
              let field = titleField(atRow: row, makeIfNecessary: false)
        else { return false }
        let locationInOutline = outlineView.convert(event.locationInWindow, from: nil)
        let locationInField = field.convert(locationInOutline, from: outlineView)
        return field.bounds.contains(locationInField)
    }

    // MARK: - Expansion

    private func persistExpansion() {
        var uuids: [String] = []
        collectExpanded(from: nil, into: &uuids)
        userDefaults.set(uuids, forKey: Self.expandedUUIDsKey)
    }

    private func restoreExpansion() {
        let wanted = Set(userDefaults.stringArray(forKey: Self.expandedUUIDsKey) ?? [])
        expandMatching(item: nil, wanted: wanted)
        persistExpansion()
    }

    private func expandMatching(item: Any?, wanted: Set<String>) {
        let count = outlineView(outlineView, numberOfChildrenOfItem: item)
        for index in 0..<count {
            let child = outlineView(outlineView, child: index, ofItem: item)
            // Sections are always open: they are structure, not persisted state.
            if child is SidebarSection {
                outlineView.expandItem(child)
                expandMatching(item: child, wanted: wanted)
                continue
            }
            guard let node = child as? OutlineNode, wanted.contains(node.uuid.uuidString) else { continue }
            outlineView.expandItem(node)
            expandMatching(item: node, wanted: wanted)
        }
    }

    private func collectExpanded(from item: Any?, into uuids: inout [String]) {
        let count = outlineView(outlineView, numberOfChildrenOfItem: item)
        for index in 0..<count {
            let child = outlineView(outlineView, child: index, ofItem: item)
            if child is SidebarSection {
                collectExpanded(from: child, into: &uuids)
                continue
            }
            guard outlineView.isItemExpanded(child), let node = child as? OutlineNode else { continue }
            uuids.append(node.uuid.uuidString)
            collectExpanded(from: child, into: &uuids)
        }
    }

    // MARK: - Inline rename

    func cancelPendingRename() {
        renameGeneration += 1
        renameTimer?.invalidate()
        renameTimer = nil
    }

    func beginEditingSelectedTitle() {
        guard let node = outlineView.item(atRow: outlineView.selectedRow) as? OutlineNode else { return }
        beginEditingTitle(of: node)
    }

    func beginEditingTitle(of node: OutlineNode) {
        cancelPendingRename()
        beginEditingTitleHandler?(node)
        if let parent = node.outlineParent { outlineView.expandItem(parent) }
        beginEditing(item: node)
    }

    private func beginEditing(item: AnyObject) {
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        guard let field = titleField(atRow: row, makeIfNecessary: true) else { return }
        field.allowsFirstResponder = true
        editingField = field
        outlineView.editColumn(0, row: row, with: nil, select: true)
        if outlineView.currentEditor() == nil {
            endTitleEditing()
        }
    }

    func endTitleEditing() {
        editingField?.allowsFirstResponder = false
        editingField = nil
        for row in 0..<outlineView.numberOfRows {
            titleField(atRow: row, makeIfNecessary: false)?.allowsFirstResponder = false
        }
    }

    private func titleField(atRow row: Int, makeIfNecessary: Bool) -> TitleTextField? {
        (outlineView.view(atColumn: 0, row: row, makeIfNecessary: makeIfNecessary) as? NSTableCellView)?
            .textField as? TitleTextField
    }

    private func editedItem(for field: NSView) -> Any? {
        let row = outlineView.row(for: field)
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row)
    }

    private func restoreTitle(_ node: OutlineNode, on field: TitleTextField) {
        if let cell = titleCell(containing: field) {
            cell.setTitle(node.title, completed: (node as? TaskItem)?.isCompleted == true)
        } else {
            field.stringValue = node.title
        }
    }

    private func titleCell(containing view: NSView) -> TitleCellView? {
        var current: NSView? = view
        while let candidate = current {
            if let cell = candidate as? TitleCellView { return cell }
            current = candidate.superview
        }
        return nil
    }
}

extension OutlineViewController: NSOutlineViewDataSource {
    private var sections: [SidebarSection] { [.projects, .mail] }

    private func children(of section: SidebarSection) -> [NSObject] {
        if section === SidebarSection.projects {
            return projects.isEmpty ? [SidebarPlaceholder.noProjects] : projects
        }
        // Recent first, then named quick searches, then the generic Search
        // mailbox last — Search is the catch-all, not a pinned shortcut.
        var mailboxes: [NSObject] = [RecentMailbox.shared]
        mailboxes.append(contentsOf: quickSearchMailboxes)
        mailboxes.append(SearchMailbox.shared)
        return mailboxes
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch item {
        case nil: return sections.count
        case let section as SidebarSection: return children(of: section).count
        case let node as OutlineNode: return node.outlineChildren.count
        default: return 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        switch item {
        case is SidebarSection: return true
        case is Project: return true
        case let task as TaskItem: return !task.subtasks.isEmpty
        default: return false
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        switch item {
        case nil: return sections[index]
        case let section as SidebarSection: return children(of: section)[index]
        default: return (item as! OutlineNode).outlineChildren[index]
        }
    }
}

extension OutlineViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is SidebarSection
    }

    /// Sections and the placeholder are labels, not destinations.
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        !(item is SidebarSection || item is SidebarPlaceholder)
    }

    /// No disclosure triangle on a section: both are always open.
    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        !(item is SidebarSection)
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        !(item is SidebarSection)
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        switch item {
        case is SidebarSection: return 26
        case is RecentMailbox, is SearchMailbox, is QuickSearchMailbox: return 24
        default: return 21
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let section = item as? SidebarSection {
            return makeSectionCell(title: section.title)
        }
        if let placeholder = item as? SidebarPlaceholder {
            return makePlaceholderCell(text: placeholder.text)
        }
        if item is RecentMailbox || item is SearchMailbox || item is QuickSearchMailbox {
            return makeConfiguredMailboxCell(for: item)
        }
        let identifier = NSUserInterfaceItemIdentifier("TitleCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeTitleCell(identifier: identifier)
        (cell.textField as? TitleTextField)?.allowsFirstResponder = false
        if let node = item as? OutlineNode, let titleCell = cell as? TitleCellView {
            isUpdatingUI = true
            titleCell.isUpdatingCompleteControl = true
            titleCell.setTitle(node.title, completed: (node as? TaskItem)?.isCompleted == true)
            if let task = node as? TaskItem {
                titleCell.completeButton.isHidden = false
                titleCell.completeButton.state = task.isCompleted ? .on : .off
                titleCell.completeButton.contentTintColor = task.isCompleted ? .controlAccentColor : .tertiaryLabelColor
                titleCell.showsProjectIcon = false
                titleCell.setDeadline(task.isCompleted ? nil : task.deadline)
            } else {
                titleCell.completeButton.isHidden = true
                titleCell.completeButton.state = .off
                titleCell.completeButton.contentTintColor = .tertiaryLabelColor
                titleCell.showsProjectIcon = true
                titleCell.setDeadline(nil)
            }
            titleCell.isUpdatingCompleteControl = false
            isUpdatingUI = false
        }
        return cell
    }

    @objc private func toggleCompleted(_ sender: NSButton) {
        guard !isUpdatingUI else { return }
        var ancestor: NSView? = sender
        while let view = ancestor {
            if let cell = view as? TitleCellView, cell.isUpdatingCompleteControl { return }
            ancestor = view.superview
        }
        let row = outlineView.row(for: sender)
        guard row >= 0, let task = outlineView.item(atRow: row) as? TaskItem else { return }
        do {
            try model.setCompleted(sender.state == .on, on: task)
        } catch {
            sender.state = task.isCompleted ? .on : .off
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        cancelPendingRename()
        publishOutlineSelection()
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        persistExpansion()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        persistExpansion()
    }

    private func makeTitleCell(identifier: NSUserInterfaceItemIdentifier) -> TitleCellView {
        let cell = TitleCellView()
        cell.identifier = identifier

        let completeButton = NSButton()
        completeButton.setButtonType(.toggle)
        completeButton.isBordered = false
        completeButton.title = ""
        completeButton.imagePosition = .imageOnly
        completeButton.imageScaling = .scaleProportionallyDown
        let symbol = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        completeButton.image = NSImage(systemSymbolName: "circle", accessibilityDescription: "Mark complete")?
            .withSymbolConfiguration(symbol)
        completeButton.alternateImage = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Completed")?
            .withSymbolConfiguration(symbol)
        completeButton.contentTintColor = .tertiaryLabelColor
        completeButton.target = self
        completeButton.action = #selector(toggleCompleted(_:))
        completeButton.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            completeButton.widthAnchor.constraint(equalToConstant: 13),
            completeButton.heightAnchor.constraint(equalToConstant: 13),
        ])

        let projectIcon = NSImageView()
        projectIcon.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
        projectIcon.contentTintColor = .controlAccentColor
        projectIcon.imageScaling = .scaleProportionallyDown
        projectIcon.setContentHuggingPriority(.required, for: .horizontal)
        projectIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            projectIcon.widthAnchor.constraint(equalToConstant: 13),
            projectIcon.heightAnchor.constraint(equalToConstant: 13),
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

        // Trailing due date: the outline used to give no hint that a task had a
        // deadline at all, so the two panes never referred to each other.
        let deadlineLabel = NSTextField(labelWithString: "")
        deadlineLabel.font = .systemFont(ofSize: 11)
        deadlineLabel.textColor = .secondaryLabelColor
        deadlineLabel.alignment = .right
        deadlineLabel.lineBreakMode = .byClipping
        deadlineLabel.refusesFirstResponder = true
        deadlineLabel.isHidden = true
        deadlineLabel.setContentHuggingPriority(.required, for: .horizontal)
        deadlineLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView(views: [completeButton, projectIcon, field, deadlineLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        cell.textField = field
        cell.completeButton = completeButton
        cell.projectIconView = projectIcon
        cell.deadlineLabel = deadlineLabel

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func makeSectionCell(title: String) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier("SectionHeader")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? Self.makeLabelCell(identifier: identifier, font: .systemFont(ofSize: 11, weight: .semibold))
        cell.textField?.stringValue = title
        return cell
    }

    private func makePlaceholderCell(text: String) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier("Placeholder")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? Self.makeLabelCell(identifier: identifier, font: .systemFont(ofSize: 12))
        cell.textField?.stringValue = text
        return cell
    }

    private static func makeLabelCell(identifier: NSUserInterfaceItemIdentifier, font: NSFont) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.font = font
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        field.refusesFirstResponder = true
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            field.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            field.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -3),
        ])
        return cell
    }

    private func makeConfiguredMailboxCell(for item: Any) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier("MailboxCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? MailboxCellView
            ?? makeMailboxCell(identifier: identifier)
        (cell.textField as? TitleTextField)?.allowsFirstResponder = false

        if item is SearchMailbox {
            cell.apply(
                name: MailLabels.searchMailName,
                symbol: "magnifyingglass",
                count: mail.searchResults.count
            )
        } else if let mailbox = item as? QuickSearchMailbox {
            cell.apply(
                name: mailbox.name,
                symbol: "folder",
                count: 0
            )
        } else {
            cell.apply(
                name: MailLabels.recentMailName,
                symbol: "tray",
                count: mail.messages.count
            )
        }
        return cell
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
        // The name absorbs the row's slack so the count stays pinned right.
        // Let the name absorb slack so the count stays pinned to the trailing edge.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

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
        // `.gravityAreas` (the default) leaves every view at its intrinsic width
        // and pools the slack at the trailing edge, which is what stranded the
        // count mid-row. `.fill` hands the slack to the lowest-hugging view --
        // the name -- so the count lands against the trailing edge on every row.
        stack.distribution = .fill
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

    func apply(name: String, symbol: String, count: Int) {
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        textField?.stringValue = name
        textField?.isEditable = false
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

private final class TitleCellView: NSTableCellView {
    var completeButton: NSButton!
    var projectIconView: NSImageView!
    var deadlineLabel: NSTextField!
    var isUpdatingCompleteControl = false
    private var titleText = ""
    private var isCompleted = false
    private var isProject = false
    private var deadline: Date?

    func setDeadline(_ deadline: Date?) {
        self.deadline = deadline
        refreshDeadline()
    }

    private func refreshDeadline() {
        guard let deadline else {
            deadlineLabel.isHidden = true
            return
        }
        let calendar = Calendar.current
        deadlineLabel.stringValue = calendar.relativeDeadlineLabel(for: deadline)
            ?? calendar.shortDeadlineString(for: deadline)
        // On an emphasized row the accent fill is behind the text, so red would
        // be unreadable; fall back to the selected-row text color.
        if backgroundStyle == .emphasized {
            deadlineLabel.textColor = .alternateSelectedControlTextColor
        } else {
            deadlineLabel.textColor = calendar.isOverdue(deadline) ? .systemRed : .secondaryLabelColor
        }
        deadlineLabel.isHidden = false
    }

    var showsProjectIcon: Bool {
        get { isProject }
        set {
            isProject = newValue
            projectIconView.isHidden = !newValue
            refreshTitle()
        }
    }

    func setTitle(_ title: String, completed: Bool) {
        titleText = title
        isCompleted = completed
        refreshTitle()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            refreshTitle()
            refreshDeadline()
        }
    }

    private func refreshTitle() {
        guard let field = textField, field.currentEditor() == nil else { return }
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        if isCompleted {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            ]
            if backgroundStyle != .emphasized {
                attributes[.foregroundColor] = NSColor.secondaryLabelColor
            }
            field.attributedStringValue = NSAttributedString(string: titleText, attributes: attributes)
        } else {
            field.font = font
            field.stringValue = titleText
        }
    }
}

extension OutlineViewController: NSTextFieldDelegate {
    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        let trimmed = fieldEditor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            NSSound.beep()
            return false
        }
        return true
    }

    func controlTextDidEndEditing(_ note: Notification) {
        defer { endTitleEditing() }
        guard !isCancellingTitleEdit,
              let field = note.object as? TitleTextField
        else { return }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch editedItem(for: field) {
        case let node as OutlineNode:
            guard trimmed != node.title else { return }
            try? model.setTitle(node, trimmed)
        default:
            break
        }
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard commandSelector == #selector(cancelOperation(_:)) else { return false }
        isCancellingTitleEdit = true
        control.abortEditing()
        if let field = control as? TitleTextField {
            switch editedItem(for: field) {
            case let node as OutlineNode: restoreTitle(node, on: field)
            default: break
            }
        }
        endTitleEditing()
        isCancellingTitleEdit = false
        return true
    }
}

extension OutlineViewController {
    /// "Empty" means the Projects section is showing its placeholder row.
    var test_isEmptyStateVisible: Bool { projects.isEmpty }

    func test_simulateStaleEmptyProjectsCache() {
        projects = []
        outlineView.reloadData()
    }
}
