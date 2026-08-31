import CoreData

/// Reads persistent history off the main queue and repairs whatever an import
/// brought in.
///
/// Merging is *not* this type's job. `viewContext.automaticallyMergesChangesFromParent`
/// already folds in saves made by any sibling context on the same coordinator,
/// which is how the CloudKit mirroring delegate writes. What history buys is the
/// two things that flag cannot give: knowing that a change came from outside
/// this process (so the panes that only listen for did-save can refresh), and a
/// point at which to run `StoreRepair` over freshly imported rows.
///
/// `@unchecked Sendable` is a claim about discipline rather than a loophole. The
/// only stored state is one background context, and every use of it is inside
/// `context.perform` — Core Data's own serial queue for that context. Nothing
/// else touches it, and the outcome handed back is plain values.
nonisolated final class PersistentHistoryDrain: @unchecked Sendable {
    struct Outcome: Sendable, Equatable {
        /// The token to persist, or the one passed in when nothing moved.
        var tokenData: Data?
        var transactionCount = 0
        var repair = StoreRepair.Summary()
        /// Non-nil if history could not be read; the token is then left alone
        /// so the next drain retries the same range.
        var failure: String?
    }

    private let context: NSManagedObjectContext
    private let skippedAuthors: [String]

    /// - Parameter skippedAuthors: transaction authors whose writes are already
    ///   visible in this process. Skipping our own repair author is what stops
    ///   the drain chasing its own tail: repair saves, that save lands in
    ///   history, and a drain that read it back would repair again forever.
    init(container: NSPersistentContainer, skippedAuthors: [String]) {
        context = container.newBackgroundContext()
        context.transactionAuthor = StoreRepair.transactionAuthor
        context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        // An import is not a user edit and must never turn up under ⌘Z.
        context.undoManager = nil
        self.skippedAuthors = skippedAuthors
    }

    /// - Parameter force: run the repair pass even when no new transactions
    ///   arrived. Used for the first drain after launch, where the interesting
    ///   damage may predate the stored token.
    func drain(
        after tokenData: Data?,
        force: Bool = false,
        completion: @escaping @Sendable (Outcome) -> Void
    ) {
        context.perform { [self] in
            var outcome = Outcome(tokenData: tokenData)
            do {
                let request = NSPersistentHistoryChangeRequest.fetchHistory(
                    after: Self.decodeToken(tokenData)
                )
                if let fetch = NSPersistentHistoryTransaction.fetchRequest {
                    fetch.predicate = NSPredicate(format: "NOT (author IN %@)", skippedAuthors)
                    request.fetchRequest = fetch
                }
                let result = try context.execute(request) as? NSPersistentHistoryResult
                let transactions = result?.result as? [NSPersistentHistoryTransaction] ?? []
                outcome.transactionCount = transactions.count

                if let latest = transactions.last?.token, let encoded = Self.encodeToken(latest) {
                    outcome.tokenData = encoded
                }
                if force || !transactions.isEmpty {
                    outcome.repair = try StoreRepair.run(in: context)
                }
                // Imported rows are not this context's to cache; the view
                // context owns what the UI shows.
                context.reset()
            } catch {
                outcome.failure = error.localizedDescription
                // Leave the token where it was so the same range is retried.
                outcome.tokenData = tokenData
            }
            completion(outcome)
        }
    }

    // MARK: - Token coding

    /// History is deliberately *not* purged here. With mirroring on, the
    /// CloudKit delegate is a second consumer of the same history, and deleting
    /// transactions it has not exported yet loses those changes. Core Data
    /// expires history on its own; this app is not the right place to second
    /// guess that.
    static func encodeToken(_ token: NSPersistentHistoryToken) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    /// A token that fails to decode — a store rebuilt, a format change — reads
    /// as "no token", which replays history rather than dropping it.
    static func decodeToken(_ data: Data?) -> NSPersistentHistoryToken? {
        guard let data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: NSPersistentHistoryToken.self,
            from: data
        )
    }
}
