import AppKit

final class MainSplitViewController: NSSplitViewController {
    let persistence: PersistenceController
    let model: ModelController
    let selection: SelectionModel
    let events: EventCoordinator

    private let outlineViewController: OutlineViewController
    private let calendarViewController: CalendarViewController
    private let inspectorViewController: InspectorViewController
    private var sidebarSplitItem: NSSplitViewItem!
    private var calendarSplitItem: NSSplitViewItem!
    private var inspectorSplitItem: NSSplitViewItem!
    private let calendarTitleField = NSTextField(labelWithString: "")
    private let weekNavigationControl = NSSegmentedControl()
    private let eventStatusView = EventStatusView()
    /// Held so the item itself can be hidden. Hiding only the inner view still
    /// leaves the toolbar drawing an empty pill where the slot is.
    private var eventStatusToolbarItem: NSToolbarItem?
    /// Items that act on the outline, hidden while the sidebar is collapsed.
    private var sidebarToolbarItems: [NSToolbarItem] = []
    private var sidebarCollapseObservation: NSKeyValueObservation?

    private enum NavigationSegment: Int {
        case previous, today, next
    }

    init(
        persistence: PersistenceController,
        model: ModelController,
        selection: SelectionModel,
        events: EventCoordinator
    ) {
        self.persistence = persistence
        self.model = model
        self.selection = selection
        self.events = events
        outlineViewController = OutlineViewController(
            persistence: persistence,
            model: model,
            selection: selection
        )
        calendarViewController = CalendarViewController(
            persistence: persistence,
            model: model,
            selection: selection,
            events: events
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
        splitView.dividerStyle = .thin
        // v1 and v2 keys stored pane widths from the old two-pane and popover layouts.
        splitView.autosaveName = "MainHorizontalSplit.v3"

        // A real sidebar item supplies the source-list material, the inset row
        // metrics, and the toolbar/sidebar coordination that hand-rolled
        // thickness clamping used to approximate.
        let outlineItem = NSSplitViewItem(sidebarWithViewController: outlineViewController)
        outlineItem.minimumThickness = Self.sidebarMinimum
        outlineItem.maximumThickness = Self.sidebarMinimum * 2
        outlineItem.preferredThicknessFraction = 260.0 / 1100.0
        // Higher holding priority = resists resizing. The sidebar keeps its width
        // and the detail pane absorbs the slack, not the other way round.
        outlineItem.holdingPriority = NSLayoutConstraint.Priority(260)
        // Collapsible now that the toolbar carries a Hide Sidebar button, but not
        // from a window resize: the outline is the only place to create projects,
        // so it should only ever disappear because the user asked it to.
        outlineItem.canCollapse = true
        outlineItem.canCollapseFromWindowResize = false
        outlineItem.isCollapsed = false
        sidebarSplitItem = outlineItem

        let calendarItem = NSSplitViewItem(viewController: calendarViewController)
        calendarItem.minimumThickness = Self.detailMinimum
        calendarItem.holdingPriority = NSLayoutConstraint.Priority(240)
        calendarItem.canCollapse = false
        calendarSplitItem = calendarItem

        // Trailing inspector: a narrow column, not a full-width strip under the
        // calendar. `inspectorWithViewController:` supplies the standard material,
        // the trailing placement, and collapse behaviour.
        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorViewController)
        inspectorItem.minimumThickness = Self.inspectorMinimum
        inspectorItem.maximumThickness = Self.inspectorMaximum
        inspectorItem.preferredThicknessFraction = 300.0 / 1100.0
        inspectorItem.holdingPriority = NSLayoutConstraint.Priority(260)
        inspectorItem.canCollapse = true
        inspectorItem.canCollapseFromWindowResize = true
        inspectorItem.isCollapsed = false
        inspectorSplitItem = inspectorItem

        addSplitViewItem(outlineItem)
        addSplitViewItem(calendarItem)
        addSplitViewItem(inspectorItem)

        // KVO rather than only the toggle action: the divider can be dragged
        // shut, and the autosave can restore a collapsed sidebar at launch.
        sidebarCollapseObservation = outlineItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.updateSidebarToolbarItemVisibility()
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(plannerSelectionDidChange),
            name: .plannerSelectionDidChange,
            object: selection
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(eventsDidChange(_:)),
            name: .plannerEventsDidChange,
            object: events
        )
        // Undo and redo mutate the context in memory only; nothing saves on
        // their behalf, and the outline reacts to did-save. Saving here is what
        // makes ⌘Z of a create or delete appear anywhere — and survive a quit.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(undoManagerDidUndoOrRedo(_:)),
            name: .NSUndoManagerDidUndoChange,
            object: persistence.viewContext.undoManager
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(undoManagerDidUndoOrRedo(_:)),
            name: .NSUndoManagerDidRedoChange,
            object: persistence.viewContext.undoManager
        )
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        installToolbarIfNeeded()
    }

    // Holding priorities stay below NSLayoutConstraint.Priority(500): at
    // .defaultHigh a pane outranks the window's own resizing priority, so its
    // restored thickness becomes a hard window minimum that the split autosave
    // then feeds back, growing the window on every launch.
    private static let sidebarMinimum: CGFloat = 240
    private static let detailMinimum: CGFloat = 420
    private static let inspectorMinimum: CGFloat = 260
    private static let inspectorMaximum: CGFloat = 380

    @discardableResult
    func flushInspectorNotes() -> Bool {
        inspectorViewController.flushPendingNote()
    }

    private func installToolbarIfNeeded() {
        guard let window = view.window, window.toolbar == nil else { return }

        let toolbar = NSToolbar(identifier: "MainToolbar.v6")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        updateCalendarChrome()
        updateSidebarToolbarItemVisibility()
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
        guard let node = selectedOutlineNode else { return }
        do {
            let created = try model.createTask(under: node)
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

    @objc func showTaskInfo(_ sender: Any?) {
        guard !isFirstResponderTextInput else { return }
        revealInspector()
    }

    /// AppKit's own inspector toggle; overridden only to revalidate the toolbar.
    /// Unlike Get Info this needs no selection, so the pane can always be reclaimed.
    override func toggleInspector(_ sender: Any?) {
        super.toggleInspector(sender)
        view.window?.toolbar?.validateVisibleItems()
    }

    override func toggleSidebar(_ sender: Any?) {
        super.toggleSidebar(sender)
        view.window?.toolbar?.validateVisibleItems()
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
        selection.setVisibleWeekStart(Date())
    }

    @objc func goToPreviousWeek(_ sender: Any?) {
        shiftVisibleWeeks(by: -1)
    }

    @objc func goToNextWeek(_ sender: Any?) {
        shiftVisibleWeeks(by: 1)
    }

    private func shiftVisibleWeeks(by weeks: Int) {
        let target = Calendar.current.date(byAdding: .day, value: weeks * 7, to: selection.visibleWeekStart)!
        selection.setVisibleWeekStart(target)
    }

    /// The visible span depends on how many week columns fit, so the title has to
    /// be refreshed when the calendar re-flows, not only when the week changes.
    @objc func refreshCalendarTitle() {
        updateCalendarChrome()
    }

    /// Re-reads Outlook. The window is recomputed from today, so this doubles
    /// as the manual fix for a machine that slept through midnight.
    @objc func refreshCalendarEvents(_ sender: Any?) {
        events.refresh(userInitiated: true)
    }

    @objc private func eventsDidChange(_ notification: Notification) {
        updateEventStatus()
    }

    @objc private func undoManagerDidUndoOrRedo(_ notification: Notification) {
        // No-op when the context is clean (e.g. undoing rename keystrokes in
        // the title field editor, which shares this manager).
        persistence.saveViewContext(presentingWindow: view.window)
    }

    /// Only loading and failure have anything to say; the rest of the time the
    /// slot goes away entirely rather than sitting there empty.
    private var isEventStatusVisible: Bool {
        switch events.state {
        case .loading, .failed: return true
        case .idle, .loaded: return false
        }
    }

    private func updateEventStatus() {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        let window = events.window
        let lastDay = Calendar.current.date(byAdding: .day, value: -1, to: window.upperBound)
            ?? window.upperBound
        eventStatusToolbarItem?.isHidden = !isEventStatusVisible
        eventStatusView.apply(
            events.state,
            settingsURL: events.failureSettingsURL,
            detail: """
            \(events.sourceDisplayName)
            Events shown: \(formatter.string(from: window.lowerBound)) – \(formatter.string(from: lastDay))
            """
        )
    }

    var test_eventStatusView: EventStatusView { eventStatusView }
    var test_isEventStatusVisible: Bool { isEventStatusVisible }
    func test_updateEventStatus() { updateEventStatus() }

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
            return "Delete “\(node.title)” and all of its tasks?"
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

    /// Tasks and days both own a note; projects do not.
    private var hasNoteEditableSelection: Bool {
        selection.selectedDay != nil || selectedOutlineNode is TaskItem
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
        let fields = notification.userInfo?[SelectionUserInfoKey.changedFields] as? Set<String> ?? []
        if fields.contains(SelectionField.visibleWeek.rawValue) {
            updateCalendarChrome()
        }
    }

    /// Get Info targets the selection: it shows the inspector if hidden and puts
    /// the caret in the note. The inspector rebinds itself from `SelectionModel`.
    /// Both a task and a calendar day have a note, so both qualify.
    func revealInspector() {
        guard hasNoteEditableSelection, let inspectorSplitItem else { return }
        if inspectorSplitItem.isCollapsed {
            inspectorSplitItem.animator().isCollapsed = false
        }
        inspectorViewController.focusNote()
        view.window?.toolbar?.validateVisibleItems()
    }

    var isInspectorVisible: Bool {
        inspectorSplitItem.map { !$0.isCollapsed } ?? false
    }

    var isSidebarVisible: Bool {
        sidebarSplitItem.map { !$0.isCollapsed } ?? false
    }

    /// New Project / New Task act on the outline, so they go away with it. The
    /// sidebar toggle itself stays put — it is the way back.
    private func updateSidebarToolbarItemVisibility() {
        let collapsed = !isSidebarVisible
        for item in sidebarToolbarItems where item.isHidden != collapsed {
            item.isHidden = collapsed
        }
        updateLeadingSpace(collapsed: collapsed)
    }

    /// The leading flexible space is what pushes the sidebar group against the
    /// divider. With the sidebar shut there is no divider to hug, so drop the
    /// space and let the toggle sit beside the window buttons, as Preview does.
    private func updateLeadingSpace(collapsed: Bool) {
        guard let toolbar = view.window?.toolbar else { return }
        let hasLeadingSpace = toolbar.items.first?.itemIdentifier == .flexibleSpace
        if collapsed, hasLeadingSpace {
            toolbar.removeItem(at: 0)
        } else if !collapsed, !hasLeadingSpace {
            toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: 0)
        }
    }

    /// Span bold, year lighter — the "August 2026" treatment, in the toolbar.
    private func updateCalendarChrome() {
        let weekCount = calendarViewController.weekView.visibleWeekCount
        let parts = Calendar.current.weekRangeComponents(
            from: selection.visibleWeekStart,
            count: weekCount
        )
        let title = NSMutableAttributedString(
            string: parts.span,
            attributes: [
                .font: NSFont.systemFont(ofSize: 16, weight: .bold),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        title.append(NSAttributedString(
            string: " \(parts.year)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 16, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        ))
        calendarTitleField.attributedStringValue = title
        view.window?.title = Calendar.current.weekRangeString(
            from: selection.visibleWeekStart,
            count: weekCount
        )
    }

    @objc private func weekNavigationClicked(_ sender: NSSegmentedControl) {
        switch NavigationSegment(rawValue: sender.selectedSegment) {
        case .previous: goToPreviousWeek(sender)
        case .today: revealToday(sender)
        case .next: goToNextWeek(sender)
        case nil: break
        }
    }

    private func isCommandEnabled(for action: Selector?) -> Bool {
        switch action {
        case #selector(newProject(_:)), #selector(revealToday(_:)),
             #selector(goToPreviousWeek(_:)), #selector(goToNextWeek(_:)),
             #selector(toggleInspector(_:)), #selector(toggleSidebar(_:)):
            return true
        case #selector(refreshCalendarEvents(_:)):
            // Refreshing while one is in flight would just cancel and restart
            // it, which looks like the command did nothing.
            return !isFirstResponderTextInput && events.state != .loading
        case #selector(newTask(_:)):
            return !isFirstResponderTextInput
                && (selectedOutlineNode is Project || selectedOutlineNode is TaskItem)
        case #selector(renameSelected(_:)), #selector(deleteSelected(_:)):
            return !isFirstResponderTextInput && selectedOutlineNode != nil
        case #selector(showTaskInfo(_:)):
            return !isFirstResponderTextInput && hasNoteEditableSelection
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
    static let paneSeparator = NSToolbarItem.Identifier("PaneSeparator")
    static let inspectorSeparator = NSToolbarItem.Identifier("InspectorSeparator")
    static let calendarTitle = NSToolbarItem.Identifier("CalendarTitle")
    static let weekNavigation = NSToolbarItem.Identifier("WeekNavigation")
    static let today = NSToolbarItem.Identifier("Today")
    static let eventStatus = NSToolbarItem.Identifier("EventStatus")
    static let getInfo = NSToolbarItem.Identifier("GetInfo")
}

extension MainSplitViewController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Tracking separators pin to both split dividers. The leading flexible
        // space pushes the sidebar's own group up against the first divider, so
        // it hugs the splitter the way the inspector toggle hugs the second one.
        // Everything between the separators sits over the calendar pane: title
        // hard left, navigation hard right.
        [
            // AppKit supplies `.toggleSidebar` itself; the delegate returns nil
            // for it and the system item renders as its own pill.
            .flexibleSpace, .addProject, .addTask, .toggleSidebar,
            .paneSeparator,
            .calendarTitle, .eventStatus, .flexibleSpace, .weekNavigation,
            .inspectorSeparator,
            .getInfo,
        ]
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
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Task")
            item.action = #selector(newTask(_:))
        case .paneSeparator:
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier,
                splitView: splitView,
                dividerIndex: 0
            )
        case .inspectorSeparator:
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier,
                splitView: splitView,
                dividerIndex: 1
            )
        case .calendarTitle:
            return makeCalendarTitleItem()
        case .weekNavigation:
            return makeWeekNavigationItem()
        case .eventStatus:
            return makeEventStatusItem()
        case .getInfo:
            item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Inspector"
            item.paletteLabel = "Inspector"
            item.toolTip = "Show or hide the inspector"
            item.image = NSImage(systemSymbolName: "sidebar.trailing", accessibilityDescription: "Inspector")
            item.action = #selector(toggleInspector(_:))
        default:
            return nil
        }

        item.target = self
        item.isBordered = true
        item.autovalidates = true

        if itemIdentifier == .addProject || itemIdentifier == .addTask {
            sidebarToolbarItems.removeAll { $0.itemIdentifier == itemIdentifier }
            sidebarToolbarItems.append(item)
            item.isHidden = !isSidebarVisible
        }
        return item
    }

    private func makeCalendarTitleItem() -> NSToolbarItem {
        calendarTitleField.lineBreakMode = .byTruncatingTail
        calendarTitleField.refusesFirstResponder = true
        calendarTitleField.setContentHuggingPriority(.required, for: .horizontal)
        calendarTitleField.removeFromSuperview()
        updateCalendarChrome()

        let item = NSToolbarItem(itemIdentifier: .calendarTitle)
        item.view = calendarTitleField
        item.label = "Dates"
        item.paletteLabel = "Dates"
        item.visibilityPriority = .low   // the first thing to drop when cramped
        return item
    }

    /// Sits immediately after the range label, inside the calendar pane's
    /// tracked span, so the feed's state reads as belonging to the calendar
    /// rather than to the window.
    private func makeEventStatusItem() -> NSToolbarItem {
        eventStatusView.onRetry = { [weak self] in self?.events.refresh(userInitiated: true) }
        eventStatusView.onOpenAutomationSettings = { [weak self] in
            guard let url = self?.events.failureSettingsURL else { return }
            NSWorkspace.shared.open(url)
        }
        eventStatusView.translatesAutoresizingMaskIntoConstraints = false
        eventStatusView.setContentHuggingPriority(.required, for: .horizontal)

        let item = NSToolbarItem(itemIdentifier: .eventStatus)
        item.label = "Calendar Events"
        item.paletteLabel = "Calendar Events"
        item.view = eventStatusView
        // Not a command: it is a status light that occasionally becomes a
        // button, so it must never be dimmed by toolbar validation.
        item.autovalidates = false
        eventStatusToolbarItem = item
        updateEventStatus()
        return item
    }

    private func makeWeekNavigationItem() -> NSToolbarItem {
        weekNavigationControl.segmentStyle = .rounded
        weekNavigationControl.trackingMode = .momentary
        weekNavigationControl.segmentCount = 3
        weekNavigationControl.setImage(
            NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous week"),
            forSegment: NavigationSegment.previous.rawValue
        )
        weekNavigationControl.setLabel("Today", forSegment: NavigationSegment.today.rawValue)
        weekNavigationControl.setImage(
            NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next week"),
            forSegment: NavigationSegment.next.rawValue
        )
        weekNavigationControl.setWidth(30, forSegment: NavigationSegment.previous.rawValue)
        weekNavigationControl.setWidth(30, forSegment: NavigationSegment.next.rawValue)
        weekNavigationControl.target = self
        weekNavigationControl.action = #selector(weekNavigationClicked(_:))
        weekNavigationControl.removeFromSuperview()

        let item = NSToolbarItem(itemIdentifier: .weekNavigation)
        item.view = weekNavigationControl
        item.label = "Week"
        item.paletteLabel = "Week"
        item.toolTip = "Previous week, this week, next week"
        return item
    }
}
