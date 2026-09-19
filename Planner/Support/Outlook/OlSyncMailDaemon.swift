import Foundation

/// JSONSerialization's dictionaries are immutable after decoding here but are
/// not statically Sendable. This box documents that ownership transfer across
/// the session actor.
nonisolated struct OlSyncJSONObject: @unchecked Sendable {
    let value: [String: Any]
}

/// Counts from a running `olsyncmail` job. `total` is the work still to index,
/// not the whole Outlook store; a no-op refresh reports 0.
nonisolated struct OutlookSyncProgress: Sendable, Equatable {
    var phase: String
    var done: Int
    var total: Int
}

/// Publishes daemon progress for the sidebar status line.
///
/// The helper can emit about ten events a second. The UI is told immediately,
/// then at least once a second for as long as the job is running, so a stall
/// on a large attachment still looks alive.
nonisolated final class OutlookSyncProgressReporter: @unchecked Sendable {
    static let shared = OutlookSyncProgressReporter()
    static let interval: TimeInterval = 1
    static let didChangeNotification = Notification.Name("plannerOutlookSyncProgressDidChange")

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "planner.outlook-sync-progress")
    private var latest: OutlookSyncProgress?
    private var lastPostedAt: TimeInterval = 0
    /// When the helper last said anything about a job, whether or not that
    /// word was published. Never reset: after a job ends this is what covers
    /// the gap before the next one starts reporting.
    private var lastHeardFrom: Date?
    private var timer: DispatchSourceTimer?

    var current: OutlookSyncProgress? {
        lock.withLock { latest }
    }

    var lastActivityAt: Date? {
        lock.withLock { lastHeardFrom }
    }

    func update(_ progress: OutlookSyncProgress) {
        let shouldPost: Bool = lock.withLock {
            latest = progress
            let now = Date()
            lastHeardFrom = now
            let stamp = now.timeIntervalSince1970
            if lastPostedAt == 0 || stamp - lastPostedAt >= Self.interval {
                lastPostedAt = stamp
                return true
            }
            return false
        }
        startHeartbeatIfNeeded()
        if shouldPost { post() }
    }

    func clear() {
        lock.lock()
        latest = nil
        lastPostedAt = 0
        lastHeardFrom = Date()
        timer?.cancel()
        timer = nil
        lock.unlock()
        post()
    }

    /// Sleeps until the helper has been silent for `seconds`.
    ///
    /// A feed's timeout is a backstop against a source that never answers, not
    /// a budget for the work. An index that is still counting messages is
    /// plainly alive, and failing it while those counts climb on screen is a
    /// contradiction the user can see — so every progress event pushes the
    /// deadline out. A queued job waits the same way: the sync queue runs one
    /// job at a time, and the one ahead is reporting.
    func waitForSilence(seconds: Int, startedAt start: Date = Date()) async {
        let window = TimeInterval(seconds)
        while !Task.isCancelled {
            let deadline = max(start, lastActivityAt ?? start).addingTimeInterval(window)
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return }
            try? await Task.sleep(for: .seconds(min(remaining, Self.interval)))
        }
    }

    private func startHeartbeatIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval)
        timer.setEventHandler { [weak self] in
            self?.heartbeat()
        }
        timer.resume()
        self.timer = timer
    }

    private func heartbeat() {
        let shouldPost: Bool = lock.withLock {
            guard latest != nil else { return false }
            lastPostedAt = Date().timeIntervalSince1970
            return true
        }
        if shouldPost { post() }
    }

    private func post() {
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self
        )
    }
}

/// FIFO for daemon writes. Calls may arrive from independent mail and calendar
/// refresh tasks, but olsyncmail deliberately runs one sync job at a time.
actor OlSyncJobQueue {
    private var tail: Task<Void, Error>?

    func enqueue(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        let previous = tail
        let task = Task {
            if let previous { _ = try? await previous.value }
            try await operation()
        }
        tail = task
        try await task.value
    }
}

/// Owns one `olsyncmail daemon` process for the life of the mail source.
///
/// The client owns the lifetime: we spawn, we write NDJSON to stdin, we read
/// NDJSON from stdout, and we drain stderr so a log line cannot fill the pipe
/// and look like a hang. Closing stdin is the shutdown signal; if Planner
/// dies first the pipe closes and the daemon follows.
nonisolated final class OlSyncMailDaemon: @unchecked Sendable {
    private let executable: URL
    private let lock = NSLock()
    private var process: Process?
    private var stdin: FileHandle?
    private var nextID: UInt64 = 1
    private var pending: [UInt64: CheckedContinuation<Data, Error>] = [:]
    private var jobs: [UInt64: CheckedContinuation<OlSyncMailProtocol.Event, Error>] = [:]
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var started = false

    init(executable: URL) {
        self.executable = executable
    }

    deinit {
        shutdown()
    }

    static func resolveExecutable(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let override = environment["PLANNER_OLSYNCMAIL"] {
            let url = URL(fileURLWithPath: override)
            if fileManager.isExecutableFile(atPath: url.path) { return url }
        }
        if let bundled = bundle.url(forAuxiliaryExecutable: "olsyncmail"),
           fileManager.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        let sibling = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("mailindex/target/release/olsyncmail")
        if fileManager.isExecutableFile(atPath: sibling.path) { return sibling }
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let url = URL(fileURLWithPath: String(directory)).appendingPathComponent("olsyncmail")
            if fileManager.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    func hello() async throws -> [String: Any] {
        try await call(method: "hello")
    }

    func open(database: URL) async throws -> [String: Any] {
        try await call(method: "open", params: ["db": database.path])
    }

    func refresh() async throws -> [String: Any] {
        try await call(method: "refresh")
    }

    func message(id: Int64) async throws -> [String: Any] {
        try await call(method: "message", params: ["message_id": id])
    }

    /// The category catalogue from the indexed database, account by account.
    /// Needs no Full Disk Access and no Outlook schema check: the daemon has
    /// already read the profile and resolved the account names.
    func categories() async throws -> [OutlookCategory] {
        OlSyncMailProtocol.categories(from: try await call(method: "categories"))
    }

    /// What carries one category, newest first. `kind` is `message` or `event`,
    /// or nil for both. Ids are this database's, not Outlook's.
    func categoryItems(
        categoryID: Int64,
        kind: String? = nil,
        limit: Int = 100
    ) async throws -> [[String: Any]] {
        var params: [String: Any] = ["category_id": categoryID, "limit": limit]
        if let kind { params["kind"] = kind }
        let reply = try await call(method: "category_items", params: params)
        return reply["items"] as? [[String: Any]] ?? []
    }

    func folders() async throws -> [MailFolder] {
        OlSyncMailProtocol.folders(from: try await call(method: "folders"))
    }

    func search(query: String, limit: Int, offset: Int = 0) async throws -> [[String: Any]] {
        let ok = try await call(
            method: "search",
            params: [
                "query": query,
                "limit": limit,
                "offset": offset,
                "sort": "date",
                "snippets": false,
                "total": false,
            ]
        )
        return (ok["hits"] as? [[String: Any]]) ?? []
    }

    func events(
        since: Int64,
        until: Int64,
        account: String?,
        calendar: String?,
        limit: Int = 10_000
    ) async throws -> [[String: Any]] {
        var params: [String: Any] = [
            "query": "",
            "since": since,
            "until": until,
            "limit": limit,
            "offset": 0,
            "sort": "oldest",
        ]
        if let account { params["account"] = account }
        if let calendar { params["calendar"] = calendar }
        let ok = try await call(method: "events", params: params)
        return ok["hits"] as? [[String: Any]] ?? []
    }

    /// Starts a sync and waits for its terminal event. One job at a time, as
    /// the protocol requires; a `busy` error is surfaced rather than queued.
    func sync(
        since: Int64? = nil,
        until: Int64? = nil,
        calendar: Bool = false,
        noMail: Bool = false,
        prune: Bool = false,
        full: Bool = false
    ) async throws {
        var params: [String: Any] = [:]
        if let since { params["since"] = since }
        if let until { params["until"] = until }
        if calendar { params["calendar"] = true }
        if noMail { params["no_mail"] = true }
        if prune { params["prune"] = true }
        if full { params["full"] = true }
        let ok = try await call(method: "sync", params: params.isEmpty ? [:] : params)
        guard let job = OlSyncMailProtocol.uint64(ok["job"]) else {
            throw OlSyncMailError.failed("sync did not return a job")
        }
        let event = try await waitForJob(job)
        switch event {
        case let .jobDone(_, cancelled, selected, indexed, failed):
            PlannerLog.mail.info(
                """
                olsyncmail job done: selected \(selected, privacy: .public), \
                indexed \(indexed, privacy: .public), failed \(failed, privacy: .public), \
                cancelled \(cancelled, privacy: .public)
                """
            )
            if cancelled {
                throw OlSyncMailError.failed("Mail sync was cancelled.")
            }
        case let .jobFailed(_, message):
            throw OlSyncMailError.failed(message)
        case .progress:
            break
        }
    }

    func shutdown() {
        lock.lock()
        let process = process
        let stdin = stdin
        let pending = pending
        let jobs = jobs
        self.process = nil
        self.stdin = nil
        self.pending = [:]
        self.jobs = [:]
        self.started = false
        lock.unlock()
        OutlookSyncProgressReporter.shared.clear()
        try? stdin?.close()
        if process?.isRunning == true {
            process?.terminate()
        }
        for continuation in pending.values {
            continuation.resume(throwing: OlSyncMailError.daemonExited)
        }
        for continuation in jobs.values {
            continuation.resume(throwing: OlSyncMailError.daemonExited)
        }
    }

    // MARK: - Calls

    @discardableResult
    private func call(method: String, params: [String: Any]? = nil) async throws -> [String: Any] {
        try await ensureStarted()
        let id: UInt64 = lock.withLock {
            defer { nextID += 1 }
            return nextID
        }
        let line = try OlSyncMailProtocol.requestLine(id: id, method: method, params: params)
        let payload = try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pending[id] = continuation
            let stdin = stdin
            lock.unlock()
            guard let stdin else {
                finish(id: id, result: .failure(OlSyncMailError.daemonExited))
                return
            }
            do {
                try stdin.write(contentsOf: line)
            } catch {
                finish(id: id, result: .failure(error))
            }
        }
        let object = try JSONSerialization.jsonObject(with: payload)
        return (object as? [String: Any]) ?? [:]
    }

    private func waitForJob(_ job: UInt64) async throws -> OlSyncMailProtocol.Event {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            jobs[job] = continuation
            lock.unlock()
        }
    }

    private func ensureStarted() async throws {
        if lock.withLock({ started && process?.isRunning == true }) { return }
        try start()
    }

    private func start() throws {
        shutdown()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["daemon"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData, stderr: false)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData, stderr: true)
        }
        process.terminationHandler = { [weak self] _ in
            self?.handleTermination()
        }
        try process.run()
        lock.lock()
        self.process = process
        self.stdin = stdinPipe.fileHandleForWriting
        self.started = true
        lock.unlock()
        PlannerLog.mail.info("Started olsyncmail daemon at \(self.executable.path, privacy: .public)")
    }

    private func consume(_ data: Data, stderr: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        if stderr {
            stderrBuffer.append(data)
            let lines = takeLines(from: &stderrBuffer)
            lock.unlock()
            for line in lines where !line.isEmpty {
                PlannerLog.mail.info("olsyncmail: \(line, privacy: .public)")
            }
            return
        }
        stdoutBuffer.append(data)
        let lines = takeLines(from: &stdoutBuffer)
        lock.unlock()
        for line in lines where !line.isEmpty {
            handle(line: line)
        }
    }

    private func takeLines(from buffer: inout Data) -> [String] {
        var lines: [String] = []
        let newline = Data([0x0A])
        while let range = buffer.range(of: newline) {
            let slice = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            if let line = String(data: slice, encoding: .utf8) {
                lines.append(line)
            }
        }
        return lines
    }

    private func handle(line: String) {
        do {
            switch try OlSyncMailProtocol.decodeIncoming(line) {
            case let .response(id, result):
                finish(id: id, result: result)
            case let .event(event):
                handle(event: event)
            }
        } catch {
            PlannerLog.mail.error("olsyncmail line failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handle(event: OlSyncMailProtocol.Event) {
        switch event {
        case let .progress(job, phase, done, total):
            OutlookSyncProgressReporter.shared.update(
                OutlookSyncProgress(phase: phase, done: done, total: total)
            )
            PlannerLog.mail.debug(
                "olsyncmail \(phase, privacy: .public) \(done, privacy: .public)/\(total, privacy: .public) job \(job, privacy: .public)"
            )
        case .jobDone, .jobFailed:
            let job: UInt64 = {
                switch event {
                case let .jobDone(job, _, _, _, _): return job
                case let .jobFailed(job, _): return job
                default: return 0
                }
            }()
            OutlookSyncProgressReporter.shared.clear()
            lock.lock()
            let continuation = jobs.removeValue(forKey: job)
            lock.unlock()
            continuation?.resume(returning: event)
        }
    }

    private func finish(id: UInt64, result: Result<Data, Error>) {
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func handleTermination() {
        lock.lock()
        let pending = pending
        let jobs = jobs
        self.pending = [:]
        self.jobs = [:]
        self.started = false
        lock.unlock()
        OutlookSyncProgressReporter.shared.clear()
        for continuation in pending.values {
            continuation.resume(throwing: OlSyncMailError.daemonExited)
        }
        for continuation in jobs.values {
            continuation.resume(throwing: OlSyncMailError.daemonExited)
        }
    }
}

/// One prepared daemon/database session shared by Planner's mail and calendar
/// sources. The actor queues sync jobs because the daemon intentionally permits
/// only one writer at a time.
actor OlSyncOutlookSession {
    private let daemon: OlSyncMailDaemon
    private let databaseURL: URL
    private var ready = false
    private var preparation: Task<Void, Error>?
    private let syncQueue = OlSyncJobQueue()

    init?(databaseURL: URL = OlSyncMailProtocol.databaseURL()) {
        guard let executable = OlSyncMailDaemon.resolveExecutable() else { return nil }
        daemon = OlSyncMailDaemon(executable: executable)
        self.databaseURL = databaseURL
    }

    init(daemon: OlSyncMailDaemon, databaseURL: URL = OlSyncMailProtocol.databaseURL()) {
        self.daemon = daemon
        self.databaseURL = databaseURL
    }

    func refresh() async throws -> OlSyncJSONObject {
        try await prepare()
        return OlSyncJSONObject(value: try await daemon.refresh())
    }

    func search(query: String, limit: Int, offset: Int = 0) async throws -> [OlSyncJSONObject] {
        try await prepare()
        return try await daemon.search(query: query, limit: limit, offset: offset)
            .map(OlSyncJSONObject.init(value:))
    }

    func folders() async throws -> [MailFolder] {
        try await prepare()
        return try await daemon.folders()
    }

    func events(
        since: Int64,
        until: Int64,
        account: String?,
        calendar: String?
    ) async throws -> [OlSyncEventHit] {
        try await prepare()
        let rows = try await daemon.events(
            since: since,
            until: until,
            account: account,
            calendar: calendar
        )
        return rows.compactMap(OlSyncEventHit.init)
    }

    func message(id: Int64) async throws -> OlSyncJSONObject {
        try await prepare()
        return OlSyncJSONObject(value: try await daemon.message(id: id))
    }

    func fileURL(for attachment: MailAttachment) async throws -> URL {
        try await prepare()
        return try OlSyncAttachmentStore.fileURL(for: attachment, databaseURL: databaseURL)
    }

    func categories() async throws -> [OutlookCategory] {
        try await prepare()
        return try await daemon.categories()
    }

    func syncMail(full: Bool = false) async throws {
        let daemon = daemon
        try await enqueueSync {
            try await daemon.sync(full: full)
        }
    }

    /// Re-read every mail and event record, then drop rows Outlook no longer
    /// has. One job so the status line reports a single pass.
    func fullResync() async throws {
        let daemon = daemon
        try await enqueueSync {
            try await daemon.sync(calendar: true, prune: true, full: true)
        }
    }

    func syncEvents(in range: Range<Date>) async throws {
        let since = Int64(range.lowerBound.timeIntervalSince1970)
        let until = Int64(range.upperBound.timeIntervalSince1970)
        let daemon = daemon
        try await enqueueSync {
            try await daemon.sync(
                since: since,
                until: until,
                calendar: true,
                noMail: true,
                prune: true
            )
        }
    }

    private func prepare() async throws {
        if ready { return }
        if let preparation {
            try await preparation.value
            return
        }
        let daemon = daemon
        let databaseURL = databaseURL
        let task = Task {
            let hello = try await daemon.hello()
            let version = UInt32(OlSyncMailProtocol.int64(hello["protocol"]) ?? 0)
            guard version == OlSyncMailProtocol.version else {
                throw OlSyncMailError.protocolMismatch(version)
            }
            do {
                _ = try await daemon.open(database: databaseURL)
            } catch OlSyncMailError.schemaMismatch {
                Self.removeDatabase(at: databaseURL)
                _ = try await daemon.open(database: databaseURL)
            }
        }
        preparation = task
        do {
            try await task.value
            ready = true
            preparation = nil
        } catch {
            preparation = nil
            throw error
        }
    }

    private func enqueueSync(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        try await prepare()
        try await syncQueue.enqueue(operation)
    }

    private nonisolated static func removeDatabase(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            let file = suffix.isEmpty ? url : URL(fileURLWithPath: url.path + suffix)
            try? FileManager.default.removeItem(at: file)
        }
    }
}
