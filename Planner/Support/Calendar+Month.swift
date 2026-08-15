import Foundation

/// Pure date arithmetic, so `nonisolated`: the event window is computed off the
/// main actor before the results ever reach the UI, and the project's default
/// `MainActor` isolation would otherwise make these unreachable from there.
nonisolated extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date))!
    }

    func endOfMonth(for date: Date) -> Date {
        self.date(byAdding: .month, value: 1, to: startOfMonth(for: date))!
    }

    func monthYearString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = self
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter.string(from: date)
    }

    // MARK: - Weeks

    /// The week grid pins Monday to the top and collapses Sat+Sun into one row,
    /// so weeks always start on Monday regardless of the locale's `firstWeekday`.
    /// A locale-driven start would put the weekend in the middle of the column.
    func startOfWeek(for date: Date) -> Date {
        let day = startOfDay(for: date)
        var offset = component(.weekday, from: day) - 2   // weekday 1 = Sunday
        if offset < 0 { offset += 7 }                     // Sunday trails the week
        return self.date(byAdding: .day, value: -offset, to: day)!
    }

    /// `count` consecutive Mondays starting at `weekStart`.
    func weekStarts(from weekStart: Date, count: Int) -> [Date] {
        let first = startOfWeek(for: weekStart)
        return (0..<max(0, count)).map {
            self.date(byAdding: .day, value: $0 * 7, to: first)!
        }
    }

    /// The seven days of a week, Monday first.
    func days(inWeekStartingAt weekStart: Date) -> [Date] {
        let first = startOfWeek(for: weekStart)
        return (0..<7).map { startOfDay(for: self.date(byAdding: .day, value: $0, to: first)!) }
    }

    /// Exclusive end of the visible range: the Monday after the last shown week.
    func endOfWeeks(from weekStart: Date, count: Int) -> Date {
        date(byAdding: .day, value: max(0, count) * 7, to: startOfWeek(for: weekStart))!
    }

    /// Full month name for the header that marks a month's first day, e.g.
    /// "September". Rendered uppercase by the calendar; kept in natural case
    /// here so the string stays usable for accessibility.
    func monthName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = self
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMM")
        return formatter.string(from: date)
    }

    /// The visible span split so the header can weight them differently:
    /// ("Aug 10 – Sep 6", "2026").
    func weekRangeComponents(from weekStart: Date, count: Int) -> (span: String, year: String) {
        let first = startOfWeek(for: weekStart)
        let last = date(byAdding: .day, value: max(1, count) * 7 - 1, to: first)!

        let dayMonth = DateFormatter()
        dayMonth.calendar = self
        dayMonth.locale = locale
        dayMonth.timeZone = timeZone
        dayMonth.setLocalizedDateFormatFromTemplate("MMM d")

        let dayOnly = DateFormatter()
        dayOnly.calendar = self
        dayOnly.locale = locale
        dayOnly.timeZone = timeZone
        dayOnly.setLocalizedDateFormatFromTemplate("d")

        let sameMonth = isDate(first, equalTo: last, toGranularity: .month)
        let end = sameMonth ? dayOnly.string(from: last) : dayMonth.string(from: last)
        return ("\(dayMonth.string(from: first)) – \(end)", String(component(.year, from: last)))
    }

    /// Title for the visible span, e.g. "Aug 10 – Sep 6, 2026".
    func weekRangeString(from weekStart: Date, count: Int) -> String {
        let parts = weekRangeComponents(from: weekStart, count: count)
        return "\(parts.span), \(parts.year)"
    }

    /// A deadline is overdue once its day is strictly before today. Completing a
    /// task clears the status; the caller decides what to do with `isCompleted`.
    func isOverdue(_ deadline: Date, now: Date = Date()) -> Bool {
        startOfDay(for: deadline) < startOfDay(for: now)
    }

    /// Short relative label for a deadline: "Overdue", "Today", "Tomorrow", or nil.
    func relativeDeadlineLabel(for deadline: Date, now: Date = Date()) -> String? {
        let day = startOfDay(for: deadline)
        let today = startOfDay(for: now)
        if day < today { return "Overdue" }
        if day == today { return "Today" }
        if day == self.date(byAdding: .day, value: 1, to: today)! { return "Tomorrow" }
        return nil
    }

    /// Compact day label for outline rows, e.g. "Aug 21".
    func shortDeadlineString(for deadline: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = self
        formatter.locale = locale
        formatter.timeZone = timeZone
        let sameYear = component(.year, from: deadline) == component(.year, from: Date())
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMM d" : "MMM d yyyy")
        return formatter.string(from: deadline)
    }

    func daysInMonthGrid(for date: Date) -> [Date] {
        let monthStart = startOfMonth(for: date)
        let weekday = component(.weekday, from: monthStart)
        var leading = weekday - firstWeekday
        if leading < 0 { leading += 7 }
        let gridStart = startOfDay(for: self.date(byAdding: .day, value: -leading, to: monthStart)!)
        return (0..<42).map { offset in
            startOfDay(for: self.date(byAdding: .day, value: offset, to: gridStart)!)
        }
    }
}
