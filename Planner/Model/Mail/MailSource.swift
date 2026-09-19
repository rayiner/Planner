import Foundation

/// Where Recent Mail comes from and where explicit mail commands go.
///
/// Not `@MainActor`, for the same reason `CalendarEventSource` is not:
/// implementations talk to a helper or to Outlook and must work off the main
/// thread. Only `Sendable` values cross back.
///
/// The split between `envelopes` and `detail` is the performance design: the
/// window is a cheap search over the local index, and body, headers and
/// attachment names are read one message at a time, on demand.
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

    /// Searches the source's complete local index. Unlike Recent Mail this has
    /// no Inbox or date-window constraint, and includes message bodies and
    /// attachment text because `olsyncmail` already indexed both.
    func search(query: String) async throws -> [MailMessage]

    /// Distinct folder paths in the local index — the names `folder:` search
    /// accepts — with how many indexed messages each holds.
    func folders() async throws -> [MailFolder]

    /// Categories Outlook currently defines, excluding its reserved `Hide`
    /// category from the generic catalog.
    func availableCategories() async throws -> [OutlookCategory]

    /// The body and headers of one message, by the id its envelope carried.
    func detail(forMessageID id: Int64) async throws -> MailMessageDetail

    /// Writes one stored attachment to a temporary file so the reader can
    /// hand it to the default viewer. Throws if the payload was never stored.
    func fileURL(for attachment: MailAttachment) async throws -> URL

    /// Brings the original up in Outlook. Always user-initiated: opening an
    /// unread message marks it read upstream, which is a write.
    func reveal(messageID id: Int64) async throws

    /// Adds or removes Outlook's `Hide` category for one message.
    func setHidden(_ hidden: Bool, messageID id: Int64) async throws

    /// Adds or removes one ordinary Outlook category by its stable record id.
    func setCategory(_ categoryID: Int64, present: Bool, messageID id: Int64) async throws

    /// Re-index every Outlook message and event, ignoring what the local
    /// database already has. Default is a no-op for sources with no index.
    func rebuildIndex() async throws
}

/// The source used when no mail account is configured or available.
///
/// Returning nothing is a legitimate state, not an error: a user with no
/// Outlook still gets a working planner and an empty Recent Mail field.
extension MailSource {
    func envelopes(
        in range: Range<Date>,
        known: [MailMessage],
        userInitiated: Bool
    ) async throws -> [MailMessage] {
        try await envelopes(in: range, userInitiated: userInitiated)
    }

    func rebuildIndex() async throws {}
}

nonisolated struct NullMailSource: MailSource {
    let sourceID = "none"
    let displayName = "No Mailbox"

    func envelopes(in range: Range<Date>, userInitiated: Bool) async throws -> [MailMessage] { [] }

    func search(query: String) async throws -> [MailMessage] { [] }

    func folders() async throws -> [MailFolder] { [] }

    func availableCategories() async throws -> [OutlookCategory] { [] }

    func detail(forMessageID id: Int64) async throws -> MailMessageDetail {
        throw MailSourceError.messageUnavailable
    }

    func fileURL(for attachment: MailAttachment) async throws -> URL {
        throw MailSourceError.attachmentUnavailable
    }

    func reveal(messageID id: Int64) async throws {
        throw MailSourceError.messageUnavailable
    }

    func setHidden(_ hidden: Bool, messageID id: Int64) async throws {
        throw MailSourceError.messageUnavailable
    }

    func setCategory(_ categoryID: Int64, present: Bool, messageID id: Int64) async throws {
        throw MailSourceError.messageUnavailable
    }
}

/// Runs `operation` with a deadline, resolving whichever of the two lands first
/// and abandoning the loser.
///
/// Not a `withThrowingTaskGroup`: a group awaits its remaining children on the
/// way out, and a hung helper would sit behind the hang the timeout exists to
/// escape. `EventCoordinator` settles this the same way, with a timer that only
/// flips the UI. The abandoned task finishes into a continuation that is
/// already spent, which the one-shot below absorbs.
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
    /// The index has the name but not the bytes — size cap, `--no-attachment-content`,
    /// or a blob that has not been written yet.
    case attachmentUnavailable

    var errorDescription: String? {
        switch self {
        case let .timedOut(seconds):
            return "Outlook didn’t respond within \(seconds) seconds."
        case .messageUnavailable:
            return "That message is no longer in Outlook."
        case .attachmentUnavailable:
            return "That attachment isn’t available."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .timedOut:
            return "Try refreshing. A large mailbox can take a while."
        case .messageUnavailable:
            return "It may have been moved or deleted. Refresh to see what’s there now."
        case .attachmentUnavailable:
            return "It may have been too large to store. Open the message in Outlook to get the file."
        }
    }
}
