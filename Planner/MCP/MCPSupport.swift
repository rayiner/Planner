import Foundation
import MCP

/// A tool argument the caller got wrong. Surfaced as an `isError` tool result, so
/// the agent reads the sentence and tries again.
struct MCPToolError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

/// Shared formatting for values that cross into tool results.
enum MCPFormat {
    static func timestamp(_ date: Date) -> String { date.formatted(.iso8601) }

    /// A calendar day, for task deadlines.
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Pretty JSON, which is what a tool result's text content carries.
    static func json(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }
}
