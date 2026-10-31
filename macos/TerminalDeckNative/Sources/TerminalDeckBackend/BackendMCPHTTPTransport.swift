import Foundation
@preconcurrency import Network
import TerminalDeckNativeCore

/// Loopback-only stateless MCP JSON-RPC over HTTP. A caller table, positive
/// tool grant and real handler registration live in BackendNativeMCPServer.
/// This transport creates no listener until start() is explicitly called.
final class BackendMCPHTTPTransport: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }
    struct Response: Sendable {
        let status: Int
        let body: Data
        static func empty(_ status: Int) -> Self { Self(status: status, body: Data()) }
        static func json(_ value: NativeRPCValue) -> Self {
            guard let body = try? value.encodedJSON(), body.count <= 16 * 1024 * 1024 else { return .empty(500) }
            return Self(status: 200, body: body)
        }
    }
    typealias Handler = @Sendable (Request, BackendMCPCancellation) async -> Response
    private let queue = DispatchQueue(label: "dev.terminaldeck.native.mcp-http", qos: .utility)
    private let handler: Handler
    private var listener: NWListener?
    private var peers: [UUID: Peer] = [:]
    private var starting: CheckedContinuation<Int, any Error>?

    init(handler: @escaping Handler) { self.handler = handler }

    func start() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard listener == nil, starting == nil else { throw BackendSessionFailure.invalidInput("The MCP listener is already starting.") }
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener; starting = continuation
                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            guard let port = self.listener?.port, let pending = self.starting else { return }
                            self.starting = nil; pending.resume(returning: Int(port.rawValue))
                        case .failed:
                            self.failStartup()
                        case .cancelled:
                            self.failStartup()
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        guard let self else { connection.cancel(); return }
                        guard self.peers.count < 128 else { connection.cancel(); return }
                        guard case .hostPort(let host, _) = connection.endpoint,
                              ["127.0.0.1", "::1"].contains(host.debugDescription) else { connection.cancel(); return }
                        let id = UUID()
                        let peer = Peer(connection: connection, queue: self.queue, handler: self.handler) { [weak self] in self?.peers[id] = nil }
                        self.peers[id] = peer; peer.start()
                    }
                    listener.start(queue: queue)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel(); listener = nil
            failStartup()
            let current = Array(peers.values); peers.removeAll()
            for peer in current { peer.close() }
        }
    }

    private func failStartup() {
        guard let pending = starting else { return }
        starting = nil
        listener?.cancel(); listener = nil
        pending.resume(throwing: BackendSessionFailure.missingCapability("the native loopback MCP listener"))
    }

    private final class Peer: @unchecked Sendable {
        private let connection: NWConnection
        private let queue: DispatchQueue
        private let handler: Handler
        private let onClose: @Sendable () -> Void
        private let cancellation = BackendMCPCancellation()
        private var data = Data()
        private var parsedHeaders: (method: String, path: String, headers: [String: String], bodyOffset: Int, length: Int)?
        private var closed = false
        private var dispatched = false
        private var task: Task<Void, Never>?
        private var deadline: DispatchWorkItem?

        init(connection: NWConnection, queue: DispatchQueue, handler: @escaping Handler, onClose: @escaping @Sendable () -> Void) {
            self.connection = connection; self.queue = queue; self.handler = handler; self.onClose = onClose
        }
        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.receive()
                case .failed, .cancelled: self.close()
                default: break
                }
            }
            let deadline = DispatchWorkItem { [weak self] in self?.reply(.empty(408)) }
            self.deadline = deadline
            queue.asyncAfter(deadline: .now() + .seconds(10), execute: deadline)
            connection.start(queue: queue)
        }
        func close() {
            guard !closed else { return }
            closed = true; deadline?.cancel(); deadline = nil
            cancellation.cancel(); task?.cancel(); task = nil
            connection.stateUpdateHandler = nil; connection.cancel()
            data.removeAll(); onClose()
        }
        private func receive() {
            guard !closed else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] bytes, _, complete, error in
                guard let self, !self.closed else { return }
                if let bytes, !bytes.isEmpty, !self.dispatched {
                    self.data.append(bytes)
                    self.consume()
                }
                if error != nil { self.close(); return }
                if complete {
                    // A vanished MCP client must not leave an approvable call
                    // behind. These clients keep their HTTP connection alive
                    // while awaiting the JSON reply.
                    if self.dispatched { self.close() }
                    else { self.reply(.empty(400)) }
                    return
                }
                self.receive()
            }
        }
        private func consume() {
            guard data.count <= 272 * 1024 else { reply(.empty(413)); return }
            if parsedHeaders == nil {
                guard let separator = data.range(of: Data([13, 10, 13, 10])) else {
                    if data.count > 16 * 1024 { reply(.empty(431)) }
                    return
                }
                guard separator.lowerBound <= 16 * 1024, let headerText = String(data: data[..<separator.lowerBound], encoding: .utf8) else { reply(.empty(400)); return }
                let lines = headerText.components(separatedBy: "\r\n")
                let first = (lines.first ?? "").components(separatedBy: " ")
                guard first.count == 3, first[2] == "HTTP/1.1", first[1].hasPrefix("/"), !first[1].contains("\0") else { reply(.empty(400)); return }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { reply(.empty(400)); return }
                    let name = String(line[..<colon]).lowercased()
                    let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty, name.range(of: #"^[a-z0-9!#$%&'*+.^_`|~-]+$"#, options: .regularExpression) != nil,
                          headers[name] == nil, !value.contains("\0") else { reply(.empty(400)); return }
                    headers[name] = value
                }
                guard headers["transfer-encoding"] == nil else { reply(.empty(400)); return }
                let length = Int(headers["content-length"] ?? "0")
                guard let length, length >= 0, length <= 256 * 1024 else { reply(.empty(413)); return }
                if first[0] == "POST" && headers["content-length"] == nil { reply(.empty(411)); return }
                parsedHeaders = (first[0], first[1], headers, separator.upperBound, length)
                deadline?.cancel(); deadline = nil
                let bodyDeadline = DispatchWorkItem { [weak self] in self?.reply(.empty(408)) }
                deadline = bodyDeadline
                queue.asyncAfter(deadline: .now() + .seconds(300), execute: bodyDeadline)
            }
            guard let parsedHeaders, data.count >= parsedHeaders.bodyOffset + parsedHeaders.length else { return }
            guard data.count == parsedHeaders.bodyOffset + parsedHeaders.length else { reply(.empty(400)); return }
            dispatched = true
            deadline?.cancel()
            let request = Request(method: parsedHeaders.method, path: parsedHeaders.path, headers: parsedHeaders.headers,
                body: Data(data[parsedHeaders.bodyOffset...]))
            data.removeAll()
            // The largest source project MCP call allows 900 seconds. Revoking
            // its caller or closing this connection cancels it immediately.
            let deadline = DispatchWorkItem { [weak self] in
                self?.cancellation.cancel(); self?.task?.cancel(); self?.reply(.empty(504))
            }
            self.deadline = deadline
            queue.asyncAfter(deadline: .now() + .seconds(900), execute: deadline)
            task = Task { [weak self] in
                guard let self else { return }
                let result = await self.handler(request, self.cancellation)
                self.queue.async { [weak self] in self?.reply(result) }
            }
        }
        private func reply(_ response: Response) {
            guard !closed else { return }
            deadline?.cancel(); deadline = nil
            let reason: String
            switch response.status {
            case 200: reason = "OK"
            case 202: reason = "Accepted"
            case 400: reason = "Bad Request"
            case 401: reason = "Unauthorized"
            case 403: reason = "Forbidden"
            case 405: reason = "Method Not Allowed"
            case 408: reason = "Request Timeout"
            case 411: reason = "Length Required"
            case 413: reason = "Content Too Large"
            case 431: reason = "Request Header Fields Too Large"
            case 503: reason = "Service Unavailable"
            case 504: reason = "Gateway Timeout"
            default: reason = "Internal Server Error"
            }
            let head = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
            connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { [weak self] _ in self?.close() })
        }
    }
}
