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
            // History tracking requires SQLite; /dev/null discards the file.
            description.url = URL(fileURLWithPath: "/dev/null")
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
}
