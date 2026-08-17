import AppKit
import CoreData

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

/// The unified navigation sidebar: a Projects section holding the task outline,
/// then a Mail section holding Recent Mail and the user's folders. One sidebar
/// for both modes — selecting a row switches the trailing panes to whichever
/// mode can show it.
final class OutlineViewController: NSViewController {
    static let expandedUUIDsKey = "outline.expandedUUIDs"

    let persistence: PersistenceController
    let model: ModelController
    let selection: SelectionModel
    let mail: MailCoordinator
    let outlineView = PlannerOutlineView()

    private let userDefaults: UserDefaults
    private var projects: [Project] = []
    private var folders: [MailFolder] = []
    private var isApplyingProgrammaticSelection = false
    private var isUpdatingUI = false
    private var renameTimer: Timer?
    private(set) var renameGeneration = 0
    private weak var editingField: TitleTextField?
    private var isCancellingTitleEdit = false

    /// Tests observe begin-edit attempts; `editColumn` requires a window.
    var beginEditingTitleHandler: ((OutlineNode) -> Void)?
    var beginEditingNameHandler: ((MailFolder) -> Void)?

    init(
        persistence: PersistenceController,
        model: ModelController,
        selection: SelectionModel,
        mail: MailCoordinator,
        userDefaults: UserDefaults = .standard
    ) {
        self.persistence = persistence
        self.model = model
        self.selection = selection
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
        root.addSubview(scrollView)
        view = root

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
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
        // The Recent Mail row carries a count, so it has to redraw when the
        // sweep lands.
        center.addObserver(
            self,
            selector: #selector(mailDidChange(_:)),
            name: .plannerMailDidChange,
            object: mail
        )
    }

    // MARK: - Store → outline

    private func reloadFromStore() {
        let selectedUUID = selection.selectedNodeUUID
        projects = (try? model.allProjects()) ?? []
        folders = model.mailFolders()
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

    /// The Mail section's contents changed: refetch the folders and rebuild
    /// just that section, keeping the Projects tree (and its expansion) alone.
    private func reloadMailSection() {
        folders = model.mailFolders()
        isApplyingProgrammaticSelection = true
        outlineView.reloadItem(SidebarSection.mail, reloadChildren: true)
        outlineView.expandItem(SidebarSection.mail)
        if selection.mode == .mail {
            revealMailbox(makeFirstResponder: false)
        }
        isApplyingProgrammaticSelection = false
    }

    @objc private func mailDidChange(_ notification: Notification) {
        let row = outlineView.row(forItem: RecentMailbox.shared)
        guard row >= 0 else { return }
        outlineView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
    }

    @objc private func contextDidSave(_ notification: Notification) {
        if notification.userInfo?[NSInvalidatedAllObjectsKey] != nil {
            reloadFromStore()
            return
        }

        let inserted = objects(in: notification, key: NSInsertedObjectsKey)
            .filter { !$0.objectID.isTemporaryID }
        let deleted = objects(in: notification, key: NSDeletedObjectsKey)

        // Folder rows carry message counts, so folder *and* message changes
        // both change what the Mail section says.
        let updated = objects(in: notification, key: NSUpdatedObjectsKey)
        if (inserted + deleted + updated).contains(where: { $0 is MailFolder || $0 is SavedMessage }) {
            reloadMailSection()
        }

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
        if outlineView.currentEditor() == nil,
           (updated + refreshed).contains(where: { $0 is MailFolder || $0 is SavedMessage }) {
            reloadMailSection()
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

    /// One highlight: a project or task in the Projects section, or Recent
    /// Mail / a folder in Mail. The trailing panes follow that row.
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
        }
        if fields.contains(SelectionField.mailbox.rawValue), selection.mode == .mail {
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
    /// opens the calendar, a mailbox opens the reader. Mode is not a separate
    /// command — it is the kind of row that is selected.
    private func publishOutlineSelection() {
        guard !isApplyingProgrammaticSelection else { return }
        switch outlineView.item(atRow: outlineView.selectedRow) {
        case let node as OutlineNode:
            selection.selectNode(uuid: node.uuid)
        case is RecentMailbox:
            selection.selectMailbox(.recent)
        case let folder as MailFolder:
            selection.selectMailbox(.folder(folder.uuid))
        default:
            // Clicking empty space clears the node in tasks mode; mail always
            // has a mailbox, so there the highlight snaps back instead.
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
        // Recent Mail has no name to edit, so the gesture ignores it.
        switch outlineView.item(atRow: row) {
        case let node as OutlineNode: beginEditingTitle(of: node)
        case let folder as MailFolder: beginEditingName(of: folder)
        default: break
        }
    }

    @objc private func toggleClickedRow() {
        cancelPendingRename()
        outlineView.pendingRenameRow = -1
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        let item = outlineView.item(atRow: row)
        if let task = item as? TaskItem, task.subtasks.isEmpty {
            selection.selectNode(uuid: task.uuid)
            NSApp.sendAction(#selector(MainSplitViewController.showTaskInfo(_:)), to: nil, from: self)
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
        switch outlineView.item(atRow: outlineView.selectedRow) {
        case let node as OutlineNode: beginEditingTitle(of: node)
        case let folder as MailFolder: beginEditingName(of: folder)
        default: break
        }
    }

    func beginEditingTitle(of node: OutlineNode) {
        cancelPendingRename()
        beginEditingTitleHandler?(node)
        if let parent = node.outlineParent { outlineView.expandItem(parent) }
        beginEditing(item: node)
    }

    /// Recent Mail is not renamable, so the caller passes a folder.
    func beginEditingName(of folder: MailFolder) {
        cancelPendingRename()
        beginEditingNameHandler?(folder)
        beginEditing(item: folder)
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
        return [RecentMailbox.shared] + folders
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
        case is RecentMailbox, is MailFolder: return 24
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
        if item is RecentMailbox || item is MailFolder {
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
        // Without this the two mailbox kinds lay out differently for a reason
        // that has nothing to do with either: `apply` makes folders editable
        // and Recent Mail not, and an editable NSTextField reports no intrinsic
        // width while a non-editable one reports its string width. Stating the
        // priorities here decides the layout instead of inheriting that.
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
        case let folder as MailFolder:
            guard trimmed != folder.name else { return }
            try? model.renameMailFolder(folder, to: trimmed)
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
            case let folder as MailFolder: field.stringValue = folder.name
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
