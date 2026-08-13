import AppKit
import CoreData

final class InspectorViewController: NSViewController, NSTextViewDelegate {
    private static let noteDebounce: TimeInterval = 0.4

    let persistence: PersistenceController
    let model: ModelController
    let selection: SelectionModel

    private let titleLabel = NSTextField(labelWithString: "Select a task")
    private let captionLabel = NSTextField(labelWithString: "")
    private let completedCheckbox = NSButton(checkboxWithTitle: "Completed", target: nil, action: nil)
    private let hasDeadlineCheckbox = NSButton(checkboxWithTitle: "Has deadline", target: nil, action: nil)
    private let datePicker = NSDatePicker()
    private let deadlineRow = NSStackView()
    private let notesLabel = NSTextField(labelWithString: "Notes")
    private let notesScrollView = NSTextView.scrollableTextView()
    private let notesTextView: NSTextView

    private var isUpdatingUI = false
    private var isRevertingFailedFlush = false
    private var boundTask: TaskItem?
    private var boundTaskObjectID: NSManagedObjectID?
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
        notesTextView = notesScrollView.documentView as! NSTextView
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
        view = NSView()
        configureControls()

        deadlineRow.orientation = .horizontal
        deadlineRow.alignment = .centerY
        deadlineRow.spacing = 8
        deadlineRow.addArrangedSubview(hasDeadlineCheckbox)
        deadlineRow.addArrangedSubview(datePicker)
        deadlineRow.isHidden = true

        let stack = NSStackView(views: [
            titleLabel,
            captionLabel,
            completedCheckbox,
            deadlineRow,
            notesLabel,
            notesScrollView,
        ])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        notesScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        notesScrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        startObserving()
        bindToCurrentSelection()
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
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.isEnabled = false

        captionLabel.lineBreakMode = .byTruncatingTail
        captionLabel.maximumNumberOfLines = 1
        captionLabel.font = .preferredFont(forTextStyle: .callout)
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.isHidden = true

        completedCheckbox.target = self
        completedCheckbox.action = #selector(completedChanged(_:))
        completedCheckbox.isEnabled = false
        completedCheckbox.isHidden = true

        hasDeadlineCheckbox.target = self
        hasDeadlineCheckbox.action = #selector(hasDeadlineChanged(_:))
        hasDeadlineCheckbox.isEnabled = false

        datePicker.datePickerStyle = .textFieldAndStepper
        datePicker.datePickerMode = .single
        datePicker.datePickerElements = .yearMonthDay
        datePicker.target = self
        datePicker.action = #selector(deadlineChanged(_:))
        datePicker.isEnabled = false

        notesLabel.isHidden = true

        notesScrollView.borderType = .bezelBorder
        notesScrollView.hasVerticalScroller = true
        notesScrollView.autohidesScrollers = true
        notesScrollView.isHidden = true

        notesTextView.isRichText = false
        notesTextView.usesFontPanel = false
        notesTextView.importsGraphics = false
        notesTextView.font = .preferredFont(forTextStyle: .body)
        notesTextView.isEditable = false
        notesTextView.isSelectable = false
        notesTextView.delegate = self
        notesTextView.allowsUndo = true
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
        guard fields.contains(SelectionField.node.rawValue) else { return }
        if isRevertingFailedFlush { return }
        noteSaveTimer?.invalidate()
        noteSaveTimer = nil
        if !flushPendingNote() {
            if let previousUUID = boundTask?.uuid, selection.selectedNodeUUID != previousUUID {
                isRevertingFailedFlush = true
                selection.selectNode(uuid: previousUUID)
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

        guard let uuid = selection.selectedNodeUUID else {
            pushEmpty()
            return
        }
        if let task = try? model.task(uuid: uuid) {
            boundTask = task
            boundTaskObjectID = task.objectID
            pushTask(task, replaceNotes: true)
            return
        }
        if let project = try? model.project(uuid: uuid) {
            pushProject(project)
            return
        }
        pushEmpty()
    }

    // MARK: - Model → view

    private func pushEmpty() {
        isUpdatingUI = true
        defer { isUpdatingUI = false }

        titleLabel.stringValue = "Select a task"
        titleLabel.isEnabled = false
        captionLabel.isHidden = true
        completedCheckbox.isHidden = true
        completedCheckbox.isEnabled = false
        completedCheckbox.state = .off
        deadlineRow.isHidden = true
        hasDeadlineCheckbox.isEnabled = false
        hasDeadlineCheckbox.state = .off
        datePicker.isEnabled = false
        notesLabel.isHidden = true
        notesScrollView.isHidden = true
        notesTextView.string = ""
        notesTextView.isEditable = false
        notesTextView.isSelectable = false
    }

    private func pushProject(_ project: Project) {
        isUpdatingUI = true
        defer { isUpdatingUI = false }

        titleLabel.stringValue = project.title
        titleLabel.isEnabled = true
        let count = descendantTaskCount(of: project)
        captionLabel.stringValue = count == 1 ? "1 task" : "\(count) tasks"
        captionLabel.isHidden = false
        completedCheckbox.isHidden = true
        completedCheckbox.isEnabled = false
        completedCheckbox.state = .off
        deadlineRow.isHidden = true
        hasDeadlineCheckbox.isEnabled = false
        hasDeadlineCheckbox.state = .off
        datePicker.isEnabled = false
        notesLabel.isHidden = true
        notesScrollView.isHidden = true
        notesTextView.string = ""
        notesTextView.isEditable = false
        notesTextView.isSelectable = false
    }

    private func pushTask(_ task: TaskItem, replaceNotes: Bool) {
        isUpdatingUI = true
        defer { isUpdatingUI = false }

        titleLabel.stringValue = task.title
        titleLabel.isEnabled = true
        captionLabel.isHidden = true
        completedCheckbox.isHidden = false
        completedCheckbox.isEnabled = true
        completedCheckbox.state = task.isCompleted ? .on : .off
        deadlineRow.isHidden = false
        hasDeadlineCheckbox.isEnabled = true
        if let deadline = task.deadline {
            hasDeadlineCheckbox.state = .on
            datePicker.dateValue = deadline
            datePicker.isEnabled = true
        } else {
            hasDeadlineCheckbox.state = .off
            datePicker.dateValue = Calendar.current.startOfDay(for: Date())
            datePicker.isEnabled = false
        }
        notesLabel.isHidden = false
        notesScrollView.isHidden = false
        notesTextView.isEditable = true
        notesTextView.isSelectable = true
        if replaceNotes {
            notesTextView.string = task.note ?? ""
        }
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
        guard touchesSelectedNode(notification) else { return }
        refreshBoundFields()
    }

    @objc private func contextObjectsDidChange(_ notification: Notification) {
        guard notification.userInfo?[NSInvalidatedAllObjectsKey] != nil else { return }
        refreshBoundFields()
    }

    private func touchesSelectedNode(_ notification: Notification) -> Bool {
        guard let uuid = selection.selectedNodeUUID else { return false }
        let objects =
            objects(in: notification, key: NSInsertedObjectsKey)
            + objects(in: notification, key: NSUpdatedObjectsKey)
            + objects(in: notification, key: NSDeletedObjectsKey)
        return objects.contains { object in
            (object as? TaskItem)?.uuid == uuid || (object as? Project)?.uuid == uuid
        }
    }

    private func objects(in notification: Notification, key: String) -> [NSManagedObject] {
        guard let set = notification.userInfo?[key] as? Set<NSManagedObject> else { return [] }
        return Array(set)
    }

    private func refreshBoundFields() {
        guard let uuid = selection.selectedNodeUUID else { return }
        if let task = try? model.task(uuid: uuid) {
            boundTask = task
            boundTaskObjectID = task.objectID
            pushTask(task, replaceNotes: shouldReplaceNotes(with: task))
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

    private func shouldReplaceNotes(with task: TaskItem) -> Bool {
        guard noteSaveTimer == nil else { return false }
        if notesTextView.window?.firstResponder === notesTextView { return false }
        return notesTextView.string != (task.note ?? "")
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

    @discardableResult
    private func persistBoundNote() -> Bool {
        guard let task = boundTask,
              task.managedObjectContext != nil,
              !task.isDeleted
        else { return true }
        let text = notesTextView.string
        let newNote: String? = text.isEmpty ? nil : text
        guard task.note != newNote else { return true }
        do {
            try model.setNote(task, text)
            return true
        } catch {
            return false
        }
    }

    @objc private func noteDebounceFired(_ timer: Timer) {
        guard let objectID = timer.userInfo as? NSManagedObjectID else { return }
        guard boundTaskObjectID == objectID else {
            if noteSaveTimer === timer { noteSaveTimer = nil }
            return
        }
        _ = persistBoundNote()
        if noteSaveTimer === timer {
            noteSaveTimer = nil
        }
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard !isUpdatingUI else { return }
        guard let objectID = boundTaskObjectID else { return }
        noteSaveTimer?.invalidate()
        let timer = Timer(
            timeInterval: Self.noteDebounce,
            target: self,
            selector: #selector(noteDebounceFired(_:)),
            userInfo: objectID,
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
    var test_title: String { titleLabel.stringValue }
    var test_titleEnabled: Bool { titleLabel.isEnabled }
    var test_caption: String { captionLabel.stringValue }
    var test_captionHidden: Bool { captionLabel.isHidden }
    var test_completedHidden: Bool { completedCheckbox.isHidden }
    var test_completedState: NSControl.StateValue { completedCheckbox.state }
    var test_deadlineRowHidden: Bool { deadlineRow.isHidden }
    var test_hasDeadlineState: NSControl.StateValue { hasDeadlineCheckbox.state }
    var test_datePickerEnabled: Bool { datePicker.isEnabled }
    var test_datePickerValue: Date { datePicker.dateValue }
    var test_notesHidden: Bool { notesScrollView.isHidden }
    var test_notesEditable: Bool { notesTextView.isEditable }
    var test_notes: String { notesTextView.string }
    var test_notesSelectedRange: NSRange {
        get { notesTextView.selectedRange() }
        set { notesTextView.setSelectedRange(newValue) }
    }
    var test_noteUndoManager: UndoManager { noteUndoManager }

    func test_setNotes(_ string: String) {
        notesTextView.string = string
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
