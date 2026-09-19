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

    func testProgressReporterKeepsTheLatestSnapshotAndHeartbeats() {
        let reporter = OutlookSyncProgressReporter.shared
        reporter.clear()
        defer { reporter.clear() }

        let first = expectation(description: "first progress")
        let heartbeat = expectation(description: "heartbeat")
        var posts = 0
        let observer = NotificationCenter.default.addObserver(
            forName: OutlookSyncProgressReporter.didChangeNotification,
            object: reporter,
            queue: .main
        ) { _ in
            posts += 1
            if posts == 1 { first.fulfill() }
            if posts == 2 { heartbeat.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        reporter.update(OutlookSyncProgress(phase: "indexing", done: 10, total: 100))
        reporter.update(OutlookSyncProgress(phase: "indexing", done: 40, total: 100))
        XCTAssertEqual(reporter.current?.done, 40)

        wait(for: [first, heartbeat], timeout: 2)
        XCTAssertEqual(reporter.current?.done, 40)

        reporter.clear()
        XCTAssertNil(reporter.current)
    }

    /// The bug this prevents: "Outlook sync failed" while the counts on screen
    /// were still climbing.
    func testAProgressEventPushesTheTimeoutDeadlineOut() async {
        let reporter = OutlookSyncProgressReporter.shared
        reporter.clear()
        defer { reporter.clear() }

        let start = Date()
        async let waited: Void = reporter.waitForSilence(seconds: 1, startedAt: start)
        try? await Task.sleep(for: .milliseconds(600))
        reporter.update(OutlookSyncProgress(phase: "indexing", done: 1, total: 10))
        await waited

        XCTAssertGreaterThan(
            Date().timeIntervalSince(start), 1.4,
            "the progress event did not extend the deadline"
        )
    }

    func testSilenceStillTimesOut() async {
        let reporter = OutlookSyncProgressReporter.shared
        reporter.clear()
        defer { reporter.clear() }

        let start = Date()
        await reporter.waitForSilence(seconds: 0, startedAt: start)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    func testAFullSyncRequestSetsTheFullFlag() throws {
        let line = try OlSyncMailProtocol.requestLine(
            id: 9,
            method: "sync",
            params: ["full": true, "calendar": true, "prune": true]
        )
        let object = try JSONSerialization.jsonObject(with: line.dropLast()) as! [String: Any]
        XCTAssertEqual(object["method"] as? String, "sync")
        let params = object["params"] as? [String: Any]
        XCTAssertEqual(params?["full"] as? Bool, true)
        XCTAssertEqual(params?["calendar"] as? Bool, true)
        XCTAssertEqual(params?["prune"] as? Bool, true)
    }

    func testAMismatchedHelloIsRefused() {
        // Not the version we speak — 3 is now correct, so this has to be another.
        XCTAssertEqual(OlSyncMailError.protocolMismatch(4).errorDescription?.contains("4"), true)
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

    func testFoldersReplyMapsNameAndCount() {
        let folders = OlSyncMailProtocol.folders(from: [
            "count": 2,
            "folders": [
                ["name": "Inbox", "message_count": 12],
                ["name": "Sent Items", "message_count": 3],
                ["message_count": 9],
            ],
        ])
        XCTAssertEqual(folders, [
            MailFolder(name: "Inbox", messageCount: 12),
            MailFolder(name: "Sent Items", messageCount: 3),
        ])
    }

    func testAHitBecomesAnEnvelopeAddressedByOutlooksRecordId() {
        let message = OlSyncMailProtocol.envelope(
            hit: [
                "message_id": 222,
                "record_id": 191_357,
                "date": 1_789_601_000,
                "from": "Ada Lovelace <ada@example.com>",
                "subject": "Re: IOEngine",
                "is_read": true,
            ]
        )
        XCTAssertEqual(message?.id, 191_357)
        XCTAssertEqual(message?.subject, "Re: IOEngine")
        XCTAssertEqual(message?.senderName, "Ada Lovelace")
        XCTAssertEqual(message?.senderAddress, "ada@example.com")
        XCTAssertEqual(message?.receivedAt, Date(timeIntervalSince1970: 1_789_601_000))
        XCTAssertTrue(message?.isRead ?? false)
        XCTAssertFalse(message?.isHidden ?? true)
    }

    func testAHitsPreviewBecomesOneFlatLine() {
        let message = OlSyncMailProtocol.envelope(
            hit: [
                "record_id": 7,
                "date": 1_789_601_000,
                "preview": "First line\nsecond   line\tthird",
                "is_read": false,
            ]
        )
        XCTAssertEqual(message?.preview, "First line second line third")
    }

    func testAHitWithNoPreviewHasAnEmptyOne() {
        let message = OlSyncMailProtocol.envelope(
            hit: ["record_id": 7, "date": 1_789_601_000, "is_read": false]
        )
        XCTAssertEqual(message?.preview, "")
    }

    /// Which account holds the message decides which categories it can take,
    /// so the envelope carries the hit's `account_uid` rather than looking it
    /// up again later.
    func testAHitCarriesItsAccount() {
        let message = OlSyncMailProtocol.envelope(
            hit: [
                "record_id": 7,
                "date": 1_789_601_000,
                "account_uid": 60_129_542_145,
                "is_read": false,
            ]
        )
        XCTAssertEqual(message?.accountUID, 60_129_542_145)

        let accountless = OlSyncMailProtocol.envelope(
            hit: ["record_id": 7, "date": 1_789_601_000, "is_read": false]
        )
        XCTAssertEqual(accountless?.accountUID, 0)
    }

    func testAHitCarriesOutlooksHiddenCategoryFlag() {
        let hit: [String: Any] = [
            "record_id": 7,
            "date": 1_789_601_000,
            "category_ids": [10, 11],
            "is_read": false,
        ]
        let categoryIDs = OlSyncMailProtocol.categoryIDs(fromHit: hit)
        let message = OlSyncMailProtocol.envelope(
            hit: hit,
            isHidden: true,
            categoryIDs: categoryIDs
        )
        XCTAssertTrue(message?.isHidden ?? false)
        XCTAssertEqual(message?.categoryIDs, [10, 11])
    }

    /// A name is unique only within an account, so the decoder has to keep the
    /// account and must not collapse two same-named categories into one.
    func testCategoryCatalogueDecodesPerAccountAndKeepsBothHides() {
        let reply: [String: Any] = [
            "total": 3,
            "accounts": [
                [
                    "account_uid": 0,
                    "account": NSNull(),
                    "categories": [
                        ["id": 1, "record_id": 6, "name": "Family", "color": "#A143CC"],
                    ],
                ],
                [
                    "account_uid": 60_129_542_145,
                    "account": "one@example.com",
                    "categories": [
                        ["id": 11, "record_id": 34, "name": "Hide", "color": "#5E732A"],
                    ],
                ],
                [
                    "account_uid": 60_129_542_146,
                    "account": "two@example.com",
                    "categories": [
                        ["id": 21, "record_id": 40, "name": "Hide", "color": "#000000"],
                    ],
                ],
            ],
        ]

        let categories = OlSyncMailProtocol.categories(from: reply)
        XCTAssertEqual(categories.count, 3)
        XCTAssertEqual(Set(categories.map(\.id)), [1, 11, 21])
        // Same name, different accounts, different categories.
        let hides = categories.filter { $0.name == "Hide" }
        XCTAssertEqual(hides.count, 2)
        XCTAssertEqual(Set(hides.map(\.accountUID)), [60_129_542_145, 60_129_542_146])
        XCTAssertEqual(Set(hides).count, 2)
        XCTAssertEqual(hides.first { $0.id == 11 }?.qualifiedName, "Hide — one@example.com")
        // The built-in set belongs to no account and says so.
        let family = categories.first { $0.id == 1 }
        XCTAssertEqual(family?.accountUID, 0)
        XCTAssertNil(family?.account)
        XCTAssertEqual(family?.qualifiedName, "Family")
        XCTAssertEqual(family?.recordID, 6)
        XCTAssertEqual(family?.colorHex, "#A143CC")
    }

    func testMessageReplyCarriesItsOwnCategoryAccounts() {
        let reply: [String: Any] = [
            "message_id": 501,
            "categories": [
                ["id": 15, "name": "Blue category", "color": "#7499E1",
                 "account_uid": 60_129_542_146, "account": "two@example.com"],
                ["id": 11, "name": "Hide", "color": "#5E732A",
                 "account_uid": 60_129_542_145, "account": "one@example.com"],
                ["name": "no id, dropped"],
            ],
        ]
        let categories = OlSyncMailProtocol.categories(fromMessage: reply)
        XCTAssertEqual(categories.map(\.id), [15, 11])
        // A message may carry another account's category; Outlook permits it.
        XCTAssertEqual(categories.first?.account, "two@example.com")
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
                    [
                        "attachment_id": 91,
                        "filename": "brief.pdf",
                        "content_type": "application/pdf",
                        "size": 12,
                        "sha256": "aaa",
                        "stored": true,
                        "is_inline": false,
                        "blob_rowid": 139,
                    ],
                    [
                        "attachment_id": 92,
                        "filename": "exhibit.docx",
                        "stored": false,
                    ],
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
        XCTAssertEqual(detail.attachments.map(\.filename), ["brief.pdf", "exhibit.docx"])
        XCTAssertEqual(detail.attachments.map(\.id), [91, 92])
        XCTAssertEqual(detail.attachments.map(\.stored), [true, false])
        XCTAssertEqual(detail.attachments.map(\.isInline), [false, false])
        XCTAssertEqual(detail.attachments.first?.sha256, "aaa")
        XCTAssertEqual(detail.attachments.first?.blobRowid, 139)
        XCTAssertEqual(detail.attachments.first?.contentType, "application/pdf")
    }

    func testInlineImagesAreOmittedFromTheReaderList() {
        let image = MailAttachment(
            id: 1,
            filename: "image001.png",
            contentType: "image/png",
            sha256: "img",
            isInline: true
        )
        let brief = MailAttachment(id: 2, filename: "brief.pdf", sha256: "pdf")
        XCTAssertFalse(image.showsInReader)
        XCTAssertTrue(brief.showsInReader)
    }

    func testAttachmentStoreWritesTheBlobToATempFile() throws {
        let database = FileManager.default.temporaryDirectory
            .appendingPathComponent("OlSyncAttachmentStoreTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: database) }
        let payload = Data("hello-attachment".utf8)
        try OlSyncAttachmentStore.seedForTesting(
            databaseURL: database,
            sha256: "deadbeefcafebabe",
            content: payload
        )
        let attachment = MailAttachment(
            id: 1,
            filename: "brief.pdf",
            sha256: "deadbeefcafebabe"
        )
        let url = try OlSyncAttachmentStore.fileURL(for: attachment, databaseURL: database)
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertTrue(url.lastPathComponent.contains("brief.pdf"))
        let again = try OlSyncAttachmentStore.fileURL(for: attachment, databaseURL: database)
        XCTAssertEqual(url, again)
    }

    func testUnstoredAttachmentsAreNotMaterialized() {
        XCTAssertThrowsError(
            try OlSyncAttachmentStore.fileURL(
                for: MailAttachment(id: 1, filename: "huge.zip", sha256: "abc", stored: false),
                databaseURL: URL(fileURLWithPath: "/tmp/missing.sqlite")
            )
        ) { error in
            XCTAssertEqual(error as? MailSourceError, .attachmentUnavailable)
        }
    }

    // MARK: - Configuration

    func testConfigurationDefaults() {
        let suite = UserDefaults(suiteName: "OutlookMailSourceTests.\(UUID().uuidString)")!
        var configuration = OutlookMailSource.Configuration.fromDefaults(suite)
        XCTAssertNil(configuration.accountName)
        XCTAssertNil(configuration.maximumMessages)

        suite.set("  work@example.com  ", forKey: OutlookMailSource.Configuration.accountDefaultsKey)
        suite.set(50, forKey: OutlookMailSource.Configuration.maximumDefaultsKey)
        configuration = OutlookMailSource.Configuration.fromDefaults(suite)
        XCTAssertEqual(configuration.accountName, "work@example.com")
        XCTAssertEqual(configuration.maximumMessages, 50)
    }

    /// A month holds ten times the mail three days do, so a flat ceiling sized
    /// for the short window would cut the long one off mid-list.
    func testTheWindowCeilingScalesWithTheWindow() {
        let configuration = OutlookMailSource.Configuration(accountName: nil, maximumMessages: nil)
        let perDay = OutlookMailSource.Configuration.defaultMaximumMessagesPerDay
        XCTAssertEqual(configuration.messageLimit(for: window(days: 1)), perDay)
        XCTAssertEqual(configuration.messageLimit(for: window(days: 3)), 3 * perDay)
        XCTAssertEqual(configuration.messageLimit(for: window(days: 30)), 30 * perDay)
    }

    /// An hour of it either way is daylight saving, not a shorter window.
    func testADaylightSavingWindowKeepsItsDayCount() {
        let configuration = OutlookMailSource.Configuration(accountName: nil, maximumMessages: nil)
        let start = Date(timeIntervalSince1970: 1_786_100_000)
        let range = start..<start.addingTimeInterval(3 * 86_400 - 3_600)
        XCTAssertEqual(
            configuration.messageLimit(for: range),
            3 * OutlookMailSource.Configuration.defaultMaximumMessagesPerDay
        )
    }

    /// The old flat key still wins, so an existing `defaults write` keeps
    /// meaning what it meant.
    func testAHandSetCeilingOverridesTheScaling() {
        let configuration = OutlookMailSource.Configuration(accountName: nil, maximumMessages: 50)
        XCTAssertEqual(configuration.messageLimit(for: window(days: 30)), 50)
    }

    private func window(days: Int) -> Range<Date> {
        let start = Date(timeIntervalSince1970: 1_786_100_000)
        return start..<start.addingTimeInterval(TimeInterval(days) * 86_400)
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

    func testHideScriptCreatesCategoryAndPreservesExistingCategories() {
        let script = OutlookMailScripting.setHidden(true, messageID: 181_121)
        XCTAssertTrue(script.contains("message id 181121"), script)
        XCTAssertTrue(script.contains("make new category with properties {name:\"Hide\"}"), script)
        XCTAssertTrue(script.contains("{hideCategory} & currentCategories"), script)
        XCTAssertTrue(script.contains("id of candidate is id of hideCategory"), script)
    }

    func testUnhideScriptRemovesOnlyHideAndDoesNotCreateIt() {
        let script = OutlookMailScripting.setHidden(false, messageID: 181_121)
        XCTAssertTrue(script.contains("name of candidate is not \"Hide\""), script)
        XCTAssertTrue(script.contains("set category of targetMessage to keptCategories"), script)
        XCTAssertFalse(script.contains("make new category"), script)
    }

    func testGenericCategoryScriptAddsByIDAndPreservesExistingCategories() {
        let script = OutlookMailScripting.setCategory(42, present: true, messageID: 181_121)
        XCTAssertTrue(script.contains("message id 181121"), script)
        XCTAssertTrue(script.contains("category id 42"), script)
        XCTAssertTrue(script.contains("if id of candidate is 42 then return"), script)
        XCTAssertTrue(script.contains("{targetCategory} & currentCategories"), script)
        XCTAssertFalse(script.contains("\"Hide\""), script)
    }

    func testGenericCategoryUndoRemovesOnlyTheSpecifiedID() {
        let script = OutlookMailScripting.setCategory(42, present: false, messageID: 181_121)
        XCTAssertTrue(script.contains("if id of candidate is not 42"), script)
        XCTAssertTrue(script.contains("set category of targetMessage to keptCategories"), script)
        XCTAssertFalse(script.contains("\"Hide\""), script)
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
