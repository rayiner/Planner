import AppKit
import CoreData

final class CalendarViewController: NSViewController {
    let persistence: PersistenceController
    let model: ModelController
    let selection: SelectionModel
    let monthView = MonthCalendarView()

    private var fetchedResultsController: NSFetchedResultsController<TaskItem>?

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
        monthView.visibleMonth = selection.visibleMonth
        monthView.selectedDay = selection.selectedDay
        monthView.selectedTaskID = selection.selectedNodeUUID
        view = monthView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        monthView.delegate = self
        startObserving()
        rebuildFRC(for: selection.visibleMonth)
    }

    static func request(for visibleMonth: Date, calendar: Calendar = .current) -> NSFetchRequest<TaskItem> {
        let days = calendar.daysInMonthGrid(for: visibleMonth)
        let start = days[0]
        let end = calendar.date(byAdding: .day, value: 1, to: days[41])!
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
    }

    @objc private func plannerSelectionDidChange(_ notification: Notification) {
        let fields = notification.userInfo?[SelectionUserInfoKey.changedFields] as? Set<String> ?? []
        if fields.contains(SelectionField.visibleMonth.rawValue) {
            monthView.visibleMonth = selection.visibleMonth
            rebuildFRC(for: selection.visibleMonth)
        }
        if fields.contains(SelectionField.day.rawValue) {
            monthView.selectedDay = selection.selectedDay
        }
        if fields.contains(SelectionField.node.rawValue) {
            monthView.selectedTaskID = selection.selectedNodeUUID
        }
    }

    private func rebuildFRC(for visibleMonth: Date) {
        fetchedResultsController?.delegate = nil
        let controller = NSFetchedResultsController(
            fetchRequest: Self.request(for: visibleMonth),
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
        monthView.deadlines = tasks.compactMap { task in
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

extension CalendarViewController: MonthCalendarViewDelegate {
    func monthCalendar(_ view: MonthCalendarView, didSelectTaskID uuid: UUID) {
        selection.selectNode(uuid: uuid)
    }

    func monthCalendar(_ view: MonthCalendarView, didSelectDay date: Date) {
        selection.selectDay(date)
    }

    func monthCalendar(_ view: MonthCalendarView, didChangeVisibleMonth date: Date) {
        // Apply via the observer so the view setter never re-enters the delegate.
        selection.setVisibleMonth(date)
    }
}

extension CalendarViewController: NSFetchedResultsControllerDelegate {
    func controllerDidChangeContent(_ controller: NSFetchedResultsController<any NSFetchRequestResult>) {
        applyDeadlines()
    }
}

extension CalendarViewController {
    var test_monthView: MonthCalendarView { monthView }
    var test_title: String { monthView.test_title }
}
