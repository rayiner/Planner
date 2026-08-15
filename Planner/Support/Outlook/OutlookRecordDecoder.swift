import Foundation

/// Turns the property dictionaries ScriptingBridge returns into Planner's own
/// types.
///
/// Pure and synchronous by design: this is where all the fiddly Outlook-shaped
/// knowledge lives, so it can be tested against captured payloads without an
/// Apple event anywhere near it. `OutlookEventSource` is then thin enough to be
/// reviewed by eye.
nonisolated enum OutlookRecordDecoder {
    // MARK: - Scalars

    /// `NSNull` is a real value here, not a missing key: Outlook returns it for
    /// an event with no location. Empty strings collapse to `nil` too, since an
    /// empty location is the same as none.
    static func string(_ value: Any?) -> String? {
        guard let value, !(value is NSNull), let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func date(_ value: Any?) -> Date? {
        guard let value, !(value is NSNull) else { return nil }
        return value as? Date
    }

    static func int(_ value: Any?) -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        return (value as? NSNumber)?.intValue
    }

    static func bool(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        return (value as? NSNumber)?.boolValue ?? false
    }

    /// Record ids arrive as `NSNumber`, so string interpolation would produce
    /// something like `Optional(2665)`.
    static func identifier(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber { return number.stringValue }
        return (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The `account` property on a calendar. Outlook's "On My Computer"
    /// calendars store `NSNull` here; `NSNull.value(forKey:)` raises an
    /// exception Swift cannot catch, so the null must be rejected first.
    static func accountID(_ value: Any?) -> NSNumber? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber { return number }
        if let record = value as? [AnyHashable: Any] {
            return record[OutlookScripting.Key.id] as? NSNumber
        }
        return (value as AnyObject).value(forKey: OutlookScripting.Key.id) as? NSNumber
    }

    /// Enum-valued scripting properties arrive as `NSAppleEventDescriptor`, not
    /// as the readable strings JXA hands back. The four-character code inside
    /// is the actual value.
    static func fourCharCode(_ value: Any?) -> String? {
        guard let descriptor = value as? NSAppleEventDescriptor else { return nil }
        var code = descriptor.enumCodeValue
        if code == 0 { code = descriptor.typeCodeValue }
        guard code != 0 else { return nil }
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        return String(bytes: bytes, encoding: .macOSRoman)
    }

    // MARK: - Recurrence

    static func dayMask(_ value: Any?) -> DayMask? {
        guard let record = value as? [AnyHashable: Any] else { return nil }
        var mask = DayMask()
        for (index, key) in OutlookScripting.DayKey.ordered.enumerated()
        where bool(record[key]) {
            mask.insert(DayMask(rawValue: 1 << index))
        }
        // Not observed in practice — Outlook expands them — but declared in the
        // sdef, so honour them if they ever show up.
        if bool(record[OutlookScripting.DayKey.allDays]) { mask.formUnion(.allDays) }
        if bool(record[OutlookScripting.DayKey.weekdays]) { mask.formUnion(.weekdays) }
        if bool(record[OutlookScripting.DayKey.weekends]) { mask.formUnion(.weekends) }
        return mask.isEmpty ? nil : mask
    }

    static func rule(_ value: Any?) -> OutlookRecurrenceRule? {
        guard let record = value as? [AnyHashable: Any] else { return nil }
        typealias Keys = OutlookScripting.RecurrenceKey

        let end = endRule(record[Keys.endDate])
        return OutlookRecurrenceRule(
            pattern: OutlookRecurrenceRule.Pattern(
                outlookCode: fourCharCode(record[Keys.recurrenceType])
            ),
            interval: int(record[Keys.occurrenceInterval]) ?? 1,
            ordinal: int(record[Keys.ordinal]),
            monthNumber: int(record[Keys.monthNumber]),
            dayOfMonth: int(record[Keys.dayOfMonth]),
            daysOfWeek: dayMask(record[Keys.daysOfWeek]),
            end: end
        )
    }

    static func endRule(_ value: Any?) -> OutlookRecurrenceRule.End {
        guard let record = value as? [AnyHashable: Any] else { return .never }
        let code = fourCharCode(record[OutlookScripting.EndKey.endType])
        let data = record[OutlookScripting.EndKey.data]
        // `data` carries a date when the series ends on one and a count when it
        // ends after a fixed number, so its type depends on the code.
        switch code {
        case "eEDt":
            return date(data).map(OutlookRecurrenceRule.End.on) ?? .never
        case "eENt":
            guard let count = int(data), count > 0 else { return .never }
            return .after(count)
        default:
            return .never
        }
    }

    // MARK: - Events

    /// Returns `nil` for a record missing the fields every event must have,
    /// rather than inventing them. A malformed record is skipped; it never
    /// fails the whole refresh.
    static func rawEvent(
        _ properties: [AnyHashable: Any],
        calendar: Calendar
    ) -> OutlookRawEvent? {
        typealias Keys = OutlookScripting.Key
        guard let id = identifier(properties[Keys.id]),
              let start = date(properties[Keys.startTime])
        else { return nil }

        let ics = (properties[Keys.icalendarData] as? String) ?? ""
        let isRecurringMaster = bool(properties[Keys.isRecurring])

        return OutlookRawEvent(
            id: id,
            uid: ics.isEmpty ? nil : ICalendar.uid(in: ics),
            subject: string(properties[Keys.subject]) ?? "(No subject)",
            location: string(properties[Keys.location]),
            organizer: string(properties[Keys.organizer]),
            isAllDay: bool(properties[Keys.allDayFlag]),
            start: start,
            // A zero-length event is legal; a missing end is not worth dropping
            // the record over.
            end: date(properties[Keys.endTime]) ?? start,
            rule: rule(properties[Keys.recurrence]),
            // Only a master's EXDATEs matter, and parsing iCalendar text for
            // every plain event would be wasted work.
            exDates: isRecurringMaster ? ICalendar.exDates(in: ics, calendar: calendar) : [],
            recurrenceId: date(properties[Keys.recurrenceId])
        )
    }

    static func rawEvents(
        _ payload: [[AnyHashable: Any]],
        calendar: Calendar
    ) -> [OutlookRawEvent] {
        payload.compactMap { rawEvent($0, calendar: calendar) }
    }
}
