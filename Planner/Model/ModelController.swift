import AppKit
import CoreData

enum ModelError: Error, Equatable {
    case saveFailed
    case emptyTitle
    case cycle
}

@MainActor
final class ModelController {
    private let persistence: PersistenceController
    weak var presentingWindow: NSWindow?

    private var ctx: NSManagedObjectContext { persistence.viewContext }

    init(persistence: PersistenceController, presentingWindow: NSWindow? = nil) {
        self.persistence = persistence
        self.presentingWindow = presentingWindow
    }

    // MARK: - Create

    func createProject() throws -> Project {
        let now = Date()
        let project = Project(context: ctx)
        project.uuid = UUID()
        project.title = "Untitled Project"
        project.sortIndex = Self.nextSortIndex(in: fetchedProjects())
        project.createdAt = now
        project.updatedAt = now
        ctx.processPendingChanges()
        ctx.undoManager?.setActionName("New Project")
        try saveOrThrow()
        return project
    }

    func createTask(in project: Project) throws -> TaskItem {
        let task = makeTask(sortIndex: Self.nextSortIndex(in: fetchedSiblings(in: project)))
        task.project = project
        task.parentTask = nil
        ctx.processPendingChanges()
        ctx.undoManager?.setActionName("New Task")
        try saveOrThrow()
        return task
    }

    func createSubtask(under parent: TaskItem) throws -> TaskItem {
        let task = makeTask(sortIndex: Self.nextSortIndex(in: fetchedSiblings(under: parent)))
        if wouldIntroduceCycle(child: task, parent: parent) {
            ctx.delete(task)
            throw ModelError.cycle
        }
        task.parentTask = parent
        task.project = nil
        ctx.processPendingChanges()
        ctx.undoManager?.setActionName("New Subtask")
        try saveOrThrow()
        return task
    }

    func createSibling(of task: TaskItem) throws -> TaskItem {
        if let project = task.project {
            return try createTask(in: project)
        }
        if let parent = task.parentTask {
            let created = try createSubtask(under: parent)
            ctx.undoManager?.setActionName("New Task")
            return created
        }
        preconditionFailure("TaskItem missing parent; ModelController invariant violated")
    }

    func createTask(under parent: OutlineNode) throws -> TaskItem {
        switch parent {
        case let project as Project: return try createTask(in: project)
        case let task as TaskItem: return try createSubtask(under: task)
        default: preconditionFailure("unknown OutlineNode")
        }
    }

    // MARK: - Delete

    func delete(_ node: OutlineNode) throws {
        switch node {
        case let project as Project:
            ctx.delete(project)
        case let task as TaskItem:
            ctx.delete(task)
        default:
            preconditionFailure("unknown OutlineNode")
        }
        ctx.processPendingChanges()
        ctx.undoManager?.setActionName("Delete")
        try saveOrThrow()
    }

    // MARK: - Mutations

    func setTitle(_ node: OutlineNode, _ title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ModelError.emptyTitle }
        let now = Date()
        switch node {
        case let project as Project:
            project.title = trimmed
            project.updatedAt = now
        case let task as TaskItem:
            task.title = trimmed
            task.updatedAt = now
        default:
            preconditionFailure("unknown OutlineNode")
        }
        ctx.processPendingChanges()
        ctx.undoManager?.setActionName("Rename")
        try saveOrThrow()
    }

    func setNote(_ task: TaskItem, _ note: String?) throws {
        task.note = (note?.isEmpty == true) ? nil : note
        task.updatedAt = Date()
        ctx.processPendingChanges()
        ctx.undoManager?.setActionName("Edit Note")
        try saveOrThrow()
    }

    func setDeadline(_ task: TaskItem, date: Date?, calendar: Calendar = .current) throws {
        task.deadline = date.map { calendar.startOfDay(for: $0) }
        task.updatedAt = Date()
        ctx.processPendingChanges()
        ctx.undoManager?.setActionName(date == nil ? "Clear Deadline" : "Set Deadline")
        try saveOrThrow()
    }

    func setCompleted(_ completed: Bool, on task: TaskItem) throws {
        task.isCompleted = completed
        task.updatedAt = Date()
        ctx.processPendingChanges()
        ctx.undoManager?.setActionName(completed ? "Complete" : "Mark Incomplete")
        try saveOrThrow()
    }

    // MARK: - Lookups

    func project(uuid: UUID) throws -> Project? {
        let request = Project.fetchRequest()
        request.predicate = NSPredicate(format: "uuid == %@", uuid as CVarArg)
        request.fetchLimit = 1
        return try ctx.fetch(request).first
    }

    func task(uuid: UUID) throws -> TaskItem? {
        let request = TaskItem.fetchRequest()
        request.predicate = NSPredicate(format: "uuid == %@", uuid as CVarArg)
        request.fetchLimit = 1
        return try ctx.fetch(request).first
    }

    func node(uuid: UUID) throws -> OutlineNode? {
        if let project = try project(uuid: uuid) { return project }
        return try task(uuid: uuid)
    }

    func allProjects() throws -> [Project] {
        let request = Project.fetchRequest()
        request.sortDescriptors = Self.siblingSortDescriptors
        return try ctx.fetch(request)
    }

    func tasks(deadlineInMonthOf date: Date, calendar: Calendar) throws -> [TaskItem] {
        let start = calendar.startOfMonth(for: date)
        let end = calendar.date(byAdding: .month, value: 1, to: start)!
        return try fetchTasks(deadlineFrom: start, to: end)
    }

    func tasks(deadlineInGridOf date: Date, calendar: Calendar) throws -> [TaskItem] {
        let days = calendar.daysInMonthGrid(for: date)
        let start = days[0]
        let end = calendar.date(byAdding: .day, value: 1, to: days[41])!
        return try fetchTasks(deadlineFrom: start, to: end)
    }

    // MARK: - Invariants

    func wouldIntroduceCycle(child: TaskItem, parent: TaskItem) -> Bool {
        var cursor: TaskItem? = parent
        var seen = Set<NSManagedObjectID>()
        while let node = cursor {
            if node.objectID == child.objectID { return true }
            if !seen.insert(node.objectID).inserted { return true }
            cursor = node.parentTask
        }
        return false
    }

    // MARK: - Internals

    static func nextSortIndex<T: OutlineNode>(in siblings: [T]) -> Int64 {
        (siblings.map(\.sortIndex).max() ?? -1) + 1
    }

    private static let siblingSortDescriptors = [
        NSSortDescriptor(key: "sortIndex", ascending: true),
        NSSortDescriptor(key: "uuid", ascending: true),
    ]

    private static let deadlineSortDescriptors = [
        NSSortDescriptor(key: "deadline", ascending: true),
        NSSortDescriptor(key: "sortIndex", ascending: true),
        NSSortDescriptor(key: "uuid", ascending: true),
    ]

    private func makeTask(sortIndex: Int64) -> TaskItem {
        let now = Date()
        let task = TaskItem(context: ctx)
        task.uuid = UUID()
        task.title = "Untitled Task"
        task.isCompleted = false
        task.sortIndex = sortIndex
        task.createdAt = now
        task.updatedAt = now
        return task
    }

    private func fetchedProjects() -> [Project] {
        (try? ctx.fetch(Project.fetchRequest())) ?? []
    }

    private func fetchedSiblings(in project: Project) -> [TaskItem] {
        let request = TaskItem.fetchRequest()
        request.predicate = NSPredicate(format: "project == %@", project)
        return (try? ctx.fetch(request)) ?? []
    }

    private func fetchedSiblings(under parent: TaskItem) -> [TaskItem] {
        let request = TaskItem.fetchRequest()
        request.predicate = NSPredicate(format: "parentTask == %@", parent)
        return (try? ctx.fetch(request)) ?? []
    }

    private func fetchTasks(deadlineFrom start: Date, to end: Date) throws -> [TaskItem] {
        let request = TaskItem.fetchRequest()
        request.predicate = NSPredicate(
            format: "deadline >= %@ AND deadline < %@",
            start as NSDate,
            end as NSDate
        )
        request.sortDescriptors = Self.deadlineSortDescriptors
        return try ctx.fetch(request)
    }

    private func saveOrThrow() throws {
        guard persistence.saveViewContext(presentingWindow: presentingWindow) else {
            throw ModelError.saveFailed
        }
    }
}

extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date))!
    }

    func daysInMonthGrid(for date: Date) -> [Date] {
        let monthStart = startOfMonth(for: date)
        let weekday = component(.weekday, from: monthStart)
        var leading = weekday - firstWeekday
        if leading < 0 { leading += 7 }
        let gridStart = startOfDay(for: self.date(byAdding: .day, value: -leading, to: monthStart)!)
        return (0..<42).map { offset in
            startOfDay(for: self.date(byAdding: .day, value: offset, to: gridStart)!)
        }
    }
}
