import CoreData

/// A note attached to a calendar day. Deliberately not an `OutlineNode`: a day
/// has no title, no parent, no children, no deadline and no completion flag —
/// it is addressed by its date, not by its position in the project tree.
@objc(DayNote)
final class DayNote: NSManagedObject {
    @NSManaged var uuid: UUID
    /// Start of day in the writing calendar. Identity for the row.
    @NSManaged var day: Date
    @NSManaged var note: String?
    /// RTF payload; `note` is its plain-text shadow. Nil for plain notes.
    @NSManaged var noteRTF: Data?
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
}

extension DayNote {
    @nonobjc class func fetchRequest() -> NSFetchRequest<DayNote> {
        NSFetchRequest<DayNote>(entityName: "DayNote")
    }
}
