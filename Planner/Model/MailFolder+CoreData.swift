import CoreData

/// A folder of saved mail. Planner's own data, not a mirror of anything in
/// Outlook: saving a message copies it here, and the original is left exactly
/// where it was.
///
/// Deliberately not an `OutlineNode`. A mail folder has no parent, no children,
/// no deadline and no completion flag — the mailbox list is one flat level, and
/// nesting would be a second tree to keep honest for no gain.
@objc(MailFolder)
final class MailFolder: NSManagedObject {
    @NSManaged var uuid: UUID
    @NSManaged var name: String
    @NSManaged var sortIndex: Int64
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
    /// Unordered, as CloudKit requires; the list sorts by `(receivedAt, uuid)`.
    @NSManaged var messages: Set<SavedMessage>
}

extension MailFolder {
    @nonobjc class func fetchRequest() -> NSFetchRequest<MailFolder> {
        NSFetchRequest<MailFolder>(entityName: "MailFolder")
    }
}
