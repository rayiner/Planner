import Foundation
import MCP

/// The app's MCP server: an HTTP endpoint on loopback that lets an agent search
/// and read mail, list mail folders, save queries, manage task folders and
/// tasks, and open a task or a message in a small window.
///
/// The transport is the SDK's stateless one, and the server above it is stateless
/// too: each request gets its own `Server`, handled and torn down. Nothing is
/// carried between requests, so any number of clients can connect, disconnect, and
/// reconnect without a session to negotiate or lose — which is right for a server
/// whose entire state is the app it is attached to. The mail index and the current
/// selection are the state, and they outlive every client.
///
/// The listener binds to 127.0.0.1 only, so nothing off this machine can reach it.
@MainActor
final class MCPServerController {
    static let shared = MCPServerController()

    /// The endpoint an MCP client connects to. `nonisolated` so the request router,
    /// which runs off the main actor, can compare against it.
    nonisolated static let endpointPath = "/mcp"

    static let enabledDefaultsKey = "mcpServerEnabled"
    static let portDefaultsKey = "mcpServerPort"
    /// Distinct from LawPDF Viewer's 8756, so both apps can listen at once.
    static let defaultPort = 8757

    enum Status: Equatable {
        case off
        case starting
        case running(port: Int)
        case failed(String)
    }

    private(set) var status: Status = .off

    private var httpServer: LoopbackHTTPServer?
    private var lifecycleTask: Task<Void, Never>?

    /// Bumped by every start and stop. Binding a socket is not cancellable, so a
    /// start that is called off while it is still binding checks this before
    /// installing its listener — otherwise turning the server off during launch
    /// would leave a listener nobody holds.
    private var generation = 0

    private init() {}

    // MARK: - Settings

    /// On unless it has been turned off. Pairing with an agent is the point of the
    /// server, so it is running whenever the app is.
    var isEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.enabledDefaultsKey) != nil else { return true }
        return defaults.bool(forKey: Self.enabledDefaultsKey)
    }

    /// A fixed port, not an ephemeral one: a client's configuration names a URL, so
    /// the URL has to be the same on every launch. Change it with the
    /// `mcpServerPort` user default.
    var port: Int {
        let stored = UserDefaults.standard.integer(forKey: Self.portDefaultsKey)
        return (1...65535).contains(stored) ? stored : Self.defaultPort
    }

    var endpointURL: URL? {
        guard case .running(let port) = status else { return nil }
        return URL(string: "http://127.0.0.1:\(port)\(Self.endpointPath)")
    }

    /// The stable URL clients should be configured with, whether or not the
    /// listener has finished starting yet.
    var configuredEndpointURL: URL {
        URL(string: "http://127.0.0.1:\(port)\(Self.endpointPath)")!
    }

    /// One line for the Planner menu.
    var statusSummary: String {
        switch status {
        case .off:
            return "MCP server off"
        case .starting:
            return "MCP server starting…"
        case .running(let port):
            return "MCP server on http://127.0.0.1:\(port)\(Self.endpointPath)"
        case .failed(let message):
            return "MCP server failed: \(message)"
        }
    }

    // MARK: - Lifecycle

    /// Called at launch. Does nothing when the server has been turned off.
    func startIfEnabled() {
        guard isEnabled else { return }
        start()
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey)
        if enabled {
            start()
        } else {
            stop()
        }
    }

    func start() {
        guard status == .off || isFailed else { return }
        generation += 1
        status = .starting

        let port = self.port
        let generation = self.generation
        lifecycleTask = Task { [weak self] in
            let http = LoopbackHTTPServer { request in await Self.respond(to: request) }
            do {
                try await http.start(port: port)
            } catch {
                let message =
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    guard let self, self.generation == generation else { return }
                    self.status = .failed(message)
                }
                return
            }
            await MainActor.run {
                guard let self, self.generation == generation else {
                    // Turned off while the socket was binding: close what we opened.
                    Task { await http.stop() }
                    return
                }
                self.httpServer = http
                self.status = .running(port: port)
            }
        }
    }

    func stop() {
        generation += 1
        lifecycleTask?.cancel()
        lifecycleTask = nil

        let http = httpServer
        httpServer = nil
        status = .off

        Task { await http?.stop() }
    }

    /// Called at quit, so the port is free for the next launch.
    func shutdown() {
        stop()
    }

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    // MARK: - Requests

    /// Answers one HTTP request with a server built for it alone.
    ///
    /// Building a `Server` per request is what makes this genuinely stateless: the
    /// SDK's `Server` accepts `initialize` once, so a shared one would refuse the
    /// second client of the day — and every client sends `initialize` when it
    /// connects. A fresh one costs an actor and two closures, which is nothing
    /// beside the work the tools themselves do.
    private nonisolated static func respond(to request: HTTPRequest) async -> HTTPResponse {
        // One endpoint. Anything else is a client pointed at the wrong URL, and
        // saying so beats a silent hang.
        guard request.path == nil || request.path == endpointPath else {
            return .error(
                statusCode: 404,
                .invalidRequest("Not Found. This server speaks MCP at \(endpointPath)."))
        }

        let transport = StatelessHTTPServerTransport()
        let server = Server(
            name: "planner",
            version: appVersion,
            title: "Planner",
            instructions: MCPTools.instructions,
            capabilities: .init(tools: .init(listChanged: false)))

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: MCPTools.all)
        }
        await server.withMethodHandler(CallTool.self) { parameters in
            await MCPTools.call(parameters)
        }

        do {
            try await server.start(transport: transport)
        } catch {
            return .error(
                statusCode: 500, .internalError("Could not start the MCP server: \(error)"))
        }

        let response = await transport.handleRequest(request)
        await server.stop()
        return response
    }

    private nonisolated static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }
}
