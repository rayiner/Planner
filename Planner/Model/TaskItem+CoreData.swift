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
