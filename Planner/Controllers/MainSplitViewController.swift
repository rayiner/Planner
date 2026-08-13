import AppKit

final class MainSplitViewController: NSSplitViewController {
    let persistence: PersistenceController
    let model: ModelController
    let selection: SelectionModel

    private let outlineViewController: OutlineViewController
    private let calendarViewController: CalendarViewController
    private let inspectorViewController: InspectorViewController

    init(
        persistence: PersistenceController,
        model: ModelController,
        selection: SelectionModel
    ) {
        self.persistence = persistence
        self.model = model
        self.selection = selection
        outlineViewController = OutlineViewController(
            persistence: persistence,
            model: model,
            selection: selection
        )
        calendarViewController = CalendarViewController(
            persistence: persistence,
            model: model,
            selection: selection
        )
        inspectorViewController = InspectorViewController(
            persistence: persistence,
            model: model,
            selection: selection
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        splitView.isVertical = true
        splitView.autosaveName = "MainHorizontalSplit"

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: outlineViewController)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = NSSplitViewItem.unspecifiedDimension
        sidebarItem.preferredThicknessFraction = 280.0 / 1040.0
        sidebarItem.holdingPriority = .defaultLow
        sidebarItem.canCollapse = false

        let rightItem = NSSplitViewItem(viewController: makeRightSplitViewController())
        rightItem.holdingPriority = .defaultHigh

        addSplitViewItem(sidebarItem)
        addSplitViewItem(rightItem)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(plannerSelectionDidChange),
            name: .plannerSelectionDidChange,
            object: selection
        )
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        installToolbarIfNeeded()
    }

    @discardableResult
    func flushInspectorNotes() -> Bool {
        inspectorViewController.flushPendingNote()
    }

    private func makeRightSplitViewController() -> NSSplitViewController {
        let rightSplit = NSSplitViewController()
        rightSplit.splitView.isVertical = false
        rightSplit.splitView.autosaveName = "RightVerticalSplit"

        let calendarItem = NSSplitViewItem(viewController: calendarViewController)
        calendarItem.holdingPriority = .defaultHigh

        let inspectorItem = NSSplitViewItem(viewController: inspectorViewController)
        inspectorItem.minimumThickness = 120
        inspectorItem.preferredThicknessFraction = 168.0 / 660.0
        inspectorItem.holdingPriority = .defaultLow

        rightSplit.addSplitViewItem(calendarItem)
        rightSplit.addSplitViewItem(inspectorItem)
        return rightSplit
    }

    private func installToolbarIfNeeded() {
        guard let window = view.window, window.toolbar == nil else { return }

        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
    }

    // MARK: - Commands

    @objc func newProject(_ sender: Any?) {
        do {
            let project = try model.createProject()
            selectAndBeginEditing(project)
        } catch {
            // saveFailed already presented; do not retarget selection.
        }
    }

    @objc func newTask(_ sender: Any?) {
        guard !isFirstResponderTextInput else { return }
        do {
            let created: TaskItem
            if let project = selectedOutlineNode as? Project {
                created = try model.createTask(in: project)
            } else if let task = selectedOutlineNode as? TaskItem {
                created = try model.createSibling(of: task)
            } else {
                return
            }
            selectAndBeginEditing(created)
        } catch {
            // saveFailed already presented; do not retarget selection.
        }
    }

    @objc func newSubtask(_ sender: Any?) {
        guard !isFirstResponderTextInput else { return }
        guard let task = selectedOutlineNode as? TaskItem else { return }
        do {
            let created = try model.createSubtask(under: task)
            selectAndBeginEditing(created)
        } catch {
            // saveFailed already presented; do not retarget selection.
        }
    }

    @objc func renameSelected(_ sender: Any?) {
        guard !isFirstResponderTextInput else { return }
        guard let node = selectedOutlineNode else { return }
        outlineViewController.beginEditingTitle(of: node)
    }

    @objc func deleteSelected(_ sender: Any?) {
        guard !isFirstResponderTextInput else { return }
        guard let node = selectedOutlineNode else { return }
        confirmDelete(node) { [weak self] confirmed in
            guard confirmed else { return }
            self?.performConfirmedDelete(node)
        }
    }

    @objc func revealToday(_ sender: Any?) {
        selection.setVisibleMonth(Date())
    }

    /// Tests assign a responder so validation/actions see a text input without hosting the split in a window.
    var firstResponderForValidation: NSResponder?

    /// Tests pass a result to skip the confirmation sheet.
    func deleteSelected(confirmed: Bool) {
        guard let node = selectedOutlineNode else { return }
        guard confirmed else { return }
        performConfirmedDelete(node)
    }

    static func deleteConfirmationMessage(for node: OutlineNode) -> String {
        if node is Project {
            return "Delete “\(node.title)” and all of its tasks?"
        }
        if let task = node as? TaskItem, !task.subtasks.isEmpty {
            return "Delete “\(node.title)” and all of its subtasks?"
        }
        return "Delete “\(node.title)”?"
    }

    static func isTextInputResponder(_ responder: NSResponder?) -> Bool {
        if let field = responder as? NSTextField {
            return isEditingTextField(field)
        }
        if let text = responder as? NSText {
            if let field = text.delegate as? NSTextField {
                return isEditingTextField(field)
            }
            return true
        }
        return false
    }

    private static func isEditingTextField(_ field: NSTextField) -> Bool {
        field.isEditable && field.currentEditor() != nil
    }

    private var selectedOutlineNode: OutlineNode? {
        guard let uuid = selection.selectedNodeUUID else { return nil }
        return try? model.node(uuid: uuid)
    }

    private var isFirstResponderTextInput: Bool {
        Self.isTextInputResponder(firstResponderForValidation ?? view.window?.firstResponder)
    }

    private func selectAndBeginEditing(_ node: OutlineNode) {
        selection.selectNode(uuid: node.uuid)
        DispatchQueue.main.async { [weak self] in
            self?.outlineViewController.beginEditingTitle(of: node)
        }
    }

    private func confirmDelete(_ node: OutlineNode, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = Self.deleteConfirmationMessage(for: node)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete")
        alert.buttons.last?.hasDestructiveAction = true

        if let window = view.window {
            alert.beginSheetModal(for: window) { response in
                completion(response == .alertSecondButtonReturn)
            }
        } else {
            completion(alert.runModal() == .alertSecondButtonReturn)
        }
    }

    private func performConfirmedDelete(_ node: OutlineNode) {
        let nextUUID = uuidToSelectAfterDeleting(node)
        do {
            try model.delete(node)
            selection.selectNode(uuid: nextUUID)
        } catch {
            // saveFailed already presented; selection and tree stay put.
        }
    }

    private func uuidToSelectAfterDeleting(_ node: OutlineNode) -> UUID? {
        let siblings: [OutlineNode]
        if let parent = node.outlineParent {
            siblings = parent.outlineChildren
        } else {
            siblings = (try? model.allProjects()) ?? []
        }
        if let index = siblings.firstIndex(where: { $0.uuid == node.uuid }), index > 0 {
            return siblings[index - 1].uuid
        }
        return node.outlineParent?.uuid
    }

    @objc private func plannerSelectionDidChange(_ notification: Notification) {
        view.window?.toolbar?.validateVisibleItems()
    }

    private func isCommandEnabled(for action: Selector?) -> Bool {
        switch action {
        case #selector(newProject(_:)), #selector(revealToday(_:)):
            return true
        case #selector(newTask(_:)):
            return !isFirstResponderTextInput
                && (selectedOutlineNode is Project || selectedOutlineNode is TaskItem)
        case #selector(newSubtask(_:)):
            return !isFirstResponderTextInput && selectedOutlineNode is TaskItem
        case #selector(renameSelected(_:)), #selector(deleteSelected(_:)):
            return !isFirstResponderTextInput && selectedOutlineNode != nil
        default:
            return false
        }
    }
}

extension MainSplitViewController: NSMenuItemValidation, NSToolbarItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        isCommandEnabled(for: item.action)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        isCommandEnabled(for: item.action)
    }
}

extension NSToolbarItem.Identifier {
    static let addProject = NSToolbarItem.Identifier("AddProject")
    static let addTask = NSToolbarItem.Identifier("AddTask")
    static let addSubtask = NSToolbarItem.Identifier("AddSubtask")
    static let today = NSToolbarItem.Identifier("Today")
}

extension MainSplitViewController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.addProject, .addTask, .addSubtask, .flexibleSpace, .today]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item: NSToolbarItem
        switch itemIdentifier {
        case .addProject:
            item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Add Project"
            item.paletteLabel = "Add Project"
            item.toolTip = "Add Project"
            item.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "Add Project")
            item.action = #selector(newProject(_:))
        case .addTask:
            item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Add Task"
            item.paletteLabel = "Add Task"
            item.toolTip = "Add Task"
            item.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: "Add Task")
            item.action = #selector(newTask(_:))
        case .addSubtask:
            item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Add Subtask"
            item.paletteLabel = "Add Subtask"
            item.toolTip = "Add Subtask"
            item.image = NSImage(systemSymbolName: "plus.square.on.square", accessibilityDescription: "Add Subtask")
            item.action = #selector(newSubtask(_:))
        case .today:
            item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Today"
            item.paletteLabel = "Today"
            item.toolTip = "Today"
            item.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Today")
            item.action = #selector(revealToday(_:))
        default:
            return nil
        }

        item.target = self
        item.isBordered = true
        item.autovalidates = true
        return item
    }
}
