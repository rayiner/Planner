import XCTest
@testable import Planner

final class MailEnvelopeCacheTests: XCTestCase {
    private func message(
        id: Int64,
        hoursAgo: Int = 1,
        isRead: Bool = false,
        now: Date = Date(timeIntervalSince1970: 1_786_100_000)
    ) -> MailMessage {
        MailMessage(
            id: id,
            subject: "S\(id)",
            senderName: "Ada",
            senderAddress: "ada@example.com",
            receivedAt: now.addingTimeInterval(TimeInterval(-hoursAgo * 3600)),
            isRead: isRead
        )
    }

    // MARK: - Sweep plan

    func testAQuietInboxReusesTheCache() {
        XCTAssertEqual(
            MailEnvelopeSweep.plan(currentIDs: [3, 2, 1], knownIDs: [1, 2, 3]),
            .reuse
        )
    }

    func testNewMailAtTheHeadIsAPrefix() {
        XCTAssertEqual(
            MailEnvelopeSweep.plan(currentIDs: [5, 4, 3, 2, 1], knownIDs: [1, 2, 3]),
            .prefix(2)
        )
    }

    func testUnknownsInTheTailForceAFullRead() {
        XCTAssertEqual(
            MailEnvelopeSweep.plan(currentIDs: [3, 2, 1, 9], knownIDs: [1, 2, 3]),
            .full
        )
    }

    func testAnEmptyInboxReusesNothing() {
        XCTAssertEqual(MailEnvelopeSweep.plan(currentIDs: [], knownIDs: [1]), .reuse)
    }

    func testAssembleDropsDeletedIdsAndUpdatesReadFlags() {
        let known = [
            message(id: 1, isRead: false),
            message(id: 2, isRead: false),
            message(id: 3, isRead: false),
        ]
        let assembled = MailEnvelopeSweep.assemble(
            currentIDs: [2, 1],
            isRead: [2: true, 1: false],
            known: Dictionary(uniqueKeysWithValues: known.map { ($0.id, $0) }),
            fresh: []
        )
        XCTAssertEqual(assembled.map(\.id), [2, 1])
        XCTAssertTrue(assembled[0].isRead)
        XCTAssertFalse(assembled[1].isRead)
    }

    func testAssemblePrefersFreshEnvelopesForThePrefix() {
        let known = [message(id: 1, hoursAgo: 10)]
        let fresh = [message(id: 2, hoursAgo: 1, isRead: true)]
        let assembled = MailEnvelopeSweep.assemble(
            currentIDs: [2, 1],
            isRead: [2: true, 1: false],
            known: [1: known[0]],
            fresh: fresh
        )
        XCTAssertEqual(assembled.map(\.id), [2, 1])
        XCTAssertEqual(assembled[0].subject, "S2")
        XCTAssertTrue(assembled[0].isRead)
    }

    // MARK: - Sidecar

    func testARoundTripPreservesTheWindow() {
        let store = MailEnvelopeStore.temporary()
        let record = MailEnvelopeRecord(
            sourceID: "stub",
            windowDays: 3,
            fetchedAt: Date(timeIntervalSince1970: 1_786_100_000),
            messages: [message(id: 7)]
        )
        store.save(record)
        XCTAssertEqual(store.load(), record)
    }

    func testADisabledStoreNeverWrites() {
        let store = MailEnvelopeStore.disabled
        store.save(
            MailEnvelopeRecord(
                sourceID: "stub",
                windowDays: 3,
                fetchedAt: Date(),
                messages: [message(id: 1)]
            )
        )
        XCTAssertNil(store.load())
    }

}
