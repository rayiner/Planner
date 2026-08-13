import CoreData

@objc(Project)
final class Project: NSManagedObject, OutlineNode {
    @NSManaged var uuid: UUID
    @NSManaged var title: String
    @NSManaged var sortIndex: Int64
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
    @NSManaged var tasks: Set<TaskItem>

    var outlineChildren: [OutlineNode] {
        tasks.sorted { ($0.sortIndex, $0.uuid) < ($1.sortIndex, $1.uuid) }
    }

    var outlineParent: OutlineNode? { nil }
}

extension Project {
    @nonobjc class func fetchRequest() -> NSFetchRequest<Project> {
        NSFetchRequest<Project>(entityName: "Project")
    }
}
