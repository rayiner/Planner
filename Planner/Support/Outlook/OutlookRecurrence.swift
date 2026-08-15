import Foundation

/// Replays Outlook recurrence rules into concrete occurrences.
nonisolated enum OutlookRecurrence {
    /// Guard against a malformed rule generating forever. Also the natural
    /// termination condition for the lazy slot sequence, which is infinite by
    /// design.
    static let maxSlots = 20_000

    struct Occurrence: Hashable, Sendable {
        let start: Date
        /// Exclusive.
        let end: Date
    }

    /// Expands one master into the occurrences overlapping `window`.
    ///
    /// Occurrences *before* the window are still generated and then discarded,
    /// because a rule that ends after a fixed number of occurrences counts them
    /// from the series start — stopping early would let the tail run too long.
    static func expand(
        master: OutlookRawEvent,
        in window: Range<Date>,
        calendar: Calendar
    ) -> [Occurrence] {
        guard let rule = master.rule else { return [] }

        let duration = max(0, master.end.timeIntervalSince(master.start))
        // Exclusive: the first instant the series may no longer start at.
        let seriesEnd = seriesEndBound(rule, calendar: calendar)
        let stop = min(seriesEnd ?? window.upperBound, window.upperBound)

        var limit = maxSlots
        if case let .after(count) = rule.end { limit = min(limit, count) }

        var occurrences: [Occurrence] = []
        var seen = 0
        for start in slots(for: rule, anchor: master.start, calendar: calendar) {
            seen += 1
            if seen > limit { break }
            if start >= stop { break }
            let end = start.addingTimeInterval(duration)
            // Overlap, not containment: a meeting already under way still counts.
            if end >= window.lowerBound {
                occurrences.append(Occurrence(start: start, end: end))
            }
        }
        return occurrences
    }

    /// The first instant a series may no longer start at, or `nil` if it never ends.
    ///
    /// Outlook reports a series end date as a UTC midnight rendered in local
    /// time, so it can land on the *previous* calendar day — a Saturday series
    /// ending "Fri 7pm" really ends that Saturday. Nudging forward half a day
    /// before taking the calendar date normalizes that under either storage
    /// convention, and never moves a value already at local midnight.
    static func seriesEndBound(_ rule: OutlookRecurrenceRule, calendar: Calendar) -> Date? {
        guard case let .on(endDate) = rule.end else { return nil }
        let nudged = endDate.addingTimeInterval(12 * 3600)
        let lastDay = calendar.startOfDay(for: nudged)
        return calendar.date(byAdding: .day, value: 1, to: lastDay)
    }

    /// The ordinal-th matching weekday of a month, e.g. "the second Wednesday".
    /// Outlook uses ordinal 5 to mean "last", so anything past the end clamps.
    static func nthWeekday(
        year: Int,
        month: Int,
        mask: DayMask,
        ordinal: Int?,
        calendar: Calendar
    ) -> Date? {
        guard let monthStart = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let range = calendar.range(of: .day, in: .month, for: monthStart)
        else { return nil }

        var matches: [Date] = []
        for day in range {
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day))
            else { continue }
            if mask.contains(weekday: calendar.component(.weekday, from: date)) {
                matches.append(date)
            }
        }
        guard !matches.isEmpty else { return nil }
        guard let ordinal, ordinal >= 1, ordinal < 5 else { return matches[matches.count - 1] }
        return matches[ordinal - 1]
    }

    /// Occurrence start times in ascending order from the series anchor.
    /// Infinite by design; callers bound it.
    static func slots(
        for rule: OutlookRecurrenceRule,
        anchor: Date,
        calendar: Calendar
    ) -> some Sequence<Date> {
        SlotSequence(rule: rule, anchor: anchor, calendar: calendar)
    }
}

// MARK: - Slot generation

nonisolated extension OutlookRecurrence {
    fileprivate struct SlotSequence: Sequence {
        let rule: OutlookRecurrenceRule
        let anchor: Date
        let calendar: Calendar

        func makeIterator() -> SlotIterator {
            SlotIterator(rule: rule, anchor: anchor, calendar: calendar)
        }
    }

    fileprivate struct SlotIterator: IteratorProtocol {
        /// A cycle that yields nothing (a month with no matching weekday, say)
        /// must not spin forever looking for one.
        private static let maxEmptyCycles = 100_000

        private let rule: OutlookRecurrenceRule
        private let anchor: Date
        private let calendar: Calendar
        private let anchorDay: Date
        private let step: Int
        private let mask: DayMask?

        private var pending: [Date] = []
        private var dayCursor: Date
        private var weekCursor: Date
        private var year: Int
        private var month: Int
        private var cycles = 0
        private var finished = false

        init(rule: OutlookRecurrenceRule, anchor: Date, calendar: Calendar) {
            self.rule = rule
            self.anchor = anchor
            self.calendar = calendar
            anchorDay = calendar.startOfDay(for: anchor)
            step = max(1, rule.interval)
            mask = rule.daysOfWeek
            dayCursor = anchorDay
            // Sunday-based, unlike the grid's Monday-based weeks: the day mask
            // is Sunday-indexed and, more importantly, this is where a
            // fortnightly series' week boundary falls.
            let weekday = calendar.component(.weekday, from: anchorDay)
            weekCursor = calendar.date(byAdding: .day, value: -(weekday - 1), to: anchorDay) ?? anchorDay
            let parts = calendar.dateComponents([.year, .month], from: anchorDay)
            year = parts.year ?? 1
            month = parts.month ?? 1
        }

        mutating func next() -> Date? {
            while pending.isEmpty {
                guard !finished else { return nil }
                cycles += 1
                if cycles > Self.maxEmptyCycles {
                    finished = true
                    return nil
                }
                advance()
            }
            return pending.removeFirst()
        }

        private mutating func advance() {
            switch rule.pattern {
            case .daily: advanceDaily()
            case .weekly: advanceWeekly()
            case .absoluteMonthly: advanceAbsoluteMonthly()
            case .relativeMonthly: advanceRelativeMonthly()
            case .absoluteYearly: advanceAbsoluteYearly()
            case .relativeYearly: advanceRelativeYearly()
            case .unknown:
                // Not a pattern we model, but its first occurrence is real.
                pending.append(anchor)
                finished = true
            }
        }

        /// "Every weekday" arrives as a *daily* rule carrying a Mon–Fri mask,
        /// not as a weekly rule — so the mask has to be honoured here too.
        private mutating func advanceDaily() {
            let day = dayCursor
            if mask == nil || mask!.contains(weekday: calendar.component(.weekday, from: day)) {
                pending.append(atAnchorTime(day))
            }
            dayCursor = calendar.date(byAdding: .day, value: step, to: day) ?? day.addingTimeInterval(86_400)
            if dayCursor <= day { finished = true }
        }

        private mutating func advanceWeekly() {
            let weekStart = weekCursor
            let effective = mask ?? .single(weekday: calendar.component(.weekday, from: anchorDay))
            for offset in 0..<7 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: weekStart) else { continue }
                guard effective.contains(weekday: calendar.component(.weekday, from: day)) else { continue }
                // The first week is partial: the series starts at its anchor.
                guard day >= anchorDay else { continue }
                pending.append(atAnchorTime(day))
            }
            weekCursor = calendar.date(byAdding: .day, value: 7 * step, to: weekStart) ?? weekStart
            if weekCursor <= weekStart { finished = true }
        }

        private mutating func advanceAbsoluteMonthly() {
            let wanted = rule.dayOfMonth ?? calendar.component(.day, from: anchorDay)
            if let day = dayInMonth(year: year, month: month, clampedTo: wanted), day >= anchorDay {
                pending.append(atAnchorTime(day))
            }
            stepMonths(step)
        }

        private mutating func advanceRelativeMonthly() {
            let effective = mask ?? .single(weekday: calendar.component(.weekday, from: anchorDay))
            if let day = OutlookRecurrence.nthWeekday(
                year: year, month: month, mask: effective,
                ordinal: rule.ordinal, calendar: calendar
            ), day >= anchorDay {
                pending.append(atAnchorTime(day))
            }
            stepMonths(step)
        }

        private mutating func advanceAbsoluteYearly() {
            let targetMonth = rule.monthNumber ?? calendar.component(.month, from: anchorDay)
            let wanted = rule.dayOfMonth ?? calendar.component(.day, from: anchorDay)
            if let day = dayInMonth(year: year, month: targetMonth, clampedTo: wanted), day >= anchorDay {
                pending.append(atAnchorTime(day))
            }
            year += step
        }

        private mutating func advanceRelativeYearly() {
            let targetMonth = rule.monthNumber ?? calendar.component(.month, from: anchorDay)
            let effective = mask ?? .single(weekday: calendar.component(.weekday, from: anchorDay))
            if let day = OutlookRecurrence.nthWeekday(
                year: year, month: targetMonth, mask: effective,
                ordinal: rule.ordinal, calendar: calendar
            ), day >= anchorDay {
                pending.append(atAnchorTime(day))
            }
            year += step
        }

        private mutating func stepMonths(_ count: Int) {
            let zeroBased = (month - 1) + count
            year += Int(floor(Double(zeroBased) / 12.0))
            month = ((zeroBased % 12) + 12) % 12 + 1
        }

        /// Short months clamp to their last day, which is what Outlook does
        /// with a 31st-of-the-month series in February.
        private func dayInMonth(year: Int, month: Int, clampedTo day: Int) -> Date? {
            guard let monthStart = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                  let range = calendar.range(of: .day, in: .month, for: monthStart)
            else { return nil }
            return calendar.date(from: DateComponents(
                year: year, month: month, day: min(day, range.count)
            ))
        }

        /// A calendar day at the series' wall-clock time. Building from
        /// components lets `Calendar` resolve a time that does not exist on a
        /// spring-forward day rather than returning nil.
        private func atAnchorTime(_ day: Date) -> Date {
            var components = calendar.dateComponents([.year, .month, .day], from: day)
            let time = calendar.dateComponents([.hour, .minute, .second], from: anchor)
            components.hour = time.hour
            components.minute = time.minute
            components.second = time.second
            return calendar.date(from: components) ?? day
        }
    }
}
