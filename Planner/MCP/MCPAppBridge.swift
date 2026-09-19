import AppKit
import MCP

/// Everything the MCP tools do to the running app, gathered behind the main actor.
///
/// The tool handlers run on the MCP server's actor; each one hops here for the
/// state it needs and gets plain `Sendable` values back, so no view or store object
/// ever escapes the main thread.
@MainActor
enum MCPAppBridge {
    /// Tests inject a coordinator and selection instead of going through the
    /// running `AppDelegate`. Production always uses the live ones.
    private static var overrideMail: MailCoordinator?
    private static var overrideSelection: SelectionModel?
    private static var overrideModel: ModelController?
    private static var overridePersistence: PersistenceController?

    static func attach(
        mail: MailCoordinator,
        selection: SelectionModel,
        model: ModelController? = nil,
        persistence: PersistenceController? = nil
    ) {
        overrideMail = mail
        overrideSelection = selection
        overrideModel = model
        overridePersistence = persistence
    }

    static func detach() {
        ItemWindowController.closeAll()
        overrideMail = nil
        overrideSelection = nil
        overrideModel = nil
        overridePersistence = nil
    }

    // MARK: - Search

    /// Searches the complete local index. Does not change the sidebar search
    /// field: an agent query is not the user's query.
    static func search(query rawQuery: String, limit: Int, offset: Int = 0) async throws -> Value {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw MCPToolError("query must not be empty.")
        }
        guard limit >= 0 else {
            throw MCPToolError("limit must be 0 or more.")
        }
        guard offset >= 0 else {
            throw MCPToolError("offset must be 0 or more.")
        }

        let mail = try mailCoordinator()
        let matches = try await mail.searchIndex(query)
        let from = min(offset, matches.count)
        let sliced = limit == 0
            ? Array(matches.dropFirst(from))
            : Array(matches.dropFirst(from).prefix(limit))
        let nextOffset = from + sliced.count
        let hasMore = nextOffset < matches.count
        var object: [String: Value] = [
            "query": .string(query),
            "offset": .int(from),
            "limit": .int(limit),
            "count": .int(sliced.count),
            "total": .int(matches.count),
            "has_more": .bool(hasMore),
            "truncated": .bool(hasMore),
            "messages": .array(sliced.map { envelopeJSON($0) }),
        ]
        object["next_offset"] = hasMore ? .int(nextOffset) : .null
        return .object(object)
    }

    // MARK: - Read

    static func readMail(id: Int64) async throws -> Value {
        try await messageJSON(id: id)
    }

    static func readSelectedMail() async throws -> Value {
        let selection = try selectionModel()
        guard case let .recent(id) = selection.message else {
            throw MCPToolError(
                "No mail is selected in Planner. Select a message in the list, "
                    + "or call read_mail with an id from search_mail.")
        }
        return try await messageJSON(id: id)
    }

    static func listMailFolders() async throws -> Value {
        let folders = try await mailCoordinator().folders()
        return .object([
            "count": .int(folders.count),
            "folders": .array(folders.map { folder in
                .object([
                    "name": .string(folder.name),
                    "message_count": .int(folder.messageCount),
                ])
            }),
        ])
    }

    static func listSavedQueries() throws -> Value {
        let searches = try mailCoordinator().quickSearches
        return .object([
            "count": .int(searches.count),
            "queries": .array(searches.map(savedQueryJSON)),
        ])
    }

    static func createSavedQuery(name: String, query: String) throws -> Value {
        guard let saved = try mailCoordinator().saveQuickSearch(name: name, query: query) else {
            throw MCPToolError("name and query must not be empty.")
        }
        return savedQueryJSON(saved)
    }

    static func deleteSavedQuery(id: UUID) throws -> Value {
        let mail = try mailCoordinator()
        guard mail.quickSearch(id: id) != nil else {
            throw MCPToolError("No saved query with that id.")
        }
        mail.deleteQuickSearch(id: id)
        return .object(["id": .string(id.uuidString), "deleted": .bool(true)])
    }

    static func openMail(id: Int64) async throws -> Value {
        let mail = try mailCoordinator()
        if mail.message(id: id) == nil {
            let hits = try await mail.searchIndex("id:\(id)")
            mail.remember(hits)
        }
        do {
            try ItemWindowController.openMail(id: id, mail: mail)
        } catch let error as MCPToolError {
            throw error
        }
        return .object(["id": .int(Int(id)), "opened": .bool(true)])
    }

    // MARK: - Tasks

    static func listTaskFolders() throws -> Value {
        let folders = try modelController().allProjects()
        return .object([
            "count": .int(folders.count),
            "folders": .array(folders.map { folderJSON($0, includeTasks: false) }),
        ])
    }

    static func createTaskFolder(title: String?) throws -> Value {
        let model = try modelController()
        return try performing {
            let project = try model.createProject()
            if let title {
                try model.setTitle(project, title)
            }
            return folderJSON(project, includeTasks: false)
        }
    }

    static func deleteTaskFolder(id: UUID) throws -> Value {
        let model = try modelController()
        guard let project = try model.project(uuid: id) else {
            throw MCPToolError("No task folder with that id.")
        }
        try performing {
            try model.delete(project)
        }
        return .object(["id": .string(id.uuidString), "deleted": .bool(true)])
    }

    static func listTasks(folderID: UUID?) throws -> Value {
        let model = try modelController()
        let projects: [Project]
        if let folderID {
            guard let project = try model.project(uuid: folderID) else {
                throw MCPToolError("No task folder with that id.")
            }
            projects = [project]
        } else {
            projects = try model.allProjects()
        }
        return .object([
            "folders": .array(projects.map { folderJSON($0, includeTasks: true) }),
        ])
    }

    static func createTask(
        folderID: UUID?,
        parentID: UUID?,
        title: String?,
        note: String?,
        deadline: Date?,
        completed: Bool?
    ) throws -> Value {
        let model = try modelController()
        return try performing {
            let task: TaskItem
            switch (folderID, parentID) {
            case (let folderID?, nil):
                guard let project = try model.project(uuid: folderID) else {
                    throw MCPToolError("No task folder with that id.")
                }
                task = try model.createTask(in: project)
            case (nil, let parentID?):
                guard let parent = try model.task(uuid: parentID) else {
                    throw MCPToolError("No parent task with that id.")
                }
                task = try model.createSubtask(under: parent)
            case (nil, nil):
                throw MCPToolError("Provide folder_id or parent_id.")
            case (.some, .some):
                throw MCPToolError("Provide folder_id or parent_id, not both.")
            }
            if let title { try model.setTitle(task, title) }
            if let note { try model.setNote(task, note) }
            if let deadline { try model.setDeadline(task, date: deadline) }
            if let completed { try model.setCompleted(completed, on: task) }
            return taskJSON(task, includeSubtasks: false)
        }
    }

    static func moveTask(id: UUID, folderID: UUID?, parentID: UUID?) throws -> Value {
        let model = try modelController()
        guard let task = try model.task(uuid: id) else {
            throw MCPToolError("No task with that id.")
        }
        let parent: OutlineNode
        switch (folderID, parentID) {
        case (let folderID?, nil):
            guard let project = try model.project(uuid: folderID) else {
                throw MCPToolError("No task folder with that id.")
            }
            parent = project
        case (nil, let parentID?):
            guard let destination = try model.task(uuid: parentID) else {
                throw MCPToolError("No parent task with that id.")
            }
            parent = destination
        case (nil, nil):
            throw MCPToolError("Provide folder_id or parent_id.")
        case (.some, .some):
            throw MCPToolError("Provide folder_id or parent_id, not both.")
        }
        do {
            try model.move(task, under: parent)
        } catch let error as ModelError {
            throw MCPToolError(error.mcpMessage)
        }
        return taskJSON(task, includeSubtasks: false)
    }

    static func modifyTask(
        id: UUID,
        title: String?,
        note: String?,
        deadline: Date??,
        completed: Bool?
    ) throws -> Value {
        let model = try modelController()
        guard let task = try model.task(uuid: id) else {
            throw MCPToolError("No task with that id.")
        }
        do {
            if let title { try model.setTitle(task, title) }
            if let note { try model.setNote(task, note) }
            if let deadline { try model.setDeadline(task, date: deadline) }
            if let completed { try model.setCompleted(completed, on: task) }
        } catch let error as ModelError {
            throw MCPToolError(error.mcpMessage)
        }
        return taskJSON(task, includeSubtasks: false)
    }

    static func openTask(id: UUID) throws -> Value {
        let model = try modelController()
        let persistence = try persistenceController()
        try ItemWindowController.openTask(uuid: id, persistence: persistence, model: model)
        return .object(["id": .string(id.uuidString), "opened": .bool(true)])
    }

    static func appendTodayNote(text: String) throws -> Value {
        let addition = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addition.isEmpty else {
            throw MCPToolError("text must not be empty.")
        }
        let model = try modelController()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        try performing {
            try model.appendDayNote(addition, on: today, calendar: calendar)
        }
        let note = model.dayNoteText(for: today, calendar: calendar).string
        return .object([
            "day": .string(MCPFormat.day(today)),
            "note": .string(note),
        ])
    }

    // MARK: - Plumbing

    private static func mailCoordinator() throws -> MailCoordinator {
        if let overrideMail { return overrideMail }
        guard let mail = (NSApp.delegate as? AppDelegate)?.mail else {
            throw MCPToolError("Planner is still starting. Try again in a moment.")
        }
        return mail
    }

    private static func selectionModel() throws -> SelectionModel {
        if let overrideSelection { return overrideSelection }
        guard let selection = (NSApp.delegate as? AppDelegate)?.selection else {
            throw MCPToolError("Planner is still starting. Try again in a moment.")
        }
        return selection
    }

    private static func modelController() throws -> ModelController {
        if let overrideModel { return overrideModel }
        guard let model = (NSApp.delegate as? AppDelegate)?.model else {
            throw MCPToolError("Planner is still starting. Try again in a moment.")
        }
        return model
    }

    private static func persistenceController() throws -> PersistenceController {
        if let overridePersistence { return overridePersistence }
        guard let persistence = (NSApp.delegate as? AppDelegate)?.persistence else {
            throw MCPToolError("Planner is still starting. Try again in a moment.")
        }
        return persistence
    }

    private static func performing<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as MCPToolError {
            throw error
        } catch let error as ModelError {
            throw MCPToolError(error.mcpMessage)
        }
    }

    private static func messageJSON(id: Int64) async throws -> Value {
        let mail = try mailCoordinator()
        let envelope = mail.message(id: id)
        let detail: MailMessageDetail
        do {
            detail = try await mail.loadDetail(for: id)
        } catch {
            throw MCPToolError(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }

        var object = envelopeJSONObject(envelope, id: id)
        object["text"] = .string(plainText(of: detail))
        object["recipients"] = detail.recipients.map(Value.string) ?? .null
        object["has_attachments"] = .bool(detail.hasAttachments)
        object["attachment_names"] = detail.attachmentNames.map(Value.string) ?? .null
        return .object(object)
    }

    private static func envelopeJSON(_ message: MailMessage) -> Value {
        .object(envelopeJSONObject(message, id: message.id))
    }

    private static func envelopeJSONObject(_ message: MailMessage?, id: Int64) -> [String: Value] {
        var object: [String: Value] = [
            "id": .int(Int(id))
        ]
        guard let message else { return object }
        object["subject"] = .string(message.subject)
        object["sender"] = .string(message.senderDisplayName)
        object["sender_address"] = .string(message.senderAddress)
        object["received_at"] = .string(MCPFormat.timestamp(message.receivedAt))
        object["is_read"] = .bool(message.isRead)
        object["is_hidden"] = .bool(message.isHidden)
        object["preview"] = .string(message.preview)
        return object
    }

    private static func savedQueryJSON(_ search: MailQuickSearch) -> Value {
        .object([
            "id": .string(search.id.uuidString),
            "name": .string(search.name),
            "query": .string(search.query),
        ])
    }

    private static func folderJSON(_ project: Project, includeTasks: Bool) -> Value {
        var object: [String: Value] = [
            "id": .string(project.uuid.uuidString),
            "title": .string(project.title),
        ]
        if includeTasks {
            object["tasks"] = .array(project.outlineChildren.compactMap { node in
                (node as? TaskItem).map { taskJSON($0, includeSubtasks: true) }
            })
        } else {
            object["task_count"] = .int(descendantTaskCount(of: project))
        }
        return .object(object)
    }

    private static func taskJSON(_ task: TaskItem, includeSubtasks: Bool) -> Value {
        var object: [String: Value] = [
            "id": .string(task.uuid.uuidString),
            "title": .string(task.title),
            "completed": .bool(task.isCompleted),
            "deadline": task.deadline.map { .string(MCPFormat.day($0)) } ?? .null,
            "note": task.note.map(Value.string) ?? .null,
            "folder_id": owningProject(of: task).map { .string($0.uuid.uuidString) } ?? .null,
            "parent_id": task.parentTask.map { .string($0.uuid.uuidString) } ?? .null,
        ]
        if includeSubtasks {
            object["subtasks"] = .array(
                task.outlineChildren.compactMap { node in
                    (node as? TaskItem).map { taskJSON($0, includeSubtasks: true) }
                }
            )
        }
        return .object(object)
    }

    private static func owningProject(of task: TaskItem) -> Project? {
        if let project = task.project { return project }
        var cursor = task.parentTask
        while let node = cursor {
            if let project = node.project { return project }
            cursor = node.parentTask
        }
        return nil
    }

    private static func descendantTaskCount(of project: Project) -> Int {
        func count(from task: TaskItem) -> Int {
            1 + task.subtasks.reduce(0) { $0 + count(from: $1) }
        }
        return project.tasks.reduce(0) { $0 + count(from: $1) }
    }

    /// The body the reader would show as text: Outlook's plain part, or the
    /// HTML decoded the same way the pane decodes it when there is no plain part.
    private static func plainText(of detail: MailMessageDetail) -> String {
        let trimmed = detail.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return detail.body }
        return MailBodyFormatting.attributedString(html: detail.html, plain: detail.body).string
    }
}

extension ModelError {
    var mcpMessage: String {
        switch self {
        case .saveFailed: return "Couldn't save."
        case .emptyTitle: return "Title must not be empty."
        case .cycle: return "That move would nest a task under one of its own subtasks."
        }
    }
}
