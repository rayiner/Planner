import Foundation

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

    /// Starts a sync and waits for its terminal event. One job at a time, as
    /// the protocol requires; a `busy` error is surfaced rather than queued.
    func sync(since: Int64?) async throws {
        var params: [String: Any] = [:]
        if let since {
            params["since"] = since
        }
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
        for continuation in pending.values {
            continuation.resume(throwing: OlSyncMailError.daemonExited)
        }
        for continuation in jobs.values {
            continuation.resume(throwing: OlSyncMailError.daemonExited)
        }
    }
}
