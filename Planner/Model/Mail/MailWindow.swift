import Foundation

/// How far back Recent Mail reaches.
///
/// Rolling and anchored on **today**, not on anything the user scrolled to:
/// Recent Mail is a sweep, not an archive. Messages leave it by ageing out, and
/// the only way to keep one is to save it into a folder — which is the whole
/// point of the feature.
nonisolated enum MailWindow {
    static let defaultDays = 3
    static let minimumDays = 1
    static let maximumDays = 7

    static let daysDefaultsKey = "mail.windowDays"

    /// Clamped rather than validated: a stale or hand-edited `defaults` value
    /// should narrow the window, never fail the fetch.
    static func days(from defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.integer(forKey: daysDefaultsKey)
        guard stored != 0 else { return defaultDays }
        return min(maximumDays, max(minimumDays, stored))
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
