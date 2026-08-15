import CoreData
import XCTest
@testable import Planner

@MainActor
final class MailStoreTests: PersistenceTestCase {
    private func envelope(
        id: Int64 = 1,
        subject: String = "Deposition prep",
        receivedAt: Date? = nil
    ) -> MailMessage {
        MailMessage(
            id: id,
            subject: subject,
            senderName: "Ada Lovelace",
            senderAddress: "ada@example.com",
            receivedAt: receivedAt ?? date(year: 2026, month: 8, day: 15),
            isRead: false
        )
    }

    private func detail(id: Int64 = 1, messageID: String? = "<a@example.com>") -> MailMessageDetail {
        MailMessageDetail(
            id: id,
            body: "Body text",
            messageID: messageID,
            inReplyTo: nil,
            references: nil,
            recipients: "you@example.com",
            hasAttachments: true,
            attachmentNames: "brief.pdf\nexhibit.png"
        )
    }

    // MARK: - Folders

    func testCreateFolderAppendsSortIndex() throws {
        let first = try model.createMailFolder()
        let second = try model.createMailFolder()
        XCTAssertEqual(first.sortIndex, 0)
        XCTAssertEqual(second.sortIndex, 1)
        XCTAssertEqual(model.mailFolders().map(\.objectID), [first.objectID, second.objectID])
    }

    func testCreateFolderAssignsDistinctUUIDsAndPermanentIDs() throws {
        let first = try model.createMailFolder()
        let second = try model.createMailFolder()
        XCTAssertNotEqual(first.uuid, second.uuid)
        XCTAssertFalse(first.objectID.isTemporaryID)
    }

    func testRenameTrimsAndRejectsEmpty() throws {
        let folder = try model.createMailFolder()
        try model.renameMailFolder(folder, to: "  Celerity  ")
        XCTAssertEqual(folder.name, "Celerity")
        XCTAssertThrowsError(try model.renameMailFolder(folder, to: "   ")) { error in
            XCTAssertEqual(error as? ModelError, .emptyTitle)
        }
        XCTAssertEqual(folder.name, "Celerity")
    }

    func testDeleteFolderCascadesToItsMessages() throws {
        let folder = try model.createMailFolder()
        try model.saveMessage(envelope(), detail: detail(), into: folder)
        try model.deleteMailFolder(folder)

        let remaining = try persistence.viewContext.fetch(SavedMessage.fetchRequest())
        XCTAssertTrue(remaining.isEmpty, "deleting a folder left its messages behind")
    }

    func testDeletingOneFolderLeavesAnotherFoldersMessages() throws {
        let keep = try model.createMailFolder(name: "Keep")
        let drop = try model.createMailFolder(name: "Drop")
        try model.saveMessage(envelope(id: 1), detail: detail(id: 1, messageID: "<one@x>"), into: keep)
        try model.saveMessage(envelope(id: 2), detail: detail(id: 2, messageID: "<two@x>"), into: drop)

        try model.deleteMailFolder(drop)
        XCTAssertEqual(model.messages(in: keep).count, 1)
    }

    /// Folders sort by `(sortIndex, uuid)` like everything else, so duplicate
    /// indexes — which CloudKit makes possible — still order deterministically.
    func testFoldersTieBreakOnUUID() throws {
        let first = try model.createMailFolder(name: "A")
        let second = try model.createMailFolder(name: "B")
        second.sortIndex = first.sortIndex
        try persistence.viewContext.save()

        let expected = [first, second].sorted { ($0.sortIndex, $0.uuid) < ($1.sortIndex, $1.uuid) }
        XCTAssertEqual(model.mailFolders().map(\.uuid), expected.map(\.uuid))
    }

    // MARK: - Saving

    func testSaveCopiesEnvelopeAndDetail() throws {
        let folder = try model.createMailFolder()
        let saved = try model.saveMessage(envelope(), detail: detail(), into: folder)

        XCTAssertEqual(saved.messageID, "<a@example.com>")
        XCTAssertEqual(saved.subject, "Deposition prep")
        XCTAssertEqual(saved.senderName, "Ada Lovelace")
        XCTAssertEqual(saved.senderAddress, "ada@example.com")
        XCTAssertEqual(saved.recipients, "you@example.com")
        XCTAssertEqual(saved.body, "Body text")
        XCTAssertTrue(saved.hasAttachments)
        XCTAssertEqual(saved.attachmentNameList, ["brief.pdf", "exhibit.png"])
        XCTAssertEqual(saved.outlookID, 1)
        XCTAssertEqual(saved.folder?.objectID, folder.objectID)
    }

    func testSaveIsIdempotentWithinAFolder() throws {
        let folder = try model.createMailFolder()
        let first = try model.saveMessage(envelope(), detail: detail(), into: folder)
        let second = try model.saveMessage(envelope(), detail: detail(), into: folder)

        XCTAssertEqual(first.objectID, second.objectID)
        XCTAssertEqual(model.messages(in: folder).count, 1)
    }

    /// The same message may legitimately be filed in two folders; dedupe is
    /// scoped to the folder, not the store.
    func testTheSameMessageMayBeSavedIntoTwoFolders() throws {
        let one = try model.createMailFolder(name: "One")
        let two = try model.createMailFolder(name: "Two")
        try model.saveMessage(envelope(), detail: detail(), into: one)
        try model.saveMessage(envelope(), detail: detail(), into: two)

        XCTAssertEqual(model.messages(in: one).count, 1)
        XCTAssertEqual(model.messages(in: two).count, 1)
    }

    /// A message with no Message-ID header still has to dedupe against itself.
    func testAMissingMessageIDFallsBackToOutlooksRecordID() throws {
        let folder = try model.createMailFolder()
        let saved = try model.saveMessage(envelope(id: 77), detail: detail(id: 77, messageID: nil), into: folder)
        XCTAssertEqual(saved.messageID, "outlook-id:77")

        try model.saveMessage(envelope(id: 77), detail: detail(id: 77, messageID: nil), into: folder)
        XCTAssertEqual(model.messages(in: folder).count, 1)
    }

    func testSavingWithNoDetailStillStoresTheEnvelope() throws {
        let folder = try model.createMailFolder()
        let saved = try model.saveMessage(envelope(id: 5), detail: nil, into: folder)
        XCTAssertEqual(saved.messageID, "outlook-id:5")
        XCTAssertNil(saved.body)
        XCTAssertFalse(saved.hasAttachments)
    }

    func testMessagesInFolderAreNewestFirst() throws {
        let folder = try model.createMailFolder()
        let older = envelope(id: 1, subject: "Older", receivedAt: date(year: 2026, month: 8, day: 10))
        let newer = envelope(id: 2, subject: "Newer", receivedAt: date(year: 2026, month: 8, day: 14))
        try model.saveMessage(older, detail: detail(id: 1, messageID: "<one@x>"), into: folder)
        try model.saveMessage(newer, detail: detail(id: 2, messageID: "<two@x>"), into: folder)

        XCTAssertEqual(model.messages(in: folder).map(\.subject), ["Newer", "Older"])
    }

    // MARK: - Moving and removing

    func testMoveReassignsTheFolder() throws {
        let source = try model.createMailFolder(name: "Source")
        let destination = try model.createMailFolder(name: "Destination")
        let saved = try model.saveMessage(envelope(), detail: detail(), into: source)

        try model.moveMessage(saved, to: destination)
        XCTAssertEqual(saved.folder?.objectID, destination.objectID)
        XCTAssertTrue(model.messages(in: source).isEmpty)
        XCTAssertEqual(model.messages(in: destination).count, 1)
    }

    /// Moving onto a folder that already holds the message collapses rather
    /// than duplicating — the same rule saving follows.
    func testMoveIntoAFolderThatAlreadyHasItCollapses() throws {
        let source = try model.createMailFolder(name: "Source")
        let destination = try model.createMailFolder(name: "Destination")
        let moved = try model.saveMessage(envelope(), detail: detail(), into: source)
        try model.saveMessage(envelope(), detail: detail(), into: destination)

        try model.moveMessage(moved, to: destination)
        XCTAssertEqual(model.messages(in: destination).count, 1)
        XCTAssertTrue(model.messages(in: source).isEmpty)
    }

    func testMoveToTheSameFolderIsANoOp() throws {
        let folder = try model.createMailFolder()
        let saved = try model.saveMessage(envelope(), detail: detail(), into: folder)
        try model.moveMessage(saved, to: folder)
        XCTAssertEqual(model.messages(in: folder).count, 1)
    }

    func testRemoveDeletesOnlyThatCopy() throws {
        let one = try model.createMailFolder(name: "One")
        let two = try model.createMailFolder(name: "Two")
        let first = try model.saveMessage(envelope(), detail: detail(), into: one)
        try model.saveMessage(envelope(), detail: detail(), into: two)

        try model.removeMessage(first)
        XCTAssertTrue(model.messages(in: one).isEmpty)
        XCTAssertEqual(model.messages(in: two).count, 1)
    }

    // MARK: - Lookups

    /// Keyed on Outlook's record id, not the Message-ID: Recent Mail fetches
    /// headers lazily, so an envelope does not know its own Message-ID and
    /// could never match a saved copy by one.
    func testFoldersByOutlookIDIndexesTheWholeStoreInOneFetch() throws {
        let first = try model.createMailFolder(name: "First")
        let second = try model.createMailFolder(name: "Second")
        try model.saveMessage(envelope(id: 1), detail: detail(id: 1, messageID: "<one@x>"), into: first)
        try model.saveMessage(envelope(id: 2), detail: detail(id: 2, messageID: "<two@x>"), into: second)

        let index = model.foldersByOutlookID()
        XCTAssertEqual(index[1]?.objectID, first.objectID)
        XCTAssertEqual(index[2]?.objectID, second.objectID)
        XCTAssertNil(index[3])
    }

    func testSavedMessageLookupByUUID() throws {
        let folder = try model.createMailFolder()
        let saved = try model.saveMessage(envelope(), detail: detail(), into: folder)
        XCTAssertEqual(model.savedMessage(uuid: saved.uuid)?.objectID, saved.objectID)
        XCTAssertNil(model.savedMessage(uuid: UUID()))
    }

    // MARK: - Tasks from messages

    func testCreateTaskFromMessageTitlesFromTheSubjectAndLinksBack() throws {
        let project = try model.createProject()
        let folder = try model.createMailFolder()
        let saved = try model.saveMessage(
            envelope(subject: "RE: Deposition prep"),
            detail: detail(),
            into: folder
        )

        let task = try model.createTask(from: saved, under: project)
        XCTAssertEqual(task.title, "Deposition prep")
        XCTAssertEqual(task.sourceMessageUUID, saved.uuid)
        XCTAssertEqual(task.project?.objectID, project.objectID)
        XCTAssertEqual(model.sourceMessage(of: task)?.objectID, saved.objectID)
    }

    func testATaskFromAnEmptySubjectKeepsTheDefaultTitle() throws {
        let project = try model.createProject()
        let folder = try model.createMailFolder()
        let saved = try model.saveMessage(envelope(subject: "Re:"), detail: detail(), into: folder)
        let task = try model.createTask(from: saved, under: project)
        XCTAssertEqual(task.title, "Untitled Task")
    }

    /// The link is a UUID, not a relationship, precisely so this holds.
    func testRemovingAMessageLeavesTheTaskWithADanglingLink() throws {
        let project = try model.createProject()
        let folder = try model.createMailFolder()
        let saved = try model.saveMessage(envelope(), detail: detail(), into: folder)
        let task = try model.createTask(from: saved, under: project)

        try model.removeMessage(saved)
        XCTAssertFalse(task.isDeleted)
        XCTAssertNotNil(task.sourceMessageUUID)
        XCTAssertNil(model.sourceMessage(of: task), "a removed message still resolved")
    }

    func testAnUnlinkedTaskHasNoSourceMessage() throws {
        let project = try model.createProject()
        let task = try model.createTask(in: project)
        XCTAssertNil(task.sourceMessageUUID)
        XCTAssertNil(model.sourceMessage(of: task))
    }

    // MARK: - Undo

    func testUndoActionNames() throws {
        let undo = try XCTUnwrap(persistence.viewContext.undoManager)

        let folder = try model.createMailFolder()
        XCTAssertEqual(undo.undoActionName, "New Folder")
        try model.renameMailFolder(folder, to: "Celerity")
        XCTAssertEqual(undo.undoActionName, "Rename Folder")

        let saved = try model.saveMessage(envelope(), detail: detail(), into: folder)
        XCTAssertEqual(undo.undoActionName, "Save Message")

        let other = try model.createMailFolder(name: "Other")
        try model.moveMessage(saved, to: other)
        XCTAssertEqual(undo.undoActionName, "Move Message")

        try model.removeMessage(saved)
        XCTAssertEqual(undo.undoActionName, "Remove Message")

        try model.deleteMailFolder(other)
        XCTAssertEqual(undo.undoActionName, "Delete Folder")
    }

    // MARK: - Failure

    func testSaveFailureRollsBackAndThrows() throws {
        let folder = try model.createMailFolder()
        persistence.failNextSave = true
        XCTAssertThrowsError(try model.saveMessage(envelope(), detail: detail(), into: folder)) { error in
            XCTAssertEqual(error as? ModelError, .saveFailed)
        }
        XCTAssertTrue(model.messages(in: folder).isEmpty)
    }

    // MARK: - CloudKit rules

    /// DESIGN.md §3: no uniqueness constraints anywhere in the model, because
    /// CloudKit rejects them. `messageID` is indexed and deduped in code.
    func testNoEntityDeclaresAUniquenessConstraint() throws {
        let entities = persistence.container.managedObjectModel.entities
        for entity in entities {
            XCTAssertTrue(
                entity.uniquenessConstraints.isEmpty,
                "\(entity.name ?? "?") declares a uniqueness constraint"
            )
        }
    }

    func testMailRelationshipsAreOptionalAndUnordered() throws {
        let model = persistence.container.managedObjectModel
        let savedMessage = try XCTUnwrap(model.entitiesByName["SavedMessage"])
        let folder = try XCTUnwrap(savedMessage.relationshipsByName["folder"])
        XCTAssertTrue(folder.isOptional, "CloudKit requires optional relationships")
        XCTAssertEqual(folder.deleteRule, .nullifyDeleteRule)

        let mailFolder = try XCTUnwrap(model.entitiesByName["MailFolder"])
        let messages = try XCTUnwrap(mailFolder.relationshipsByName["messages"])
        XCTAssertFalse(messages.isOrdered, "CloudKit requires unordered relationships")
        XCTAssertEqual(messages.deleteRule, .cascadeDeleteRule)
    }

    func testSavedMessageIsIndexedOnMessageIDAndReceivedAt() throws {
        let entity = try XCTUnwrap(
            persistence.container.managedObjectModel.entitiesByName["SavedMessage"]
        )
        let indexed = Set(entity.indexes.flatMap { $0.elements.compactMap { $0.propertyName } })
        XCTAssertTrue(indexed.contains("messageID"))
        XCTAssertTrue(indexed.contains("receivedAt"))
    }

    /// Every save goes through `ModelController`, which always sets a folder.
    func testEveryStoredMessageHasAFolder() throws {
        let folder = try model.createMailFolder()
        try model.saveMessage(envelope(), detail: detail(), into: folder)
        let all = try persistence.viewContext.fetch(SavedMessage.fetchRequest())
        XCTAssertFalse(all.isEmpty)
        XCTAssertTrue(all.allSatisfy { $0.folder != nil })
    }

    // MARK: - Migration

    /// A store written by the shipped v1 model must open under v2 with its
    /// contents intact. Additive-only changes make this inferrable, but
    /// "inferrable" is a claim worth testing rather than assuming.
    func testAV1StoreMigratesLightweightAndKeepsItsRows() throws {
        let bundle = Bundle(for: DayNote.self)
        let momd = try XCTUnwrap(bundle.url(forResource: "Planner", withExtension: "momd"))
        let v1 = try XCTUnwrap(NSManagedObjectModel(contentsOf: momd.appendingPathComponent("Planner.mom")))

        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MigrationTest-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(
                    at: storeURL.deletingPathExtension()
                        .appendingPathExtension("sqlite\(suffix)")
                )
            }
        }

        let projectUUID = UUID()
        try writeV1Store(at: storeURL, model: v1, projectUUID: projectUUID)

        // Reopen with the current model, exactly as the app does.
        let migrated = NSPersistentContainer(name: "Planner")
        let description = NSPersistentStoreDescription(url: storeURL)
        description.shouldAddStoreAsynchronously = false
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        migrated.persistentStoreDescriptions = [description]

        var loadError: Error?
        migrated.loadPersistentStores { _, error in loadError = error }
        XCTAssertNil(loadError, "the v1 store did not migrate")

        let request = Project.fetchRequest()
        request.predicate = NSPredicate(format: "uuid == %@", projectUUID as CVarArg)
        let projects = try migrated.viewContext.fetch(request)
        XCTAssertEqual(projects.count, 1, "the migrated store lost its project")
        XCTAssertEqual(projects.first?.title, "Carried over")

        let tasks = try migrated.viewContext.fetch(TaskItem.fetchRequest())
        XCTAssertEqual(tasks.count, 1)
        XCTAssertNil(tasks.first?.sourceMessageUUID, "a new optional attribute arrived non-nil")

        // The new entities exist and are usable in the migrated store.
        XCTAssertNotNil(migrated.managedObjectModel.entitiesByName["MailFolder"])
        XCTAssertNotNil(migrated.managedObjectModel.entitiesByName["SavedMessage"])
        XCTAssertTrue(try migrated.viewContext.fetch(MailFolder.fetchRequest()).isEmpty)

        for store in migrated.persistentStoreCoordinator.persistentStores {
            try migrated.persistentStoreCoordinator.remove(store)
        }
    }

    private func writeV1Store(at url: URL, model: NSManagedObjectModel, projectUUID: UUID) throws {
        let container = NSPersistentContainer(name: "Planner", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: url)
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }

        let context = container.viewContext
        let now = Date()
        let project = NSEntityDescription.insertNewObject(forEntityName: "Project", into: context)
        project.setValue(projectUUID, forKey: "uuid")
        project.setValue("Carried over", forKey: "title")
        project.setValue(Int64(0), forKey: "sortIndex")
        project.setValue(now, forKey: "createdAt")
        project.setValue(now, forKey: "updatedAt")

        let task = NSEntityDescription.insertNewObject(forEntityName: "Task", into: context)
        task.setValue(UUID(), forKey: "uuid")
        task.setValue("Old task", forKey: "title")
        task.setValue(false, forKey: "isCompleted")
        task.setValue(Int64(0), forKey: "sortIndex")
        task.setValue(now, forKey: "createdAt")
        task.setValue(now, forKey: "updatedAt")
        task.setValue(project, forKey: "project")

        try context.save()
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
    }
}
