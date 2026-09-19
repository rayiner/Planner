import XCTest
@testable import Planner

final class OutlookEventSourceTests: XCTestCase {
    func testSharedDaemonQueueNeverOverlapsMailAndCalendarSyncs() async throws {
        let queue = OlSyncJobQueue()
        let recorder = SyncRecorder()

        async let first: Void = queue.enqueue {
            await recorder.begin("mail")
            try await Task.sleep(for: .milliseconds(30))
            await recorder.end("mail")
        }
        async let second: Void = queue.enqueue {
            await recorder.begin("calendar")
            await recorder.end("calendar")
        }
        _ = try await (first, second)

        let result = await recorder.result()
        XCTAssertFalse(result.overlapped)
        XCTAssertEqual(result.names.count, 2)
    }

    func testConfigurationDefaultsToCalendarAndAcceptsOverrides() {
        let suite = "OlSyncEventSourceTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(
            OlSyncEventSource.Configuration.fromDefaults(defaults),
            .init(accountName: nil, calendarName: "Calendar")
        )
        defaults.set("account@example.com", forKey: "events.accountName")
        defaults.set("Team Calendar", forKey: "events.calendarName")
        XCTAssertEqual(
            OlSyncEventSource.Configuration.fromDefaults(defaults),
            .init(accountName: "account@example.com", calendarName: "Team Calendar")
        )
    }

    func testDaemonHitMapsEveryDisplayedFieldAndStableIdentity() throws {
        let raw: [String: Any] = [
            "event_id": 9,
            "record_id": 44,
            "ical_uid": "series@example.com",
            "account_uid": 60129542145,
            "start_utc": 1_800_000_000,
            "end_utc": 1_800_003_600,
            "all_day": false,
            "subject": "Review",
            "location": "Room 4",
            "organizer": "owner@example.com",
            "folder": "Mailbox/Team Calendar",
            "is_recurring": true,
            "is_rescheduled": false,
        ]
        let hit = try XCTUnwrap(OlSyncEventHit(raw))
        let event = OlSyncEventProtocol.event(
            from: hit,
            fallbackCalendarName: "Calendar",
            calendar: utcCalendar()
        )

        XCTAssertEqual(event.id, "outlook|series@example.com|1800000000")
        XCTAssertEqual(event.title, "Review")
        XCTAssertEqual(event.location, "Room 4")
        XCTAssertEqual(event.organizer, "owner@example.com")
        XCTAssertEqual(event.calendarName, "Team Calendar")
        XCTAssertTrue(event.isRecurring)
        XCTAssertFalse(event.isRescheduled)
    }

    func testModifiedOccurrenceIsRecurringAndRescheduled() throws {
        let hit = try XCTUnwrap(OlSyncEventHit([
            "event_id": 9,
            "record_id": 44,
            "start_utc": 1_800_000_000,
            "end_utc": 1_800_003_600,
            "all_day": false,
            "subject": "Moved review",
            "is_recurring": false,
            "is_rescheduled": true,
        ]))
        let event = OlSyncEventProtocol.event(
            from: hit,
            fallbackCalendarName: "Calendar",
            calendar: utcCalendar()
        )
        XCTAssertTrue(event.isRecurring)
        XCTAssertTrue(event.isRescheduled)
    }

    func testAllDayUTCBoundariesBecomeLocalCalendarDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let hit = try XCTUnwrap(OlSyncEventHit([
            "event_id": 1,
            "start_utc": 1_775_865_600, // 2026-04-11 00:00 UTC
            "end_utc": 1_775_779_200,   // deliberately invalid/earlier
            "all_day": true,
            "subject": "Holiday",
            "is_recurring": false,
            "is_rescheduled": false,
        ]))
        let event = OlSyncEventProtocol.event(
            from: hit,
            fallbackCalendarName: "Calendar",
            calendar: calendar
        )
        XCTAssertTrue(event.isAllDay)
        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day], from: event.start),
            DateComponents(year: 2026, month: 4, day: 11)
        )
        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day], from: event.end),
            DateComponents(year: 2026, month: 4, day: 12)
        )
    }

    func testMalformedHitIsRejected() {
        XCTAssertNil(OlSyncEventHit(["event_id": 1, "subject": "No dates"]))
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

private actor SyncRecorder {
    private var active = false
    private var overlap = false
    private var completed: [String] = []

    func begin(_ name: String) {
        if active { overlap = true }
        active = true
        completed.append(name)
    }

    func end(_: String) {
        active = false
    }

    func result() -> (overlapped: Bool, names: [String]) {
        (overlap, completed)
    }
}
