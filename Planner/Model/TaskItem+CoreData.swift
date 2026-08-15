import CoreData

@objc(TaskItem)
final class TaskItem: NSManagedObject, OutlineNode {
    @NSManaged var uuid: UUID
    @NSManaged var title: String
    @NSManaged var note: String?
    /// RTF payload; `note` is its plain-text shadow. Nil for plain notes.
    @NSManaged var noteRTF: Data?
    @NSManaged var deadline: Date?
    @NSManaged var isCompleted: Bool
    @NSManaged var sortIndex: Int64
    /// The `SavedMessage` this task came from, if any. A soft link by UUID
    /// rather than a relationship, the same shape selection and reveal use:
    /// deleting the message must leave the task intact, and a dangling link is
    /// simply a chip the inspector does not draw.
    @NSManaged var sourceMessageUUID: UUID?
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
    @NSManaged var project: Project?
    @NSManaged var parentTask: TaskItem?
    @NSManaged var subtasks: Set<TaskItem>

    var outlineChildren: [OutlineNode] {
        subtasks.sorted { ($0.sortIndex, $0.uuid) < ($1.sortIndex, $1.uuid) }
    }

    var outlineParent: OutlineNode? { parentTask ?? project }
}

extension TaskItem {
    @nonobjc class func fetchRequest() -> NSFetchRequest<TaskItem> {
        NSFetchRequest<TaskItem>(entityName: "Task")
    }
}
