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
    private var pendingSearches: [
        (query: String, continuation: CheckedContinuation<[MailMessage], Error>)
    ] = []
    private var pendingDetails: [(id: Int64, continuation: CheckedContinuation<MailMessageDetail, Error>)] = []
    private var _requestedRanges: [Range<Date>] = []
    private var _userInitiatedFlags: [Bool] = []
    private var _requestedDetailIDs: [Int64] = []
    private var _revealedIDs: [Int64] = []
    private var _hiddenChanges: [(id: Int64, hidden: Bool)] = []
    private var _availableCategories: [OutlookCategory] = []
    private var _folders: [MailFolder] = []
    private var _categoryChanges: [(id: Int64, categoryID: Int64, present: Bool)] = []
    private var blobs: [String: Data] = [:]
    private var hiddenChangeError: Error?
    private var hiddenChangeErrorsByID: [Int64: Error] = [:]
    private var categoryChangeErrorsByID: [Int64: Error] = [:]
    private var _knownIDsPerRequest: [[Int64]] = []
    private var _rebuildCount = 0

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

    var hiddenChanges: [(id: Int64, hidden: Bool)] {
        lock.withLock { _hiddenChanges }
    }

    var categoryChanges: [(id: Int64, categoryID: Int64, present: Bool)] {
        lock.withLock { _categoryChanges }
    }

    /// The ids the coordinator claimed to already hold envelopes for, per
    /// sweep. What the incremental plan is computed from, so a test can catch a
    /// change that quietly turns every refresh into a full re-read.
    var knownIDsPerRequest: [[Int64]] {
        lock.lock(); defer { lock.unlock() }
        return _knownIDsPerRequest
    }

    var rebuildCount: Int {
        lock.withLock { _rebuildCount }
    }

    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pendingEnvelopes.count
    }

    var pendingDetailCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pendingDetails.count
    }

    var pendingSearchCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pendingSearches.count
    }

    var requestedSearchQueries: [String] {
        lock.lock(); defer { lock.unlock() }
        return pendingSearches.map(\.query)
    }

    /// Overrides the protocol's default, which drops `known` on the floor, so
    /// the tests can see what the coordinator offered the incremental sweep.
    func envelopes(
        in range: Range<Date>,
        known: [MailMessage],
        userInitiated: Bool
    ) async throws -> [MailMessage] {
        // Recorded through a synchronous helper: NSLock cannot be taken
        // directly from an async context.
        recordKnown(known.map(\.id))
        return try await envelopes(in: range, userInitiated: userInitiated)
    }

    private func recordKnown(_ ids: [Int64]) {
        lock.lock(); defer { lock.unlock() }
        _knownIDsPerRequest.append(ids)
    }

    func rebuildIndex() async throws {
        lock.withLock { _rebuildCount += 1 }
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

    func search(query: String) async throws -> [MailMessage] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pendingSearches.append((query, continuation))
            lock.unlock()
        }
    }

    func availableCategories() async throws -> [OutlookCategory] {
        lock.withLock { _availableCategories }
    }

    func folders() async throws -> [MailFolder] {
        lock.withLock { _folders }
    }

    func setFolders(_ folders: [MailFolder]) {
        lock.withLock { _folders = folders }
    }

    func setAvailableCategories(_ categories: [OutlookCategory]) {
        lock.withLock { _availableCategories = categories }
    }

    func reveal(messageID id: Int64) async throws {
        lock.withLock { _revealedIDs.append(id) }
    }

    func setAttachmentData(_ data: Data, sha256: String) {
        lock.withLock { blobs[sha256] = data }
    }

    func fileURL(for attachment: MailAttachment) async throws -> URL {
        guard attachment.stored else { throw MailSourceError.attachmentUnavailable }
        let data: Data? = lock.withLock { blobs[attachment.sha256] }
        guard let data else { throw MailSourceError.attachmentUnavailable }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            OlSyncAttachmentStore.fileName(for: attachment)
        )
        try data.write(to: url, options: .atomic)
        return url
    }

    func setHidden(_ hidden: Bool, messageID id: Int64) async throws {
        let error: Error? = lock.withLock {
            _hiddenChanges.append((id, hidden))
            return hiddenChangeErrorsByID[id] ?? hiddenChangeError
        }
        if let error { throw error }
    }

    func failHiddenChanges(with error: Error?) {
        lock.withLock { hiddenChangeError = error }
    }

    func failHiddenChange(id: Int64, with error: Error) {
        lock.withLock { hiddenChangeErrorsByID[id] = error }
    }

    func setCategory(_ categoryID: Int64, present: Bool, messageID id: Int64) async throws {
        let error: Error? = lock.withLock {
            _categoryChanges.append((id, categoryID, present))
            return categoryChangeErrorsByID[id]
        }
        if let error { throw error }
    }

    func failCategoryChange(id: Int64, with error: Error) {
        lock.withLock { categoryChangeErrorsByID[id] = error }
    }

    /// Completes the oldest outstanding sweep.
    func finish(with messages: [MailMessage]) {
        take()?.resume(returning: messages)
    }

    func finish(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    /// Completes **every** outstanding sweep with the same result.
    ///
    /// The list view starts its own sweep when it loads, so a test that then
    /// refreshes has two in flight. The coordinator's generation gate drops the
    /// superseded one, so answering both is the way to settle on the newest.
    func finishAll(with messages: [MailMessage]) {
        lock.lock()
        let pending = pendingEnvelopes
        pendingEnvelopes = []
        lock.unlock()
        for continuation in pending { continuation.resume(returning: messages) }
    }

    func finishAll(throwing error: Error) {
        lock.lock()
        let pending = pendingEnvelopes
        pendingEnvelopes = []
        lock.unlock()
        for continuation in pending { continuation.resume(throwing: error) }
    }

    func finishSearch(with messages: [MailMessage]) {
        lock.lock()
        let continuation = pendingSearches.isEmpty ? nil : pendingSearches.removeFirst().continuation
        lock.unlock()
        continuation?.resume(returning: messages)
    }

    func finishSearch(throwing error: Error) {
        lock.lock()
        let continuation = pendingSearches.isEmpty ? nil : pendingSearches.removeFirst().continuation
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    func finishLatestSearch(with messages: [MailMessage]) {
        lock.lock()
        let continuation = pendingSearches.popLast()?.continuation
        lock.unlock()
        continuation?.resume(returning: messages)
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
        let searches = pendingSearches
        let details = pendingDetails
        pendingEnvelopes = []
        pendingSearches = []
        pendingDetails = []
        lock.unlock()
        for continuation in envelopes { continuation.resume(returning: []) }
        for entry in searches { entry.continuation.resume(returning: []) }
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
        isRead: Bool = false,
        isHidden: Bool = false,
        categoryIDs: Set<Int64> = [],
        // Not 0: that is Outlook's built-in set, which no message belongs to,
        // and a message with no account can take no category at all.
        accountUID: Int64 = 1
    ) -> MailMessage {
        MailMessage(
            id: id,
            subject: subject,
            senderName: senderName,
            senderAddress: senderAddress,
            receivedAt: receivedAt,
            isRead: isRead,
            isHidden: isHidden,
            categoryIDs: categoryIDs,
            accountUID: accountUID
        )
    }
}

extension MailMessageDetail {
    static func fixture(
        id: Int64 = 1,
        body: String = "Body",
        html: String? = nil,
        messageID: String? = "<a@example.com>",
        inReplyTo: String? = nil,
        references: String? = nil,
        recipients: String? = "you@example.com",
        hasAttachments: Bool = false,
        attachmentNames: String? = nil,
        attachments: [MailAttachment] = []
    ) -> MailMessageDetail {
        let resolved: [MailAttachment]
        if attachments.isEmpty, let attachmentNames {
            resolved = attachmentNames
                .components(separatedBy: "\n")
                .filter { !$0.isEmpty }
                .enumerated()
                .map { index, name in
                    MailAttachment(
                        id: Int64(index + 1),
                        filename: name,
                        sha256: "sha-\(name)",
                        stored: true
                    )
                }
        } else {
            resolved = attachments
        }
        return MailMessageDetail(
            id: id,
            body: body,
            html: html,
            messageID: messageID,
            inReplyTo: inReplyTo,
            references: references,
            recipients: recipients,
            hasAttachments: hasAttachments,
            attachments: resolved
        )
    }
}
