import Foundation

/// Where external calendar events come from.
///
/// Not `@MainActor`: implementations are expected to be slow (the Outlook
/// source costs ~2s of Apple events) and must do their work off the main
/// thread. Only `Sendable` values cross the boundary, which is what keeps
/// non-`Sendable` bridge objects from ever escaping their own queue.
///
/// This protocol is the seam that lets the model, the coordinator, and the grid
/// be built and tested with no Outlook anywhere near them.
nonisolated protocol CalendarEventSource: Sendable {
    var sourceID: String { get }
    /// Shown in error messages and the refresh tooltip, e.g. a calendar name.
    var displayName: String { get }

    /// - Parameter userInitiated: An explicit refresh may raise a system
    ///   consent dialog; an automatic one (launch, day rollover) must not.
    func events(in range: Range<Date>, userInitiated: Bool) async throws -> [CalendarEvent]
}

/// The source used when no calendar is configured or available.
///
/// Returning nothing is a legitimate state, not an error: a user with no
/// Outlook still gets a working planner, and the grid simply shows deadlines.
nonisolated struct NullEventSource: CalendarEventSource {
    let sourceID = "none"
    let displayName = "No Calendar"

    func events(in range: Range<Date>, userInitiated: Bool) async throws -> [CalendarEvent] { [] }
}

/// A failure the user can only resolve outside Planner, and where to send them.
///
/// Keeps the coordinator from having to know what an Outlook consent refusal
/// looks like: it just carries the URL through to whatever surfaces the error.
nonisolated protocol ExternallyResolvableError: Error {
    var settingsURL: URL? { get }
}

nonisolated enum EventSourceError: LocalizedError, Equatable {
    case timedOut(seconds: Int)

    var errorDescription: String? {
        switch self {
        case let .timedOut(seconds):
            return "The calendar did not respond within \(seconds) seconds."
        }
    }
}
