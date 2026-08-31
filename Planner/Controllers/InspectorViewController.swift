import AppKit
import CoreData

final class InspectorViewController: NSViewController, NSTextViewDelegate {
    private static let noteDebounce: TimeInterval = 0.4

    let persistence: PersistenceController
    let model: ModelController
    let selection: SelectionModel

    private let titleField = InspectorTitleField()
    private let captionLabel = NSTextField(labelWithString: "")
    private var completedCheckbox: NSButton { titleField.completedButton }
    private let hasDeadlineCheckbox = NSButton(checkboxWithTitle: "Due date", target: nil, action: nil)
    private let datePicker = NSDatePicker()
    private let dueCaptionLabel = NSTextField(labelWithString: "")
    private let deadlineRow = NSStackView()
    /// "From: <subject>" on a task made from a message. A button rather than a
    /// label because it is also the way back to the message it came from.
    private let sourceMessageButton = NSButton()
    private let formatBar = NSSegmentedControl()
    private let notesScrollView = NSScrollView()
    private let notesTextView = NoteTextView(frame: .zero)

    private enum FormatSegment: Int, CaseIterable {
        case bold, italic, underline, bulletList, numberedList

        var symbolName: String {
            switch self {
            case .bold: return "bold"
            case .italic: return "italic"
            case .underline: return "underline"
            case .bulletList: return "list.bullet"
            case .numberedList: return "list.number"
            }
        }

        var label: String {
            switch self {
            case .bold: return "Bold"
            case .italic: return "Italic"
            case .underline: return "Underline"
            case .bulletList: return "Bulleted List"
            case .numberedList: return "Numbered List"
            }
        }
    }
    private let notesPlaceholder = PlaceholderLabel(labelWithString: "Add a note…")
    /// Shown when a note save fails. Without it a failed flush is silent — the
    /// selection snapping back after a failed switch looked like a UI glitch.
    private let noteSaveErrorLabel = NSTextField(wrappingLabelWithString: "")
    private let bottomSpacer = NSView()

    private var isUpdatingUI = false
    private var isRevertingFailedFlush = false
    private var notesBufferIsDirty = false
    private var boundTask: TaskItem?
    private var boundTaskObjectID: NSManagedObjectID?
    /// Set instead of `boundTask` when the calendar day owns the selection.
    private var boundDay: Date?
    private var noteSaveTimer: Timer?
    private var noteUndoManager = UndoManager()

    init(
        persistence: PersistenceController,
        model: ModelController,
        selection: SelectionModel
    ) {
        self.persistence = persistence
        self.model = model
        self.selection = selection
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
        // Sidebar material, matching the outline on the opposite edge: it reads as
        // chrome framing the calendar rather than more content surface.
        let root = NSVisualEffectView()
        root.material = .sidebar
        root.blendingMode = .behindWindow
        root.state = .followsWindowActiveState
        view = root
        configureControls()
        layoutContent()
    }

    /// Called by ⌘I / Get Info once the pane is uncollapsed.
    func focusNote() {
        guard notesTextView.isEditable else { return }
        view.window?.makeFirstResponder(notesTextView)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        startObserving()
        bindToCurrentSelection()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        titleField.preferredToolbarWidth = max(120, view.bounds.width - 20)
    }

    /// Hosted in the inspector's toolbar slot. Not in the pane: the name
    /// belongs with the chrome, the way the calendar title sits over the grid.
    var titleToolbarView: NSView {
        loadViewIfNeeded()
        return titleField
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        flushPendingNote()
    }

    @discardableResult
    func flushPendingNote() -> Bool {
        noteSaveTimer?.invalidate()
        noteSaveTimer = nil
        return persistBoundNote()
    }

    private func configureControls() {
        titleField.completedButton.target = self
        titleField.completedButton.action = #selector(completedChanged(_:))

        captionLabel.lineBreakMode = .byTruncatingTail
        captionLabel.maximumNumberOfLines = 1
        captionLabel.alignment = .left
        captionLabel.font = .systemFont(ofSize: 13)
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.isHidden = true

        hasDeadlineCheckbox.font = .systemFont(ofSize: 13)
        hasDeadlineCheckbox.target = self
        hasDeadlineCheckbox.action = #selector(hasDeadlineChanged(_:))
        hasDeadlineCheckbox.isEnabled = false
        hasDeadlineCheckbox.setContentHuggingPriority(.required, for: .horizontal)

        // Borderless: a bezeled stepper field reads as a 2013 preference pane.
        datePicker.datePickerStyle = .textField
        datePicker.datePickerMode = .single
        datePicker.datePickerElements = .yearMonthDay
        datePicker.font = .systemFont(ofSize: 13)
        datePicker.isBezeled = false
        datePicker.isBordered = false
        datePicker.drawsBackground = false
        datePicker.target = self
        datePicker.action = #selector(deadlineChanged(_:))
        datePicker.isEnabled = false
        datePicker.setContentHuggingPriority(.required, for: .horizontal)
        datePicker.setContentCompressionResistancePriority(.required, for: .horizontal)

        dueCaptionLabel.font = .systemFont(ofSize: 12)
        dueCaptionLabel.textColor = .secondaryLabelColor
        dueCaptionLabel.isHidden = true
        dueCaptionLabel.lineBreakMode = .byTruncatingTail
        dueCaptionLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        dueCaptionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Bold / italic / underline. `refusesFirstResponder` keeps the caret in
        // the note when a segment is clicked, so the selection it acts on survives.
        formatBar.segmentStyle = .rounded
        formatBar.trackingMode = .selectAny
        formatBar.segmentCount = FormatSegment.allCases.count
        formatBar.refusesFirstResponder = true
        formatBar.isHidden = true
        formatBar.target = self
        formatBar.action = #selector(formatSegmentClicked(_:))
        for segment in FormatSegment.allCases {
            formatBar.setImage(
                NSImage(systemSymbolName: segment.symbolName, accessibilityDescription: segment.label),
                forSegment: segment.rawValue
            )
            formatBar.setWidth(32, forSegment: segment.rawValue)
        }
        formatBar.setContentHuggingPriority(.required, for: .horizontal)

        // Built by hand rather than `NSTextView.scrollableTextView()` so the
        // document view can be our sanitising NoteTextView subclass.
        notesTextView.autoresizingMask = [.width]
        notesTextView.isVerticallyResizable = true
        notesTextView.isHorizontallyResizable = false
        notesTextView.minSize = NSSize(width: 0, height: 0)
        notesTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                       height: CGFloat.greatestFiniteMagnitude)
        // A hand-built NSTextView gets a container with a finite default height,
        // which silently stops laying out text past it. `scrollableTextView()`
        // sets this for you; building the view directly means we must.
        notesTextView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        notesTextView.textContainer?.widthTracksTextView = true

        notesScrollView.documentView = notesTextView
        notesScrollView.borderType = .noBorder
        notesScrollView.hasVerticalScroller = true
        notesScrollView.autohidesScrollers = true
        notesScrollView.drawsBackground = false
        notesScrollView.isHidden = true

        // Rich text on, but font panel and graphics stay off: the supported
        // traits are bold/italic/underline and lists, nothing else.
        notesTextView.isRichText = true
        notesTextView.usesFontPanel = false
        notesTextView.importsGraphics = false
        notesTextView.font = NoteFormatting.bodyFont
        notesTextView.typingAttributes = NoteFormatting.typingAttributes
        notesTextView.isEditable = false
        notesTextView.isSelectable = false
        notesTextView.delegate = self
        notesTextView.allowsUndo = true
        notesTextView.drawsBackground = false
        notesTextView.textContainerInset = NSSize(width: 2, height: 4)
        // Typed URLs become live links; pasted ones keep theirs through the
        // sanitiser, which whitelists `.link`.
        notesTextView.isAutomaticLinkDetectionEnabled = true
        // Same as the reader body: command-F over the note means find-in-note,
        // and the Find submenu routes it here, so give it the in-pane bar
        // rather than the floating Find panel.
        notesTextView.usesFindBar = true
        notesTextView.isIncrementalSearchingEnabled = true
        notesTextView.onFormattingStateChange = { [weak self] in
            self?.updateFormatBar()
        }

        notesPlaceholder.font = .systemFont(ofSize: 13)
        notesPlaceholder.textColor = .tertiaryLabelColor
        notesPlaceholder.refusesFirstResponder = true
        notesPlaceholder.isHidden = true

        noteSaveErrorLabel.stringValue = "Couldn't save this note. Changes stay here until saving succeeds."
        noteSaveErrorLabel.font = .systemFont(ofSize: 11)
        noteSaveErrorLabel.textColor = .systemRed
        noteSaveErrorLabel.refusesFirstResponder = true
        noteSaveErrorLabel.isHidden = true
    }

    private func layoutContent() {
        // Stack rows with detachesHiddenViews so a hidden checkbox leaves no gap.
        configureRow(deadlineRow, views: [hasDeadlineCheckbox, datePicker, dueCaptionLabel], spacing: 8)
        deadlineRow.isHidden = true

        notesPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        notesScrollView.addSubview(notesPlaceholder)
        NSLayoutConstraint.activate([
            notesPlaceholder.leadingAnchor.constraint(equalTo: notesScrollView.leadingAnchor, constant: 7),
            notesPlaceholder.topAnchor.constraint(equalTo: notesScrollView.topAnchor, constant: 4),
        ])

        sourceMessageButton.bezelStyle = .inline
        sourceMessageButton.controlSize = .small
        sourceMessageButton.font = .systemFont(ofSize: 11)
        sourceMessageButton.lineBreakMode = .byTruncatingTail
        sourceMessageButton.isHidden = true
        // Routed through the responder chain: revealing a message is the split
        // controller's job, since it owns both modes.
        sourceMessageButton.target = nil
        sourceMessageButton.action = #selector(MainSplitViewController.revealSourceMessage(_:))

        let stack = NSStackView(views: [
            captionLabel,
            sourceMessageButton,
            deadlineRow,
            formatBar,
            notesScrollView,
            noteSaveErrorLabel,
            bottomSpacer,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        // The notes field absorbs slack when it is showing; otherwise the spacer
        // does, so a project's caption stays pinned to the top of the pane
        // instead of drifting to the middle.
        notesScrollView.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        notesScrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        bottomSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(100), for: .vertical)
        bottomSpacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .vertical)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            captionLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16),
            deadlineRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16),
            notesScrollView.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16),
            notesScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
            noteSaveErrorLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16),
            datePicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
        ])
    }

    private func configureRow(_ row: NSStackView, views: [NSView], spacing: CGFloat) {
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = spacing
        row.detachesHiddenViews = true
        row.translatesAutoresizingMaskIntoConstraints = false
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addArrangedSubview(view)
        }
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 22).isActive = true
    }

    private func startObserving() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(plannerSelectionDidChange(_:)),
            name: .plannerSelectionDidChange,
            object: selection
        )
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
            selector: #selector(windowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: nil
        )
    }

    // MARK: - Selection

    @objc private func plannerSelectionDidChange(_ notification: Notification) {
        let fields = notification.userInfo?[SelectionUserInfoKey.changedFields] as? Set<String> ?? []
        // A day and a node are mutually exclusive, so either field moving means
        // the inspector has a new subject.
        guard fields.contains(SelectionField.node.rawValue)
            || fields.contains(SelectionField.day.rawValue)
        else { return }
        if isRevertingFailedFlush { return }
        noteSaveTimer?.invalidate()
        noteSaveTimer = nil
        if !flushPendingNote() {
            if let previous = boundSelection, selection.selection != previous {
                isRevertingFailedFlush = true
                switch previous {
                case let .node(uuid): selection.selectNode(uuid: uuid)
                case let .day(date): selection.selectDay(date)
                }
                isRevertingFailedFlush = false
            }
            return
        }
        noteUndoManager = UndoManager()
        bindToCurrentSelection()
    }

    private func bindToCurrentSelection() {
        boundTask = nil
        boundTaskObjectID = nil
        boundDay = nil
        notesBufferIsDirty = false

        switch selection.selection {
        case nil:
            pushEmpty()
        case let .day(date):
            boundDay = date
            pushDay(date, replaceNotes: true)
        case let .node(uuid):
            if let task = try? model.task(uuid: uuid) {
                boundTask = task
                boundTaskObjectID = task.objectID
                pushTask(task, replaceNotes: true)
            } else if let project = try? model.project(uuid: uuid) {
                pushProject(project)
            } else {
                pushEmpty()
            }
        }
    }

    /// What the notes buffer currently belongs to, used to revert a failed flush.
    private var boundSelection: PlannerSelection? {
        if let boundDay { return .day(boundDay) }
        if let boundTask { return .node(boundTask.uuid) }
        return nil
    }

    // MARK: - Model → view

    private func pushEmpty() {
        isUpdatingUI = true
        defer {
            titleField.refreshTitleInset()
            isUpdatingUI = false
        }

        titleField.stringValue = "Select a task to edit its note"
        titleField.isEnabled = false
        titleField.textColor = .secondaryLabelColor
        captionLabel.isHidden = true
        sourceMessageButton.isHidden = true
        completedCheckbox.isHidden = true
        completedCheckbox.isEnabled = false
        completedCheckbox.state = .off
        deadlineRow.isHidden = true
        hasDeadlineCheckbox.isEnabled = false
        hasDeadlineCheckbox.state = .off
        datePicker.isEnabled = false
        dueCaptionLabel.isHidden = true
        notesScrollView.isHidden = true
        setNotesContent(NSAttributedString())
        notesTextView.isEditable = false
        notesTextView.isSelectable = false
        updateNotesPlaceholder()
    }

    private func pushProject(_ project: Project) {
        isUpdatingUI = true
        defer {
            titleField.refreshTitleInset()
            isUpdatingUI = false
        }

        titleField.stringValue = project.title
        titleField.isEnabled = true
        titleField.textColor = .labelColor
        let count = descendantTaskCount(of: project)
        captionLabel.stringValue = count == 1 ? "1 task" : "\(count) tasks"
        captionLabel.isHidden = false
        sourceMessageButton.isHidden = true
        completedCheckbox.isHidden = true
        completedCheckbox.isEnabled = false
        completedCheckbox.state = .off
        deadlineRow.isHidden = true
        hasDeadlineCheckbox.isEnabled = false
        hasDeadlineCheckbox.state = .off
        datePicker.isEnabled = false
        dueCaptionLabel.isHidden = true
        notesScrollView.isHidden = true
        setNotesContent(NSAttributedString())
        notesTextView.isEditable = false
        notesTextView.isSelectable = false
        updateNotesPlaceholder()
    }

    private func pushTask(_ task: TaskItem, replaceNotes: Bool) {
        isUpdatingUI = true
        defer {
            titleField.refreshTitleInset()
            isUpdatingUI = false
        }

        titleField.stringValue = task.title
        titleField.isEnabled = true
        titleField.textColor = .labelColor
        captionLabel.isHidden = true
        updateSourceMessageChip(for: task)
        completedCheckbox.isHidden = false
        completedCheckbox.isEnabled = true
        completedCheckbox.state = task.isCompleted ? .on : .off
        completedCheckbox.contentTintColor = task.isCompleted ? .controlAccentColor : .tertiaryLabelColor
        deadlineRow.isHidden = false
        hasDeadlineCheckbox.isEnabled = true
        let calendar = Calendar.current
        if let deadline = task.deadline {
            hasDeadlineCheckbox.state = .on
            datePicker.dateValue = deadline
            datePicker.isEnabled = true
            let overdue = !task.isCompleted && calendar.isOverdue(deadline)
            datePicker.textColor = overdue ? .systemRed : .labelColor
            // Today / Tomorrow were noise next to a date the picker already
            // shows. Overdue stays: the picker going red is easy to miss.
            if overdue {
                dueCaptionLabel.stringValue = "Overdue"
                dueCaptionLabel.textColor = .systemRed
                dueCaptionLabel.isHidden = false
            } else {
                dueCaptionLabel.isHidden = true
            }
        } else {
            hasDeadlineCheckbox.state = .off
            datePicker.dateValue = calendar.startOfDay(for: Date())
            datePicker.isEnabled = false
            datePicker.textColor = .labelColor
            dueCaptionLabel.isHidden = true
        }
        notesScrollView.isHidden = false
        notesTextView.isEditable = true
        notesTextView.isSelectable = true
        if replaceNotes {
            setNotesContent(model.noteText(of: task))
        }
        updateNotesPlaceholder()
    }

    /// The chip on a task made from a message, and the way back to it.
    ///
    /// Hidden when the link dangles — the message has been removed from its
    /// folder since. The link is a UUID rather than a relationship precisely so
    /// that case is a missing chip rather than a deleted task.
    private func updateSourceMessageChip(for task: TaskItem) {
        guard let message = model.sourceMessage(of: task) else {
            sourceMessageButton.isHidden = true
            return
        }
        let subject = message.subject.isEmpty ? "(No subject)" : message.subject
        sourceMessageButton.title = "From: \(subject)"
        sourceMessageButton.toolTip = "Show this message in Mail"
        sourceMessageButton.isHidden = false
    }

    /// A day has a note and nothing else: no completion flag, no due date.
    private func pushDay(_ day: Date, replaceNotes: Bool) {
        isUpdatingUI = true
        defer {
            titleField.refreshTitleInset()
            isUpdatingUI = false
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        sourceMessageButton.isHidden = true
        formatter.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        titleField.stringValue = formatter.string(from: day)
        titleField.isEnabled = true
        titleField.textColor = .labelColor
        captionLabel.isHidden = true

        completedCheckbox.isHidden = true
        completedCheckbox.isEnabled = false
        completedCheckbox.state = .off
        deadlineRow.isHidden = true
        hasDeadlineCheckbox.isEnabled = false
        hasDeadlineCheckbox.state = .off
        datePicker.isEnabled = false
        dueCaptionLabel.isHidden = true

        notesScrollView.isHidden = false
        notesTextView.isEditable = true
        notesTextView.isSelectable = true
        if replaceNotes {
            setNotesContent(model.dayNoteText(for: day))
        }
        updateNotesPlaceholder()
    }

    @objc private func formatSegmentClicked(_ sender: NSSegmentedControl) {
        switch FormatSegment(rawValue: sender.selectedSegment) {
        case .bold: notesTextView.toggleBold(sender)
        case .italic: notesTextView.toggleItalic(sender)
        case .underline: notesTextView.toggleUnderline(sender)
        case .bulletList: notesTextView.toggleBulletList(sender)
        case .numberedList: notesTextView.toggleNumberedList(sender)
        case nil: break
        }
        // The text view is the source of truth; a click should not leave a
        // segment lit if the toggle did not actually apply.
        updateFormatBar()
        view.window?.makeFirstResponder(notesTextView)
    }

    private func updateFormatBar() {
        formatBar.isHidden = notesScrollView.isHidden
        guard !formatBar.isHidden else { return }
        formatBar.setSelected(notesTextView.selectionHasTrait(.bold), forSegment: FormatSegment.bold.rawValue)
        formatBar.setSelected(notesTextView.selectionHasTrait(.italic), forSegment: FormatSegment.italic.rawValue)
        formatBar.setSelected(notesTextView.selectionIsUnderlined, forSegment: FormatSegment.underline.rawValue)
        let listKind = notesTextView.selectionListKind
        formatBar.setSelected(listKind == .bullet, forSegment: FormatSegment.bulletList.rawValue)
        formatBar.setSelected(listKind == .numbered, forSegment: FormatSegment.numberedList.rawValue)
    }

    /// Replaces the buffer, keeping typing attributes canonical so the next
    /// keystroke cannot inherit whatever the last run of text carried.
    private func setNotesContent(_ attributed: NSAttributedString) {
        notesTextView.textStorage?.setAttributedString(attributed)
        notesTextView.typingAttributes = NoteFormatting.typingAttributes
    }

    private var notesContent: NSAttributedString {
        notesTextView.attributedString()
    }

    private func updateNotesPlaceholder() {
        notesPlaceholder.isHidden = notesScrollView.isHidden || !notesTextView.string.isEmpty
        // The spacer only exists to keep a project's title at the top when there
        // is no note. With a note showing, the field takes all the slack itself.
        bottomSpacer.isHidden = !notesScrollView.isHidden
        updateFormatBar()
    }

    private func descendantTaskCount(of project: Project) -> Int {
        func count(_ tasks: Set<TaskItem>) -> Int {
            tasks.reduce(0) { $0 + 1 + count($1.subtasks) }
        }
        return count(project.tasks)
    }

    @objc private func contextDidSave(_ notification: Notification) {
        if notification.userInfo?[NSInvalidatedAllObjectsKey] != nil {
            refreshBoundFields()
            return
        }
        guard touchesBoundOrSelectedNode(
            notification,
            keys: [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey]
        ) else { return }
        refreshBoundFields()
    }

    @objc private func contextObjectsDidChange(_ notification: Notification) {
        if notification.userInfo?[NSInvalidatedAllObjectsKey] != nil {
            refreshBoundFields()
            return
        }
        guard touchesBoundOrSelectedNode(
            notification,
            keys: [NSUpdatedObjectsKey, NSInvalidatedObjectsKey]
        ) else { return }
        refreshBoundFields()
    }

    private func touchesBoundOrSelectedNode(_ notification: Notification, keys: [String]) -> Bool {
        let changed = keys.flatMap { objects(in: notification, key: $0) }
        if let boundID = boundTaskObjectID, changed.contains(where: { $0.objectID == boundID }) {
            return true
        }
        if let boundDay {
            let calendar = Calendar.current
            if changed.contains(where: { ($0 as? DayNote).map { calendar.isDate($0.day, inSameDayAs: boundDay) } ?? false }) {
                return true
            }
        }
        guard let uuid = selection.selectedNodeUUID else { return false }
        return changed.contains { object in
            (object as? TaskItem)?.uuid == uuid || (object as? Project)?.uuid == uuid
        }
    }

    private func objects(in notification: Notification, key: String) -> [NSManagedObject] {
        guard let set = notification.userInfo?[key] as? Set<NSManagedObject> else { return [] }
        return Array(set)
    }

    private func refreshBoundFields() {
        if let boundDay {
            pushDay(boundDay, replaceNotes: shouldReplaceNotes(with: model.dayNoteText(for: boundDay)))
            return
        }
        if let task = boundTask, task.managedObjectContext != nil, !task.isDeleted {
            pushTask(task, replaceNotes: shouldReplaceNotes(with: model.noteText(of: task)))
            return
        }
        guard let uuid = selection.selectedNodeUUID else {
            boundTask = nil
            boundTaskObjectID = nil
            pushEmpty()
            return
        }
        if let task = try? model.task(uuid: uuid) {
            boundTask = task
            boundTaskObjectID = task.objectID
            pushTask(task, replaceNotes: shouldReplaceNotes(with: model.noteText(of: task)))
            return
        }
        if let project = try? model.project(uuid: uuid) {
            boundTask = nil
            boundTaskObjectID = nil
            pushProject(project)
            return
        }
        boundTask = nil
        boundTaskObjectID = nil
        pushEmpty()
    }

    /// Never clobber what the user is typing: only pull the stored note back in
    /// when the buffer is clean, idle, unfocused, and actually out of date.
    /// Compared as RTF, so a formatting-only change abroad still refreshes.
    private func shouldReplaceNotes(with stored: NSAttributedString) -> Bool {
        if notesBufferIsDirty { return false }
        guard noteSaveTimer == nil else { return false }
        if notesTextView.window?.firstResponder === notesTextView { return false }
        return NoteFormatting.rtf(from: notesContent) != NoteFormatting.rtf(from: stored)
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        guard notification.object as AnyObject === view.window else { return }
        flushPendingNote()
    }

    // MARK: - View → model

    @objc private func completedChanged(_ sender: NSButton) {
        guard !isUpdatingUI, let task = boundTask else { return }
        let completed = sender.state == .on
        guard task.isCompleted != completed else { return }
        do {
            try model.setCompleted(completed, on: task)
        } catch {
            refreshBoundFields()
        }
    }

    @objc private func hasDeadlineChanged(_ sender: NSButton) {
        guard !isUpdatingUI, let task = boundTask else { return }
        if sender.state == .on {
            datePicker.isEnabled = true
            do {
                try model.setDeadline(task, date: datePicker.dateValue)
            } catch {
                refreshBoundFields()
            }
        } else {
            datePicker.isEnabled = false
            do {
                try model.setDeadline(task, date: nil)
            } catch {
                refreshBoundFields()
            }
        }
    }

    @objc private func deadlineChanged(_ sender: NSDatePicker) {
        guard !isUpdatingUI, let task = boundTask else { return }
        guard hasDeadlineCheckbox.state == .on else { return }
        do {
            try model.setDeadline(task, date: sender.dateValue)
        } catch {
            refreshBoundFields()
        }
    }

    /// Every save path funnels through here, so this is the one place the
    /// error indicator is raised and cleared.
    @discardableResult
    private func persistBoundNote() -> Bool {
        let saved = saveBoundNote()
        noteSaveErrorLabel.isHidden = saved
        return saved
    }

    private func saveBoundNote() -> Bool {
        let attributed = notesContent
        // Compare RTF, not just the string: bolding a word changes nothing about
        // the plain text but is still an edit worth saving.
        let newRTF = NoteFormatting.rtf(from: attributed)

        if let boundDay {
            let stored = model.dayNote(for: boundDay)
            guard stored?.noteRTF != newRTF
                || stored?.note != NoteFormatting.plainText(from: attributed)
            else {
                notesBufferIsDirty = false
                return true
            }
            do {
                try model.setDayNote(attributed, on: boundDay)
                notesBufferIsDirty = false
                return true
            } catch {
                return false
            }
        }

        guard let task = boundTask,
              task.managedObjectContext != nil,
              !task.isDeleted
        else {
            notesBufferIsDirty = false
            return true
        }
        guard task.noteRTF != newRTF
            || task.note != NoteFormatting.plainText(from: attributed)
        else {
            notesBufferIsDirty = false
            return true
        }
        do {
            try model.setNote(task, attributed)
            notesBufferIsDirty = false
            return true
        } catch {
            return false
        }
    }

    /// A day has no object ID until its note first exists, so the debounce is
    /// keyed on the selection itself rather than on a managed object.
    @objc private func noteDebounceFired(_ timer: Timer) {
        guard let fired = timer.userInfo as? NoteTargetBox else { return }
        guard fired.target == currentNoteTarget else {
            if noteSaveTimer === timer { noteSaveTimer = nil }
            return
        }
        _ = persistBoundNote()
        if noteSaveTimer === timer {
            noteSaveTimer = nil
        }
    }

    private enum NoteTarget: Equatable {
        case task(NSManagedObjectID)
        case day(Date)
    }

    /// `Timer.userInfo` is `Any?`, so the enum travels boxed in a class.
    private final class NoteTargetBox {
        let target: NoteTarget
        init(_ target: NoteTarget) { self.target = target }
    }

    private var currentNoteTarget: NoteTarget? {
        if let boundDay { return .day(boundDay) }
        if let boundTaskObjectID { return .task(boundTaskObjectID) }
        return nil
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        updateNotesPlaceholder()
        guard !isUpdatingUI else { return }
        guard let target = currentNoteTarget else { return }
        notesBufferIsDirty = true
        noteSaveTimer?.invalidate()
        let timer = Timer(
            timeInterval: Self.noteDebounce,
            target: self,
            selector: #selector(noteDebounceFired(_:)),
            userInfo: NoteTargetBox(target),
            repeats: false
        )
        RunLoop.main.add(timer, forMode: .common)
        noteSaveTimer = timer
    }

    func textDidEndEditing(_ notification: Notification) {
        flushPendingNote()
    }

    func textView(_ textView: NSTextView, undoManagerForTextView view: NSTextView) -> UndoManager? {
        noteUndoManager
    }
}

extension InspectorViewController {
    var test_title: String { titleField.stringValue }
    var test_titleEnabled: Bool { titleField.isEnabled }
    var test_caption: String { captionLabel.stringValue }
    var test_captionHidden: Bool { captionLabel.isHidden }
    var test_dueCaption: String { dueCaptionLabel.stringValue }
    var test_dueCaptionHidden: Bool { dueCaptionLabel.isHidden }
    var test_completedHidden: Bool { completedCheckbox.isHidden }
    var test_completedState: NSControl.StateValue { completedCheckbox.state }
    var test_deadlineRowHidden: Bool { deadlineRow.isHidden }
    var test_hasDeadlineState: NSControl.StateValue { hasDeadlineCheckbox.state }
    var test_datePickerEnabled: Bool { datePicker.isEnabled }
    var test_datePickerValue: Date { datePicker.dateValue }
    var test_notesHidden: Bool { notesScrollView.isHidden }
    var test_noteSaveErrorHidden: Bool { noteSaveErrorLabel.isHidden }
    var test_notesEditable: Bool { notesTextView.isEditable }
    var test_notes: String { notesTextView.string }
    var test_notesAttributed: NSAttributedString { notesContent }
    var test_notesContainerHeight: CGFloat { notesTextView.textContainer?.containerSize.height ?? 0 }
    /// What a click where the "Add a note…" placeholder draws actually lands on.
    /// The placeholder overlays the note, so if it hit-tests it swallows the one
    /// click that should start editing an empty note.
    func test_viewHitWhereThePlaceholderDraws() -> NSView? {
        guard let content = view.window?.contentView, let root = content.superview else { return nil }
        let inPlaceholder = NSPoint(x: 5, y: notesPlaceholder.bounds.midY)
        let inWindow = notesPlaceholder.convert(inPlaceholder, to: nil)
        return content.hitTest(root.convert(inWindow, from: nil))
    }

    var test_notesUsesFindBar: Bool { notesTextView.usesFindBar && notesTextView.isIncrementalSearchingEnabled }
    /// Deliberately never reads `layoutManager`: that call is what would drop
    /// the view to TextKit 1, which is the thing this asserts against.
    var test_notesUsesTextKit2: Bool { notesTextView.textLayoutManager != nil }
    var test_bottomSpacerHidden: Bool { bottomSpacer.isHidden }
    var test_notesSelectedRange: NSRange {
        get { notesTextView.selectedRange() }
        set { notesTextView.setSelectedRange(newValue) }
    }
    var test_noteUndoManager: UndoManager { noteUndoManager }

    func test_setNotes(_ string: String) {
        setNotesContent(NSAttributedString(string: string, attributes: NoteFormatting.typingAttributes))
        textDidChange(Notification(name: NSText.didChangeNotification, object: notesTextView))
    }

    func test_clickCompleted() {
        completedCheckbox.performClick(nil)
    }

    func test_clickHasDeadline() {
        hasDeadlineCheckbox.performClick(nil)
    }

    func test_setDatePicker(_ date: Date) {
        datePicker.dateValue = date
        datePicker.sendAction(datePicker.action, to: datePicker.target)
    }

    func test_saveNoteIfMatching(_ objectID: NSManagedObjectID) {
        guard boundTaskObjectID == objectID else { return }
        persistBoundNote()
    }
}

extension InspectorViewController {
    var test_sourceMessageChip: String? {
        sourceMessageButton.isHidden ? nil : sourceMessageButton.title
    }
}

/// Name + optional completion circle, hosted as a toolbar text field so the
/// unified toolbar does not draw a control capsule around it — the same
/// reason `TitleStatusField` is a text field rather than a stack.
private final class InspectorTitleField: NSTextField {
    let completedButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private static let buttonSize: CGFloat = 17
    private static let spacing: CGFloat = 6
    private static let barHeight: CGFloat = 22

    /// Width the toolbar should give this field: the inspector pane, so the
    /// name sits over the note rather than hugging the string. Constraints,
    /// not `NSToolbarItem.minSize` — that API is deprecated and the item
    /// measures its view from these.
    var preferredToolbarWidth: CGFloat = 220 {
        didSet {
            guard abs(preferredToolbarWidth - oldValue) > 0.5 else { return }
            widthConstraint.constant = preferredToolbarWidth
            invalidateIntrinsicContentSize()
        }
    }

    private var widthConstraint: NSLayoutConstraint!

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: Self.barHeight))
        cell = InspectorTitleCell(textCell: "")
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        refusesFirstResponder = true
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
        cell?.truncatesLastVisibleLine = true
        alignment = .left
        font = .systemFont(ofSize: 13, weight: .semibold)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        stringValue = "Select a task to edit its note"
        isEnabled = false

        let symbol = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        completedButton.setButtonType(.toggle)
        completedButton.isBordered = false
        completedButton.title = ""
        completedButton.imagePosition = .imageOnly
        completedButton.imageScaling = .scaleProportionallyDown
        completedButton.image = NSImage(systemSymbolName: "circle", accessibilityDescription: "Mark complete")?
            .withSymbolConfiguration(symbol)
        completedButton.alternateImage = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Completed")?
            .withSymbolConfiguration(symbol)
        completedButton.contentTintColor = .tertiaryLabelColor
        completedButton.setAccessibilityLabel("Completed")
        completedButton.isEnabled = false
        completedButton.isHidden = true
        completedButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(completedButton)

        widthConstraint = widthAnchor.constraint(equalToConstant: 220)
        NSLayoutConstraint.activate([
            widthConstraint,
            heightAnchor.constraint(equalToConstant: Self.barHeight),
            completedButton.widthAnchor.constraint(equalToConstant: Self.buttonSize),
            completedButton.heightAnchor.constraint(equalToConstant: Self.buttonSize),
            completedButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            completedButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    fileprivate func refreshTitleInset() {
        (cell as? InspectorTitleCell)?.leadingInset = completedButton.isHidden
            ? 0 : Self.buttonSize + Self.spacing
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: preferredToolbarWidth, height: Self.barHeight)
    }
}

/// A label that overlays an editable view, so it must never take the mouse:
/// `NSTextField` swallows `mouseDown` even when it is neither editable nor
/// selectable, and `refusesFirstResponder` does not stop that — it only keeps
/// the label out of the key-view loop. Without this, clicking the placeholder
/// of an empty note did nothing at all.
private final class PlaceholderLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class InspectorTitleCell: NSTextFieldCell {
    var leadingInset: CGFloat = 0

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        var inset = super.titleRect(forBounds: rect)
        inset.origin.x += leadingInset
        inset.size.width = max(0, inset.size.width - leadingInset)
        return inset
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        titleRect(forBounds: rect)
    }
}
