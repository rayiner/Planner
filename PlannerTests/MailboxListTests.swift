import AppKit
import XCTest
@testable import Planner

/// The Mail section of the unified sidebar: Recent Mail, then the folders —
/// and the mode switching that selecting either performs.
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

    private func makeSplit(mode: PlannerMode = .mail) -> (MainSplitViewController, SelectionModel, OutlineViewController) {
        let selection = SelectionModel(defaults: defaults)
        selection.setMode(mode)
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
        let outline = split.outlineViewController
        outline.loadViewIfNeeded()
        return (split, selection, outline)
    }

    private func mailItems(_ outline: OutlineViewController) -> [Any] {
        let view = outline.outlineView
        return (0..<view.numberOfChildren(ofItem: SidebarSection.mail)).compactMap {
            view.child($0, ofItem: SidebarSection.mail)
        }
    }

    private func mailNames(_ outline: OutlineViewController) -> [String] {
        mailItems(outline).map {
            ($0 as? MailFolder)?.name ?? MailLabels.recentMailName
        }
    }

    private func selectRow(for item: Any, in outline: OutlineViewController) {
        let row = outline.outlineView.row(forItem: item)
        XCTAssertGreaterThanOrEqual(row, 0, "\(item) has no row")
        outline.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    // MARK: - Contents

    func testTheMailSectionLeadsWithRecentMail() {
        let (_, _, outline) = makeSplit()
        XCTAssertEqual(mailNames(outline), [MailLabels.recentMailName])
        XCTAssertTrue(mailItems(outline).first is RecentMailbox)
        XCTAssertGreaterThanOrEqual(outline.outlineView.row(forItem: RecentMailbox.shared), 0)
    }

    func testFoldersFollowRecentMailInListOrder() throws {
        let (_, _, outline) = makeSplit()
        try model.createMailFolder(name: "Celerity")
        try model.createMailFolder(name: "Paltalk")
        XCTAssertEqual(mailNames(outline), [MailLabels.recentMailName, "Celerity", "Paltalk"])
    }

    /// The sidebar reacts to did-save, so a folder created anywhere shows up.
    func testANewFolderAppearsWithoutAnExplicitReload() throws {
        let (_, _, outline) = makeSplit()
        try model.createMailFolder(name: "New")
        XCTAssertEqual(mailNames(outline).count, 2)
    }

    func testDeletingAFolderRemovesItsRow() throws {
        let (_, _, outline) = makeSplit()
        let folder = try model.createMailFolder(name: "Doomed")
        try model.deleteMailFolder(folder)
        XCTAssertEqual(mailNames(outline), [MailLabels.recentMailName])
    }

    /// Both sections coexist: creating projects must not disturb the mail rows,
    /// and vice versa.
    func testProjectsAndMailboxesShareTheSidebar() throws {
        let (_, _, outline) = makeSplit()
        let project = try model.createProject()
        let folder = try model.createMailFolder(name: "Celerity")
        XCTAssertGreaterThanOrEqual(outline.outlineView.row(forItem: project), 0)
        XCTAssertGreaterThanOrEqual(outline.outlineView.row(forItem: folder), 0)
        XCTAssertLessThan(
            outline.outlineView.row(forItem: project),
            outline.outlineView.row(forItem: RecentMailbox.shared),
            "Projects come before Mail"
        )
    }

    // MARK: - Selection and mode switching

    func testSelectingAFolderRowPublishesTheMailboxSelection() throws {
        let (_, selection, outline) = makeSplit()
        let folder = try model.createMailFolder(name: "Celerity")
        selectRow(for: folder, in: outline)
        XCTAssertEqual(selection.selectedFolderUUID, folder.uuid)
    }

    func testSelectingRecentMailPublishesRecent() throws {
        let (_, selection, outline) = makeSplit()
        let folder = try model.createMailFolder()
        selection.selectMailbox(.folder(folder.uuid))

        selectRow(for: RecentMailbox.shared, in: outline)
        XCTAssertTrue(selection.isRecentMailSelected)
    }

    /// The point of the unified sidebar: a mailbox row switches the trailing
    /// panes to mail, a project row switches them back to tasks.
    func testSelectingAMailboxFromTasksModeSwitchesToMail() throws {
        let (split, selection, outline) = makeSplit(mode: .tasks)
        let folder = try model.createMailFolder(name: "Celerity")

        selectRow(for: folder, in: outline)

        XCTAssertEqual(selection.mode, .mail)
        XCTAssertEqual(selection.selectedFolderUUID, folder.uuid)
        XCTAssertTrue(split.splitViewItems[1].viewController is MailListViewController)
    }

    func testSelectingAProjectFromMailModeSwitchesToTasks() throws {
        let (split, selection, outline) = makeSplit(mode: .mail)
        let project = try model.createProject()

        selectRow(for: project, in: outline)

        XCTAssertEqual(selection.mode, .tasks)
        XCTAssertEqual(selection.selectedNodeUUID, project.uuid)
        XCTAssertTrue(split.splitViewItems[1].viewController is CalendarViewController)
    }

    func testAModelSelectionRevealsTheRow() throws {
        let (_, selection, outline) = makeSplit()
        let folder = try model.createMailFolder(name: "Celerity")
        selection.selectMailbox(.folder(folder.uuid))
        XCTAssertEqual(
            outline.outlineView.item(atRow: outline.outlineView.selectedRow) as? MailFolder,
            folder
        )
    }

    /// Each mode keeps its own selection, and the one highlight follows the
    /// mode: switching re-reveals whichever row the new mode is showing.
    func testTheHighlightFollowsTheModeAcrossSwitches() throws {
        let (_, selection, outline) = makeSplit(mode: .tasks)
        let project = try model.createProject()
        let folder = try model.createMailFolder(name: "Celerity")
        selection.selectNode(uuid: project.uuid)
        selection.selectMailbox(.folder(folder.uuid))

        selection.setMode(.mail)
        XCTAssertEqual(
            outline.outlineView.selectedRow,
            outline.outlineView.row(forItem: folder)
        )

        selection.setMode(.tasks)
        XCTAssertEqual(
            outline.outlineView.selectedRow,
            outline.outlineView.row(forItem: project)
        )
    }

    // MARK: - Creating

    func testNewFolderSelectsItAndStartsRenaming() async throws {
        let (split, selection, outline) = makeSplit()
        var began: UUID?
        outline.beginEditingNameHandler = { began = $0.uuid }

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
        let (split, selection, outline) = makeSplit()
        let folder = try model.createMailFolder(name: "Celerity")
        selection.selectMailbox(.folder(folder.uuid))
        var began: UUID?
        outline.beginEditingNameHandler = { began = $0.uuid }

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
        let (_, _, outline) = makeSplit()
        selectRow(for: RecentMailbox.shared, in: outline)
        var began: UUID?
        outline.beginEditingNameHandler = { began = $0.uuid }
        let row = outline.outlineView.row(forItem: RecentMailbox.shared)
        outline.renameTimerFired(row: row, generation: outline.renameGeneration)
        XCTAssertNil(began)
    }

    func testAPendingRenameIsDroppedWhenTheSelectionMoves() throws {
        let (_, _, outline) = makeSplit()
        let folder = try model.createMailFolder(name: "Celerity")
        let row = outline.outlineView.row(forItem: folder)
        var began: UUID?
        outline.beginEditingNameHandler = { began = $0.uuid }

        let generation = outline.renameGeneration
        outline.scheduleDelayedRename(at: row)
        outline.cancelPendingRename()
        outline.renameTimerFired(row: row, generation: generation)
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
        let (_, _, outline) = makeSplit()
        let folder = try model.createMailFolder(name: "Celerity")
        try model.saveMessage(
            MailMessage.fixture(id: 1),
            detail: .fixture(id: 1, messageID: "<a@x>"),
            into: folder
        )
        let row = outline.outlineView.row(forItem: folder)
        let cell = outline.outlineView.view(atColumn: 0, row: row, makeIfNecessary: true)
        XCTAssertEqual(cell?.accessibilityLabel(), "Celerity, 1 message")
    }

    func testAnEmptyMailboxSaysNothingRatherThanZero() {
        XCTAssertEqual(MailLabels.mailboxAccessibilityLabel(name: "Recent Mail", count: 0), "Recent Mail")
        XCTAssertEqual(MailLabels.mailboxAccessibilityLabel(name: "Celerity", count: 4), "Celerity, 4 messages")
    }

    // MARK: - Context menu

    func testTheFolderContextMenuOffersRenameAndDelete() throws {
        let (_, _, outline) = makeSplit()
        let folder = try model.createMailFolder()
        let row = outline.outlineView.row(forItem: folder)
        let menu = outline.outlineView.menu(forRow: row)
        XCTAssertEqual(
            menu.items.map(\.action),
            [
                #selector(MainSplitViewController.newMailFolder(_:)),
                #selector(MainSplitViewController.renameSelected(_:)),
                #selector(MainSplitViewController.deleteSelected(_:)),
            ]
        )
    }

    func testRecentMailOffersOnlyNewFolder() {
        let (_, _, outline) = makeSplit()
        let row = outline.outlineView.row(forItem: RecentMailbox.shared)
        XCTAssertEqual(
            outline.outlineView.menu(forRow: row).items.map(\.action),
            [#selector(MainSplitViewController.newMailFolder(_:))]
        )
    }

    /// The empty area serves both sections, so it offers both creations.
    func testTheEmptyAreaOffersNewProjectAndNewFolder() {
        let (_, _, outline) = makeSplit()
        XCTAssertEqual(
            outline.outlineView.menu(forRow: -1).items.map(\.action),
            [
                #selector(MainSplitViewController.newProject(_:)),
                #selector(MainSplitViewController.newMailFolder(_:)),
            ]
        )
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
