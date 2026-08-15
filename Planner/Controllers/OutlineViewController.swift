import AppKit
import CoreData

final class OutlineViewController: NSViewController {
    static let expandedUUIDsKey = "outline.expandedUUIDs"

    let persistence: PersistenceController
    let model: ModelController
    let selection: SelectionModel
    let outlineView = PlannerOutlineView()

    private let userDefaults: UserDefaults
    private let emptyStateLabel = NSTextField(labelWithString: "No Projects — ⌘N to add one.")
    private var projects: [Project] = []
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
        userDefaults: UserDefaults = .standard
    ) {
        self.persistence = persistence
        self.model = model
        self.selection = selection
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

        emptyStateLabel.font = .systemFont(ofSize: 13, weight: .regular)
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.alignment = .center
        emptyStateLabel.maximumNumberOfLines = 0
        emptyStateLabel.lineBreakMode = .byWordWrapping
        emptyStateLabel.refusesFirstResponder = true
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false

        let headerLabel = NSTextField(labelWithString: "Projects")
        headerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        // The sidebar split item supplies the vibrant material; a plain host view
        // lets it through instead of stacking a second effect view on top of it.
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
            emptyStateLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: 12),
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
    }

    // MARK: - Store → outline

    private func reloadFromStore() {
        let selectedUUID = selection.selectedNodeUUID
        projects = (try? model.allProjects()) ?? []
        isApplyingProgrammaticSelection = true
        outlineView.reloadData()
        restoreExpansion()
        reveal(uuid: selectedUUID, makeFirstResponder: false)
        isApplyingProgrammaticSelection = false
        updateEmptyState()
    }

    private func updateEmptyState() {
        emptyStateLabel.isHidden = !projects.isEmpty
    }

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
            updateEmptyState()
            return
        }

        if applySurgicalInserts(
            projects: insertedProjects,
            tasks: insertedTasks,
            deletedProjects: deletedProjects,
            deletedTasks: deletedTasks
        ) {
            updateEmptyState()
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
            for project in insertedProjects.sorted(by: Self.siblingLessThan) {
                let next = (projects + [project]).sorted(by: Self.siblingLessThan)
                guard let index = next.firstIndex(where: { $0.objectID == project.objectID }) else {
                    return false
                }
                projects.insert(project, at: index)
                outlineView.insertItems(at: IndexSet(integer: index), inParent: nil, withAnimation: [])
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
            for index in indexes.sorted(by: >) {
                projects.remove(at: index)
                outlineView.removeItems(at: IndexSet(integer: index), inParent: nil, withAnimation: [])
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

    @objc private func plannerSelectionDidChange(_ notification: Notification) {
        let fields = notification.userInfo?[SelectionUserInfoKey.changedFields] as? Set<String> ?? []
        guard fields.contains(SelectionField.node.rawValue) else { return }
        isApplyingProgrammaticSelection = true
        reveal(uuid: selection.selectedNodeUUID, makeFirstResponder: true)
        isApplyingProgrammaticSelection = false
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
        updateEmptyState()
        _ = selectVisibleRow(for: node, makeFirstResponder: makeFirstResponder)
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

    private func publishOutlineSelection() {
        guard !isApplyingProgrammaticSelection else { return }
        let item = outlineView.item(atRow: outlineView.selectedRow) as? OutlineNode
        selection.selectNode(uuid: item?.uuid)
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
              row == outlineView.selectedRow,
              let node = outlineView.item(atRow: row) as? OutlineNode
        else { return }
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
            guard let node = child as? OutlineNode, wanted.contains(node.uuid.uuidString) else { continue }
            outlineView.expandItem(node)
            expandMatching(item: node, wanted: wanted)
        }
    }

    private func collectExpanded(from item: Any?, into uuids: inout [String]) {
        let count = outlineView(outlineView, numberOfChildrenOfItem: item)
        for index in 0..<count {
            let child = outlineView(outlineView, child: index, ofItem: item)
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
        let row = outlineView.row(forItem: node)
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

    private func node(for field: NSView) -> OutlineNode? {
        let row = outlineView.row(for: field)
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? OutlineNode
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
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return projects.count }
        return (item as! OutlineNode).outlineChildren.count
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is Project || !(item as! TaskItem).subtasks.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return projects[index] }
        return (item as! OutlineNode).outlineChildren[index]
    }
}

extension OutlineViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
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
              let field = note.object as? TitleTextField,
              let node = node(for: field)
        else { return }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != node.title else { return }
        try? model.setTitle(node, trimmed)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard commandSelector == #selector(cancelOperation(_:)) else { return false }
        isCancellingTitleEdit = true
        control.abortEditing()
        if let field = control as? TitleTextField, let node = node(for: field) {
            restoreTitle(node, on: field)
        }
        endTitleEditing()
        isCancellingTitleEdit = false
        return true
    }
}

extension OutlineViewController {
    var test_isEmptyStateVisible: Bool { !emptyStateLabel.isHidden }

    func test_simulateStaleEmptyProjectsCache() {
        projects = []
        outlineView.reloadData()
        updateEmptyState()
    }
}
