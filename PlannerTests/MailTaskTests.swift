import AppKit
import XCTest
@testable import Planner

@MainActor
final class MailTaskTests: PersistenceTestCase {
    private var defaults: UserDefaults!
    private var source: StubMailSource!
    private var split: MainSplitViewController!
    private var selection: SelectionModel!
    private var windows: [NSWindow] = []

    private var coordinator: MailCoordinator { split.mail }

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

    private func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func savedMessage(
        subject: String = "RE: Deposition prep",
        in folder: MailFolder
    ) throws -> SavedMessage {
        try model.saveMessage(
            MailMessage.fixture(id: 5, subject: subject),
            detail: .fixture(id: 5, messageID: "<five@x>"),
            into: folder
        )
    }

    // MARK: - Creating

    func testATaskFromASavedMessageIsTitledFromTheSubjectAndLinksBack() throws {
        let project = try model.createProject()
        let folder = try model.createMailFolder(name: "Celerity")
        let message = try savedMessage(in: folder)
        selection.selectMailbox(.folder(folder.uuid))
        selection.selectMessage(.saved(message.uuid))

        split.newTaskFromMessage(nil)

        let task = try XCTUnwrap(try fetchAllTasks().first)
        XCTAssertEqual(task.title, "Deposition prep", "the reply prefix survived")
        XCTAssertEqual(task.sourceMessageUUID, message.uuid)
        XCTAssertEqual(task.project?.objectID, project.objectID)
    }

    /// Switching modes is the point: the new task is the thing to look at now,
    /// and it lives in the other half of the app.
    func testCreatingATaskSwitchesToTasksModeAndSelectsIt() throws {
        try model.createProject()
        let folder = try model.createMailFolder(name: "Celerity")
        let message = try savedMessage(in: folder)
        selection.selectMessage(.saved(message.uuid))

        split.newTaskFromMessage(nil)

        let task = try XCTUnwrap(try fetchAllTasks().first)
        XCTAssertEqual(selection.mode, .tasks)
        XCTAssertEqual(selection.selectedNodeUUID, task.uuid)
    }

    func testTheNewTaskGoesUnderTheOutlineSelection() throws {
        let first = try model.createProject()
        let second = try model.createProject()
        let parentTask = try model.createTask(in: second)
        _ = first
        selection.selectNode(uuid: parentTask.uuid)

        let folder = try model.createMailFolder(name: "Celerity")
        let message = try savedMessage(in: folder)
        selection.selectMessage(.saved(message.uuid))
        split.newTaskFromMessage(nil)

        let created = try XCTUnwrap(try fetchAllTasks().first { $0.sourceMessageUUID != nil })
        XCTAssertEqual(created.parentTask?.objectID, parentTask.objectID)
    }

    /// With no projects at all there is nowhere to put it, so one is made —
    /// the same fallback chain ⌘T follows.
    func testWithNoProjectsAtAllOneIsCreated() throws {
        let folder = try model.createMailFolder(name: "Celerity")
        let message = try savedMessage(in: folder)
        selection.selectMessage(.saved(message.uuid))

        split.newTaskFromMessage(nil)

        XCTAssertEqual(try model.allProjects().count, 1)
        XCTAssertEqual(try fetchAllTasks().count, 1)
    }

    /// A task must link to a *saved* message: a link into Recent Mail would
    /// dangle within days, which is the whole reason Recent Mail is transient.
    func testATaskFromAnUnsavedMessageSavesItFirst() async throws {
        try model.createProject()
        let folder = try model.createMailFolder(name: "Celerity")
        let envelope = MailMessage.fixture(id: 9, subject: "Fwd: Expert report")

        let before = source.requestedRanges.count
        coordinator.refresh()
        await settle { self.source.requestedRanges.count > before }
        source.finishAll(with: [envelope])
        await settle { !self.coordinator.isLoading }
        selection.selectMessage(.recent(9))

        // The folder arrives the way the popped menu delivers it.
        let item = folderMenuItem(folder)
        split.newTaskFromMessage(item)
        await settle { self.source.pendingDetailCount > 0 }
        source.finishDetail(.fixture(id: 9, messageID: "<nine@x>"))
        await settle { !(try? self.fetchAllTasks())!.isEmpty }

        let saved = try XCTUnwrap(model.messages(in: folder).first)
        let task = try XCTUnwrap(try fetchAllTasks().first)
        XCTAssertEqual(task.title, "Expert report")
        XCTAssertEqual(task.sourceMessageUUID, saved.uuid)
    }

    func testAFailedSaveCreatesNoTask() async throws {
        try model.createProject()
        let folder = try model.createMailFolder(name: "Celerity")
        let envelope = MailMessage.fixture(id: 9)

        let before = source.requestedRanges.count
        coordinator.refresh()
        await settle { self.source.requestedRanges.count > before }
        source.finishAll(with: [envelope])
        await settle { !self.coordinator.isLoading }
        selection.selectMessage(.recent(9))

        split.newTaskFromMessage(folderMenuItem(folder))
        await settle { self.source.pendingDetailCount > 0 }
        source.finishDetail(id: 9, throwing: MailSourceError.messageUnavailable)
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertTrue(try fetchAllTasks().isEmpty)
        XCTAssertTrue(model.messages(in: folder).isEmpty)
    }

    // MARK: - The chip back

    func testRevealingTheSourceMessageSwitchesToMailAndOpensIt() throws {
        let project = try model.createProject()
        let folder = try model.createMailFolder(name: "Celerity")
        let message = try savedMessage(in: folder)
        let task = try model.createTask(from: message, under: project)

        selection.setMode(.tasks)
        selection.selectNode(uuid: task.uuid)
        split.revealSourceMessage(nil)

        XCTAssertEqual(selection.mode, .mail)
        XCTAssertEqual(selection.selectedFolderUUID, folder.uuid)
        XCTAssertEqual(selection.message, .saved(message.uuid))
    }

    /// The link is a UUID, not a relationship, so a removed message leaves the
    /// task standing — and the chip has to notice.
    func testADanglingLinkOffersNothingToRevealAndNoChip() throws {
        let project = try model.createProject()
        let folder = try model.createMailFolder(name: "Celerity")
        let message = try savedMessage(in: folder)
        let task = try model.createTask(from: message, under: project)
        try model.removeMessage(message)

        selection.setMode(.tasks)
        selection.selectNode(uuid: task.uuid)
        XCTAssertFalse(split.validateMenuItem(item(#selector(MainSplitViewController.revealSourceMessage(_:)))))
        XCTAssertNil(split.test_inspectorSourceChip)
    }

    func testTheInspectorShowsTheChipOnALinkedTask() throws {
        let project = try model.createProject()
        let folder = try model.createMailFolder(name: "Celerity")
        let message = try savedMessage(subject: "Deposition prep", in: folder)
        let task = try model.createTask(from: message, under: project)

        selection.setMode(.tasks)
        selection.selectNode(uuid: task.uuid)
        XCTAssertEqual(split.test_inspectorSourceChip, "From: Deposition prep")
    }

    func testAnUnlinkedTaskHasNoChip() throws {
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        selection.setMode(.tasks)
        selection.selectNode(uuid: task.uuid)
        XCTAssertNil(split.test_inspectorSourceChip)
    }

    func testAProjectHasNoChip() throws {
        let project = try model.createProject()
        selection.setMode(.tasks)
        selection.selectNode(uuid: project.uuid)
        XCTAssertNil(split.test_inspectorSourceChip)
    }

    // MARK: - Commands

    func testNewTaskFromMessageNeedsAMessage() throws {
        let folder = try model.createMailFolder(name: "Celerity")
        let message = try savedMessage(in: folder)

        selection.selectMessage(nil)
        XCTAssertFalse(split.validateMenuItem(item(#selector(MainSplitViewController.newTaskFromMessage(_:)))))

        selection.selectMessage(.saved(message.uuid))
        XCTAssertTrue(split.validateMenuItem(item(#selector(MainSplitViewController.newTaskFromMessage(_:)))))

        selection.setMode(.tasks)
        XCTAssertFalse(
            split.validateMenuItem(item(#selector(MainSplitViewController.newTaskFromMessage(_:)))),
            "a mail command stayed live in tasks mode"
        )
    }

    private func item(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "")
    }

    /// Shaped like the item the folder menu pops up: tagged, so the command can
    /// tell a chosen folder from a fresh invocation.
    private func folderMenuItem(_ folder: MailFolder) -> NSMenuItem {
        let item = NSMenuItem(title: folder.name, action: nil, keyEquivalent: "")
        item.representedObject = folder
        item.tag = MainSplitViewController.test_folderMenuItemTag
        return item
    }
}
