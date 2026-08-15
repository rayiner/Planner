import AppKit
import CoreData

final class CalendarViewController: NSViewController {
    let persistence: PersistenceController
    let model: ModelController
    let selection: SelectionModel
    let events: EventCoordinator
    let weekView = WeekCalendarView()

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
        weekView.visibleWeekStart = selection.visibleWeekStart
        weekView.selectedDay = selection.selectedDay
        weekView.selectedTaskID = selection.selectedNodeUUID
        weekView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSVisualEffectView()
        container.material = .contentBackground
        container.blendingMode = .behindWindow
        container.state = .followsWindowActiveState

        container.addSubview(weekView)

        NSLayoutConstraint.activate([
            weekView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            weekView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            weekView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            weekView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        weekView.delegate = self
        startObserving()
        rebuildFRC(for: selection.visibleWeekStart)
        applyDayNotes()
        applyEvents()
        events.refresh()
    }

    static func request(
        for visibleWeekStart: Date,
        weekCount: Int,
        calendar: Calendar = .current
    ) -> NSFetchRequest<TaskItem> {
        let start = calendar.startOfWeek(for: visibleWeekStart)
        let end = calendar.endOfWeeks(from: start, count: weekCount)
        let request = TaskItem.fetchRequest()
        request.predicate = NSPredicate(
            format: "deadline >= %@ AND deadline < %@",
            start as NSDate,
            end as NSDate
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
    }

    @objc private func contextDidSave(_ notification: Notification) {
        applyDayNotes()
    }

    @objc private func eventsDidChange(_ notification: Notification) {
        applyEvents()
    }

    /// Events are fetched for a window months wide, so only the chips for the
    /// visible span are handed to the grid; paging within the window is a
    /// dictionary lookup rather than a refetch.
    private func applyEvents() {
        let calendar = Calendar.current
        let starts = calendar.weekStarts(
            from: selection.visibleWeekStart,
            count: weekView.visibleWeekCount
        )
        weekView.events = starts
            .flatMap { calendar.days(inWeekStartingAt: $0) }
            .flatMap { events.chips(forDay: $0) }
    }

    private func applyDayNotes() {
        let calendar = Calendar.current
        let start = calendar.startOfWeek(for: selection.visibleWeekStart)
        let end = calendar.endOfWeeks(from: start, count: weekView.visibleWeekCount)
        weekView.daysWithNotes = (try? model.daysWithNotes(from: start, to: end)) ?? []
    }

    @objc private func plannerSelectionDidChange(_ notification: Notification) {
        let fields = notification.userInfo?[SelectionUserInfoKey.changedFields] as? Set<String> ?? []
        if fields.contains(SelectionField.visibleWeek.rawValue) {
            weekView.visibleWeekStart = selection.visibleWeekStart
            rebuildFRC(for: selection.visibleWeekStart)
            applyDayNotes()
            applyEvents()
        }
        if fields.contains(SelectionField.day.rawValue) {
            weekView.selectedDay = selection.selectedDay
        }
        if fields.contains(SelectionField.node.rawValue) {
            weekView.selectedTaskID = selection.selectedNodeUUID
        }
    }

    private func rebuildFRC(for visibleWeekStart: Date) {
        fetchedResultsController?.delegate = nil
        let controller = NSFetchedResultsController(
            fetchRequest: Self.request(for: visibleWeekStart, weekCount: weekView.visibleWeekCount),
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
        // The inspector is a pane now: it rebinds from SelectionModel on its own.
        // Forcing focus into the note here would fight the outline's reveal.
        selection.selectNode(uuid: uuid)
    }

    func weekCalendar(_ view: WeekCalendarView, didSelectDay date: Date) {
        selection.selectDay(date)
    }

    func weekCalendar(_ view: WeekCalendarView, didChangeVisibleWeekStart date: Date) {
        // Apply via the observer so the view setter never re-enters the delegate.
        selection.setVisibleWeekStart(date)
    }

    /// The pane got wider or narrower, so a different number of weeks is on
    /// screen and the fetch window has to follow.
    func weekCalendar(_ view: WeekCalendarView, didChangeVisibleWeekCount count: Int) {
        rebuildFRC(for: selection.visibleWeekStart)
        applyDayNotes()
        applyEvents()
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
        rebuildFRC(for: selection.visibleWeekStart)
        applyEvents()
    }

    func test_applyEvents() { applyEvents() }
}
