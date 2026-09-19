import XCTest
@testable import Planner

/// What a day cell does when it runs out of room.
///
/// Before this was fixed, `+K more` escaped a short cell and drew over the
/// following day's number.
@MainActor
final class CalendarCellOverflowTests: XCTestCase {
    /// The window's own content minimum is 520pt; by the time the toolbar and
    /// the pane insets are taken out the grid is roughly this tall, which makes
    /// a row about 64pt.
    private static let minimumGridHeight: CGFloat = 450
    /// Every row is exactly `WeekCalendarView.rowHeight` now and the pane
    /// scrolls, so a cell is never squeezed by the pane's height — the only way
    /// to run one out of room is to fill it with more than it holds.
    private static let fullCellItemCount = 8

    private func makeView(height: CGFloat = minimumGridHeight) -> WeekCalendarView {
        let view = WeekCalendarView(frame: NSRect(x: 0, y: 0, width: 720, height: height))
        view.test_setWeekCount(4)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func task(_ title: String, day: Date) -> TaskDeadlineChip {
        TaskDeadlineChip(uuid: UUID(), title: title, day: day, isCompleted: false)
    }

    private func event(_ title: String, day: Date, id: String = UUID().uuidString) -> CalendarEventChip {
        CalendarEventChip(
            id: id,
            title: title,
            day: Calendar.current.startOfDay(for: day),
            startTime: nil,
            endTime: nil,
            isAllDay: true,
            continuesFromPreviousDay: false,
            continuesToNextDay: false,
            location: nil,
            organizer: nil,
            calendarName: "Work",
            isRecurring: false,
            isRescheduled: false
        )
    }

    /// Days are chronological, so index 5 is the first Saturday, 6 the Sunday.
    private let saturday = 5
    private let sunday = 6

    // MARK: - Nothing escapes the cell

    /// The reported bug: `+1 more` struck through the following day's number.
    func testTheOverflowLineNeverDrawsOutsideItsCell() {
        let view = makeView()
        let day = view.test_days[saturday]
        view.deadlines = [task("Anna math", day: day)]
        view.events = [event("Celerity Trial", day: day)]
        view.layoutSubtreeIfNeeded()

        let cell = view.test_cellFrame(at: saturday)
        if let overflow = view.test_overflowButtonFrame(at: saturday) {
            XCTAssertLessThanOrEqual(
                overflow.maxY, cell.height,
                "the +K more line escaped into the next day"
            )
        }
    }

    func testNoRowEverDrawsOutsideItsCell() {
        let view = makeView()
        for index in [saturday, sunday] {
            let day = view.test_days[index]
            view.deadlines = (0..<3).map { task("Task \($0)", day: day) }
            view.events = (0..<3).map { event("Event \($0)", day: day, id: "e\(index)-\($0)") }
        }
        view.layoutSubtreeIfNeeded()

        for index in [saturday, sunday] {
            let cell = view.test_cellFrame(at: index)
            for frame in view.test_visibleRowFrames(at: index) {
                XCTAssertLessThanOrEqual(
                    frame.maxY, cell.height,
                    "a row escaped cell \(index): \(frame) in \(cell.height)"
                )
                XCTAssertGreaterThanOrEqual(frame.minY, 0)
            }
        }
    }

    /// Holds at every height, not just the one that happened to be reported.
    func testNothingEscapesAtAnyHeight() {
        for height in stride(from: 320.0, through: 900.0, by: 40.0) {
            let view = makeView(height: height)
            for index in 0..<7 {
                let day = view.test_days[index]
                view.deadlines = (0..<2).map { task("Task \($0)", day: day) }
                view.events = (0..<3).map { event("Event \($0)", day: day, id: "e\(index)-\($0)") }
            }
            view.layoutSubtreeIfNeeded()

            for index in 0..<7 {
                let cell = view.test_cellFrame(at: index)
                for frame in view.test_visibleRowFrames(at: index) {
                    XCTAssertLessThanOrEqual(
                        frame.maxY, cell.height,
                        "row escaped at grid height \(height), cell \(index)"
                    )
                }
                if let overflow = view.test_overflowButtonFrame(at: index) {
                    XCTAssertLessThanOrEqual(
                        overflow.maxY, cell.height,
                        "overflow escaped at grid height \(height), cell \(index)"
                    )
                }
            }
        }
    }

    // MARK: - The count survives as a badge

    /// A cell too short for the `+K more` line still has to say that
    /// something is hidden, or it silently shows one of three items.
    func testAFullCellAnnouncesWhatItCannotShow() {
        let view = makeView()
        let day = view.test_days[saturday]
        view.deadlines = [task("Anna math", day: day)]
        view.events = (0..<(Self.fullCellItemCount - 1)).map {
            event("Event \($0)", day: day, id: "e\($0)")
        }
        view.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(view.test_overflowCount(at: saturday), 0)
        let hasLine = view.test_overflowButtonFrame(at: saturday) != nil
        let badge = view.test_overflowBadge(at: saturday)
        XCTAssertTrue(hasLine || badge != nil, "the hidden items must be announced somehow")
        if !hasLine {
            XCTAssertEqual(badge, "+\(view.test_overflowCount(at: saturday))")
        }
    }

    func testATallCellUsesTheFullLineRatherThanTheBadge() {
        let view = makeView(height: 900)
        let day = view.test_days[0]   // Monday, full height
        view.deadlines = (0..<8).map { task("Task \($0)", day: day) }
        view.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(view.test_overflowCount(at: 0), 0)
        XCTAssertNotNil(view.test_overflowButtonFrame(at: 0))
        XCTAssertNil(view.test_overflowBadge(at: 0), "a tall cell has room for the line")
    }

    func testACellWithNothingHiddenShowsNeitherForm() {
        let view = makeView(height: 900)
        let day = view.test_days[0]
        view.deadlines = [task("Only one", day: day)]
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.test_overflowCount(at: 0), 0)
        XCTAssertNil(view.test_overflowButtonFrame(at: 0))
        XCTAssertNil(view.test_overflowBadge(at: 0))
    }

    /// VoiceOver has no tooltip, and when the count is a badge there is no
    /// button to focus either.
    func testTheCellAnnouncesHiddenItemsToVoiceOver() {
        let view = makeView()
        let day = view.test_days[saturday]
        view.deadlines = [task("Anna math", day: day)]
        view.events = (0..<(Self.fullCellItemCount - 1)).map {
            event("Event \($0)", day: day, id: "e\($0)")
        }
        view.layoutSubtreeIfNeeded()

        let label = view.test_cellAccessibilityLabel(at: saturday) ?? ""
        XCTAssertTrue(label.contains("more"), label)
    }

    // MARK: - Weekend cells are full size

    /// Weekend cells match weekday cells, so a chip there gets its natural
    /// height rather than the squeezed one the old half-height rows forced.
    func testAWeekendCellFitsARealRowAtMinimumHeight() {
        let view = makeView()
        let day = view.test_days[saturday]
        view.deadlines = [task("Anna math", day: day)]
        view.layoutSubtreeIfNeeded()

        let frames = view.test_visibleRowFrames(at: saturday)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(
            frames[0].height, 18,
            "the task chip should get its natural height, not a squeezed one"
        )
    }
}

/// The today marker and the header band.
///
/// Same bug class as the overflow line: geometry computed from content size
/// rather than from the space available, which draws outside the cell.
@MainActor
final class CalendarDayHeaderTests: XCTestCase {
    private func makeView(height: CGFloat = 450, weekStart: Date? = nil) -> WeekCalendarView {
        let view = WeekCalendarView(frame: NSRect(x: 0, y: 0, width: 720, height: height))
        view.test_setWeekCount(4)
        if let weekStart { view.visibleWeekStart = weekStart }
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func task(_ title: String, day: Date) -> TaskDeadlineChip {
        TaskDeadlineChip(uuid: UUID(), title: title, day: day, isCompleted: false)
    }

    /// The reported defect: a flat-topped circle, because it started 1pt above
    /// the cell and the cell now clips.
    func testTheTodayMarkerStaysInsideTheHeaderBand() {
        for height in stride(from: 320.0, through: 900.0, by: 40.0) {
            let view = makeView(height: height)
            for index in 0..<7 {
                let marker = view.test_todayMarkerRect(at: index)
                XCTAssertGreaterThanOrEqual(
                    marker.minY, 0,
                    "marker overhangs the cell top at grid \(height), cell \(index)"
                )
                XCTAssertLessThanOrEqual(
                    marker.maxY, view.test_headerHeight(at: index),
                    "marker overhangs the header band at grid \(height), cell \(index)"
                )
            }
        }
    }

    /// It used to overlap the first chip by 3pt.
    func testTheTodayMarkerNeverReachesTheFirstRow() {
        let view = makeView()
        for index in 0..<7 {
            let day = view.test_days[index]
            view.deadlines = (0..<7).map { task("Task \($0)", day: day) }
        }
        view.layoutSubtreeIfNeeded()

        for index in 0..<7 {
            let marker = view.test_todayMarkerRect(at: index)
            guard let firstRow = view.test_visibleRowFrames(at: index).first else { continue }
            XCTAssertLessThanOrEqual(
                marker.maxY, firstRow.minY,
                "marker overlaps the first row in cell \(index)"
            )
        }
    }

    /// The header and the first row used to touch exactly.
    func testThereIsAGapBetweenTheHeaderAndTheFirstRow() {
        let view = makeView()
        for index in 0..<7 {
            let day = view.test_days[index]
            view.deadlines = [task("Task", day: day)]
        }
        view.layoutSubtreeIfNeeded()

        for index in 0..<7 {
            XCTAssertGreaterThan(
                view.test_contentTop(at: index), view.test_headerHeight(at: index),
                "cell \(index) starts its rows flush against the header"
            )
            guard let firstRow = view.test_visibleRowFrames(at: index).first else { continue }
            XCTAssertGreaterThanOrEqual(firstRow.minY, view.test_contentTop(at: index))
        }
    }

    /// The marker is a capsule that is never narrower than it is tall: round
    /// for a narrow number, slightly elongated for a wide one.
    ///
    /// It deliberately does *not* promise an exact circle for single digits —
    /// `NSTextField.sizeToFit` bakes in its own padding, so whether "1" comes
    /// out square depends on the font, and tuning the inset to force it would
    /// break the next time the font changed.
    func testTheMarkerWidensWithTheDayNumberButKeepsItsHeight() {
        // The week of Monday 31 August 2026 runs 31, 1, 2, 3, 4, 5, 6.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let weekStart = calendar.date(from: DateComponents(year: 2026, month: 8, day: 31))!
        let view = makeView(weekStart: weekStart)

        // Rows are fixed slots on a sheet anchored on today, so scrolling to a
        // date lands on the row holding it rather than starting a row with it.
        let last = view.test_days.firstIndex { calendar.component(.day, from: $0) == 31 }
        let first = try! XCTUnwrap(last).advanced(by: 1)
        XCTAssertEqual(view.test_dayNumber(at: first - 1), "31")
        XCTAssertEqual(view.test_dayNumber(at: first), "1")

        let twoDigit = view.test_todayMarkerRect(at: first - 1)
        let singleDigit = view.test_todayMarkerRect(at: first)
        XCTAssertGreaterThan(twoDigit.width, singleDigit.width, "a wider number needs a wider marker")
        XCTAssertEqual(twoDigit.height, singleDigit.height, accuracy: 0.01, "same band, same height")
        for marker in [twoDigit, singleDigit] {
            XCTAssertGreaterThanOrEqual(
                marker.width, marker.height,
                "a marker narrower than it is tall would read as an oval on its side"
            )
            XCTAssertLessThanOrEqual(marker.maxY, view.test_headerHeight(at: 0))
        }
    }

    /// It has to enclose the digits, or the fill sits behind part of the number.
    func testTheMarkerEnclosesTheDayNumber() {
        let view = makeView()
        for index in 0..<7 {
            let marker = view.test_todayMarkerRect(at: index)
            let number = view.test_dayNumberFrame(at: index)
            XCTAssertLessThanOrEqual(marker.minX, number.minX, "cell \(index)")
            XCTAssertGreaterThanOrEqual(marker.maxX, number.maxX, "cell \(index)")
            XCTAssertGreaterThanOrEqual(marker.minX, 0, "cell \(index) marker escapes the leading edge")
        }
    }

    /// The marker centres on the digits' cap-height band, not the label frame:
    /// the frame includes descender space digits never use, so frame-centring
    /// left the number riding high inside the capsule.
    func testTheMarkerCentersOnTheDigitInkNotTheLabelFrame() {
        let view = makeView()
        for index in 0..<7 {
            let marker = view.test_todayMarkerRect(at: index)
            let number = view.test_dayNumberFrame(at: index)
            XCTAssertLessThan(
                marker.midY, number.midY,
                "cell \(index): a marker centred on the label frame sits low on the glyphs"
            )
        }
    }

    /// Weekend cells are full size, so their marker matches the weekday one.
    func testTheWeekendMarkerMatchesTheWeekdayOne() {
        let view = makeView()
        let weekday = view.test_days.indices.first { !view.test_isWeekend(at: $0) }!
        let weekend = view.test_days.indices.first { view.test_isWeekend(at: $0) }!
        XCTAssertEqual(
            view.test_todayMarkerRect(at: weekend).height,
            view.test_todayMarkerRect(at: weekday).height,
            accuracy: 0.001
        )
    }
}
