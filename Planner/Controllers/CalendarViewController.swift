import AppKit
import CoreData

final class CalendarViewController: NSViewController {
    let persistence: PersistenceController
    let model: ModelController
    let selection: SelectionModel
    let events: EventCoordinator
    let weekView = WeekCalendarView()
    let scrollView = NSScrollView()

    private var fetchedResultsController: NSFetchedResultsController<TaskItem>?

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
        weekView.selectedDay = selection.selectedDay
        weekView.selectedTaskID = selection.selectedNodeUUID
        // The sheet is the scroll view's document view: it sizes itself from the
        // clip view and positions its own cells, so it stays out of Auto Layout.
        weekView.translatesAutoresizingMaskIntoConstraints = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        // Horizontal elasticity would let the sheet slide out from under its
        // own columns; it has nowhere to go sideways.
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = weekView

        let container = NSVisualEffectView()
        container.material = .contentBackground
        container.blendingMode = .behindWindow
        container.state = .followsWindowActiveState

        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        weekView.delegate = self
        startObserving()
        applyLoadedRange()
        events.refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // The clip view has a height at last, so the sheet can put the stored
        // day under the top edge rather than opening at the start of 2024.
        weekView.scroll(toDay: selection.visibleWeekStart)
    }

    static func request(for range: Range<Date>) -> NSFetchRequest<TaskItem> {
        let request = TaskItem.fetchRequest()
        request.predicate = NSPredicate(
            format: "deadline >= %@ AND deadline < %@",
            range.lowerBound as NSDate,
            range.upperBound as NSDate
        )
        request.sortDescriptors = [
            NSSortDescriptor(key: "deadline", ascending: true),
            NSSortDescriptor(key: "sortIndex", ascending: true),
            NSSortDescriptor(key: "uuid", ascending: true),
        ]
        return request
    }

    private func startObserving() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(plannerSelectionDidChange(_:)),
            name: .plannerSelectionDidChange,
            object: selection
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(eventsDidChange(_:)),
            name: .plannerEventsDidChange,
            object: events
        )
        // Day notes are not in the deadline FRC, so their dots refresh on save.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contextDidSave(_:)),
            name: .NSManagedObjectContextDidSave,
            object: persistence.viewContext
        )
        // An import merges rather than saves, so it needs its own hook.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contextDidSave(_:)),
            name: .plannerStoreDidChangeRemotely,
            object: nil
        )
    }

    @objc private func contextDidSave(_ notification: Notification) {
        applyDayNotes()
    }

    @objc private func eventsDidChange(_ notification: Notification) {
        applyEvents()
    }

    /// Everything the sheet's fetch window covers: deadlines, notes and event
    /// chips. The window is a screenful either side of what is on screen, so an
    /// ordinary scroll is answered from what is already in hand.
    private func applyLoadedRange() {
        rebuildFRC()
        applyDayNotes()
        applyEvents()
    }

    /// Events are fetched for a window months wide, so only the chips inside
    /// the sheet's fetch window are handed over; scrolling within that window
    /// is a dictionary lookup rather than a refetch.
    private func applyEvents() {
        let calendar = Calendar.current
        let range = weekView.loadedRange
        let count = calendar.dateComponents([.day], from: range.lowerBound, to: range.upperBound).day ?? 0
        let days = calendar.visibleDays(from: range.lowerBound, count: count)
        weekView.events = days.flatMap { events.chips(forDay: $0) }
    }

    private func applyDayNotes() {
        let range = weekView.loadedRange
        weekView.daysWithNotes =
            (try? model.daysWithNotes(from: range.lowerBound, to: range.upperBound)) ?? []
    }

    @objc private func plannerSelectionDidChange(_ notification: Notification) {
        let fields = notification.userInfo?[SelectionUserInfoKey.changedFields] as? Set<String> ?? []
        if fields.contains(SelectionField.visibleWeek.rawValue) {
            // A no-op when the change came from our own scroll; a scroll when it
            // came from Today or a reveal.
            weekView.visibleWeekStart = selection.visibleWeekStart
        }
        if fields.contains(SelectionField.day.rawValue) {
            weekView.selectedDay = selection.selectedDay
        }
        if fields.contains(SelectionField.node.rawValue) {
            weekView.selectedTaskID = selection.selectedNodeUUID
        }
    }

    private func rebuildFRC() {
        fetchedResultsController?.delegate = nil
        let controller = NSFetchedResultsController(
            fetchRequest: Self.request(for: weekView.loadedRange),
            managedObjectContext: persistence.viewContext,
            sectionNameKeyPath: nil,
            cacheName: nil
        )
        controller.delegate = self
        fetchedResultsController = controller
        do {
            try controller.performFetch()
        } catch {
            PlannerLog.calendar.error("Calendar fetch failed: \(error.localizedDescription, privacy: .public)")
        }
        applyDeadlines()
    }

    private func applyDeadlines() {
        let calendar = Calendar.current
        let tasks = fetchedResultsController?.fetchedObjects ?? []
        weekView.deadlines = tasks.compactMap { task in
            guard let deadline = task.deadline else { return nil }
            return TaskDeadlineChip(
                uuid: task.uuid,
                title: task.title,
                day: calendar.startOfDay(for: deadline),
                isCompleted: task.isCompleted
            )
        }
    }
}

extension CalendarViewController: WeekCalendarViewDelegate {
    func weekCalendar(_ view: WeekCalendarView, didSelectTaskID uuid: UUID) {
        selection.selectNode(uuid: uuid)
    }

    func weekCalendar(_ view: WeekCalendarView, didSelectDay date: Date) {
        selection.selectDay(date)
    }

    func weekCalendar(_ view: WeekCalendarView, didDoubleClickDay date: Date) {
        selection.selectDay(date)
        ItemWindowController.openDayNote(day: date, persistence: persistence, model: model)
    }

    /// A chip is a task, so it opens the task the way the outline does.
    func weekCalendar(_ view: WeekCalendarView, didDoubleClickTaskID uuid: UUID) {
        selection.selectNode(uuid: uuid)
        try? ItemWindowController.openTask(uuid: uuid, persistence: persistence, model: model)
    }

    func weekCalendar(_ view: WeekCalendarView, didChangeVisibleWeekStart date: Date) {
        // Apply via the observer so the view setter never re-enters the delegate.
        selection.setVisibleWeekStart(date)
        NSApp.sendAction(#selector(MainSplitViewController.refreshCalendarTitle), to: nil, from: self)
    }

    /// The scroll ran off the end of what was fetched, or a reflow re-cut the
    /// rows, so the fetch window moved and everything keyed to it follows.
    func weekCalendar(_ view: WeekCalendarView, didChangeLoadedRange range: Range<Date>) {
        applyLoadedRange()
        NSApp.sendAction(#selector(MainSplitViewController.refreshCalendarTitle), to: nil, from: self)
    }
}

extension CalendarViewController: NSFetchedResultsControllerDelegate {
    func controllerDidChangeContent(_ controller: NSFetchedResultsController<any NSFetchRequestResult>) {
        applyDeadlines()
    }
}

extension CalendarViewController {
    var test_weekView: WeekCalendarView { weekView }
    var test_title: String { weekView.test_title }

    func test_setWeekCount(_ count: Int) {
        weekView.test_setWeekCount(count)
        applyLoadedRange()
    }

    func test_applyEvents() { applyEvents() }
    func test_applyLoadedRange() { applyLoadedRange() }
}
