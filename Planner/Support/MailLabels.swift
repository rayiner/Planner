import Foundation

/// Every user-visible string mail mode produces.
///
/// Separated from the views for the same reason `EventLabels` is: the wording
/// is then testable, and the three audiences want different things — a list row
/// has one line, a tooltip has room for detail, and VoiceOver needs the things
/// the layout says silently.
@MainActor
enum MailLabels {
    // MARK: - Mailboxes

    static let recentMailName = "Recent Mail"

    /// The title over the message list, and the window title with it.
    static func mailboxTitle(
        mailbox: MailboxSelection,
        windowDays: Int,
        folderName: String?
    ) -> String {
        switch mailbox {
        case .recent:
            return recentMailName
        case .folder:
            // A folder deleted out from under the selection: name the state
            // rather than showing an empty title bar.
            return folderName ?? "No Folder"
        }
    }

    /// The window-length pop-up's entries. Singular for one day, because "Last
    /// 1 Days" is the kind of thing that makes an app feel unfinished.
    static func windowRangeName(days: Int) -> String {
        days == 1 ? "Today" : "Last \(days) Days"
    }

    /// How many messages are in view, for the toolbar and VoiceOver. The count
    /// is what tells the user whether a seven-day window was a good idea.
    static func messageCount(_ count: Int) -> String {
        count == 1 ? "1 message" : "\(count) messages"
    }

    /// A sidebar row reads as "Celerity, 4 messages" rather than as a name and
    /// a bare number, which VoiceOver would otherwise announce as two things.
    static func mailboxAccessibilityLabel(name: String, count: Int) -> String {
        count == 0 ? name : "\(name), \(messageCount(count))"
    }

    // MARK: - Date groups

    /// The sticky header over each day's run of messages.
    ///
    /// "Today" and "Yesterday" earn their place — they are how people actually
    /// refer to recent mail — and everything else gets a weekday plus a date,
    /// because in a seven-day window "Monday" alone is ambiguous the moment the
    /// window is longer than a week's worth of habit.
    static func dateGroupTitle(
        for day: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let today = calendar.startOfDay(for: now)
        let target = calendar.startOfDay(for: day)
        if target == today { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), target == yesterday {
            return "Yesterday"
        }
        return groupFormatter(calendar).string(from: target)
    }

    /// A list row shows only the time: the group header above it already said
    /// which day, and repeating the date in every row is noise in a column
    /// calibrated on subjects.
    static func listTime(for date: Date, calendar: Calendar = .current) -> String {
        timeFormatter(calendar).string(from: date)
    }

    /// The reader has room for the whole thing, and is the one place the user
    /// goes to check exactly when something arrived.
    static func readerTimestamp(for date: Date, calendar: Calendar = .current) -> String {
        readerFormatter(calendar).string(from: date)
    }

    // MARK: - The reader

    static func senderLine(name: String, address: String) -> String {
        // A display name that *is* the address should not be printed twice.
        guard !name.isEmpty, name.caseInsensitiveCompare(address) != .orderedSame else {
            return address.isEmpty ? name : address
        }
        return address.isEmpty ? name : "\(name) <\(address)>"
    }

    static func recipientsLine(_ recipients: String?) -> String? {
        guard let recipients else { return nil }
        let trimmed = recipients.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : "To: \(trimmed)"
    }

    /// Says *that* a message carries attachments, not what they are: Planner
    /// never opens one, so a list of names is dead weight in the header. The
    /// count is kept when the source could read the list; a rights-protected
    /// message refuses its list but still flags the header, and gets the
    /// uncounted line.
    static func attachmentsIndicator(count: Int, hasAttachments: Bool) -> String? {
        guard hasAttachments || count > 0 else { return nil }
        switch count {
        case 0: return "Has attachments"
        case 1: return "1 attachment"
        default: return "\(count) attachments"
        }
    }

    /// The banner that says a message is on its way out of the window.
    ///
    /// The point of Recent Mail is that it *expires*, so the reader says when —
    /// otherwise "save it or lose it" is a rule the user has to be told once
    /// and then remember.
    static func expiryNotice(
        expiry: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: expiry)
        let days = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        switch days {
        case ..<0:
            return "This message has already left Recent Mail."
        case 0:
            return "Leaves Recent Mail today. Save it to keep it."
        case 1:
            return "Leaves Recent Mail tomorrow. Save it to keep it."
        default:
            return "Leaves Recent Mail on \(expiryFormatter(calendar).string(from: day))."
        }
    }

    /// Only worth saying when it is close: on day one of a seven-day window,
    /// the banner is noise.
    static func shouldShowExpiry(
        expiry: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: expiry)
        let days = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        return days <= 1
    }

    static func savedChip(folderName: String) -> String {
        "Saved to \(folderName)"
    }

    static func conversationPosition(index: Int, of count: Int) -> String {
        "Message \(index + 1) of \(count) in this conversation"
    }

    /// The people on a conversation, deduplicated and in order of appearance.
    ///
    /// Truncated after three: the row has one line for this, and a thread of
    /// twelve would otherwise show twelve names and no subject.
    static func threadParticipants(_ names: [String]) -> String {
        var seen = Set<String>()
        var ordered: [String] = []
        for name in names where !name.isEmpty {
            if seen.insert(name).inserted { ordered.append(name) }
        }
        guard ordered.count > 3 else { return ordered.joined(separator: ", ") }
        return ordered.prefix(3).joined(separator: ", ") + " and \(ordered.count - 3) more"
    }

    // MARK: - Empty states

    /// What an empty list means depends entirely on why it is empty, and the
    /// three reasons want three different sentences.
    static func emptyRecentMail(days: Int, hasSource: Bool) -> String {
        guard hasSource else { return "Planner shows recent Outlook mail here." }
        return days == 1
            ? "No mail today."
            : "No mail in the last \(days) days."
    }

    static func emptyFolder(name: String) -> String {
        "Nothing saved in “\(name)” yet."
    }

    static let searchPlaceholder = "Search"

    /// The field already shows what the user typed. Echoing it here turns a
    /// pasted paragraph into a wrapping manifesto in a 300-pt pane.
    static let emptySearch = "No messages match this search."
    static let searchFailed = "Couldn’t search this folder."

    static let noMessageSelected = "Select a message to read it."

    // MARK: - Accessibility

    /// Reads as a sentence, and says "Unread" out loud — the blue dot says it
    /// only to people who can see it.
    static func messageAccessibilityLabel(
        sender: String,
        subject: String,
        receivedAt: Date,
        isRead: Bool,
        savedFolderName: String?,
        calendar: Calendar = .current
    ) -> String {
        var parts = [sender, subject.isEmpty ? "No subject" : subject]
        parts.append(readerTimestamp(for: receivedAt, calendar: calendar))
        if !isRead { parts.append("Unread") }
        if let savedFolderName { parts.append(savedChip(folderName: savedFolderName)) }
        return parts.joined(separator: ", ")
    }

    static func threadAccessibilityLabel(subject: String, count: Int, latest: Date) -> String {
        "\(subject), \(messageCount(count)), latest \(readerTimestamp(for: latest))"
    }

    // MARK: - Formatting

    /// Keyed on locale and time zone rather than invalidated by notification: a
    /// stale cache is then impossible by construction instead of dependent on
    /// an observer being wired up. Same trick as `EventLabels`.
    private struct FormatterKey: Hashable {
        let identifier: String
        let timeZone: String
        let template: String
    }

    private static var cache: [FormatterKey: DateFormatter] = [:]

    private static func formatter(template: String, calendar: Calendar) -> DateFormatter {
        let locale = calendar.locale ?? .current
        let timeZone = calendar.timeZone
        let key = FormatterKey(
            identifier: locale.identifier,
            timeZone: timeZone.identifier,
            template: template
        )
        if let cached = cache[key] { return cached }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        // `j` is the locale's own hour field, so 24-hour locales get 24-hour
        // times without a preference check.
        formatter.setLocalizedDateFormatFromTemplate(template)
        cache[key] = formatter
        return formatter
    }

    private static func timeFormatter(_ calendar: Calendar) -> DateFormatter {
        formatter(template: "j:mm", calendar: calendar)
    }

    private static func groupFormatter(_ calendar: Calendar) -> DateFormatter {
        formatter(template: "EEEEMMMMd", calendar: calendar)
    }

    private static func expiryFormatter(_ calendar: Calendar) -> DateFormatter {
        formatter(template: "EEEE", calendar: calendar)
    }

    private static func readerFormatter(_ calendar: Calendar) -> DateFormatter {
        formatter(template: "EEEEMMMMdyyyyjmm", calendar: calendar)
    }
}
