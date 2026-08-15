import Foundation

/// One occurrence of an external calendar event, as the source reports it.
///
/// Deliberately **not** a Core Data entity: the store is CloudKit-bound and
/// `ModelController` is its only writer, so mirroring a read-only foreign feed
/// into it would add a second writer, sync borrowed data later, and create a
/// delete-reconcile problem when an event disappears upstream. Events live in
/// memory for the visible window and are discarded on quit.
///
/// `Sendable` because it is the only thing that crosses back from the source's
/// own queue — no source object and no managed object ever does.
nonisolated struct CalendarEvent: Hashable, Sendable {
    /// Stable across refreshes: source + external UID + occurrence start.
    let id: String
    let title: String
    let start: Date
    /// Exclusive.
    let end: Date
    let isAllDay: Bool
    let location: String?
    let organizer: String?
    let calendarName: String?
    let isRecurring: Bool
    /// An occurrence moved off the slot its series would have put it in.
    let isRescheduled: Bool

    init(
        id: String,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        location: String? = nil,
        organizer: String? = nil,
        calendarName: String? = nil,
        isRecurring: Bool = false,
        isRescheduled: Bool = false
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.organizer = organizer
        self.calendarName = calendarName
        self.isRecurring = isRecurring
        self.isRescheduled = isRescheduled
    }
}

/// One event row inside one day cell. A multi-day event becomes one chip per
/// day it covers, so the grid never has to reason about spans.
///
/// Mirrors `TaskDeadlineChip`'s `(id, title, day)` shape so the calendar's
/// existing group-by-start-of-day needs no restructuring.
nonisolated struct CalendarEventChip: Hashable, Sendable {
    let id: String
    let title: String
    /// Start of day, matching `TaskDeadlineChip.day`.
    let day: Date
    /// Wall-clock start, shown as a prefix in the label. `nil` for all-day
    /// events and for the continuation days of a multi-day event, where a start
    /// time would be a lie.
    let startTime: Date?
    /// Wall-clock end, for the tooltip and VoiceOver only — never drawn. Set
    /// alongside `startTime`, so a continuation day carries neither.
    let endTime: Date?
    let isAllDay: Bool
    let continuesFromPreviousDay: Bool
    let continuesToNextDay: Bool
    // Tooltip / accessibility only. Never drawn in the grid.
    let location: String?
    let organizer: String?
    let calendarName: String?
    let isRecurring: Bool
    let isRescheduled: Bool
}

nonisolated extension CalendarEventChip {
    /// Expands events into per-day chips clamped to `window`, indexed by day.
    ///
    /// Ordering is settled here, once: all-day events first, then by start,
    /// title, and id. That is list order, not a time axis — the grid stacks
    /// chips and never positions them by time within a day. Doing it at
    /// expansion time means each day's bucket inherits the order and the view
    /// re-sorts nothing, so the grid cannot reshuffle between refreshes.
    static func index(
        _ events: [CalendarEvent],
        in window: Range<Date>,
        calendar: Calendar = .current
    ) -> [Date: [CalendarEventChip]] {
        let ordered = events.sorted { lhs, rhs in
            if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.title != rhs.title { return lhs.title < rhs.title }
            return lhs.id < rhs.id
        }

        var index: [Date: [CalendarEventChip]] = [:]
        for event in ordered {
            for chip in chips(for: event, in: window, calendar: calendar) {
                index[chip.day, default: []].append(chip)
            }
        }
        return index
    }

    /// The chips one event contributes, one per covered day inside `window`.
    static func chips(
        for event: CalendarEvent,
        in window: Range<Date>,
        calendar: Calendar = .current
    ) -> [CalendarEventChip] {
        let firstDay = calendar.startOfDay(for: event.start)
        var lastDay = calendar.startOfDay(for: event.end)
        // `end` is exclusive, so an event finishing exactly at midnight belongs
        // to the previous day and must not light up the next one.
        if lastDay > firstDay, lastDay == event.end {
            lastDay = calendar.date(byAdding: .day, value: -1, to: lastDay) ?? firstDay
        }
        if lastDay < firstDay { lastDay = firstDay }

        // The window's exclusive upper bound is a start-of-day, so the last day
        // actually on screen is the day before it.
        let windowFirst = calendar.startOfDay(for: window.lowerBound)
        guard let windowLast = calendar.date(
            byAdding: .day,
            value: -1,
            to: calendar.startOfDay(for: window.upperBound)
        ) else { return [] }

        let from = max(firstDay, windowFirst)
        let through = min(lastDay, windowLast)
        guard from <= through else { return [] }

        var chips: [CalendarEventChip] = []
        var day = from
        while day <= through {
            chips.append(CalendarEventChip(
                id: "\(event.id)|\(dayKey(day, calendar: calendar))",
                title: event.title,
                day: day,
                startTime: (event.isAllDay || day > firstDay) ? nil : event.start,
                endTime: (event.isAllDay || day > firstDay) ? nil : event.end,
                isAllDay: event.isAllDay,
                continuesFromPreviousDay: day > firstDay,
                continuesToNextDay: day < lastDay,
                location: event.location,
                organizer: event.organizer,
                calendarName: event.calendarName,
                isRecurring: event.isRecurring,
                isRescheduled: event.isRescheduled
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return chips
    }

    /// Calendar-day identity for the chip id. Derived from components rather
    /// than the `Date` so two runs in different time zones cannot disagree
    /// about which day a chip belongs to.
    private static func dayKey(_ day: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
}
