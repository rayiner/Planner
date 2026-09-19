import Foundation

/// User-initiated Outlook commands. Envelope reads and bodies go through
/// `olsyncmail`; category membership is read from Outlook's local database.
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

    /// Adds or removes the `Hide` category without changing any other category.
    /// Hiding creates the category when Outlook does not have it yet.
    static func setHidden(_ hidden: Bool, messageID: Int64) -> String {
        hidden ? hide(messageID: messageID) : unhide(messageID: messageID)
    }

    /// Adds or removes one already-defined ordinary Outlook category by id.
    /// The generic UI never supplies the reserved Hide category here.
    static func setCategory(_ categoryID: Int64, present: Bool, messageID: Int64) -> String {
        present
            ? addCategory(categoryID, messageID: messageID)
            : removeCategory(categoryID, messageID: messageID)
    }

    private static func hide(messageID: Int64) -> String {
        """
        tell application "Microsoft Outlook"
            set targetMessage to message id \(messageID)
            set hideCategory to missing value
            repeat with candidate in every category
                if name of candidate is "Hide" then
                    set hideCategory to candidate
                    exit repeat
                end if
            end repeat
            if hideCategory is missing value then
                set hideCategory to make new category with properties {name:"Hide"}
            end if
            set currentCategories to category of targetMessage
            repeat with candidate in currentCategories
                if id of candidate is id of hideCategory then return
            end repeat
            set category of targetMessage to {hideCategory} & currentCategories
        end tell
        """
    }

    private static func unhide(messageID: Int64) -> String {
        """
        tell application "Microsoft Outlook"
            set targetMessage to message id \(messageID)
            set keptCategories to {}
            repeat with candidate in category of targetMessage
                if name of candidate is not "Hide" then
                    copy candidate to end of keptCategories
                end if
            end repeat
            set category of targetMessage to keptCategories
        end tell
        """
    }

    private static func addCategory(_ categoryID: Int64, messageID: Int64) -> String {
        """
        tell application "Microsoft Outlook"
            set targetMessage to message id \(messageID)
            set targetCategory to category id \(categoryID)
            set currentCategories to category of targetMessage
            repeat with candidate in currentCategories
                if id of candidate is \(categoryID) then return
            end repeat
            set category of targetMessage to {targetCategory} & currentCategories
        end tell
        """
    }

    private static func removeCategory(_ categoryID: Int64, messageID: Int64) -> String {
        """
        tell application "Microsoft Outlook"
            set targetMessage to message id \(messageID)
            set keptCategories to {}
            repeat with candidate in category of targetMessage
                if id of candidate is not \(categoryID) then
                    copy candidate to end of keptCategories
                end if
            end repeat
            set category of targetMessage to keptCategories
        end tell
        """
    }
}
