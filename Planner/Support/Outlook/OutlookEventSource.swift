import Foundation

nonisolated struct OlSyncEventHit: Sendable {
    let eventID: Int64
    let recordID: Int64?
    let icalUID: String?
    let accountUID: Int64?
    let startUTC: Int64
    let endUTC: Int64
    let allDay: Bool
    let subject: String
    let location: String?
    let organizer: String?
    let folder: String?
    let isRecurring: Bool
    let isRescheduled: Bool

    init?(_ raw: [String: Any]) {
        guard let eventID = OlSyncMailProtocol.int64(raw["event_id"]),
              let startUTC = OlSyncMailProtocol.int64(raw["start_utc"]),
              let endUTC = OlSyncMailProtocol.int64(raw["end_utc"])
        else { return nil }
        self.eventID = eventID
        recordID = OlSyncMailProtocol.int64(raw["record_id"])
        icalUID = raw["ical_uid"] as? String
        accountUID = OlSyncMailProtocol.int64(raw["account_uid"])
        self.startUTC = startUTC
        self.endUTC = endUTC
        allDay = OlSyncMailProtocol.bool(raw["all_day"])
        subject = raw["subject"] as? String ?? ""
        location = raw["location"] as? String
        organizer = raw["organizer"] as? String
        folder = raw["folder"] as? String
        isRecurring = OlSyncMailProtocol.bool(raw["is_recurring"])
        isRescheduled = OlSyncMailProtocol.bool(raw["is_rescheduled"])
    }
}

nonisolated enum OlSyncEventProtocol {
    static func event(
        from hit: OlSyncEventHit,
        fallbackCalendarName: String,
        calendar: Calendar
    ) -> CalendarEvent {
        var start = Date(timeIntervalSince1970: TimeInterval(hit.startUTC))
        var end = Date(timeIntervalSince1970: TimeInterval(hit.endUTC))
        if hit.allDay {
            let span = allDaySpan(start: start, end: end, calendar: calendar)
            start = span.start
            end = span.end
        } else {
            end = max(end, start)
        }

        let externalID = nonempty(hit.icalUID)
            ?? hit.recordID.map(String.init)
            ?? String(hit.eventID)
        return CalendarEvent(
            id: "outlook|\(externalID)|\(Int(start.timeIntervalSince1970))",
            title: hit.subject,
            start: start,
            end: end,
            isAllDay: hit.allDay,
            location: nonempty(hit.location),
            organizer: nonempty(hit.organizer),
            calendarName: calendarName(from: hit.folder) ?? fallbackCalendarName,
            isRecurring: hit.isRecurring || hit.isRescheduled,
            isRescheduled: hit.isRescheduled
        )
    }

    private static func calendarName(from path: String?) -> String? {
        nonempty(path?.split(separator: "/").last.map(String.init))
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    static func allDaySpan(
        start: Date,
        end: Date,
        calendar: Calendar
    ) -> (start: Date, end: Date) {
        let first = calendar.startOfDay(for: start.addingTimeInterval(12 * 3_600))
        let boundary = calendar.startOfDay(for: end.addingTimeInterval(12 * 3_600))
        let exclusiveEnd = boundary > first
            ? boundary
            : (calendar.date(byAdding: .day, value: 1, to: first) ?? first)
        return (first, exclusiveEnd)
    }
}

/// Reads Outlook calendar occurrences through the same `olsyncmail` daemon
/// session as Recent Mail. Outlook need not be running; the helper reads its
/// local profile and maintains Planner's derived index.
nonisolated final class OlSyncEventSource: CalendarEventSource, @unchecked Sendable {
    struct Configuration: Sendable, Equatable {
        /// `nil` selects the first account represented in the requested
        /// calendar window, preserving Planner's previous default.
        var accountName: String?
        var calendarName: String

        static let defaultCalendarName = "Calendar"
        static let accountDefaultsKey = "events.accountName"
        static let calendarDefaultsKey = "events.calendarName"

        static func fromDefaults(_ defaults: UserDefaults = .standard) -> Configuration {
            let account = defaults.string(forKey: accountDefaultsKey)?
                .trimmingCharacters(in: .whitespaces)
            let calendar = defaults.string(forKey: calendarDefaultsKey)?
                .trimmingCharacters(in: .whitespaces)
            return Configuration(
                accountName: (account?.isEmpty ?? true) ? nil : account,
                calendarName: (calendar?.isEmpty ?? true) ? defaultCalendarName : calendar!
            )
        }
    }

    let sourceID = "outlook"
    var displayName: String { configuration.calendarName }

    private let configuration: Configuration
    private let session: OlSyncOutlookSession?
    private let calendar: Calendar

    init(
        configuration: Configuration = .fromDefaults(),
        session: OlSyncOutlookSession? = nil,
        calendar: Calendar = .current
    ) {
        self.configuration = configuration
        self.session = session ?? OlSyncOutlookSession()
        self.calendar = calendar
    }

    func events(in range: Range<Date>, userInitiated _: Bool) async throws -> [CalendarEvent] {
        guard let session else { throw OlSyncMailError.helperMissing }
        try await session.syncEvents(in: range)
        let since = Int64(range.lowerBound.timeIntervalSince1970)
        let until = Int64(range.upperBound.timeIntervalSince1970)
        var hits = try await session.events(
            since: since,
            until: until,
            account: configuration.accountName,
            calendar: configuration.calendarName
        )

        // The old source selected Outlook's first Exchange account when no
        // account was configured. A stable account UID is the daemon-side
        // equivalent and prevents same-named calendars from being merged.
        if configuration.accountName == nil,
           let accountUID = hits.compactMap(\.accountUID).min() {
            hits = hits.filter { $0.accountUID == accountUID }
        }

        return hits.map {
            OlSyncEventProtocol.event(
                from: $0,
                fallbackCalendarName: configuration.calendarName,
                calendar: calendar
            )
        }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
            if $0.title != $1.title { return $0.title < $1.title }
            return $0.id < $1.id
        }
    }

}
