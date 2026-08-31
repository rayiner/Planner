import CoreData
import XCTest
@testable import Planner

/// The model rules `NSPersistentCloudKitContainer` enforces at store load.
///
/// Every one of these fails loudly at runtime rather than at build time, on the
/// user's Mac rather than here, and only once sync is switched on — which is
/// exactly the shape of bug worth a test. `MailStoreTests` already covers
/// uniqueness constraints and the mail relationships; these are the rest.
@MainActor
final class CloudKitModelRuleTests: PersistenceTestCase {
    private var managedObjectModel: NSManagedObjectModel {
        persistence.container.managedObjectModel
    }

    /// The rule that forced the `Planner 3` model version. CloudKit records
    /// arrive with fields absent, so an attribute the store insists on cannot be
    /// filled from a mirrored record.
    func testEveryAttributeIsOptionalOrHasADefaultValue() {
        for entity in managedObjectModel.entities {
            for (name, attribute) in entity.attributesByName {
                XCTAssertTrue(
                    attribute.isOptional || attribute.defaultValue != nil,
                    "\(entity.name ?? "?").\(name) is neither optional nor defaulted"
                )
            }
        }
    }

    func testEveryRelationshipIsOptionalAndHasAnInverse() {
        for entity in managedObjectModel.entities {
            for (name, relationship) in entity.relationshipsByName {
                XCTAssertTrue(
                    relationship.isOptional,
                    "\(entity.name ?? "?").\(name) is a required relationship"
                )
                XCTAssertNotNil(
                    relationship.inverseRelationship,
                    "\(entity.name ?? "?").\(name) has no inverse"
                )
                XCTAssertFalse(
                    relationship.isOrdered,
                    "\(entity.name ?? "?").\(name) is ordered"
                )
            }
        }
    }

    /// Deny would abort a mirrored delete with no way for the user to act on it.
    func testNoRelationshipUsesTheDenyDeleteRule() {
        for entity in managedObjectModel.entities {
            for (name, relationship) in entity.relationshipsByName {
                XCTAssertNotEqual(
                    relationship.deleteRule,
                    .denyDeleteRule,
                    "\(entity.name ?? "?").\(name) denies deletes"
                )
            }
        }
    }

    func testNoEntityUsesInheritance() {
        for entity in managedObjectModel.entities {
            XCTAssertNil(entity.superentity, "\(entity.name ?? "?") has a superentity")
            XCTAssertFalse(entity.isAbstract, "\(entity.name ?? "?") is abstract")
        }
    }

    /// `uuid` is the lookup key behind every chip reveal, inspector rebind and
    /// expansion restore, and repair fetches on it too. A non-unique fetch index
    /// is CloudKit-safe; only *uniqueness constraints* are forbidden.
    func testEveryEntityIsIndexedOnUUID() {
        for entity in managedObjectModel.entities {
            let indexed = Set(entity.indexes.flatMap { $0.elements.compactMap(\.propertyName) })
            XCTAssertTrue(indexed.contains("uuid"), "\(entity.name ?? "?") has no uuid index")
        }
    }
}

// MARK: - Settings

final class CloudSyncSettingsTests: XCTestCase {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "CloudSyncSettingsTests.\(UUID().uuidString)")!
    }

    /// Updating the app must not start uploading a library on its own.
    func testSyncIsOffWhenNothingHasBeenChosen() {
        XCTAssertFalse(CloudSyncSettings(defaults: defaults()).isEnabled)
    }

    func testTheContainerDefaultsToTheBundleIdentifierConvention() {
        XCTAssertEqual(
            CloudSyncSettings(defaults: defaults()).containerIdentifier,
            "iCloud.com.rihscb.Planner"
        )
    }

    func testAContainerOverrideIsUsed() {
        let store = defaults()
        store.set("iCloud.example.Other", forKey: CloudSyncSettings.Key.containerIdentifier)
        XCTAssertEqual(CloudSyncSettings(defaults: store).containerIdentifier, "iCloud.example.Other")
    }

    /// A blank or whitespace override is a cleared text field, not a request to
    /// attach to a container named "".
    func testABlankContainerOverrideFallsBackToTheDefault() {
        let store = defaults()
        store.set("   ", forKey: CloudSyncSettings.Key.containerIdentifier)
        XCTAssertEqual(
            CloudSyncSettings(defaults: store).containerIdentifier,
            CloudSyncSettings.defaultContainerIdentifier
        )
    }

    func testSettingEnabledRoundTrips() {
        let store = defaults()
        CloudSyncSettings.setEnabled(true, in: store)
        XCTAssertTrue(CloudSyncSettings(defaults: store).isEnabled)
        CloudSyncSettings.setEnabled(false, in: store)
        XCTAssertFalse(CloudSyncSettings(defaults: store).isEnabled)
    }
}

// MARK: - Store configuration and fallback

@MainActor
final class CloudSyncStoreTests: XCTestCase {
    private var temporaryStores: [URL] = []

    override func tearDown() {
        for url in temporaryStores {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(
                    at: url.deletingPathExtension().appendingPathExtension("sqlite\(suffix)")
                )
            }
        }
        temporaryStores = []
        super.tearDown()
    }

    private func temporaryStoreURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudSyncTest-\(UUID().uuidString).sqlite")
        temporaryStores.append(url)
        return url
    }

    private func close(_ persistence: PersistenceController) {
        let coordinator = persistence.container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            try? coordinator.remove(store)
        }
    }

    func testTheDefaultStoreDoesNotSync() {
        let persistence = PersistenceController(inMemory: true)
        XCTAssertNil(persistence.storeLoadError)
        XCTAssertFalse(persistence.isCloudSyncActive)
        XCTAssertNil(persistence.cloudSyncFallbackError)
        XCTAssertEqual(persistence.viewContext.transactionAuthor, PersistenceController.userTransactionAuthor)
    }

    /// `/dev/null` is not a file CloudKit can mirror, so an in-memory store must
    /// refuse the request outright rather than fail to attach and log about it.
    func testAnInMemoryStoreNeverSyncsEvenWhenAsked() {
        let persistence = PersistenceController(
            inMemory: true,
            syncSettings: CloudSyncSettings(isEnabled: true)
        )
        XCTAssertNil(persistence.storeLoadError)
        XCTAssertFalse(persistence.isCloudSyncActive)
        XCTAssertFalse(persistence.syncSettings.isEnabled)
    }

    /// The behaviour the whole feature rests on: a container this build is not
    /// signed for must cost the user nothing. No launch failure, no lost
    /// library — just a local store and something honest to say in the menu.
    ///
    /// This is not a hypothetical. Mirroring without the entitlement does not
    /// error; it silently never syncs. The gate in `PersistenceController` is
    /// what turns that into a state the app can describe.
    ///
    /// The identifier below can never appear in any entitlement, so the test
    /// holds whether or not the machine running it is set up for iCloud.
    func testAnUnusableContainerFallsBackToALocalStore() {
        let persistence = PersistenceController(
            syncSettings: CloudSyncSettings(
                isEnabled: true,
                containerIdentifier: "iCloud.com.rihscb.Planner.invalid.test"
            ),
            storeURL: temporaryStoreURL()
        )
        defer { close(persistence) }

        XCTAssertNil(persistence.storeLoadError, "the fallback store must still load")
        XCTAssertFalse(persistence.isCloudSyncActive)
        XCTAssertNotNil(persistence.cloudSyncFallbackError, "the reason must be kept, not swallowed")

        // And the local store is fully usable.
        let model = ModelController(persistence: persistence)
        XCTAssertNoThrow(try model.createProject())
        XCTAssertEqual(try model.allProjects().count, 1)
    }

    func testTheControllerReportsUnavailableWhenSyncWasAskedForAndRefused() {
        let persistence = PersistenceController(
            syncSettings: CloudSyncSettings(
                isEnabled: true,
                containerIdentifier: "iCloud.com.rihscb.Planner.invalid.test"
            ),
            storeURL: temporaryStoreURL()
        )
        defer { close(persistence) }

        let sync = CloudSyncController(persistence: persistence, defaults: isolatedDefaults())
        guard case .unavailable = sync.status else {
            return XCTFail("expected .unavailable, got \(sync.status)")
        }
        XCTAssertTrue(sync.status.menuDescription.hasPrefix("iCloud unavailable"))
    }

    /// A regression test for a real crash, not a hypothetical: `start()` used to
    /// ask `CKContainer(identifier:)` for the account status, and that raises an
    /// Objective-C exception — unrecoverable from Swift — when the build is not
    /// signed for the container. Enabling sync on an unsigned build took the app
    /// down on launch. `CloudSyncEntitlement` now gates it, and nothing here may
    /// reach CloudKit unless the entitlement is present.
    func testStartingTheControllerOnAnUnsignedBuildDoesNotCrash() {
        let persistence = PersistenceController(
            syncSettings: CloudSyncSettings(
                isEnabled: true,
                containerIdentifier: "iCloud.com.rihscb.Planner.invalid.test"
            ),
            storeURL: temporaryStoreURL()
        )
        defer { close(persistence) }

        let sync = CloudSyncController(persistence: persistence, defaults: isolatedDefaults())
        sync.start()

        guard case .unavailable = sync.status else {
            return XCTFail("expected .unavailable, got \(sync.status)")
        }
    }

    func testTheControllerReportsOffWhenSyncWasNeverAskedFor() {
        let persistence = PersistenceController(inMemory: true)
        let sync = CloudSyncController(persistence: persistence, defaults: isolatedDefaults())
        XCTAssertEqual(sync.status, .off)
        XCTAssertEqual(sync.status.menuDescription, "Not syncing")
    }

    /// `.idle(nil)` must not claim a sync happened.
    func testTheStatusLineNeverClaimsASyncItCannotEvidence() {
        XCTAssertEqual(CloudSyncStatus.idle(nil).menuDescription, "Waiting for the first sync")
        XCTAssertEqual(CloudSyncStatus.working.menuDescription, "Syncing…")
        XCTAssertEqual(
            CloudSyncStatus.failed("your iCloud storage is full").menuDescription,
            "Sync failed — your iCloud storage is full"
        )
    }
}

// MARK: - Entitlement gate

final class CloudSyncEntitlementTests: XCTestCase {
    /// The check that stands between an unentitled build and a hard crash:
    /// `CKContainer(identifier:)` raises when the container is not in the code
    /// signature, and an Objective-C exception is not something Swift catches.
    func testAContainerThisBuildCannotBeSignedForIsRejected() {
        XCTAssertFalse(
            CloudSyncEntitlement.isSigned(forContainer: "iCloud.com.rihscb.Planner.invalid.test")
        )
    }

    /// Whatever the build is signed for, asking must not throw or trap.
    func testReadingTheEntitlementIsSafeOnAnyBuild() {
        let containers = CloudSyncEntitlement.declaredContainers()
        XCTAssertEqual(containers, containers.filter { !$0.isEmpty })
    }
}

// MARK: - Model version migration

/// `Planner 3` relaxes optionality on every attribute CloudKit would otherwise
/// reject and adds a `uuid` index to each entity. Both are inferrable changes —
/// but "inferrable" is a claim worth testing rather than assuming, and a store
/// that fails to migrate is a library the user cannot open.
@MainActor
final class ModelVersionMigrationTests: XCTestCase {
    func testAV2StoreMigratesToV3AndKeepsItsRows() throws {
        let bundle = Bundle(for: DayNote.self)
        let momd = try XCTUnwrap(bundle.url(forResource: "Planner", withExtension: "momd"))
        let v2 = try XCTUnwrap(
            NSManagedObjectModel(contentsOf: momd.appendingPathComponent("Planner 2.mom"))
        )

        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("V2MigrationTest-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(
                    at: storeURL.deletingPathExtension().appendingPathExtension("sqlite\(suffix)")
                )
            }
        }

        let projectUUID = UUID()
        let messageUUID = UUID()
        try writeV2Store(at: storeURL, model: v2, projectUUID: projectUUID, messageUUID: messageUUID)

        let migrated = NSPersistentContainer(name: "Planner")
        let description = NSPersistentStoreDescription(url: storeURL)
        description.shouldAddStoreAsynchronously = false
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        migrated.persistentStoreDescriptions = [description]

        var loadError: Error?
        migrated.loadPersistentStores { _, error in loadError = error }
        XCTAssertNil(loadError, "the v2 store did not migrate")

        let projects = Project.fetchRequest()
        projects.predicate = NSPredicate(format: "uuid == %@", projectUUID as CVarArg)
        XCTAssertEqual(try migrated.viewContext.fetch(projects).first?.title, "Carried over")

        let messages = SavedMessage.fetchRequest()
        messages.predicate = NSPredicate(format: "uuid == %@", messageUUID as CVarArg)
        let message = try XCTUnwrap(try migrated.viewContext.fetch(messages).first)
        XCTAssertEqual(message.subject, "Kept")
        XCTAssertEqual(message.folder?.name, "Archive")

        // The relaxed optionality is what CloudKit needed, and it survived.
        let attribute = try XCTUnwrap(
            migrated.managedObjectModel.entitiesByName["Project"]?.attributesByName["createdAt"]
        )
        XCTAssertTrue(attribute.isOptional)

        for store in migrated.persistentStoreCoordinator.persistentStores {
            try migrated.persistentStoreCoordinator.remove(store)
        }
    }

    private func writeV2Store(
        at url: URL,
        model: NSManagedObjectModel,
        projectUUID: UUID,
        messageUUID: UUID
    ) throws {
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

        let folder = NSEntityDescription.insertNewObject(forEntityName: "MailFolder", into: context)
        folder.setValue(UUID(), forKey: "uuid")
        folder.setValue("Archive", forKey: "name")
        folder.setValue(Int64(0), forKey: "sortIndex")
        folder.setValue(now, forKey: "createdAt")
        folder.setValue(now, forKey: "updatedAt")

        let message = NSEntityDescription.insertNewObject(forEntityName: "SavedMessage", into: context)
        message.setValue(messageUUID, forKey: "uuid")
        message.setValue("<kept@example.com>", forKey: "messageID")
        message.setValue("Kept", forKey: "subject")
        message.setValue("A Sender", forKey: "senderName")
        message.setValue("a@example.com", forKey: "senderAddress")
        message.setValue(now, forKey: "receivedAt")
        message.setValue(false, forKey: "hasAttachments")
        message.setValue(Int64(7), forKey: "outlookID")
        message.setValue(now, forKey: "createdAt")
        message.setValue(now, forKey: "updatedAt")
        message.setValue(folder, forKey: "folder")

        try context.save()
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
    }
}
