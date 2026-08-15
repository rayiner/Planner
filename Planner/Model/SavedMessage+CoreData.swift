import CoreData

/// A message the user chose to keep: a copy taken at save time, not a pointer
/// into Outlook.
///
/// That is the whole reason this is an entity while `MailMessage` is not.
/// Recent Mail is a transient view of a foreign feed; a saved message is
/// Planner data, and it has to survive the original being filed, archived, or
/// deleted upstream. `outlookID` is kept only as a best-effort handle for
/// "Open in Outlook" and is expected to go stale.
@objc(SavedMessage)
final class SavedMessage: NSManagedObject {
    @NSManaged var uuid: UUID
    /// RFC 822 Message-ID. The dedupe key — **indexed, not unique**, because
    /// CloudKit forbids uniqueness constraints. `ModelController` enforces
    /// one-copy-per-folder on the way in instead.
    @NSManaged var messageID: String
    @NSManaged var subject: String
    @NSManaged var senderName: String
    @NSManaged var senderAddress: String
    @NSManaged var recipients: String?
    @NSManaged var receivedAt: Date
    @NSManaged var body: String?
    @NSManaged var inReplyTo: String?
    /// Space-joined ids, oldest first, exactly as the header carried them.
    /// Parsed by `MailThreading`; never split at write time.
    @NSManaged var references: String?
    @NSManaged var attachmentNames: String?
    @NSManaged var hasAttachments: Bool
    /// Outlook's record id at save time. A stale value simply means "Open in
    /// Outlook" fails with a message that says so.
    @NSManaged var outlookID: Int64
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
    /// Optional in the model because CloudKit requires it; non-nil in practice,
    /// enforced by `ModelController` and asserted in tests.
    @NSManaged var folder: MailFolder?
}

extension SavedMessage {
    @nonobjc class func fetchRequest() -> NSFetchRequest<SavedMessage> {
        NSFetchRequest<SavedMessage>(entityName: "SavedMessage")
    }

    /// The name if there is one, else the address — the same rule
    /// `MailMessage` uses, so a row does not change shape when it is saved.
    var senderDisplayName: String {
        senderName.isEmpty ? senderAddress : senderName
    }

    var attachmentNameList: [String] {
        guard let attachmentNames, !attachmentNames.isEmpty else { return [] }
        return attachmentNames
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
