import CoreData
import XCTest
@testable import Planner

/// Carries a drain outcome back from Core Data's queue to the test's.
///
/// A plain `var` captured by the completion would be a cross-actor mutation;
/// the wait below is what actually orders the write against the read.
private final class OutcomeBox: @unchecked Sendable {
    var value: PersistentHistoryDrain.Outcome?
}

@MainActor
final class StoreRepairTests: PersistenceTestCase {
    private var context: NSManagedObjectContext { persistence.viewContext }

    // MARK: - Fixtures

    /// Inserts a row the way a CloudKit import does — straight into the store,
    /// with whatever fields the record happened to carry — rather than through
    /// `ModelController`, which by construction cannot produce these states.
    @discardableResult
    private func insert(_ entityName: String, _ values: [String: Any?]) -> NSManagedObject {
        let object = NSEntityDescription.insertNewObject(forEntityName: entityName, into: context)
        for (key, value) in values {
            object.setValue(value, forKey: key)
        }
        return object
    }

    private func wellFormedProject(title: String = "Kept") -> NSManagedObject {
        insert("Project", [
            "uuid": UUID(), "title": title, "sortIndex": Int64(0),
            "createdAt": Date(), "updatedAt": Date(),
        ])
    }

    @discardableResult
    private func repair(now: Date = Date()) throws -> StoreRepair.Summary {
        try StoreRepair.run(in: context, now: now, calendar: testCalendar)
    }

    private func fetch(_ entityName: String, where format: String? = nil) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        if let format { request.predicate = NSPredicate(format: format) }
        return try context.fetch(request)
    }

    // MARK: - Identity and timestamps

    func testAnImportedRowWithNoIdentityGetsOne() throws {
        insert("Project", ["title": "No id", "sortIndex": Int64(0), "createdAt": Date(), "updatedAt": Date()])

        let summary = try repair()

        XCTAssertEqual(summary.identitiesFilled, 1)
        let project = try XCTUnwrap(fetch("Project").first)
        XCTAssertNotNil(project.value(forKey: "uuid"))
    }

    func testAnImportedRowWithNoTimestampsGetsThem() throws {
        insert("Project", ["uuid": UUID(), "title": "No dates", "sortIndex": Int64(0)])

        let summary = try repair()

        XCTAssertEqual(summary.timestampsFilled, 1)
        let project = try XCTUnwrap(fetch("Project").first)
        XCTAssertNotNil(project.value(forKey: "createdAt"))
        XCTAssertNotNil(project.value(forKey: "updatedAt"))
    }

    /// A day note with no day belongs to no date and can never be read back, so
    /// it is anchored to the day it was created.
    func testADayNoteWithNoDayIsAnchoredToItsCreationDay() throws {
        let created = date(year: 2026, month: 3, day: 14, hour: 22, minute: 5)
        insert("DayNote", ["uuid": UUID(), "note": "Stranded", "createdAt": created, "updatedAt": created])

        try repair()

        let note = try XCTUnwrap(fetch("DayNote").first)
        XCTAssertEqual(note.value(forKey: "day") as? Date, testCalendar.startOfDay(for: created))
    }

    func testASavedMessageWithNoReceivedDateFallsBackToWhenItArrived() throws {
        let created = date(year: 2026, month: 4, day: 2)
        insert("SavedMessage", [
            "uuid": UUID(), "messageID": "<a@b>", "subject": "No date",
            "senderName": "A", "senderAddress": "a@b", "hasAttachments": false,
            "outlookID": Int64(0), "createdAt": created, "updatedAt": created,
        ])

        try repair()

        let message = try XCTUnwrap(fetch("SavedMessage").first)
        XCTAssertEqual(message.value(forKey: "receivedAt") as? Date, created)
    }

    func testAnEmptyTitleIsFilledRatherThanLeftBlank() throws {
        insert("Project", ["uuid": UUID(), "title": "", "sortIndex": Int64(0), "createdAt": Date(), "updatedAt": Date()])

        let summary = try repair()

        XCTAssertEqual(summary.titlesFilled, 1)
        XCTAssertEqual(try fetch("Project").first?.value(forKey: "title") as? String, "Untitled Project")
    }

    // MARK: - Parentage

    /// DESIGN.md §3's xor, arriving broken. `parentTask` is the more specific
    /// claim, and the project stays reachable through it.
    func testATaskWithBothParentsKeepsTheTaskParent() throws {
        let project = try model.createProject()
        let parent = try model.createTask(in: project)
        let child = try model.createSubtask(under: parent)
        child.project = project

        let summary = try repair()

        XCTAssertEqual(summary.dualParentsResolved, 1)
        XCTAssertNil(child.project)
        XCTAssertEqual(child.parentTask, parent)
    }

    func testATaskWithNoParentIsAdoptedRatherThanDeleted() throws {
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        task.title = "Survivor"
        task.project = nil

        let summary = try repair()

        XCTAssertEqual(summary.orphansAdopted, 1)
        XCTAssertEqual(task.project?.title, StoreRepair.recoveryProjectTitle)
        XCTAssertEqual(task.title, "Survivor", "the text the user typed must survive")
    }

    func testEveryOrphanLandsInTheSameRecoveryProject() throws {
        let project = try model.createProject()
        let first = try model.createTask(in: project)
        let second = try model.createTask(in: project)
        first.project = nil
        second.project = nil

        try repair()

        let recoveries = try context.fetch(Project.fetchRequest()).filter {
            $0.title == StoreRepair.recoveryProjectTitle
        }
        XCTAssertEqual(recoveries.count, 1)
        XCTAssertEqual(first.project, second.project)
        XCTAssertNotEqual(first.sortIndex, second.sortIndex, "recovered siblings must not stack on one index")
    }

    /// Two devices reparenting the same pair into each other. Neither write is
    /// invalid alone; the merge is, and an uncut cycle hangs every outline walk.
    func testATwoTaskCycleIsCutAndBothTasksStayReachable() throws {
        let project = try model.createProject()
        let first = try model.createTask(in: project)
        let second = try model.createTask(in: project)
        first.project = nil
        second.project = nil
        first.parentTask = second
        second.parentTask = first

        let summary = try repair()

        XCTAssertEqual(summary.cyclesBroken, 1)
        // Which of the two edges gets cut depends on fetch order and does not
        // matter. What matters is that walking up from either task terminates.
        for task in [first, second] {
            var steps = 0
            var node: TaskItem? = task
            while let current = node, steps < 10 {
                node = current.parentTask
                steps += 1
            }
            XCTAssertLessThan(steps, 10, "the parent chain still loops")
        }
        XCTAssertEqual(try fetch("Task").count, 2, "cutting a cycle must not delete a task")
    }

    func testASelfParentedTaskIsDetachedAndAdopted() throws {
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        task.project = nil
        task.parentTask = task

        let summary = try repair()

        XCTAssertEqual(summary.cyclesBroken, 1)
        XCTAssertNil(task.parentTask)
        XCTAssertEqual(task.project?.title, StoreRepair.recoveryProjectTitle)
    }

    // MARK: - Mail

    func testAMessageWithNoFolderIsRefiledRatherThanLeftInvisible() throws {
        insert("SavedMessage", [
            "uuid": UUID(), "messageID": "<loose@example.com>", "subject": "Loose",
            "senderName": "A", "senderAddress": "a@example.com", "hasAttachments": false,
            "outlookID": Int64(0), "receivedAt": Date(), "createdAt": Date(), "updatedAt": Date(),
        ])

        let summary = try repair()

        XCTAssertEqual(summary.messagesRefiled, 1)
        let message = try XCTUnwrap(context.fetch(SavedMessage.fetchRequest()).first)
        XCTAssertEqual(message.folder?.name, StoreRepair.recoveryFolderName)
    }

    // MARK: - Restraint

    func testAHealthyStoreIsLeftAlone() throws {
        let project = try model.createProject()
        let parent = try model.createTask(in: project)
        _ = try model.createSubtask(under: parent)
        _ = try model.createMailFolder(name: "Keep")
        try model.setDayNote("Note", on: date(year: 2026, month: 5, day: 1), calendar: testCalendar)

        let summary = try repair()

        XCTAssertTrue(summary.isEmpty, "repair touched a store with nothing wrong: \(summary)")
        XCTAssertEqual(try fetch("Project").count, 1, "no recovery project should have been made")
    }

    func testRepairIsIdempotent() throws {
        wellFormedProject()
        insert("Project", ["title": "Broken", "sortIndex": Int64(0)])
        insert("SavedMessage", [
            "uuid": UUID(), "messageID": "<x@y>", "subject": "Loose",
            "senderName": "A", "senderAddress": "a@b", "hasAttachments": false, "outlookID": Int64(0),
        ])

        let first = try repair()
        XCTAssertFalse(first.isEmpty)

        let second = try repair()
        XCTAssertTrue(second.isEmpty, "a second pass changed something: \(second)")
    }
}

// MARK: - History drain

@MainActor
final class PersistentHistoryDrainTests: PersistenceTestCase {
    private func makeDrain() -> PersistentHistoryDrain {
        PersistentHistoryDrain(
            container: persistence.container,
            skippedAuthors: [PersistenceController.userTransactionAuthor, StoreRepair.transactionAuthor]
        )
    }

    private func drain(_ drain: PersistentHistoryDrain, force: Bool = false) -> PersistentHistoryDrain.Outcome {
        let box = OutcomeBox()
        let finished = expectation(description: "drain finished")
        drain.drain(after: nil, force: force) { outcome in
            box.value = outcome
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
        return box.value ?? PersistentHistoryDrain.Outcome()
    }

    /// Without this the drain would repair its own repairs forever, and every
    /// keystroke saved in this window would look like news from another Mac.
    func testOurOwnWritesAreNotTreatedAsRemoteChanges() throws {
        _ = try model.createProject()

        let outcome = drain(makeDrain())

        XCTAssertNil(outcome.failure)
        XCTAssertEqual(outcome.transactionCount, 0)
        XCTAssertTrue(outcome.repair.isEmpty)
    }

    /// The whole mechanism end to end: a write by another author lands in
    /// history, the drain notices it, and the repair pass fixes what arrived.
    func testAWriteByAnotherAuthorIsDrainedAndRepaired() throws {
        let background = persistence.container.newBackgroundContext()
        background.transactionAuthor = "test.import"
        background.performAndWait {
            let project = NSEntityDescription.insertNewObject(forEntityName: "Project", into: background)
            // No uuid: exactly the shape of a record whose field was absent.
            project.setValue("Arrived from elsewhere", forKey: "title")
            project.setValue(Date(), forKey: "createdAt")
            project.setValue(Date(), forKey: "updatedAt")
            try? background.save()
        }

        let outcome = drain(makeDrain())

        XCTAssertNil(outcome.failure)
        XCTAssertGreaterThan(outcome.transactionCount, 0)
        XCTAssertEqual(outcome.repair.identitiesFilled, 1)
        XCTAssertNotNil(outcome.tokenData, "a drained range must advance the token")
    }

    func testAHistoryTokenSurvivesBeingStoredAndReadBack() throws {
        _ = try model.createProject()
        let coordinator = persistence.container.persistentStoreCoordinator
        let token = try XCTUnwrap(coordinator.currentPersistentHistoryToken(fromStores: nil))

        let data = try XCTUnwrap(PersistentHistoryDrain.encodeToken(token))
        XCTAssertEqual(PersistentHistoryDrain.decodeToken(data), token)
    }

    /// A store rebuilt underneath a stale token must replay history, not crash
    /// and not silently drop the range.
    func testUnreadableTokenDataReadsAsNoToken() {
        XCTAssertNil(PersistentHistoryDrain.decodeToken(Data([0x00, 0x01, 0x02])))
        XCTAssertNil(PersistentHistoryDrain.decodeToken(nil))
    }
}
