import AppKit
import XCTest
@testable import Planner

@MainActor
final class MailboxListTests: PersistenceTestCase {
    private var defaults: UserDefaults!
    private var windows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        defaults = isolatedDefaults()
    }

    override func tearDown() {
        for window in windows { window.contentViewController = nil }
        windows = []
        defaults = nil
        super.tearDown()
    }

    private func makeSplit() -> (MainSplitViewController, SelectionModel, MailboxListViewController) {
        let selection = SelectionModel(defaults: defaults)
        selection.setMode(.mail)
        let split = MainSplitViewController(
            persistence: persistence,
            model: model,
            selection: selection,
            events: EventCoordinator(source: NullEventSource()),
            mail: MailCoordinator(source: NullMailSource(), defaults: defaults),
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
        let mailboxes = split.mailboxListViewController
        mailboxes.loadViewIfNeeded()
        return (split, selection, mailboxes)
    }

    private func names(_ mailboxes: MailboxListViewController) -> [String] {
        let outline = mailboxes.outlineView
        return (0..<outline.numberOfRows).map { row in
            switch outline.item(atRow: row) {
            case let folder as MailFolder: return folder.name
            default: return MailLabels.recentMailName
            }
        }
    }

    // MARK: - Contents

    func testRecentMailIsAlwaysTheFirstRow() {
        let (_, _, mailboxes) = makeSplit()
        XCTAssertEqual(names(mailboxes), [MailLabels.recentMailName])
        XCTAssertTrue(mailboxes.outlineView.item(atRow: 0) is RecentMailbox)
    }

    func testFoldersFollowRecentMailInListOrder() throws {
        let (_, _, mailboxes) = makeSplit()
        try model.createMailFolder(name: "Celerity")
        try model.createMailFolder(name: "Paltalk")
        XCTAssertEqual(names(mailboxes), [MailLabels.recentMailName, "Celerity", "Paltalk"])
    }

    /// The sidebar reacts to did-save, so a folder created anywhere shows up.
    func testANewFolderAppearsWithoutAnExplicitReload() throws {
        let (_, _, mailboxes) = makeSplit()
        try model.createMailFolder(name: "New")
        XCTAssertEqual(mailboxes.outlineView.numberOfRows, 2)
    }

    func testDeletingAFolderRemovesItsRow() throws {
        let (_, _, mailboxes) = makeSplit()
        let folder = try model.createMailFolder(name: "Doomed")
        try model.deleteMailFolder(folder)
        XCTAssertEqual(names(mailboxes), [MailLabels.recentMailName])
    }

    func testEmptyStateShowsOnlyWhileThereAreNoFolders() throws {
        let (_, _, mailboxes) = makeSplit()
        XCTAssertTrue(mailboxes.test_isEmptyStateVisible)
        try model.createMailFolder()
        XCTAssertFalse(mailboxes.test_isEmptyStateVisible)
    }

    // MARK: - Selection

    func testSelectingAFolderRowPublishesTheMailboxSelection() throws {
        let (_, selection, mailboxes) = makeSplit()
        let folder = try model.createMailFolder(name: "Celerity")
        let row = mailboxes.outlineView.row(forItem: folder)
        XCTAssertGreaterThan(row, 0)

        mailboxes.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        XCTAssertEqual(selection.selectedFolderUUID, folder.uuid)
    }

    func testSelectingRecentMailPublishesRecent() throws {
        let (_, selection, mailboxes) = makeSplit()
        let folder = try model.createMailFolder()
        selection.selectMailbox(.folder(folder.uuid))

        mailboxes.outlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertTrue(selection.isRecentMailSelected)
    }

    func testAModelSelectionRevealsTheRow() throws {
        let (_, selection, mailboxes) = makeSplit()
        let folder = try model.createMailFolder(name: "Celerity")
        selection.selectMailbox(.folder(folder.uuid))
        XCTAssertEqual(
            mailboxes.outlineView.item(atRow: mailboxes.outlineView.selectedRow) as? MailFolder,
            folder
        )
    }

    // MARK: - Creating

    func testNewFolderSelectsItAndStartsRenaming() async throws {
        let (split, selection, mailboxes) = makeSplit()
        var began: UUID?
        mailboxes.beginEditingNameHandler = { began = $0.uuid }

        split.newMailFolder(nil)

        let folder = try XCTUnwrap(model.mailFolders().first)
        XCTAssertEqual(folder.name, "Untitled Folder")
        XCTAssertEqual(selection.selectedFolderUUID, folder.uuid)
        XCTAssertNil(began, "renaming starts on the next run loop, after the row exists")

        let scheduled = expectation(description: "begin edit")
        DispatchQueue.main.async { scheduled.fulfill() }
        await fulfillment(of: [scheduled], timeout: 1)
        XCTAssertEqual(began, folder.uuid)
    }

    /// New Folder from tasks mode has to land somewhere the user can see it.
    func testNewFolderFromTasksModeSwitchesToMail() {
        let (split, selection, _) = makeSplit()
        selection.setMode(.tasks)
        split.newMailFolder(nil)
        XCTAssertEqual(selection.mode, .mail)
    }

    func testNewFolderIsDisabledWhileRenaming() {
        let (split, _, _) = makeSplit()
        split.firstResponderForValidation = editingTextField()
        split.newMailFolder(nil)
        XCTAssertTrue(model.mailFolders().isEmpty)
    }

    // MARK: - Renaming

    func testRenameSelectedTargetsTheSelectedFolder() throws {
        let (split, selection, mailboxes) = makeSplit()
        let folder = try model.createMailFolder(name: "Celerity")
        selection.selectMailbox(.folder(folder.uuid))
        var began: UUID?
        mailboxes.beginEditingNameHandler = { began = $0.uuid }

        split.renameSelected(nil)
        XCTAssertEqual(began, folder.uuid)
    }

    func testRenameAndDeleteAreDisabledForRecentMail() throws {
        let (split, selection, _) = makeSplit()
        try model.createMailFolder()
        selection.selectMailbox(.recent)

        XCTAssertFalse(split.validateMenuItem(menuItem(#selector(MainSplitViewController.renameSelected(_:)))))
        XCTAssertFalse(split.validateMenuItem(menuItem(#selector(MainSplitViewController.deleteSelected(_:)))))
    }

    func testRenameAndDeleteAreEnabledForAFolder() throws {
        let (split, selection, _) = makeSplit()
        let folder = try model.createMailFolder()
        selection.selectMailbox(.folder(folder.uuid))

        XCTAssertTrue(split.validateMenuItem(menuItem(#selector(MainSplitViewController.renameSelected(_:)))))
        XCTAssertTrue(split.validateMenuItem(menuItem(#selector(MainSplitViewController.deleteSelected(_:)))))
    }

    /// The delayed click is a rename gesture, and Recent Mail has no name to
    /// edit — so it must not arm one.
    func testTheDelayedClickRenameIgnoresRecentMail() {
        let (_, _, mailboxes) = makeSplit()
        mailboxes.outlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        var began: UUID?
        mailboxes.beginEditingNameHandler = { began = $0.uuid }
        mailboxes.renameTimerFired(row: 0, generation: mailboxes.renameGeneration)
        XCTAssertNil(began)
    }

    func testAPendingRenameIsDroppedWhenTheSelectionMoves() throws {
        let (_, _, mailboxes) = makeSplit()
        let folder = try model.createMailFolder(name: "Celerity")
        let row = mailboxes.outlineView.row(forItem: folder)
        var began: UUID?
        mailboxes.beginEditingNameHandler = { began = $0.uuid }

        let generation = mailboxes.renameGeneration
        mailboxes.scheduleDelayedRename(at: row)
        mailboxes.cancelPendingRename()
        mailboxes.renameTimerFired(row: row, generation: generation)
        XCTAssertNil(began, "a cancelled rename still fired")
    }

    // MARK: - Deleting

    func testDeleteRemovesTheFolderAndSelectsTheOneBefore() throws {
        let (split, selection, _) = makeSplit()
        let first = try model.createMailFolder(name: "First")
        let second = try model.createMailFolder(name: "Second")
        selection.selectMailbox(.folder(second.uuid))

        split.deleteSelected(confirmed: true)
        XCTAssertEqual(model.mailFolders().map(\.name), ["First"])
        XCTAssertEqual(selection.selectedFolderUUID, first.uuid)
    }

    func testDeletingTheOnlyFolderFallsBackToRecentMail() throws {
        let (split, selection, _) = makeSplit()
        let folder = try model.createMailFolder()
        selection.selectMailbox(.folder(folder.uuid))

        split.deleteSelected(confirmed: true)
        XCTAssertTrue(selection.isRecentMailSelected)
    }

    func testCancellingTheConfirmationLeavesTheFolder() throws {
        let (split, selection, _) = makeSplit()
        let folder = try model.createMailFolder()
        selection.selectMailbox(.folder(folder.uuid))

        split.deleteSelected(confirmed: false)
        XCTAssertEqual(model.mailFolders().count, 1)
    }

    /// The cascade is the surprising part, so the sheet has to name it — and
    /// say what it does *not* do to Outlook.
    func testTheDeleteSheetNamesTheCascadeAndSparesOutlook() throws {
        let folder = try model.createMailFolder(name: "Celerity")
        XCTAssertEqual(
            MainSplitViewController.deleteConfirmationMessage(for: folder),
            "Delete “Celerity”?"
        )

        try model.saveMessage(
            MailMessage.fixture(id: 1),
            detail: .fixture(id: 1, messageID: "<a@x>"),
            into: folder
        )
        let message = MainSplitViewController.deleteConfirmationMessage(for: folder)
        XCTAssertTrue(message.contains("1 message"), message)
        XCTAssertTrue(message.contains("Outlook aren’t affected"), message)
    }

    // MARK: - Counts

    func testAFolderRowCountsItsMessages() throws {
        let (_, _, mailboxes) = makeSplit()
        let folder = try model.createMailFolder(name: "Celerity")
        try model.saveMessage(
            MailMessage.fixture(id: 1),
            detail: .fixture(id: 1, messageID: "<a@x>"),
            into: folder
        )
        let row = mailboxes.outlineView.row(forItem: folder)
        let cell = mailboxes.outlineView.view(atColumn: 0, row: row, makeIfNecessary: true)
        XCTAssertEqual(cell?.accessibilityLabel(), "Celerity, 1 message")
    }

    func testAnEmptyMailboxSaysNothingRatherThanZero() {
        XCTAssertEqual(MailLabels.mailboxAccessibilityLabel(name: "Recent Mail", count: 0), "Recent Mail")
        XCTAssertEqual(MailLabels.mailboxAccessibilityLabel(name: "Celerity", count: 4), "Celerity, 4 messages")
    }

    // MARK: - Context menu

    func testTheFolderContextMenuOffersRenameAndDelete() throws {
        let (_, _, mailboxes) = makeSplit()
        let folder = try model.createMailFolder()
        let row = mailboxes.outlineView.row(forItem: folder)
        let menu = mailboxes.outlineView.menu(forRow: row)
        XCTAssertEqual(
            menu.items.map(\.action),
            [
                #selector(MainSplitViewController.newMailFolder(_:)),
                #selector(MainSplitViewController.renameSelected(_:)),
                #selector(MainSplitViewController.deleteSelected(_:)),
            ]
        )
    }

    func testTheEmptyAreaAndRecentMailOfferOnlyNewFolder() {
        let (_, _, mailboxes) = makeSplit()
        for row in [-1, 0] {
            XCTAssertEqual(
                mailboxes.outlineView.menu(forRow: row).items.map(\.action),
                [#selector(MainSplitViewController.newMailFolder(_:))],
                "row \(row)"
            )
        }
    }

    // MARK: - Helpers

    private func menuItem(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "")
    }

    /// A field that is actually mid-edit, which is what suppresses commands.
    private func editingTextField() -> NSTextField {
        let field = NSTextField()
        field.isEditable = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        windows.append(window)
        return field
    }
}
