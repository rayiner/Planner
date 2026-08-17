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
    private var undoVendor: UndoManagerVendor?

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
        undoVendor = nil
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
        split.saveMessageToFolder(folderMenuItem(folder))

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
        split.saveMessageToFolder(folderMenuItem(folder))
        await settle { self.source.pendingDetailCount > 0 }
        source.finishDetail(id: 5, throwing: MailSourceError.messageUnavailable)
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertTrue(model.messages(in: folder).isEmpty)
    }

    func testSavingIntoANewFolderCreatesOneAndStartsRenamingIt() async throws {
        let envelope = message(id: 5)
        await load([envelope])
        var began: UUID?
        split.outlineViewController.loadViewIfNeeded()
        split.outlineViewController.beginEditingNameHandler = { began = $0.uuid }

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
        split.saveMessageToFolder(folderMenuItem(nil))
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

    /// Children sit under the header, not in the same column as a lone
    /// message. Recent Mail keeps zero indent so day titles stay clean.
    func testConversationChildrenAreIndentedAndMarked() throws {
        let folder = try model.createMailFolder(name: "Celerity")
        _ = try saveThread(into: folder)
        selection.selectMailbox(.folder(folder.uuid))
        list.reload()

        XCTAssertEqual(list.test_indentationPerLevel, MailListViewController.conversationIndent)
        let thread = try XCTUnwrap(list.test_folderRows.first as? MailThreadRow)
        list.outlineView.expandItem(thread)
        XCTAssertEqual(list.outlineView.level(forItem: thread), 0)
        let child = try XCTUnwrap(thread.rows.first)
        XCTAssertEqual(list.outlineView.level(forItem: child), 1)
        XCTAssertTrue(list.test_showsConversationTick(for: child))
        XCTAssertFalse(list.test_showsConversationTick(for: thread))
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
        let lone = try XCTUnwrap(list.test_folderRows.first)
        XCTAssertEqual(list.outlineView.level(forItem: lone), 0)
        XCTAssertFalse(list.test_showsConversationTick(for: lone))
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

    func testSearchingAThreadFlattensItAndClearingRestoresTheConversation() throws {
        let folder = try model.createMailFolder(name: "Celerity")
        _ = try saveThread(into: folder)
        selection.selectMailbox(.folder(folder.uuid))
        list.reload()
        XCTAssertEqual(list.test_threadSubjects, ["Expert report"])

        list.test_applySearch("expert")
        XCTAssertTrue(list.test_threadSubjects.isEmpty)
        XCTAssertEqual(list.test_folderRows.count, 2)
        XCTAssertTrue(list.test_folderRows.allSatisfy { $0 is SavedMessageRow })
        XCTAssertEqual(list.test_indentationPerLevel, 0)

        list.test_clearSearch(resigning: false)
        XCTAssertEqual(list.test_threadSubjects, ["Expert report"])
        XCTAssertEqual(list.test_folderRows.count, 1)
        XCTAssertEqual(list.test_indentationPerLevel, MailListViewController.conversationIndent)
    }

    /// Flattening keeps the same `.saved` uuid, so rebind never runs; the
    /// list has to tell the reader the conversation is gone.
    func testSearchingHidesConversationChromeAndClearingRestoresIt() throws {
        let folder = try model.createMailFolder(name: "Celerity")
        let messages = try saveThread(into: folder)
        selection.selectMailbox(.folder(folder.uuid))
        list.reload()
        selection.selectMessage(.saved(messages[1].uuid))
        XCTAssertEqual(reader.test_conversationPosition, "Message 1 of 2 in this conversation")

        list.test_applySearch("expert")
        XCTAssertNil(reader.test_conversationPosition)

        list.test_clearSearch(resigning: false)
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

    func testASavedHTMLBodyIsRendered() throws {
        let folder = try model.createMailFolder(name: "Celerity")
        let saved = try model.saveMessage(
            message(id: 5),
            detail: .fixture(
                id: 5,
                body: "Hello there",
                html: "<p>Hello <b>there</b></p>",
                messageID: "<five@x>"
            ),
            into: folder
        )
        selection.selectMailbox(.folder(folder.uuid))
        selection.selectMessage(.saved(saved.uuid))

        XCTAssertTrue(reader.test_body.contains("Hello"))
        XCTAssertTrue(reader.test_bodyHasBold)
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

        split.moveMessageToFolder(folderMenuItem(destination))

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

        split.removeSelectedMessage(confirmed: true)
        XCTAssertTrue(model.messages(in: folder).isEmpty)
        XCTAssertNil(selection.message)
        XCTAssertTrue(reader.test_isEmptyStateVisible)
    }

    func testRemovingASavedMessageSelectsTheNextOne() throws {
        let folder = try model.createMailFolder(name: "Celerity")
        let first = try model.saveMessage(
            message(id: 5, minutesAgo: 0),
            detail: .fixture(id: 5, messageID: "<five@x>"),
            into: folder
        )
        let second = try model.saveMessage(
            message(id: 6, minutesAgo: 10),
            detail: .fixture(id: 6, messageID: "<six@x>"),
            into: folder
        )
        selection.selectMailbox(.folder(folder.uuid))
        list.reload()
        selection.selectMessage(.saved(first.uuid))

        split.removeSelectedMessage(confirmed: true)
        XCTAssertEqual(model.messages(in: folder).map(\.uuid), [second.uuid])
        XCTAssertEqual(selection.message, .saved(second.uuid))
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
        XCTAssertFalse(split.validateMenuItem(item(#selector(MainSplitViewController.removeSelectedMessage(_:)))))

        selection.selectMailbox(.folder(folder.uuid))
        selection.selectMessage(.saved(saved.uuid))
        XCTAssertFalse(split.validateMenuItem(item(#selector(MainSplitViewController.saveMessageToFolder(_:)))))
        XCTAssertTrue(split.validateMenuItem(item(#selector(MainSplitViewController.moveMessageToFolder(_:)))))
        XCTAssertTrue(split.validateMenuItem(item(#selector(MainSplitViewController.removeSelectedMessage(_:)))))
    }

    /// The toolbar's folder button does double duty: it saves from Recent
    /// Mail, moves within a folder, and validates whenever either half would.
    func testTheFolderButtonSavesFromRecentMailAndMovesWithinAFolder() async throws {
        let envelope = message(id: 5)
        await load([envelope])
        let button = item(#selector(MainSplitViewController.fileMessageToFolder(_:)))

        selection.selectMessage(nil)
        XCTAssertFalse(split.validateMenuItem(button))

        // Over Recent Mail the button is Save.
        let folder = try model.createMailFolder(name: "Celerity")
        selection.selectMessage(.recent(5))
        XCTAssertTrue(split.validateMenuItem(button))
        split.fileMessageToFolder(folderMenuItem(folder))
        await settle { self.source.pendingDetailCount > 0 }
        source.finishDetail(.fixture(id: 5, messageID: "<five@x>"))
        await settle { !self.model.messages(in: folder).isEmpty }
        let saved = try XCTUnwrap(model.messages(in: folder).first)

        // Over a folder the same button is Move.
        let destination = try model.createMailFolder(name: "Destination")
        selection.selectMailbox(.folder(folder.uuid))
        selection.selectMessage(.saved(saved.uuid))
        XCTAssertTrue(split.validateMenuItem(button))
        split.fileMessageToFolder(folderMenuItem(destination))
        XCTAssertEqual(saved.folder?.uuid, destination.uuid)
    }

    /// The one button is named for whichever half it would do, so the tooltip
    /// and overflow menu never promise the wrong verb.
    func testTheFolderButtonIsNamedForTheOpenMailbox() throws {
        let item = try XCTUnwrap(split.toolbar(
            NSToolbar(identifier: "test"),
            itemForItemIdentifier: .fileMessage,
            willBeInsertedIntoToolbar: true
        ))
        _ = split.validateToolbarItem(item)
        XCTAssertEqual(item.label, "Save")

        let folder = try model.createMailFolder(name: "Celerity")
        selection.selectMailbox(.folder(folder.uuid))
        _ = split.validateToolbarItem(item)
        XCTAssertEqual(item.label, "Move")
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
        XCTAssertEqual(savedMenu.items.last?.action, #selector(MainSplitViewController.removeSelectedMessage(_:)))
        XCTAssertEqual(saved.folder?.uuid, folder.uuid)
    }

    /// A date header and a conversation heading are labels, not things to act
    /// on, so neither gets a menu.
    func testHeadingsHaveNoContextMenu() async throws {
        await load([message(id: 5)])
        XCTAssertNil(list.outlineView.menu(forRow: 0), "the date header offered a menu")
        XCTAssertNil(list.outlineView.menu(forRow: -1), "the empty area offered a menu")
    }

    // MARK: - Folder search

    /// reloadData jumps to the top; a query edit is a new list, a did-save
    /// with the same query is not.
    func testChangingTheQueryResetsScrollAndASaveWithTheSameQueryDoesNot() throws {
        let folder = try model.createMailFolder(name: "Celerity")
        for index in 1...24 {
            try model.saveMessage(
                message(id: Int64(index), minutesAgo: index),
                detail: .fixture(id: Int64(index), messageID: "<\(index)@x>"),
                into: folder
            )
        }
        selection.selectMailbox(.folder(folder.uuid))
        list.reload()
        prepareListForScrollAssertions()

        list.test_applySearch("ada")
        scrollFolderListToLastRow()
        let originBefore = list.test_scrollOrigin
        XCTAssertGreaterThan(originBefore.y, 0, "the list never left the top, so this is not a scroll test")

        list.test_applySearch("deposition")
        XCTAssertEqual(list.test_scrollOrigin.y, 0, accuracy: 1)

        scrollFolderListToLastRow()
        let originAfterScroll = list.test_scrollOrigin
        XCTAssertGreaterThan(originAfterScroll.y, 0)

        try model.saveMessage(
            message(id: 100, minutesAgo: 0),
            detail: .fixture(id: 100, messageID: "<hundred@x>"),
            into: folder
        )
        XCTAssertEqual(list.test_searchQuery, "deposition")
        XCTAssertEqual(list.test_scrollOrigin.y, originAfterScroll.y, accuracy: 1)
    }

    func testATrailingSpaceDoesNotReloadOrJumpScroll() throws {
        let folder = try model.createMailFolder(name: "Celerity")
        for index in 1...24 {
            try model.saveMessage(
                message(id: Int64(index), minutesAgo: index),
                detail: .fixture(id: Int64(index), messageID: "<\(index)@x>"),
                into: folder
            )
        }
        selection.selectMailbox(.folder(folder.uuid))
        list.reload()
        prepareListForScrollAssertions()

        list.test_applySearch("ada")
        scrollFolderListToLastRow()
        let originBefore = list.test_scrollOrigin
        XCTAssertGreaterThan(originBefore.y, 0, "the list never left the top, so this is not a scroll test")

        list.test_applySearch("ada ")
        XCTAssertEqual(list.test_searchQuery, "ada ")
        XCTAssertEqual(list.test_scrollOrigin.y, originBefore.y, accuracy: 1)
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

    // MARK: - Dismissing from Recent Mail

    /// Anchored on the real clock rather than on `message(id:)`'s fixed epoch.
    /// Dismissals are pruned against "older than the widest window can reach",
    /// so a fixture pinned to a date in the past stops being dismissable as
    /// soon as the calendar walks past it — these tests need mail that is
    /// actually recent, which is also what the feature ever sees.
    private func recentMessage(id: Int64, minutesAgo: Int = 0) -> MailMessage {
        MailMessage(
            id: id,
            subject: "Deposition prep",
            senderName: "Ada Lovelace",
            senderAddress: "ada@example.com",
            receivedAt: Date().addingTimeInterval(TimeInterval(-minutesAgo * 60)),
            isRead: false
        )
    }

    func testTheTrashDismissesFromRecentMailWithoutASheet() async {
        let envelope = recentMessage(id: 5)
        await load([envelope, recentMessage(id: 6, minutesAgo: 10)])
        selection.selectMessage(.recent(5))

        split.removeSelectedMessage(nil)
        XCTAssertEqual(coordinator.messages.map(\.id), [6])
        XCTAssertEqual(selection.message, .recent(6))
    }

    /// The reason the neighbour is selected at all: ⌫ ⌫ ⌫ should walk the
    /// list, not stop after the first because nothing is selected anymore.
    func testSequentialDismissalsWalkDownTheList() async {
        await load([
            recentMessage(id: 5),
            recentMessage(id: 6, minutesAgo: 10),
            recentMessage(id: 7, minutesAgo: 20),
        ])
        selection.selectMessage(.recent(5))

        split.removeSelectedMessage(nil)
        XCTAssertEqual(selection.message, .recent(6))
        split.removeSelectedMessage(nil)
        XCTAssertEqual(selection.message, .recent(7))
        split.removeSelectedMessage(nil)
        XCTAssertNil(selection.message)
        XCTAssertTrue(coordinator.messages.isEmpty)
    }

    func testDismissingTheLastRowSelectsThePreviousOne() async {
        await load([recentMessage(id: 5), recentMessage(id: 6, minutesAgo: 10)])
        selection.selectMessage(.recent(6))

        split.removeSelectedMessage(nil)
        XCTAssertEqual(coordinator.messages.map(\.id), [5])
        XCTAssertEqual(selection.message, .recent(5))
    }

    /// reloadData jumps to the top; a dismissal in the middle of a sweep
    /// must not take the user back to the newest mail.
    func testDismissingPreservesScrollPosition() async {
        let messages = (1...24).map { recentMessage(id: Int64($0), minutesAgo: $0) }
        await load(messages)
        windows.first?.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 400), display: true)
        windows.first?.layoutIfNeeded()
        list.view.layoutSubtreeIfNeeded()

        selection.selectMessage(.recent(16))
        if let row = list.test_rows.first(where: { $0.message.id == 16 }) {
            list.outlineView.scrollRowToVisible(list.outlineView.row(forItem: row))
        }
        let originBefore = list.test_scrollOrigin
        XCTAssertGreaterThan(originBefore.y, 0, "the list never left the top, so this is not a scroll test")

        split.removeSelectedMessage(nil)
        XCTAssertEqual(selection.message, .recent(17))
        XCTAssertEqual(list.test_scrollOrigin.y, originBefore.y, accuracy: 1)
    }

    /// The half of the double duty that must not have changed.
    func testTheTrashStillRemovesFromAFolder() async throws {
        let folder = try model.createMailFolder(name: "Celerity")
        let saved = try model.saveMessage(
            recentMessage(id: 5),
            detail: .fixture(id: 5, messageID: "<five@x>"),
            into: folder
        )
        selection.selectMailbox(.folder(folder.uuid))
        selection.selectMessage(.saved(saved.uuid))

        split.removeSelectedMessage(confirmed: true)
        XCTAssertTrue(model.messages(in: folder).isEmpty)
    }

    /// A filed message keeps its Recent Mail row, because that row's "Saved to
    /// …" chip is the receipt for the filing.
    func testAMessageAlreadySavedCannotBeDismissed() async throws {
        let folder = try model.createMailFolder(name: "Celerity")
        let envelope = recentMessage(id: 5)
        await load([envelope])
        await save(envelope, into: folder)

        selection.selectMailbox(.recent)
        selection.selectMessage(.recent(5))
        XCTAssertFalse(
            split.validateMenuItem(item(#selector(MainSplitViewController.removeSelectedMessage(_:))))
        )
        split.removeSelectedMessage(nil)
        XCTAssertEqual(coordinator.messages.map(\.id), [5])
    }

    func testTheTrashIsNamedForTheOpenMailbox() async {
        await load([recentMessage(id: 5)])
        selection.selectMessage(.recent(5))
        let toolbarItem = NSToolbarItem(itemIdentifier: .removeMessage)
        toolbarItem.action = #selector(MainSplitViewController.removeSelectedMessage(_:))

        _ = split.validateToolbarItem(toolbarItem)
        XCTAssertEqual(toolbarItem.label, "Dismiss")
        XCTAssertTrue(toolbarItem.toolTip?.contains("Outlook is unchanged") == true)

        selection.selectMailbox(.folder(UUID()))
        _ = split.validateToolbarItem(toolbarItem)
        XCTAssertEqual(toolbarItem.label, "Remove")
    }

    /// The ellipsis promises a sheet, and only the folder half opens one.
    func testTheMenuItemDropsItsEllipsisOverRecentMail() async {
        await load([recentMessage(id: 5)])
        selection.selectMessage(.recent(5))
        let menuItem = item(#selector(MainSplitViewController.removeSelectedMessage(_:)))

        _ = split.validateMenuItem(menuItem)
        XCTAssertEqual(menuItem.title, "Remove from Recent Mail")
    }

    /// The bare key, which is the gesture the list actually gets used with —
    /// the menu's ⌘⌫ is the sidebar's delete.
    func testBareDeleteInTheListDismissesTheSelectedMessage() async {
        await load([recentMessage(id: 5), recentMessage(id: 6, minutesAgo: 10)])
        selection.selectMessage(.recent(5))
        list.outlineView.keyDown(with: Self.deleteKeyEvent())
        XCTAssertEqual(coordinator.messages.map(\.id), [6])
        XCTAssertEqual(selection.message, .recent(6))
        list.outlineView.keyDown(with: Self.deleteKeyEvent())
        XCTAssertTrue(coordinator.messages.isEmpty)
        XCTAssertNil(selection.message)
    }

    func testBareDeleteWithNoRowSelectedDoesNothing() async {
        await load([recentMessage(id: 5)])
        list.outlineView.deselectAll(nil)
        selection.selectMessage(nil)
        list.outlineView.keyDown(with: Self.deleteKeyEvent())
        XCTAssertEqual(coordinator.messages.map(\.id), [5])
    }

    private static func deleteKeyEvent() -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{8}",
            charactersIgnoringModifiers: "\u{8}",
            isARepeat: false,
            keyCode: 51
        )!
    }

    func testDeleteActsOnTheListWhenTheListHasFocusAndTheSidebarOtherwise() async throws {
        let folder = try model.createMailFolder(name: "Celerity")
        let envelope = recentMessage(id: 5)
        await load([envelope])
        selection.selectMessage(.recent(5))

        // Sidebar focused: ⌫ still means the mailbox row, so Recent Mail — which
        // is not a folder — is left alone.
        split.firstResponderForValidation = split.outlineViewController.view
        split.deleteSelected(nil)
        XCTAssertEqual(coordinator.messages.map(\.id), [5])

        split.firstResponderForValidation = list.outlineView
        split.deleteSelected(nil)
        XCTAssertTrue(coordinator.messages.isEmpty)
        XCTAssertEqual(model.mailFolders().map(\.name), ["Celerity"], "⌫ over the list hit the folder")
    }

    /// ⌘Z has to reach a dismissal, and it has to reach it on the *same* stack
    /// as everything else — so the window vends the Core Data undo manager here
    /// exactly as `AppDelegate` does in the running app.
    func testUndoBringsADismissedMessageBackOnTheSharedStack() async throws {
        let undo = try XCTUnwrap(persistence.viewContext.undoManager)
        let vendor = UndoManagerVendor(undoManager: undo)
        undoVendor = vendor
        windows.first?.delegate = vendor

        await load([recentMessage(id: 5), recentMessage(id: 6, minutesAgo: 10)])
        selection.selectMessage(.recent(5))

        split.removeSelectedMessage(nil)
        XCTAssertEqual(coordinator.messages.map(\.id), [6])
        XCTAssertEqual(undo.undoActionName, "Remove from Recent Mail")

        undo.undo()
        XCTAssertEqual(coordinator.messages.map(\.id), [5, 6])
        XCTAssertEqual(selection.message, .recent(5))
    }

    func testTheContextMenuOffersDismissalOnARecentRow() async {
        await load([recentMessage(id: 5)])
        let row = try? XCTUnwrap(list.outlineView.item(atRow: 1))
        let menu = list.outlineView.menu(forRow: 1)
        XCTAssertNotNil(row)
        XCTAssertEqual(
            menu?.items.last?.action,
            #selector(MainSplitViewController.removeSelectedMessage(_:))
        )
        XCTAssertEqual(menu?.items.last?.title, "Remove from Recent Mail")
    }

    // MARK: - Find, Escape, and list focus

    func testFindShowPanelFocusesTheFieldInAFolderAndIsANoOpOnRecentMail() throws {
        let folder = try model.createMailFolder(name: "Celerity")
        try model.saveMessage(
            recentMessage(id: 5),
            detail: .fixture(id: 5, messageID: "<five@x>"),
            into: folder
        )
        selection.selectMailbox(.folder(folder.uuid))
        list.reload()
        let window = try XCTUnwrap(windows.first)
        window.makeKeyAndOrderFront(nil)
        list.view.layoutSubtreeIfNeeded()

        let show = findItem(.showFindPanel)
        XCTAssertTrue(split.validateMenuItem(show))
        XCTAssertFalse(
            split.test_isCommandEnabled(for: #selector(NSTextView.performFindPanelAction(_:))),
            "Find is validated by tag, not isCommandEnabled"
        )
        split.performFindPanelAction(show)
        let responder = window.firstResponder
        XCTAssertTrue(
            responder === list.test_searchField
                || responder === list.test_searchField.currentEditor()
                || responder is MailSearchFieldEditor,
            "⌘F should focus the search field, got \(String(describing: responder))"
        )

        selection.selectMailbox(.recent)
        list.reload()
        XCTAssertFalse(split.validateMenuItem(show))
        split.performFindPanelAction(show)
        let after = window.firstResponder
        XCTAssertFalse(
            after === list.test_searchField || after is MailSearchFieldEditor
        )
    }

    func testFindIsEnabledOverTheReaderBodyEvenInRecentMail() {
        selection.selectMailbox(.recent)
        split.firstResponderForValidation = list.outlineView
        XCTAssertFalse(split.validateMenuItem(findItem(.showFindPanel)))
        XCTAssertFalse(split.validateMenuItem(findItem(.next)))

        split.firstResponderForValidation = reader.test_bodyView
        XCTAssertTrue(split.validateMenuItem(findItem(.showFindPanel)))
        XCTAssertTrue(split.validateMenuItem(findItem(.next)))
        XCTAssertTrue(split.validateMenuItem(findItem(.previous)))
        XCTAssertTrue(split.validateMenuItem(findItem(.setFindString)))
    }

    func testFindNextPreviousAndUseSelectionValidateOnlyOverAFindBarTextView() throws {
        let folder = try model.createMailFolder(name: "Celerity")
        selection.selectMailbox(.folder(folder.uuid))

        let show = findItem(.showFindPanel)
        let next = findItem(.next)
        let previous = findItem(.previous)
        let useSelection = findItem(.setFindString)

        split.firstResponderForValidation = list.outlineView
        XCTAssertTrue(split.validateMenuItem(show))
        XCTAssertFalse(split.validateMenuItem(next))
        XCTAssertFalse(split.validateMenuItem(previous))
        XCTAssertFalse(split.validateMenuItem(useSelection))

        split.firstResponderForValidation = list.test_searchField
        XCTAssertTrue(split.validateMenuItem(show))
        XCTAssertFalse(split.validateMenuItem(next))
        XCTAssertFalse(split.validateMenuItem(previous))
        XCTAssertFalse(split.validateMenuItem(useSelection))

        split.firstResponderForValidation = list.test_searchField.searchEditor
        XCTAssertTrue(split.validateMenuItem(show))
        XCTAssertFalse(split.validateMenuItem(next))
        XCTAssertFalse(split.validateMenuItem(previous))
        XCTAssertFalse(split.validateMenuItem(useSelection))

        split.firstResponderForValidation = reader.test_bodyView
        XCTAssertTrue(split.validateMenuItem(show))
        XCTAssertTrue(split.validateMenuItem(next))
        XCTAssertTrue(split.validateMenuItem(previous))
        XCTAssertTrue(split.validateMenuItem(useSelection))
    }

    func testTheSearchFieldEditorIsAFieldEditorAndSwallowsFindAsSelectAll() {
        let editor = list.test_searchField.searchEditor
        XCTAssertTrue(editor.isFieldEditor)
        XCTAssertFalse(editor.isRichText)

        editor.string = "ada report"
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.performFindPanelAction(findItem(.showFindPanel))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: editor.string.utf16.count))

        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.performFindPanelAction(findItem(.next))
        XCTAssertEqual(editor.selectedRange().length, 0)
    }

    func testTheReaderBodyAndNotesUseTheFindBar() {
        XCTAssertTrue(reader.test_bodyView.usesFindBar)
        XCTAssertTrue(reader.test_bodyView.isIncrementalSearchingEnabled)
        let notes = NoteTextView(frame: .zero)
        XCTAssertTrue(notes.usesFindBar)
        XCTAssertTrue(notes.isIncrementalSearchingEnabled)
    }

    func testRemoveIsGatedWhileTheSearchFieldIsEditing() throws {
        let folder = try model.createMailFolder(name: "Celerity")
        let saved = try model.saveMessage(
            recentMessage(id: 5),
            detail: .fixture(id: 5, messageID: "<five@x>"),
            into: folder
        )
        selection.selectMailbox(.folder(folder.uuid))
        selection.selectMessage(.saved(saved.uuid))

        XCTAssertTrue(split.validateMenuItem(item(#selector(MainSplitViewController.removeSelectedMessage(_:)))))

        split.firstResponderForValidation = list.test_searchField.searchEditor
        XCTAssertFalse(split.validateMenuItem(item(#selector(MainSplitViewController.removeSelectedMessage(_:)))))
        XCTAssertFalse(split.validateMenuItem(item(#selector(MainSplitViewController.deleteSelected(_:)))))

        split.removeSelectedMessage(nil)
        XCTAssertEqual(model.messages(in: folder).map(\.uuid), [saved.uuid])

        split.firstResponderForValidation = nil
        split.removeSelectedMessage(confirmed: true)
        XCTAssertTrue(model.messages(in: folder).isEmpty)
    }

    func testEscapeInTheEmptySearchFieldResignsToTheList() throws {
        let folder = try model.createMailFolder(name: "Celerity")
        selection.selectMailbox(.folder(folder.uuid))
        list.reload()
        windows.first?.makeFirstResponder(list.test_searchField)

        let handled = list.control(
            list.test_searchField,
            textView: list.test_searchField.searchEditor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        )
        XCTAssertTrue(handled)
        XCTAssertTrue(windows.first?.firstResponder === list.outlineView)
    }

    func testEscapeInTheSearchFieldWithAQueryDoesNotStealCancel() throws {
        let folder = try model.createMailFolder(name: "Celerity")
        selection.selectMailbox(.folder(folder.uuid))
        list.test_searchField.stringValue = "ada"
        let handled = list.control(
            list.test_searchField,
            textView: list.test_searchField.searchEditor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        )
        XCTAssertFalse(handled)
        XCTAssertEqual(list.test_searchField.stringValue, "ada")
    }

    func testEscapeInTheOutlineClearsAnActiveQueryAndLeavesAnEmptyOne() throws {
        let folder = try model.createMailFolder(name: "Celerity")
        try model.saveMessage(
            recentMessage(id: 5),
            detail: .fixture(id: 5, body: "ada report", messageID: "<five@x>"),
            into: folder
        )
        selection.selectMailbox(.folder(folder.uuid))
        list.reload()
        list.test_applySearch("ada")
        XCTAssertEqual(list.test_searchQuery, "ada")

        list.outlineView.keyDown(with: Self.escapeKeyEvent())
        XCTAssertEqual(list.test_searchQuery, "")
        XCTAssertEqual(list.test_searchField.stringValue, "")

        list.outlineView.keyDown(with: Self.escapeKeyEvent())
        XCTAssertEqual(list.test_searchQuery, "")
    }

    private func findItem(_ action: NSFindPanelAction) -> NSMenuItem {
        let item = NSMenuItem(
            title: "",
            action: #selector(NSTextView.performFindPanelAction(_:)),
            keyEquivalent: ""
        )
        item.tag = Int(action.rawValue)
        return item
    }

    private static func escapeKeyEvent() -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        )!
    }

    private func prepareListForScrollAssertions() {
        windows.first?.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 400), display: true)
        windows.first?.layoutIfNeeded()
        list.view.layoutSubtreeIfNeeded()
    }

    private func scrollFolderListToLastRow() {
        guard let last = list.test_folderRows.last else { return }
        list.outlineView.scrollRowToVisible(list.outlineView.row(forItem: last))
    }

    private func item(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "")
    }

    /// Shaped like the item the folder menu delivers: tagged, so the command
    /// can tell a chosen folder from a fresh invocation that has to ask.
    private func folderMenuItem(_ folder: MailFolder?) -> NSMenuItem {
        MainSplitViewController.folderMenuItem(
            title: folder?.name ?? "New Folder…",
            folder: folder,
            action: #selector(MainSplitViewController.saveMessageToFolder(_:))
        )
    }
}

/// Stands in for `AppDelegate`, which is the window delegate in the running app
/// and is what routes `NSResponder.undoManager` to the Core Data stack.
private final class UndoManagerVendor: NSObject, NSWindowDelegate {
    private let undoManager: UndoManager

    init(undoManager: UndoManager) {
        self.undoManager = undoManager
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undoManager }
}
