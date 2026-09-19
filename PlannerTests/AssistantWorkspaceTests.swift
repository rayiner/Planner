import XCTest
@testable import Planner

final class AssistantWorkspaceTests: XCTestCase {
    func testCreatesDocumentedTemporaryAssistantWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AssistantWorkspaceTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let endpoint = URL(string: "http://127.0.0.1:8757/mcp")!
        let workspace = try AssistantWorkspace(
            endpointURL: endpoint,
            temporaryDirectory: root
        )
        let agentsURL = workspace.url.appendingPathComponent("AGENTS.md")
        let text = try String(contentsOf: agentsURL, encoding: .utf8)

        XCTAssertTrue(workspace.url.lastPathComponent.hasPrefix("Planner-Assistant-"))
        XCTAssertTrue(text.contains("experienced personal assistant"))
        XCTAssertTrue(text.contains(endpoint.absoluteString))
        XCTAssertTrue(text.contains("`search_mail`"))
        XCTAssertTrue(text.contains("`read_mail`"))
        XCTAssertTrue(text.contains("`read_selected_mail`"))
        XCTAssertTrue(text.contains("## Paging"))
        XCTAssertTrue(text.contains("`has_more`"))
        XCTAssertTrue(text.contains("`next_offset`"))
        XCTAssertTrue(text.contains("Only `search_mail` truncates"))
        XCTAssertTrue(text.contains(MCPTools.searchQueryDocumentation))
        XCTAssertTrue(text.contains("Focus on recent mail and current or future events"))
        XCTAssertTrue(text.contains("not calendar-event retrieval"))

        workspace.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.url.path))
    }
}
