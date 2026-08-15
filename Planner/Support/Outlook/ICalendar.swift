import Foundation

/// The little bit of iCalendar Planner has to read.
///
/// Outlook hands back an event's `icalendarData` alongside its other
/// properties, and two fields in there are load-bearing:
///
/// - `UID` joins an exception to its master. The alternative — asking each
///   exception for `master.id` — costs one Apple event per exception.
/// - `EXDATE` is the **only** record of a deleted occurrence. It has no event
///   of its own and no exception record, so expansion would otherwise put it
///   back.
nonisolated enum ICalendar {
    /// Splits into logical lines, undoing the 75-character folding the format
    /// mandates. A folded continuation begins with a space or tab and belongs
    /// to the previous line; matching before unfolding misses long EXDATE runs.
    static func logicalLines(_ ics: String) -> [String] {
        var lines: [String] = []
        for raw in ics.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else {
                lines.append(String(raw))
            }
        }
        return lines
    }

    /// The series identifier, shared by a master and every exception of it.
    static func uid(in ics: String) -> String? {
        for line in logicalLines(ics) where line.hasPrefix("UID:") {
            let value = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Deleted-occurrence dates.
    ///
    /// Read as **wall-clock local time**, deliberately: Outlook sometimes tags
    /// these with a different `TZID` than the series itself, and a trailing `Z`
    /// is likewise ignored. Being a little off is fine because the slot matching
    /// downstream is nearest-wins within a tolerance; being systematically
    /// shifted by trusting an inconsistent zone would not be.
    static func exDates(in ics: String, calendar: Calendar) -> [Date] {
        var dates: [Date] = []
        for line in logicalLines(ics) {
            guard line.uppercased().hasPrefix("EXDATE"),
                  let colon = line.firstIndex(of: ":") else { continue }
            let value = line[line.index(after: colon)...]
            for token in value.split(separator: ",") {
                if let date = date(fromICSValue: token.trimmingCharacters(in: .whitespaces),
                                   calendar: calendar) {
                    dates.append(date)
                }
            }
        }
        return dates
    }

    /// `20260803T124500` or the date-only `20260803`. Anything else is skipped
    /// rather than guessed at.
    static func date(fromICSValue token: String, calendar: Calendar) -> Date? {
        let digits = Array(token.prefix(while: { $0.isNumber || $0 == "T" }))
        guard digits.count >= 8 else { return nil }

        func number(_ range: Range<Int>) -> Int? {
            Int(String(digits[range]))
        }
        guard let year = number(0..<4), let month = number(4..<6), let day = number(6..<8) else {
            return nil
        }

        var components = DateComponents(year: year, month: month, day: day)
        if digits.count >= 15, digits[8] == "T" {
            components.hour = number(9..<11)
            components.minute = number(11..<13)
            components.second = number(13..<15)
        }
        return calendar.date(from: components)
    }
}
