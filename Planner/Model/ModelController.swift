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

    // MARK: - Mail folders

    @discardableResult
    func createMailFolder(name: String = "Untitled Folder") throws -> MailFolder {
        let now = Date()
        // Computed before the insert: a fetch sees pending changes, so asking
        // afterwards would count the new folder's own default index.
        let sortIndex = (fetchedMailFolders().map(\.sortIndex).max() ?? -1) + 1
        let folder = MailFolder(context: ctx)
        folder.uuid = UUID()
        folder.name = name
        folder.sortIndex = sortIndex
        folder.createdAt = now
        folder.updatedAt = now
        ctx.processPendingChanges()
        ctx.undoManager?.setActionName("New Folder")
        try saveOrThrow()
        return folder
    }

    func renameMailFolder(_ folder: MailFolder, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ModelError.emptyTitle }
        folder.name = trimmed
        folder.updatedAt = Date()
        ctx.processPendingChanges()
        ctx.undoManager?.setActionName("Rename Folder")
        try saveOrThrow()
    }

    /// Cascades to the folder's messages, per the model. The confirmation sheet
    /// is the view controller's job, exactly as it is for projects.
    func deleteMailFolder(_ folder: MailFolder) throws {
        ctx.delete(folder)
        ctx.processPendingChanges()
        ctx.undoManager?.setActionName("Delete Folder")
        try saveOrThrow()
    }

    func mailFolders() -> [MailFolder] {
        let request = MailFolder.fetchRequest()
        request.sortDescriptors = Self.folderSortDescriptors
        return (try? ctx.fetch(request)) ?? []
    }

    // MARK: - Saved messages

    /// Copies a message into a folder, or returns the copy already there.
    ///
    /// Idempotent by `messageID` **within the folder**: saving the same message
    /// twice is a no-op, but the same message may legitimately sit in two
    /// folders. Since CloudKit forbids a uniqueness constraint, this lookup is
    /// the only thing enforcing it — which is why every save goes through here.
    @discardableResult
    func saveMessage(
        _ envelope: MailMessage,
        detail: MailMessageDetail?,
        into folder: MailFolder
    ) throws -> SavedMessage {
        let messageID = Self.normalizedMessageID(detail?.messageID, fallbackFor: envelope)
        if let existing = savedMessage(messageID: messageID, in: folder) { return existing }

        let now = Date()
        let message = SavedMessage(context: ctx)
        message.uuid = UUID()
        message.messageID = messageID
        message.subject = envelope.subject
        message.senderName = envelope.senderName
        message.senderAddress = envelope.senderAddress
        message.recipients = detail?.recipients
        message.receivedAt = envelope.receivedAt
        message.body = detail?.body
        message.inReplyTo = detail?.inReplyTo
        message.references = detail?.references
        message.attachmentNames = detail?.attachmentNames
        message.hasAttachments = detail?.hasAttachments ?? false
        message.outlookID = envelope.id
        message.createdAt = now
        message.updatedAt = now
        message.folder = folder
        folder.updatedAt = now
        ctx.processPendingChanges()
        ctx.undoManager?.setActionName("Save Message")
        try saveOrThrow()
        return message
    }

    /// Moves a saved message between folders, collapsing into the copy already
    /// at the destination rather than creating a duplicate.
    func moveMessage(_ message: SavedMessage, to folder: MailFolder) throws {
        guard message.folder?.objectID != folder.objectID else { return }
        let now = Date()
        if let duplicate = savedMessage(messageID: message.messageID, in: folder),
           duplicate.objectID != message.objectID {
            ctx.delete(message)
        } else {
            message.folder = folder
            message.updatedAt = now
        }
        folder.updatedAt = now
        ctx.processPendingChanges()
        ctx.undoManager?.setActionName("Move Message")
        try saveOrThrow()
    }

    func removeMessage(_ message: SavedMessage) throws {
        message.folder?.updatedAt = Date()
        ctx.delete(message)
        ctx.processPendingChanges()
        ctx.undoManager?.setActionName("Remove Message")
        try saveOrThrow()
    }

    /// Newest first, matching the reading order of a conversation.
    func messages(in folder: MailFolder) -> [SavedMessage] {
        folder.messages.sorted {
            $0.receivedAt == $1.receivedAt ? $0.uuid < $1.uuid : $0.receivedAt > $1.receivedAt
        }
    }

    func savedMessage(uuid: UUID) -> SavedMessage? {
        let request = SavedMessage.fetchRequest()
        request.predicate = NSPredicate(format: "uuid == %@", uuid as CVarArg)
        request.fetchLimit = 1
        return (try? ctx.fetch(request))?.first
    }

    /// Which folder already holds this message, for the "Saved to X" chip in
    /// Recent Mail. Returns the first by `(sortIndex, uuid)` if somehow several
    /// do — a chip has room for one name, and the list order settles which.
    func folderContaining(messageID: String) -> MailFolder? {
        guard !messageID.isEmpty else { return nil }
        let request = SavedMessage.fetchRequest()
        request.predicate = NSPredicate(format: "messageID == %@", messageID)
        let folders = ((try? ctx.fetch(request)) ?? []).compactMap(\.folder)
        return folders.min { ($0.sortIndex, $0.uuid) < ($1.sortIndex, $1.uuid) }
    }

    /// Every folder holding a copy of this message, keyed by message id — one
    /// fetch for a whole list, rather than one per visible row.
    func foldersByMessageID() -> [String: MailFolder] {
        var index: [String: MailFolder] = [:]
        for message in (try? ctx.fetch(SavedMessage.fetchRequest())) ?? [] {
            guard let folder = message.folder, !message.messageID.isEmpty else { continue }
            if let existing = index[message.messageID],
               (existing.sortIndex, existing.uuid) <= (folder.sortIndex, folder.uuid) {
                continue
            }
            index[message.messageID] = folder
        }
        return index
    }

    private func savedMessage(messageID: String, in folder: MailFolder) -> SavedMessage? {
        guard !messageID.isEmpty else { return nil }
        return folder.messages.first { $0.messageID == messageID }
    }

    /// A message with no `Message-ID` header still has to dedupe against
    /// itself, so it falls back to a synthetic id derived from Outlook's record
    /// id. Scoped by a prefix so it can never collide with a real header.
    static func normalizedMessageID(_ headerValue: String?, fallbackFor envelope: MailMessage) -> String {
        let trimmed = headerValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "outlook-id:\(envelope.id)" : trimmed
    }

    // MARK: - Tasks from messages

    /// Creates a task under `parent` titled from the message and linked back to
    /// it. The link is a UUID rather than a relationship, so removing the
    /// message later leaves the task alone.
    @discardableResult
    func createTask(from message: SavedMessage, under parent: OutlineNode) throws -> TaskItem {
        let task = try createTask(under: parent)
        task.title = Self.taskTitle(fromSubject: message.subject)
        task.sourceMessageUUID = message.uuid
        task.updatedAt = Date()
        ctx.processPendingChanges()
        ctx.undoManager?.setActionName("New Task")
        try saveOrThrow()
        return task
    }

    /// The message this task came from, or nil if it was never linked or the
    /// message has since been removed.
    func sourceMessage(of task: TaskItem) -> SavedMessage? {
        guard let uuid = task.sourceMessageUUID else { return nil }
        return savedMessage(uuid: uuid)
    }

    /// Subjects arrive with reply and forward prefixes that say nothing about
    /// the work; an empty subject falls back to the default task title rather
    /// than an empty one, which the store forbids.
    static func taskTitle(fromSubject subject: String) -> String {
        let stripped = MailThreading.normalizedSubject(subject)
        return stripped.isEmpty ? "Untitled Task" : stripped
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
        let start = calendar.startOfWeek(for: weekStart)
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

    private static let folderSortDescriptors = [
        NSSortDescriptor(key: "sortIndex", ascending: true),
        NSSortDescriptor(key: "uuid", ascending: true),
    ]

    private func fetchedMailFolders() -> [MailFolder] {
        (try? ctx.fetch(MailFolder.fetchRequest())) ?? []
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
