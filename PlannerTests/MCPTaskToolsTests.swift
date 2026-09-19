import MCP
import XCTest
@testable import Planner

@MainActor
final class MCPTaskToolsTests: PersistenceTestCase {
    private var source: StubMailSource!
    private var coordinator: MailCoordinator!
    private var selection: SelectionModel!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        source = StubMailSource()
        defaults = UserDefaults(suiteName: "MCPTaskToolsTests.\(UUID().uuidString)")!
        coordinator = MailCoordinator(
            source: source,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            defaults: defaults,
            detailTimeoutSeconds: 2
        )
        selection = SelectionModel(defaults: defaults)
        MCPAppBridge.attach(
            mail: coordinator,
            selection: selection,
            model: model,
            persistence: persistence
        )
    }

    override func tearDown() {
        MCPAppBridge.detach()
        coordinator?.cancel()
        source?.drain()
        coordinator = nil
        source = nil
        selection = nil
        defaults = nil
        super.tearDown()
    }

    func testCreateListAndDeleteTaskFolders() throws {
        let created = try MCPAppBridge.createTaskFolder(title: "Inbox")
        guard case let .object(folder) = created,
              case let .string(idString) = folder["id"],
              let id = UUID(uuidString: idString)
        else {
            return XCTFail("expected folder")
        }
        XCTAssertEqual(folder["title"], .string("Inbox"))

        let listed = try MCPAppBridge.listTaskFolders()
        guard case let .object(object) = listed,
              case let .array(folders) = object["folders"]
        else {
            return XCTFail("expected folders")
        }
        XCTAssertEqual(object["count"], .int(1))
        XCTAssertEqual(folders.count, 1)

        let deleted = try MCPAppBridge.deleteTaskFolder(id: id)
        guard case let .object(deletedObject) = deleted else {
            return XCTFail("expected object")
        }
        XCTAssertEqual(deletedObject["deleted"], .bool(true))
        XCTAssertTrue(try model.allProjects().isEmpty)
    }

    func testCreateListMoveAndModifyTasks() throws {
        let folder = try model.createProject()
        try model.setTitle(folder, "Work")
        let other = try model.createProject()
        try model.setTitle(other, "Home")

        let created = try MCPAppBridge.createTask(
            folderID: folder.uuid,
            parentID: nil,
            title: "File brief",
            note: "Due Friday",
            deadline: date(year: 2026, month: 9, day: 18),
            completed: false
        )
        guard case let .object(taskObject) = created,
              case let .string(idString) = taskObject["id"],
              let id = UUID(uuidString: idString)
        else {
            return XCTFail("expected task")
        }
        XCTAssertEqual(taskObject["title"], .string("File brief"))
        XCTAssertEqual(taskObject["note"], .string("Due Friday"))
        XCTAssertEqual(taskObject["completed"], .bool(false))

        let listed = try MCPAppBridge.listTasks(folderID: folder.uuid)
        guard case let .object(listObject) = listed,
              case let .array(folders) = listObject["folders"],
              case let .object(firstFolder) = folders.first,
              case let .array(tasks) = firstFolder["tasks"]
        else {
            return XCTFail("expected tasks")
        }
        XCTAssertEqual(tasks.count, 1)

        let moved = try MCPAppBridge.moveTask(id: id, folderID: other.uuid, parentID: nil)
        guard case let .object(movedObject) = moved else {
            return XCTFail("expected moved task")
        }
        XCTAssertEqual(movedObject["folder_id"], .string(other.uuid.uuidString))

        let modified = try MCPAppBridge.modifyTask(
            id: id,
            title: "File the brief",
            note: nil,
            deadline: .some(nil),
            completed: true
        )
        guard case let .object(modifiedObject) = modified else {
            return XCTFail("expected modified task")
        }
        XCTAssertEqual(modifiedObject["title"], .string("File the brief"))
        XCTAssertEqual(modifiedObject["completed"], .bool(true))
        XCTAssertEqual(modifiedObject["deadline"], .null)
        XCTAssertEqual(try model.task(uuid: id)?.isCompleted, true)
        XCTAssertNil(try model.task(uuid: id)?.deadline)
    }

    func testCreateTaskRequiresExactlyOneParent() {
        XCTAssertThrowsError(
            try MCPAppBridge.createTask(
                folderID: nil,
                parentID: nil,
                title: "X",
                note: nil,
                deadline: nil,
                completed: nil
            )
        ) { error in
            XCTAssertTrue((error as? MCPToolError)?.message.contains("folder_id") == true)
        }
    }

    func testOpenTaskPutsAWindowOnScreen() throws {
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        try model.setTitle(task, "Notes")

        let value = try MCPAppBridge.openTask(id: task.uuid)
        guard case let .object(object) = value else {
            return XCTFail("expected object")
        }
        XCTAssertEqual(object["opened"], .bool(true))
        XCTAssertTrue(ItemWindowController.openSubjects.contains(.task(task.uuid)))

        try MCPAppBridge.openTask(id: task.uuid)
        XCTAssertEqual(ItemWindowController.openSubjects.filter { $0 == .task(task.uuid) }.count, 1)
    }

    func testAppendTodayNoteAddsALineWithoutReplacing() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        try model.setDayNote("already here", on: today, calendar: calendar)

        let value = try MCPAppBridge.appendTodayNote(text: "  new line  ")
        guard case let .object(object) = value,
              case let .string(note) = object["note"]
        else {
            return XCTFail("expected note")
        }
        XCTAssertEqual(note, "already here\nnew line")
        XCTAssertEqual(model.dayNote(for: today, calendar: calendar)?.note, "already here\nnew line")
        XCTAssertEqual(object["day"], .string(MCPFormat.day(today)))
    }

    func testAppendTodayNoteCreatesTheRowWhenEmpty() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        XCTAssertNil(model.dayNote(for: today, calendar: calendar))

        _ = try MCPAppBridge.appendTodayNote(text: "first")
        XCTAssertEqual(model.dayNote(for: today, calendar: calendar)?.note, "first")
    }

    func testAppendTodayNoteRejectsEmptyText() {
        XCTAssertThrowsError(try MCPAppBridge.appendTodayNote(text: "   ")) { error in
            XCTAssertTrue((error as? MCPToolError)?.message.contains("empty") == true)
        }
    }

    func testOpenMailPutsAWindowOnScreen() async throws {
        let message = MailMessage.fixture(id: 91, subject: "Hello")
        coordinator.remember([message])
        let value = try await MCPAppBridge.openMail(id: 91)
        guard case let .object(object) = value else {
            return XCTFail("expected object")
        }
        XCTAssertEqual(object["opened"], .bool(true))
        XCTAssertTrue(ItemWindowController.openSubjects.contains(.mail(91)))
    }
}
