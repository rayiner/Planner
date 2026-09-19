import MCP
import XCTest
@testable import Planner

@MainActor
final class MCPMailToolsTests: XCTestCase {
    private var source: StubMailSource!
    private var coordinator: MailCoordinator!
    private var selection: SelectionModel!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        source = StubMailSource()
        defaults = UserDefaults(suiteName: "MCPMailToolsTests.\(UUID().uuidString)")!
        coordinator = MailCoordinator(
            source: source,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            defaults: defaults,
            detailTimeoutSeconds: 2
        )
        selection = SelectionModel(defaults: defaults)
        MCPAppBridge.attach(mail: coordinator, selection: selection)
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

    func testSearchMailReturnsEnvelopesAndHonorsLimit() async throws {
        let search = Task {
            try await MCPAppBridge.search(query: "invoice", limit: 1)
        }
        await waitUntil("search request") { self.source.pendingSearchCount >= 1 }
        source.finishSearch(with: [
            .fixture(id: 11, subject: "Invoice A", receivedAt: Date(timeIntervalSince1970: 100)),
            .fixture(id: 12, subject: "Invoice B", receivedAt: Date(timeIntervalSince1970: 200)),
        ])
        let value = try await search.value
        guard case let .object(object) = value else {
            return XCTFail("expected object")
        }
        XCTAssertEqual(object["count"], .int(1))
        XCTAssertEqual(object["truncated"], .bool(true))
        XCTAssertEqual(object["has_more"], .bool(true))
        XCTAssertEqual(object["total"], .int(2))
        XCTAssertEqual(object["offset"], .int(0))
        XCTAssertEqual(object["next_offset"], .int(1))
        XCTAssertEqual(object["query"], .string("invoice"))
        guard case let .array(messages) = object["messages"],
              case let .object(first) = messages.first
        else {
            return XCTFail("expected one envelope")
        }
        // Newest first, then limited to one.
        XCTAssertEqual(first["id"], .int(12))
        XCTAssertEqual(first["subject"], .string("Invoice B"))
    }

    func testSearchMailRejectsEmptyQuery() async {
        do {
            _ = try await MCPAppBridge.search(query: "  ", limit: 50)
            XCTFail("empty query should fail")
        } catch let error as MCPToolError {
            XCTAssertTrue(error.message.contains("empty"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testSearchMailOmitsHiddenMessages() async throws {
        let search = Task {
            try await MCPAppBridge.search(query: "hide", limit: 0)
        }
        await waitUntil("search request") { self.source.pendingSearchCount >= 1 }
        source.finishSearch(with: [
            .fixture(id: 1, subject: "Visible"),
            .fixture(id: 2, subject: "Hidden", isHidden: true),
        ])
        let value = try await search.value
        guard case let .object(object) = value,
              case let .array(messages) = object["messages"]
        else {
            return XCTFail("expected messages")
        }
        XCTAssertEqual(messages.count, 1)
        guard case let .object(first) = messages[0] else { return XCTFail("envelope") }
        XCTAssertEqual(first["id"], .int(1))
    }

    func testSearchMailPagesWithOffset() async throws {
        let search = Task {
            try await MCPAppBridge.search(query: "invoice", limit: 1, offset: 1)
        }
        await waitUntil("search request") { self.source.pendingSearchCount >= 1 }
        source.finishSearch(with: [
            .fixture(id: 11, subject: "Invoice A", receivedAt: Date(timeIntervalSince1970: 100)),
            .fixture(id: 12, subject: "Invoice B", receivedAt: Date(timeIntervalSince1970: 200)),
            .fixture(id: 13, subject: "Invoice C", receivedAt: Date(timeIntervalSince1970: 300)),
        ])
        let value = try await search.value
        guard case let .object(object) = value,
              case let .array(messages) = object["messages"],
              case let .object(first) = messages.first
        else {
            return XCTFail("expected one envelope")
        }
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(first["id"], .int(12))
        XCTAssertEqual(object["offset"], .int(1))
        XCTAssertEqual(object["total"], .int(3))
        XCTAssertEqual(object["has_more"], .bool(true))
        XCTAssertEqual(object["next_offset"], .int(2))
    }

    func testSearchMailLastPageHasNoNextOffset() async throws {
        let search = Task {
            try await MCPAppBridge.search(query: "invoice", limit: 2, offset: 1)
        }
        await waitUntil("search request") { self.source.pendingSearchCount >= 1 }
        source.finishSearch(with: [
            .fixture(id: 11, subject: "Invoice A", receivedAt: Date(timeIntervalSince1970: 100)),
            .fixture(id: 12, subject: "Invoice B", receivedAt: Date(timeIntervalSince1970: 200)),
            .fixture(id: 13, subject: "Invoice C", receivedAt: Date(timeIntervalSince1970: 300)),
        ])
        let value = try await search.value
        guard case let .object(object) = value,
              case let .array(messages) = object["messages"]
        else {
            return XCTFail("expected messages")
        }
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(object["has_more"], .bool(false))
        XCTAssertEqual(object["truncated"], .bool(false))
        XCTAssertEqual(object["next_offset"], .null)
        XCTAssertEqual(object["total"], .int(3))
    }

    func testSearchMailRejectsNegativeOffset() async {
        do {
            _ = try await MCPAppBridge.search(query: "invoice", limit: 50, offset: -1)
            XCTFail("negative offset should fail")
        } catch let error as MCPToolError {
            XCTAssertTrue(error.message.contains("offset"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testReadMailReturnsPlainText() async throws {
        let read = Task { try await MCPAppBridge.readMail(id: 42) }
        await waitUntil("detail request") { self.source.pendingDetailCount >= 1 }
        source.finishDetail(.fixture(id: 42, body: "Please see attached."))
        let value = try await read.value
        guard case let .object(object) = value else { return XCTFail("expected object") }
        XCTAssertEqual(object["id"], .int(42))
        XCTAssertEqual(object["text"], .string("Please see attached."))
    }

    func testReadMailDecodesHTMLWhenBodyIsEmpty() async throws {
        let read = Task { try await MCPAppBridge.readMail(id: 7) }
        await waitUntil("detail request") { self.source.pendingDetailCount >= 1 }
        source.finishDetail(
            .fixture(id: 7, body: "  ", html: "<p>Hello <b>Ada</b></p>")
        )
        let value = try await read.value
        guard case let .object(object) = value,
              case let .string(text) = object["text"]
        else {
            return XCTFail("expected text")
        }
        XCTAssertTrue(text.contains("Hello"))
        XCTAssertTrue(text.contains("Ada"))
    }

    func testReadSelectedMailUsesListSelection() async throws {
        selection.selectMessage(.recent(9))
        let read = Task { try await MCPAppBridge.readSelectedMail() }
        await waitUntil("detail request") { self.source.pendingDetailCount >= 1 }
        XCTAssertEqual(source.requestedDetailIDs, [9])
        source.finishDetail(.fixture(id: 9, body: "Selected body"))
        let value = try await read.value
        guard case let .object(object) = value else { return XCTFail("expected object") }
        XCTAssertEqual(object["id"], .int(9))
        XCTAssertEqual(object["text"], .string("Selected body"))
    }

    func testReadSelectedMailErrorsWhenNothingIsSelected() async {
        do {
            _ = try await MCPAppBridge.readSelectedMail()
            XCTFail("should fail with nothing selected")
        } catch let error as MCPToolError {
            XCTAssertTrue(error.message.contains("No mail is selected"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testSearchMailCatalogDocumentsQuerySyntax() {
        guard let tool = MCPTools.all.first(where: { $0.name == "search_mail" }) else {
            return XCTFail("search_mail is missing from the catalog")
        }
        let description = tool.description ?? ""
        for needle in [
            "`AND`", "`from:`", "`after:`", "`has:attachment`", "Adjacent terms mean AND",
            "`has_more`", "`next_offset`", "`offset`",
        ] {
            XCTAssertTrue(
                description.contains(needle),
                "search_mail description should document \(needle)"
            )
        }
    }

    func testCallUnknownToolIsAnErrorResult() async {
        let result = await MCPTools.call(
            CallTool.Parameters(name: "delete_mail", arguments: [:])
        )
        XCTAssertEqual(result.isError, true)
        guard case let .text(text, _, _) = result.content.first else {
            return XCTFail("expected text content")
        }
        XCTAssertTrue(text.contains("No tool named"))
    }

    func testListMailFoldersReturnsIndexedPaths() async throws {
        source.setFolders([MailFolder(name: "Inbox", messageCount: 8)])
        let value = try await MCPAppBridge.listMailFolders()
        guard case let .object(object) = value,
              case let .array(folders) = object["folders"],
              case let .object(first) = folders.first
        else {
            return XCTFail("expected folders")
        }
        XCTAssertEqual(object["count"], .int(1))
        XCTAssertEqual(first["name"], .string("Inbox"))
        XCTAssertEqual(first["message_count"], .int(8))
    }

    func testSavedQueriesCanBeCreatedListedAndDeleted() throws {
        let created = try MCPAppBridge.createSavedQuery(name: "Patent", query: "patent")
        guard case let .object(createdObject) = created,
              case let .string(idString) = createdObject["id"],
              let id = UUID(uuidString: idString)
        else {
            return XCTFail("expected id")
        }
        XCTAssertEqual(createdObject["query"], .string("patent"))

        let listed = try MCPAppBridge.listSavedQueries()
        guard case let .object(listObject) = listed,
              case let .array(queries) = listObject["queries"]
        else {
            return XCTFail("expected queries")
        }
        XCTAssertEqual(queries.count, 1)

        let deleted = try MCPAppBridge.deleteSavedQuery(id: id)
        guard case let .object(deletedObject) = deleted else {
            return XCTFail("expected object")
        }
        XCTAssertEqual(deletedObject["deleted"], .bool(true))
        XCTAssertTrue(coordinator.quickSearches.isEmpty)
    }

    func testCatalogIncludesMailAndTaskTools() {
        let names = Set(MCPTools.all.map(\.name))
        for name in [
            "search_mail", "list_mail_folders", "create_saved_query", "delete_saved_query",
            "open_mail", "list_task_folders", "create_task", "move_task", "modify_task",
            "open_task", "append_today_note",
        ] {
            XCTAssertTrue(names.contains(name), "missing \(name)")
        }
        XCTAssertFalse(names.contains("delete_task"))
    }

    private func waitUntil(
        _ description: String,
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for \(description)", file: file, line: line)
    }
}
