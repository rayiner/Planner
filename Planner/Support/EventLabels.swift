import Foundation

/// Every user-visible string an event chip produces.
///
/// Separated from the view so the wording is testable, and because the three
/// audiences want different things: the grid shows only the subject, the
/// tooltip carries the full detail on demand, and VoiceOver gets that same
/// detail plus the word "Event" — the only way the distinction the leading dot
/// draws reaches a screen reader.
@MainActor
enum EventLabels {
    /// The single line drawn in the cell: the subject, and nothing else.
    ///
    /// **No time.** Planner is not a calendar — an event is context for the
    /// day's deadlines, not an appointment to be read off the grid. A time
    /// prefix costs characters of subject in a column whose width is calibrated
    /// on task titles, and buys back something the user is not here to do. The
    /// tooltip and VoiceOver still carry it, where there is room and where it
    /// is asked for.
    static func title(for chip: CalendarEventChip) -> String {
        chip.title
    }

    /// The full detail, which the grid has no room for.
    static func tooltip(for chip: CalendarEventChip) -> String {
        var lines = [chip.title, when(chip)]
        if let location = chip.location { lines.append(location) }
        if let organizer = chip.organizer { lines.append(organizer) }
        if let calendarName = chip.calendarName { lines.append(calendarName) }

        var tags: [String] = []
        if chip.isRecurring { tags.append("Repeating") }
        if chip.isRescheduled { tags.append("Moved") }
        if !tags.isEmpty { lines.append(tags.joined(separator: " · ")) }

        return lines.joined(separator: "\n")
    }

    /// Reads as a sentence, and always ends in "Event" — a chip is not a task,
    /// and the dot that says so visually says nothing aloud.
    static func accessibilityLabel(for chip: CalendarEventChip) -> String {
        var parts = [when(chip), chip.title]
        if let calendarName = chip.calendarName { parts.append(calendarName) }
        if chip.isRescheduled { parts.append("Moved") }
        parts.append("Event")
        return parts.joined(separator: ", ")
    }

    /// The time phrase, in whichever of the four shapes applies.
    private static func when(_ chip: CalendarEventChip) -> String {
        if chip.isAllDay {
            return chip.continuesFromPreviousDay || chip.continuesToNextDay
                ? "All day, continues"
                : "All day"
        }
        guard let start = chip.startTime else {
            // A continuation day of a timed run: the start was days ago.
            return "Continues from a previous day"
        }
        let formatter = timeFormatter()
        let opening = formatter.string(from: start)
        guard let end = chip.endTime, end > start else { return opening }
        let range = "\(opening) to \(formatter.string(from: end))"
        return chip.continuesToNextDay ? "\(range), continues" : range
    }

    // MARK: - Formatting

    /// Keyed on the locale identifier rather than invalidated by notification:
    /// a stale cache is then impossible by construction instead of dependent on
    /// an observer being wired up.
    private static var cached: (identifier: String, formatter: DateFormatter)?

    private static func timeFormatter() -> DateFormatter {
        let locale = Locale.current
        if let cached, cached.identifier == locale.identifier { return cached.formatter }
        let formatter = DateFormatter()
        formatter.locale = locale
        // `j` is the locale's own hour field, so 24-hour locales get 24-hour
        // times without a preference check.
        formatter.setLocalizedDateFormatFromTemplate("j:mm")
        cached = (locale.identifier, formatter)
        return formatter
    }
}
