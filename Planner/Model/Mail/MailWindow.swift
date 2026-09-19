import Foundation

/// How far back Recent Mail reaches.
///
/// Rolling and anchored on **today**, not on anything the user scrolled to:
/// Recent Mail is a sweep, not an archive. Messages leave it by ageing out;
/// Hidden uses the same window and is not an archive either.
nonisolated enum MailWindow {
    static let defaultDays = 3
    static let minimumDays = 1
    static let maximumDays = 30

    /// The lengths the window can be set to, and the entries of the menu that
    /// sets it. Discrete rather than every number up to the maximum: a month
    /// is worth offering — a slow correspondence, a bill that arrives on the
    /// 1st — but nobody reaches for "Last 23 Days", and thirty menu rows to
    /// pick from would be the cost of pretending otherwise.
    static let choices = [1, 2, 3, 4, 5, 6, 7, maximumDays]

    static let daysDefaultsKey = "mail.windowDays"

    /// Snaps a day count onto `choices`, so the menu can always show where the
    /// window is. Downwards, because a value that is not one of them — a
    /// hand-edited default, a setting written by an older build — should
    /// narrow the sweep rather than widen it behind the user's back.
    static func choice(for days: Int) -> Int {
        let clamped = min(maximumDays, max(minimumDays, days))
        return choices.last { $0 <= clamped } ?? minimumDays
    }

    /// Clamped rather than validated: a stale or hand-edited `defaults` value
    /// should narrow the window, never fail the fetch.
    static func days(from defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.integer(forKey: daysDefaultsKey)
        guard stored != 0 else { return defaultDays }
        return choice(for: stored)
    }

    /// Closed-open: `[startOfDay(today − (days − 1)), startOfDay(tomorrow))`.
    ///
    /// Whole days at both ends, so "the last 3 days" means three calendar days
    /// including today rather than a 72-hour sliding tail — the former is what
    /// a date-grouped list can label.
    static func current(
        days: Int = defaultDays,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Range<Date> {
        let clamped = min(maximumDays, max(minimumDays, days))
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(clamped - 1), to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        return start..<max(end, start)
    }

    /// The day a message drops out of the window, for the reader's expiry
    /// banner. A message received on day *d* survives through `d + days`, so it
    /// is gone on the morning after that.
    static func expiryDay(
        for receivedAt: Date,
        days: Int,
        calendar: Calendar = .current
    ) -> Date? {
        let clamped = min(maximumDays, max(minimumDays, days))
        return calendar.date(
            byAdding: .day,
            value: clamped,
            to: calendar.startOfDay(for: receivedAt)
        )
    }
}
