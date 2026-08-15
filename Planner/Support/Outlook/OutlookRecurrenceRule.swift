import Foundation

/// Which days of the week a rule applies to.
///
/// Bit 0 is Sunday, matching both Outlook's `day of week` record and
/// `Calendar`'s `.weekday` component (1 = Sunday), so no re-indexing is needed
/// anywhere between the two.
nonisolated struct DayMask: OptionSet, Hashable, Sendable {
    let rawValue: Int

    init(rawValue: Int) { self.rawValue = rawValue }

    static let sunday = DayMask(rawValue: 1 << 0)
    static let monday = DayMask(rawValue: 1 << 1)
    static let tuesday = DayMask(rawValue: 1 << 2)
    static let wednesday = DayMask(rawValue: 1 << 3)
    static let thursday = DayMask(rawValue: 1 << 4)
    static let friday = DayMask(rawValue: 1 << 5)
    static let saturday = DayMask(rawValue: 1 << 6)

    static let weekdays: DayMask = [.monday, .tuesday, .wednesday, .thursday, .friday]
    static let weekends: DayMask = [.saturday, .sunday]
    static let allDays: DayMask = [.sunday, .monday, .tuesday, .wednesday,
                                   .thursday, .friday, .saturday]

    /// `weekday` uses `Calendar`'s convention: 1 = Sunday … 7 = Saturday.
    func contains(weekday: Int) -> Bool {
        guard (1...7).contains(weekday) else { return false }
        return contains(DayMask(rawValue: 1 << (weekday - 1)))
    }

    static func single(weekday: Int) -> DayMask {
        guard (1...7).contains(weekday) else { return [] }
        return DayMask(rawValue: 1 << (weekday - 1))
    }
}

/// A normalized Outlook recurrence rule.
///
/// Outlook's scripting interface does not expand a series: it exposes one
/// master sitting at the series' **first** occurrence plus one exception per
/// individually moved or cancelled slot. Everything downstream of this type
/// exists to replay the rule locally.
nonisolated struct OutlookRecurrenceRule: Hashable, Sendable {
    enum Pattern: Hashable, Sendable {
        case daily
        case weekly
        case relativeMonthly
        case absoluteMonthly
        case relativeYearly
        case absoluteYearly
        /// A pattern this build does not model. Still yields the first
        /// occurrence — a series we cannot expand is better represented by one
        /// real event than by nothing.
        case unknown

        /// ScriptingBridge hands enum properties back as four-character codes
        /// wrapped in `NSAppleEventDescriptor`, not as the readable strings JXA
        /// produces, so the mapping is by code.
        init(outlookCode: String?) {
            switch outlookCode {
            case "eRdp": self = .daily
            case "eRwp": self = .weekly
            case "eRrm": self = .relativeMonthly
            case "eRam": self = .absoluteMonthly
            case "eRry": self = .relativeYearly
            case "eRay": self = .absoluteYearly
            default: self = .unknown
            }
        }
    }

    enum End: Hashable, Sendable {
        case never
        /// Outlook writes this as a UTC midnight, so it needs the half-day
        /// nudge before its calendar day can be trusted. See `seriesEndBound`.
        case on(Date)
        case after(Int)

        static func code(_ outlookCode: String?, data: Any?) -> End {
            switch outlookCode {
            case "eEDt":
                return (data as? Date).map(End.on) ?? .never
            case "eENt":
                if let count = data as? Int, count > 0 { return .after(count) }
                if let number = data as? NSNumber, number.intValue > 0 { return .after(number.intValue) }
                return .never
            default:
                return .never
            }
        }
    }

    var pattern: Pattern
    /// Every `interval` days / weeks / months / years. Always at least 1.
    var interval: Int
    /// 1…4 pick that occurrence of the weekday in the month; **5 means "last"**,
    /// and anything past the end of the month clamps to the last match.
    var ordinal: Int?
    /// 1 = January.
    var monthNumber: Int?
    var dayOfMonth: Int?
    /// `nil` means "derive from the anchor" — an empty mask is not a rule that
    /// never fires, it is a rule that did not bother to say.
    var daysOfWeek: DayMask?
    var end: End

    init(
        pattern: Pattern,
        interval: Int = 1,
        ordinal: Int? = nil,
        monthNumber: Int? = nil,
        dayOfMonth: Int? = nil,
        daysOfWeek: DayMask? = nil,
        end: End = .never
    ) {
        self.pattern = pattern
        self.interval = max(1, interval)
        self.ordinal = ordinal
        self.monthNumber = monthNumber
        self.dayOfMonth = dayOfMonth
        self.daysOfWeek = (daysOfWeek?.isEmpty ?? true) ? nil : daysOfWeek
        self.end = end
    }
}

/// One record as Outlook reports it, after decoding but before any expansion.
///
/// The same shape covers all three kinds the source fetches — plain events,
/// recurring masters, and exceptions — because they differ only in which
/// optional fields are populated.
nonisolated struct OutlookRawEvent: Hashable, Sendable {
    /// Outlook's numeric record id, as a string.
    let id: String
    /// iCalendar UID. Shared by a master and its exceptions; the join key.
    let uid: String?
    let subject: String
    let location: String?
    let organizer: String?
    let isAllDay: Bool
    let start: Date
    /// Exclusive.
    let end: Date
    /// Masters only.
    let rule: OutlookRecurrenceRule?
    /// Masters only: deleted occurrences, which exist nowhere else.
    let exDates: [Date]
    /// Exceptions only: the series slot this record replaces.
    let recurrenceId: Date?

    init(
        id: String,
        uid: String? = nil,
        subject: String,
        location: String? = nil,
        organizer: String? = nil,
        isAllDay: Bool = false,
        start: Date,
        end: Date,
        rule: OutlookRecurrenceRule? = nil,
        exDates: [Date] = [],
        recurrenceId: Date? = nil
    ) {
        self.id = id
        self.uid = uid
        self.subject = subject
        self.location = location
        self.organizer = organizer
        self.isAllDay = isAllDay
        self.start = start
        self.end = end
        self.rule = rule
        self.exDates = exDates
        self.recurrenceId = recurrenceId
    }
}

/// Everything one fetch returns. Masters and exceptions are deliberately **not**
/// bounded by the window: a series that began years ago still occurs inside it,
/// and an occurrence moved *out* of it must still suppress the slot it vacated.
nonisolated struct OutlookSnapshot: Hashable, Sendable {
    let calendarName: String?
    let plain: [OutlookRawEvent]
    let masters: [OutlookRawEvent]
    let exceptions: [OutlookRawEvent]

    init(
        calendarName: String? = nil,
        plain: [OutlookRawEvent] = [],
        masters: [OutlookRawEvent] = [],
        exceptions: [OutlookRawEvent] = []
    ) {
        self.calendarName = calendarName
        self.plain = plain
        self.masters = masters
        self.exceptions = exceptions
    }
}
