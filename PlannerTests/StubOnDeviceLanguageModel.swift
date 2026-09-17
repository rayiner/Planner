import Foundation
@testable import Planner

/// A model whose replies the test hands out, so `MailSummaryCoordinator`'s
/// queue and states can be observed one step at a time rather than raced.
///
/// Same shape as `StubMailSource`: requests park on continuations, the test
/// inspects what was asked, then answers or fails whichever one it likes.
final class StubOnDeviceLanguageModel: OnDeviceLanguageModel, @unchecked Sendable {
    private let lock = NSLock()
    private var _availability: OnDeviceModelAvailability
    private var pending: [(request: OnDeviceModelRequest, continuation: CheckedContinuation<String, Error>)] = []
    private var _requests: [OnDeviceModelRequest] = []

    init(availability: OnDeviceModelAvailability = .available) {
        _availability = availability
    }

    var availability: OnDeviceModelAvailability {
        get { lock.withLock { _availability } }
        set { lock.withLock { _availability = newValue } }
    }

    /// Every request received, in order, answered or not.
    var requests: [OnDeviceModelRequest] {
        lock.withLock { _requests }
    }

    var pendingCount: Int {
        lock.withLock { pending.count }
    }

    var pendingPrompts: [String] {
        lock.withLock { pending.map(\.request.prompt) }
    }

    @concurrent func respond(to request: OnDeviceModelRequest) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            _requests.append(request)
            pending.append((request, continuation))
            lock.unlock()
        }
    }

    /// Answers the oldest outstanding request.
    func finish(with reply: String) {
        take()?.continuation.resume(returning: reply)
    }

    func finish(throwing error: Error) {
        take()?.continuation.resume(throwing: error)
    }

    /// Answers the outstanding request whose prompt contains `fragment`.
    func finish(promptContaining fragment: String, with reply: String) {
        lock.lock()
        let index = pending.firstIndex { $0.request.prompt.contains(fragment) }
        let entry = index.map { pending.remove(at: $0) }
        lock.unlock()
        entry?.continuation.resume(returning: reply)
    }

    private func take() -> (request: OnDeviceModelRequest, continuation: CheckedContinuation<String, Error>)? {
        lock.lock(); defer { lock.unlock() }
        return pending.isEmpty ? nil : pending.removeFirst()
    }

    /// Tests must not leave continuations un-resumed; the runtime traps.
    func drain() {
        lock.lock()
        let entries = pending
        pending = []
        lock.unlock()
        for entry in entries {
            entry.continuation.resume(throwing: OnDeviceModelError.unavailable(.unavailable))
        }
    }
}
