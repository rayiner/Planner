import Foundation

/// Where Recent Mail comes from.
///
/// Not `@MainActor`, for the same reason `CalendarEventSource` is not:
/// implementations are slow — the Outlook source costs ~60ms per message — and
/// must work off the main thread. Only `Sendable` values cross back, which is
/// what keeps scripting objects from escaping their own queue.
///
/// The split between `envelopes` and `detail` is the whole performance design,
/// settled by the M0 spike: the sweep reads five fields per message, and body,
/// headers and attachment names are read one message at a time, on demand.
nonisolated protocol MailSource: Sendable {
    var sourceID: String { get }
    /// Shown in error messages and the refresh tooltip, e.g. "Inbox".
    var displayName: String { get }

    /// - Parameter userInitiated: An explicit refresh may raise a system
    ///   consent dialog; an automatic one (launch, day rollover) must not.
    func envelopes(in range: Range<Date>, userInitiated: Bool) async throws -> [MailMessage]

    /// Same as `envelopes(in:userInitiated:)`, with the last successful window
    /// so a source that can do an incremental sweep does not re-read every
    /// field. Sources that cannot ignore `known`.
    func envelopes(
        in range: Range<Date>,
        known: [MailMessage],
        userInitiated: Bool
    ) async throws -> [MailMessage]

    /// The body and headers of one message, by the id its envelope carried.
    func detail(forMessageID id: Int64) async throws -> MailMessageDetail

    /// Brings the original up in Outlook. Always user-initiated: opening an
    /// unread message marks it read upstream, which is a write.
    func reveal(messageID id: Int64) async throws
}

/// The source used when no mail account is configured or available.
///
/// Returning nothing is a legitimate state, not an error: a user with no
/// Outlook still gets a working planner, with mail folders they can file into
/// by hand and an empty Recent Mail.
extension MailSource {
    func envelopes(
        in range: Range<Date>,
        known: [MailMessage],
        userInitiated: Bool
    ) async throws -> [MailMessage] {
        try await envelopes(in: range, userInitiated: userInitiated)
    }
}

nonisolated struct NullMailSource: MailSource {
    let sourceID = "none"
    let displayName = "No Mailbox"

    func envelopes(in range: Range<Date>, userInitiated: Bool) async throws -> [MailMessage] { [] }

    func detail(forMessageID id: Int64) async throws -> MailMessageDetail {
        throw MailSourceError.messageUnavailable
    }

    func reveal(messageID id: Int64) async throws {
        throw MailSourceError.messageUnavailable
    }
}

/// Runs `operation` with a deadline, resolving whichever of the two lands first
/// and abandoning the loser.
///
/// Not a `withThrowingTaskGroup`: a group awaits its remaining children on the
/// way out, and the mail source wraps a blocking Apple event that never
/// observes cancellation — so the group would sit behind the very hang the
/// timeout exists to escape. `EventCoordinator` settles this the same way, with
/// a timer that only flips the UI. The abandoned task finishes into a
/// continuation that is already spent, which the one-shot below absorbs.
nonisolated func withMailTimeout<T: Sendable>(
    seconds: Int,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let outcome = MailOneShot<T>()
    return try await withCheckedThrowingContinuation { continuation in
        outcome.arm(continuation)
        Task {
            do { outcome.resolve(.success(try await operation())) }
            catch { outcome.resolve(.failure(error)) }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            outcome.resolve(.failure(MailSourceError.timedOut(seconds: seconds)))
        }
    }
}

/// A continuation that can be resumed from either of two racing tasks and is
/// resumed exactly once. Resuming twice traps, and silently dropping the second
/// result is precisely the desired behaviour.
nonisolated private final class MailOneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var settled = false

    func arm(_ continuation: CheckedContinuation<T, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func resolve(_ result: Result<T, Error>) {
        let continuation: CheckedContinuation<T, Error>? = lock.withLock {
            guard !settled else { return nil }
            settled = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}

nonisolated enum MailSourceError: LocalizedError, Equatable {
    case timedOut(seconds: Int)
    /// The message is no longer where its id said it was — moved, deleted, or
    /// aged out of Outlook while Planner held a stale envelope.
    case messageUnavailable

    var errorDescription: String? {
        switch self {
        case let .timedOut(seconds):
            return "Outlook didn’t respond within \(seconds) seconds."
        case .messageUnavailable:
            return "That message is no longer in Outlook."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .timedOut:
            return "Try refreshing. A large mailbox can take a while."
        case .messageUnavailable:
            return "It may have been moved or deleted. Refresh to see what’s there now."
        }
    }
}
