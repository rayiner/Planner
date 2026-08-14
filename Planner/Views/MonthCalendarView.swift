import AppKit

protocol MonthCalendarViewDelegate: AnyObject {
    func monthCalendar(_ view: MonthCalendarView, didSelectTaskID uuid: UUID)
    func monthCalendar(_ view: MonthCalendarView, didSelectDay date: Date)
    func monthCalendar(_ view: MonthCalendarView, didChangeVisibleMonth date: Date)
}

struct TaskDeadlineChip: Hashable {
    var uuid: UUID
    var title: String
    var day: Date
    var isCompleted: Bool
}

final class MonthCalendarView: NSView {
    fileprivate static let maxVisibleChips = 3

    weak var delegate: MonthCalendarViewDelegate?

    /// Displayed month. Setter must not call the delegate.
    var visibleMonth: Date {
        get { _visibleMonth }
        set {
            let normalized = Calendar.current.startOfMonth(for: newValue)
            guard _visibleMonth != normalized else { return }
            _visibleMonth = normalized
            applyVisibleMonth()
        }
    }

    var deadlines: [TaskDeadlineChip] = [] {
        didSet { applyChipsToCells() }
    }

    var selectedTaskID: UUID?

    var selectedDay: Date? {
        get { _selectedDay }
        set {
            let normalized = newValue.map { Calendar.current.startOfDay(for: $0) }
            guard _selectedDay != normalized else { return }
            _selectedDay = normalized
            applySelectionHighlights()
        }
    }

    private var _visibleMonth: Date
    private var _selectedDay: Date?

    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let todayButton = NSButton(title: "Today", target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: "")
    private let headerView = NSView()
    private let gridContainer = GridContainer()
    private var weekdayLabels: [NSTextField] = []
    private var dayCells: [DayCellView] = []

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        _visibleMonth = Calendar.current.startOfMonth(for: Date())
        super.init(frame: frameRect)
        configure()
        applyVisibleMonth()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Calls `didChangeVisibleMonth` with `Date()`; does not assign `visibleMonth`.
    func revealToday() {
        delegate?.monthCalendar(self, didChangeVisibleMonth: Date())
    }

    override func layout() {
        super.layout()
        if gridContainer.bounds.width <= 0 || gridContainer.bounds.height <= 0, bounds.width > 0 {
            let headerHeight = max(headerView.frame.height, 28)
            gridContainer.frame = NSRect(
                x: 8,
                y: 8 + headerHeight + 6,
                width: max(0, bounds.width - 16),
                height: max(0, bounds.height - 16 - headerHeight - 6)
            )
        }
        layoutGrid()
    }

    private func configure() {
        configureHeader()
        configureGrid()
    }

    private func configureHeader() {
        previousButton.bezelStyle = .flexiblePush
        previousButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous month")
        previousButton.imagePosition = previousButton.image == nil ? .noImage : .imageOnly
        if previousButton.image == nil { previousButton.title = "<" }
        previousButton.target = self
        previousButton.action = #selector(goToPreviousMonth)
        previousButton.setAccessibilityLabel("Previous month")

        nextButton.bezelStyle = .flexiblePush
        nextButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next month")
        nextButton.imagePosition = nextButton.image == nil ? .noImage : .imageOnly
        if nextButton.image == nil { nextButton.title = ">" }
        nextButton.target = self
        nextButton.action = #selector(goToNextMonth)
        nextButton.setAccessibilityLabel("Next month")

        todayButton.bezelStyle = .flexiblePush
        todayButton.target = self
        todayButton.action = #selector(todayClicked)
        todayButton.setAccessibilityLabel("Today")

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let navigation = NSStackView(views: [previousButton, titleLabel, nextButton])
        navigation.orientation = .horizontal
        navigation.alignment = .centerY
        navigation.spacing = 8

        let header = NSStackView(views: [navigation, todayButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .equalSpacing
        header.translatesAutoresizingMaskIntoConstraints = false
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(header)
        addSubview(headerView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: headerView.topAnchor),
            header.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            header.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),

            headerView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            headerView.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func configureGrid() {
        gridContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gridContainer)

        NSLayoutConstraint.activate([
            gridContainer.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 6),
            gridContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            gridContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            gridContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])

        weekdayLabels = (0..<7).map { _ in
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.refusesFirstResponder = true
            gridContainer.addSubview(label)
            return label
        }

        dayCells = (0..<42).map { _ in
            let cell = DayCellView()
            cell.onChipClick = { [weak self] chip in
                self?.handleChipClick(chip)
            }
            cell.onDayClick = { [weak self] day in
                self?.handleDayClick(day)
            }
            gridContainer.addSubview(cell)
            return cell
        }
    }

    private func applyVisibleMonth() {
        titleLabel.stringValue = Calendar.current.monthYearString(for: _visibleMonth)
        applyWeekdayLabels()
        let days = Calendar.current.daysInMonthGrid(for: _visibleMonth)
        for (index, cell) in dayCells.enumerated() {
            cell.configure(day: days[index], visibleMonth: _visibleMonth, selectedDay: _selectedDay)
        }
        applyChipsToCells()
    }

    private func applyWeekdayLabels() {
        let calendar = Calendar.current
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        let rotated = Array(symbols[first...]) + Array(symbols[..<first])
        for (index, label) in weekdayLabels.enumerated() {
            label.stringValue = rotated[index]
        }
    }

    private func applySelectionHighlights() {
        for cell in dayCells {
            cell.isSelected = _selectedDay.map { Calendar.current.isDate(cell.day, inSameDayAs: $0) } ?? false
        }
    }

    private func applyChipsToCells() {
        let calendar = Calendar.current
        var grouped: [Date: [TaskDeadlineChip]] = [:]
        for chip in deadlines {
            let day = calendar.startOfDay(for: chip.day)
            grouped[day, default: []].append(chip)
        }
        for cell in dayCells {
            cell.chips = grouped[calendar.startOfDay(for: cell.day)] ?? []
        }
    }

    private func layoutGrid() {
        let bounds = gridContainer.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        let weekdayHeight: CGFloat = 20
        let columnWidth = bounds.width / 7
        let rowHeight = max(0, (bounds.height - weekdayHeight) / 6)

        for (index, label) in weekdayLabels.enumerated() {
            label.frame = NSRect(
                x: CGFloat(index) * columnWidth,
                y: 0,
                width: columnWidth,
                height: weekdayHeight
            )
        }

        for (index, cell) in dayCells.enumerated() {
            let column = index % 7
            let row = index / 7
            cell.frame = NSRect(
                x: CGFloat(column) * columnWidth,
                y: weekdayHeight + CGFloat(row) * rowHeight,
                width: columnWidth,
                height: rowHeight
            )
        }
    }

    private func handleChipClick(_ chip: TaskDeadlineChip) {
        delegate?.monthCalendar(self, didSelectTaskID: chip.uuid)
        delegate?.monthCalendar(self, didSelectDay: chip.day)
    }

    private func handleDayClick(_ day: Date) {
        let calendar = Calendar.current
        delegate?.monthCalendar(self, didSelectDay: day)
        if !calendar.isDate(day, equalTo: _visibleMonth, toGranularity: .month) {
            delegate?.monthCalendar(self, didChangeVisibleMonth: calendar.startOfMonth(for: day))
        }
    }

    // Gestures leave visibleMonth alone so SelectionModel stays the only source of truth.
    @objc private func goToPreviousMonth() {
        let previous = Calendar.current.date(byAdding: .month, value: -1, to: _visibleMonth)!
        delegate?.monthCalendar(self, didChangeVisibleMonth: previous)
    }

    @objc private func goToNextMonth() {
        let next = Calendar.current.date(byAdding: .month, value: 1, to: _visibleMonth)!
        delegate?.monthCalendar(self, didChangeVisibleMonth: next)
    }

    @objc private func todayClicked() {
        revealToday()
    }
}

extension MonthCalendarView {
    var test_title: String { titleLabel.stringValue }
    var test_weekdaySymbols: [String] { weekdayLabels.map(\.stringValue) }
    var test_days: [Date] { dayCells.map(\.day) }
    var test_dayCount: Int { dayCells.count }

    func test_isSpillover(at index: Int) -> Bool {
        !dayCells[index].isInVisibleMonth
    }

    func test_visibleChips(at index: Int) -> [TaskDeadlineChip] {
        Array(dayCells[index].chips.prefix(Self.maxVisibleChips))
    }

    func test_overflowCount(at index: Int) -> Int {
        max(0, dayCells[index].chips.count - Self.maxVisibleChips)
    }

    func test_chipAppearance(at index: Int, chip chipIndex: Int) -> (color: NSColor, isStruck: Bool)? {
        dayCells[index].test_chipAppearance(at: chipIndex)
    }

    func test_isToday(at index: Int) -> Bool {
        dayCells[index].isToday
    }

    func test_isSelected(at index: Int) -> Bool {
        dayCells[index].isSelected
    }

    func test_clickPreviousMonth() { goToPreviousMonth() }
    func test_clickNextMonth() { goToNextMonth() }
    func test_clickToday() { revealToday() }

    func test_clickDay(at index: Int) {
        dayCells[index].test_clickDay()
    }

    func test_clickChip(at index: Int, chip chipIndex: Int) {
        dayCells[index].test_clickChip(at: chipIndex)
    }

    func test_clickOverflow(at index: Int) {
        dayCells[index].test_clickOverflow()
    }

    func test_dayNumberHitView(at index: Int) -> NSView? {
        let cell = dayCells[index]
        return cell.test_hitView(at: NSPoint(x: cell.test_dayNumberFrame.midX, y: cell.test_dayNumberFrame.midY))
    }

    func test_mouseDownOnDayNumber(at index: Int) {
        let cell = dayCells[index]
        cell.test_mouseDown(at: NSPoint(x: cell.test_dayNumberFrame.midX, y: cell.test_dayNumberFrame.midY))
    }

    func test_mouseDownOnChip(at index: Int, chip chipIndex: Int) {
        dayCells[index].test_mouseDownOnChip(at: chipIndex)
    }

    func test_performDayAccessibilityPress(at index: Int) -> Bool {
        dayCells[index].test_performAccessibilityPress()
    }

    func test_performChipAccessibilityPress(at index: Int, chip chipIndex: Int) -> Bool {
        dayCells[index].test_performChipAccessibilityPress(at: chipIndex)
    }

    func test_chipAccessibilityLabel(at index: Int, chip chipIndex: Int) -> String? {
        dayCells[index].test_chipAccessibilityLabel(at: chipIndex)
    }
}

private final class GridContainer: NSView {
    override var isFlipped: Bool { true }
}

private final class DayCellView: NSView {
    var onChipClick: ((TaskDeadlineChip) -> Void)?
    var onDayClick: ((Date) -> Void)?

    private(set) var day: Date = Date()
    private(set) var isInVisibleMonth = true
    private(set) var isToday = false

    var isSelected = false {
        didSet { needsDisplay = true }
    }

    var chips: [TaskDeadlineChip] = [] {
        didSet { rebuildChipViews() }
    }

    private let dayNumberLabel = NSTextField(labelWithString: "")
    private var chipViews: [DeadlineChipView] = []
    private let overflowButton = NSButton(title: "", target: nil, action: nil)

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(day: Date, visibleMonth: Date, selectedDay: Date?) {
        let calendar = Calendar.current
        self.day = calendar.startOfDay(for: day)
        isInVisibleMonth = calendar.isDate(day, equalTo: visibleMonth, toGranularity: .month)
        isToday = calendar.isDateInToday(day)
        isSelected = selectedDay.map { calendar.isDate(day, inSameDayAs: $0) } ?? false
        dayNumberLabel.stringValue = String(calendar.component(.day, from: day))
        if isToday {
            dayNumberLabel.textColor = .alternateSelectedControlTextColor
        } else if isInVisibleMonth {
            dayNumberLabel.textColor = .labelColor
        } else {
            dayNumberLabel.textColor = .tertiaryLabelColor
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        setAccessibilityLabel(formatter.string(from: day))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            bounds.fill()
        }

        if isToday {
            let diameter: CGFloat = 20
            let rect = NSRect(x: 3, y: 2, width: diameter, height: diameter)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }

        NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.25, dy: 0.25))
        border.lineWidth = 0.5
        border.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        onDayClick?(day)
    }

    // Incoming point is in the superview. Skip the full-width day-number field.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if !overflowButton.isHidden, let overflowHit = overflowButton.hitTest(local) {
            return overflowHit
        }
        for chipView in chipViews.reversed() {
            if let chipHit = chipView.hitTest(local) {
                return chipHit
            }
        }
        return self
    }

    override func accessibilityPerformPress() -> Bool {
        onDayClick?(day)
        return true
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 3
        dayNumberLabel.frame = NSRect(x: inset, y: 2, width: max(0, bounds.width - inset * 2), height: 18)

        var y: CGFloat = 22
        let chipHeight: CGFloat = 15
        for chipView in chipViews {
            chipView.frame = NSRect(
                x: inset,
                y: y,
                width: max(0, bounds.width - inset * 2),
                height: chipHeight
            )
            y += chipHeight + 1
        }

        overflowButton.frame = NSRect(
            x: inset,
            y: y,
            width: max(0, bounds.width - inset * 2),
            height: 14
        )
    }

    private func configure() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        dayNumberLabel.font = .systemFont(ofSize: 12, weight: .medium)
        dayNumberLabel.alignment = .left
        dayNumberLabel.isBezeled = false
        dayNumberLabel.drawsBackground = false
        dayNumberLabel.refusesFirstResponder = true
        dayNumberLabel.setAccessibilityElement(false)
        addSubview(dayNumberLabel)

        overflowButton.isBordered = false
        overflowButton.font = .systemFont(ofSize: 10)
        overflowButton.alignment = .left
        overflowButton.contentTintColor = .secondaryLabelColor
        overflowButton.target = self
        overflowButton.action = #selector(overflowClicked)
        overflowButton.isHidden = true
        addSubview(overflowButton)
    }

    private func rebuildChipViews() {
        chipViews.forEach { $0.removeFromSuperview() }
        chipViews = Array(chips.prefix(MonthCalendarView.maxVisibleChips)).map { chip in
            let view = DeadlineChipView(chip: chip)
            view.onClick = { [weak self] in
                self?.onChipClick?(chip)
            }
            addSubview(view)
            return view
        }
        let extra = chips.count - MonthCalendarView.maxVisibleChips
        overflowButton.isHidden = extra <= 0
        if extra > 0 {
            overflowButton.title = "+\(extra) more"
        }
        needsLayout = true
        if !bounds.isEmpty {
            layout()
        }
    }

    @objc private func overflowClicked() {
        onDayClick?(day)
    }

    func test_clickDay() {
        onDayClick?(day)
    }

    func test_clickChip(at index: Int) {
        guard chips.indices.contains(index) else { return }
        onChipClick?(chips[index])
    }

    func test_clickOverflow() {
        overflowClicked()
    }

    func test_chipAppearance(at index: Int) -> (color: NSColor, isStruck: Bool)? {
        guard chipViews.indices.contains(index) else { return nil }
        return chipViews[index].test_appearance
    }

    var test_dayNumberFrame: NSRect { dayNumberLabel.frame }

    func test_hitView(at localPoint: NSPoint) -> NSView? {
        hitTest(convert(localPoint, to: superview))
    }

    func test_mouseDown(at localPoint: NSPoint) {
        let hit = test_hitView(at: localPoint) ?? self
        hit.mouseDown(with: Self.testMouseEvent(at: convert(localPoint, to: nil)))
    }

    func test_mouseDownOnChip(at index: Int) {
        layout()
        guard chipViews.indices.contains(index) else { return }
        let chip = chipViews[index]
        test_mouseDown(at: convert(NSPoint(x: chip.bounds.midX, y: chip.bounds.midY), from: chip))
    }

    func test_performAccessibilityPress() -> Bool {
        accessibilityPerformPress()
    }

    func test_performChipAccessibilityPress(at index: Int) -> Bool {
        guard chipViews.indices.contains(index) else { return false }
        return chipViews[index].accessibilityPerformPress()
    }

    func test_chipAccessibilityLabel(at index: Int) -> String? {
        guard chipViews.indices.contains(index) else { return nil }
        return chipViews[index].accessibilityLabel()
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

private final class DeadlineChipView: NSView {
    let chip: TaskDeadlineChip
    var onClick: (() -> Void)?

    private let titleColor: NSColor
    private let isStruck: Bool

    var test_appearance: (color: NSColor, isStruck: Bool) {
        (titleColor, isStruck)
    }

    override var isFlipped: Bool { true }

    init(chip: TaskDeadlineChip) {
        self.chip = chip
        if chip.isCompleted {
            titleColor = .tertiaryLabelColor
            isStruck = true
        } else {
            titleColor = .labelColor
            isStruck = false
        }
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(chip.isCompleted ? "\(chip.title), Completed" : chip.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: titleColor,
        ]
        if isStruck {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        let text = NSAttributedString(string: chip.title, attributes: attributes)
        text.draw(
            with: bounds,
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
