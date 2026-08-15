import AppKit
import XCTest
@testable import Planner

@MainActor
final class MailSavingTests: PersistenceTestCase {
    private var defaults: UserDefaults!
    private var source: StubMailSource!
    private var split: MainSplitViewController!
    private var selection: SelectionModel!
    private var windows: [NSWindow] = []

    private var coordinator: MailCoordinator { split.mail }
    private var list: MailListViewController { split.mailListViewController }
    private var reader: MailReaderViewController { split.mailReaderViewController }

    override func setUp() {
        super.setUp()
        defaults = isolatedDefaults()
        source = StubMailSource()
        selection = SelectionModel(defaults: defaults)
        selection.setMode(.mail)
        split = MainSplitViewController(
            persistence: persistence,
            model: model,
            selection: selection,
            events: EventCoordinator(source: NullEventSource()),
            mail: MailCoordinator(source: source, defaults: defaults),
            userDefaults: defaults
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = split
        windows.append(window)
        split.loadViewIfNeeded()
        list.loadViewIfNeeded()
        reader.loadViewIfNeeded()
    }

    override func tearDown() {
        coordinator.cancel()
        source?.drain()
        for window in windows { window.contentViewController = nil }
        windows = []
        split = nil
        selection = nil
        source = nil
        defaults = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func message(
        id: Int64,
        minutesAgo: Int = 0,
        subject: String = "Deposition prep",
        sender: String = "Ada Lovelace",
        address: String = "ada@example.com"
    ) -> MailMessage {
        MailMessage(
            id: id,
            subject: subject,
            senderName: sender,
            senderAddress: address,
            receivedAt: Date(timeIntervalSince1970: 1_786_100_000 - TimeInterval(minutesAgo * 60)),
            isRead: false
        )
    }

    private func load(_ messages: [MailMessage]) async {
        let before = source.requestedRanges.count
        coordinator.refresh()
        await settle { self.source.requestedRanges.count > before }
        source.finishAll(with: messages)
        await settle { !self.coordinator.isLoading }
        list.reload()
        reader.rebind()
    }

    /// Runs the save the reader's menu would run, and settles the body fetch it
    /// depends on.
    private func save(
        _ message: MailMessage,
        into folder: MailFolder?,
        detail: MailMessageDetail? = nil,
        failing: Error? = nil
    ) async {
        selection.selectMessage(.recent(message.id))
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.representedObject = folder
        split.saveMessageToFolder(item)

        await settle { self.source.pendingDetailCount > 0 }
        if let failing {
            source.finishDetail(id: message.id, throwing: failing)
        } else {
            source.finishDetail(detail ?? .fixture(id: message.id, messageID: "<\(message.id)@x>"))
        }
        await settle { !self.model.mailFolders().flatMap { self.model.messages(in: $0) }.isEmpty }
    }

    // MARK: - Saving

    func testSavingCopiesTheMessageIntoTheChosenFolder() async throws {
        let folder = try model.createMailFolder(name: "Celerity")
        let envelope = message(id: 5)
        await load([envelope])
        await save(envelope, into: folder, detail: .fixture(
            id: 5,
            body: "The body",
            messageID: "<five@x>",
            recipients: "you@example.com"
        ))

        let saved = try XCTUnwrap(model.messages(in: folder).first)
        XCTAssertEqual(saved.subject, "Deposition prep")
        XCTAssertEqual(saved.body, "The body")
        XCTAssertEqual(saved.messageID, "<five@x>")
        XCTAssertEqual(saved.outlookID, 5)
    }

    /// A saved message with no body is worse than no saved message: it looks
    /// like it worked.
    func testAFailedBodyFetchSavesNothing() async throws {
        let folder = try model.createMailFolder(name: "Celerity")
        let envelope = message(id: 5)
        await load([envelope])

        selection.selectMessage(.recent(5))
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.representedObject = folder
        split.saveMessageToFolder(item)
        await settle { self.source.pendingDetailCount > 0 }
        source.finishDetail(id: 5, throwing: MailSourceError.messageUnavailable)
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertTrue(model.messages(in: folder).isEmpty)
    }

    func testSavingIntoANewFolderCreatesOneAndStartsRenamingIt() async throws {
        let envelope = message(id: 5)
        await load([envelope])
        var began: UUID?
        split.mailboxListViewController.loadViewIfNeeded()
        split.mailboxListViewController.beginEditingNameHandler = { began = $0.uuid }

        await save(envelope, into: nil)

        let folder = try XCTUnwrap(model.mailFolders().first)
        XCTAssertEqual(model.messages(in: folder).count, 1)
        XCTAssertEqual(selection.selectedFolderUUID, folder.uuid)
        XCTAssertEqual(began, folder.uuid, "a folder made on the way to saving still needs a name")
    }

    /// A folder created for a save that then fails must not be left behind.
    func testAFailedSaveIntoANewFolderLeavesNoFolder() async {
        let envelope = message(id: 5)
        await load([envelope])

        selection.selectMessage(.recent(5))
        split.saveMessageToFolder(NSMenuItem(title: "", action: nil, keyEquivalent: ""))
        await settle { self.source.pendingDetailCount > 0 }
        source.finishDetail(id: 5, throwing: MailSourceError.messageUnavailable)
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertTrue(model.mailFolders().isEmpty, "an empty folder was left behind by a failed save")
    }

    func testSavingTheSameMessageTwiceIsANoOp() async throws {
        let folder = try model.createMailFolder(name: "Celerity")
        let envelope = message(id: 5)
        await load([envelope])
        await save(envelope, into: folder)
        await save(envelope, into: folder)
        XCTAssertEqual(model.messages(in: folder).count, 1)
    }

    /// The empty state is per-mailbox: an empty folder and an empty Recent Mail
    /// are different facts, and a folder with mail in it is neither.
    func testAFolderWithMailShowsNoEmptyState() async throws {
        let folder = try model.createMailFolder(name: "Celerity")
        selection.selectMailbox(.folder(folder.uuid))
        list.reload()
        XCTAssertTrue(list.test_isEmptyStateVisible)
        XCTAssertEqual(list.test_emptyStateText, "Nothing saved in “Celerity” yet.")

        try model.saveMessage(
            message(id: 9),
            detail: .fixture(id: 9, messageID: "<nine@x>"),
            into: folder
        )
        list.reload()
        XCTAssertFalse(list.test_isEmptyStateVisible, "a folder with mail in it claimed to be empty")
    }

    func testTheSavedRowDimsAndNamesItsFolder() async throws {
        let folder = try model.createMailFolder(name: "Celerity")
        let envelope = message(id: 5)
        await load([envelope])
        await save(envelope, into: folder, detail: .fixture(id: 5, messageID: "<five@x>"))
        list.reload()
        XCTAssertEqual(list.test_rows.first?.savedFolderName, "Celerity")
    }

    // MARK: - Threading in a folder

    private func saveThread(into folder: MailFolder) throws -> [SavedMessage] {
        let root = try model.saveMessage(
            message(id: 1, minutesAgo: 30, subject: "Expert report"),
            detail: .fixture(id: 1, messageID: "<root@x>", recipients: "you@example.com"),
            into: folder
        )
        let reply = try model.saveMessage(
            message(id: 2, minutesAgo: 10, subject: "RE: Expert report"),
            detail: .fixture(
                id: 2,
                messageID: "<reply@x>",
                inReplyTo: "<root@x>",
                references: "<root@x>",
                recipients: "you@example.com"
            ),
            into: folder
        )
        return [root, reply]
    }

    func testAFolderShowsConversationsRatherThanAFlatList() throws {
        let folder = try model.createMailFolder(name: "Celerity")
        _ = try saveThread(into: folder)
        selection.selectMailbox(.folder(folder.uuid))
        list.reload()

        XCTAssertEqual(list.test_threadSubjects, ["Expert report"])
        XCTAssertEqual(list.test_folderRows.count, 1, "the two messages did not thread")
    }

    /// A conversation of one is just a message; wrapping it would cost a click
    /// on the common case.
    func testALoneMessageIsNotWrappedInAConversation() throws {
        let folder = try model.createMailFolder(name: "Celerity")
        try model.saveMessage(
            message(id: 1, subject: "Standalone"),
            detail: .fixture(id: 1, messageID: "<one@x>"),
            into: folder
        )
        selection.selectMailbox(.folder(folder.uuid))
        list.reload()

        XCTAssertTrue(list.test_threadSubjects.isEmpty)
        XCTAssertTrue(list.test_folderRows.first is SavedMessageRow)
    }

    func testTheConversationCountsTheMessagesInIt() throws {
        let folder = try model.createMailFolder(name: "Celerity")
        let messages = try saveThread(into: folder)
        selection.selectMailbox(.folder(folder.uuid))
        list.reload()

        XCTAssertEqual(list.conversation(containing: messages[0].uuid).count, 2)
        // Newest first, matching the list.
        XCTAssertEqual(
            list.conversation(containing: messages[0].uuid).map(\.uuid),
            [messages[1].uuid, messages[0].uuid]
        )
    }

    func testTheReaderCountsThePositionInTheConversation() throws {
        let folder = try model.createMailFolder(name: "Celerity")
        let messages = try saveThread(into: folder)
        selection.selectMailbox(.folder(folder.uuid))
        list.reload()

        selection.selectMessage(.saved(messages[0].uuid))
        XCTAssertEqual(reader.test_conversationPosition, "Message 2 of 2 in this conversation")
        selection.selectMessage(.saved(messages[1].uuid))
        XCTAssertEqual(reader.test_conversationPosition, "Message 1 of 2 in this conversation")
    }

    func testALoneMessageHasNoConversationLine() throws {
        let folder = try model.createMailFolder(name: "Celerity")
        let saved = try model.saveMessage(
            message(id: 1, subject: "Standalone"),
            detail: .fixture(id: 1, messageID: "<one@x>"),
            into: folder
        )
        selection.selectMailbox(.folder(folder.uuid))
        list.reload()
        selection.selectMessage(.saved(saved.uuid))
        XCTAssertNil(reader.test_conversationPosition)
    }

    // MARK: - Reading a saved message

    func testASavedMessageNeedsNoFetch() throws {
        let folder = try model.createMailFolder(name: "Celerity")
        let saved = try model.saveMessage(
            message(id: 5),
            detail: .fixture(id: 5, body: "Stored body", messageID: "<five@x>"),
            into: folder
        )
        selection.selectMailbox(.folder(folder.uuid))
        selection.selectMessage(.saved(saved.uuid))

        XCTAssertEqual(reader.test_body, "Stored body")
        XCTAssertFalse(reader.test_isBodyLoading)
        XCTAssertEqual(source.requestedDetailIDs, [], "a saved message was fetched from Outlook")
    }

    /// Saved mail does not expire; that is what saving it was for.
    func testASavedMessageHasNoExpiryBanner() throws {
        let folder = try model.createMailFolder(name: "Celerity")
        let saved = try model.saveMessage(
            message(id: 5, minutesAgo: 60 * 24 * 30),
            detail: .fixture(id: 5, messageID: "<five@x>"),
            into: folder
        )
        selection.selectMailbox(.folder(folder.uuid))
        selection.selectMessage(.saved(saved.uuid))
        XCTAssertNil(reader.test_expiryText)
    }

    // MARK: - Moving and removing

    func testMovingReassignsTheFolderAndFollowsTheMessage() throws {
        let source = try model.createMailFolder(name: "Source")
        let destination = try model.createMailFolder(name: "Destination")
        let saved = try model.saveMessage(
            message(id: 5),
            detail: .fixture(id: 5, messageID: "<five@x>"),
            into: source
        )
        selection.selectMailbox(.folder(source.uuid))
        selection.selectMessage(.saved(saved.uuid))

        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.representedObject = destination
        split.moveMessageToFolder(item)

        XCTAssertEqual(saved.folder?.uuid, destination.uuid)
        XCTAssertEqual(selection.selectedFolderUUID, destination.uuid, "the sidebar did not follow")
        XCTAssertEqual(selection.message, .saved(saved.uuid))
    }

    func testRemovingDeletesTheCopyAndClearsTheReader() throws {
        let folder = try model.createMailFolder(name: "Celerity")
        let saved = try model.saveMessage(
            message(id: 5),
            detail: .fixture(id: 5, messageID: "<five@x>"),
            into: folder
        )
        selection.selectMailbox(.folder(folder.uuid))
        selection.selectMessage(.saved(saved.uuid))

        split.removeSavedMessage(confirmed: true)
        XCTAssertTrue(model.messages(in: folder).isEmpty)
        XCTAssertNil(selection.message)
        XCTAssertTrue(reader.test_isEmptyStateVisible)
    }

    /// The confirmation exists because removing discards Planner's only copy —
    /// so it says exactly that.
    func testTheRemoveSheetSaysItIsTheOnlyCopy() throws {
        let folder = try model.createMailFolder(name: "Celerity")
        let saved = try model.saveMessage(
            message(id: 5, subject: "Deposition prep"),
            detail: .fixture(id: 5, messageID: "<five@x>"),
            into: folder
        )
        let text = MainSplitViewController.removeConfirmationMessage(for: saved)
        XCTAssertTrue(text.contains("Deposition prep"), text)
        XCTAssertTrue(text.contains("only copy"), text)
    }

    // MARK: - Commands

    func testSaveIsOfferedOnlyForRecentMailAndMoveOnlyForSavedMail() throws {
        let folder = try model.createMailFolder(name: "Celerity")
        let saved = try model.saveMessage(
            message(id: 5),
            detail: .fixture(id: 5, messageID: "<five@x>"),
            into: folder
        )

        selection.selectMessage(nil)
        XCTAssertFalse(split.validateMenuItem(item(#selector(MainSplitViewController.saveMessageToFolder(_:)))))
        XCTAssertFalse(split.validateMenuItem(item(#selector(MainSplitViewController.moveMessageToFolder(_:)))))

        selection.selectMessage(.recent(5))
        XCTAssertTrue(split.validateMenuItem(item(#selector(MainSplitViewController.saveMessageToFolder(_:)))))
        XCTAssertFalse(split.validateMenuItem(item(#selector(MainSplitViewController.removeSavedMessage(_:)))))

        selection.selectMailbox(.folder(folder.uuid))
        selection.selectMessage(.saved(saved.uuid))
        XCTAssertFalse(split.validateMenuItem(item(#selector(MainSplitViewController.saveMessageToFolder(_:)))))
        XCTAssertTrue(split.validateMenuItem(item(#selector(MainSplitViewController.moveMessageToFolder(_:)))))
        XCTAssertTrue(split.validateMenuItem(item(#selector(MainSplitViewController.removeSavedMessage(_:)))))
    }

    func testOpenInOutlookUsesTheStoredIdForASavedMessage() async throws {
        let folder = try model.createMailFolder(name: "Celerity")
        let saved = try model.saveMessage(
            message(id: 77),
            detail: .fixture(id: 77, messageID: "<seven@x>"),
            into: folder
        )
        selection.selectMailbox(.folder(folder.uuid))
        selection.selectMessage(.saved(saved.uuid))

        split.openMessageInOutlook(nil)
        await settle { !self.source.revealedIDs.isEmpty }
        XCTAssertEqual(source.revealedIDs, [77])
    }

    // MARK: - The list's context menu

    func testTheContextMenuOffersWhatTheRowCanHaveDoneToIt() async throws {
        await load([message(id: 5)])
        let recentRow = try XCTUnwrap(list.test_rows.first)
        let recentMenu = try XCTUnwrap(list.outlineView.menu(forRow: list.outlineView.row(forItem: recentRow)))
        XCTAssertEqual(recentMenu.items.first?.action, #selector(MainSplitViewController.saveMessageToFolder(_:)))

        let folder = try model.createMailFolder(name: "Celerity")
        let saved = try model.saveMessage(
            message(id: 6),
            detail: .fixture(id: 6, messageID: "<six@x>"),
            into: folder
        )
        selection.selectMailbox(.folder(folder.uuid))
        list.reload()
        let savedRow = try XCTUnwrap(list.test_folderRows.first)
        let savedMenu = try XCTUnwrap(list.outlineView.menu(forRow: list.outlineView.row(forItem: savedRow)))
        XCTAssertEqual(savedMenu.items.first?.action, #selector(MainSplitViewController.moveMessageToFolder(_:)))
        XCTAssertEqual(savedMenu.items.last?.action, #selector(MainSplitViewController.removeSavedMessage(_:)))
        XCTAssertEqual(saved.folder?.uuid, folder.uuid)
    }

    /// A date header and a conversation heading are labels, not things to act
    /// on, so neither gets a menu.
    func testHeadingsHaveNoContextMenu() async throws {
        await load([message(id: 5)])
        XCTAssertNil(list.outlineView.menu(forRow: 0), "the date header offered a menu")
        XCTAssertNil(list.outlineView.menu(forRow: -1), "the empty area offered a menu")
    }

    // MARK: - Participants

    func testThreadParticipantsAreDeduplicatedAndTruncated() {
        XCTAssertEqual(MailLabels.threadParticipants(["Ada", "Ada", "Grace"]), "Ada, Grace")
        XCTAssertEqual(
            MailLabels.threadParticipants(["A", "B", "C", "D", "E"]),
            "A, B, C and 2 more"
        )
    }

    /// The subject fallback in threading turns on a participant overlap, so
    /// pulling addresses out of a `To:` line has to survive quoted names with
    /// commas in them.
    func testAddressesAreExtractedFromRealisticRecipientLines() {
        XCTAssertEqual(
            SavedMessage.addresses(in: "\"Hashem, Rayiner\" <rhashem@x.com>, ada@y.com"),
            ["rhashem@x.com", "ada@y.com"]
        )
        XCTAssertEqual(SavedMessage.addresses(in: nil), [])
        XCTAssertEqual(SavedMessage.addresses(in: "Undisclosed recipients"), [])
    }

    private func item(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "")
    }
}
