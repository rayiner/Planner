import Foundation

/// The Outlook scripting vocabulary Planner depends on, in one place.
///
/// Everything is dispatched dynamically by name, so these strings **are** the
/// API contract: a typo is a runtime nil rather than a compile error. Keeping
/// them together is what makes the contract reviewable and re-verifiable.
///
/// To check them against a new Outlook build:
///
/// ```sh
/// sdef /Applications/Microsoft\ Outlook.app > /tmp/Outlook.sdef
/// # then grep the Calendar Suite for the names below
/// ```
///
/// Why dynamic dispatch rather than the usual generated header: `sdp` emits
/// `@interface` declarations whose classes exist only at runtime, so linking a
/// Swift binary against them fails outright (`Undefined symbols
/// _OBJC_CLASS_$_Outlook*`). Declaring `@objc` protocols instead does not help
/// either — the object `SBApplication` vends is an `SBScriptableApplication`,
/// which a conformance category on `SBApplication` does not reach, so the
/// protocol cast fails at runtime. Sending by selector is what actually works.
nonisolated enum OutlookScripting {
    static let bundleIdentifier = "com.microsoft.Outlook"

    /// Apple-event timeout, in ticks (1/60 s).
    static let timeoutTicks = 120 * 60

    /// Element collections.
    enum Element {
        static let exchangeAccounts = "exchangeAccounts"
        static let calendars = "calendars"
        static let calendarEvents = "calendarEvents"
    }

    /// The pseudo-property that returns every field of every match in a single
    /// Apple event. Reading fields individually costs ~0.4s *each*; reading
    /// them per object costs ~0.4s *per field per object*.
    static let properties = "properties"

    enum Key {
        static let id = "id"
        static let name = "name"
        static let account = "account"

        static let subject = "subject"
        static let startTime = "startTime"
        static let endTime = "endTime"
        static let location = "location"
        static let organizer = "organizer"
        static let allDayFlag = "allDayFlag"
        static let isRecurring = "isRecurring"
        static let isOccurrence = "isOccurrence"
        static let recurrenceId = "recurrenceId"
        static let recurrence = "recurrence"
        static let icalendarData = "icalendarData"
    }

    /// Keys inside the `recurrence` record.
    ///
    /// `ordinal`, `dayOfMonth` and `monthNumber` are **absent entirely** rather
    /// than null when the pattern does not use them, so every read has to
    /// tolerate a missing key.
    enum RecurrenceKey {
        static let recurrenceType = "recurrenceType"
        static let occurrenceInterval = "occurrenceInterval"
        static let ordinal = "ordinal"
        static let dayOfMonth = "dayOfMonth"
        static let monthNumber = "monthNumber"
        static let daysOfWeek = "daysOfWeek"
        static let startDate = "startDate"
        static let endDate = "endDate"
    }

    /// Keys inside the nested `endDate` record.
    enum EndKey {
        static let endType = "endType"
        static let data = "data"
    }

    /// Keys inside the nested `daysOfWeek` record, in `DayMask` bit order
    /// (Sunday first), which is also `Calendar`'s weekday order.
    ///
    /// The sdef also declares `all days` / `weekdays` / `weekends` aggregates,
    /// but Outlook expands those into the individual flags before handing the
    /// record over — no observed record carried them. They are still read
    /// defensively below, since costing nothing is cheaper than finding out.
    enum DayKey {
        static let ordered = ["sunday", "monday", "tuesday", "wednesday",
                              "thursday", "friday", "saturday"]
        static let allDays = "allDays"
        static let weekdays = "weekdays"
        static let weekends = "weekends"
    }

    /// Predicates for the three `whose` clauses. Each costs a fixed scan of the
    /// calendar regardless of how many events match, so the count of these is
    /// the entire performance story.
    enum Query {
        /// Overlap, not containment: an event already under way still counts.
        static func plain(in range: Range<Date>) -> NSPredicate {
            NSPredicate(
                format: "isRecurring == NO AND isOccurrence == NO AND endTime >= %@ AND startTime <= %@",
                range.lowerBound as NSDate,
                range.upperBound as NSDate
            )
        }

        /// Unbounded on purpose: a master sits at the series' *first*
        /// occurrence, so a weekly meeting running since 2018 is a single
        /// record dated 2018. Bounding this by the window would drop every
        /// future occurrence of it.
        ///
        /// Built per call rather than stored: `NSPredicate` is not `Sendable`,
        /// and this is read from the source's own queue.
        static func masters() -> NSPredicate {
            NSPredicate(format: "isRecurring == YES")
        }

        /// Also unbounded: an occurrence moved *out* of the window must still
        /// suppress the slot it vacated.
        static func exceptions() -> NSPredicate {
            NSPredicate(format: "isOccurrence == YES")
        }
    }
}
