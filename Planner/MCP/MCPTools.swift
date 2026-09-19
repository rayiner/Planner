import Foundation
import MCP

/// The tools this app exposes over MCP, and the code behind them.
///
/// An agent sitting next to Planner needs three things from the mail it already
/// shows: searching the local index, reading one message by the id a search
/// returned, and reading whatever is currently selected so the person and the
/// agent are looking at the same thing.
///
/// Every result is JSON in a text content block.
enum MCPTools {
    /// Kept separately because the terminal's generated AGENTS.md gives the
    /// same grammar to an assistant before it has listed MCP tools.
    nonisolated static let searchQueryDocumentation = """
        Terms are `field:value`, a `"quoted phrase"`, or a bare word. Bare words \
        and unscoped phrases match subject and body together. Quoted text is a \
        literal phrase. `AND`, `OR`, and `NOT` combine terms; a leading `-` or \
        `!` also means NOT. Adjacent terms mean AND. Parentheses group. NOT \
        binds tightest, then AND, then OR.

        Fields (aliases in parentheses):
        - `subject:` (`subj`) — subject line
        - `body:` — message text
        - `from:` (`sender`) — sender
        - `to:` — direct recipients
        - `cc:` (`copied`) — copied recipients, including bcc
        - `people:` (`person`, `anyone`, `with`) — any participant
        - `attachment:` (`attach`, `file`, `filename`) — attachment filename \
          and extracted text once indexed
        - `folder:` (`in`) — that folder and everything under it
        - `domain:` — any participant at this email domain, including subdomains
        - `has:attachment` — messages with at least one attachment
        - `category:` (`cat`, `tag`) — Outlook category by name or local id
        - `is:read` / `is:unread` — Outlook's read flag
        - `after:` / `before:` (`since`, `until`) — `YYYY-MM-DD`, a Unix \
          timestamp, or a relative `30d` / `12h`
        - `id:` (`record`) — Outlook record id
        - `message-id:` (`msgid`) — RFC822 Message-ID
        - `account:` / `fidelity:` — account uid; `original-mime` or `rebuilt-html`

        Examples:
        - `from:lamken AND patent`
        - `subject:"summary judgment" -folder:Drafts`
        - `(from:lamken OR cc:lamken) after:30d has:attachment`
        - `domain:uscourts.gov AND NOT folder:"Deleted Items"`
        - `category:Patent is:unread`
        - `attachment:brief AND before:2026-01-01`
        """

    /// Sent to the client at initialization, ahead of the tool list.
    /// `nonisolated` because the HTTP router builds a `Server` off the main actor.
    nonisolated static let instructions = """
        Planner is a macOS task manager that also shows Outlook mail from a local \
        index. Tasks live in folders (projects). Use the task tools to list, \
        create, and rename those folders; list and create tasks; move a task \
        between folders or under another task; and change a task's title, note, \
        deadline, or completed flag. Tasks cannot be deleted over MCP.

        Mail: use `search_mail` to find messages (subject, sender, date, a short \
        preview, and an `id`). Its query language is field-scoped terms joined \
        with AND / OR / NOT and parentheses — the same syntax as the sidebar \
        search; the search_mail tool description is the grammar. Results are \
        paged: default `limit` is 50. When `has_more` is true, call again with \
        the same query and `offset` set to `next_offset`. Use `read_mail` \
        with an `id` for the full plain text. Use `read_selected_mail` when \
        the user is already looking at a message in Planner. `list_mail_folders` \
        names the indexed folders `folder:` search accepts. Saved queries are \
        named whole-index searches in the sidebar; create and delete those with \
        the saved-query tools.

        To put a task or a message in front of the person using the app, call \
        `open_task` or `open_mail`. That opens a small window with that one item.

        `append_today_note` adds a line to the calendar note for today without \
        replacing what is already there.
        """

    // MARK: - Catalog

    nonisolated static let all: [Tool] = [
        Tool(
            name: "search_mail",
            title: "Search mail",
            description: """
                Search Planner's complete local mail index. Unlike Recent Mail this \
                has no date-window constraint. Returns envelopes (id, subject, \
                sender, date, preview) — call read_mail with an id for the full \
                text. Does not change what is selected on screen.

                Paging: `limit` defaults to 50. If `has_more` is true, pass the \
                returned `next_offset` as `offset` with the same query for the \
                next page. `offset` 0 is the first page. `limit` 0 returns \
                everything from `offset` onward.

                Query language (same as the sidebar search / olsearchmail):

                \(searchQueryDocumentation)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "query": .object([
                        "type": "string",
                        "description": """
                            Field-scoped search. Bare words match subject and \
                            body. Combine with AND / OR / NOT (also -term) and \
                            parentheses; adjacency means AND. Quote multi-word \
                            values: subject:"summary judgment". Dates: \
                            after:2026-01-01 or after:30d. See the tool \
                            description for every field.
                            """,
                    ]),
                    "limit": .object([
                        "type": "integer",
                        "description":
                            "Maximum messages to return. Defaults to 50; 0 for all from offset.",
                        "minimum": 0,
                    ]),
                    "offset": .object([
                        "type": "integer",
                        "description":
                            "Skip this many matches before returning a page. Defaults to 0.",
                        "minimum": 0,
                    ]),
                ]),
                "required": .array(["query"]),
            ]),
            annotations: .init(readOnlyHint: true, openWorldHint: false)),

        Tool(
            name: "read_mail",
            title: "Read mail",
            description: """
                The plain text of one message, by the `id` search_mail returned. \
                Also includes subject, sender, date, recipients and attachment \
                names when Planner already has that envelope.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "id": .object([
                        "type": "integer",
                        "description": "The message id from search_mail (or from a previous read).",
                    ]),
                ]),
                "required": .array(["id"]),
            ]),
            annotations: .init(readOnlyHint: true, openWorldHint: false)),

        Tool(
            name: "read_selected_mail",
            title: "Read selected mail",
            description: """
                The plain text of the message currently selected in Planner's mail \
                list — the one the reading pane is showing. Errors if nothing is \
                selected. Use this when the user is talking about the open message; \
                use search_mail and read_mail for everything else.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([:]),
            ]),
            annotations: .init(readOnlyHint: true, openWorldHint: false)),

        Tool(
            name: "list_mail_folders",
            title: "List mail folders",
            description: """
                Indexed Outlook folders and how many messages each currently \
                holds. Names are what `folder:` accepts in search_mail.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([:]),
            ]),
            annotations: .init(readOnlyHint: true, openWorldHint: false)),

        Tool(
            name: "list_saved_queries",
            title: "List saved queries",
            description: "Named whole-index mail searches saved in Planner's sidebar.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([:]),
            ]),
            annotations: .init(readOnlyHint: true, openWorldHint: false)),

        Tool(
            name: "create_saved_query",
            title: "Create saved query",
            description: """
                Save a named whole-index mail search in the sidebar. Saving an \
                existing name (case-insensitive) updates its query.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "name": .object([
                        "type": "string",
                        "description": "Sidebar label for this search.",
                    ]),
                    "query": .object([
                        "type": "string",
                        "description": "The search_mail query language.",
                    ]),
                ]),
                "required": .array(["name", "query"]),
            ]),
            annotations: .init(readOnlyHint: false, openWorldHint: false)),

        Tool(
            name: "delete_saved_query",
            title: "Delete saved query",
            description: "Remove a named mail search from the sidebar by the id list_saved_queries returned.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "id": .object([
                        "type": "string",
                        "description": "The saved query id.",
                    ]),
                ]),
                "required": .array(["id"]),
            ]),
            annotations: .init(readOnlyHint: false, openWorldHint: false)),

        Tool(
            name: "open_mail",
            title: "Open mail",
            description: """
                Open one message in a small window in front of the user, by the \
                `id` search_mail returned.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "id": .object([
                        "type": "integer",
                        "description": "The message id from search_mail.",
                    ]),
                ]),
                "required": .array(["id"]),
            ]),
            annotations: .init(readOnlyHint: true, openWorldHint: false)),

        Tool(
            name: "list_task_folders",
            title: "List task folders",
            description: "Projects in Planner: id, title, and how many tasks each contains.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([:]),
            ]),
            annotations: .init(readOnlyHint: true, openWorldHint: false)),

        Tool(
            name: "create_task_folder",
            title: "Create task folder",
            description: "Create a project (task folder). Omit title for “Untitled Project”.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "title": .object([
                        "type": "string",
                        "description": "Folder name.",
                    ]),
                ]),
            ]),
            annotations: .init(readOnlyHint: false, openWorldHint: false)),

        Tool(
            name: "delete_task_folder",
            title: "Delete task folder",
            description: "Delete a project and every task in it. Tasks themselves cannot be deleted over MCP.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "id": .object([
                        "type": "string",
                        "description": "The folder id from list_task_folders.",
                    ]),
                ]),
                "required": .array(["id"]),
            ]),
            annotations: .init(readOnlyHint: false, openWorldHint: false)),

        Tool(
            name: "list_tasks",
            title: "List tasks",
            description: """
                Tasks nested under their folders. Omit folder_id to list every \
                folder. Each task includes id, title, completed, deadline, note, \
                parent_id, and subtasks.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "folder_id": .object([
                        "type": "string",
                        "description": "Limit the listing to this folder.",
                    ]),
                ]),
            ]),
            annotations: .init(readOnlyHint: true, openWorldHint: false)),

        Tool(
            name: "create_task",
            title: "Create task",
            description: """
                Create a task in a folder or as a subtask of another task. \
                Provide exactly one of folder_id or parent_id. Tasks cannot be \
                deleted over MCP.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "folder_id": .object([
                        "type": "string",
                        "description": "Create the task at the top of this folder.",
                    ]),
                    "parent_id": .object([
                        "type": "string",
                        "description": "Create the task under this existing task.",
                    ]),
                    "title": .object(["type": "string", "description": "Defaults to Untitled Task."]),
                    "note": .object(["type": "string", "description": "Plain-text note."]),
                    "deadline": .object([
                        "type": "string",
                        "description": "Due date as YYYY-MM-DD.",
                    ]),
                    "completed": .object(["type": "boolean"]),
                ]),
            ]),
            annotations: .init(readOnlyHint: false, openWorldHint: false)),

        Tool(
            name: "move_task",
            title: "Move task",
            description: """
                Move a task into a folder or under another task. Provide exactly \
                one of folder_id or parent_id. Refuses a move that would nest a \
                task under one of its own subtasks.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "id": .object(["type": "string", "description": "The task to move."]),
                    "folder_id": .object([
                        "type": "string",
                        "description": "Move the task to the top of this folder.",
                    ]),
                    "parent_id": .object([
                        "type": "string",
                        "description": "Move the task under this task.",
                    ]),
                ]),
                "required": .array(["id"]),
            ]),
            annotations: .init(readOnlyHint: false, openWorldHint: false)),

        Tool(
            name: "modify_task",
            title: "Modify task",
            description: """
                Change a task's title, note, deadline, or completed flag. Omitted \
                fields are left as they are. Pass deadline as null to clear it, \
                or YYYY-MM-DD to set it.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "id": .object(["type": "string", "description": "The task to change."]),
                    "title": .object(["type": "string"]),
                    "note": .object(["type": "string"]),
                    "deadline": .object([
                        "description": "YYYY-MM-DD, or null to clear.",
                    ]),
                    "completed": .object(["type": "boolean"]),
                ]),
                "required": .array(["id"]),
            ]),
            annotations: .init(readOnlyHint: false, openWorldHint: false)),

        Tool(
            name: "open_task",
            title: "Open task",
            description: "Open one task and its note in a small window in front of the user.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "id": .object([
                        "type": "string",
                        "description": "The task id from list_tasks.",
                    ]),
                ]),
                "required": .array(["id"]),
            ]),
            annotations: .init(readOnlyHint: true, openWorldHint: false)),

        Tool(
            name: "append_today_note",
            title: "Append today's note",
            description: """
                Add text to the calendar note for today. Existing content is \
                kept; the addition is placed on a new line. Does not replace \
                or clear the note.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "text": .object([
                        "type": "string",
                        "description": "Plain text to append.",
                    ]),
                ]),
                "required": .array(["text"]),
            ]),
            annotations: .init(readOnlyHint: false, openWorldHint: false)),
    ]

    // MARK: - Dispatch

    static func call(_ params: CallTool.Parameters) async -> CallTool.Result {
        let arguments = Arguments(params.arguments ?? [:])
        do {
            let value: Value
            switch params.name {
            case "search_mail": value = try await searchMail(arguments)
            case "read_mail": value = try await readMail(arguments)
            case "read_selected_mail": value = try await MCPAppBridge.readSelectedMail()
            case "list_mail_folders": value = try await MCPAppBridge.listMailFolders()
            case "list_saved_queries": value = try MCPAppBridge.listSavedQueries()
            case "create_saved_query":
                value = try MCPAppBridge.createSavedQuery(
                    name: try arguments.string("name"),
                    query: try arguments.string("query")
                )
            case "delete_saved_query":
                value = try MCPAppBridge.deleteSavedQuery(id: try arguments.uuid("id"))
            case "open_mail": value = try await MCPAppBridge.openMail(id: try arguments.int64("id"))
            case "list_task_folders": value = try MCPAppBridge.listTaskFolders()
            case "create_task_folder":
                value = try MCPAppBridge.createTaskFolder(title: try arguments.optionalString("title"))
            case "delete_task_folder":
                value = try MCPAppBridge.deleteTaskFolder(id: try arguments.uuid("id"))
            case "list_tasks":
                value = try MCPAppBridge.listTasks(folderID: try arguments.optionalUUID("folder_id"))
            case "create_task":
                value = try MCPAppBridge.createTask(
                    folderID: try arguments.optionalUUID("folder_id"),
                    parentID: try arguments.optionalUUID("parent_id"),
                    title: try arguments.optionalString("title"),
                    note: try arguments.optionalString("note"),
                    deadline: try arguments.optionalDate("deadline"),
                    completed: try arguments.optionalBool("completed")
                )
            case "move_task":
                value = try MCPAppBridge.moveTask(
                    id: try arguments.uuid("id"),
                    folderID: try arguments.optionalUUID("folder_id"),
                    parentID: try arguments.optionalUUID("parent_id")
                )
            case "modify_task":
                value = try MCPAppBridge.modifyTask(
                    id: try arguments.uuid("id"),
                    title: try arguments.optionalString("title"),
                    note: try arguments.optionalString("note"),
                    deadline: try arguments.optionalNullableDate("deadline"),
                    completed: try arguments.optionalBool("completed")
                )
            case "open_task":
                value = try MCPAppBridge.openTask(id: try arguments.uuid("id"))
            case "append_today_note":
                value = try MCPAppBridge.appendTodayNote(text: try arguments.string("text"))
            default:
                throw MCPToolError(
                    "No tool named “\(params.name)”. This server has: "
                        + all.map(\.name).joined(separator: ", ") + ".")
            }
            return .init(content: [.text(text: MCPFormat.json(value), annotations: nil, _meta: nil)])
        } catch {
            let message = (error as? MCPToolError)?.message ?? error.localizedDescription
            return .init(
                content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
        }
    }

    private static func searchMail(_ arguments: Arguments) async throws -> Value {
        let query = try arguments.string("query")
        let limit = try arguments.optionalInt("limit") ?? 50
        let offset = try arguments.optionalInt("offset") ?? 0
        return try await MCPAppBridge.search(query: query, limit: limit, offset: offset)
    }

    private static func readMail(_ arguments: Arguments) async throws -> Value {
        try await MCPAppBridge.readMail(id: try arguments.int64("id"))
    }
}

// MARK: - Arguments

/// Typed reads of a tool call's arguments, with the message the agent should see
/// when one is the wrong shape.
private struct Arguments {
    private let values: [String: Value]

    init(_ values: [String: Value]) {
        self.values = values
    }

    func string(_ name: String) throws -> String {
        guard let value = values[name] else {
            throw MCPToolError("\(name) is required.")
        }
        guard let string = value.stringValue else {
            throw MCPToolError("\(name) must be a string.")
        }
        return string
    }

    func optionalString(_ name: String) throws -> String? {
        guard let value = values[name], value != .null else { return nil }
        guard let string = value.stringValue else {
            throw MCPToolError("\(name) must be a string.")
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func uuid(_ name: String) throws -> UUID {
        guard let parsed = try optionalUUID(name) else {
            throw MCPToolError("\(name) is required.")
        }
        return parsed
    }

    func optionalUUID(_ name: String) throws -> UUID? {
        guard let raw = try optionalString(name) else { return nil }
        guard let uuid = UUID(uuidString: raw) else {
            throw MCPToolError("\(name) must be a UUID.")
        }
        return uuid
    }

    func optionalBool(_ name: String) throws -> Bool? {
        guard let value = values[name], value != .null else { return nil }
        if let flag = value.boolValue { return flag }
        throw MCPToolError("\(name) must be true or false.")
    }

    func optionalDate(_ name: String) throws -> Date? {
        guard let raw = try optionalString(name) else { return nil }
        return try Self.parseDay(raw, name: name)
    }

    /// Missing leaves the field unchanged; JSON null clears it.
    func optionalNullableDate(_ name: String) throws -> Date?? {
        guard let value = values[name] else { return nil }
        if value == .null { return .some(nil) }
        guard let string = value.stringValue else {
            throw MCPToolError("\(name) must be a date string or null.")
        }
        return try Self.parseDay(string, name: name)
    }

    private static func parseDay(_ raw: String, name: String) throws -> Date {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        if let date = formatter.date(from: trimmed) {
            return Calendar.current.startOfDay(for: date)
        }
        if let date = try? Date(trimmed, strategy: .iso8601) {
            return Calendar.current.startOfDay(for: date)
        }
        throw MCPToolError("\(name) must be YYYY-MM-DD.")
    }

    /// Accepts a JSON number that arrived as a double (`3.0`) as well as an int.
    func optionalInt(_ name: String) throws -> Int? {
        guard let value = values[name], value != .null else { return nil }
        if let int = value.intValue { return int }
        if let double = value.doubleValue, double == double.rounded() { return Int(double) }
        throw MCPToolError("\(name) must be a whole number.")
    }

    /// A message id. JSON numbers are the usual form; a decimal string is also
    /// accepted so a client that stringifies large integers still works.
    func int64(_ name: String) throws -> Int64 {
        guard let value = values[name], value != .null else {
            throw MCPToolError("\(name) is required.")
        }
        if let int = value.intValue { return Int64(int) }
        if let double = value.doubleValue, double == double.rounded() {
            return Int64(double)
        }
        if let string = value.stringValue,
            let parsed = Int64(string.trimmingCharacters(in: .whitespacesAndNewlines))
        {
            return parsed
        }
        throw MCPToolError("\(name) must be a message id.")
    }
}
