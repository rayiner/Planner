import AppKit

protocol WeekCalendarViewDelegate: AnyObject {
    func weekCalendar(_ view: WeekCalendarView, didSelectTaskID uuid: UUID)
    func weekCalendar(_ view: WeekCalendarView, didSelectDay date: Date)
    func weekCalendar(_ view: WeekCalendarView, didChangeVisibleWeekStart date: Date)
    func weekCalendar(_ view: WeekCalendarView, didChangeVisibleWeekCount count: Int)
}

struct TaskDeadlineChip: Hashable {
    var uuid: UUID
    var title: String
    var day: Date
    var isCompleted: Bool
}

/// Days flow in reading order: the first visible day at the top left, each
/// row filling left to right before the next begins. A row holds one day per
/// column — the count the pane width allows — so the grid is always seven
/// rows and paging moves by that many days, one column at a time. Weekend
/// cells are full size; a gray wash is what distinguishes them from weekdays.
final class WeekCalendarView: NSView {
    /// Upper bound only; each cell fits as many chips as its height allows.
    fileprivate static let maxVisibleChips = 6

    /// Days per week over days per row (`visibleWeekCount`): the grid is
    /// always exactly seven rows deep.
    static let rowCount = 7

    /// Width a chip's text loses to insets before a glyph is drawn: the cell's
    /// inset on both sides, plus the chip's bar gutter and trailing padding.
    static var chipTextHorizontalInset: CGFloat {
        DayCellView.inset * 2 + DeadlineChipView.textLeading + DeadlineChipView.textTrailing
    }

    /// The narrowest column is calibrated on a realistic longest task title, so
    /// even the tightest column shows one whole. Measured rather than hardcoded
    /// so it survives a change of chip font or padding.
    static let chipWidthCalibrationTitle = "Qualcomm brief due"

    static let targetColumnWidth: CGFloat = {
        let text = chipWidthCalibrationTitle as NSString
        let width = text.size(withAttributes: [.font: DeadlineChipView.titleFont]).width
        return (width + chipTextHorizontalInset).rounded(.up)
    }()

    /// Room a chip title actually gets in a column of `columnWidth`.
    static func chipTextWidth(inColumnOfWidth columnWidth: CGFloat) -> CGFloat {
        max(0, columnWidth - chipTextHorizontalInset)
    }

    static let minimumWeekCount = 2
    static let maximumWeekCount = 8

    weak var delegate: WeekCalendarViewDelegate?

    /// First visible day. Setter must not call the delegate.
    var visibleWeekStart: Date {
        get { _visibleWeekStart }
        set {
            let normalized = Calendar.current.startOfDay(for: newValue)
            guard _visibleWeekStart != normalized else { return }
            _visibleWeekStart = normalized
            applyVisibleWeeks()
        }
    }

    private(set) var visibleWeekCount: Int = 4

    var deadlines: [TaskDeadlineChip] = [] {
        didSet { applyChipsToCells() }
    }

    /// External calendar events, already expanded to one chip per day. Read
    /// only: they cannot be selected, edited, or completed.
    var events: [CalendarEventChip] = [] {
        didSet { applyChipsToCells() }
    }

    /// Start-of-day dates that carry a note, marked with a dot in the cell.
    var daysWithNotes: Set<Date> = [] {
        didSet {
            guard daysWithNotes != oldValue else { return }
            applyNoteMarkers()
        }
    }

    var selectedTaskID: UUID? {
        didSet {
            guard selectedTaskID != oldValue else { return }
            for cell in dayCells { cell.selectedTaskID = selectedTaskID }
        }
    }

    var selectedDay: Date? {
        get { _selectedDay }
        set {
            let normalized = newValue.map { Calendar.current.startOfDay(for: $0) }
            guard _selectedDay != normalized else { return }
            _selectedDay = normalized
            applySelectionHighlights()
        }
    }

    private var _visibleWeekStart: Date
    private var _selectedDay: Date?

    private let gridContainer = GridContainer()
    /// Chronological, first visible day first; the cell at index `i` sits at
    /// row `i / visibleWeekCount`, column `i % visibleWeekCount`.
    private var dayCells: [DayCellView] = []

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        _visibleWeekStart = Calendar.current.startOfDay(for: Date())
        super.init(frame: frameRect)
        configure()
        rebuildCells()
        applyVisibleWeeks()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Calls `didChangeVisibleWeekStart` with today; does not assign.
    func revealToday() {
        delegate?.weekCalendar(self, didChangeVisibleWeekStart: Date())
    }

    func goToPreviousWeek() {
        shiftVisibleWeeks(by: -1)
    }

    func goToNextWeek() {
        shiftVisibleWeeks(by: 1)
    }

    /// One step is one column: the grid slides left or right by the number of
    /// days in a row, so every cell moves into its neighbour's place.
    private func shiftVisibleWeeks(by weeks: Int) {
        let target = Calendar.current.date(
            byAdding: .day,
            value: weeks * visibleWeekCount,
            to: _visibleWeekStart
        )!
        delegate?.weekCalendar(self, didChangeVisibleWeekStart: target)
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let offset = Self.dayOffset(for: event, daysPerRow: visibleWeekCount) else {
            super.keyDown(with: event)
            return
        }
        moveSelection(byDays: offset)
    }

    /// Reading order: horizontal movement walks days along a row; vertical
    /// movement jumps a whole row, which is one day per visible week.
    static func dayOffset(for event: NSEvent, daysPerRow: Int) -> Int? {
        switch Int(event.keyCode) {
        case 123: return -1            // left
        case 124: return 1             // right
        case 125: return daysPerRow    // down
        case 126: return -daysPerRow   // up
        default: return nil
        }
    }

    func moveSelection(byDays offset: Int) {
        let calendar = Calendar.current
        // Taking focus must not change the selection on its own — merely hiding a
        // pane moves first responder here, and that should not retarget the
        // inspector. So the first arrow press is what seeds a day, landing on
        // today rather than a day away from it.
        guard let anchor = _selectedDay else {
            select(calendar.startOfDay(for: Date()))
            return
        }
        guard let target = calendar.date(byAdding: .day, value: offset, to: anchor) else { return }
        select(calendar.startOfDay(for: target))
    }

    private func select(_ day: Date) {
        let calendar = Calendar.current
        delegate?.weekCalendar(self, didSelectDay: day)

        // Page only when the new day falls outside what is on screen, and
        // then by whole columns so the grid stays on its current phase.
        let firstVisible = calendar.startOfDay(for: _visibleWeekStart)
        let lastVisible = calendar.endOfWeeks(from: firstVisible, count: visibleWeekCount)
        if day < firstVisible || day >= lastVisible {
            delegate?.weekCalendar(self, didChangeVisibleWeekStart: pagedStart(containing: day))
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        if gridContainer.bounds.width <= 0 || gridContainer.bounds.height <= 0, bounds.width > 0 {
            gridContainer.frame = NSRect(
                x: 0,
                y: 0,
                width: max(0, bounds.width),
                height: max(0, bounds.height - 8)
            )
        }
        updateWeekCountForWidth()
        layoutGrid()
    }

    /// Columns keep a readable width; the visible week count follows the pane.
    static func weekCount(fittingWidth width: CGFloat) -> Int {
        guard width > 0 else { return minimumWeekCount }
        let raw = Int((width / targetColumnWidth).rounded(.down))
        return max(minimumWeekCount, min(maximumWeekCount, raw))
    }

    private func updateWeekCountForWidth() {
        let wanted = Self.weekCount(fittingWidth: gridContainer.bounds.width)
        guard wanted != visibleWeekCount else { return }
        visibleWeekCount = wanted
        rebuildCells()
        applyVisibleWeeks()
        delegate?.weekCalendar(self, didChangeVisibleWeekCount: wanted)
    }

    /// Seven equal row bands, top to bottom. Every day — weekend included — is
    /// full size; the weekend's mark is its wash, not its height.
    static func rowFrames(in height: CGFloat) -> [NSRect] {
        let rowHeight = height / CGFloat(rowCount)
        return (0..<rowCount).map {
            NSRect(x: 0, y: CGFloat($0) * rowHeight, width: 0, height: rowHeight)
        }
    }

    static func columnFrames(in width: CGFloat, count: Int) -> [NSRect] {
        guard count > 0 else { return [] }
        let columnWidth = width / CGFloat(count)
        return (0..<count).map {
            NSRect(x: CGFloat($0) * columnWidth, y: 0, width: columnWidth, height: 0)
        }
    }

    private func layoutGrid() {
        let bounds = gridContainer.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        gridContainer.weekCount = visibleWeekCount
        gridContainer.needsDisplay = true

        let columns = Self.columnFrames(in: bounds.width, count: visibleWeekCount)
        let rows = Self.rowFrames(in: bounds.height)

        // Reading order: fill a row left to right, then start the next.
        for (index, cell) in dayCells.enumerated() {
            let row = index / visibleWeekCount
            let column = index % visibleWeekCount
            guard row < rows.count, column < columns.count else { continue }
            cell.frame = NSRect(
                x: columns[column].minX,
                y: rows[row].minY,
                width: columns[column].width,
                height: rows[row].height
            )
        }
    }

    private func configure() {
        gridContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gridContainer)
        NSLayoutConstraint.activate([
            gridContainer.topAnchor.constraint(equalTo: topAnchor),
            gridContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            gridContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            gridContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    private func rebuildCells() {
        dayCells.forEach { $0.removeFromSuperview() }
        dayCells = (0..<(visibleWeekCount * 7)).map { _ in
            let cell = DayCellView()
            cell.onChipClick = { [weak self] chip in
                self?.handleChipClick(chip)
            }
            cell.onDayClick = { [weak self] day in
                self?.handleDayClick(day)
            }
            cell.onEventClick = { [weak self] chip in
                self?.handleEventClick(chip)
            }
            gridContainer.addSubview(cell)
            return cell
        }
    }

    /// The first visible day plus whole columns until `day` is on screen.
    private func pagedStart(containing day: Date) -> Date {
        let calendar = Calendar.current
        let first = calendar.startOfDay(for: _visibleWeekStart)
        let step = max(1, visibleWeekCount)
        let span = visibleWeekCount * Self.rowCount
        if day < first {
            let daysBack = calendar.dateComponents([.day], from: day, to: first).day ?? 0
            let steps = (daysBack + step - 1) / step
            return calendar.date(byAdding: .day, value: -steps * step, to: first)!
        }
        let daysForward = calendar.dateComponents([.day], from: first, to: day).day ?? 0
        let steps = (daysForward - span + step) / step
        return calendar.date(byAdding: .day, value: steps * step, to: first)!
    }

    private func applyVisibleWeeks() {
        let calendar = Calendar.current
        let days = calendar.visibleDays(
            from: _visibleWeekStart,
            count: visibleWeekCount * Self.rowCount
        )
        for (index, day) in days.enumerated() {
            guard dayCells.indices.contains(index) else { continue }
            dayCells[index].configure(
                day: day,
                isWeekend: calendar.isWeekend(day),
                selectedDay: _selectedDay
            )
        }
        applyChipsToCells()
        applyNoteMarkers()
    }

    private func applyNoteMarkers() {
        let calendar = Calendar.current
        for cell in dayCells {
            cell.hasNote = daysWithNotes.contains(calendar.startOfDay(for: cell.day))
        }
    }

    private func applySelectionHighlights() {
        let calendar = Calendar.current
        for cell in dayCells {
            cell.isSelected = _selectedDay.map { calendar.isDate(cell.day, inSameDayAs: $0) } ?? false
        }
    }

    private func applyChipsToCells() {
        let calendar = Calendar.current
        var tasks: [Date: [TaskDeadlineChip]] = [:]
        for chip in deadlines {
            tasks[calendar.startOfDay(for: chip.day), default: []].append(chip)
        }
        var events: [Date: [CalendarEventChip]] = [:]
        for chip in self.events {
            events[calendar.startOfDay(for: chip.day), default: []].append(chip)
        }
        for cell in dayCells {
            cell.selectedTaskID = selectedTaskID
            // Set together, so a cell rebuilds its rows once rather than twice.
            cell.setRows(
                tasks: tasks[calendar.startOfDay(for: cell.day)] ?? [],
                events: events[calendar.startOfDay(for: cell.day)] ?? []
            )
        }
    }

    /// Selects the task only. Selection is exclusive, so also selecting the day
    /// would immediately displace the task the user just clicked.
    private func handleChipClick(_ chip: TaskDeadlineChip) {
        window?.makeFirstResponder(self)
        delegate?.weekCalendar(self, didSelectTaskID: chip.uuid)
    }

    /// An event is not a selectable thing: `PlannerSelection` holds a node or a
    /// day, and an event is neither. Clicking one therefore selects its day,
    /// which is also what clicking the cell around it does.
    private func handleEventClick(_ chip: CalendarEventChip) {
        handleDayClick(chip.day)
    }

    private func handleDayClick(_ day: Date) {
        window?.makeFirstResponder(self)
        delegate?.weekCalendar(self, didSelectDay: day)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        for subview in subviews.reversed() {
            if let hit = subview.hitTest(local) { return hit }
        }
        return self
    }
}

// MARK: - Test hooks

extension WeekCalendarView {
    var test_title: String {
        Calendar.current.weekRangeString(from: _visibleWeekStart, count: visibleWeekCount)
    }
    var test_dayCount: Int { dayCells.count }
    var test_days: [Date] { dayCells.map(\.day) }
    var test_weekCount: Int { visibleWeekCount }

    func test_setWeekCount(_ count: Int) {
        guard count != visibleWeekCount else { return }
        visibleWeekCount = count
        rebuildCells()
        applyVisibleWeeks()
    }

    func test_isWeekend(at index: Int) -> Bool { dayCells[index].isWeekend }
    func test_hasNoteMarker(at index: Int) -> Bool { dayCells[index].hasNote }
    func test_cellFrame(at index: Int) -> NSRect { dayCells[index].frame }
    func test_isToday(at index: Int) -> Bool { dayCells[index].isToday }
    func test_isSelected(at index: Int) -> Bool { dayCells[index].isSelected }
    func test_monthBadge(at index: Int) -> String? { dayCells[index].monthBadgeText }
    func test_monthHeaderText(at index: Int) -> String { dayCells[index].test_monthHeaderText }
    func test_monthHeaderFrame(at index: Int) -> NSRect? { dayCells[index].test_monthHeaderFrame }
    func test_noteDotFrame(at index: Int) -> NSRect { dayCells[index].test_noteDotFrame }
    func test_dayNumber(at index: Int) -> String { dayCells[index].test_dayNumberText }
    func test_dayNumberFrame(at index: Int) -> NSRect { dayCells[index].test_dayNumberFrame }

    func test_visibleChips(at index: Int) -> [TaskDeadlineChip] { dayCells[index].visibleChips }
    func test_visibleEvents(at index: Int) -> [CalendarEventChip] { dayCells[index].visibleEvents }
    /// Hidden rows of both kinds — there is one shared overflow line.
    func test_overflowCount(at index: Int) -> Int { dayCells[index].overflowCount }
    func test_overflowButtonFrame(at index: Int) -> NSRect? { dayCells[index].test_overflowButtonFrame }
    func test_todayMarkerRect(at index: Int) -> NSRect { dayCells[index].test_todayMarkerRect }
    func test_headerHeight(at index: Int) -> CGFloat { dayCells[index].test_headerHeight }
    func test_contentTop(at index: Int) -> CGFloat { dayCells[index].test_contentTop }
    func test_overflowBadge(at index: Int) -> String? { dayCells[index].test_overflowBadgeText }
    func test_visibleRowFrames(at index: Int) -> [NSRect] { dayCells[index].test_visibleRowFrames }
    func test_cellAccessibilityLabel(at index: Int) -> String? { dayCells[index].test_accessibilityLabel }
    /// Row order as laid out: task rows first, then event rows.
    func test_rowKinds(at index: Int) -> [String] { dayCells[index].test_rowKinds }
    func test_eventRowFrame(at index: Int, event eventIndex: Int) -> NSRect? {
        dayCells[index].test_eventRowFrame(at: eventIndex)
    }
    func test_chipFrame(at index: Int, chip chipIndex: Int) -> NSRect? {
        dayCells[index].test_chipFrame(at: chipIndex)
    }
    func test_clickEvent(at index: Int, event eventIndex: Int) {
        dayCells[index].test_clickEvent(at: eventIndex)
    }
    func test_eventAccessibility(at index: Int, event eventIndex: Int) -> (role: NSAccessibility.Role?, label: String?)? {
        dayCells[index].test_eventAccessibility(at: eventIndex)
    }
    func test_eventToolTip(at index: Int, event eventIndex: Int) -> String? {
        dayCells[index].test_eventToolTip(at: eventIndex)
    }
    func test_hitIsEventRow(_ view: NSView?, at index: Int, event eventIndex: Int) -> Bool {
        view === dayCells[index].test_eventView(at: eventIndex)
    }

    func test_chipAppearance(at index: Int, chip chipIndex: Int) -> (color: NSColor, isStruck: Bool, isSelected: Bool)? {
        dayCells[index].test_chipAppearance(at: chipIndex)
    }

    func test_chipAccessibilityLabel(at index: Int, chip chipIndex: Int) -> String? {
        dayCells[index].test_chipAccessibilityLabel(at: chipIndex)
    }

    func test_clickDay(at index: Int) { dayCells[index].test_clickDay() }
    func test_clickChip(at index: Int, chip chipIndex: Int) { dayCells[index].test_clickChip(at: chipIndex) }
    func test_clickOverflow(at index: Int) { dayCells[index].test_clickOverflow() }
    func test_clickPreviousWeek() { goToPreviousWeek() }
    func test_clickNextWeek() { goToNextWeek() }
    func test_clickToday() { revealToday() }

    func test_performDayAccessibilityPress(at index: Int) -> Bool {
        dayCells[index].test_performAccessibilityPress()
    }

    func test_performChipAccessibilityPress(at index: Int, chip chipIndex: Int) -> Bool {
        dayCells[index].test_performChipAccessibilityPress(at: chipIndex)
    }

    func test_hitIsDayCell(_ view: NSView?, at index: Int) -> Bool { view === dayCells[index] }

    func test_hitIsChip(_ view: NSView?, at index: Int, chip chipIndex: Int) -> Bool {
        view === dayCells[index].test_chipView(at: chipIndex)
    }

    func test_hitViewFromCalendarOnDayNumber(at index: Int) -> NSView? {
        let cell = dayCells[index]
        let local = NSPoint(x: cell.test_dayNumberFrame.midX, y: cell.test_dayNumberFrame.midY)
        return test_hitTestInSelfCoordinates(convert(local, from: cell))
    }

    func test_hitViewFromCalendarOnChip(at index: Int, chip chipIndex: Int) -> NSView? {
        dayCells[index].layout()
        guard let chipView = dayCells[index].test_chipView(at: chipIndex) else { return nil }
        let local = NSPoint(x: chipView.bounds.midX, y: chipView.bounds.midY)
        return test_hitTestInSelfCoordinates(convert(local, from: chipView))
    }

    private func test_hitTestInSelfCoordinates(_ pointInSelf: NSPoint) -> NSView? {
        layoutSubtreeIfNeeded()
        return hitTest(convert(pointInSelf, to: superview))
    }

    func test_mouseDownFromCalendarOnDayNumber(at index: Int) {
        let cell = dayCells[index]
        let local = NSPoint(x: cell.test_dayNumberFrame.midX, y: cell.test_dayNumberFrame.midY)
        let inSelf = convert(local, from: cell)
        test_hitTestInSelfCoordinates(inSelf)?.mouseDown(with: Self.testMouseEvent(at: convert(inSelf, to: nil)))
    }

    func test_mouseDownFromCalendarOnChip(at index: Int, chip chipIndex: Int) {
        dayCells[index].layout()
        guard let chipView = dayCells[index].test_chipView(at: chipIndex) else { return }
        let local = NSPoint(x: chipView.bounds.midX, y: chipView.bounds.midY)
        let inSelf = convert(local, from: chipView)
        test_hitTestInSelfCoordinates(inSelf)?.mouseDown(with: Self.testMouseEvent(at: convert(inSelf, to: nil)))
    }

    private static func testMouseEvent(at location: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }
}

// MARK: - Grid

private final class GridContainer: NSView {
    var weekCount = 4

    override var isFlipped: Bool { true }

    /// Hairline rules under the cells; a cell only paints when it is today,
    /// selected, or a weekend.
    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }

        let rows = WeekCalendarView.rowFrames(in: bounds.height)
        let columns = WeekCalendarView.columnFrames(in: bounds.width, count: weekCount)

        NSColor.separatorColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1

        for row in rows {
            let y = row.minY.rounded() + 0.5
            path.move(to: NSPoint(x: 0, y: y))
            path.line(to: NSPoint(x: bounds.width, y: y))
        }
        let bottom = bounds.height.rounded() - 0.5
        path.move(to: NSPoint(x: 0, y: bottom))
        path.line(to: NSPoint(x: bounds.width, y: bottom))

        for column in columns.dropFirst() {
            let x = column.minX.rounded() + 0.5
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x, y: bounds.height))
        }
        path.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        for subview in subviews.reversed() {
            if let hit = subview.hitTest(local) { return hit }
        }
        return self
    }
}

/// One line inside a day cell. Tasks and events share the stack — and the
/// single `+K more` — but not their appearance.
fileprivate enum CalendarRowItem: Hashable {
    case task(TaskDeadlineChip)
    case event(CalendarEventChip)

    var height: CGFloat {
        switch self {
        case .task: return DayCellView.chipHeight
        case .event: return DayCellView.eventHeight
        }
    }
}

private final class DayCellView: NSView {
    var onChipClick: ((TaskDeadlineChip) -> Void)?
    var onDayClick: ((Date) -> Void)?
    var onEventClick: ((CalendarEventChip) -> Void)?

    private(set) var day: Date = Date()
    private(set) var isToday = false
    private(set) var isWeekend = false
    /// Non-nil on the first day of a month, e.g. "Aug".
    private(set) var monthBadgeText: String?
    private var dayDescription = ""

    var isSelected = false {
        didSet { needsDisplay = true }
    }

    var hasNote = false {
        didSet {
            guard hasNote != oldValue else { return }
            needsDisplay = true
        }
    }

    var selectedTaskID: UUID? {
        didSet { applyChipSelection() }
    }

    private(set) var chips: [TaskDeadlineChip] = []
    private(set) var events: [CalendarEventChip] = []

    /// Tasks first, then events. The order is a priority statement: this is a
    /// task planner, and a meeting-heavy day must not push a deadline into the
    /// overflow. They share one `+K more` so the capacity maths stays in one
    /// place rather than being duplicated per kind.
    private var rows: [CalendarRowItem] {
        chips.map(CalendarRowItem.task) + events.map(CalendarRowItem.event)
    }

    func setRows(tasks: [TaskDeadlineChip], events: [CalendarEventChip]) {
        guard tasks != chips || events != self.events else { return }
        chips = tasks
        self.events = events
        rebuildChipViews()
    }

    private let dayNumberLabel = NSTextField(labelWithString: "")
    private let monthLabel = NSTextField(labelWithString: "")
    private var chipViews: [DeadlineChipView] = []
    private var eventViews: [EventRowView] = []
    private let overflowButton = NSButton(title: "", target: nil, action: nil)
    /// Stands in for `+K more` in a cell too short to give it a line of its
    /// own — otherwise a short weekend cell shows one of three items and no
    /// hint that the others exist.
    private let overflowBadgeLabel = NSTextField(labelWithString: "")

    fileprivate static let chipHeight: CGFloat = 18
    /// Shorter than a task chip: an event is context, not a commitment.
    fileprivate static let eventHeight: CGFloat = 16
    fileprivate static let rowSpacing: CGFloat = 2
    /// One set of metrics for every day: weekend cells are full size now, so
    /// the shrunken weekend header and padding went with the half-height rows.
    private static let headerHeight: CGFloat = 18
    private static let contentPadding: CGFloat = 4
    /// Without this the day number's label ends exactly where the first row
    /// begins, so the two touch.
    private static let rowTopGap: CGFloat = 2
    private static let overflowHeight: CGFloat = 14
    /// Read by `WeekCalendarView.chipTextHorizontalInset`.
    fileprivate static let inset: CGFloat = 5
    /// Vertical centre of the day number within the cell; the month header
    /// lines up with this.
    static let dayNumberCenterY: CGFloat = 10

    private var headerHeight: CGFloat { Self.headerHeight }
    private var contentPadding: CGFloat { Self.contentPadding }
    private var rowTopGap: CGFloat { Self.rowTopGap }

    /// Where rows begin, below the header band and its gap.
    private var contentTop: CGFloat { headerHeight + rowTopGap }

    /// The today marker, fitted to the **header band** rather than to the day
    /// number's label box.
    ///
    /// A circle enclosing two digits needs roughly 21pt, which neither the 18pt
    /// weekday band nor the 15pt weekend band has — sizing from the label made
    /// it overhang the cell top by 1pt and the first row by 3pt. It only became
    /// visible when cells started clipping; before that it drew into the
    /// previous day. Single-digit days still come out as exact circles.
    var todayMarkerRect: NSRect {
        let height = max(0, headerHeight - 4)
        let width = max(height, dayNumberLabel.frame.width + 6)
        return NSRect(
            x: dayNumberLabel.frame.midX - width / 2,
            y: dayNumberInkCenterY - height / 2,
            width: width,
            height: height
        )
    }

    /// The optical centre of the digits, not the label's `midY`: the frame
    /// includes descender space digits never use, so centring the marker on
    /// the frame left the number riding ~0.75pt high inside the capsule.
    /// Digits span exactly the cap-height band above the baseline.
    private var dayNumberInkCenterY: CGFloat {
        guard let font = dayNumberLabel.font else { return dayNumberLabel.frame.midY }
        let baseline = dayNumberLabel.frame.minY + dayNumberLabel.firstBaselineOffsetFromTop
        return baseline - font.capHeight / 2
    }

    private var dayNumberCenterY: CGFloat { Self.dayNumberCenterY }
    fileprivate static let noteDotSize: CGFloat = 5
    /// A row shorter than this is not worth drawing; hide it instead.
    private static let minimumRowHeight: CGFloat = 10

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(day: Date, isWeekend: Bool, selectedDay: Date?) {
        let calendar = Calendar.current
        self.day = calendar.startOfDay(for: day)
        self.isWeekend = isWeekend
        isToday = calendar.isDateInToday(day)
        isSelected = selectedDay.map { calendar.isDate(day, inSameDayAs: $0) } ?? false

        let dayOfMonth = calendar.component(.day, from: day)
        dayNumberLabel.stringValue = String(dayOfMonth)
        // Weekend cells draw exactly like weekdays; the gray wash in `draw` is
        // what tells them apart.
        dayNumberLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        dayNumberLabel.textColor = isToday ? .alternateSelectedControlTextColor : .labelColor

        monthBadgeText = dayOfMonth == 1 ? calendar.monthName(for: day) : nil
        monthLabel.stringValue = monthBadgeText?.uppercased() ?? ""
        monthLabel.isHidden = monthBadgeText == nil

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        dayDescription = formatter.string(from: day)
        updateAccessibilityLabel()
        needsLayout = true
        needsDisplay = true
    }

    /// Fills the cell top-down and stops when the next row would not fit,
    /// reserving space for `+K more` when anything is left over.
    ///
    /// Greedy rather than a slot count because task and event rows are
    /// different heights; a uniform divisor would either waste a row or
    /// overflow the cell.
    var visibleRows: [CalendarRowItem] {
        let rows = rows
        guard !rows.isEmpty else { return [] }
        let capped = Array(rows.prefix(WeekCalendarView.maxVisibleChips))
        // Before first layout there is no height to measure against; showing
        // one row beats showing an empty cell that later fills in.
        guard bounds.height > 0 else { return Array(capped.prefix(1)) }

        let available = bounds.height - contentTop - contentPadding
        var used: CGFloat = 0
        var taken: [CalendarRowItem] = []
        for row in capped {
            let next = used + (taken.isEmpty ? 0 : Self.rowSpacing) + row.height
            if next > available { break }
            used = next
            taken.append(row)
        }

        if taken.count == rows.count { return taken }
        // Something is hidden, so `+K more` needs a line of its own.
        while let last = taken.last,
              used + Self.rowSpacing + Self.overflowHeight > available {
            taken.removeLast()
            used -= last.height + (taken.isEmpty ? 0 : Self.rowSpacing)
        }
        // A half-height weekend row may not fit even one row plus the overflow
        // line. Showing the row matters more than showing the count.
        return taken.isEmpty ? Array(capped.prefix(1)) : taken
    }

    var visibleChips: [TaskDeadlineChip] {
        visibleRows.compactMap { if case let .task(chip) = $0 { return chip } else { return nil } }
    }

    var visibleEvents: [CalendarEventChip] {
        visibleRows.compactMap { if case let .event(chip) = $0 { return chip } else { return nil } }
    }

    /// Hidden rows of **both** kinds — there is only one overflow line.
    var overflowCount: Int { max(0, rows.count - visibleRows.count) }

    override func draw(_ dirtyRect: NSRect) {
        if isWeekend {
            NSColor.quaternaryLabelColor.withAlphaComponent(0.05).setFill()
            bounds.fill()
        }

        if isSelected {
            let card = bounds.insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: card, xRadius: 5, yRadius: 5)
            NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }

        if isToday {
            let rect = todayMarkerRect
            NSColor.controlAccentColor.setFill()
            NSBezierPath(
                roundedRect: rect,
                xRadius: rect.height / 2,
                yRadius: rect.height / 2
            ).fill()
        }

        // A day note is otherwise invisible until the day is selected. It sits
        // at the trailing edge, so every note marker in a week lands at the same
        // x and the column can be scanned in one pass.
        if hasNote {
            let dot = NSRect(
                x: bounds.width - Self.inset - Self.noteDotSize,
                y: dayNumberLabel.frame.midY - Self.noteDotSize / 2,
                width: Self.noteDotSize,
                height: Self.noteDotSize
            )
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
    }

    override func layout() {
        super.layout()
        let inset = Self.inset
        let width = max(0, bounds.width - inset * 2)

        dayNumberLabel.sizeToFit()
        monthLabel.sizeToFit()

        dayNumberLabel.frame = NSRect(
            x: inset,
            y: dayNumberCenterY - 8,
            width: min(dayNumberLabel.frame.width, width),
            height: 16
        )

        // Centred in the cell, between the day number and the note dot. The
        // month only ever appears beside "1", so the left zone stays narrow.
        if !monthLabel.isHidden {
            let monthWidth = min(monthLabel.frame.width, width)
            monthLabel.frame = NSRect(
                x: (bounds.width - monthWidth) / 2,
                y: dayNumberCenterY - 6,
                width: monthWidth,
                height: 12
            )
        }

        syncChipViews()

        var y = contentTop
        var tasks = chipViews.makeIterator()
        var events = eventViews.makeIterator()
        // Walk the merged list so the two view arrays interleave in row order
        // rather than each stacking from the top.
        for row in visibleRows {
            let view: NSView?
            switch row {
            case .task: view = tasks.next()
            case .event: view = events.next()
            }
            // Nothing is ever positioned past the cell. `visibleRows` can force
            // a row into a cell too short for it, and an escaped row draws over
            // the following day rather than over nothing.
            let remaining = bounds.height - y
            guard remaining >= Self.minimumRowHeight else {
                view?.isHidden = true
                continue
            }
            view?.isHidden = false
            view?.frame = NSRect(x: inset, y: y, width: width, height: min(row.height, remaining))
            y += min(row.height, remaining) + Self.rowSpacing
        }

        layoutOverflow(afterY: y, inset: inset, width: width)
    }

    private func configure() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        // Belt and braces: even if the arithmetic above is ever wrong, a row
        // must not draw over the following day.
        clipsToBounds = true

        for label in [dayNumberLabel, monthLabel] {
            label.isBezeled = false
            label.drawsBackground = false
            label.refusesFirstResponder = true
            label.setAccessibilityElement(false)
            addSubview(label)
        }
        // Small caps, secondary, no fill: a month boundary is structure, not a
        // task. The accent-tinted pill this replaced borrowed the chip's whole
        // visual vocabulary and read as content.
        monthLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        monthLabel.textColor = .secondaryLabelColor
        monthLabel.alignment = .center
        monthLabel.isHidden = true

        overflowButton.isBordered = false
        overflowButton.font = .systemFont(ofSize: 10)
        overflowButton.alignment = .left
        overflowButton.contentTintColor = .secondaryLabelColor
        overflowButton.target = self
        overflowButton.action = #selector(overflowClicked)
        overflowButton.isHidden = true
        addSubview(overflowButton)

        overflowBadgeLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        overflowBadgeLabel.textColor = .tertiaryLabelColor
        overflowBadgeLabel.isBezeled = false
        overflowBadgeLabel.drawsBackground = false
        overflowBadgeLabel.refusesFirstResponder = true
        overflowBadgeLabel.setAccessibilityElement(false)
        overflowBadgeLabel.isHidden = true
        addSubview(overflowBadgeLabel)
    }

    private func rebuildChipViews() {
        needsLayout = true
        if !bounds.isEmpty {
            layout()
        } else {
            syncChipViews()
        }
    }

    private func syncChipViews() {
        let wantedChips = visibleChips
        let wantedEvents = visibleEvents
        // Identity decides whether views are reused; content always flows in.
        // Matching on UUID/id alone here left a renamed or completed task's
        // chip drawing its old title and state until the chip *set* changed.
        let sameChipIdentity = wantedChips.count == chipViews.count
            && zip(wantedChips, chipViews).allSatisfy { $0.uuid == $1.chip.uuid }
        let sameEventIdentity = wantedEvents.count == eventViews.count
            && zip(wantedEvents, eventViews).allSatisfy { $0.id == $1.chip.id }

        if sameChipIdentity {
            for (chip, view) in zip(wantedChips, chipViews) {
                view.chip = chip
            }
        } else {
            chipViews.forEach { $0.removeFromSuperview() }
            chipViews = wantedChips.map { chip in
                let view = DeadlineChipView(chip: chip)
                view.onClick = { [weak self, weak view] in
                    guard let view else { return }
                    self?.onChipClick?(view.chip)
                }
                addSubview(view)
                return view
            }
        }
        if sameEventIdentity {
            for (chip, view) in zip(wantedEvents, eventViews) {
                view.chip = chip
            }
        } else {
            eventViews.forEach { $0.removeFromSuperview() }
            eventViews = wantedEvents.map { chip in
                let view = EventRowView(chip: chip)
                view.onClick = { [weak self, weak view] in
                    guard let view else { return }
                    self?.onEventClick?(view.chip)
                }
                addSubview(view)
                return view
            }
        }
        if sameChipIdentity, sameEventIdentity {
            updateOverflowButton()
            return
        }
        applyChipSelection()
        updateOverflowButton()
    }

    private func updateOverflowButton() {
        let extra = overflowCount
        if extra > 0 {
            overflowButton.title = "+\(extra) more"
            overflowBadgeLabel.stringValue = "+\(extra)"
        }
        // Provisional: `layout` decides which of the two forms actually fits.
        // Needed because `rebuildChipViews` can run before there are bounds.
        overflowButton.isHidden = extra <= 0
        overflowBadgeLabel.isHidden = true
        updateAccessibilityLabel()
    }

    /// Gives the count a full line when there is room, and a badge beside the
    /// day number when there is not.
    private func layoutOverflow(afterY y: CGFloat, inset: CGFloat, width: CGFloat) {
        guard overflowCount > 0 else {
            overflowButton.isHidden = true
            overflowBadgeLabel.isHidden = true
            return
        }

        if y + Self.overflowHeight <= bounds.height {
            overflowButton.isHidden = false
            overflowBadgeLabel.isHidden = true
            overflowButton.frame = NSRect(x: inset, y: y, width: width, height: Self.overflowHeight)
            return
        }

        overflowButton.isHidden = true
        overflowBadgeLabel.sizeToFit()
        let badgeWidth = overflowBadgeLabel.frame.width
        let x = dayNumberLabel.frame.maxX + 4
        // The month label is centred and the note dot is trailing, so the badge
        // gets whatever is left of the leading zone and hides rather than
        // colliding with either.
        var limit = bounds.width - inset
        if hasNote { limit -= Self.noteDotSize + 4 }
        if !monthLabel.isHidden { limit = min(limit, monthLabel.frame.minX - 4) }

        guard x + badgeWidth <= limit else {
            overflowBadgeLabel.isHidden = true
            return
        }
        overflowBadgeLabel.isHidden = false
        overflowBadgeLabel.frame = NSRect(
            x: x,
            y: dayNumberLabel.frame.midY - 6,
            width: badgeWidth,
            height: 12
        )
    }

    /// VoiceOver has no tooltip and, when the count is a badge, no button
    /// either — so the hidden items have to be named on the cell itself.
    private func updateAccessibilityLabel() {
        let extra = overflowCount
        setAccessibilityLabel(extra > 0 ? "\(dayDescription), \(extra) more" : dayDescription)
    }

    private func applyChipSelection() {
        for view in chipViews {
            view.isSelected = view.chip.uuid == selectedTaskID
        }
    }

    override func mouseDown(with event: NSEvent) {
        onDayClick?(day)
    }

    /// Incoming point is in the superview. Skip the labels so a click on the day
    /// number still reaches the cell.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if !overflowButton.isHidden, let hit = overflowButton.hitTest(local) { return hit }
        for chipView in chipViews.reversed() {
            if let hit = chipView.hitTest(local) { return hit }
        }
        for eventView in eventViews.reversed() {
            if let hit = eventView.hitTest(local) { return hit }
        }
        return self
    }

    override func accessibilityPerformPress() -> Bool {
        onDayClick?(day)
        return true
    }

    @objc private func overflowClicked() {
        onDayClick?(day)
    }

    // MARK: - Test hooks

    var test_dayNumberFrame: NSRect { dayNumberLabel.frame }
    var test_monthHeaderText: String { monthLabel.stringValue }
    var test_monthHeaderFrame: NSRect? { monthLabel.isHidden ? nil : monthLabel.frame }
    /// Mirrors the dot geometry in `draw(_:)`.
    var test_noteDotFrame: NSRect {
        NSRect(
            x: bounds.width - Self.inset - Self.noteDotSize,
            y: dayNumberLabel.frame.midY - Self.noteDotSize / 2,
            width: Self.noteDotSize,
            height: Self.noteDotSize
        )
    }
    var test_dayNumberText: String { dayNumberLabel.stringValue }

    func test_clickDay() { onDayClick?(day) }

    func test_clickChip(at index: Int) {
        guard chips.indices.contains(index) else { return }
        onChipClick?(chips[index])
    }

    func test_clickOverflow() { overflowClicked() }

    var test_overflowButtonFrame: NSRect? { overflowButton.isHidden ? nil : overflowButton.frame }
    /// The geometry the today fill uses, computed whether or not this is today.
    var test_todayMarkerRect: NSRect { todayMarkerRect }
    var test_headerHeight: CGFloat { headerHeight }
    var test_contentTop: CGFloat { contentTop }
    var test_overflowBadgeText: String? {
        overflowBadgeLabel.isHidden ? nil : overflowBadgeLabel.stringValue
    }
    var test_visibleRowFrames: [NSRect] {
        (chipViews + eventViews.map { $0 as NSView })
            .filter { !$0.isHidden }
            .map(\.frame)
    }
    var test_accessibilityLabel: String? { accessibilityLabel() }

    var test_rowKinds: [String] {
        visibleRows.map { if case .task = $0 { return "task" } else { return "event" } }
    }

    func test_eventView(at index: Int) -> NSView? {
        eventViews.indices.contains(index) ? eventViews[index] : nil
    }

    func test_eventRowFrame(at index: Int) -> NSRect? {
        eventViews.indices.contains(index) ? eventViews[index].frame : nil
    }

    func test_chipFrame(at index: Int) -> NSRect? {
        chipViews.indices.contains(index) ? chipViews[index].frame : nil
    }

    func test_clickEvent(at index: Int) {
        guard events.indices.contains(index) else { return }
        onEventClick?(events[index])
    }

    func test_eventAccessibility(at index: Int) -> (role: NSAccessibility.Role?, label: String?)? {
        guard eventViews.indices.contains(index) else { return nil }
        return (eventViews[index].accessibilityRole(), eventViews[index].accessibilityLabel())
    }

    func test_eventToolTip(at index: Int) -> String? {
        eventViews.indices.contains(index) ? eventViews[index].toolTip : nil
    }

    func test_chipAppearance(at index: Int) -> (color: NSColor, isStruck: Bool, isSelected: Bool)? {
        guard chipViews.indices.contains(index) else { return nil }
        return chipViews[index].test_appearance
    }

    func test_chipView(at index: Int) -> NSView? {
        guard chipViews.indices.contains(index) else { return nil }
        return chipViews[index]
    }

    func test_performAccessibilityPress() -> Bool { accessibilityPerformPress() }

    func test_performChipAccessibilityPress(at index: Int) -> Bool {
        guard chipViews.indices.contains(index) else { return false }
        return chipViews[index].accessibilityPerformPress()
    }

    func test_chipAccessibilityLabel(at index: Int) -> String? {
        guard chipViews.indices.contains(index) else { return nil }
        return chipViews[index].accessibilityLabel()
    }
}

private final class DeadlineChipView: NSView {
    /// Title metrics live here so the column-width calibration can measure with
    /// exactly what `draw` uses.
    static let titleFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let textLeading: CGFloat = 9
    static let textTrailing: CGFloat = 2

    var chip: TaskDeadlineChip {
        didSet {
            guard chip != oldValue else { return }
            applyChipContent()
            needsDisplay = true
        }
    }
    var onClick: (() -> Void)?

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            needsDisplay = true
        }
    }

    private var isStruck: Bool { chip.isCompleted }

    /// A completed task is never overdue; the flag outranks the date.
    private var isOverdue: Bool {
        !chip.isCompleted && Calendar.current.isOverdue(chip.day)
    }

    private var titleColor: NSColor {
        if chip.isCompleted { return .tertiaryLabelColor }
        if isSelected { return .controlAccentColor }
        if isOverdue { return .systemRed }
        return .labelColor
    }

    private var barColor: NSColor {
        if chip.isCompleted { return .tertiaryLabelColor }
        if isOverdue { return .systemRed.withAlphaComponent(isSelected ? 1 : 0.85) }
        return .controlAccentColor.withAlphaComponent(isSelected ? 1 : 0.75)
    }

    var test_appearance: (color: NSColor, isStruck: Bool, isSelected: Bool) {
        (titleColor, isStruck, isSelected)
    }

    override var isFlipped: Bool { true }

    init(chip: TaskDeadlineChip) {
        self.chip = chip
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        applyChipContent()
    }

    private func applyChipContent() {
        toolTip = chip.title
        setAccessibilityLabel(chip.isCompleted ? "\(chip.title), Completed" : chip.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }

        let bar = NSRect(x: 2, y: 3, width: 3, height: max(0, bounds.height - 6))
        barColor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()

        var attributes: [NSAttributedString.Key: Any] = [
            .font: Self.titleFont,
            .foregroundColor: titleColor,
        ]
        if isStruck {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        attributes[.paragraphStyle] = paragraph

        let textRect = NSRect(
            x: Self.textLeading,
            y: 2,
            width: max(0, bounds.width - Self.textLeading - Self.textTrailing),
            height: max(0, bounds.height - 4)
        )
        NSAttributedString(string: chip.title, attributes: attributes).draw(
            with: textRect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        )
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// An external calendar event.
///
/// Deliberately quieter than `DeadlineChipView`, and different in kind rather
/// than in degree: a dot instead of a bar, secondary instead of primary text,
/// regular instead of medium weight, and no selected state at all. A filled
/// tinted capsule was tried first and rejected — it outweighed the task chips
/// and made borrowed context the loudest thing in the cell.
private final class EventRowView: NSView {
    static let titleFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    static let dotDiameter: CGFloat = 4
    /// Matches `DeadlineChipView.textLeading` so event and task titles line up
    /// in one column despite the different leading marks.
    static let textLeading: CGFloat = 9
    static let textTrailing: CGFloat = 2

    var chip: CalendarEventChip {
        didSet {
            guard chip != oldValue else { return }
            applyChipContent()
            needsDisplay = true
        }
    }
    var onClick: (() -> Void)?

    override var isFlipped: Bool { true }

    init(chip: CalendarEventChip) {
        self.chip = chip
        super.init(frame: .zero)
        setAccessibilityElement(true)
        // Static text, not a button: clicking selects the day, which is what
        // the cell already does, so announcing it as a control would promise
        // an action it does not have.
        setAccessibilityRole(.staticText)
        applyChipContent()
    }

    private func applyChipContent() {
        toolTip = EventLabels.tooltip(for: chip)
        setAccessibilityLabel(EventLabels.accessibilityLabel(for: chip))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let dot = NSRect(
            x: 2,
            y: (bounds.height - Self.dotDiameter) / 2,
            width: Self.dotDiameter,
            height: Self.dotDiameter
        )
        NSColor.secondaryLabelColor.setFill()
        NSBezierPath(ovalIn: dot).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.titleFont,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]

        let textRect = NSRect(
            x: Self.textLeading,
            y: 1,
            width: max(0, bounds.width - Self.textLeading - Self.textTrailing),
            height: max(0, bounds.height - 2)
        )
        NSAttributedString(string: EventLabels.title(for: chip), attributes: attributes)
            .draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
