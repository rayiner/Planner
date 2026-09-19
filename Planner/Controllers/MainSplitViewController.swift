import AppKit

final class MainSplitViewController: NSSplitViewController {
    let persistence: PersistenceController
    let model: ModelController
    let selection: SelectionModel
    let events: EventCoordinator
    let mail: MailCoordinator

    let outlineViewController: OutlineViewController
    /// The right side's top/bottom split. Its bottom item is the terminal.
    private let rightSplitViewController = NSSplitViewController()
    /// The existing middle/trailing pair, now nested in the top of the right split.
    private let contentSplitViewController = NSSplitViewController()
    let terminalViewController = TerminalViewController {
        MCPServerController.shared.configuredEndpointURL
    }
    private let calendarViewController: CalendarViewController
    let mailListViewController: MailListViewController
    let mailReaderViewController: MailReaderViewController

    private var sidebarSplitItem: NSSplitViewItem!
    private var calendarSplitItem: NSSplitViewItem!
    private var mailListSplitItem: NSSplitViewItem!
    private var mailReaderSplitItem: NSSplitViewItem!
    private var rightSplitItem: NSSplitViewItem!
    private var terminalSplitItem: NSSplitViewItem!
    /// Nil until the first `applyMode`, so launch always runs the full swap.
    private var appliedMode: PlannerMode?
    /// Divider 1 is per-mode; divider 0 is shared. See `applyMode`.
    private var middlePaneWidths: [PlannerMode: CGFloat] = [:]

    private lazy var calendarTitleField = TitleStatusField(status: eventStatusView)
    private lazy var mailTitleField = TitleStatusField(status: mailStatusView)
    /// Each rides inside its mode's title item rather than holding a toolbar
    /// slot of its own: the toolbar draws a control pill behind every separate
    /// slot, and a spinner in a pill reads as a broken button. Beside the title
    /// text it is plainly a status light. The view hides itself when quiet and
    /// the title's stack reclaims the space.
    private let eventStatusView = EventStatusView()
    private let mailStatusView = EventStatusView()
    private var mailMutationInFlight = false
    /// Items that act on the sidebar's content, hidden while it is collapsed.
    private var sidebarToolbarItems: [NSToolbarItem] = []
    private var sidebarCollapseObservation: NSKeyValueObservation?
    private let userDefaults: UserDefaults

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
            events: events,
            mail: mail
        )
        calendarViewController = CalendarViewController(
            persistence: persistence,
            model: model,
            selection: selection,
            events: events
        )
        mailListViewController = MailListViewController(
            selection: selection,
            mail: mail
        )
        mailReaderViewController = MailReaderViewController(
            selection: selection,
            mail: mail
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

        // Outer split: sidebar on the left, all working content on the right.
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autosaveName = "MainSidebarSplit.v1"

        // Inner horizontal split: ordinary content above, terminal below.
        rightSplitViewController.splitView.isVertical = false
        rightSplitViewController.splitView.dividerStyle = .thin
        rightSplitViewController.splitView.autosaveName = "MainTerminalSplit.v1"

        // Inner top split: the existing middle/trailing pair.
        contentSplitViewController.splitView.isVertical = true
        contentSplitViewController.splitView.dividerStyle = .thin
        contentSplitViewController.splitView.autosaveName = "MainContentSplit.v1"

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
        // Collapsible from the toolbar, but never from a window resize.
        sidebarItem.canCollapse = true
        sidebarItem.canCollapseFromWindowResize = false
        sidebarItem.isCollapsed = false
        sidebarSplitItem = sidebarItem

        let calendarItem = NSSplitViewItem(viewController: calendarViewController)
        calendarItem.minimumThickness = Self.detailMinimum
        calendarItem.holdingPriority = NSLayoutConstraint.Priority(240)
        calendarItem.canCollapse = false
        calendarSplitItem = calendarItem

        // Mail is a pair where tasks is a single pane: a narrow list that keeps
        // its width, and a reader that takes the slack.
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

        let topItem = NSSplitViewItem(viewController: contentSplitViewController)
        topItem.minimumThickness = 260
        topItem.holdingPriority = NSLayoutConstraint.Priority(240)
        topItem.canCollapse = false

        let terminalItem = NSSplitViewItem(viewController: terminalViewController)
        terminalItem.minimumThickness = 120
        terminalItem.preferredThicknessFraction = 0.35
        terminalItem.holdingPriority = NSLayoutConstraint.Priority(260)
        terminalItem.canCollapse = true
        terminalItem.canCollapseFromWindowResize = true
        terminalItem.isCollapsed = !userDefaults.bool(forKey: Self.terminalVisibleDefaultsKey)
        terminalSplitItem = terminalItem

        rightSplitViewController.addSplitViewItem(topItem)
        rightSplitViewController.addSplitViewItem(terminalItem)
        // The explicit visibility preference owns collapse state; the split's
        // autosave owns only the divider position.
        terminalItem.isCollapsed = !userDefaults.bool(forKey: Self.terminalVisibleDefaultsKey)

        let rightItem = NSSplitViewItem(viewController: rightSplitViewController)
        rightItem.canCollapse = false
        rightSplitItem = rightItem

        addSplitViewItem(sidebarItem)
        addSplitViewItem(rightItem)
        applyMode(selection.mode)
        // Autosave can reapply a stored collapse after the items are in a
        // windowed split; the preference is the source of truth.
        terminalItem.isCollapsed = !userDefaults.bool(forKey: Self.terminalVisibleDefaultsKey)

        if !terminalItem.isCollapsed, NSClassFromString("XCTestCase") == nil {
            terminalViewController.startIfNeeded()
        }

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

    /// The window's own content minimum, which is what actually bounds how
    /// narrow either mode can get. Both modes' pane minimums have to fit
    /// inside it, or entering that mode forces the window wider.
    static let windowContentMinimumWidth: CGFloat = 880
    /// Never below what the toolbar parks over this pane: everything between
    /// the two tracking separators is confined to the middle pane's width, so
    /// a pane narrower than its own toolbar section pushes those items into the
    /// overflow menu — the title first, which is the pane's only label.
    static let mailListMinimum: CGFloat = max(300, mailToolbarSectionMinimum)

    /// Width the mail toolbar's middle section needs: the title, plus the feed
    /// status light that rides inside it, plus the toolbar's own padding.
    ///
    /// Measured rather than hardcoded and calibrated on **"Recent Mail"**.
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
    // wider.
    private static let mailReaderMinimum: CGFloat = 220
    /// Where divider 1 sits in mail mode the first time it is entered.
    private static let mailListDefaultWidth: CGFloat = 420

    /// Stored as the *middle pane's width* rather than divider 1's absolute
    /// position, which is what the plan called for: a position is measured from
    /// the window's leading edge, so it silently encodes the sidebar's width
    /// too, and restoring one after the sidebar has been dragged puts the
    /// trailing panes in the wrong place.
    /// Mail only: tasks is a single pane now, so it has no divider 1 to record.
    private static let middleWidthDefaultsKeys: [PlannerMode: String] = [
        .mail: "mail.middlePaneWidth",
    ]
    private static let terminalVisibleDefaultsKey = "terminalPaneVisible"

    // MARK: - Mode

    /// Replaces the contents of the inner top split; the outer sidebar and the
    /// terminal below are untouched. Tasks is one pane, mail is two.
    private func applyMode(_ mode: PlannerMode) {
        guard appliedMode != mode else { return }
        let outgoing = appliedMode
        if let outgoing { recordTrailingGeometry(for: outgoing) }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false

            while !contentSplitViewController.splitViewItems.isEmpty {
                let items = contentSplitViewController.splitViewItems
                contentSplitViewController.removeSplitViewItem(items[items.count - 1])
            }

            switch mode {
            case .tasks:
                contentSplitViewController.addSplitViewItem(calendarSplitItem)
            case .mail:
                contentSplitViewController.addSplitViewItem(mailListSplitItem)
                contentSplitViewController.addSplitViewItem(mailReaderSplitItem)
            }
            let panes = contentSplitViewController.splitViewItems
            rightSplitItem.minimumThickness =
                panes.reduce(0) { $0 + $1.minimumThickness }
                + CGFloat(max(0, panes.count - 1))
                * contentSplitViewController.splitView.dividerThickness

            appliedMode = mode
            view.layoutSubtreeIfNeeded()
            restoreTrailingGeometry(for: mode)
            view.layoutSubtreeIfNeeded()
        }

        rebuildToolbarItems()
        updateToolbarItemVisibility()
        updateChrome()
        view.window?.toolbar?.validateVisibleItems()
    }

    /// Tasks has no trailing pane any more, so there is nothing to record or
    /// restore for it: the calendar fills the split on its own.
    private func trailingItem(for mode: PlannerMode) -> NSSplitViewItem? {
        mode == .mail ? mailReaderSplitItem : nil
    }

    /// A pane's rectangle in the split view's own coordinates.
    ///
    /// **Not** `splitView.subviews[index]`: an `NSSplitViewController`'s split
    /// view carries the dividers and its own chrome as subviews too, in an
    /// order that has nothing to do with pane order — measuring by index there
    /// silently reads the wrong pane.
    private func contentPaneFrame(at index: Int) -> CGRect? {
        let controller = contentSplitViewController
        guard index < controller.splitViewItems.count else { return nil }
        let paneView = controller.splitViewItems[index].viewController.view
        guard paneView.superview != nil else { return nil }
        return paneView.convert(paneView.bounds, to: controller.splitView)
    }

    private func outerPaneFrame(at index: Int) -> CGRect? {
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
        guard contentSplitViewController.splitViewItems.count == 2 else { return }
        // Neither trailing pane can collapse from the UI any more, but a
        // programmatic collapse inflates the middle pane, and a width measured
        // then is not one worth replaying.
        guard trailingItem(for: mode)?.isCollapsed != true else { return }
        guard let width = contentPaneFrame(at: 0)?.width, width > 0 else { return }
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
        let controller = contentSplitViewController
        guard let item = trailingItem(for: mode), controller.splitViewItems.count == 2 else {
            return
        }
        // The reader may never open shut: a mode with its reader missing reads
        // as broken.
        item.isCollapsed = false
        view.layoutSubtreeIfNeeded()

        guard !item.isCollapsed,
              let width = storedMiddleWidth(for: mode)
        else { return }
        // Clamped so the trailing pane keeps its minimum: a width stored in a
        // wider window would otherwise hand AppKit a conflict, which it
        // resolves by squeezing whichever pane is cheapest — the sidebar, or
        // the reader right out of existence.
        let room = controller.splitView.bounds.width
            - controller.splitView.dividerThickness - item.minimumThickness
        guard room >= controller.splitViewItems[0].minimumThickness else { return }
        controller.splitView.setPosition(min(width, room), ofDividerAt: 0)
    }

    @objc private func applicationWillTerminate(_ notification: Notification) {
        if let appliedMode { recordTrailingGeometry(for: appliedMode) }
        terminalViewController.shutdown()
    }

    /// The remembered middle-pane width, or — the first time mail mode is
    /// entered — a sensible list width rather than half the window.
    private func storedMiddleWidth(for mode: PlannerMode) -> CGFloat? {
        if let width = middlePaneWidths[mode] { return width }
        if let key = Self.middleWidthDefaultsKeys[mode] {
            let stored = userDefaults.double(forKey: key)
            if stored > 0 { return CGFloat(stored) }
        }
        return mode == .mail ? Self.mailListDefaultWidth : nil
    }

    var isMailMode: Bool { selection.mode == .mail }

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

    var isTerminalVisible: Bool {
        terminalSplitItem?.isCollapsed == false
    }

    @objc func toggleTerminal(_ sender: Any?) {
        setTerminalVisible(!isTerminalVisible)
    }

    @objc func restartTerminal(_ sender: Any?) {
        setTerminalVisible(true)
        terminalViewController.restart()
    }

    private func setTerminalVisible(_ visible: Bool) {
        guard let terminalSplitItem else { return }
        terminalSplitItem.animator().isCollapsed = !visible
        userDefaults.set(visible, forKey: Self.terminalVisibleDefaultsKey)
        guard visible else { return }
        if NSClassFromString("XCTestCase") == nil {
            terminalViewController.startIfNeeded()
        }
        DispatchQueue.main.async { [weak self] in
            self?.terminalViewController.focusTerminal()
        }
    }

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

    /// Brings the original up in Outlook. Always explicit: opening an unread
    /// message marks it read upstream, which is a write Planner will not make
    /// on the user's behalf.
    @objc func openMessageInOutlook(_ sender: Any?) {
        guard let id = outlookIDOfSelectedMessage else { return }
        Task { [weak self] in
            guard let self else { return }
            do { try await mail.reveal(messageID: id) } catch { present(error) }
        }
    }

    private var outlookIDOfSelectedMessage: Int64? {
        guard case let .recent(id)? = selection.message else { return nil }
        return id
    }

    /// Adds or removes Outlook's `Hide` category on the selected messages.
    /// Hide if any of them are still visible; Unhide only when every selected
    /// message is already hidden.
    @objc func toggleHiddenForSelectedMessage(_ sender: Any?) {
        if isFirstResponderTextInput { return }
        let envelopes = hideableSelectedMessages
        guard !envelopes.isEmpty else { return }
        changeHiddenState(shouldHideSelectedMessages, for: envelopes)
    }

    /// Test seam matching the project-delete command's shape.
    func toggleHiddenForSelectedMessage(confirmed: Bool) {
        let envelopes = hideableSelectedMessages
        guard confirmed, !envelopes.isEmpty else { return }
        changeHiddenState(shouldHideSelectedMessages, for: envelopes)
    }

    /// Selected messages that have an envelope to write.
    private var hideableSelectedMessages: [MailMessage] {
        selection.messages.compactMap { item in
            guard case let .recent(id) = item else { return nil }
            return mail.message(id: id)
        }
    }

    private var shouldHideSelectedMessages: Bool {
        let envelopes = hideableSelectedMessages
        return envelopes.contains { !$0.isHidden }
    }

    @objc func toggleShowsHiddenMail(_ sender: Any?) {
        mail.setShowsHiddenMessages(!mail.showsHiddenMessages)
        view.window?.toolbar?.validateVisibleItems()
    }

    private func changeHiddenState(
        _ hidden: Bool,
        for envelopes: [MailMessage],
        selectMovedMessages: Bool = false
    ) {
        guard !mailMutationInFlight, !envelopes.isEmpty else { return }
        mailMutationInFlight = true
        view.window?.toolbar?.validateVisibleItems()
        let next = mailListViewController.messageToSelectAfterMoving(
            envelopes.map { .recent($0.id) }
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                mailMutationInFlight = false
                view.window?.toolbar?.validateVisibleItems()
            }
            do {
                try await mail.setHidden(hidden, messages: envelopes)
            } catch {
                present(error)
            }
            let changed = envelopes.compactMap { mail.message(id: $0.id) }
                .filter { $0.isHidden == hidden }
            guard !changed.isEmpty else { return }
            let stillVisible = changed.filter { message in
                switch selection.mailbox {
                case .recent:
                    return mail.messages.contains { $0.id == message.id }
                case .search, .quickSearch:
                    return mail.searchResults.contains { $0.id == message.id }
                }
            }
            if selectMovedMessages, !stillVisible.isEmpty {
                selection.selectMessages(stillVisible.map { .recent($0.id) })
            } else if stillVisible.isEmpty {
                selection.selectMessage(next)
            }
            undoManager?.registerUndo(withTarget: self) { target in
                target.changeHiddenState(
                    !hidden,
                    for: changed,
                    selectMovedMessages: true
                )
            }
            undoManager?.setActionName(
                hidden
                    ? MailLabels.hideActionTitle(count: changed.count)
                    : MailLabels.unhideActionTitle(count: changed.count)
            )
        }
    }

    @objc func applyCategoryToSelectedMessages(_ sender: Any?) {
        guard !isFirstResponderTextInput,
              let categoryID = categoryID(from: sender),
              let category = applicableCategories.first(where: { $0.id == categoryID })
        else { return }
        let present = categoryState(for: categoryID) != .on
        let messages = selectedMessages(with: categoryID, present: !present)
        guard !messages.isEmpty else { return }
        changeCategory(category, present: present, for: messages)
    }

    /// Finder tags: checked when every selected message has it, mixed when
    /// some do, off when none do. A click on a checked item removes it; any
    /// other click adds it to the messages that lack it.
    private func categoryState(for categoryID: Int64) -> NSControl.StateValue {
        let messages = selectedMailMessages
        guard !messages.isEmpty else { return .off }
        let tagged = messages.filter { $0.categoryIDs.contains(categoryID) }.count
        if tagged == 0 { return .off }
        if tagged == messages.count { return .on }
        return .mixed
    }

    /// What the Categories menu offers for the current selection: the selected
    /// messages' own account's categories, never Outlook's built-in set.
    private var applicableCategories: [OutlookCategory] {
        mail.categories(applicableTo: selectedMailMessages)
    }

    private var selectedMailMessages: [MailMessage] {
        selection.messages.compactMap { item in
            guard case let .recent(id) = item else { return nil }
            return mail.message(id: id)
        }
    }

    private func selectedMessages(with categoryID: Int64, present: Bool) -> [MailMessage] {
        selectedMailMessages.filter { $0.categoryIDs.contains(categoryID) == present }
    }

    private func changeCategory(
        _ category: OutlookCategory,
        present: Bool,
        for messages: [MailMessage]
    ) {
        guard !mailMutationInFlight, !messages.isEmpty else { return }
        mailMutationInFlight = true
        view.window?.toolbar?.validateVisibleItems()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                mailMutationInFlight = false
                view.window?.toolbar?.validateVisibleItems()
            }
            do {
                try await mail.setCategory(category.id, present: present, messages: messages)
            } catch {
                self.present(error)
            }
            let changed = messages.compactMap { before -> MailMessage? in
                guard let after = mail.message(id: before.id),
                      after.categoryIDs.contains(category.id) == present
                else { return nil }
                return after
            }
            guard !changed.isEmpty else { return }
            undoManager?.registerUndo(withTarget: self) { target in
                target.changeCategory(category, present: !present, for: changed)
            }
            undoManager?.setActionName(
                present ? "Apply \(category.name)" : "Remove \(category.name)"
            )
        }
    }

    private func categoryID(from sender: Any?) -> Int64? {
        if let item = sender as? NSMenuItem {
            return (item.representedObject as? NSNumber)?.int64Value
        }
        return nil
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
        guard !isMailMode else { return }
        guard let node = selectedOutlineNode else { return }
        outlineViewController.beginEditingTitle(of: node)
    }

    /// Get Info is the keyboard's double click: the inspector pane is gone, so
    /// the note opens in the same window a double click would.
    @objc func showTaskInfo(_ sender: Any?) {
        guard !isFirstResponderTextInput else { return }
        if selectedOutlineNode is TaskItem {
            openTaskWindow(sender)
            return
        }
        openDayNoteWindow(sender)
    }

    @objc func openTaskWindow(_ sender: Any?) {
        guard let task = selectedOutlineNode as? TaskItem else { return }
        try? ItemWindowController.openTask(uuid: task.uuid, persistence: persistence, model: model)
    }

    @objc func openDayNoteWindow(_ sender: Any?) {
        let day = selection.selectedDay ?? calendarViewController.weekView.selectedDay
        guard let day else { return }
        ItemWindowController.openDayNote(day: day, persistence: persistence, model: model)
    }

    @objc func openMailWindow(_ sender: Any?) {
        guard case let .recent(id) = selection.message else { return }
        try? ItemWindowController.openMail(id: id, mail: mail)
    }

    override func toggleSidebar(_ sender: Any?) {
        super.toggleSidebar(sender)
        view.window?.toolbar?.validateVisibleItems()
    }

    @objc func deleteSelected(_ sender: Any?) {
        guard !isFirstResponderTextInput else { return }
        if isMailMode {
            if case .quickSearch = selection.mailbox {
                deleteQuickSearch(sender)
                return
            }
            if !hideableSelectedMessages.isEmpty {
                toggleHiddenForSelectedMessage(sender)
            }
            return
        }
        guard let node = selectedOutlineNode else { return }
        confirm(message: Self.deleteConfirmationMessage(for: node)) { [weak self] confirmed in
            guard confirmed else { return }
            self?.performConfirmedDelete(node)
        }
    }

    @objc func deleteQuickSearch(_ sender: Any?) {
        guard case let .quickSearch(id) = selection.mailbox else { return }
        mail.deleteQuickSearch(id: id)
        selection.selectMailbox(.search)
    }

    /// The one remaining jump. Everything else about moving through time is the
    /// calendar's scroll: there are no week buttons to step it by a column.
    @objc func revealToday(_ sender: Any?) {
        selection.setVisibleWeekStart(Date())
        calendarViewController.weekView.scroll(toDay: Date())
    }

    /// The visible span depends on how many columns fit and how tall the pane
    /// is, so the title has to be refreshed when the calendar re-flows or
    /// scrolls, not only when the day changes.
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

    /// Re-index every Outlook message and event, ignoring what Planner already
    /// has, then reload both feeds from the rebuilt index.
    @objc func resyncOutlookIndex(_ sender: Any?) {
        mail.rebuildIndex(userInitiated: true)
        events.refresh(userInitiated: true)
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
        rebuildToolbarItems()
        updateCategoryMenu()
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
    var test_weekView: WeekCalendarView { calendarViewController.weekView }
    /// Logical pane widths in the old public order: sidebar, middle, trailing.
    var test_paneWidths: [CGFloat] {
        [
            outerPaneFrame(at: 0)?.width ?? 0,
            contentPaneFrame(at: 0)?.width ?? 0,
            contentPaneFrame(at: 1)?.width ?? 0,
        ]
    }
    var test_contentSplitViewController: NSSplitViewController { contentSplitViewController }
    var test_rightSplitViewController: NSSplitViewController { rightSplitViewController }
    var test_contentSplitItems: [NSSplitViewItem] { contentSplitViewController.splitViewItems }
    var test_terminalIsVisible: Bool { isTerminalVisible }

    /// Tests assign a responder so validation/actions see a text input without hosting the split in a window.
    var firstResponderForValidation: NSResponder?

    func test_isCommandEnabled(for action: Selector?) -> Bool {
        isCommandEnabled(for: action)
    }

    /// Tests pass a result to skip the confirmation sheet.
    func deleteSelected(confirmed: Bool) {
        guard confirmed else { return }
        if isMailMode {
            if case .quickSearch = selection.mailbox {
                deleteQuickSearch(nil)
            } else {
                toggleHiddenForSelectedMessage(confirmed: true)
            }
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
        if fields.contains(SelectionField.visibleWeek.rawValue) {
            updateChrome()
        }
        if fields.contains(SelectionField.mailbox.rawValue) {
            updateChrome()
            updateMailStatus()
            if selection.mailbox == .search { focusPreferredResponder() }
        }
        if fields.contains(SelectionField.message.rawValue) {
            // The Categories menu is the selected messages' own account's
            // categories, so it is rebuilt whenever the selection moves.
            updateCategoryMenu()
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
            if selection.mailbox == .search {
                mailListViewController.focusSearchField()
            } else {
                window.makeFirstResponder(mailListViewController.outlineView)
            }
        }
    }

    var isSidebarVisible: Bool {
        sidebarSplitItem.map { !$0.isCollapsed } ?? false
    }

    /// New Project / New Task act on the sidebar's content, so
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
        Calendar.current.dayRangeString(
            from: selection.visibleWeekStart,
            days: calendarViewController.weekView.visibleDayCount
        )
    }

    private var mailWindowTitle: String {
        switch selection.mailbox {
        case .recent: return MailLabels.recentMailName
        case .search: return MailLabels.searchMailName
        case let .quickSearch(id):
            return mail.quickSearch(id: id)?.name ?? MailLabels.searchMailName
        }
    }

    private func updateMailChrome() {
        mailTitleField.attributedStringValue = Self.toolbarTitle(
            bold: mailWindowTitle,
            trailing: nil
        )
    }

    /// Span bold, year lighter — the "August 2026" treatment, in the toolbar.
    private func updateCalendarChrome() {
        let parts = Calendar.current.dayRangeComponents(
            from: selection.visibleWeekStart,
            days: calendarViewController.weekView.visibleDayCount
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

    private func isCommandEnabled(for action: Selector?) -> Bool {
        switch action {
        case #selector(toggleSidebar(_:)), #selector(toggleTerminal(_:)),
             #selector(restartTerminal(_:)):
            return true
        case #selector(toggleShowsHiddenMail(_:)):
            return isMailMode
        case #selector(revealToday(_:)):
            return !isMailMode
        case #selector(newProject(_:)):
            return true
        case #selector(toggleHiddenForSelectedMessage(_:)):
            guard isMailMode, !isFirstResponderTextInput else { return false }
            return !mailMutationInFlight && !hideableSelectedMessages.isEmpty
        case #selector(applyCategoryToSelectedMessages(_:)):
            return isMailMode && !isFirstResponderTextInput
                && !mailMutationInFlight && !selection.messages.isEmpty
        case #selector(openMessageInOutlook(_:)):
            return isMailMode && outlookIDOfSelectedMessage != nil
        case #selector(refreshCalendarEvents(_:)):
            // Refreshing while one is in flight would just cancel and restart
            // it, which looks like the command did nothing.
            return !isMailMode && !isFirstResponderTextInput && events.state != .loading
        case #selector(refreshCurrentMode(_:)):
            guard !isFirstResponderTextInput else { return false }
            return isMailMode ? !mail.isLoading : events.state != .loading
        case #selector(resyncOutlookIndex(_:)):
            guard !isFirstResponderTextInput else { return false }
            return !mail.isLoading && events.state != .loading
        case #selector(refreshMailMessages(_:)):
            return isMailMode && !isFirstResponderTextInput && !mail.isLoading
        case #selector(setMailWindowDays(_:)), #selector(showMailWindowMenu(_:)):
            return isMailMode && !isFirstResponderTextInput
        case #selector(newTask(_:)):
            return !isMailMode && !isFirstResponderTextInput
                && (selectedOutlineNode is Project || selectedOutlineNode is TaskItem)
        case #selector(renameSelected(_:)):
            guard !isFirstResponderTextInput else { return false }
            return !isMailMode && selectedOutlineNode != nil
        case #selector(deleteSelected(_:)):
            guard !isFirstResponderTextInput else { return false }
            if isMailMode, case .quickSearch = selection.mailbox { return true }
            return isMailMode
                ? !mailMutationInFlight && !hideableSelectedMessages.isEmpty
                : selectedOutlineNode != nil
        case #selector(deleteQuickSearch(_:)):
            guard !isFirstResponderTextInput else { return false }
            if case .quickSearch = selection.mailbox { return isMailMode }
            return false
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
        case #selector(toggleTerminal(_:)):
            item.title = isTerminalVisible ? "Hide Terminal" : "Show Terminal"
        case #selector(toggleShowsHiddenMail(_:)):
            item.title = MailLabels.hiddenMailVisibilityTitle(showing: mail.showsHiddenMessages)
        case #selector(showMailWindowMenu(_:)): updateWindowRangeMenu(item)
        case #selector(toggleHiddenForSelectedMessage(_:)):
            let count = hideableSelectedMessages.count
            item.title = shouldHideSelectedMessages
                ? MailLabels.hideActionTitle(count: max(count, 1))
                : MailLabels.unhideActionTitle(count: max(count, 1))
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
        selection.selectMailbox(.search)
        mailListViewController.focusSearchField()
    }

    private func isFindPanelActionEnabled(tag: Int) -> Bool {
        if isEditingMailSearchField { return tag == Int(NSFindPanelAction.showFindPanel.rawValue) }
        if isFindBarTextViewFirstResponder { return true }
        if isMailMode {
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
        if item.action == #selector(applyCategoryToSelectedMessages(_:)),
           let categoryID = categoryID(from: item) {
            item.state = isCommandEnabled(for: item.action) ? categoryState(for: categoryID) : .off
            return isCommandEnabled(for: item.action)
        }
        return isCommandEnabled(for: item.action)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if item.itemIdentifier == .categorizeMessage {
            // The menu is the selection's own account's categories, so an
            // empty one means there is nothing to apply, not merely no
            // selection.
            return isCommandEnabled(for: #selector(applyCategoryToSelectedMessages(_:)))
                && !applicableCategories.isEmpty
        }
        if item.action == #selector(toggleHiddenForSelectedMessage(_:)) {
            let hide = shouldHideSelectedMessages
            item.label = hide ? "Hide" : "Unhide"
            item.toolTip = hide
                ? "Add the Hide category in Outlook"
                : "Remove the Hide category in Outlook"
            item.image = NSImage(
                systemSymbolName: hide ? "eye.slash" : "eye",
                accessibilityDescription: hide ? "Hide" : "Unhide"
            )
        }
        return isCommandEnabled(for: item.action)
    }
}

extension NSToolbarItem.Identifier {
    static let addProject = NSToolbarItem.Identifier("AddProject")
    static let addTask = NSToolbarItem.Identifier("AddTask")
    static let sidebarMode = NSToolbarItem.Identifier("SidebarMode")
    static let paneSeparator = NSToolbarItem.Identifier("PaneSeparator")
    static let inspectorSeparator = NSToolbarItem.Identifier("InspectorSeparator")
    static let calendarTitle = NSToolbarItem.Identifier("CalendarTitle")
    static let mailTitle = NSToolbarItem.Identifier("MailTitle")
    static let windowRange = NSToolbarItem.Identifier("WindowRange")
    static let today = NSToolbarItem.Identifier("Today")
    static let refreshMail = NSToolbarItem.Identifier("RefreshMail")
    static let hideMessage = NSToolbarItem.Identifier("HideMessage")
    static let categorizeMessage = NSToolbarItem.Identifier("CategorizeMessage")
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
                .calendarTitle, .flexibleSpace, .today,
            ]
        case .mail:
            return [
                .flexibleSpace, .sidebarMode,
                .paneSeparator,
                .mailTitle, .flexibleSpace,
                .inspectorSeparator,
                .categorizeMessage, .hideMessage, .openInOutlook,
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
        case .hideMessage:
            item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Hide"
            item.paletteLabel = "Hide or Unhide"
            item.toolTip = "Add the Hide category in Outlook"
            item.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "Hide")
            item.action = #selector(toggleHiddenForSelectedMessage(_:))
            item.visibilityPriority = .high
        case .categorizeMessage:
            let menuItem = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            menuItem.label = "Categories"
            menuItem.paletteLabel = "Apply Category"
            menuItem.toolTip = "Add or remove Outlook categories on the selected messages"
            menuItem.image = NSImage(
                systemSymbolName: "tag",
                accessibilityDescription: "Apply Category"
            )
            menuItem.menu = makeCategoryMenu()
            menuItem.showsIndicator = true
            menuItem.autovalidates = true
            menuItem.visibilityPriority = .high
            return menuItem
        case .openInOutlook:
            item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Open in Outlook"
            item.paletteLabel = "Open in Outlook"
            item.toolTip = "Open the original message in Outlook"
            item.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: "Open in Outlook")
            item.action = #selector(openMessageInOutlook(_:))
            item.visibilityPriority = .high
        case .paneSeparator:
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier,
                splitView: splitView,
                dividerIndex: 0
            )
        case .inspectorSeparator:
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier,
                splitView: contentSplitViewController.splitView,
                dividerIndex: 0
            )
        // View-backed items configure themselves and must not pick up the
        // bordered/validating treatment below, but they still belong to a mode.
        case .today:
            return makeTodayItem()
        case .calendarTitle:
            return makeCalendarTitleItem()
        case .mailTitle:
            return makeMailTitleItem()
        case .sidebarMode:
            return makeSidebarModeItem()
        default:
            return nil
        }

        item.target = self
        item.isBordered = true
        item.autovalidates = true

        if [.addProject, .addTask].contains(itemIdentifier) {
            sidebarToolbarItems.removeAll { $0.itemIdentifier == itemIdentifier }
            sidebarToolbarItems.append(item)
            // Items are built lazily, so one created while the sidebar is
            // already shut must start hidden rather than appear and be
            // corrected a frame later.
            item.isHidden = !isSidebarVisible
        }
        return item
    }

    private func makeCategoryMenu() -> NSMenu {
        let menu = NSMenu(title: "Categories")
        for category in applicableCategories {
            let item = NSMenuItem(
                title: category.name,
                action: #selector(applyCategoryToSelectedMessages(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = NSNumber(value: category.id)
            menu.addItem(item)
        }
        return menu
    }

    private func updateCategoryMenu() {
        guard let item = view.window?.toolbar?.items.first(where: {
            $0.itemIdentifier == .categorizeMessage
        }) as? NSMenuToolbarItem else { return }
        item.menu = makeCategoryMenu()
    }

    /// Title text with the feed's status light riding inside it, one item.
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
        item.label = "Recent Mail"
        item.paletteLabel = "Recent Mail"
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

    /// Populates View → Recent Mail Window from `MailWindow.choices`, so the
    /// menu cannot drift from what `setWindowDays` will accept. The xib
    /// supplies an empty submenu; this fills it and keeps the check mark on the
    /// current length.
    private func updateWindowRangeMenu(_ item: NSMenuItem) {
        let submenu = item.submenu ?? NSMenu(title: item.title)
        item.submenu = submenu
        if submenu.items.count != MailWindow.choices.count {
            submenu.removeAllItems()
            for days in MailWindow.choices {
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
        let count: Int
        switch selection.mailbox {
        case .recent: count = mail.messages.count
        case .search: count = mail.searchResults.count
        case .quickSearch: count = mail.searchResults.count
        }
        let isWholeIndexSearch: Bool = {
            switch selection.mailbox {
            case .search, .quickSearch: return true
            case .recent: return false
            }
        }()
        let scope = isWholeIndexSearch
            ? MailLabels.messageCount(count)
            : "\(MailLabels.windowRangeName(days: mail.windowDays)) · \(MailLabels.messageCount(count))"
        mailStatusView.apply(
            mail.state,
            settingsURL: mail.failureSettingsURL,
            detail: """
            \(mail.sourceDisplayName)
            \(scope)
            """
        )
    }

    /// Scrolling is how the sheet moves through time; this is only the way
    /// back from wherever the scroll went.
    private func makeTodayItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .today)
        item.label = "Today"
        item.paletteLabel = "Today"
        item.toolTip = "Scroll back to today"
        item.image = NSImage(
            systemSymbolName: "smallcircle.filled.circle",
            accessibilityDescription: "Today"
        )
        item.action = #selector(revealToday(_:))
        item.target = self
        item.isBordered = true
        item.autovalidates = true
        return item
    }
}
