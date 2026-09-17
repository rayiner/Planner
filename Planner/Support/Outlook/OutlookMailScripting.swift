import Foundation

/// The one remaining Apple event in the mail path: opening a message the user
/// asked to see in Outlook. Envelope reads and bodies go through `olsyncmail`.
nonisolated enum OutlookMailScripting {
    static let bundleIdentifier = "com.microsoft.Outlook"

    /// Brings the original up in Outlook.
    ///
    /// The one command here that is not a read — and it is not Planner's write
    /// either: opening a message is the user asking to work on it in Outlook,
    /// which is why it is only ever reachable from an explicit action. The
    /// argument is Outlook's record id, which AppleScript addresses as
    /// `message id N`.
    static func reveal(messageID: Int64) -> String {
        """
        tell application "Microsoft Outlook"
            activate
            open message id \(messageID)
        end tell
        """
    }
}
