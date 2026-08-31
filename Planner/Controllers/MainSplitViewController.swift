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
    let mailListViewController: MailListViewController
    let mailReaderViewController: MailReaderViewController

    private var sidebarSplitItem: NSSplitViewItem!
    private var calendarSplitItem: NSSplitViewItem!
    private var inspectorSplitItem: NSSplitViewItem!
    private var mailListSplitItem: NSSplitViewItem!
    private var mailReaderSplitItem: NSSplitViewItem!
    /// Nil until the first `applyMode`, so launch always runs the full swap.
    private var appliedMode: PlannerMode?
    /// Divider 1 is per-mode; divider 0 is shared. See `applyMode`.
    private var middlePaneWidths: [PlannerMode: CGFloat] = [:]

    private lazy var calendarTitleField = TitleStatusField(status: eventStatusView)
    private lazy var mailTitleField = TitleStatusField(status: mailStatusView)
    private let weekNavigationControl = NSSegmentedControl()
    /// Each rides inside its mode's title item rather than holding a toolbar
    /// slot of its own: the toolbar draws a control pill behind every separate
    /// slot, and a spinner in a pill reads as a broken button. Beside the title
    /// text it is plainly a status light. The view hides itself when quiet and
    /// the title's stack reclaims the space.
    private let eventStatusView = EventStatusView()
    private let mailStatusView = EventStatusView()
    /// Items that act on the sidebar's content, hidden while it is collapsed.
    private var sidebarToolbarItems: [NSToolbarItem] = []
    private var sidebarCollapseObservation: NSKeyValueObservation?
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
            selection: selection,
            mail: mail
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
        mailListViewController.conversationChromeNeedsRefresh = { [weak self] in
            self?.mailReaderViewController.refreshConversationPosition()
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
        // thickness clamping used to approximate. One sidebar for both modes:
        // the unified outline carries Projects and Mail as sections, so a mode
        // switch replaces only the trailing pair.
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: outlineViewController)
        sidebarItem.minimumThickness = Self.sidebarMinimum
        sidebarItem.maximumThickness = Self.sidebarMinimum * 2
        // `sidebarWithViewController:` installs a 250-pt automatic max, below
        // the 480 the user may drag to. Automatic / proportional sizing
        // (fullscreen, a fitting-size change) would then clamp a widened
        // sidebar back. The absolute max still holds; this only drops the
        // tighter automatic one.
        sidebarItem.automaticMaximumThickness = NSSplitViewItem.unspecifiedDimension
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
        // Not collapsible, the same bargain the mail reader makes: notes are
        // half the point of tasks mode, and a pane that can vanish reads as
        // lost, not hidden. The window refusing to shrink past the panes'
        // minimum sum is the accepted trade.
        inspectorItem.canCollapse = false
        inspectorItem.canCollapseFromWindowResize = false
        inspectorItem.isCollapsed = false
        inspectorSplitItem = inspectorItem

        // Mail's trailing pair is the calendar pair's proportions inverted: a
        // narrow list that keeps its width, and a reader that takes the slack.
        // Separate items rather than one pair with mutated constraints, because
        // the differences include item *style* — content-list versus inspector
        // — which is fixed at init.
        let mailListItem = NSSplitViewItem(contentListWithViewController: mailListViewController)
        mailListItem.minimumThickness = Self.mailListMinimum
        // `contentListWithViewController:` also installs an automatic max
        // (576) and a 0.33 preferred fraction — the no-sidebar value, because
        // this item is built before it sits next to one. Clear the auto-max
        // so a user-widened list is not clamped on the next automatic pass,
        // and pin the fraction to the same default width first-run mail uses.
        // No absolute maximumThickness: the holding priorities already send
        // window growth to the reader, and while the reader is collapsed the
        // list is the only pane that can absorb slack — capping it (with the
        // sidebar already capped) would leave a wide window with space no
        // pane may fill, which Auto Layout resolves by breaking a maximum
        // at random.
        mailListItem.automaticMaximumThickness = NSSplitViewItem.unspecifiedDimension
        mailListItem.preferredThicknessFraction = Self.mailListDefaultWidth / 1100.0
        mailListItem.holdingPriority = NSLayoutConstraint.Priority(260)
        mailListItem.canCollapse = false
        mailListSplitItem = mailListItem

        let mailReaderItem = NSSplitViewItem(viewController: mailReaderViewController)
        mailReaderItem.minimumThickness = Self.mailReaderMinimum
        mailReaderItem.holdingPriority = NSLayoutConstraint.Priority(240)
        // Not collapsible at all — the reader is the point of mail mode, and
        // its minimum is now low enough that the window refusing to shrink
        // past the panes' minimum sum is the better trade. Collapse-from-resize
        // was tried and proved a trapdoor: AppKit sprang it on transient
        // squeezes mid-resize (even while the window *grew*), and nothing on
        // AppKit's side reliably reopened a pane that has no Show command.
        mailReaderItem.canCollapse = false
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mailDidChange(_:)),
            name: .plannerMailDidChange,
            object: mail
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
        // Mode switches record the trailing geometry on the way out; quitting
        // *inside* a mode is the same departure, so it records too — otherwise
        // a divider dragged since the last switch reverts on relaunch.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate(_:)),
            name: NSApplication.willTerminateNotification,
            object: nil
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
    /// Never below what the toolbar parks over this pane: everything between
    /// the two tracking separators is confined to the middle pane's width, so
    /// a pane narrower than its own toolbar section pushes those items into the
    /// overflow menu — the title first, which is the pane's only label.
    static let mailListMinimum: CGFloat = max(300, mailToolbarSectionMinimum)

    /// Width the mail toolbar's middle section needs: the title, plus the feed
    /// status light that rides inside it, plus the toolbar's own padding.
    ///
    /// Measured rather than hardcoded, and calibrated on **"Recent Mail"** —
    /// the one title that is not user-supplied. A folder name is unbounded and
    /// truncates by design; guaranteeing the fixed title fits is what the pane
    /// minimum can honestly promise. Same bargain as the calendar's
    /// `chipWidthCalibrationTitle`.
    static let mailToolbarSectionMinimum: CGFloat = {
        let title = MailLabels.recentMailName as NSString
        let width = title.size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 16, weight: .bold),
        ]).width
        // The status light and its spacing (`TitleStatusField.statusSpacing`),
        // then the padding the toolbar puts around a view-backed item.
        return (width + 8 + 16 + 32).rounded(.up)
    }()
    // Well under the list's minimum: the reader is a wrapping text column and
    // stays legible far narrower than the list's fixed-format rows. Mail's
    // minimum sum (762) sits *below* tasks' 920, which is safe in the only
    // direction that matters: switching into mail never forces the window
    // wider. Switching into tasks from a narrower window grows it to the
    // minimum sum — with the inspector no longer collapsible there is nothing
    // left to shed, and that is the going rate for panes that never vanish.
    private static let mailReaderMinimum: CGFloat = 220
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

    // MARK: - Mode

    /// Replaces the two trailing panes; the unified sidebar stays put.
    ///
    /// Divider 0 and the sidebar's collapse state are deliberately untouched:
    /// a frozen sidebar makes the switch read as "the content changed" rather
    /// than "the layout rearranged". Divider 1 is per-mode, restored in
    /// the same layout pass and **unanimated** — a jump cut is invisible while
    /// both trailing panes' content is replaced, whereas animating would slide
    /// the toolbar's tracking separator after the cut.
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

    /// Captures divider 1 for the mode being left. Recorded in memory *and* in
    /// defaults: the split view's own autosave cannot serve two geometries
    /// under one name, and quitting while in mail mode would otherwise leave
    /// it holding mail's numbers.
    private func recordTrailingGeometry(for mode: PlannerMode) {
        guard splitViewItems.count == 3 else { return }
        // Neither trailing pane can collapse from the UI any more, but a
        // programmatic collapse inflates the middle pane, and a width measured
        // then is not one worth replaying.
        guard trailingItem(for: mode)?.isCollapsed != true else { return }
        guard let width = paneFrame(at: 1)?.width, width > 0 else { return }
        middlePaneWidths[mode] = width
        if let key = Self.middleWidthDefaultsKeys[mode] {
            userDefaults.set(Double(width), forKey: key)
        }
    }

    /// Restores divider 1 for the mode being entered.
    ///
    /// Each step gets its own layout pass. Setting a divider before the split
    /// view has settled the one before it makes AppKit resolve the conflict by
    /// squeezing whichever pane is cheapest — which, with the sidebar leading,
    /// is the sidebar, and the sidebar is the one thing that must not move.
    private func restoreTrailingGeometry(for mode: PlannerMode) {
        guard let item = trailingItem(for: mode), splitViewItems.count == 3 else { return }
        // Neither trailing pane may open shut — a mode with its trailing pane
        // missing reads as broken, not as collapsed — so a stored collapse
        // (from a build that allowed one) is dropped, not replayed.
        item.isCollapsed = false
        view.layoutSubtreeIfNeeded()

        guard !item.isCollapsed,
              let width = storedMiddleWidth(for: mode),
              let sidebarEdge = paneFrame(at: 0)?.maxX
        else { return }
        // Clamped so the trailing pane keeps its minimum: a width stored in a
        // wider window would otherwise hand AppKit a conflict, which it
        // resolves by squeezing whichever pane is cheapest — the sidebar, or
        // the reader right out of existence.
        let room = splitView.bounds.width - sidebarEdge
            - 2 * splitView.dividerThickness - item.minimumThickness
        guard room >= splitViewItems[1].minimumThickness else { return }
        splitView.setPosition(
            sidebarEdge + splitView.dividerThickness + min(width, room),
            ofDividerAt: 1
        )
    }

    @objc private func applicationWillTerminate(_ notification: Notification) {
        if let appliedMode { recordTrailingGeometry(for: appliedMode) }
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
            // The Projects section is visible in both modes, but the project
            // is a tasks-mode thing — creating one goes to where it lives.
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
            selection.selectMailbox(.folder(folder.uuid))
            DispatchQueue.main.async { [weak self] in
                self?.outlineViewController.beginEditingName(of: folder)
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
        // Invoked from the menu bar rather than from a folder menu: ask which
        // folder rather than picking one. Plan Q1 — always show the menu.
        guard let item = chosenFolderItem(sender) else {
            presentFolderMenu(from: sender, action: #selector(saveMessageToFolder(_:)))
            return
        }
        let folder = item.representedObject as? MailFolder
        Task { [weak self] in await self?.save(envelope, into: folder) }
    }

    /// The toolbar's folder button, doing double duty: over Recent Mail it
    /// saves the open message to a folder, over a folder it moves the message.
    /// One button because the two are the same gesture — "put this message in
    /// a folder" — and the mailbox already says which kind of putting is
    /// possible. The File menu keeps them separate: a menu names its verbs.
    @objc func fileMessageToFolder(_ sender: Any?) {
        switch selection.message {
        case .recent?: saveMessageToFolder(sender)
        case .saved?: moveMessageToFolder(sender)
        case nil: break
        }
    }

    /// A menu item that carries a folder choice, as opposed to the command
    /// being invoked afresh. The two arrive at the same selector, so the tag is
    /// what tells them apart.
    private func chosenFolderItem(_ sender: Any?) -> NSMenuItem? {
        guard let item = sender as? NSMenuItem, item.tag == Self.folderMenuItemTag else {
            return nil
        }
        return item
    }

    static func folderMenuItem(title: String, folder: MailFolder?, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.representedObject = folder
        item.tag = folderMenuItemTag
        return item
    }

    /// Returns the saved message's UUID rather than the object: a managed
    /// object is not `Sendable`, and this value is produced across a suspension.
    @discardableResult
    private func save(_ envelope: MailMessage, into folder: MailFolder?) async -> UUID? {
        var target = folder
        var created = false
        if target == nil {
            guard let new = try? model.createMailFolder() else { return nil }
            target = new
            created = true
        }
        guard let target else { return nil }

        do {
            let detail = try await mail.loadDetail(for: envelope.id)
            let saved = try model.saveMessage(envelope, detail: detail, into: target)
            if created {
                // A folder made on the way to saving still needs a name, and
                // the message it was made for is the best reminder of why.
                selection.selectMailbox(.folder(target.uuid))
                outlineViewController.beginEditingName(of: target)
            }
            PlannerLog.mail.info("Saved message \(saved.outlookID, privacy: .public)")
            return saved.uuid
        } catch {
            // Nothing was written, including the folder if this call made one.
            if created { try? model.deleteMailFolder(target) }
            present(error)
            return nil
        }
    }

    /// Brings the original up in Outlook. Always explicit: opening an unread
    /// message marks it read upstream, which is a write Planner will not make
    /// on the user's behalf.
    // MARK: - Tasks from mail

    /// Turns the open message into a task.
    ///
    /// A task links to a **saved** message, not to a passing one — a link into
    /// Recent Mail would dangle in three days — so an unsaved message is saved
    /// first, and that needs a folder. Rather than picking one, the command
    /// asks: the first call pops the folder menu, and choosing from it calls
    /// back with the folder attached.
    @objc func newTaskFromMessage(_ sender: Any?) {
        if let saved = selectedSavedMessage {
            createTask(from: saved)
            return
        }
        guard case let .recent(id)? = selection.message, let envelope = mail.message(id: id) else {
            return
        }
        guard let item = chosenFolderItem(sender) else {
            presentFolderMenu(from: sender, action: #selector(newTaskFromMessage(_:)))
            return
        }
        let folder = item.representedObject as? MailFolder
        Task { [weak self] in
            guard let self,
                  let uuid = await save(envelope, into: folder),
                  let saved = model.savedMessage(uuid: uuid)
            else { return }
            createTask(from: saved)
        }
    }

    /// Where a new task lands: under whatever the outline has selected, else
    /// the first project, else a project made for it — the same fallback chain
    /// ⌘T follows, so a task from mail is not a different kind of task.
    private func createTask(from message: SavedMessage) {
        do {
            let parent = try taskParent()
            let task = try model.createTask(from: message, under: parent)
            selectAndBeginEditing(task)
        } catch {
            // saveFailed already presented.
        }
    }

    private func taskParent() throws -> OutlineNode {
        if let node = selectedOutlineNode { return node }
        if let project = try model.allProjects().first { return project }
        return try model.createProject()
    }

    /// The inspector's "From: <subject>" chip: back to the message the task
    /// came from, in the mode that can show it.
    @objc func revealSourceMessage(_ sender: Any?) {
        guard let uuid = selection.selectedNodeUUID,
              let task = try? model.task(uuid: uuid),
              let message = model.sourceMessage(of: task),
              let folder = message.folder
        else { return }
        selection.selectMailbox(.folder(folder.uuid))
        selection.selectMessage(.saved(message.uuid))
    }

    /// Tagged so a callback can tell "the user picked a folder" from "the user
    /// invoked the command", which arrive at the same selector.
    private static let folderMenuItemTag = 8_201

    private func presentFolderMenu(from sender: Any?, action: Selector) {
        let menu = NSMenu()
        for folder in model.mailFolders() {
            let item = Self.folderMenuItem(title: folder.name, folder: folder, action: action)
            item.target = self
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let newFolder = Self.folderMenuItem(title: "New Folder…", folder: nil, action: action)
        newFolder.target = self
        menu.addItem(newFolder)

        if let view = sender as? NSView {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height), in: view)
        } else if let event = NSApp.currentEvent, let contentView = view.window?.contentView {
            menu.popUp(
                positioning: nil,
                at: contentView.convert(event.locationInWindow, from: nil),
                in: contentView
            )
        }
    }

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
        guard let item = chosenFolderItem(sender) else {
            presentFolderMenu(from: sender, action: #selector(moveMessageToFolder(_:)))
            return
        }
        var target = item.representedObject as? MailFolder
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

    /// The trash's two halves: over a folder it deletes Planner's copy of a
    /// saved message, and over Recent Mail it dismisses a passing one. Double
    /// duty the same way the folder button is, and for the same reason — one
    /// button in one place, named by validation for whichever half applies.
    ///
    /// Removing is deleting Planner's only copy, so it asks — but only when it
    /// really is the only one. A message filed in two folders can lose one of
    /// them without ceremony. Dismissing destroys nothing at all, so it never
    /// asks.
    @objc func removeSelectedMessage(_ sender: Any?) {
        if isFirstResponderTextInput { return }
        if let envelope = dismissableRecentMessage {
            dismiss(envelope)
            return
        }
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
    func removeSelectedMessage(confirmed: Bool) {
        if let envelope = dismissableRecentMessage {
            dismiss(envelope)
            return
        }
        guard confirmed, let message = selectedSavedMessage else { return }
        performRemove(message)
    }

    /// The open Recent Mail message, when dismissing it is a thing that can
    /// happen. A message already saved to a folder is excluded: its row carries
    /// a "Saved to …" chip, and that chip is the receipt for the filing — a
    /// command that hides it would be hiding the evidence the save worked.
    private var dismissableRecentMessage: MailMessage? {
        guard selection.isRecentMailSelected,
              case let .recent(id)? = selection.message,
              let envelope = mail.message(id: id),
              model.foldersByOutlookID()[id] == nil
        else { return nil }
        return envelope
    }

    private func dismiss(_ envelope: MailMessage) {
        // Neighbour first: dismiss republishes immediately, and this row is
        // gone from the list by the time we write the new selection.
        let next = mailListViewController.messageToSelectAfterRemoving(.recent(envelope.id))
        mail.dismiss(envelope)
        selection.selectMessage(next)
        // Not Core Data's undo, but the same stack: ⌘Z means "the last thing I
        // did" regardless of which store it landed in.
        undoManager?.registerUndo(withTarget: self) { target in
            target.mail.restore(envelope)
            target.selection.selectMessage(.recent(envelope.id))
        }
        undoManager?.setActionName("Remove from Recent Mail")
    }

    private func performRemove(_ message: SavedMessage) {
        let next = mailListViewController.messageToSelectAfterRemoving(.saved(message.uuid))
        do {
            try model.removeMessage(message)
            selection.selectMessage(next)
        } catch {
            // saveFailed already presented; selection and list stay put.
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
            outlineViewController.beginEditingName(of: folder)
            return
        }
        guard let node = selectedOutlineNode else { return }
        outlineViewController.beginEditingTitle(of: node)
    }

    @objc func showTaskInfo(_ sender: Any?) {
        guard !isFirstResponderTextInput else { return }
        revealInspector()
    }

    override func toggleSidebar(_ sender: Any?) {
        super.toggleSidebar(sender)
        view.window?.toolbar?.validateVisibleItems()
    }

    @objc func deleteSelected(_ sender: Any?) {
        guard !isFirstResponderTextInput else { return }
        if isMailMode {
            // ⌫ acts on the pane the user is actually in. Over the message list
            // that means dismissing the open message; over the sidebar it keeps
            // meaning the folder, which is what it has always meant.
            if isMailListFirstResponder, dismissableRecentMessage != nil {
                removeSelectedMessage(sender)
                return
            }
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
        let columns = calendarViewController.weekView.visibleWeekCount
        let target = Calendar.current.date(
            byAdding: .day,
            value: weeks * columns,
            to: selection.visibleWeekStart
        )!
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

    @objc private func mailDidChange(_ notification: Notification) {
        updateMailStatus()
        updateChrome()
        // Refresh is disabled while a sweep is in flight, so its enablement
        // changes with the feed rather than with anything the user did.
        view.window?.toolbar?.validateVisibleItems()
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
    var test_mailStatusView: EventStatusView { mailStatusView }
    func test_updateMailStatus() { updateMailStatus() }
    var test_isEventStatusVisible: Bool { isEventStatusVisible }
    func test_updateEventStatus() { updateEventStatus() }
    /// The window title is computed here even when there is no window to set it
    /// on, which is the case in tests.
    var test_windowTitle: String { isMailMode ? mailWindowTitle : calendarWindowTitle }
    var test_visibleColumnCount: Int { calendarViewController.weekView.visibleWeekCount }
    /// Pane widths in pane order, which `splitView.subviews` does not give.
    static var test_folderMenuItemTag: Int { folderMenuItemTag }
    var test_inspectorSourceChip: String? { inspectorViewController.test_sourceMessageChip }
    var test_paneWidths: [CGFloat] {
        (0..<splitViewItems.count).map { paneFrame(at: $0)?.width ?? 0 }
    }

    /// Tests assign a responder so validation/actions see a text input without hosting the split in a window.
    var firstResponderForValidation: NSResponder?

    func test_isCommandEnabled(for action: Selector?) -> Bool {
        isCommandEnabled(for: action)
    }

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

    /// Whether the message list — rather than the sidebar — holds focus. Shares
    /// the validation seam so a test can put focus somewhere without a window.
    private var isMailListFirstResponder: Bool {
        guard let responder = firstResponderForValidation ?? view.window?.firstResponder else {
            return false
        }
        guard let view = responder as? NSView else { return false }
        return view.isDescendant(of: mailListViewController.view)
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

    /// Puts the caret back where the mode expects it, so selecting a
    /// sidebar row leaves the keyboard usable without a second click.
    private func focusPreferredResponder() {
        guard let window = view.window else { return }
        switch selection.mode {
        case .tasks:
            window.makeFirstResponder(outlineViewController.outlineView)
        case .mail:
            // The search field is the first descendant of the list pane; focusing
            // the pane itself would land the caret in Search after Tasks → folder.
            window.makeFirstResponder(mailListViewController.outlineView)
        }
    }

    /// Get Info targets the selection: it puts the caret in the note. The
    /// inspector rebinds itself from `SelectionModel`. Both a task and a
    /// calendar day have a note, so both qualify.
    func revealInspector() {
        guard hasNoteEditableSelection else { return }
        inspectorViewController.focusNote()
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
        // The collapse also changes which items belong in the toolbar at all
        // (the leading space and divider 0's tracking separator go with the
        // sidebar); the rebuild's identifier comparison makes this a no-op
        // when nothing changed.
        rebuildToolbarItems()
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
        case #selector(toggleSidebar(_:)):
            return true
        case #selector(revealToday(_:)), #selector(goToPreviousWeek(_:)),
             #selector(goToNextWeek(_:)):
            return !isMailMode
        // Both sections live in the unified sidebar, so both creations are
        // reachable from either mode; each switches to its own mode. New
        // Project is deliberately not gated on text input — the field editor
        // commits — matching its behavior before the sidebars merged.
        case #selector(newProject(_:)):
            return true
        case #selector(newMailFolder(_:)):
            return !isFirstResponderTextInput
        case #selector(saveMessageToFolder(_:)):
            guard case .recent? = selection.message else { return false }
            return isMailMode
        case #selector(moveMessageToFolder(_:)):
            return isMailMode && selectedSavedMessage != nil
        case #selector(removeSelectedMessage(_:)):
            // Double duty, so it is enabled whenever either half would be —
            // and this gate has to agree with the dispatch about which half.
            // Over Recent Mail that is only an *unsaved* message: a filed one
            // keeps its row so the "Saved to …" chip stays visible.
            guard isMailMode, !isFirstResponderTextInput else { return false }
            return dismissableRecentMessage != nil || selectedSavedMessage != nil
        case #selector(fileMessageToFolder(_:)):
            // Enabled whenever either half would be: the dispatch above and
            // this gate must agree on which half that is.
            guard isMailMode else { return false }
            switch selection.message {
            case .recent?: return true
            case .saved?: return selectedSavedMessage != nil
            case nil: return false
            }
        case #selector(openMessageInOutlook(_:)):
            return isMailMode && outlookIDOfSelectedMessage != nil
        case #selector(newTaskFromMessage(_:)):
            return isMailMode && selection.message != nil
        case #selector(revealSourceMessage(_:)):
            guard let uuid = selection.selectedNodeUUID,
                  let task = try? model.task(uuid: uuid)
            else { return false }
            return model.sourceMessage(of: task)?.folder != nil
        case #selector(refreshCalendarEvents(_:)):
            // Refreshing while one is in flight would just cancel and restart
            // it, which looks like the command did nothing.
            return !isMailMode && !isFirstResponderTextInput && events.state != .loading
        case #selector(refreshCurrentMode(_:)):
            guard !isFirstResponderTextInput else { return false }
            return isMailMode ? !mail.isLoading : events.state != .loading
        case #selector(refreshMailMessages(_:)):
            return isMailMode && !isFirstResponderTextInput && !mail.isLoading
        case #selector(setMailWindowDays(_:)), #selector(showMailWindowMenu(_:)):
            // The window length is a property of Recent Mail. Over a folder it
            // would be offering to change something the pane does not show.
            return isMailMode && selection.isRecentMailSelected && !isFirstResponderTextInput
        case #selector(newTask(_:)):
            return !isMailMode && !isFirstResponderTextInput
                && (selectedOutlineNode is Project || selectedOutlineNode is TaskItem)
        case #selector(renameSelected(_:)):
            guard !isFirstResponderTextInput else { return false }
            // Recent Mail is not a folder: it cannot be renamed.
            return isMailMode ? selectedMailFolder != nil : selectedOutlineNode != nil
        case #selector(deleteSelected(_:)):
            guard !isFirstResponderTextInput else { return false }
            guard isMailMode else { return selectedOutlineNode != nil }
            // Has to agree with the dispatch, which sends ⌫ to whichever pane
            // holds focus — enabling this only for the folder would leave the
            // command greyed out over the message list, where it now does work.
            if isMailListFirstResponder, dismissableRecentMessage != nil { return true }
            return selectedMailFolder != nil
        case #selector(showTaskInfo(_:)):
            return !isMailMode && !isFirstResponderTextInput && hasNoteEditableSelection
        default:
            return false
        }
    }

    /// The sidebar toggle names the direction it would go.
    private func updateModeMenuItemState(_ item: NSMenuItem) {
        switch item.action {
        case #selector(toggleSidebar(_:)):
            item.title = isSidebarVisible ? "Hide Sidebar" : "Show Sidebar"
        case #selector(showMailWindowMenu(_:)): updateWindowRangeMenu(item)
        // The ellipsis is a promise that a sheet follows, and only the folder
        // half keeps it — dismissing takes nothing away that Outlook still has.
        case #selector(removeSelectedMessage(_:)):
            item.title = dismissableRecentMessage != nil
                ? "Remove from Recent Mail"
                : "Remove Message\u{2026}"
        case #selector(setMailWindowDays(_:)):
            item.state = item.tag == mail.windowDays ? .on : .off
        default: break
        }
    }

    /// The parent of the range submenu. It carries no action of its own — the
    /// submenu's entries do the work — but it needs a selector so validation
    /// can populate it and gate it on Recent Mail being open.
    @objc func showMailWindowMenu(_ sender: Any?) {}

    @objc func performFindPanelAction(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? Int(NSFindPanelAction.showFindPanel.rawValue)
        guard tag == Int(NSFindPanelAction.showFindPanel.rawValue) else { return }
        mailListViewController.focusSearchField()
    }

    private func isFindPanelActionEnabled(tag: Int) -> Bool {
        if isEditingMailSearchField { return tag == Int(NSFindPanelAction.showFindPanel.rawValue) }
        if isFindBarTextViewFirstResponder { return true }
        if isMailMode, selection.selectedFolderUUID != nil {
            return tag == Int(NSFindPanelAction.showFindPanel.rawValue)
        }
        return false
    }

    /// The field editor, not the field, is first responder while typing.
    private var isEditingMailSearchField: Bool {
        let responder = firstResponderForValidation ?? view.window?.firstResponder
        return mailListViewController.isSearchFieldResponder(responder)
    }

    /// Reader body / inspector note. Checked after the search editor so it cannot pass.
    private var isFindBarTextViewFirstResponder: Bool {
        guard !isEditingMailSearchField else { return false }
        let responder = firstResponderForValidation ?? view.window?.firstResponder
        return responder is NSTextView
    }
}

extension MainSplitViewController: NSMenuItemValidation, NSToolbarItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        updateModeMenuItemState(item)
        // Same ObjC selector the xib wires (`performFindPanelAction:`). Do not
        // fold this into `isCommandEnabled` — that helper cannot see `item.tag`.
        if item.action == #selector(NSTextView.performFindPanelAction(_:)) {
            return isFindPanelActionEnabled(tag: item.tag)
        }
        return isCommandEnabled(for: item.action)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if item.itemIdentifier == .fileMessage { updateFileMessageItem(item) }
        if item.itemIdentifier == .removeMessage { updateRemoveMessageItem(item) }
        return isCommandEnabled(for: item.action)
    }

    /// The folder button's name follows the open mailbox, so the overflow menu
    /// and tooltip say which half of its double duty a click would do.
    private func updateFileMessageItem(_ item: NSToolbarItem) {
        if selection.isRecentMailSelected {
            item.label = "Save"
            item.toolTip = "Save this message to a folder"
        } else {
            item.label = "Move"
            item.toolTip = "Move this message to another folder"
        }
    }

    /// The trash's name follows the open mailbox too, and here it is doing more
    /// than labelling: "Remove" over a folder deletes Planner's copy, while the
    /// Recent Mail half touches nothing but this list. Saying so is the only
    /// warning the user gets that the two are not the same act.
    private func updateRemoveMessageItem(_ item: NSToolbarItem) {
        if selection.isRecentMailSelected {
            item.label = "Dismiss"
            item.toolTip = "Remove this message from Recent Mail (Outlook is unchanged)"
        } else {
            item.label = "Remove"
            item.toolTip = "Remove this message from its folder"
        }
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
    static let inspectorTitle = NSToolbarItem.Identifier("InspectorTitle")
    static let mailTitle = NSToolbarItem.Identifier("MailTitle")
    static let weekNavigation = NSToolbarItem.Identifier("WeekNavigation")
    static let windowRange = NSToolbarItem.Identifier("WindowRange")
    static let today = NSToolbarItem.Identifier("Today")
    static let refreshMail = NSToolbarItem.Identifier("RefreshMail")
    static let fileMessage = NSToolbarItem.Identifier("FileMessage")
    static let removeMessage = NSToolbarItem.Identifier("RemoveMessage")
    static let newTaskFromMessage = NSToolbarItem.Identifier("NewTaskFromMessage")
    static let openInOutlook = NSToolbarItem.Identifier("OpenInOutlook")
}

extension MainSplitViewController: NSToolbarDelegate {
    /// Only the current mode's items.
    ///
    /// Tracking separators pin to both split dividers, and they bind to the
    /// split view rather than to the items, so they survive both the per-mode
    /// swap of the trailing panes and this rebuild. The leading flexible space
    /// pushes the sidebar's own group up against the first divider, so it hugs
    /// the splitter the way mail's reader actions hug the second one.
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
                .calendarTitle, .flexibleSpace, .weekNavigation,
                .inspectorSeparator,
                .inspectorTitle,
            ]
        case .mail:
            return [
                .flexibleSpace, .newMailFolder, .sidebarMode,
                .paneSeparator,
                .mailTitle, .flexibleSpace,
                .inspectorSeparator,
                .fileMessage, .removeMessage, .newTaskFromMessage, .openInOutlook,
            ]
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        identifiers(for: .tasks) + identifiers(for: .mail)
    }

    /// What the toolbar should hold right now: the mode's items, minus the
    /// pieces that only make sense while the sidebar is open.
    ///
    /// The leading flexible space is what pushes the sidebar group against
    /// divider 0; with the sidebar shut there is no divider to hug, so it goes
    /// and the toggle sits beside the window buttons, as Preview does. The
    /// `paneSeparator` goes for the same reason with worse failure: a tracking
    /// separator whose divider is collapsed has nothing to track, and AppKit
    /// parks it — and everything laid out against it — over the wrong divider.
    func wantedToolbarIdentifiers() -> [NSToolbarItem.Identifier] {
        var wanted = identifiers(for: selection.mode)
        if !isSidebarVisible {
            wanted.removeAll { $0 == .paneSeparator }
            if wanted.first == .flexibleSpace { wanted.removeFirst() }
        }
        return wanted
    }

    /// Swaps the toolbar's contents to what the mode and sidebar state want,
    /// in one pass. The identifier comparison is what keeps this from
    /// rebuilding on every validation pass.
    private func rebuildToolbarItems() {
        guard let toolbar = view.window?.toolbar else { return }
        let wanted = wantedToolbarIdentifiers()
        guard toolbar.items.map(\.itemIdentifier) != wanted else { return }
        while !toolbar.items.isEmpty { toolbar.removeItem(at: 0) }
        for (index, identifier) in wanted.enumerated() {
            toolbar.insertItem(withItemIdentifier: identifier, at: index)
        }
        // Freshly inserted sidebar items must start with the current collapse
        // state; the rebuild guard above stops this from recursing.
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
        // The reader's actions live over its own pane, past the second tracking
        // separator. The folder button pops the folder menu itself — the
        // command asks which folder when the sender carries none, so a plain
        // button is enough. It does double duty (save from Recent Mail, move
        // within a folder), so validation renames it to whichever half the
        // open mailbox makes true.
        case .fileMessage:
            item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Save"
            item.paletteLabel = "Save or Move to Folder"
            item.toolTip = "Save this message to a folder"
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Save or Move to Folder")
            item.action = #selector(fileMessageToFolder(_:))
        case .removeMessage:
            item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Remove"
            item.paletteLabel = "Remove"
            item.toolTip = "Remove this message from its folder"
            item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Remove")
            item.action = #selector(removeSelectedMessage(_:))
        case .newTaskFromMessage:
            item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "New Task"
            item.paletteLabel = "New Task from Message"
            item.toolTip = "Turn this message into a task"
            item.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "New Task from Message")
            item.action = #selector(newTaskFromMessage(_:))
        case .openInOutlook:
            item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Open in Outlook"
            item.paletteLabel = "Open in Outlook"
            item.toolTip = "Open the original message in Outlook"
            item.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: "Open in Outlook")
            item.action = #selector(openMessageInOutlook(_:))
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
        case .inspectorTitle:
            return makeInspectorTitleItem()
        case .mailTitle:
            return makeMailTitleItem()
        case .weekNavigation:
            return makeWeekNavigationItem()
        case .sidebarMode:
            return makeSidebarModeItem()
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

    /// Title text with the feed's status light riding inside it, one item.
    /// `TitleStatusField` says why the two share a text field.
    /// The selected task or day's name, plus the completion circle when the
    /// subject is a task. Lives past divider 1 so it sits over the inspector
    /// the way the calendar title sits over the grid.
    private func makeInspectorTitleItem() -> NSToolbarItem {
        let view = inspectorViewController.titleToolbarView
        view.removeFromSuperview()
        // Do not set `label`: an unsized view-backed item falls back to that
        // string as a chevron button, which the tracking separator then parks
        // over the calendar. Size comes from the view's own constraints.
        let item = NSToolbarItem(itemIdentifier: .inspectorTitle)
        item.view = view
        item.paletteLabel = "Info"
        item.visibilityPriority = .high
        return item
    }

    private func makeCalendarTitleItem() -> NSToolbarItem {
        calendarTitleField.setContentHuggingPriority(.required, for: .horizontal)
        calendarTitleField.removeFromSuperview()
        updateCalendarChrome()

        eventStatusView.onRetry = { [weak self] in self?.events.refresh(userInitiated: true) }
        eventStatusView.onOpenAutomationSettings = { [weak self] in
            guard let url = self?.events.failureSettingsURL else { return }
            NSWorkspace.shared.open(url)
        }
        updateEventStatus()

        let item = NSToolbarItem(itemIdentifier: .calendarTitle)
        item.view = calendarTitleField
        item.label = "Dates"
        item.paletteLabel = "Dates"
        item.visibilityPriority = .low   // the first thing to drop when cramped
        return item
    }

    private func makeMailTitleItem() -> NSToolbarItem {
        mailTitleField.setContentHuggingPriority(.required, for: .horizontal)
        mailTitleField.removeFromSuperview()
        updateMailChrome()

        mailStatusView.onRetry = { [weak self] in self?.mail.refresh(userInitiated: true) }
        mailStatusView.onOpenAutomationSettings = { [weak self] in
            guard let url = self?.mail.failureSettingsURL else { return }
            NSWorkspace.shared.open(url)
        }
        updateMailStatus()

        let item = NSToolbarItem(itemIdentifier: .mailTitle)
        item.view = mailTitleField
        item.label = "Mailbox"
        item.paletteLabel = "Mailbox"
        item.visibilityPriority = .low   // the first thing to drop when cramped
        return item
    }

    /// Hide / Show Sidebar. A clickable icon, not a menu: mode follows the
    /// selected sidebar row, so this button has only one job.
    private func makeSidebarModeItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .sidebarMode)
        item.image = NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: "Sidebar")
        item.isBordered = true
        item.label = "Sidebar"
        item.paletteLabel = "Sidebar"
        item.toolTip = "Hide or show the sidebar"
        item.action = #selector(toggleSidebar(_:))
        item.target = self
        item.autovalidates = true
        return item
    }

    /// How far back Recent Mail reaches. Menu-only: the range is set once and
    /// then left alone for weeks, which does not earn permanent toolbar width —
    /// and the toolbar's mail section has to fit inside the message list's own
    /// minimum width. The item carries the day count as its tag.
    @objc func setMailWindowDays(_ sender: Any?) {
        guard let days = (sender as? NSMenuItem)?.tag, days > 0 else { return }
        mail.setWindowDays(days)
        updateChrome()
    }

    /// Populates View → Recent Mail Window from the coordinator's own bounds,
    /// so the menu cannot drift from what `setWindowDays` will accept. The xib
    /// supplies an empty submenu; this fills it and keeps the check mark on the
    /// current length.
    private func updateWindowRangeMenu(_ item: NSMenuItem) {
        let submenu = item.submenu ?? NSMenu(title: item.title)
        item.submenu = submenu
        if submenu.items.count != MailWindow.maximumDays - MailWindow.minimumDays + 1 {
            submenu.removeAllItems()
            for days in MailWindow.minimumDays...MailWindow.maximumDays {
                let entry = NSMenuItem(
                    title: MailLabels.windowRangeName(days: days),
                    action: #selector(setMailWindowDays(_:)),
                    keyEquivalent: ""
                )
                entry.target = self
                entry.tag = days
                submenu.addItem(entry)
            }
        }
        for entry in submenu.items {
            entry.state = entry.tag == mail.windowDays ? .on : .off
        }
    }

    /// Only loading and failure have anything to say; the rest of the time the
    /// light goes away entirely rather than sitting there empty.
    private var isMailStatusVisible: Bool {
        FeedStatus(mail.state) != .quiet
    }

    private func updateMailStatus() {
        mailStatusView.apply(
            mail.state,
            settingsURL: mail.failureSettingsURL,
            detail: """
            \(mail.sourceDisplayName)
            \(MailLabels.windowRangeName(days: mail.windowDays)) · \
            \(MailLabels.messageCount(mail.messages.count))
            """
        )
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
