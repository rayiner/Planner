import XCTest
@testable import Planner

@MainActor
final class CalendarWeekTests: XCTestCase {
    func testStartOfWeekIsMondayRegardlessOfLocaleFirstWeekday() {
        var calendar = utcCalendar
        calendar.firstWeekday = 1                      // locale says Sunday
        let monday = date(year: 2026, month: 8, day: 10, calendar: calendar)

        for offset in 0..<7 {
            let day = calendar.date(byAdding: .day, value: offset, to: monday)!
            XCTAssertEqual(
                calendar.startOfWeek(for: day),
                calendar.startOfDay(for: monday),
                "day +\(offset) should belong to the week starting Monday the 10th"
            )
        }

        // Sunday trails its own week rather than starting the next one.
        let sunday = calendar.date(byAdding: .day, value: 6, to: monday)!
        XCTAssertEqual(calendar.component(.weekday, from: sunday), 1)
        XCTAssertEqual(calendar.startOfWeek(for: sunday), calendar.startOfDay(for: monday))

        let nextMonday = calendar.date(byAdding: .day, value: 7, to: monday)!
        XCTAssertEqual(calendar.startOfWeek(for: nextMonday), calendar.startOfDay(for: nextMonday))
    }

    func testWeekStartsAndDaysRunMondayFirst() {
        let calendar = utcCalendar
        let monday = date(year: 2026, month: 8, day: 10, calendar: calendar)

        let starts = calendar.weekStarts(from: monday, count: 4)
        XCTAssertEqual(starts.count, 4)
        XCTAssertEqual(starts[0], calendar.startOfDay(for: monday))
        XCTAssertEqual(starts[3], calendar.startOfDay(for: date(year: 2026, month: 8, day: 31, calendar: calendar)))

        let days = calendar.days(inWeekStartingAt: monday)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(calendar.component(.weekday, from: days[0]), 2)   // Monday
        XCTAssertEqual(calendar.component(.weekday, from: days[5]), 7)   // Saturday
        XCTAssertEqual(calendar.component(.weekday, from: days[6]), 1)   // Sunday
        XCTAssertEqual(days.map { calendar.component(.day, from: $0) }, [10, 11, 12, 13, 14, 15, 16])
    }

    func testEndOfWeeksIsExclusive() {
        let calendar = utcCalendar
        let monday = date(year: 2026, month: 8, day: 10, calendar: calendar)
        XCTAssertEqual(
            calendar.endOfWeeks(from: monday, count: 4),
            calendar.startOfDay(for: date(year: 2026, month: 9, day: 7, calendar: calendar))
        )
        // A mid-week start is not snapped back to Monday.
        let thursday = date(year: 2026, month: 8, day: 13, calendar: calendar)
        XCTAssertEqual(
            calendar.endOfWeeks(from: thursday, count: 4),
            calendar.startOfDay(for: date(year: 2026, month: 9, day: 10, calendar: calendar))
        )
    }

    func testVisibleDaysRunFromTheGivenStart() {
        let calendar = utcCalendar
        let thursday = date(year: 2026, month: 8, day: 13, calendar: calendar)
        let days = calendar.visibleDays(from: thursday, count: 4)
        XCTAssertEqual(days.map { calendar.component(.day, from: $0) }, [13, 14, 15, 16])
        XCTAssertTrue(calendar.isWeekend(days[2]))
        XCTAssertTrue(calendar.isWeekend(days[3]))
        XCTAssertFalse(calendar.isWeekend(days[0]))
    }

    func testWeekRangeStringCollapsesTheMonthWhenItDoesNotChange() {
        var calendar = utcCalendar
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let monday = date(year: 2026, month: 8, day: 10, calendar: calendar)

        XCTAssertEqual(calendar.weekRangeString(from: monday, count: 1), "Aug 10 – 16, 2026")
        XCTAssertEqual(calendar.weekRangeString(from: monday, count: 4), "Aug 10 – Sep 6, 2026")
        XCTAssertEqual(
            calendar.weekRangeString(
                from: date(year: 2026, month: 8, day: 13, calendar: calendar),
                count: 4
            ),
            "Aug 13 – Sep 9, 2026"
        )
    }

    func testMonthName() {
        var calendar = utcCalendar
        calendar.locale = Locale(identifier: "en_US_POSIX")
        XCTAssertEqual(
            calendar.monthName(for: date(year: 2026, month: 8, day: 1, calendar: calendar)),
            "August"
        )
    }

    func testOverdueIsDayGranularAndIgnoresTimeOfDay() {
        let calendar = utcCalendar
        let today = date(year: 2026, month: 8, day: 13, calendar: calendar)
        let laterToday = calendar.date(byAdding: .hour, value: 6, to: today)!

        XCTAssertFalse(calendar.isOverdue(laterToday, now: today))
        XCTAssertFalse(calendar.isOverdue(today, now: laterToday))
        XCTAssertTrue(calendar.isOverdue(calendar.date(byAdding: .day, value: -1, to: today)!, now: today))
        XCTAssertFalse(calendar.isOverdue(calendar.date(byAdding: .day, value: 1, to: today)!, now: today))
    }

    func testRelativeDeadlineLabels() {
        let calendar = utcCalendar
        let today = date(year: 2026, month: 8, day: 13, calendar: calendar)

        XCTAssertEqual(calendar.relativeDeadlineLabel(for: today, now: today), "Today")
        XCTAssertEqual(
            calendar.relativeDeadlineLabel(for: calendar.date(byAdding: .day, value: 1, to: today)!, now: today),
            "Tomorrow"
        )
        XCTAssertEqual(
            calendar.relativeDeadlineLabel(for: calendar.date(byAdding: .day, value: -3, to: today)!, now: today),
            "Overdue"
        )
        XCTAssertNil(
            calendar.relativeDeadlineLabel(for: calendar.date(byAdding: .day, value: 5, to: today)!, now: today)
        )
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 1
        return calendar
    }

    private func date(year: Int, month: Int, day: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 15))!
    }
}

@MainActor
final class WeekCalendarViewTests: XCTestCase {
    func testDaysRunChronologicallyFromToday() {
        let view = makeView()
        let calendar = Calendar.current

        XCTAssertEqual(view.test_dayCount, view.test_weekCount * view.visibleRowCount)
        // The sheet opens on today, which the range is snapped to begin a row.
        XCTAssertEqual(view.test_days[0], calendar.startOfDay(for: Date()))
        XCTAssertEqual(view.visibleWeekStart, calendar.startOfDay(for: Date()))

        // Every slot is exactly one day after the slot before it.
        for index in 1..<view.test_dayCount {
            XCTAssertEqual(
                view.test_days[index],
                calendar.date(byAdding: .day, value: index, to: view.test_days[0])!
            )
        }
    }

    /// Reading order: left to right along a row, then the next row down.
    func testDaysFlowLeftToRightThenWrapToTheNextRow() {
        let view = makeView()
        view.layoutSubtreeIfNeeded()
        let perRow = view.test_weekCount

        let first = view.test_cellFrame(at: 0)
        let second = view.test_cellFrame(at: 1)
        XCTAssertGreaterThan(second.minX, first.minX, "the next day sits to the right")
        XCTAssertEqual(second.minY, first.minY, accuracy: 0.001, "…on the same row")

        let wrapped = view.test_cellFrame(at: perRow)
        XCTAssertEqual(wrapped.minX, first.minX, accuracy: 0.001, "a new row starts at the left edge")
        XCTAssertEqual(wrapped.minY, first.maxY, accuracy: 0.001, "…directly below the first")
    }

    func testWeekendFlagsOnlySaturdayAndSunday() {
        let view = makeView()
        let calendar = Calendar.current
        for index in 0..<view.test_dayCount {
            XCTAssertEqual(
                view.test_isWeekend(at: index),
                calendar.isWeekend(view.test_days[index]),
                "only Saturday and Sunday carry the weekend wash"
            )
        }
    }

    /// Every row is the same fixed height, wherever it sits on the sheet.
    func testEveryRowIsTheFixedHeight() {
        let view = makeView()
        view.layoutSubtreeIfNeeded()
        let columns = view.test_weekCount

        for index in 0..<view.test_dayCount {
            XCTAssertEqual(
                view.test_cellFrame(at: index).height,
                WeekCalendarView.rowHeight,
                accuracy: 0.001
            )
        }

        // Rows stack without gaps.
        for row in 1..<(view.test_dayCount / columns) {
            XCTAssertEqual(
                view.test_cellFrame(at: row * columns).minY,
                view.test_cellFrame(at: (row - 1) * columns).maxY,
                accuracy: 0.001
            )
        }
    }

    /// The row height was calibrated on the header plus five content rows, up
    /// from the three a fit-to-pane row settled for.
    func testTheRowHeightFitsFiveContentRows() {
        let view = makeView()
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(WeekCalendarView.rowHeight, 100)
        XCTAssertEqual(view.test_contentTop(at: 0) + 5 * 18 + 4 * 2 + 4, WeekCalendarView.rowHeight)
    }

    /// A shorter pane shows fewer rows and scrolls for the rest; it never
    /// thins the rows that are on screen.
    func testAShorterPaneKeepsRowHeightAndShowsFewerRows() {
        let view = WeekCalendarView(
            frame: NSRect(x: 0, y: 0, width: 720, height: WeekCalendarView.rowHeight * 7)
        )
        view.layoutSubtreeIfNeeded()
        let columns = view.test_weekCount
        XCTAssertEqual(view.visibleRowCount, 7)
        XCTAssertEqual(view.test_dayCount, columns * 7)
        let firstRowHeight = view.test_cellFrame(at: 0).height

        view.frame = NSRect(x: 0, y: 0, width: 720, height: WeekCalendarView.rowHeight * 5)
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.visibleRowCount, 5)
        XCTAssertEqual(view.test_dayCount, columns * 5)
        XCTAssertEqual(view.visibleDayCount, columns * 5)
        XCTAssertEqual(
            view.test_cellFrame(at: 0).height,
            firstRowHeight,
            accuracy: 0.001,
            "the rows that stayed changed height"
        )
    }

    /// The sheet reaches years either side of today, so there is always
    /// somewhere to scroll and the pane's height never bounds it.
    func testTheSheetIsFarTallerThanThePane() {
        let view = makeView()
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.test_rowCount, view.visibleRowCount * 10)
        XCTAssertEqual(
            view.documentHeight,
            CGFloat(view.test_rowCount) * WeekCalendarView.rowHeight,
            accuracy: 0.001
        )
    }

    /// Today begins a row whatever the column count, so a reflow never slides
    /// today's cell sideways.
    func testTodayBeginsARowAtEveryColumnCount() {
        let view = makeView()
        let today = Calendar.current.startOfDay(for: Date())
        for columns in WeekCalendarView.minimumWeekCount...WeekCalendarView.maximumWeekCount {
            view.test_setWeekCount(columns)
            view.scroll(toDay: today)
            XCTAssertEqual(view.test_days.first, today, "\(columns) columns put today mid-row")
        }
    }

    /// Scrolling is what moves the sheet through time, a whole row at a step.
    func testScrollingMovesTheVisibleStartByWholeRows() {
        let view = makeView()
        view.layoutSubtreeIfNeeded()
        let recorder = RecordingDelegate()
        view.delegate = recorder
        let calendar = Calendar.current
        let original = view.visibleWeekStart
        let columns = view.test_weekCount

        view.test_scroll(byRows: 2)

        XCTAssertEqual(
            view.visibleWeekStart,
            calendar.date(byAdding: .day, value: 2 * columns, to: original)!
        )
        XCTAssertEqual(recorder.weekStarts.last, view.visibleWeekStart)
        XCTAssertEqual(view.test_days.first, view.visibleWeekStart)

        view.test_scroll(byRows: -2)
        XCTAssertEqual(view.visibleWeekStart, original)
    }

    /// The fetch window is padded a screenful either side, so scrolling within
    /// it costs nothing and scrolling past it slides the window.
    func testTheFetchWindowSlidesOnlyWhenTheScrollLeavesIt() {
        let view = makeView()
        view.layoutSubtreeIfNeeded()
        let recorder = RecordingDelegate()
        view.delegate = recorder
        let beforeRange = view.test_loadedRange

        view.test_scroll(byRows: 1)
        XCTAssertTrue(recorder.loadedRanges.isEmpty, "a scroll inside the window refetched")
        XCTAssertEqual(view.test_loadedRange, beforeRange)

        view.test_scroll(byRows: view.visibleRowCount * 3)
        XCTAssertFalse(recorder.loadedRanges.isEmpty, "a scroll past the window did not refetch")
        XCTAssertNotEqual(view.test_loadedRange, beforeRange)
        // Whatever is on screen is always inside the window.
        XCTAssertLessThanOrEqual(view.test_loadedRange.lowerBound, view.test_days[0])
        XCTAssertGreaterThan(view.test_loadedRange.upperBound, view.test_days.last!)
    }

    func testColumnEdgesSplitTheWidthEvenlyAndLeaveNoSeam() {
        let edges = WeekCalendarView.columnEdges(in: 700, count: 4)
        XCTAssertEqual(edges, [0, 175, 350, 525, 700])

        // A width that does not divide evenly still spans the pane end to end,
        // and every column abuts the next rather than leaving a rounding seam.
        let ragged = WeekCalendarView.columnEdges(in: 703, count: 5)
        XCTAssertEqual(ragged.first, 0)
        XCTAssertEqual(ragged.last, 703)
        XCTAssertEqual(ragged.count, 6)
        for index in 1..<ragged.count {
            XCTAssertGreaterThan(ragged[index], ragged[index - 1])
        }
    }

    func testNarrowestColumnFitsTheCalibrationTitleWithoutTruncating() {
        let title = WeekCalendarView.chipWidthCalibrationTitle

        XCTAssertFalse(
            truncates(title, inColumnOfWidth: WeekCalendarView.targetColumnWidth),
            "\"\(title)\" truncates in the narrowest column"
        )

        // "Just wide enough": the minimum sits within a few points of the
        // narrowest column that renders the title whole, rather than being
        // padded out well beyond it.
        var narrowest = WeekCalendarView.targetColumnWidth
        while narrowest > 1, !truncates(title, inColumnOfWidth: narrowest - 1) {
            narrowest -= 1
        }
        XCTAssertLessThanOrEqual(
            WeekCalendarView.targetColumnWidth - narrowest,
            4,
            "minimum column is \(WeekCalendarView.targetColumnWidth)pt but \(narrowest)pt already fits"
        )
    }

    /// Truncation as the chip actually renders it, not as `.size()` estimates it:
    /// the final glyph's trailing side bearing means text fits a little tighter
    /// than its measured width suggests.
    private func truncates(_ title: String, inColumnOfWidth columnWidth: CGFloat) -> Bool {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let storage = NSTextStorage(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .paragraphStyle: paragraph,
        ])
        let container = NSTextContainer(size: NSSize(
            width: WeekCalendarView.chipTextWidth(inColumnOfWidth: columnWidth),
            height: 100
        ))
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)

        var truncated = false
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, range, _ in
            if layout.truncatedGlyphRange(inLineFragmentForGlyphAt: range.location).location != NSNotFound {
                truncated = true
            }
        }
        return truncated
    }

    func testColumnsNeverFallBelowTheCalibratedMinimumWhileWeeksFit() {
        // Whatever the pane width, dividing it by the chosen count must leave
        // columns at least as wide as the minimum — that is what makes
        // targetColumnWidth a floor rather than just a hint.
        for width in stride(from: WeekCalendarView.targetColumnWidth * 2, through: 2_000, by: 17) {
            let count = WeekCalendarView.weekCount(fittingWidth: width)
            guard count < WeekCalendarView.maximumWeekCount else { continue }
            let columnWidth = width / CGFloat(count)
            XCTAssertGreaterThanOrEqual(
                columnWidth,
                WeekCalendarView.targetColumnWidth,
                "at \(width)pt the \(count) columns are only \(columnWidth)pt wide"
            )
        }
    }

    func testVisibleWeekCountFollowsAvailableWidth() {
        let minimum = WeekCalendarView.targetColumnWidth
        // Derived from the calibrated minimum rather than hardcoded, so changing
        // the chip font moves the counts without invalidating the test.
        XCTAssertEqual(WeekCalendarView.weekCount(fittingWidth: minimum * 3), 3)
        XCTAssertEqual(WeekCalendarView.weekCount(fittingWidth: minimum * 5 + 20), 5)
        // Clamped at both ends so columns never vanish or shrink to slivers.
        XCTAssertEqual(WeekCalendarView.weekCount(fittingWidth: 10), WeekCalendarView.minimumWeekCount)
        XCTAssertEqual(WeekCalendarView.weekCount(fittingWidth: 9_000), WeekCalendarView.maximumWeekCount)
    }

    func testMonthBadgeMarksOnlyTheFirstDayOfAMonth() throws {
        let view = makeView()
        let calendar = Calendar.current
        // Anchor on a week that certainly contains a 1st.
        let augustFirstWeek = calendar.startOfWeek(for: makeDate(2026, 8, 1))
        view.visibleWeekStart = augustFirstWeek

        let index = try XCTUnwrap(view.test_days.firstIndex { calendar.component(.day, from: $0) == 1 })
        XCTAssertEqual(view.test_monthBadge(at: index), calendar.monthName(for: view.test_days[index]))

        for other in 0..<view.test_dayCount where calendar.component(.day, from: view.test_days[other]) != 1 {
            XCTAssertNil(view.test_monthBadge(at: other))
        }
    }

    func testMonthHeaderIsCentredAndRenderedInCaps() throws {
        let view = makeView()
        let calendar = Calendar.current
        view.visibleWeekStart = calendar.startOfWeek(for: makeDate(2026, 9, 1))
        view.layoutSubtreeIfNeeded()

        let index = try XCTUnwrap(view.test_days.firstIndex { calendar.component(.day, from: $0) == 1 })
        XCTAssertEqual(view.test_monthHeaderText(at: index), "SEPTEMBER")

        // Centred in the cell, not pinned to an edge.
        let cell = view.test_cellFrame(at: index)
        let header = try XCTUnwrap(view.test_monthHeaderFrame(at: index))
        XCTAssertEqual(header.midX, cell.width / 2, accuracy: 1)
    }

    func testNoteDotSitsAtTheTrailingEdgeRegardlessOfDayNumberWidth() {
        let view = makeView()
        view.daysWithNotes = Set(view.test_days)
        view.layoutSubtreeIfNeeded()

        // Single- and double-digit days must put the marker in the same place.
        let frames = (0..<7).map { view.test_noteDotFrame(at: $0) }
        let trailingEdges = Set(frames.map { ($0.maxX * 10).rounded() })
        XCTAssertEqual(trailingEdges.count, 1, "every note dot shares one trailing edge")

        let cell = view.test_cellFrame(at: 0)
        XCTAssertGreaterThan(frames[0].minX, cell.width / 2, "the dot is on the trailing side")
    }

    func testEveryDayShowsItsNumber() {
        let view = makeView()
        let calendar = Calendar.current
        for index in 0..<view.test_dayCount {
            XCTAssertEqual(
                view.test_dayNumber(at: index),
                String(calendar.component(.day, from: view.test_days[index]))
            )
        }
    }

    /// Rows are fixed slots on the sheet, so assigning a mid-row day scrolls to
    /// the row holding it and reports the day that row actually begins with —
    /// otherwise the model and the sheet would disagree about where it is.
    func testVisibleWeekStartSetterSnapsToTheRowAndReportsIt() {
        let view = makeView()
        view.layoutSubtreeIfNeeded()
        let recorder = RecordingDelegate()
        view.delegate = recorder
        let calendar = Calendar.current
        let columns = view.test_weekCount
        let midRow = calendar.date(byAdding: .day, value: columns + 1, to: view.visibleWeekStart)!

        view.visibleWeekStart = midRow

        let rowStart = calendar.date(byAdding: .day, value: columns, to: view.test_days[0])!
        XCTAssertEqual(view.visibleWeekStart, view.test_days[0])
        XCTAssertLessThanOrEqual(view.visibleWeekStart, calendar.startOfDay(for: midRow))
        XCTAssertLessThan(calendar.startOfDay(for: midRow), rowStart, "the day asked for is off screen")
        XCTAssertEqual(recorder.weekStarts, [view.visibleWeekStart])
        XCTAssertTrue(recorder.taskIDs.isEmpty)
        XCTAssertTrue(recorder.days.isEmpty)
    }

    /// A day that already begins a row is not moved at all, and nothing is
    /// reported because nothing changed.
    func testVisibleWeekStartSetterOnARowBoundaryReportsNothing() {
        let view = makeView()
        view.layoutSubtreeIfNeeded()
        let recorder = RecordingDelegate()
        view.delegate = recorder
        let calendar = Calendar.current
        let next = calendar.date(byAdding: .day, value: view.test_weekCount, to: view.visibleWeekStart)!

        view.visibleWeekStart = next

        XCTAssertEqual(view.visibleWeekStart, calendar.startOfDay(for: next))
        XCTAssertTrue(recorder.weekStarts.isEmpty)
    }

    /// Today is the only jump left — the week buttons are gone — and like the
    /// old gestures it only tells the delegate.
    func testTodayIsTheOnlyJumpAndOnlyCallsTheDelegate() {
        let view = makeView()
        view.layoutSubtreeIfNeeded()
        view.test_scroll(byRows: 20)
        let recorder = RecordingDelegate()
        view.delegate = recorder
        let scrolled = view.visibleWeekStart

        view.test_clickToday()

        XCTAssertEqual(view.visibleWeekStart, scrolled, "the gesture never mutates the view directly")
        XCTAssertEqual(recorder.weekStarts.count, 1)
        XCTAssertEqual(
            Calendar.current.startOfDay(for: recorder.weekStarts[0]),
            Calendar.current.startOfDay(for: Date())
        )
        XCTAssertTrue(recorder.taskIDs.isEmpty)
        XCTAssertTrue(recorder.days.isEmpty)
    }

    func testMoveSelectionWalksDaysAndScrollsOnlyWhenLeavingTheScreen() {
        let view = makeView()
        view.layoutSubtreeIfNeeded()
        let recorder = RecordingDelegate()
        view.delegate = recorder
        let calendar = Calendar.current
        let anchor = view.test_days[0]
        view.selectedDay = anchor

        view.moveSelection(byDays: 1)
        XCTAssertEqual(recorder.days.last, calendar.date(byAdding: .day, value: 1, to: anchor)!)
        XCTAssertTrue(recorder.weekStarts.isEmpty, "staying on screen must not scroll")

        view.selectedDay = anchor
        view.moveSelection(byDays: view.test_weekCount)
        XCTAssertEqual(
            recorder.days.last,
            calendar.date(byAdding: .day, value: view.test_weekCount, to: anchor)!
        )
        XCTAssertTrue(recorder.weekStarts.isEmpty)

        // Stepping back off the first visible day scrolls one row earlier —
        // exactly one, not a whole screen.
        view.selectedDay = anchor
        view.moveSelection(byDays: -1)
        XCTAssertEqual(recorder.weekStarts.count, 1)
        XCTAssertEqual(
            calendar.startOfDay(for: recorder.weekStarts[0]),
            calendar.date(byAdding: .day, value: -view.test_weekCount, to: anchor)!
        )
    }

    /// Walking the selection off the bottom leaves the sheet on a row
    /// boundary, so the top row is never shown as a sliver.
    func testScrollingASelectionIntoViewLandsOnARowBoundary() {
        let view = makeView()
        view.layoutSubtreeIfNeeded()
        // A viewport that is not a whole number of rows tall is the case that
        // used to leave a half row at the top.
        view.frame = NSRect(
            x: 0,
            y: 0,
            width: 720,
            height: WeekCalendarView.rowHeight * 4 + WeekCalendarView.rowHeight / 2
        )
        view.layoutSubtreeIfNeeded()
        view.selectedDay = view.test_days[0]

        for _ in 0..<8 { view.moveSelection(byDays: view.test_weekCount) }

        XCTAssertGreaterThan(view.test_scrollOrigin, 0, "the selection never left the screen")
        XCTAssertEqual(
            view.test_scrollOrigin.truncatingRemainder(dividingBy: WeekCalendarView.rowHeight),
            0,
            accuracy: 0.001,
            "the sheet came to rest mid-row"
        )
        XCTAssertEqual(view.test_cellFrame(at: 0).minY, view.test_scrollOrigin, accuracy: 0.001)
        XCTAssertTrue(
            view.test_days.contains(view.selectedDay!),
            "the selected day scrolled out of view"
        )
    }

    func testFirstArrowPressWithNothingSelectedLandsOnToday() {
        let view = makeView()
        let recorder = RecordingDelegate()
        view.delegate = recorder
        XCTAssertNil(view.selectedDay)

        view.moveSelection(byDays: 1)

        // Lands on today rather than tomorrow: with nothing selected there is no
        // anchor to move from.
        XCTAssertEqual(recorder.days, [Calendar.current.startOfDay(for: Date())])
    }

    func testChipClickSelectsTheTaskOnly() {
        let view = makeView()
        let recorder = RecordingDelegate()
        view.delegate = recorder
        let day = view.test_days[2]
        let chip = TaskDeadlineChip(uuid: UUID(), title: "Write tests", day: day, isCompleted: false)
        view.deadlines = [chip]

        view.test_clickChip(at: 2, chip: 0)

        // Selection is exclusive: emitting the day too would immediately
        // displace the task the user just clicked.
        XCTAssertEqual(recorder.taskIDs, [chip.uuid])
        XCTAssertTrue(recorder.days.isEmpty)
        XCTAssertTrue(recorder.weekStarts.isEmpty)
    }

    func testDayAndOverflowClickSelectDayOnly() {
        let view = makeView()
        let recorder = RecordingDelegate()
        view.delegate = recorder
        let index = 2
        let day = view.test_days[index]
        let chips = (0..<8).map { offset in
            TaskDeadlineChip(uuid: UUID(), title: "Task \(offset)", day: day, isCompleted: false)
        }
        view.deadlines = chips

        let visible = view.test_visibleChips(at: index)
        XCTAssertGreaterThanOrEqual(visible.count, 1)
        XCTAssertLessThan(visible.count, chips.count)
        XCTAssertEqual(visible.map(\.uuid), chips.prefix(visible.count).map(\.uuid))
        XCTAssertEqual(visible.count + view.test_overflowCount(at: index), chips.count)

        view.test_clickDay(at: index)
        view.test_clickOverflow(at: index)

        XCTAssertTrue(recorder.taskIDs.isEmpty)
        XCTAssertEqual(recorder.days.count, 2)
        XCTAssertTrue(recorder.days.allSatisfy { Calendar.current.isDate($0, inSameDayAs: day) })
        XCTAssertTrue(recorder.weekStarts.isEmpty)
        XCTAssertTrue(recorder.doubleClickedDays.isEmpty)
    }

    /// Chips, event rows and the overflow button sit on top of the cell, so a
    /// double-click that lands on one must not be swallowed as a single click.
    func testDoubleClickingAChipReportsTheTaskNotTheDay() {
        let view = makeView()
        let recorder = RecordingDelegate()
        view.delegate = recorder
        let day = futureDay(in: view)
        let index = view.test_days.firstIndex(of: day)!
        let chip = TaskDeadlineChip(uuid: UUID(), title: "Brief", day: day, isCompleted: false)
        view.deadlines = [chip]

        view.test_mouseDownFromCalendarOnChip(at: index, chip: 0, clickCount: 2)

        XCTAssertEqual(recorder.doubleClickedTaskIDs, [chip.uuid])
        XCTAssertEqual(recorder.taskIDs, [chip.uuid], "the task is selected first")
        XCTAssertTrue(recorder.doubleClickedDays.isEmpty, "a chip is a task, not its day")
    }

    func testDoubleClickingAnEventRowOpensItsDay() {
        let view = makeView()
        let recorder = RecordingDelegate()
        view.delegate = recorder
        let day = futureDay(in: view)
        let index = view.test_days.firstIndex(of: day)!
        view.events = [
            CalendarEventChip(
                id: UUID().uuidString,
                title: "Standup",
                day: day,
                startTime: Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day),
                endTime: nil,
                isAllDay: false,
                continuesFromPreviousDay: false,
                continuesToNextDay: false,
                location: nil,
                organizer: nil,
                calendarName: "Work",
                isRecurring: false,
                isRescheduled: false
            )
        ]
        view.layoutSubtreeIfNeeded()

        view.test_doubleClickEvent(at: index, event: 0)

        XCTAssertEqual(recorder.doubleClickedDays.count, 1)
        XCTAssertTrue(Calendar.current.isDate(recorder.doubleClickedDays[0], inSameDayAs: day))
        XCTAssertTrue(recorder.taskIDs.isEmpty)
    }

    func testDoubleClickingADaySelectsItAndReportsTheDoubleClick() {
        let view = makeView()
        let recorder = RecordingDelegate()
        view.delegate = recorder
        let index = 1
        let day = view.test_days[index]

        view.test_doubleClickDay(at: index)

        XCTAssertEqual(recorder.days.count, 1)
        XCTAssertEqual(recorder.doubleClickedDays.count, 1)
        XCTAssertTrue(Calendar.current.isDate(recorder.days[0], inSameDayAs: day))
        XCTAssertTrue(Calendar.current.isDate(recorder.doubleClickedDays[0], inSameDayAs: day))
    }

    func testCompletedChipsAreDimmedAndStruck() {
        let view = makeView()
        let day = futureDay(in: view)
        let index = view.test_days.firstIndex(of: day)!
        view.deadlines = [
            TaskDeadlineChip(uuid: UUID(), title: "Done", day: day, isCompleted: true),
            TaskDeadlineChip(uuid: UUID(), title: "Open", day: day, isCompleted: false),
        ]

        let completed = view.test_chipAppearance(at: index, chip: 0)
        let open = view.test_chipAppearance(at: index, chip: 1)
        XCTAssertEqual(completed?.color, .tertiaryLabelColor)
        XCTAssertEqual(completed?.isStruck, true)
        XCTAssertEqual(open?.color, .labelColor)
        XCTAssertEqual(open?.isStruck, false)
    }

    /// Completing or renaming a task keeps its UUID, so the chip view must
    /// update in place rather than only when the chip set changes.
    func testChipUpdatesInPlaceWhenTaskChangesUnderTheSameUUID() {
        let view = makeView()
        let day = futureDay(in: view)
        let index = view.test_days.firstIndex(of: day)!
        let uuid = UUID()
        view.deadlines = [TaskDeadlineChip(uuid: uuid, title: "Draft brief", day: day, isCompleted: false)]
        XCTAssertEqual(view.test_chipAppearance(at: index, chip: 0)?.isStruck, false)

        view.deadlines = [TaskDeadlineChip(uuid: uuid, title: "Send brief", day: day, isCompleted: true)]

        let appearance = view.test_chipAppearance(at: index, chip: 0)
        XCTAssertEqual(appearance?.isStruck, true, "completing must strike the existing chip")
        XCTAssertEqual(appearance?.color, .tertiaryLabelColor)
        XCTAssertEqual(
            view.test_chipAccessibilityLabel(at: index, chip: 0),
            "Send brief, Completed",
            "the rename and the completion both reach VoiceOver"
        )
    }

    func testSelectedChipUsesAccentColor() {
        let view = makeView()
        let day = futureDay(in: view)
        let index = view.test_days.firstIndex(of: day)!
        let selected = TaskDeadlineChip(uuid: UUID(), title: "Selected", day: day, isCompleted: false)
        let other = TaskDeadlineChip(uuid: UUID(), title: "Other", day: day, isCompleted: false)
        view.deadlines = [selected, other]

        view.selectedTaskID = selected.uuid

        XCTAssertEqual(view.test_chipAppearance(at: index, chip: 0)?.color, .controlAccentColor)
        XCTAssertEqual(view.test_chipAppearance(at: index, chip: 0)?.isSelected, true)
        XCTAssertEqual(view.test_chipAppearance(at: index, chip: 1)?.color, .labelColor)
    }

    func testOverdueChipIsRedUnlessCompletedOrSelected() throws {
        let view = makeView()
        let calendar = Calendar.current
        // Page back so the visible weeks are entirely in the past.
        view.visibleWeekStart = calendar.date(byAdding: .day, value: -28, to: view.visibleWeekStart)!
        let today = calendar.startOfDay(for: Date())
        let index = try XCTUnwrap(view.test_days.indices.last { view.test_days[$0] < today })
        let past = view.test_days[index]

        let late = TaskDeadlineChip(uuid: UUID(), title: "Late", day: past, isCompleted: false)
        let lateButDone = TaskDeadlineChip(uuid: UUID(), title: "Late done", day: past, isCompleted: true)
        view.deadlines = [late, lateButDone]

        XCTAssertEqual(view.test_chipAppearance(at: index, chip: 0)?.color, .systemRed)
        XCTAssertEqual(view.test_chipAppearance(at: index, chip: 1)?.color, .tertiaryLabelColor)

        view.selectedTaskID = late.uuid
        XCTAssertEqual(view.test_chipAppearance(at: index, chip: 0)?.color, .controlAccentColor)
    }

    func testAccessibilityPressSelectsDayAndChip() {
        let view = makeView()
        let recorder = RecordingDelegate()
        view.delegate = recorder
        let day = view.test_days[3]
        let done = TaskDeadlineChip(uuid: UUID(), title: "Done", day: day, isCompleted: true)
        let open = TaskDeadlineChip(uuid: UUID(), title: "Open", day: day, isCompleted: false)
        view.deadlines = [done, open]

        XCTAssertEqual(view.test_chipAccessibilityLabel(at: 3, chip: 0), "Done, Completed")
        XCTAssertEqual(view.test_chipAccessibilityLabel(at: 3, chip: 1), "Open")
        XCTAssertTrue(view.test_performDayAccessibilityPress(at: 3))
        XCTAssertTrue(view.test_performChipAccessibilityPress(at: 3, chip: 1))

        // The day press selects the day; the chip press selects only the task.
        XCTAssertEqual(recorder.days.count, 1)
        XCTAssertEqual(recorder.taskIDs, [open.uuid])
    }

    func testDayNumberHitFromCalendarSelectsDay() {
        let view = makeView()
        let recorder = RecordingDelegate()
        view.delegate = recorder
        let index = 4

        XCTAssertTrue(
            view.test_hitIsDayCell(view.test_hitViewFromCalendarOnDayNumber(at: index), at: index),
            "a hit on the day number must reach the day cell, not a label"
        )
        view.test_mouseDownFromCalendarOnDayNumber(at: index)

        XCTAssertEqual(recorder.days.count, 1)
        XCTAssertTrue(Calendar.current.isDate(recorder.days[0], inSameDayAs: view.test_days[index]))
        XCTAssertTrue(recorder.taskIDs.isEmpty)
    }

    func testChipHitFromCalendarSelectsTask() {
        let view = makeView()
        let recorder = RecordingDelegate()
        view.delegate = recorder
        let index = 9   // partway into the grid, off the first row
        let chip = TaskDeadlineChip(uuid: UUID(), title: "Chip", day: view.test_days[index], isCompleted: false)
        view.deadlines = [chip]
        view.layoutSubtreeIfNeeded()

        XCTAssertTrue(view.test_hitIsChip(
            view.test_hitViewFromCalendarOnChip(at: index, chip: 0),
            at: index,
            chip: 0
        ))
        view.test_mouseDownFromCalendarOnChip(at: index, chip: 0)

        XCTAssertEqual(recorder.taskIDs, [chip.uuid])
        XCTAssertTrue(recorder.days.isEmpty)
    }

    func testWeekendCellsAreFullSize() {
        let view = makeView()
        view.layoutSubtreeIfNeeded()
        let weekday = view.test_days.indices.first { !view.test_isWeekend(at: $0) }!
        let saturday = view.test_days.indices.first { view.test_isWeekend(at: $0) }!
        let weekdayFrame = view.test_cellFrame(at: weekday)
        let weekendFrame = view.test_cellFrame(at: saturday)

        XCTAssertTrue(view.test_isWeekend(at: saturday))
        // The gray wash, not the size, is what marks the weekend now.
        XCTAssertEqual(weekendFrame.height, weekdayFrame.height, accuracy: 0.001)
        XCTAssertEqual(weekendFrame.width, weekdayFrame.width, accuracy: 0.001)
    }

    /// The MON…SUN gutter is gone; the grid owns the full pane width.
    func testTheGridFillsTheFullWidth() {
        let view = makeView()
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.test_cellFrame(at: 0).minX, 0, accuracy: 0.001)
        let lastInRow = view.test_cellFrame(at: view.test_weekCount - 1)
        XCTAssertEqual(lastInRow.maxX, 720, accuracy: 0.001)
    }

    /// Arrow keys follow reading order: ±1 day sideways, a whole row — one day
    /// per visible week — vertically.
    func testArrowKeyOffsetsFollowReadingOrder() throws {
        func key(_ code: UInt16) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: " ",
                charactersIgnoringModifiers: " ",
                isARepeat: false,
                keyCode: code
            ))
        }
        XCTAssertEqual(try WeekCalendarView.dayOffset(for: key(123), daysPerRow: 4), -1)
        XCTAssertEqual(try WeekCalendarView.dayOffset(for: key(124), daysPerRow: 4), 1)
        XCTAssertEqual(try WeekCalendarView.dayOffset(for: key(125), daysPerRow: 4), 4)
        XCTAssertEqual(try WeekCalendarView.dayOffset(for: key(126), daysPerRow: 4), -4)
        XCTAssertNil(try WeekCalendarView.dayOffset(for: key(36), daysPerRow: 4), "return is not navigation")
    }

    private func makeView() -> WeekCalendarView {
        let view = WeekCalendarView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// A visible day that is not already past, so appearance assertions are about
    /// completion and selection rather than the overdue tint.
    private func futureDay(in view: WeekCalendarView) -> Date {
        let today = Calendar.current.startOfDay(for: Date())
        let days = view.test_days
        return days.first { $0 >= today } ?? days[0]
    }

    private func makeDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
}

@MainActor
final class CalendarViewControllerTests: PersistenceTestCase {
    /// The model asks for a day; the sheet scrolls to its row and hands the
    /// snapped day back, so the two never drift apart.
    func testObserverAppliesVisibleWeekFromSelectionModel() {
        let selection = SelectionModel()
        let calendarVC = makeCalendar(selection: selection)
        let originalTitle = calendarVC.test_title
        let calendar = Calendar.current
        let next = calendar.date(byAdding: .day, value: 7, to: selection.visibleWeekStart)!

        selection.setVisibleWeekStart(next)

        let weekView = calendarVC.weekView
        XCTAssertEqual(weekView.visibleWeekStart, selection.visibleWeekStart)
        XCTAssertEqual(weekView.visibleWeekStart, weekView.test_days[0])
        XCTAssertTrue(
            weekView.test_days.contains(calendar.startOfDay(for: next)),
            "the day that was asked for is not on screen"
        )
        XCTAssertNotEqual(calendarVC.test_title, originalTitle)
    }

    /// A scroll writes the selection, and the observer coming back round does
    /// not scroll on top of it.
    func testScrollingWritesSelectionThenViewUpdatesFromObserver() {
        let selection = SelectionModel()
        let calendarVC = makeCalendar(selection: selection)
        let original = selection.visibleWeekStart
        let originalNode = selection.selectedNodeUUID

        calendarVC.weekView.test_scroll(byRows: 1)

        let expected = Calendar.current.date(
            byAdding: .day,
            value: calendarVC.weekView.visibleWeekCount,
            to: original
        )!
        XCTAssertEqual(selection.visibleWeekStart, expected)
        XCTAssertEqual(calendarVC.weekView.visibleWeekStart, expected)
        XCTAssertEqual(calendarVC.weekView.test_days.first, expected)
        XCTAssertEqual(selection.selectedNodeUUID, originalNode)
    }

    func testChipClickSelectsTheTaskAndClearsAnySelectedDay() throws {
        let selection = SelectionModel()
        let calendarVC = makeCalendar(selection: selection)
        let project = try model.createProject()
        let day = calendarVC.weekView.test_days[2]
        let task = try makeTask(in: project, title: "Deadline", deadline: day)
        let originalWeek = selection.visibleWeekStart
        selection.selectDay(calendarVC.weekView.test_days[0])

        XCTAssertEqual(calendarVC.weekView.test_visibleChips(at: 2).map(\.uuid), [task.uuid])

        calendarVC.weekView.test_clickChip(at: 2, chip: 0)

        XCTAssertEqual(selection.selectedNodeUUID, task.uuid)
        XCTAssertNil(selection.selectedDay, "a task and a day cannot both be selected")
        XCTAssertEqual(selection.visibleWeekStart, originalWeek)
        XCTAssertEqual(calendarVC.weekView.selectedTaskID, task.uuid)
        XCTAssertNil(calendarVC.weekView.selectedDay)
    }

    func testDayClickTakesSelectionFromTheOutline() throws {
        let selection = SelectionModel()
        let calendarVC = makeCalendar(selection: selection)
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        selection.selectNode(uuid: task.uuid)
        let day = calendarVC.weekView.test_days[1]

        calendarVC.weekView.test_clickDay(at: 1)

        XCTAssertNil(selection.selectedNodeUUID, "the day takes the selection from the task")
        XCTAssertEqual(selection.selectedDay, Calendar.current.startOfDay(for: day))
        XCTAssertEqual(calendarVC.weekView.selectedDay, Calendar.current.startOfDay(for: day))
        XCTAssertNil(calendarVC.weekView.selectedTaskID)
    }

    func testFetchCoversTheWindowIncludingCompletedButNotProjectsOrNilDeadlines() throws {
        let selection = SelectionModel()
        let calendarVC = makeCalendar(selection: selection)
        let project = try model.createProject()
        try model.setTitle(project, "Garden")

        let days = calendarVC.weekView.test_days
        let first = days[0]
        let last = days[days.count - 1]
        let middle = days[days.count / 2]
        let calendar = Calendar.current
        // The fetch window reaches a screenful past what is on screen, so
        // "outside it" has to be measured from the window, not from the pane.
        let window = calendarVC.weekView.loadedRange
        let before = calendar.date(byAdding: .day, value: -1, to: window.lowerBound)!
        let after = window.upperBound

        let open = try makeTask(in: project, title: "Open", deadline: middle)
        let done = try makeTask(in: project, title: "Done", deadline: middle)
        try model.setCompleted(true, on: done)
        let firstDay = try makeTask(in: project, title: "First", deadline: first)
        let lastDay = try makeTask(in: project, title: "Last", deadline: last)
        _ = try makeTask(in: project, title: "Before", deadline: before)
        _ = try makeTask(in: project, title: "After", deadline: after)
        _ = try model.createTask(in: project)

        let chips = calendarVC.weekView.deadlines
        XCTAssertEqual(Set(chips.map(\.uuid)), [open.uuid, done.uuid, firstDay.uuid, lastDay.uuid])
        XCTAssertTrue(chips.contains { $0.uuid == done.uuid && $0.isCompleted })
        XCTAssertFalse(chips.contains { $0.title == "Garden" })
    }

    /// Scrolling towards a day outside the window slides the window and the
    /// deadline arrives with it.
    func testScrollingFetchesDaysThatWereOutsideTheWindow() throws {
        let selection = SelectionModel()
        let calendarVC = makeCalendar(selection: selection)
        let project = try model.createProject()
        let weekView = calendarVC.weekView
        let farOut = weekView.loadedRange.upperBound
        let task = try makeTask(in: project, title: "Far", deadline: farOut)

        XCTAssertFalse(weekView.deadlines.contains { $0.uuid == task.uuid })

        weekView.scroll(toDay: farOut)

        XCTAssertTrue(weekView.deadlines.contains { $0.uuid == task.uuid })
    }

    private func makeCalendar(selection: SelectionModel) -> CalendarViewController {
        let calendarVC = CalendarViewController(
            persistence: persistence,
            model: model,
            selection: selection,
            events: EventCoordinator(source: NullEventSource())
        )
        calendarVC.loadViewIfNeeded()
        calendarVC.view.frame = NSRect(x: 0, y: 0, width: 720, height: 480)
        calendarVC.view.layoutSubtreeIfNeeded()
        return calendarVC
    }

    private func makeTask(in project: Project, title: String, deadline: Date) throws -> TaskItem {
        let task = try model.createTask(in: project)
        try model.setTitle(task, title)
        try model.setDeadline(task, date: deadline)
        return task
    }
}

@MainActor
private final class RecordingDelegate: WeekCalendarViewDelegate {
    var taskIDs: [UUID] = []
    var doubleClickedTaskIDs: [UUID] = []
    var days: [Date] = []
    var doubleClickedDays: [Date] = []
    var weekStarts: [Date] = []
    var loadedRanges: [Range<Date>] = []

    func weekCalendar(_ view: WeekCalendarView, didSelectTaskID uuid: UUID) {
        taskIDs.append(uuid)
    }

    func weekCalendar(_ view: WeekCalendarView, didSelectDay date: Date) {
        days.append(date)
    }

    func weekCalendar(_ view: WeekCalendarView, didDoubleClickDay date: Date) {
        doubleClickedDays.append(date)
    }

    func weekCalendar(_ view: WeekCalendarView, didDoubleClickTaskID uuid: UUID) {
        doubleClickedTaskIDs.append(uuid)
    }

    func weekCalendar(_ view: WeekCalendarView, didChangeVisibleWeekStart date: Date) {
        weekStarts.append(date)
    }

    func weekCalendar(_ view: WeekCalendarView, didChangeLoadedRange range: Range<Date>) {
        loadedRanges.append(range)
    }
}
