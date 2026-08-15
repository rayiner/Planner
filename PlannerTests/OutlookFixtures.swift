import Foundation
@testable import Planner

/// Shared scaffolding for the Outlook expansion tests.
///
/// The cases these support are ported from CalendarList's `recurrence.test.js`,
/// `exdates.test.js` and `agenda.test.js`, which were validated against a live
/// Exchange calendar. Where a Swift result disagrees with the JS one, the JS is
/// right until proven otherwise.
enum OutlookFixtures {
    /// Pinned to US Eastern rather than the machine's zone: several cases are
    /// about DST and about Outlook's UTC-midnight all-day storage, both of
    /// which are silently untested in UTC.
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    static func at(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0,
        _ minute: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: 0
        ))!
    }

    /// Outlook's day-of-week record is Sunday-first; the JS fixtures write it as
    /// a bit string like `"0010000"` (Tuesday), so the ported cases can keep
    /// their original notation.
    static func mask(_ bits: String) -> DayMask {
        var mask = DayMask()
        for (index, character) in bits.enumerated() where character == "1" {
            mask.insert(DayMask(rawValue: 1 << index))
        }
        return mask
    }

    static func master(
        _ start: Date,
        _ rule: OutlookRecurrenceRule,
        durationMinutes: Double = 30,
        uid: String = "m1",
        subject: String = "test",
        isAllDay: Bool = false,
        exDates: [Date] = []
    ) -> OutlookRawEvent {
        OutlookRawEvent(
            id: uid,
            uid: uid,
            subject: subject,
            isAllDay: isAllDay,
            start: start,
            end: start.addingTimeInterval(durationMinutes * 60),
            rule: rule,
            exDates: exDates
        )
    }

    static func plain(
        _ start: Date,
        _ end: Date,
        subject: String = "Lunch",
        id: String = "p1",
        isAllDay: Bool = false
    ) -> OutlookRawEvent {
        OutlookRawEvent(id: id, uid: id, subject: subject, isAllDay: isAllDay, start: start, end: end)
    }

    static func exception(
        recurrenceId: Date,
        start: Date,
        end: Date,
        subject: String = "Standup",
        uid: String = "m1",
        id: String = "x1"
    ) -> OutlookRawEvent {
        OutlookRawEvent(
            id: id,
            uid: uid,
            subject: subject,
            start: start,
            end: end,
            recurrenceId: recurrenceId
        )
    }

    /// `yyyy-MM-dd`, matching the JS fixtures' `starts()` helper.
    static func days(_ dates: [Date]) -> [String] {
        dates.map { date in
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        }
    }

    static func days(_ occurrences: [OutlookRecurrence.Occurrence]) -> [String] {
        days(occurrences.map(\.start))
    }

    static func days(_ events: [CalendarEvent]) -> [String] {
        days(events.map(\.start))
    }

    static func expand(
        _ master: OutlookRawEvent,
        from start: Date,
        to end: Date
    ) -> [OutlookRecurrence.Occurrence] {
        OutlookRecurrence.expand(master: master, in: start..<end, calendar: calendar)
    }
}
