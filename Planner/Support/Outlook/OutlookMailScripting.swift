import Foundation

/// The Outlook mail vocabulary Planner depends on, in one place.
///
/// These strings **are** the API contract, exactly as `OutlookScripting`'s
/// selector names are for the calendar — but the mechanism differs, and the
/// reason is worth stating where the scripts live.
///
/// The calendar source drives Outlook through ScriptingBridge. Mail cannot,
/// because the only viable fetch shape is an AppleScript **range specifier**
/// (`messages 1 thru N of inb`), which ScriptingBridge has no way to express.
/// The M0 spike measured the alternatives on a 34,881-message Inbox:
///
/// | shape | cost |
/// | --- | --- |
/// | `whose timeReceived ≥ cutoff` | **23s**, every call |
/// | bulk one property over the whole collection | **13.7s** |
/// | `properties` of a *single* message | 2.4 MB (it drags `content`, `plainTextContent` and `source`) |
/// | `messages 1 thru N`, five fields, N = 164 | **~10s** |
/// | one message's body by id | **~10ms** |
///
/// So: find the window's edge by binary search over a collection that is
/// ordered newest-first, range-read the envelope, and leave bodies and headers
/// to per-id reads. To re-verify the vocabulary against a new Outlook build:
///
/// ```sh
/// sdef /Applications/Microsoft\ Outlook.app > /tmp/Outlook.sdef
/// # then grep the Mail Suite for the terms below
/// ```
nonisolated enum OutlookMailScripting {
    static let bundleIdentifier = "com.microsoft.Outlook"

    /// AE record keys inside the `sender` record.
    enum SenderKey {
        static let name: AEKeyword = 0x706E616D    // 'pnam'
        static let address: AEKeyword = 0x72616464 // 'radd'
    }

    /// Names of the Exchange accounts, in the order Outlook lists them — which
    /// is the order the index-based queries below address them by.
    static let accountNames = """
    tell application "Microsoft Outlook" to return name of every exchange account
    """

    static func inboxName(accountIndex: Int) -> String {
        """
        tell application "Microsoft Outlook" to return name of inbox of exchange account \(accountIndex)
        """
    }

    /// How many of the newest messages fall inside the window.
    ///
    /// The binary search runs **inside** the script rather than as a series of
    /// round trips: the probes are property reads inside Outlook's own address
    /// space, so the whole search costs one Apple event instead of fifteen.
    /// Correct only because the collection is ordered newest-first and strictly
    /// monotonic, which M0 verified over the newest 400 messages.
    static func windowCount(accountIndex: Int, since: Date, calendar: Calendar) -> String {
        """
        tell application "Microsoft Outlook"
            set inb to inbox of exchange account \(accountIndex)
            set total to count of messages of inb
            if total is 0 then return 0
            \(dateLiteral(named: "cutoff", for: since, calendar: calendar))
            if (time received of message 1 of inb) < cutoff then return 0
            set lo to 1
            set hi to total
            repeat while lo < hi
                set mid to (lo + hi + 1) div 2
                if (time received of message mid of inb) ≥ cutoff then
                    set lo to mid
                else
                    set hi to mid - 1
                end if
            end repeat
            return lo
        end tell
        """
    }

    /// Five parallel arrays, one Apple event each, all index-aligned.
    ///
    /// Deliberately **not** `properties`: see the table above. The order of the
    /// columns here is the order `OutlookMailDecoder` reads them in.
    static func envelopes(accountIndex: Int, count: Int) -> String {
        """
        tell application "Microsoft Outlook"
            set inb to inbox of exchange account \(accountIndex)
            set theIDs to id of messages 1 thru \(count) of inb
            set theSubjects to subject of messages 1 thru \(count) of inb
            set theTimes to time received of messages 1 thru \(count) of inb
            set theRead to is read of messages 1 thru \(count) of inb
            set theSenders to sender of messages 1 thru \(count) of inb
            return {theIDs, theSubjects, theTimes, theRead, theSenders}
        end tell
        """
    }

    /// One message's body, headers and attachment names, by unique id.
    ///
    /// Every read is wrapped: a message can lose its body to a partial
    /// download, and an attachment list can fail on a rights-protected message,
    /// and neither is a reason to fail the whole fetch.
    static func detail(messageID: Int64) -> String {
        """
        tell application "Microsoft Outlook"
            set m to message id \(messageID)
            set theBody to ""
            try
                set theBody to plain text content of m
            end try
            set theHeaders to ""
            try
                set theHeaders to headers of m
            end try
            set theNames to {}
            try
                set theNames to name of every attachment of m
            end try
            return {theBody, theHeaders, theNames}
        end tell
        """
    }

    /// Brings the original up in Outlook.
    ///
    /// The one command here that is not a read — and it is not Planner's write
    /// either: opening a message is the user asking to work on it in Outlook,
    /// which is why it is only ever reachable from an explicit action.
    static func reveal(messageID: Int64) -> String {
        """
        tell application "Microsoft Outlook"
            activate
            open message id \(messageID)
        end tell
        """
    }

    /// An AppleScript date built field by field.
    ///
    /// A formatted date string would have to match Outlook's locale, and there
    /// is no reliable way to know what that is. Fields are numbers, so this is
    /// also the only form with nothing to escape. `day` is set to 1 first
    /// because setting, say, day 31 while the month is February rolls the date
    /// forward instead of erroring.
    static func dateLiteral(named name: String, for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let seconds = (parts.hour ?? 0) * 3600 + (parts.minute ?? 0) * 60 + (parts.second ?? 0)
        return """
        set \(name) to (current date)
            set day of \(name) to 1
            set year of \(name) to \(parts.year ?? 2000)
            set month of \(name) to \(parts.month ?? 1)
            set day of \(name) to \(parts.day ?? 1)
            set time of \(name) to \(seconds)
        """
    }
}
