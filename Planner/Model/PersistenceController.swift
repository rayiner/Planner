import AppKit
import CoreData

enum PersistenceError: LocalizedError {
    case missingStoreDescription
    case missingCloudKitEntitlement(String)

    var errorDescription: String? {
        switch self {
        case .missingStoreDescription:
            return "The persistent store description is missing."
        case .missingCloudKitEntitlement(let identifier):
            return "this build of Planner is not signed for the iCloud container “\(identifier)”"
        }
    }
}

final class PersistenceController {
    /// The author stamped on every user edit, so the history drain can tell an
    /// import apart from something typed in this window.
    static let userTransactionAuthor = "planner.user"

    let container: NSPersistentContainer
    let storeLoadError: Error?

    /// The settings this store actually loaded with — after any fallback, so
    /// `isEnabled` here can be true while `isCloudSyncActive` is false.
    let syncSettings: CloudSyncSettings

    /// True when the store is attached to a CloudKit container. That means
    /// mirroring is configured and the entitlement is present — not that a
    /// transfer has succeeded, which only `CloudSyncController` can say.
    private(set) var isCloudSyncActive = false

    /// Why mirroring was asked for and did not happen: the container this build
    /// is signed for does not match the one requested, or the model was refused
    /// by CloudKit. Nil when sync is off or working.
    private(set) var cloudSyncFallbackError: Error?

    var viewContext: NSManagedObjectContext { container.viewContext }

    /// - Parameters:
    ///   - inMemory: When true, use a throwaway SQLite file under the temporary
    ///     directory, deleted when this controller goes. It cannot be
    ///     `NSInMemoryStoreType` — history tracking requires SQLite — and it can
    ///     no longer be `/dev/null`, which worked only while the binary was
    ///     unsigned: once the app signs for real, Core Data's connection manager
    ///     rejects the character device with "No eligible connection available"
    ///     on the first fetch. Forces sync off: a scratch file is not something
    ///     to mirror.
    ///   - syncSettings: Defaults to `.disabled` rather than reading
    ///     `UserDefaults`, so a test — or any other caller that did not ask for
    ///     it — can never be talking to iCloud by accident. `AppDelegate` is the
    ///     one place that passes the real preference in.
    ///   - storeURL: Overrides where the store file lives. Only tests pass it,
    ///     and only the ones that need a real file on disk — CloudKit will not
    ///     attach to `/dev/null`, so exercising the fallback needs somewhere to
    ///     put a throwaway store that is not the user's library.
    /// Deleted on `deinit` when `inMemory` created it. Nil otherwise — a real
    /// library is never this controller's to remove.
    private let temporaryStoreURL: URL?

    init(inMemory: Bool = false, syncSettings: CloudSyncSettings = .disabled, storeURL: URL? = nil) {
        // Assigned before any early return: every stored property must be.
        // The pid in the name is what makes the sweep below safe under
        // parallel test execution — a scratch store belonging to a process
        // that is still running must never be deleted out from under it.
        if inMemory {
            Self.sweepAbandonedTemporaryStores()
            temporaryStoreURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "\(Self.temporaryStorePrefix)\(getpid())-\(UUID().uuidString).sqlite"
                )
        } else {
            temporaryStoreURL = nil
        }

        // Always the CloudKit subclass, even with sync off: without
        // `cloudKitContainerOptions` on the description it behaves exactly like
        // `NSPersistentContainer`, and having one class means the store file,
        // the model, and every code path below are identical either way.
        let container = NSPersistentCloudKitContainer(name: "Planner")
        self.container = container

        let wantsSync = syncSettings.isEnabled && !inMemory
        self.syncSettings = CloudSyncSettings(
            isEnabled: wantsSync,
            containerIdentifier: syncSettings.containerIdentifier
        )

        // Asked before anything CloudKit-shaped is constructed, because
        // mirroring without the entitlement does not fail — it does nothing,
        // quietly, forever — and `CKContainer(identifier:)` on an unentitled
        // container raises an Objective-C exception that ends the process.
        let isEntitled = CloudSyncEntitlement.isSigned(forContainer: syncSettings.containerIdentifier)
        if wantsSync && !isEntitled {
            cloudSyncFallbackError = PersistenceError.missingCloudKitEntitlement(
                syncSettings.containerIdentifier
            )
        }
        let canSync = wantsSync && isEntitled

        guard let description = container.persistentStoreDescriptions.first else {
            storeLoadError = PersistenceError.missingStoreDescription
            PlannerLog.persistence.error("Persistent store failed to load: missing store description")
            return
        }

        if let temporaryStoreURL {
            description.url = temporaryStoreURL
        } else if let storeURL {
            description.url = storeURL
        }

        description.shouldAddStoreAsynchronously = false
        // Both are prerequisites for mirroring, not merely nice to have: the
        // CloudKit delegate consumes the same history this app's drain reads.
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        description.setOption(["journal_mode": "WAL"] as NSDictionary, forKey: NSSQLitePragmasOption)

        if canSync {
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: syncSettings.containerIdentifier
            )
        }

        var loadError: Error?
        container.loadPersistentStores { _, error in
            loadError = error
        }

        // A model CloudKit rejects — an ordered relationship, a uniqueness
        // constraint, an attribute that is neither optional nor defaulted —
        // fails the load outright. That is a programming mistake, and it is not
        // a reason to refuse to open a local library the user can still work in,
        // so drop the CloudKit options and try again before giving up.
        if let cloudError = loadError, canSync {
            PlannerLog.persistence.error(
                """
                CloudKit store failed to load (\(cloudError.localizedDescription, privacy: .public)); \
                falling back to a local store
                """
            )
            cloudSyncFallbackError = cloudError
            description.cloudKitContainerOptions = nil
            loadError = nil
            container.loadPersistentStores { _, error in
                loadError = error
            }
        } else if canSync {
            isCloudSyncActive = true
        }

        storeLoadError = loadError

        if let storeLoadError {
            PlannerLog.persistence.error("Persistent store failed to load: \(storeLoadError.localizedDescription, privacy: .public)")
            return
        }

        PlannerLog.persistence.info(
            "Persistent store loaded (iCloud sync \(self.isCloudSyncActive ? "on" : "off", privacy: .public))"
        )

        viewContext.automaticallyMergesChangesFromParent = true
        // Local edits win a property-level conflict. With mirroring on this is
        // last-writer-wins per attribute, which is why `ModelController` bumps
        // `updatedAt` only when a value really changed: a meaningless bump is a
        // meaningless conflict.
        viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        viewContext.undoManager = UndoManager()
        viewContext.name = "viewContext"
        viewContext.transactionAuthor = Self.userTransactionAuthor
    }

    static let temporaryStorePrefix = "PlannerTestStore-"

    deinit {
        guard let temporaryStoreURL else { return }
        let base = temporaryStoreURL.deletingPathExtension()
        for suffix in ["sqlite", "sqlite-wal", "sqlite-shm"] {
            try? FileManager.default.removeItem(at: base.appendingPathExtension(suffix))
        }
    }

    /// Removes scratch stores left behind by test processes that have exited.
    ///
    /// `deinit` handles the tidy case, but it is not enough on its own: a view
    /// controller built in a UI test keeps its `PersistenceController` alive to
    /// the end of the process, and `deinit` at process exit is not guaranteed to
    /// run at all. Without this, every test run left a few hundred empty SQLite
    /// files in the temporary directory.
    ///
    /// Safe under parallel testing because it only touches files whose owning
    /// pid is gone: `kill(pid, 0)` succeeding — or failing with `EPERM`, meaning
    /// the process exists but belongs to someone else — leaves the file alone.
    private static func sweepAbandonedTemporaryStores() {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }

        for name in names where name.hasPrefix(temporaryStorePrefix) {
            let trailing = name.dropFirst(temporaryStorePrefix.count)
            guard let field = trailing.split(separator: "-").first,
                  let pid = pid_t(field) else { continue }
            if kill(pid, 0) == 0 || errno == EPERM { continue }
            try? manager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Test hook: next save rolls back and returns false without an alert.
    var failNextSave = false

    @discardableResult
    func saveViewContext(presentingWindow: NSWindow?) -> Bool {
        let ctx = viewContext
        guard ctx.hasChanges else { return true }
        if failNextSave {
            failNextSave = false
            ctx.rollback()
            return false
        }
        do {
            try ctx.save()
            return true
        } catch {
            ctx.rollback()
            PlannerLog.persistence.error("Failed to save view context: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert(error: error)
            if let presentingWindow { alert.beginSheetModal(for: presentingWindow) }
            else { alert.runModal() }
            return false
        }
    }

    /// Pushes the model to CloudKit as a schema, in the development environment.
    ///
    /// Debug only and deliberately not wired to any menu: this is the one-off a
    /// developer runs once per model change so the record types exist before a
    /// real device syncs, and running it is a write to the developer's CloudKit
    /// dashboard, not something a user should be able to trigger by accident.
    /// Set `PLANNER_INIT_CLOUDKIT_SCHEMA=1` in the scheme's environment.
    #if DEBUG
    static let initializeSchemaEnvironmentKey = "PLANNER_INIT_CLOUDKIT_SCHEMA"

    func initializeCloudKitSchemaIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard environment[Self.initializeSchemaEnvironmentKey] == "1" else { return }
        guard isCloudSyncActive, let container = container as? NSPersistentCloudKitContainer else {
            PlannerLog.persistence.error("Cannot initialize the CloudKit schema: sync is not active")
            return
        }
        do {
            try container.initializeCloudKitSchema(options: [])
            PlannerLog.persistence.info("CloudKit schema initialized")
        } catch {
            PlannerLog.persistence.error(
                "CloudKit schema initialization failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
    #endif
}
