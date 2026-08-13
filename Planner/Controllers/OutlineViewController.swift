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

        emptyStateLabel.font = .preferredFont(forTextStyle: .callout)
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.alignment = .center
        emptyStateLabel.maximumNumberOfLines = 0
        emptyStateLabel.lineBreakMode = .byWordWrapping
        emptyStateLabel.refusesFirstResponder = true
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(scrollView)
        container.addSubview(emptyStateLabel)
        view = container

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyStateLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 16),
            emptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
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
        outlineView.rowHeight = 22
        outlineView.headerView = nil
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.indentationPerLevel = 16
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.floatsGroupRows = false
        outlineView.focusRingType = .none
        outlineView.backgroundColor = .clear
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
        guard keys.contains("title") || keys.contains("isCompleted") else { return }
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
        expandAncestors(of: node)
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        if makeFirstResponder {
            view.window?.makeFirstResponder(outlineView)
        }
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

    @objc private func toggleClickedRow() {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        let item = outlineView.item(atRow: row)
        if outlineView.isItemExpanded(item) {
            outlineView.collapseItem(item)
        } else {
            outlineView.expandItem(item)
        }
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
        if let node = item as? OutlineNode, let titleCell = cell as? TitleCellView {
            isUpdatingUI = true
            titleCell.isUpdatingCompleteControl = true
            titleCell.setTitle(node.title, completed: (node as? TaskItem)?.isCompleted == true)
            if let task = node as? TaskItem {
                titleCell.completeButton.isHidden = false
                titleCell.completeButton.state = task.isCompleted ? .on : .off
            } else {
                titleCell.completeButton.isHidden = true
                titleCell.completeButton.state = .off
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
        completeButton.setButtonType(.switch)
        completeButton.title = ""
        completeButton.imagePosition = .imageOnly
        completeButton.controlSize = .small
        completeButton.target = self
        completeButton.action = #selector(toggleCompleted(_:))
        completeButton.setContentHuggingPriority(.required, for: .horizontal)

        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        field.isEditable = false
        field.isSelectable = false
        field.refusesFirstResponder = true
        field.drawsBackground = false
        field.isBordered = false

        let stack = NSStackView(views: [completeButton, field])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.detachesHiddenViews = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        cell.textField = field
        cell.completeButton = completeButton

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

private final class TitleCellView: NSTableCellView {
    var completeButton: NSButton!
    var isUpdatingCompleteControl = false
    private var titleText = ""
    private var isCompleted = false

    func setTitle(_ title: String, completed: Bool) {
        titleText = title
        isCompleted = completed
        refreshTitle()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { refreshTitle() }
    }

    private func refreshTitle() {
        guard let field = textField else { return }
        if isCompleted {
            var attributes: [NSAttributedString.Key: Any] = [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            ]
            if backgroundStyle != .emphasized {
                attributes[.foregroundColor] = NSColor.secondaryLabelColor
            }
            field.attributedStringValue = NSAttributedString(string: titleText, attributes: attributes)
        } else {
            field.stringValue = titleText
        }
        field.isEditable = false
    }
}
