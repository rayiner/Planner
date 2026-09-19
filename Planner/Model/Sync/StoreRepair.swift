import CoreData

/// Repairs — never rejects — rows that violate an invariant `ModelController`
/// enforces at the write site but the store itself cannot.
///
/// DESIGN.md §3 deliberately keeps `validateForInsert`/`validateForUpdate` free
/// of throws so that a CloudKit import can never abort partway and strand the
/// store. The price of that choice is paid here: the xor between `project` and
/// `parentTask`, non-empty titles, and acyclic parent chains are all *code*
/// invariants, and a record that arrives from
/// another device — or from an older, buggier build of this app — can break any
/// of them. Mirroring also means every attribute is optional in the model
/// (CloudKit fills absent fields with nil), so identity and timestamps can be
/// missing too.
///
/// Every fix is idempotent and additive: a second run over a repaired store
/// changes nothing. Nothing here deletes a row — an orphan is adopted into a
/// recovery container rather than dropped, because a task that lost its parent
/// in a merge is still something the user typed.
///
/// Reads go through `value(forKey:)` rather than the typed `@NSManaged`
/// accessors on purpose: those are declared non-optional, and reading a nil
/// through one traps. This type is the one place that expects nil.
nonisolated enum StoreRepair {
    /// The transaction author repair writes under, so the history consumer can
    /// tell its own writes from an import and not chase its tail.
    static let transactionAuthor = "planner.repair"

    static let recoveryProjectTitle = "Recovered Items"

    private static let entityNames = ["Project", "Task", "DayNote"]

    struct Summary: Equatable {
        var identitiesFilled = 0
        var timestampsFilled = 0
        var titlesFilled = 0
        var dualParentsResolved = 0
        var cyclesBroken = 0
        var orphansAdopted = 0

        var isEmpty: Bool {
            identitiesFilled == 0 && timestampsFilled == 0 && titlesFilled == 0
                && dualParentsResolved == 0 && cyclesBroken == 0 && orphansAdopted == 0
        }
    }

    /// Runs every repair, in dependency order, and saves if anything changed.
    ///
    /// Order matters: timestamps lean on the identity pass having run, cycle
    /// breaking detaches rows that the orphan pass then adopts, and dual parents
    /// are resolved first so the cycle walk sees one parent chain per task.
    @discardableResult
    static func run(
        in context: NSManagedObjectContext,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> Summary {
        var summary = Summary()
        summary.identitiesFilled = try fillMissingIdentity(in: context)
        summary.timestampsFilled = try fillMissingTimestamps(in: context, now: now, calendar: calendar)
        summary.titlesFilled = try fillEmptyTitles(in: context)
        summary.dualParentsResolved = try resolveDualParents(in: context)
        summary.cyclesBroken = try breakCycles(in: context)
        summary.orphansAdopted = try adoptOrphanTasks(in: context, now: now)

        if context.hasChanges {
            try context.save()
        }
        return summary
    }

    // MARK: - Identity and timestamps

    /// `uuid` is the app-stable identity every reveal, chip and expansion key
    /// leans on. A row without one is invisible to all of them.
    private static func fillMissingIdentity(in context: NSManagedObjectContext) throws -> Int {
        var filled = 0
        for name in entityNames {
            for object in try context.fetch(rows(name, where: "uuid == nil")) {
                object.setValue(UUID(), forKey: "uuid")
                filled += 1
            }
        }
        return filled
    }

    private static func fillMissingTimestamps(
        in context: NSManagedObjectContext,
        now: Date,
        calendar: Calendar
    ) throws -> Int {
        var filled = 0
        for name in entityNames {
            let request = rows(name, where: "createdAt == nil OR updatedAt == nil")
            for object in try context.fetch(request) {
                if object.value(forKey: "createdAt") == nil { object.setValue(now, forKey: "createdAt") }
                if object.value(forKey: "updatedAt") == nil { object.setValue(now, forKey: "updatedAt") }
                filled += 1
            }
        }

        // `day` is a DayNote's address, not decoration: without it the note
        // belongs to no date and can never be read back.
        for note in try context.fetch(rows("DayNote", where: "day == nil")) {
            let created = note.value(forKey: "createdAt") as? Date ?? now
            note.setValue(calendar.startOfDay(for: created), forKey: "day")
            filled += 1
        }

        return filled
    }

    /// An empty title renders as a blank, unclickable outline row.
    private static func fillEmptyTitles(in context: NSManagedObjectContext) throws -> Int {
        var filled = 0
        let blanks: [(entity: String, key: String, replacement: String)] = [
            ("Project", "title", "Untitled Project"),
            ("Task", "title", "Untitled Task"),
        ]
        for blank in blanks {
            let request = rows(blank.entity, where: "\(blank.key) == nil OR \(blank.key) == ''")
            for object in try context.fetch(request) {
                object.setValue(blank.replacement, forKey: blank.key)
                filled += 1
            }
        }
        return filled
    }

    // MARK: - Parentage

    /// DESIGN.md §3: a task hangs off a project **xor** another task. When both
    /// arrive set, `parentTask` wins — it is the more specific claim, and the
    /// project is still reachable through the parent chain.
    private static func resolveDualParents(in context: NSManagedObjectContext) throws -> Int {
        let tasks = try context.fetch(rows("Task", where: "project != nil AND parentTask != nil"))
        for task in tasks {
            task.setValue(nil, forKey: "project")
        }
        return tasks.count
    }

    /// Two devices can reparent the same pair of tasks into each other. Neither
    /// write is invalid on its own; the merge is. An uncut cycle hangs every
    /// outline walk, so cut the edge that closes it and let the orphan pass
    /// adopt whatever came loose.
    private static func breakCycles(in context: NSManagedObjectContext) throws -> Int {
        let tasks = try context.fetch(rows("Task", where: "parentTask != nil"))

        var broken = 0
        var acyclic: Set<NSManagedObjectID> = []

        for task in tasks {
            var walked: [NSManagedObject] = []
            var seen: Set<NSManagedObjectID> = []
            var node: NSManagedObject? = task

            while let current = node {
                if acyclic.contains(current.objectID) { break }
                guard seen.insert(current.objectID).inserted else {
                    // `current` is already on this walk, so the edge just
                    // followed into it is the one closing the loop.
                    walked.last?.setValue(nil, forKey: "parentTask")
                    broken += 1
                    break
                }
                walked.append(current)
                node = current.value(forKey: "parentTask") as? NSManagedObject
            }
            acyclic.formUnion(seen)
        }
        return broken
    }

    /// A task with neither parent is unreachable from the outline. Adopting it
    /// into a recovery project keeps the text; deleting it would not.
    private static func adoptOrphanTasks(in context: NSManagedObjectContext, now: Date) throws -> Int {
        let orphans = try context.fetch(rows("Task", where: "project == nil AND parentTask == nil"))
        guard !orphans.isEmpty else { return 0 }

        let recovery = try recoveryProject(in: context, now: now)
        var index = try nextSortIndex(forChildrenOf: recovery, in: context)
        for orphan in orphans {
            orphan.setValue(recovery, forKey: "project")
            orphan.setValue(nil, forKey: "parentTask")
            orphan.setValue(index, forKey: "sortIndex")
            index += 1
        }
        return orphans.count
    }

    // MARK: - Recovery containers

    /// Found by title rather than by a marker attribute, so the user can rename
    /// or delete it and the next repair simply makes a new one. Matching on
    /// title means no CloudKit-visible schema exists purely to serve repair.
    private static func recoveryProject(in context: NSManagedObjectContext, now: Date) throws -> NSManagedObject {
        if let existing = try first("Project", where: "title == %@", recoveryProjectTitle, in: context) {
            return existing
        }
        let project = NSEntityDescription.insertNewObject(forEntityName: "Project", into: context)
        project.setValue(UUID(), forKey: "uuid")
        project.setValue(recoveryProjectTitle, forKey: "title")
        project.setValue(try maxSortIndex(rows("Project", where: "TRUEPREDICATE"), in: context) + 1, forKey: "sortIndex")
        project.setValue(now, forKey: "createdAt")
        project.setValue(now, forKey: "updatedAt")
        return project
    }

    // MARK: - Helpers

    /// Untyped on purpose. Repair runs on a background context, and the typed
    /// `NSManagedObject` subclasses in this app are main-actor isolated because
    /// every other caller reaches them through the view context. Reaching for
    /// `NSManagedObject` here keeps that isolation intact everywhere else
    /// instead of loosening five model files to suit one background pass — and
    /// it is the same key-value access the nil-tolerant reads above already need.
    private static func rows(_ entityName: String, where format: String) -> NSFetchRequest<NSManagedObject> {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.predicate = NSPredicate(format: format)
        return request
    }

    /// The oldest match, so two devices that both made a recovery container
    /// converge on the same one rather than ping-ponging between them.
    private static func first(
        _ entityName: String,
        where format: String,
        _ argument: String,
        in context: NSManagedObjectContext
    ) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.predicate = NSPredicate(format: format, argument)
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    /// Duplicate `sortIndex` values are legal (DESIGN §3 orders siblings by
    /// `(sortIndex, uuid)`), so this only has to avoid piling every recovered
    /// row on index zero — it does not have to be collision-free.
    private static func maxSortIndex(
        _ request: NSFetchRequest<NSManagedObject>,
        in context: NSManagedObjectContext
    ) throws -> Int64 {
        request.sortDescriptors = [NSSortDescriptor(key: "sortIndex", ascending: false)]
        request.fetchLimit = 1
        guard let top = try context.fetch(request).first,
              let index = top.value(forKey: "sortIndex") as? Int64 else { return -1 }
        return index
    }

    private static func nextSortIndex(
        forChildrenOf project: NSManagedObject,
        in context: NSManagedObjectContext
    ) throws -> Int64 {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Task")
        request.predicate = NSPredicate(format: "project == %@", project)
        return try maxSortIndex(request, in: context) + 1
    }
}
