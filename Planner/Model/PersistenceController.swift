import AppKit
import CoreData

enum PersistenceError: LocalizedError {
    case missingStoreDescription

    var errorDescription: String? {
        switch self {
        case .missingStoreDescription:
            return "The persistent store description is missing."
        }
    }
}

final class PersistenceController {
    let container: NSPersistentContainer
    let storeLoadError: Error?

    var viewContext: NSManagedObjectContext { container.viewContext }

    /// - Parameter inMemory: When true, keep NSSQLiteStoreType and point
    ///   the file at /dev/null so history tracking still works.
    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "Planner")
        guard let description = container.persistentStoreDescriptions.first else {
            storeLoadError = PersistenceError.missingStoreDescription
            PlannerLog.persistence.error("Persistent store failed to load: missing store description")
            return
        }

        if inMemory {
            description.url = URL(fileURLWithPath: "/dev/null")
            // Do NOT set description.type = NSInMemoryStoreType.
            // History tracking is SQLite-only.
        }

        description.shouldAddStoreAsynchronously = false
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        description.setOption(["journal_mode": "WAL"] as NSDictionary, forKey: NSSQLitePragmasOption)

        var loadError: Error?
        container.loadPersistentStores { _, error in
            loadError = error
        }
        // shouldAddStoreAsynchronously == false: the store is attached
        // (or has failed) before loadPersistentStores returns. Do not
        // DispatchGroup.wait() on the main queue — that deadlocks if the
        // completion is bounced back to main.
        storeLoadError = loadError

        if let storeLoadError {
            PlannerLog.persistence.error("Persistent store failed to load: \(storeLoadError.localizedDescription, privacy: .public)")
            return
        }

        PlannerLog.persistence.info("Persistent store loaded")

        viewContext.automaticallyMergesChangesFromParent = true
        viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        viewContext.undoManager = UndoManager()
        viewContext.name = "viewContext"
        viewContext.transactionAuthor = "planner.user"
    }

    @discardableResult
    func saveViewContext(presentingWindow: NSWindow?) -> Bool {
        let ctx = viewContext
        guard ctx.hasChanges else { return true }
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
}
