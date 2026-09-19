import Foundation
import MCP
import Network

/// A minimal HTTP/1.1 server bound to the loopback interface.
///
/// The MCP SDK's `StatelessHTTPServerTransport` is framework-agnostic: it turns an
/// `HTTPRequest` into an `HTTPResponse` and leaves the socket to the host app. This
/// is that socket — just enough HTTP for one JSON endpoint on 127.0.0.1: a request
/// line, headers, a `Content-Length` body, and keep-alive. Chunked bodies, TLS, and
/// everything else an internet-facing server needs are deliberately absent; nothing
/// off this machine can reach it.
actor LoopbackHTTPServer {
    /// Turns one parsed request into the response to write back.
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    enum StartError: LocalizedError {
        case invalidPort(Int)
        case listenFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidPort(let port):
                return "\(port) is not a usable TCP port."
            case .listenFailed(let message):
                return message
            }
        }
    }

    /// Refuses a request whose head or body is implausible for a JSON-RPC call,
    /// rather than buffering it.
    private static let maxRequestBytes = 8 * 1024 * 1024
    private static let maxHeadBytes = 64 * 1024

    private let handler: Handler
    private let queue = DispatchQueue(label: "com.rihscb.Planner.mcp.http")

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    // MARK: - Lifecycle

    /// Binds to `127.0.0.1:port` and returns once the listener is ready.
    func start(port: Int) async throws {
        guard let port = UInt16(exactly: port), let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw StartError.invalidPort(port)
        }
        stop()

        let parameters = NWParameters.tcp
        // Binding the local endpoint (rather than passing `on:`) is what keeps the
        // socket off every other interface: loopback only, never the network.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        // A listener left in TIME_WAIT by a previous run should not block a restart.
        parameters.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw StartError.listenFailed(error.localizedDescription)
        }
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            Task { await self.accept(connection) }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            // NWListener reports readiness and failure through the same handler and
            // may report several states; `resumed` keeps the continuation single-use.
            let resumed = OneShot()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    // `.waiting` on a bound port means the address is unavailable —
                    // in practice, something else already holds it. Never retry
                    // silently: a port nobody can predict is no use to a client.
                    if resumed.claim() {
                        continuation.resume(
                            throwing: StartError.listenFailed(error.localizedDescription))
                    }
                case .cancelled:
                    if resumed.claim() {
                        continuation.resume(throwing: StartError.listenFailed("Listener cancelled"))
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Drops the listener and every open connection. Safe to call when stopped.
    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil

        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) async {
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue: queue)

        await serve(connection)

        connection.cancel()
        connections[ObjectIdentifier(connection)] = nil
    }

    /// Reads requests from one connection until the client hangs up, the client
    /// asks to close, or the exchange goes wrong.
    private func serve(_ connection: NWConnection) async {
        var buffer = Data()

        while true {
            let parsed: ParsedRequest?
            do {
                parsed = try Self.parseRequest(from: buffer)
            } catch let error as ParseError {
                try? await send(connection, Self.serialize(.error(statusCode: error.statusCode,
                    .invalidRequest(error.message)), keepAlive: false))
                return
            } catch {
                return
            }

            guard let parsed else {
                guard buffer.count <= Self.maxRequestBytes else {
                    try? await send(connection, Self.serialize(
                        .error(statusCode: 413, .invalidRequest("Payload Too Large")),
                        keepAlive: false))
                    return
                }
                guard let chunk = try? await receive(connection), !chunk.isEmpty else {
                    return  // clean EOF, or the connection went away
                }
                buffer.append(chunk)
                continue
            }

            buffer.removeFirst(parsed.byteCount)

            let response = await handler(parsed.request)
            guard (try? await send(connection, Self.serialize(response, keepAlive: parsed.keepAlive)))
                != nil
            else { return }

            guard parsed.keepAlive else { return }
        }
    }

    private func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: Data())  // EOF
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
        }
    }

    // MARK: - Parsing

    private struct ParsedRequest {
        let request: HTTPRequest
        /// Bytes of `buffer` this request occupied, head and body together.
        let byteCount: Int
        let keepAlive: Bool
    }

    private struct ParseError: Error {
        let statusCode: Int
        let message: String
    }

    /// Returns nil while the buffer holds less than one complete request.
    private static func parseRequest(from buffer: Data) throws -> ParsedRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headEnd = buffer.firstRange(of: separator) else {
            if buffer.count > maxHeadBytes {
                throw ParseError(statusCode: 431, message: "Request header fields too large")
            }
            return nil
        }

        let headData = buffer[buffer.startIndex..<headEnd.lowerBound]
        guard let head = String(data: headData, encoding: .utf8) else {
            throw ParseError(statusCode: 400, message: "Request head is not valid UTF-8")
        }

        var lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw ParseError(statusCode: 400, message: "Empty request")
        }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            throw ParseError(statusCode: 400, message: "Malformed request line")
        }
        let method = String(parts[0])
        let target = String(parts[1])
        let version = parts.count > 2 ? String(parts[2]) : "HTTP/1.1"

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                throw ParseError(statusCode: 400, message: "Malformed header line")
            }
            let name = String(line[line.startIndex..<colon])
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            // Repeated headers join with a comma, as HTTP defines.
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        func header(_ name: String) -> String? {
            let wanted = name.lowercased()
            return headers.first { $0.key.lowercased() == wanted }?.value
        }

        if header("Transfer-Encoding") != nil {
            // No chunked decoder here; every MCP client sends Content-Length.
            throw ParseError(statusCode: 411, message: "Transfer-Encoding is not supported")
        }

        var bodyLength = 0
        if let raw = header("Content-Length") {
            guard let length = Int(raw.trimmingCharacters(in: .whitespaces)), length >= 0 else {
                throw ParseError(statusCode: 400, message: "Malformed Content-Length")
            }
            guard length <= maxRequestBytes else {
                throw ParseError(statusCode: 413, message: "Payload Too Large")
            }
            bodyLength = length
        }

        let bodyStart = headEnd.upperBound
        let total = buffer.distance(from: buffer.startIndex, to: bodyStart) + bodyLength
        guard buffer.count >= total else { return nil }

        let body =
            bodyLength > 0
            ? Data(buffer[bodyStart..<buffer.index(bodyStart, offsetBy: bodyLength)]) : nil

        // HTTP/1.1 keeps the connection open unless asked not to; HTTP/1.0 is the
        // other way round.
        let connectionHeader = header("Connection")?.lowercased() ?? ""
        let keepAlive =
            version.hasSuffix("1.0")
            ? connectionHeader.contains("keep-alive") : !connectionHeader.contains("close")

        return ParsedRequest(
            request: HTTPRequest(
                method: method, headers: headers, body: body, path: path(of: target)),
            byteCount: total,
            keepAlive: keepAlive)
    }

    /// The path of a request target, with any query string dropped.
    private static func path(of target: String) -> String {
        guard let questionMark = target.firstIndex(of: "?") else { return target }
        return String(target[target.startIndex..<questionMark])
    }

    // MARK: - Serializing

    private static func serialize(_ response: HTTPResponse, keepAlive: Bool) -> Data {
        // `.stream` is an SSE response, which only the stateful transport produces;
        // an empty body is the honest rendering of it here.
        let body = response.bodyData ?? Data()

        var head = "HTTP/1.1 \(response.statusCode) \(reasonPhrase(response.statusCode))\r\n"
        for (name, value) in response.headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"

        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    private static func reasonPhrase(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 406: return "Not Acceptable"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 421: return "Misdirected Request"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}

/// A one-shot latch for callback-based APIs that may fire more than once while a
/// continuation may be resumed only once.
///
/// `nonisolated` because NWListener callbacks arrive off the main actor, and
/// Planner's default isolation is MainActor.
nonisolated private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
