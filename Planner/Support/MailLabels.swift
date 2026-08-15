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

    static func folderCount(_ count: Int) -> String {
        count == 1 ? "1 message" : "\(count) messages"
    }
}
