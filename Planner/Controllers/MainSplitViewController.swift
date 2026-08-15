import AppKit

final class MainSplitViewController: NSSplitViewController {
    let persistence: PersistenceController
    let model: ModelController
    let selection: SelectionModel
    let events: EventCoordinator
    let mail: MailCoordinator

    let outlineViewController: OutlineViewController
    private let calendarViewController: CalendarViewController
    private let inspectorViewController: InspectorViewController
    let mailboxListViewController: MailboxListViewController
    let mailListViewController: MailListViewController
    let mailReaderViewController: MailReaderViewController

    /// The one pane that survives a mode switch. See `ModeContainerViewController`.
    private let sidebarContainer = ModeContainerViewController()
    private var sidebarSplitItem: NSSplitViewItem!
    private var calendarSplitItem: NSSplitViewItem!
    private var inspectorSplitItem: NSSplitViewItem!
    private var mailListSplitItem: NSSplitViewItem!
    private var mailReaderSplitItem: NSSplitViewItem!
    /// Nil until the first `applyMode`, so launch always runs the full swap.
    private var appliedMode: PlannerMode?
    /// Divider 1 is per-mode; divider 0 is shared. See `applyMode`.
    private var middlePaneWidths: [PlannerMode: CGFloat] = [:]
    private var trailingCollapsed: [PlannerMode: Bool] = [:]

    private let calendarTitleField = NSTextField(labelWithString: "")
    private let mailTitleField = NSTextField(labelWithString: "")
    private let weekNavigationControl = NSSegmentedControl()
    private let sidebarModeControl = NSSegmentedControl()
    private let eventStatusView = EventStatusView()
    /// Held so the item itself can be hidden. Hiding only the inner view still
    /// leaves the toolbar drawing an empty pill where the slot is.
    private var eventStatusToolbarItem: NSToolbarItem?
    /// Items that act on the sidebar's content, hidden while it is collapsed.
    private var sidebarToolbarItems: [NSToolbarItem] = []
    private var sidebarCollapseObservation: NSKeyValueObservation?
    private weak var windowRangeButton: NSPopUpButton?
    private let userDefaults: UserDefaults

    private enum NavigationSegment: Int {
        case previous, today, next
    }

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
        mailboxListViewController = MailboxListViewController(
            persistence: persistence,
            model: model,
            selection: selection,
            mail: mail
        )
        mailListViewController = MailListViewController(
            persistence: persistence,
            model: model,
            selection: selection,
            mail: mail
        )
        mailReaderViewController = MailReaderViewController(
            persistence: persistence,
            model: model,
            selection: selection,
            mail: mail
        )
        super.init(nibName: nil, bundle: nil)
        // The list is where a folder is threaded; the reader asks it rather
        // than threading the same folder a second time and risking a different
        // answer.
        mailReaderViewController.conversationProvider = { [weak self] uuid in
            self?.mailListViewController.conversation(containing: uuid) ?? []
        }
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
        // v1 and v2 keys stored pane widths from the old two-pane and popover
        // layouts; v3 predates mail mode, whose trailing panes want inverted
        // proportions from the calendar's.
        splitView.autosaveName = "MainHorizontalSplit.v4"

        // A real sidebar item supplies the source-list material, the inset row
        // metrics, and the toolbar/sidebar coordination that hand-rolled
        // thickness clamping used to approximate.
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarContainer)
        sidebarItem.minimumThickness = Self.sidebarMinimum
        sidebarItem.maximumThickness = Self.sidebarMinimum * 2
        sidebarItem.preferredThicknessFraction = 260.0 / 1100.0
        // Higher holding priority = resists resizing. The sidebar keeps its width
        // and the detail pane absorbs the slack, not the other way round.
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        // Collapsible now that the toolbar carries a Hide Sidebar button, but not
        // from a window resize: the sidebar is the only place to create projects
        // and folders, so it should only ever disappear because the user asked.
        sidebarItem.canCollapse = true
        sidebarItem.canCollapseFromWindowResize = false
        sidebarItem.isCollapsed = false
        sidebarSplitItem = sidebarItem

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

        // Mail's trailing pair is the calendar pair's proportions inverted: a
        // narrow list that keeps its width, and a reader that takes the slack.
        // Separate items rather than one pair with mutated constraints, because
        // the differences include item *style* — content-list versus inspector
        // — which is fixed at init.
        let mailListItem = NSSplitViewItem(contentListWithViewController: mailListViewController)
        mailListItem.minimumThickness = Self.mailListMinimum
        mailListItem.maximumThickness = Self.mailListMaximum
        mailListItem.holdingPriority = NSLayoutConstraint.Priority(260)
        mailListItem.canCollapse = false
        mailListSplitItem = mailListItem

        let mailReaderItem = NSSplitViewItem(viewController: mailReaderViewController)
        mailReaderItem.minimumThickness = Self.mailReaderMinimum
        mailReaderItem.holdingPriority = NSLayoutConstraint.Priority(240)
        // Collapsible only from a window resize: the reader is the point of
        // mail mode, so nothing offers to hide it, but a window dragged narrower
        // than both minimums must give somewhere rather than refusing to shrink.
        mailReaderItem.canCollapse = true
        mailReaderItem.canCollapseFromWindowResize = true
        mailReaderItem.isCollapsed = false
        mailReaderSplitItem = mailReaderItem

        addSplitViewItem(sidebarItem)
        applyMode(selection.mode)

        // KVO rather than only the toggle action: the divider can be dragged
        // shut, and the autosave can restore a collapsed sidebar at launch.
        sidebarCollapseObservation = sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.updateToolbarItemVisibility()
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
    // Chosen so both modes' minimum sums come to the same 920: switching modes
    // can then never be the thing that forces the window wider.
    private static let mailListMinimum: CGFloat = 300
    private static let mailListMaximum: CGFloat = 520
    private static let mailReaderMinimum: CGFloat = 380
    /// Where divider 1 sits in mail mode the first time it is entered.
    private static let mailListDefaultWidth: CGFloat = 384

    /// Stored as the *middle pane's width* rather than divider 1's absolute
    /// position, which is what the plan called for: a position is measured from
    /// the window's leading edge, so it silently encodes the sidebar's width
    /// too, and restoring one after the sidebar has been dragged puts the
    /// trailing panes in the wrong place.
    private static let middleWidthDefaultsKeys: [PlannerMode: String] = [
        .tasks: "tasks.middlePaneWidth",
        .mail: "mail.middlePaneWidth",
    ]
    private static let trailingCollapseDefaultsKeys: [PlannerMode: String] = [
        .tasks: "tasks.trailingCollapsed",
        .mail: "mail.trailingCollapsed",
    ]

    // MARK: - Mode

    /// Swaps the sidebar's content and replaces the two trailing panes.
    ///
    /// Divider 0 and the sidebar's collapse state are deliberately untouched:
    /// a frozen sidebar makes the switch read as "the content changed" rather
    /// than "the layout rearranged", which is the effect Preview gets swapping
    /// Thumbnails for a Table of Contents. Divider 1 is per-mode, restored in
    /// the same layout pass and **unanimated** — a jump cut is invisible while
    /// all three panes' content is replaced, whereas animating would slide the
    /// toolbar's tracking separator after the cut.
    private func applyMode(_ mode: PlannerMode) {
        guard appliedMode != mode else { return }
        let outgoing = appliedMode
        if outgoing == .tasks { flushInspectorNotes() }
        if let outgoing { recordTrailingGeometry(for: outgoing) }
        // Captured before the panes come out: with only the sidebar left the
        // split view spreads it across the whole window, and re-adding two
        // items redistributes from *that* rather than from where it was.
        let sidebarWidth = paneFrame(at: 0)?.width

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false

            while splitViewItems.count > 1 {
                removeSplitViewItem(splitViewItems[splitViewItems.count - 1])
            }
            sidebarContainer.show(mode == .tasks ? outlineViewController : mailboxListViewController)

            switch mode {
            case .tasks:
                addSplitViewItem(calendarSplitItem)
                addSplitViewItem(inspectorSplitItem)
            case .mail:
                addSplitViewItem(mailListSplitItem)
                addSplitViewItem(mailReaderSplitItem)
            }

            appliedMode = mode
            view.layoutSubtreeIfNeeded()
            // Divider 0 first, and only then divider 1: the sidebar is shared
            // across modes and must land back exactly where it was before the
            // trailing pair gets a say in the layout.
            if let sidebarWidth, sidebarWidth > 0, !sidebarSplitItem.isCollapsed {
                splitView.setPosition(sidebarWidth, ofDividerAt: 0)
                view.layoutSubtreeIfNeeded()
            }
            restoreTrailingGeometry(for: mode)
            view.layoutSubtreeIfNeeded()
        }

        rebuildToolbarItems()
        updateToolbarItemVisibility()
        updateChrome()
        view.window?.toolbar?.validateVisibleItems()
    }

    private func trailingItem(for mode: PlannerMode) -> NSSplitViewItem? {
        mode == .tasks ? inspectorSplitItem : mailReaderSplitItem
    }

    /// A pane's rectangle in the split view's own coordinates.
    ///
    /// **Not** `splitView.subviews[index]`: an `NSSplitViewController`'s split
    /// view carries the dividers and its own chrome as subviews too, in an
    /// order that has nothing to do with pane order — measuring by index there
    /// silently reads the wrong pane.
    private func paneFrame(at index: Int) -> CGRect? {
        guard index < splitViewItems.count else { return nil }
        let paneView = splitViewItems[index].viewController.view
        guard paneView.superview != nil else { return nil }
        return paneView.convert(paneView.bounds, to: splitView)
    }

    /// Captures divider 1 and the trailing pane's collapse state for the mode
    /// being left. Recorded in memory *and* in defaults: the split view's own
    /// autosave cannot serve two geometries under one name, and quitting while
    /// in mail mode would otherwise leave it holding mail's numbers.
    private func recordTrailingGeometry(for mode: PlannerMode) {
        guard splitViewItems.count == 3 else { return }
        let collapsed = trailingItem(for: mode)?.isCollapsed ?? false
        trailingCollapsed[mode] = collapsed
        if let key = Self.trailingCollapseDefaultsKeys[mode] {
            userDefaults.set(collapsed, forKey: key)
        }

        // A collapsed trailing pane has no width worth remembering; keeping the
        // last real one means reopening lands where the user left it.
        guard !collapsed else { return }
        guard let width = paneFrame(at: 1)?.width, width > 0 else { return }
        middlePaneWidths[mode] = width
        if let key = Self.middleWidthDefaultsKeys[mode] {
            userDefaults.set(Double(width), forKey: key)
        }
    }

    /// Restores the trailing pair's collapse state and divider 1.
    ///
    /// Each step gets its own layout pass. Setting a divider before the split
    /// view has settled the one before it makes AppKit resolve the conflict by
    /// squeezing whichever pane is cheapest — which, with the sidebar leading,
    /// is the sidebar, and the sidebar is the one thing that must not move.
    private func restoreTrailingGeometry(for mode: PlannerMode) {
        guard let item = trailingItem(for: mode), splitViewItems.count == 3 else { return }
        // An inherited collapsed state would open mail with no reading pane,
        // which reads as broken rather than as collapsed.
        item.isCollapsed = storedTrailingCollapsed(for: mode)
        view.layoutSubtreeIfNeeded()

        guard !item.isCollapsed,
              let width = storedMiddleWidth(for: mode),
              let sidebarEdge = paneFrame(at: 0)?.maxX
        else { return }
        splitView.setPosition(sidebarEdge + splitView.dividerThickness + width, ofDividerAt: 1)
    }

    private func storedTrailingCollapsed(for mode: PlannerMode) -> Bool {
        if let collapsed = trailingCollapsed[mode] { return collapsed }
        guard let key = Self.trailingCollapseDefaultsKeys[mode] else { return false }
        return userDefaults.bool(forKey: key)
    }

    /// The remembered middle-pane width, or — the first time mail mode is
    /// entered — a sensible list width rather than half the window. Tasks has
    /// no fallback: with nothing stored, the split view's own autosave is
    /// already holding the calendar where the user left it.
    private func storedMiddleWidth(for mode: PlannerMode) -> CGFloat? {
        if let width = middlePaneWidths[mode] { return width }
        if let key = Self.middleWidthDefaultsKeys[mode] {
            let stored = userDefaults.double(forKey: key)
            if stored > 0 { return CGFloat(stored) }
        }
        return mode == .mail ? Self.mailListDefaultWidth : nil
    }

    @objc func showTasksMode(_ sender: Any?) {
        selection.setMode(.tasks)
    }

    @objc func showMailMode(_ sender: Any?) {
        selection.setMode(.mail)
    }

    var isMailMode: Bool { selection.mode == .mail }

    @discardableResult
    func flushInspectorNotes() -> Bool {
        inspectorViewController.flushPendingNote()
    }

    private func installToolbarIfNeeded() {
        guard let window = view.window, window.toolbar == nil else { return }

        // v7: the sidebar slot became a segmented control with a mode menu, and
        // the mail items joined the set.
        let toolbar = NSToolbar(identifier: "MainToolbar.v7")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        updateChrome()
        updateToolbarItemVisibility()
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

    /// A new folder arrives named and selected but not yet titled, so it goes
    /// straight into rename — the same bargain New Project makes.
    @objc func newMailFolder(_ sender: Any?) {
        guard !isFirstResponderTextInput else { return }
        do {
            let folder = try model.createMailFolder()
            selection.setMode(.mail)
            selection.selectMailbox(.folder(folder.uuid))
            DispatchQueue.main.async { [weak self] in
                self?.mailboxListViewController.beginEditingName(of: folder)
            }
        } catch {
            // saveFailed already presented; leave the selection alone.
        }
    }

    // MARK: - Saving mail

    /// Copies the open Recent Mail message into a folder.
    ///
    /// The body is fetched **first**: a saved message with no body is worse
    /// than no saved message, because it looks like it worked. A failed fetch
    /// therefore saves nothing and says so.
    @objc func saveMessageToFolder(_ sender: Any?) {
        guard case let .recent(id)? = selection.message, let envelope = mail.message(id: id) else {
            return
        }
        let folder = (sender as? NSMenuItem)?.representedObject as? MailFolder
        Task { [weak self] in await self?.save(envelope, into: folder) }
    }

    private func save(_ envelope: MailMessage, into folder: MailFolder?) async {
        var target = folder
        var created = false
        if target == nil {
            guard let new = try? model.createMailFolder() else { return }
            target = new
            created = true
        }
        guard let target else { return }

        do {
            let detail = try await mail.loadDetail(for: envelope.id)
            let saved = try model.saveMessage(envelope, detail: detail, into: target)
            if created {
                // A folder made on the way to saving still needs a name, and
                // the message it was made for is the best reminder of why.
                selection.selectMailbox(.folder(target.uuid))
                mailboxListViewController.beginEditingName(of: target)
            }
            PlannerLog.mail.info("Saved message \(saved.outlookID, privacy: .public)")
        } catch {
            // Nothing was written, including the folder if this call made one.
            if created { try? model.deleteMailFolder(target) }
            present(error)
        }
    }

    /// Brings the original up in Outlook. Always explicit: opening an unread
    /// message marks it read upstream, which is a write Planner will not make
    /// on the user's behalf.
    /// Lands with the New Task PR; declared here so the reader's button and the
    /// list's context menu can bind to it now.
    @objc func newTaskFromMessage(_ sender: Any?) {}

    @objc func openMessageInOutlook(_ sender: Any?) {
        guard let id = outlookIDOfSelectedMessage else { return }
        Task { [weak self] in
            guard let self else { return }
            do { try await mail.reveal(messageID: id) } catch { present(error) }
        }
    }

    private var outlookIDOfSelectedMessage: Int64? {
        switch selection.message {
        case let .recent(id)?:
            return id
        case let .saved(uuid)?:
            // Best-effort: a saved message keeps the id it had at save time,
            // and Outlook may have moved on.
            let stored = model.savedMessage(uuid: uuid)?.outlookID ?? 0
            return stored == 0 ? nil : stored
        case nil:
            return nil
        }
    }

    @objc func moveMessageToFolder(_ sender: Any?) {
        guard let message = selectedSavedMessage else { return }
        var target = (sender as? NSMenuItem)?.representedObject as? MailFolder
        if target == nil { target = try? model.createMailFolder() }
        guard let target else { return }
        do {
            try model.moveMessage(message, to: target)
            selection.selectMailbox(.folder(target.uuid))
            selection.selectMessage(.saved(message.uuid))
        } catch {
            // saveFailed already presented.
        }
    }

    /// Removing is deleting Planner's only copy, so it asks — but only when it
    /// really is the only one. A message filed in two folders can lose one of
    /// them without ceremony.
    @objc func removeSavedMessage(_ sender: Any?) {
        guard let message = selectedSavedMessage else { return }
        guard copiesElsewhere(of: message) == 0 else {
            performRemove(message)
            return
        }
        confirm(message: Self.removeConfirmationMessage(for: message)) { [weak self] confirmed in
            guard confirmed else { return }
            self?.performRemove(message)
        }
    }

    /// Tests pass a result to skip the confirmation sheet.
    func removeSavedMessage(confirmed: Bool) {
        guard confirmed, let message = selectedSavedMessage else { return }
        performRemove(message)
    }

    private func performRemove(_ message: SavedMessage) {
        do {
            try model.removeMessage(message)
            selection.selectMessage(nil)
        } catch {
            // saveFailed already presented.
        }
    }

    private func copiesElsewhere(of message: SavedMessage) -> Int {
        model.mailFolders()
            .filter { $0.objectID != message.folder?.objectID }
            .reduce(0) { count, folder in
                count + folder.messages.filter { $0.messageID == message.messageID }.count
            }
    }

    static func removeConfirmationMessage(for message: SavedMessage) -> String {
        let subject = message.subject.isEmpty ? "this message" : "“\(message.subject)”"
        return "Remove \(subject)? This is Planner's only copy."
    }

    private var selectedSavedMessage: SavedMessage? {
        guard case let .saved(uuid)? = selection.message else { return nil }
        return model.savedMessage(uuid: uuid)
    }

    private func present(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.informativeText = (error as? LocalizedError)?.recoverySuggestion ?? ""
        alert.alertStyle = .warning
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc func renameSelected(_ sender: Any?) {
        guard !isFirstResponderTextInput else { return }
        if isMailMode {
            guard let folder = selectedMailFolder else { return }
            mailboxListViewController.beginEditingName(of: folder)
            return
        }
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
        if isMailMode {
            guard let folder = selectedMailFolder else { return }
            confirm(message: Self.deleteConfirmationMessage(for: folder)) { [weak self] confirmed in
                guard confirmed else { return }
                self?.performConfirmedDelete(folder)
            }
            return
        }
        guard let node = selectedOutlineNode else { return }
        confirm(message: Self.deleteConfirmationMessage(for: node)) { [weak self] confirmed in
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
        updateChrome()
    }

    /// Re-reads Outlook mail. Like the calendar's, the window is recomputed
    /// from today, so this doubles as the fix for a machine that slept through
    /// midnight.
    @objc func refreshMailMessages(_ sender: Any?) {
        mail.refresh(userInitiated: true)
    }

    /// Routes ⌘R to whichever feed the current mode is showing.
    @objc func refreshCurrentMode(_ sender: Any?) {
        if isMailMode {
            refreshMailMessages(sender)
        } else {
            refreshCalendarEvents(sender)
        }
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
    /// The split item holds a container, so the sidebar's actual content is a
    /// child of a child — which the mode tests are precisely about.
    var test_sidebarChild: NSViewController? { sidebarContainer.current }
    /// The window title is computed here even when there is no window to set it
    /// on, which is the case in tests.
    var test_windowTitle: String { isMailMode ? mailWindowTitle : calendarWindowTitle }
    /// Pane widths in pane order, which `splitView.subviews` does not give.
    var test_paneWidths: [CGFloat] {
        (0..<splitViewItems.count).map { paneFrame(at: $0)?.width ?? 0 }
    }

    /// Tests assign a responder so validation/actions see a text input without hosting the split in a window.
    var firstResponderForValidation: NSResponder?

    /// Tests pass a result to skip the confirmation sheet.
    func deleteSelected(confirmed: Bool) {
        guard confirmed else { return }
        if isMailMode {
            guard let folder = selectedMailFolder else { return }
            performConfirmedDelete(folder)
            return
        }
        guard let node = selectedOutlineNode else { return }
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

    /// Names the cascade, because it is the surprising part: the messages in a
    /// folder are Planner's only copies, and deleting the folder discards them.
    /// The Outlook originals are untouched either way, which the wording says
    /// so the user is not left guessing.
    static func deleteConfirmationMessage(for folder: MailFolder) -> String {
        let count = folder.messages.count
        guard count > 0 else { return "Delete “\(folder.name)”?" }
        return "Delete “\(folder.name)” and the \(MailLabels.messageCount(count)) saved in it?"
            + " The originals in Outlook aren’t affected."
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

    /// Nil when Recent Mail is selected: it is a view over Outlook, not a
    /// folder, so nothing that acts on a folder applies to it.
    private var selectedMailFolder: MailFolder? {
        guard let uuid = selection.selectedFolderUUID else { return nil }
        return model.mailFolders().first { $0.uuid == uuid }
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

    private func confirm(message: String, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
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

    /// Falls back to Recent Mail, which is always there — unlike a project,
    /// there is no "no mailbox" state to land in.
    private func performConfirmedDelete(_ folder: MailFolder) {
        let siblings = model.mailFolders()
        let index = siblings.firstIndex { $0.uuid == folder.uuid }
        let next = index.flatMap { $0 > 0 ? siblings[$0 - 1] : nil }
        do {
            try model.deleteMailFolder(folder)
            selection.selectMailbox(next.map { .folder($0.uuid) } ?? .recent)
        } catch {
            // saveFailed already presented; selection and sidebar stay put.
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
        if fields.contains(SelectionField.mode.rawValue) {
            applyMode(selection.mode)
            focusPreferredResponder()
        }
        // The mail title names the open mailbox, so it follows the sidebar.
        if fields.contains(SelectionField.visibleWeek.rawValue)
            || fields.contains(SelectionField.mailbox.rawValue) {
            updateChrome()
        }
    }

    /// Puts the caret back where the mode expects it, so ⌘1/⌘2 leaves the
    /// keyboard usable without a click.
    private func focusPreferredResponder() {
        guard let window = view.window else { return }
        switch selection.mode {
        case .tasks:
            window.makeFirstResponder(outlineViewController.outlineView)
        case .mail:
            window.makeFirstResponder(mailListViewController.view)
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

    /// New Project / New Task / New Folder act on the sidebar's content, so
    /// they go away with it. The sidebar toggle itself stays put — it is the
    /// way back. Which mode an item belongs to is settled by the toolbar's
    /// contents, not here.
    private func updateToolbarItemVisibility() {
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

    /// Both modes keep a title in the same slot, and the window title follows
    /// whichever one is showing.
    private func updateChrome() {
        updateCalendarChrome()
        updateMailChrome()
        view.window?.title = isMailMode ? mailWindowTitle : calendarWindowTitle
    }

    private var calendarWindowTitle: String {
        Calendar.current.weekRangeString(
            from: selection.visibleWeekStart,
            count: calendarViewController.weekView.visibleWeekCount
        )
    }

    /// Named for what it shows, not for the feature: "Recent Mail" is a rolling
    /// window, and a folder is a folder.
    private var mailWindowTitle: String {
        MailLabels.mailboxTitle(
            mailbox: selection.mailbox,
            windowDays: mail.windowDays,
            folderName: selectedFolderName
        )
    }

    private var selectedFolderName: String? {
        guard let uuid = selection.selectedFolderUUID else { return nil }
        return model.mailFolders().first { $0.uuid == uuid }?.name
    }

    private func updateMailChrome() {
        mailTitleField.attributedStringValue = Self.toolbarTitle(
            bold: mailWindowTitle,
            trailing: nil
        )
        // The window length is a property of Recent Mail. Over a folder it
        // would be offering to change something the pane does not show.
        windowRangeButton?.isEnabled = selection.isRecentMailSelected
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
    }

    /// The toolbar's title treatment: the name bold, an optional qualifier
    /// lighter beside it — the same shape as the calendar's "August 2026".
    private static func toolbarTitle(bold: String, trailing: String?) -> NSAttributedString {
        let title = NSMutableAttributedString(
            string: bold,
            attributes: [
                .font: NSFont.systemFont(ofSize: 16, weight: .bold),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        if let trailing {
            title.append(NSAttributedString(
                string: " \(trailing)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 16, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ))
        }
        return title
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
        case #selector(toggleSidebar(_:)), #selector(showTasksMode(_:)), #selector(showMailMode(_:)):
            // Always available: they are how the user gets between the two
            // modes and back to a sidebar they shut.
            return true
        case #selector(revealToday(_:)), #selector(goToPreviousWeek(_:)),
             #selector(goToNextWeek(_:)), #selector(toggleInspector(_:)):
            return !isMailMode
        case #selector(newProject(_:)):
            return !isMailMode
        case #selector(newMailFolder(_:)):
            return isMailMode && !isFirstResponderTextInput
        case #selector(saveMessageToFolder(_:)):
            guard case .recent? = selection.message else { return false }
            return isMailMode
        case #selector(moveMessageToFolder(_:)), #selector(removeSavedMessage(_:)):
            return isMailMode && selectedSavedMessage != nil
        case #selector(openMessageInOutlook(_:)):
            return isMailMode && outlookIDOfSelectedMessage != nil
        case #selector(newTaskFromMessage(_:)):
            // Lands with the New Task PR.
            return false
        case #selector(refreshCalendarEvents(_:)):
            // Refreshing while one is in flight would just cancel and restart
            // it, which looks like the command did nothing.
            return !isMailMode && !isFirstResponderTextInput && events.state != .loading
        case #selector(refreshCurrentMode(_:)):
            guard !isFirstResponderTextInput else { return false }
            return isMailMode ? !mail.isLoading : events.state != .loading
        case #selector(newTask(_:)):
            return !isMailMode && !isFirstResponderTextInput
                && (selectedOutlineNode is Project || selectedOutlineNode is TaskItem)
        case #selector(renameSelected(_:)), #selector(deleteSelected(_:)):
            guard !isFirstResponderTextInput else { return false }
            // Recent Mail is not a folder: it cannot be renamed or deleted.
            return isMailMode ? selectedMailFolder != nil : selectedOutlineNode != nil
        case #selector(showTaskInfo(_:)):
            return !isMailMode && !isFirstResponderTextInput && hasNoteEditableSelection
        default:
            return false
        }
    }

    /// Mode items are radio buttons across the View menu and the sidebar
    /// control's attached menu, so validation also has to say which is on.
    private func updateModeMenuItemState(_ item: NSMenuItem) {
        switch item.action {
        case #selector(showTasksMode(_:)): item.state = isMailMode ? .off : .on
        case #selector(showMailMode(_:)): item.state = isMailMode ? .on : .off
        default: break
        }
    }
}

extension MainSplitViewController: NSMenuItemValidation, NSToolbarItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        updateModeMenuItemState(item)
        return isCommandEnabled(for: item.action)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        isCommandEnabled(for: item.action)
    }
}

extension NSToolbarItem.Identifier {
    static let addProject = NSToolbarItem.Identifier("AddProject")
    static let addTask = NSToolbarItem.Identifier("AddTask")
    static let newMailFolder = NSToolbarItem.Identifier("NewMailFolder")
    static let sidebarMode = NSToolbarItem.Identifier("SidebarMode")
    static let paneSeparator = NSToolbarItem.Identifier("PaneSeparator")
    static let inspectorSeparator = NSToolbarItem.Identifier("InspectorSeparator")
    static let calendarTitle = NSToolbarItem.Identifier("CalendarTitle")
    static let mailTitle = NSToolbarItem.Identifier("MailTitle")
    static let weekNavigation = NSToolbarItem.Identifier("WeekNavigation")
    static let windowRange = NSToolbarItem.Identifier("WindowRange")
    static let today = NSToolbarItem.Identifier("Today")
    static let eventStatus = NSToolbarItem.Identifier("EventStatus")
    static let refreshMail = NSToolbarItem.Identifier("RefreshMail")
    static let getInfo = NSToolbarItem.Identifier("GetInfo")
}

extension MainSplitViewController: NSToolbarDelegate {
    /// Only the current mode's items.
    ///
    /// Tracking separators pin to both split dividers, and they bind to the
    /// split view rather than to the items, so they survive both the per-mode
    /// swap of the trailing panes and this rebuild. The leading flexible space
    /// pushes the sidebar's own group up against the first divider, so it hugs
    /// the splitter the way the inspector toggle hugs the second one.
    /// Everything between the separators sits over the middle pane: title hard
    /// left, controls hard right.
    ///
    /// The alternative — one list holding both modes' items, hidden by mode —
    /// does not work: a hidden item still counts toward the toolbar's width, so
    /// carrying the other mode's items pushes real ones into the overflow menu.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        identifiers(for: selection.mode)
    }

    func identifiers(for mode: PlannerMode) -> [NSToolbarItem.Identifier] {
        switch mode {
        case .tasks:
            return [
                .flexibleSpace, .addProject, .addTask, .sidebarMode,
                .paneSeparator,
                .calendarTitle, .eventStatus, .flexibleSpace, .weekNavigation,
                .inspectorSeparator,
                .getInfo,
            ]
        case .mail:
            return [
                .flexibleSpace, .newMailFolder, .sidebarMode,
                .paneSeparator,
                .mailTitle, .flexibleSpace, .windowRange, .refreshMail,
                .inspectorSeparator,
            ]
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        identifiers(for: .tasks) + identifiers(for: .mail)
    }

    /// Swaps the toolbar's contents to the current mode's, in one pass.
    private func rebuildToolbarItems() {
        guard let toolbar = view.window?.toolbar else { return }
        var wanted = identifiers(for: selection.mode)
        // The leading space is dropped while the sidebar is shut; leaving it in
        // the comparison would rebuild the toolbar on every validation pass.
        if !isSidebarVisible, wanted.first == .flexibleSpace { wanted.removeFirst() }
        guard toolbar.items.map(\.itemIdentifier) != wanted else { return }
        while !toolbar.items.isEmpty { toolbar.removeItem(at: 0) }
        for (index, identifier) in wanted.enumerated() {
            toolbar.insertItem(withItemIdentifier: identifier, at: index)
        }
        updateToolbarItemVisibility()
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
        case .newMailFolder:
            item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "New Folder"
            item.paletteLabel = "New Folder"
            item.toolTip = "New Folder"
            item.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "New Folder")
            item.action = #selector(newMailFolder(_:))
        case .refreshMail:
            item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Refresh"
            item.paletteLabel = "Refresh"
            item.toolTip = "Re-read recent mail from Outlook"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
            item.action = #selector(refreshMailMessages(_:))
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
        // View-backed items configure themselves and must not pick up the
        // bordered/validating treatment below, but they still belong to a mode.
        case .calendarTitle:
            return makeCalendarTitleItem()
        case .mailTitle:
            return makeMailTitleItem()
        case .weekNavigation:
            return makeWeekNavigationItem()
        case .windowRange:
            return makeWindowRangeItem()
        case .eventStatus:
            return makeEventStatusItem()
        case .sidebarMode:
            return makeSidebarModeItem()
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

        if [.addProject, .addTask, .newMailFolder].contains(itemIdentifier) {
            sidebarToolbarItems.removeAll { $0.itemIdentifier == itemIdentifier }
            sidebarToolbarItems.append(item)
            // Items are built lazily, so one created while the sidebar is
            // already shut must start hidden rather than appear and be
            // corrected a frame later.
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

    private func makeMailTitleItem() -> NSToolbarItem {
        mailTitleField.lineBreakMode = .byTruncatingTail
        mailTitleField.refusesFirstResponder = true
        mailTitleField.setContentHuggingPriority(.required, for: .horizontal)
        mailTitleField.removeFromSuperview()
        updateMailChrome()

        let item = NSToolbarItem(itemIdentifier: .mailTitle)
        item.view = mailTitleField
        item.label = "Mailbox"
        item.paletteLabel = "Mailbox"
        item.visibilityPriority = .low   // the first thing to drop when cramped
        return item
    }

    /// How far back Recent Mail reaches. A pop-up rather than a stepper: the
    /// range is a choice from a short list, and the list says what the choices
    /// mean. Wired up in the refresh-and-polish PR.
    private func makeWindowRangeItem() -> NSToolbarItem {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.bezelStyle = .toolbar
        for days in MailWindow.minimumDays...MailWindow.maximumDays {
            let menuItem = NSMenuItem(
                title: MailLabels.windowRangeName(days: days),
                action: #selector(windowRangeChanged(_:)),
                keyEquivalent: ""
            )
            menuItem.target = self
            menuItem.tag = days
            button.menu?.addItem(menuItem)
        }
        button.selectItem(withTag: mail.windowDays)
        button.target = self
        button.action = #selector(windowRangeChanged(_:))
        windowRangeButton = button

        let item = NSToolbarItem(itemIdentifier: .windowRange)
        item.view = button
        item.label = "Range"
        item.paletteLabel = "Range"
        item.toolTip = "How far back Recent Mail reaches"
        item.autovalidates = false
        return item
    }

    /// The sidebar toggle, with the mode switch hung off it.
    ///
    /// A custom item rather than the system `.toggleSidebar`, which cannot grow
    /// a menu. A plain click still toggles the sidebar — that muscle memory is
    /// worth more than the slot — and the menu indicator beside it opens Tasks
    /// / Mail. The View menu carries the same two commands, because a menu you
    /// reach by clicking a small arrow is not a keyboard path.
    ///
    /// A one-segment `NSSegmentedControl` rather than `NSMenuToolbarItem`,
    /// which renders as a ~90pt pill: everything before the first tracking
    /// separator has to fit inside the sidebar's own width, alongside the
    /// window buttons and two more items, and 90pt does not. The explicit
    /// segment width matters for the same reason — without one the control
    /// measures as zero and the toolbar drops it into the overflow menu.
    private func makeSidebarModeItem() -> NSToolbarItem {
        sidebarModeControl.segmentStyle = .rounded
        sidebarModeControl.trackingMode = .momentary
        sidebarModeControl.segmentCount = 1
        sidebarModeControl.setImage(
            NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: "Sidebar"),
            forSegment: 0
        )
        sidebarModeControl.setWidth(32, forSegment: 0)
        sidebarModeControl.setMenu(makeModeMenu(), forSegment: 0)
        sidebarModeControl.setShowsMenuIndicator(true, forSegment: 0)
        sidebarModeControl.target = self
        sidebarModeControl.action = #selector(toggleSidebar(_:))
        sidebarModeControl.removeFromSuperview()

        let item = NSToolbarItem(itemIdentifier: .sidebarMode)
        item.view = sidebarModeControl
        item.label = "Sidebar"
        item.paletteLabel = "Sidebar"
        item.toolTip = "Show or hide the sidebar. The arrow switches between Tasks and Mail."
        item.autovalidates = false
        return item
    }

    private func makeModeMenu() -> NSMenu {
        let menu = NSMenu()
        let tasks = NSMenuItem(title: "Tasks", action: #selector(showTasksMode(_:)), keyEquivalent: "1")
        let mail = NSMenuItem(title: "Mail", action: #selector(showMailMode(_:)), keyEquivalent: "2")
        for item in [tasks, mail] {
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func windowRangeChanged(_ sender: Any?) {
        let days = (sender as? NSPopUpButton)?.selectedTag() ?? (sender as? NSMenuItem)?.tag
        guard let days else { return }
        mail.setWindowDays(days)
        updateChrome()
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
