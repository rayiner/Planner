import Foundation

/// Merges the three record kinds Outlook exposes into one ordered list of
/// events, expanding recurring series along the way.
nonisolated enum OutlookAgenda {
    /// Outlook has no "cancelled" flag on an event. A cancelled occurrence is
    /// an exception whose subject the server rewrote, so the prefix is the only
    /// signal available — and it is localized, so a non-English Outlook will
    /// list cancelled occurrences instead of hiding them. Known limitation,
    /// inherited deliberately rather than replaced with a worse heuristic.
    static let cancelledPrefixes = ["cancelled:", "canceled:"]

    static func isCancelled(_ subject: String) -> Bool {
        let lowered = subject.lowercased()
        return cancelledPrefixes.contains { lowered.hasPrefix($0) }
    }

    /// Builds the events overlapping `window`.
    ///
    /// A slot covered by an exception is dropped from the expansion, so a moved
    /// meeting is listed once — at its real time — and a cancelled one not at
    /// all.
    static func build(
        _ snapshot: OutlookSnapshot,
        in window: Range<Date>,
        calendar: Calendar
    ) -> [CalendarEvent] {
        var events: [CalendarEvent] = []

        for plain in snapshot.plain where overlaps(plain.start, plain.end, window, calendar: calendar) {
            events.append(event(
                from: plain,
                start: plain.start,
                end: plain.end,
                calendarName: snapshot.calendarName,
                isRecurring: false,
                isRescheduled: false,
                calendar: calendar
            ))
        }

        // Exceptions carry their master's UID, so this join costs nothing —
        // asking each exception for `master.id` would be one Apple event apiece.
        var slotsByUID: [String: [Date]] = [:]
        for exception in snapshot.exceptions {
            guard let uid = exception.uid, let recurrenceId = exception.recurrenceId else { continue }
            slotsByUID[uid, default: []].append(recurrenceId)
        }

        for master in snapshot.masters {
            // An all-day master shares the UTC-midnight storage convention that
            // `allDaySpan` repairs for plain events — but a series must be
            // repaired *before* expansion. An anchor rendered as 8pm the
            // previous local day generates every slot on the wrong weekday or
            // day-of-month, and the per-occurrence nudge then rounds them all
            // one day late. Recurrence ids and EXDATEs are stored the same
            // way, so claims get the same nudge and keep matching exactly.
            let expansionMaster = master.isAllDay
                ? nudgedAllDayMaster(master, calendar: calendar)
                : master
            var claims = (master.uid.flatMap { slotsByUID[$0] } ?? []) + master.exDates
            if master.isAllDay {
                claims = claims.map { allDayBoundary($0, calendar: calendar) }
            }
            let expanded = OutlookRecurrence.expand(master: expansionMaster, in: window, calendar: calendar)
            for occurrence in OutlookExceptions.removeSuperseded(expanded, claims: claims) {
                events.append(event(
                    from: master,
                    start: occurrence.start,
                    end: occurrence.end,
                    calendarName: snapshot.calendarName,
                    isRecurring: true,
                    isRescheduled: false,
                    calendar: calendar
                ))
            }
        }

        for exception in snapshot.exceptions {
            guard !isCancelled(exception.subject) else { continue }
            guard overlaps(exception.start, exception.end, window, calendar: calendar) else { continue }
            events.append(event(
                from: exception,
                start: exception.start,
                end: exception.end,
                calendarName: snapshot.calendarName,
                isRecurring: true,
                isRescheduled: true,
                calendar: calendar
            ))
        }

        return events.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
            if lhs.title != rhs.title { return lhs.title < rhs.title }
            return lhs.id < rhs.id
        }
    }

    // MARK: - Internals

    /// A copy of an all-day master whose boundaries are snapped onto the local
    /// days they mean, so the recurrence engine expands from the intended
    /// first day. Occurrences then land at local midnight, which makes the
    /// per-occurrence `allDaySpan` in `event(from:)` a no-op for them.
    private static func nudgedAllDayMaster(
        _ master: OutlookRawEvent,
        calendar: Calendar
    ) -> OutlookRawEvent {
        let span = allDaySpan(start: master.start, end: master.end, calendar: calendar)
        return OutlookRawEvent(
            id: master.id,
            uid: master.uid,
            subject: master.subject,
            location: master.location,
            organizer: master.organizer,
            isAllDay: true,
            start: span.start,
            end: span.end,
            rule: master.rule,
            exDates: master.exDates,
            recurrenceId: master.recurrenceId
        )
    }

    private static func event(
        from raw: OutlookRawEvent,
        start: Date,
        end: Date,
        calendarName: String?,
        isRecurring: Bool,
        isRescheduled: Bool,
        calendar: Calendar
    ) -> CalendarEvent {
        let span = raw.isAllDay
            ? allDaySpan(start: start, end: end, calendar: calendar)
            : (start: start, end: max(end, start))

        return CalendarEvent(
            id: identifier(for: raw, start: span.start),
            title: raw.subject,
            start: span.start,
            end: span.end,
            isAllDay: raw.isAllDay,
            location: raw.location?.isEmpty == false ? raw.location : nil,
            organizer: raw.organizer?.isEmpty == false ? raw.organizer : nil,
            calendarName: calendarName,
            isRecurring: isRecurring,
            isRescheduled: isRescheduled
        )
    }

    /// Stable across refreshes: the series (or record) plus the occurrence, so
    /// two occurrences of one weekly meeting never collide and the same
    /// occurrence keeps its identity between fetches.
    private static func identifier(for raw: OutlookRawEvent, start: Date) -> String {
        "outlook|\(raw.uid ?? raw.id)|\(Int(start.timeIntervalSince1970))"
    }

    /// Snaps an all-day event onto the calendar days it actually covers,
    /// keeping the end **exclusive**.
    ///
    /// Outlook stores all-day boundaries as UTC midnight, so an event on 31
    /// July arrives as 30 July 20:00 in US Eastern and would otherwise be
    /// listed a day early. Nudging forward half a day before taking the
    /// calendar date recovers the intended day under either storage convention
    /// and never moves a boundary already at local midnight.
    ///
    /// CalendarList stores the *inclusive* last day here and its renderers
    /// convert back; Planner keeps `CalendarEvent.end` exclusive throughout, so
    /// day expansion has one rule rather than two.
    static func allDaySpan(
        start: Date,
        end: Date,
        calendar: Calendar
    ) -> (start: Date, end: Date) {
        let first = allDayBoundary(start, calendar: calendar)
        let boundary = allDayBoundary(end, calendar: calendar)
        let exclusiveEnd = boundary > first
            ? boundary
            : (calendar.date(byAdding: .day, value: 1, to: first) ?? first)
        return (first, exclusiveEnd)
    }

    static func allDayBoundary(_ date: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: date.addingTimeInterval(12 * 3600))
    }

    private static func overlaps(
        _ start: Date,
        _ end: Date,
        _ window: Range<Date>,
        calendar: Calendar
    ) -> Bool {
        // Overlap, not containment: an event that began before the window but
        // is still running belongs on screen.
        max(end, start) >= window.lowerBound && start < window.upperBound
    }
}
