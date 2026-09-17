import XCTest
@testable import Planner

final class OutlookMailSourceTests: XCTestCase {
    // MARK: - Paths and queries

    func testTheIndexLivesInApplicationSupport() {
        let url = OlSyncMailProtocol.databaseURL()
        XCTAssertEqual(url.lastPathComponent, "olsyncmail.sqlite")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Planner")
        XCTAssertTrue(url.path.contains("Application Support"))
    }

    func testWindowQueryUsesUnixBoundsAndInbox() {
        let start = Date(timeIntervalSince1970: 1_786_100_000)
        let end = start.addingTimeInterval(86_400)
        XCTAssertEqual(
            OlSyncMailProtocol.windowQuery(in: start..<end),
            "folder:Inbox after:1786100000 before:1786186400"
        )
    }

    // MARK: - Protocol lines

    func testHelloHasNoParams() throws {
        let data = try OlSyncMailProtocol.requestLine(id: 1, method: "hello")
        XCTAssertEqual(data.last, 0x0A)
        let object = try JSONSerialization.jsonObject(with: data.dropLast()) as! [String: Any]
        XCTAssertEqual(object["id"] as? Int, 1)
        XCTAssertEqual(object["method"] as? String, "hello")
        XCTAssertNil(object["params"])
    }

    func testOpenNamesTheDatabase() throws {
        let line = try OlSyncMailProtocol.requestLine(
            id: 2,
            method: "open",
            params: ["db": "/tmp/mail.sqlite"]
        )
        let object = try JSONSerialization.jsonObject(with: line.dropLast()) as! [String: Any]
        let params = object["params"] as! [String: Any]
        XCTAssertEqual(params["db"] as? String, "/tmp/mail.sqlite")
    }

    func testInt64ParamsAreJSONNumbers() throws {
        let line = try OlSyncMailProtocol.requestLine(
            id: 3,
            method: "message",
            params: ["message_id": Int64(222)]
        )
        XCTAssertTrue(JSONSerialization.isValidJSONObject(
            try JSONSerialization.jsonObject(with: line.dropLast())
        ))
        let object = try JSONSerialization.jsonObject(with: line.dropLast()) as! [String: Any]
        let params = object["params"] as! [String: Any]
        XCTAssertEqual(OlSyncMailProtocol.int64(params["message_id"]), 222)
    }

    func testASearchReplyDecodesAsAResponse() throws {
        let incoming = try OlSyncMailProtocol.decodeIncoming(
            #"{"id":7,"ok":{"hits":[{"message_id":222,"record_id":191357,"date":1789601000,"from":"Ada <ada@example.com>","subject":"Hi"}],"elapsed_ms":3}}"#
        )
        guard case let .response(id, result) = incoming, case let .success(data) = result else {
            return XCTFail("expected a successful response")
        }
        XCTAssertEqual(id, 7)
        let ok = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let hits = ok?["hits"] as? [[String: Any]]
        XCTAssertEqual(OlSyncMailProtocol.int64(hits?.first?["record_id"]), 191357)
    }

    func testAnErrorLineMapsTheCode() throws {
        let incoming = try OlSyncMailProtocol.decodeIncoming(
            #"{"id":4,"error":{"code":"profile_unavailable","message":"no profile"}}"#
        )
        guard case let .response(_, result) = incoming, case let .failure(error) = result else {
            return XCTFail("expected a failure")
        }
        XCTAssertEqual(error as? OlSyncMailError, .profileUnavailable("no profile"))
        XCTAssertEqual(
            (error as? OlSyncMailError)?.settingsURL,
            OlSyncMailError.fullDiskAccessSettingsURL
        )
    }

    func testProgressIsAnEvent() throws {
        let incoming = try OlSyncMailProtocol.decodeIncoming(
            #"{"event":"progress","job":1,"phase":"indexing","done":4120,"total":25000}"#
        )
        guard case let .event(.progress(job, phase, done, total)) = incoming else {
            return XCTFail("expected progress")
        }
        XCTAssertEqual(job, 1)
        XCTAssertEqual(phase, "indexing")
        XCTAssertEqual(done, 4120)
        XCTAssertEqual(total, 25_000)
    }

    func testAMismatchedHelloIsRefused() {
        XCTAssertEqual(OlSyncMailError.protocolMismatch(2).errorDescription?.contains("2"), true)
    }

    // MARK: - Mapping onto Planner types

    func testAMailboxSplitsNameAndAddress() {
        let parsed = OlSyncMailProtocol.parseMailbox("\"Looper, Jared\" <jlooper@example.com>")
        XCTAssertEqual(parsed.name, "Looper, Jared")
        XCTAssertEqual(parsed.address, "jlooper@example.com")
        XCTAssertEqual(OlSyncMailProtocol.parseMailbox("ada@example.com").address, "ada@example.com")
    }

    func testStatusRMeansRead() {
        XCTAssertTrue(OlSyncMailProtocol.isRead(status: "RO"))
        XCTAssertFalse(OlSyncMailProtocol.isRead(status: "O"))
        XCTAssertFalse(OlSyncMailProtocol.isRead(status: nil))
    }

    func testAHitBecomesAnEnvelopeAddressedByOutlooksRecordId() {
        let message = OlSyncMailProtocol.envelope(
            hit: [
                "message_id": 222,
                "record_id": 191_357,
                "date": 1_789_601_000,
                "from": "Ada Lovelace <ada@example.com>",
                "subject": "Re: IOEngine",
            ],
            isRead: true
        )
        XCTAssertEqual(message?.id, 191_357)
        XCTAssertEqual(message?.subject, "Re: IOEngine")
        XCTAssertEqual(message?.senderName, "Ada Lovelace")
        XCTAssertEqual(message?.senderAddress, "ada@example.com")
        XCTAssertEqual(message?.receivedAt, Date(timeIntervalSince1970: 1_789_601_000))
        XCTAssertTrue(message?.isRead ?? false)
    }

    func testDetailReadsBodiesHeadersAndAttachmentNames() {
        let detail = OlSyncMailProtocol.detail(
            from: [
                "message_id": 222,
                "record_id": 7,
                "rfc822_message_id": "mid@example.com",
                "body_text": "plain",
                "body_html": "<p>html</p>",
                "to": "Ray <ray@example.com>",
                "cc": "Ada <ada@example.com>",
                "headers": [
                    ["In-Reply-To", "<prev@example.com>"],
                    ["References", "<prev@example.com>"],
                    ["X-MS-Has-Attach", "yes"],
                ],
                "attachments": [
                    ["filename": "brief.pdf"],
                    ["filename": "exhibit.docx"],
                ],
            ],
            fallbackID: 0
        )
        XCTAssertEqual(detail.id, 7)
        XCTAssertEqual(detail.body, "plain")
        XCTAssertEqual(detail.html, "<p>html</p>")
        XCTAssertEqual(detail.messageID, "<mid@example.com>")
        XCTAssertEqual(detail.inReplyTo, "<prev@example.com>")
        XCTAssertEqual(detail.recipients, "Ray <ray@example.com>, Ada <ada@example.com>")
        XCTAssertTrue(detail.hasAttachments)
        XCTAssertEqual(detail.attachmentNames, "brief.pdf\nexhibit.docx")
    }

    // MARK: - Configuration

    func testConfigurationDefaults() {
        let suite = UserDefaults(suiteName: "OutlookMailSourceTests.\(UUID().uuidString)")!
        var configuration = OutlookMailSource.Configuration.fromDefaults(suite)
        XCTAssertNil(configuration.accountName)
        XCTAssertEqual(configuration.maximumMessages, OutlookMailSource.Configuration.defaultMaximumMessages)

        suite.set("  work@example.com  ", forKey: OutlookMailSource.Configuration.accountDefaultsKey)
        suite.set(50, forKey: OutlookMailSource.Configuration.maximumDefaultsKey)
        configuration = OutlookMailSource.Configuration.fromDefaults(suite)
        XCTAssertEqual(configuration.accountName, "work@example.com")
        XCTAssertEqual(configuration.maximumMessages, 50)
    }

    func testABlankAccountNameMeansTheFirstAccount() {
        let suite = UserDefaults(suiteName: "OutlookMailSourceTests.\(UUID().uuidString)")!
        suite.set("   ", forKey: OutlookMailSource.Configuration.accountDefaultsKey)
        XCTAssertNil(OutlookMailSource.Configuration.fromDefaults(suite).accountName)
    }

    // MARK: - Reveal and errors

    func testTheRevealScriptAddressesOneMessageById() {
        let script = OutlookMailScripting.reveal(messageID: 181_121)
        XCTAssertTrue(script.contains("message id 181121"), script)
        XCTAssertTrue(script.contains("activate"), script)
    }

    func testAppleScriptFailuresMapOntoOutlookErrors() {
        func mapped(_ code: Int) -> OutlookError {
            OutlookError.fromAppleScript([NSAppleScript.errorNumber: code] as NSDictionary)
        }
        XCTAssertEqual(mapped(-1743), .permissionDenied)
        XCTAssertEqual(mapped(-600), .notRunning)
        XCTAssertEqual(mapped(-609), .notRunning)
        XCTAssertEqual(mapped(-1728), .appleEvent(code: -1728))
    }

    func testAMissingObjectIsDistinguishedFromABrokenConnection() {
        XCTAssertTrue(OutlookError.appleEvent(code: -1728).isMissingObject)
        XCTAssertTrue(OutlookError.appleEvent(code: -1719).isMissingObject)
        XCTAssertFalse(OutlookError.appleEvent(code: -1712).isMissingObject)
        XCTAssertFalse(OutlookError.permissionDenied.isMissingObject)
    }
}
