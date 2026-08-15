import Foundation
@testable import Planner

/// A source whose completion the test drives, so the asynchronous behaviour of
/// `EventCoordinator` can be observed rather than raced against.
final class StubEventSource: CalendarEventSource, @unchecked Sendable {
    let sourceID = "stub"
    let displayName = "Stub Calendar"

    private let lock = NSLock()
    private var pending: [CheckedContinuation<[CalendarEvent], Error>] = []
    private var _requestedRanges: [Range<Date>] = []
    private var _userInitiatedFlags: [Bool] = []

    /// Every range the coordinator has asked for, in order.
    var requestedRanges: [Range<Date>] {
        lock.lock(); defer { lock.unlock() }
        return _requestedRanges
    }

    var userInitiatedFlags: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return _userInitiatedFlags
    }

    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }

    func events(in range: Range<Date>, userInitiated: Bool) async throws -> [CalendarEvent] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            _requestedRanges.append(range)
            _userInitiatedFlags.append(userInitiated)
            pending.append(continuation)
            lock.unlock()
        }
    }

    /// Completes the oldest outstanding request.
    func finish(with events: [CalendarEvent]) {
        take()?.resume(returning: events)
    }

    func finish(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    /// Completes the most recent outstanding request, leaving older ones
    /// hanging — the shape of a slow first call overtaken by a fast second.
    func finishLatest(with events: [CalendarEvent]) {
        lock.lock()
        let continuation = pending.popLast()
        lock.unlock()
        continuation?.resume(returning: events)
    }

    /// Fails the most recent outstanding request, leaving older ones hanging.
    func finishLatest(throwing error: Error) {
        lock.lock()
        let continuation = pending.popLast()
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<[CalendarEvent], Error>? {
        lock.lock(); defer { lock.unlock() }
        return pending.isEmpty ? nil : pending.removeFirst()
    }

    /// Tests must not leave continuations un-resumed; the runtime traps.
    func drain() {
        lock.lock()
        let remaining = pending
        pending = []
        lock.unlock()
        for continuation in remaining { continuation.resume(returning: []) }
    }
}
