import CloudKit
import CoreData

extension Notification.Name {
    /// Posted on the main queue once changes written outside this process — a
    /// CloudKit import, or a second Planner on the same Mac — have been merged
    /// into the view context.
    ///
    /// The outline and the inspector already redraw on
    /// `NSManagedObjectContextObjectsDidChange`, which a merge does post. The
    /// calendar's day-note dots and the mail list only listen for did-save,
    /// and a merge is not a save. This is the notification that covers them.
    static let plannerStoreDidChangeRemotely = Notification.Name("plannerStoreDidChangeRemotely")

    /// Posted when `CloudSyncController.status` changes, so the menu can redraw.
    static let plannerCloudSyncStatusDidChange = Notification.Name("plannerCloudSyncStatusDidChange")
}

/// What the sync menu shows and, more importantly, what a failure looks like.
nonisolated enum CloudSyncStatus: Equatable, Sendable {
    /// Sync is switched off in preferences. The store is local, as before.
    case off
    /// Switched on, but iCloud cannot be used — no account, no entitlement, a
    /// container the signing team does not own. The store still loaded locally;
    /// nothing is lost, nothing is uploaded.
    case unavailable(String)
    /// Set up and quiet. Carries the end of the last successful transfer.
    case idle(Date?)
    /// A transfer is in flight.
    case working
    /// The last transfer failed. Carries the message worth showing a human.
    case failed(String)

    /// One line for a disabled menu item. Deliberately never "Synced" without
    /// evidence: an idle sync with no transfer yet says so.
    var menuDescription: String {
        switch self {
        case .off:
            return "Not syncing"
        case .unavailable(let reason):
            return "iCloud unavailable — \(reason)"
        case .idle(let date):
            guard let date else { return "Waiting for the first sync" }
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return "Last synced \(formatter.string(from: date))"
        case .working:
            return "Syncing…"
        case .failed(let message):
            return "Sync failed — \(message)"
        }
    }
}

/// Holds notification observers so they are removed when the controller goes.
///
/// A `@MainActor` stored property is not reachable from a nonisolated `deinit`
/// under Swift 6, and `deinit` cannot be isolated. Parking the tokens in a
/// separately-owned box moves the cleanup to the box's own `deinit`, which is
/// nonisolated all the way down. `NotificationCenter` is thread-safe, so the
/// only thing needing protection is the array itself.
private nonisolated final class ObserverTokens: @unchecked Sendable {
    private let lock = NSLock()
    /// `nonisolated(unsafe)` because a `Sendable` type's `deinit` may run on any
    /// thread and so may not touch non-`Sendable` state — which an array of
    /// observer tokens is. The lock below is what actually makes it safe.
    private nonisolated(unsafe) var tokens: [NSObjectProtocol] = []

    func append(_ token: NSObjectProtocol) {
        lock.lock()
        defer { lock.unlock() }
        tokens.append(token)
    }

    deinit {
        lock.lock()
        let drained = tokens
        tokens = []
        lock.unlock()
        for token in drained {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

/// One CloudKit mirroring event, reduced to values that can cross an isolation
/// boundary. `NSPersistentCloudKitContainer.Event` cannot: it is a class, and
/// its `error` is an `any Error`.
private nonisolated struct CloudSyncEvent: Sendable {
    var kind: String
    var endDate: Date?
    var failureMessage: String?

    var isFinished: Bool { endDate != nil }
}

/// Owns everything that is true only while CloudKit mirroring is on: the remote
/// change observer, the history drain that follows it, the repair pass, and the
/// status the menu reads.
///
/// Deliberately separate from `PersistenceController`, which decides *whether*
/// to mirror and must stay usable — and testable — with sync off. When sync is
/// off this controller installs nothing and reports `.off`.
@MainActor
final class CloudSyncController {
    private let container: NSPersistentContainer
    private let defaults: UserDefaults
    private let containerIdentifier: String
    private let drain: PersistentHistoryDrain?

    private let observers = ObserverTokens()
    /// A drain in flight plus a request that arrived while it ran. CloudKit
    /// posts remote-change notifications in bursts during an import, and each
    /// one does not need its own pass over the same history.
    private var isDraining = false
    private var needsAnotherDrain = false
    /// Set once a transfer has actually succeeded, so `.idle` can tell "quiet
    /// because it is done" from "quiet because nothing has happened yet".
    private var lastSuccess: Date?

    private(set) var status: CloudSyncStatus {
        didSet {
            guard status != oldValue else { return }
            NotificationCenter.default.post(name: .plannerCloudSyncStatusDidChange, object: self)
        }
    }

    /// What the last repair pass had to fix. Nil until one has run. Exposed for
    /// tests and for the log; a non-empty summary is worth noticing, because it
    /// means two devices produced a state neither one could produce alone.
    private(set) var lastRepair: StoreRepair.Summary?

    init(persistence: PersistenceController, defaults: UserDefaults = .standard) {
        self.container = persistence.container
        self.defaults = defaults
        self.containerIdentifier = persistence.syncSettings.containerIdentifier

        if persistence.isCloudSyncActive {
            self.drain = PersistentHistoryDrain(
                container: persistence.container,
                skippedAuthors: [PersistenceController.userTransactionAuthor, StoreRepair.transactionAuthor]
            )
            self.status = .idle(nil)
        } else {
            self.drain = nil
            if persistence.syncSettings.isEnabled {
                // Asked for, refused. The most common cause by far is a build
                // signed without the iCloud entitlement, so say that rather
                // than a Core Data error the user cannot act on.
                let reason = persistence.cloudSyncFallbackError?.localizedDescription
                    ?? "the store could not be attached to \(persistence.syncSettings.containerIdentifier)"
                self.status = .unavailable(reason)
            } else {
                self.status = .off
            }
        }
    }

    /// Installs the observers and takes a first pass over history. Safe to call
    /// when sync is off — it does nothing.
    func start() {
        guard drain != nil else {
            PlannerLog.persistence.info("iCloud sync inactive: \(self.status.menuDescription, privacy: .public)")
            return
        }
        observeRemoteChanges()
        observeSyncEvents()
        checkAccount()
        // Forced: damage that arrived before this launch predates the token.
        runDrain(force: true)
    }

    // MARK: - Remote changes

    private func observeRemoteChanges() {
        let observer = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: container.persistentStoreCoordinator,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.runDrain()
            }
        }
        observers.append(observer)
    }

    private func runDrain(force: Bool = false) {
        guard let drain else { return }
        guard !isDraining else {
            needsAnotherDrain = true
            return
        }
        isDraining = true

        let tokenData = defaults.data(forKey: CloudSyncSettings.Key.historyToken)
        drain.drain(after: tokenData, force: force) { [weak self] outcome in
            Task { @MainActor in
                self?.finishDrain(outcome)
            }
        }
    }

    private func finishDrain(_ outcome: PersistentHistoryDrain.Outcome) {
        isDraining = false

        if let failure = outcome.failure {
            PlannerLog.persistence.error("Persistent history drain failed: \(failure, privacy: .public)")
        } else if let tokenData = outcome.tokenData {
            defaults.set(tokenData, forKey: CloudSyncSettings.Key.historyToken)
        }

        if !outcome.repair.isEmpty {
            lastRepair = outcome.repair
            PlannerLog.persistence.info(
                """
                Import repair: \(outcome.repair.identitiesFilled, privacy: .public) ids, \
                \(outcome.repair.timestampsFilled, privacy: .public) timestamps, \
                \(outcome.repair.titlesFilled, privacy: .public) titles, \
                \(outcome.repair.dualParentsResolved, privacy: .public) dual parents, \
                \(outcome.repair.cyclesBroken, privacy: .public) cycles, \
                \(outcome.repair.orphansAdopted, privacy: .public) orphans
                """
            )
        }

        if outcome.transactionCount > 0 {
            NotificationCenter.default.post(name: .plannerStoreDidChangeRemotely, object: self)
        }

        if needsAnotherDrain {
            needsAnotherDrain = false
            runDrain()
        }
    }

    // MARK: - Sync events

    private func observeSyncEvents() {
        let observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: container,
            queue: .main
        ) { [weak self] notification in
            // Flattened here, on the delivering side, because neither the event
            // nor its error can be carried across to the main actor as-is.
            guard let event = notification.userInfo?[
                NSPersistentCloudKitContainer.eventNotificationUserInfoKey
            ] as? NSPersistentCloudKitContainer.Event else { return }
            let reduced = CloudSyncEvent(
                kind: Self.name(of: event.type),
                endDate: event.endDate,
                failureMessage: event.error.map(Self.message(for:))
            )
            MainActor.assumeIsolated { [weak self] in
                self?.apply(reduced)
            }
        }
        observers.append(observer)
    }

    private func apply(_ event: CloudSyncEvent) {
        guard event.isFinished else {
            status = .working
            return
        }
        if let failure = event.failureMessage {
            PlannerLog.persistence.error(
                "CloudKit \(event.kind, privacy: .public) failed: \(failure, privacy: .public)"
            )
            status = .failed(failure)
            return
        }
        lastSuccess = event.endDate ?? lastSuccess
        status = .idle(lastSuccess)
    }

    private nonisolated static func name(of type: NSPersistentCloudKitContainer.EventType) -> String {
        switch type {
        case .setup: return "setup"
        case .import: return "import"
        case .export: return "export"
        @unknown default: return "event"
        }
    }

    /// CloudKit's own text is usually the most accurate thing available, but the
    /// two failures a user can actually act on deserve to say so plainly.
    private nonisolated static func message(for error: Error) -> String {
        guard let ckError = error as? CKError else { return error.localizedDescription }
        switch ckError.code {
        case .notAuthenticated:
            return "sign in to iCloud in System Settings"
        case .quotaExceeded:
            return "your iCloud storage is full"
        case .networkUnavailable, .networkFailure:
            return "no network connection"
        case .managedAccountRestricted:
            return "iCloud is restricted on this account"
        default:
            return ckError.localizedDescription
        }
    }

    // MARK: - Account

    /// An entitlement or account problem shows up here as a clear sentence,
    /// where otherwise it would only surface as an opaque export failure some
    /// seconds later.
    private func checkAccount() {
        let identifier = containerIdentifier
        Task { [weak self] in
            let (accountStatus, failure) = await Self.accountStatus(for: identifier)
            self?.applyAccountStatus(accountStatus, failure: failure)
        }
    }

    private func applyAccountStatus(_ accountStatus: CKAccountStatus?, failure: String?) {
        if let failure {
            status = .unavailable(failure)
            return
        }
        switch accountStatus {
        case .available, .none:
            break
        case .noAccount:
            status = .unavailable("no iCloud account is signed in on this Mac")
        case .restricted:
            status = .unavailable("iCloud is restricted on this Mac")
        case .couldNotDetermine, .temporarilyUnavailable:
            status = .unavailable("iCloud is temporarily unavailable")
        @unknown default:
            break
        }
    }

    /// Returns plain values rather than a `Result`: the hop back to the main
    /// actor has to carry `Sendable` payloads, and `any Error` is not.
    private nonisolated static func accountStatus(
        for identifier: String
    ) async -> (CKAccountStatus?, String?) {
        do {
            return (try await CKContainer(identifier: identifier).accountStatus(), nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }
}
