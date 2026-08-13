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
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        installToolbarIfNeeded()
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
        case .addTask:
            item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Add Task"
            item.paletteLabel = "Add Task"
            item.toolTip = "Add Task"
            item.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: "Add Task")
        case .addSubtask:
            item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Add Subtask"
            item.paletteLabel = "Add Subtask"
            item.toolTip = "Add Subtask"
            item.image = NSImage(systemSymbolName: "plus.square.on.square", accessibilityDescription: "Add Subtask")
        case .today:
            item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Today"
            item.paletteLabel = "Today"
            item.toolTip = "Today"
            item.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Today")
        default:
            return nil
        }

        item.isBordered = true
        item.autovalidates = false
        item.isEnabled = false
        return item
    }
}
