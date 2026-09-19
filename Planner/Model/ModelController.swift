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

    @discardableResult
    func createProject() throws -> Project {
        let now = Date()
        let sortIndex = Self.nextSortIndex(in: fetchedProjects())
        let project = Project(context: ctx)
        project.uuid = UUID()
        project.title = "Untitled Project"
        project.sortIndex = sortIndex
        project.createdAt = now
        project.updatedAt = now
        ctx.processPendingChanges()
        ctx.undoManager?.setActionName("New Project")
        try saveOrThrow()
        return project
    }

    @discardableResult
    func createTask(in project: Project) throws -> TaskItem {
        let task = makeTask(sortIndex: Self.nextSortIndex(in: fetchedSiblings(in: project)))
        task.project = project
        task.parentTask = nil
        ctx.processPendingChanges()
        ctx.undoManager?.setActionName("New Task")
        try saveOrThrow()
        return task
    }

    @discardableResult
    func createSubtask(under parent: TaskItem) throws -> TaskItem {
        let task = makeTask(sortIndex: Self.nextSortIndex(in: fetchedSiblings(under: parent)))
        if wouldIntroduceCycle(child: task, parent: parent) {
            ctx.delete(task)
            ctx.processPendingChanges()
            throw ModelError.cycle
        }
        task.parentTask = parent
        task.project = nil
        ctx.processPendingChanges()
        ctx.undoManager?.setActionName("New Task")
        try saveOrThrow()
        return task
    }

    @discardableResult
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

    @discardableResult
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
        try setNote(task, NoteFormatting.attributedString(rtf: nil, plain: note))
    }

    /// Writes both columns together: `noteRTF` is the content, `note` its
    /// plain-text shadow. They are only ever set here, so they cannot drift.
    func setNote(_ task: TaskItem, _ attributed: NSAttributedString) throws {
        task.noteRTF = NoteFormatting.rtf(from: attributed)
        task.note = NoteFormatting.plainText(from: attributed)
        task.updatedAt = Date()
        ctx.processPendingChanges()
        ctx.undoManager?.setActionName("Edit Note")
        try saveOrThrow()
    }

    func noteText(of task: TaskItem) -> NSAttributedString {
        NoteFormatting.attributedString(rtf: task.noteRTF, plain: task.note)
    }

    /// Writes a day's note, creating the row on first use and deleting it when
    /// the text is cleared, so browsing days never leaves empty rows behind.
    func setDayNote(_ text: String?, on day: Date, calendar: Calendar = .current) throws {
        try setDayNote(
            NoteFormatting.attributedString(rtf: nil, plain: text),
            on: day,
            calendar: calendar
        )
    }

    /// Adds a line to a day's note without replacing what is already there.
    /// Existing rich text is kept; the addition is plain body text. An empty
    /// addition is ignored so a stray call cannot wipe the note.
    func appendDayNote(_ text: String, on day: Date, calendar: Calendar = .current) throws {
        let addition = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addition.isEmpty else { return }
        let existing = dayNoteText(for: day, calendar: calendar)
        let combined = NSMutableAttributedString(attributedString: existing)
        if combined.length > 0, !combined.string.hasSuffix("\n") {
            combined.append(NSAttributedString(string: "\n", attributes: NoteFormatting.typingAttributes))
        }
        combined.append(NSAttributedString(string: addition, attributes: NoteFormatting.typingAttributes))
        try setDayNote(combined, on: day, calendar: calendar)
    }

    func setDayNote(
        _ attributed: NSAttributedString,
        on day: Date,
        calendar: Calendar = .current
    ) throws {
        let normalized = calendar.startOfDay(for: day)
        let plain = NoteFormatting.plainText(from: attributed)
        let rtf = NoteFormatting.rtf(from: attributed)
        let existing = fetchedDayNote(for: normalized)

        switch (existing, plain) {
        case (nil, nil):
            return
        case let (note?, nil):
            ctx.delete(note)
        case let (note?, value?):
            guard note.note != value || note.noteRTF != rtf else { return }
            note.note = value
            note.noteRTF = rtf
            note.updatedAt = Date()
        case let (nil, value?):
            let now = Date()
            let note = DayNote(context: ctx)
            note.uuid = UUID()
            note.day = normalized
            note.note = value
            note.noteRTF = rtf
            note.createdAt = now
            note.updatedAt = now
        }

        ctx.processPendingChanges()
        ctx.undoManager?.setActionName("Edit Note")
        try saveOrThrow()
    }

    func dayNote(for day: Date, calendar: Calendar = .current) -> DayNote? {
        fetchedDayNote(for: calendar.startOfDay(for: day))
    }

    func dayNoteText(for day: Date, calendar: Calendar = .current) -> NSAttributedString {
        let note = dayNote(for: day, calendar: calendar)
        return NoteFormatting.attributedString(rtf: note?.noteRTF, plain: note?.note)
    }

    /// No uniqueness constraint on `day` (CloudKit forbids them), so duplicates
    /// are legal. Order by `(createdAt, uuid)` and take the first, the same
    /// tie-break the outline uses for duplicate `sortIndex` values.
    private func fetchedDayNote(for startOfDay: Date) -> DayNote? {
        let request = DayNote.fetchRequest()
        request.predicate = NSPredicate(format: "day == %@", startOfDay as NSDate)
        request.sortDescriptors = [
            NSSortDescriptor(key: "createdAt", ascending: true),
            NSSortDescriptor(key: "uuid", ascending: true),
        ]
        request.fetchLimit = 1
        return (try? ctx.fetch(request))?.first
    }

    /// Days in `[from, to)` that carry a non-empty note.
    func daysWithNotes(from start: Date, to end: Date) throws -> Set<Date> {
        let request = DayNote.fetchRequest()
        request.predicate = NSPredicate(
            format: "day >= %@ AND day < %@ AND note != nil AND note != ''",
            start as NSDate,
            end as NSDate
        )
        return Set(try ctx.fetch(request).map(\.day))
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

    /// Reparents `task` under a project or another task. The destination owns
    /// the new sort index; a move that would loop a parent under its own child
    /// is refused.
    func move(_ task: TaskItem, under parent: OutlineNode) throws {
        switch parent {
        case let project as Project:
            task.project = project
            task.parentTask = nil
            task.sortIndex = Self.nextSortIndex(in: fetchedSiblings(in: project).filter { $0.objectID != task.objectID })
        case let destination as TaskItem:
            if wouldIntroduceCycle(child: task, parent: destination) {
                throw ModelError.cycle
            }
            task.parentTask = destination
            task.project = nil
            task.sortIndex = Self.nextSortIndex(in: fetchedSiblings(under: destination).filter { $0.objectID != task.objectID })
        default:
            preconditionFailure("unknown OutlineNode")
        }
        task.updatedAt = Date()
        ctx.processPendingChanges()
        ctx.undoManager?.setActionName("Move Task")
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

    func tasks(deadlineInWeeksFrom weekStart: Date, count: Int, calendar: Calendar) throws -> [TaskItem] {
        let start = calendar.startOfDay(for: weekStart)
        return try fetchTasks(deadlineFrom: start, to: calendar.endOfWeeks(from: start, count: count))
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
