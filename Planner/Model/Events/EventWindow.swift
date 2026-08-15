import Foundation

/// How far either side of today external events are pulled.
///
/// Anchored on **today**, not on `visibleWeekStart`: the whole window is
/// fetched in one refresh, so paging the grid inside it costs nothing and does
/// not re-hit a slow source. Days outside it simply show no events — marking
/// every out-of-range cell would be the loudest thing on screen, which is the
/// same argument the weekday gutter settles in §8.1.
nonisolated enum EventWindow {
    static let monthsBack = 2
    static let monthsForward = 3

    /// Closed-open, and snapped outward to whole Monday-started weeks so a
    /// window edge never bisects a visible column.
    static func current(now: Date = Date(), calendar: Calendar = .current) -> Range<Date> {
        let today = calendar.startOfDay(for: now)
        let earliest = calendar.date(byAdding: .month, value: -monthsBack, to: today) ?? today
        let latest = calendar.date(byAdding: .month, value: monthsForward, to: today) ?? today

        let start = calendar.startOfWeek(for: earliest)
        // Exclusive end: the Monday after the week that contains `latest`, so
        // that week is shown whole.
        let end = calendar.date(byAdding: .day, value: 7, to: calendar.startOfWeek(for: latest))
            ?? calendar.startOfWeek(for: latest)
        return start..<max(end, start)
    }
}
