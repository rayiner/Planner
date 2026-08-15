import Foundation
@testable import Planner

/// A source whose completion the test drives, so `MailCoordinator`'s
/// asynchronous behaviour can be observed rather than raced against.
///
/// Envelope and detail requests are queued separately: the reader loads a body
/// while a sweep is still in flight, and the tests need to settle those two in
/// whichever order they please.
final class StubMailSource: MailSource, @unchecked Sendable {
    let sourceID = "stub"
    let displayName = "Stub Mailbox"

    private let lock = NSLock()
    private var pendingEnvelopes: [CheckedContinuation<[MailMessage], Error>] = []
    private var pendingDetails: [(id: Int64, continuation: CheckedContinuation<MailMessageDetail, Error>)] = []
    private var _requestedRanges: [Range<Date>] = []
    private var _userInitiatedFlags: [Bool] = []
    private var _requestedDetailIDs: [Int64] = []
    private var _revealedIDs: [Int64] = []

    /// Every range the coordinator has asked for, in order.
    var requestedRanges: [Range<Date>] {
        lock.lock(); defer { lock.unlock() }
        return _requestedRanges
    }

    var userInitiatedFlags: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return _userInitiatedFlags
    }

    var requestedDetailIDs: [Int64] {
        lock.lock(); defer { lock.unlock() }
        return _requestedDetailIDs
    }

    var revealedIDs: [Int64] {
        lock.lock(); defer { lock.unlock() }
        return _revealedIDs
    }

    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pendingEnvelopes.count
    }

    var pendingDetailCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pendingDetails.count
    }

    func envelopes(in range: Range<Date>, userInitiated: Bool) async throws -> [MailMessage] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            _requestedRanges.append(range)
            _userInitiatedFlags.append(userInitiated)
            pendingEnvelopes.append(continuation)
            lock.unlock()
        }
    }

    func detail(forMessageID id: Int64) async throws -> MailMessageDetail {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            _requestedDetailIDs.append(id)
            pendingDetails.append((id, continuation))
            lock.unlock()
        }
    }

    func reveal(messageID id: Int64) async throws {
        lock.withLock { _revealedIDs.append(id) }
    }

    /// Completes the oldest outstanding sweep.
    func finish(with messages: [MailMessage]) {
        take()?.resume(returning: messages)
    }

    func finish(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    /// Completes the most recent outstanding sweep, leaving older ones hanging
    /// — the shape of a slow first call overtaken by a fast second.
    func finishLatest(with messages: [MailMessage]) {
        lock.lock()
        let continuation = pendingEnvelopes.popLast()
        lock.unlock()
        continuation?.resume(returning: messages)
    }

    func finishDetail(_ detail: MailMessageDetail) {
        lock.lock()
        let index = pendingDetails.firstIndex { $0.id == detail.id }
        let entry = index.map { pendingDetails.remove(at: $0) }
        lock.unlock()
        entry?.continuation.resume(returning: detail)
    }

    func finishDetail(id: Int64, throwing error: Error) {
        lock.lock()
        let index = pendingDetails.firstIndex { $0.id == id }
        let entry = index.map { pendingDetails.remove(at: $0) }
        lock.unlock()
        entry?.continuation.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<[MailMessage], Error>? {
        lock.lock(); defer { lock.unlock() }
        return pendingEnvelopes.isEmpty ? nil : pendingEnvelopes.removeFirst()
    }

    /// Tests must not leave continuations un-resumed; the runtime traps.
    func drain() {
        lock.lock()
        let envelopes = pendingEnvelopes
        let details = pendingDetails
        pendingEnvelopes = []
        pendingDetails = []
        lock.unlock()
        for continuation in envelopes { continuation.resume(returning: []) }
        for entry in details { entry.continuation.resume(throwing: MailSourceError.messageUnavailable) }
    }
}

extension MailMessage {
    /// Envelope fixture. Every field has a default because most tests care
    /// about exactly one of them.
    static func fixture(
        id: Int64 = 1,
        subject: String = "Subject",
        senderName: String = "Ada Lovelace",
        senderAddress: String = "ada@example.com",
        receivedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        isRead: Bool = false
    ) -> MailMessage {
        MailMessage(
            id: id,
            subject: subject,
            senderName: senderName,
            senderAddress: senderAddress,
            receivedAt: receivedAt,
            isRead: isRead
        )
    }
}

extension MailMessageDetail {
    static func fixture(
        id: Int64 = 1,
        body: String = "Body",
        messageID: String? = "<a@example.com>",
        inReplyTo: String? = nil,
        references: String? = nil,
        recipients: String? = "you@example.com",
        hasAttachments: Bool = false,
        attachmentNames: String? = nil
    ) -> MailMessageDetail {
        MailMessageDetail(
            id: id,
            body: body,
            messageID: messageID,
            inReplyTo: inReplyTo,
            references: references,
            recipients: recipients,
            hasAttachments: hasAttachments,
            attachmentNames: attachmentNames
        )
    }
}
