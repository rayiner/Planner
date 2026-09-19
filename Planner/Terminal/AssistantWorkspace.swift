import Foundation

/// A disposable working directory for the terminal's personal-assistant shell.
///
/// It is created lazily when the terminal first opens and removed after the
/// shell has been stopped at quit. A process-specific name keeps a second
/// Planner instance from sharing files with the first.
nonisolated final class AssistantWorkspace {
    let url: URL

    init(
        endpointURL: URL,
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws {
        url = temporaryDirectory.appendingPathComponent(
            "Planner-Assistant-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true
        )
        try? fileManager.removeItem(at: url)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try Self.agentsDocument(endpointURL: endpointURL).write(
            to: url.appendingPathComponent("AGENTS.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    func remove(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: url)
    }

    static func agentsDocument(endpointURL: URL) -> String {
        """
        # Planner Personal Assistant

        You are an experienced personal assistant. Help the user understand and \
        act on their current responsibilities, correspondence, and upcoming work. \
        Focus on recent mail and current or future events unless the user asks \
        for older material or it is necessary to answer the request.

        ## Planner MCP

        Planner exposes a local MCP server at \(endpointURL.absoluteString).
        Configure an MCP client with that streamable HTTP URL. If it is unavailable, \
        ask the user to turn on the MCP server from the Planner application menu.

        Available tools:

        - `search_mail`: search the complete local Outlook mail index and return \
          message envelopes with ids. Results are paged; see Paging below.
        - `read_mail`: retrieve the plain text of a message by an id returned by \
          `search_mail`.
        - `read_selected_mail`: retrieve the text of the message currently selected \
          in Planner.

        Planner's current MCP API exposes mail, not calendar-event retrieval. Do \
        not claim to have inspected calendar events through MCP.

        ## Paging

        Only `search_mail` truncates. Other list tools return the full set.

        `search_mail` returns at most `limit` messages (default 50) from `offset` \
        (default 0). The JSON includes:

        - `total` — matches after hidden messages are dropped
        - `count` — messages in this page
        - `offset` — start index of this page
        - `limit` — page size that was applied (`0` means “the rest from offset”)
        - `has_more` — true if more matches remain after this page
        - `next_offset` — pass this as `offset` on the next call; JSON `null` \
          when there is no next page
        - `truncated` — same as `has_more`

        When `has_more` is true, call `search_mail` again with the same `query` \
        and `limit`, and `offset` set to `next_offset`. Do not skip pages or \
        invent offsets. Keep paging until `has_more` is false if you need every \
        match.

        ## Mail query syntax

        \(MCPTools.searchQueryDocumentation)
        """
    }
}
