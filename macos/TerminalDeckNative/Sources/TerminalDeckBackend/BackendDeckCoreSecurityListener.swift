import Foundation
@preconcurrency import Network
import TerminalDeckNativeCore

/// Production factory default. Tests replace only this transport boundary;
/// the actual authentication, framing and MCP gate remain the same services.
public struct BackendDeckCoreSecurityNativeListening: BackendDeckCoreSecurityListening {
    private let listener: BackendDeckCoreSecurityListener
    public init(handler: @escaping BackendDeckCoreSecurityHTTPHandler) { listener = BackendDeckCoreSecurityListener(handler: handler) }
    public func start(port: Int) async throws -> Int { try await listener.start(port: port) }
    public func stop() async { listener.stop() }
}

struct BackendDeckCoreSecurityHTTPParseFailure: Error { let status: Int }

/// Incremental framing counts decoded body bytes, rather than chunk framing,
/// against the exact 256 KiB cap. Header/trailer buffers remain separately bounded.
struct BackendDeckCoreSecurityHTTPParser {
    private var pending = Data()
    private var method: String?
    private var path = ""
    private var headers: [String: String] = [:]
    private var length = 0
    private var chunked = false
    private var chunkRemaining: Int?
    private var needsChunkCRLF = false
    private var trailers = false
    private var trailerBytes = 0
    private var body = Data()
    private var completed = false
    var hasHeaders: Bool { method != nil }
    mutating func receive(_ bytes: Data, endOfStream: Bool = false) throws -> BackendDeckCoreSecurityHTTPRequest? {
        guard !completed else { if bytes.isEmpty { return nil }; throw BackendDeckCoreSecurityHTTPParseFailure(status: 400) }
        pending.append(bytes)
        if method == nil {
            guard let separator = pending.range(of: Data([13, 10, 13, 10])) else {
                if pending.count > 16 * 1024 { throw BackendDeckCoreSecurityHTTPParseFailure(status: 431) }
                if endOfStream { throw BackendDeckCoreSecurityHTTPParseFailure(status: 400) }; return nil
            }
            guard separator.lowerBound <= 16 * 1024, let text = String(data: pending[..<separator.lowerBound], encoding: .utf8) else { throw BackendDeckCoreSecurityHTTPParseFailure(status: 400) }
            let lines = text.components(separatedBy: "\r\n"); let first = (lines.first ?? "").components(separatedBy: " ")
            guard first.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(first[2]), !first[0].isEmpty, first[1].hasPrefix("/"), !first[1].contains("\0") else { throw BackendDeckCoreSecurityHTTPParseFailure(status: 400) }
            for line in lines.dropFirst() {
                let (name, value) = try Self.header(line)
                guard headers[name] == nil else { throw BackendDeckCoreSecurityHTTPParseFailure(status: 400) }; headers[name] = value
            }
            if let encoding = headers["transfer-encoding"] {
                guard encoding.lowercased() == "chunked", headers["content-length"] == nil else { throw BackendDeckCoreSecurityHTTPParseFailure(status: 400) }; chunked = true
            } else if let raw = headers["content-length"] {
                guard raw.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil, let size = Int(raw) else { throw BackendDeckCoreSecurityHTTPParseFailure(status: 400) }
                guard size <= 256 * 1024 else { throw BackendDeckCoreSecurityHTTPParseFailure(status: 413) }; length = size
            }
            method = first[0]; path = first[1]; pending = Data(pending[separator.upperBound...])
        }
        if !chunked {
            guard pending.count <= length else { throw BackendDeckCoreSecurityHTTPParseFailure(status: 400) }
            guard pending.count == length else { if endOfStream { throw BackendDeckCoreSecurityHTTPParseFailure(status: 400) }; return nil }
            body = pending; pending.removeAll(); return finish()
        }
        while true {
            if trailers {
                guard let line = takeLine(maximum: 16 * 1024) else {
                    if pending.count + trailerBytes > 16 * 1024 { throw BackendDeckCoreSecurityHTTPParseFailure(status: 431) }
                    if endOfStream { throw BackendDeckCoreSecurityHTTPParseFailure(status: 400) }; return nil
                }
                trailerBytes += line.count + 2
                guard trailerBytes <= 16 * 1024 else { throw BackendDeckCoreSecurityHTTPParseFailure(status: 431) }
                if line.isEmpty { guard pending.isEmpty else { throw BackendDeckCoreSecurityHTTPParseFailure(status: 400) }; return finish() }
                guard let text = String(data: line, encoding: .utf8) else { throw BackendDeckCoreSecurityHTTPParseFailure(status: 400) }
                _ = try Self.header(text); continue
            }
            if needsChunkCRLF {
                guard pending.count >= 2 else { if endOfStream { throw BackendDeckCoreSecurityHTTPParseFailure(status: 400) }; return nil }
                guard pending.prefix(2) == Data([13, 10]) else { throw BackendDeckCoreSecurityHTTPParseFailure(status: 400) }
                pending = Data(pending.dropFirst(2)); needsChunkCRLF = false; chunkRemaining = nil
            }
            if chunkRemaining == nil {
                guard let line = takeLine(maximum: 8 * 1024) else {
                    if pending.count > 8 * 1024 || endOfStream { throw BackendDeckCoreSecurityHTTPParseFailure(status: 400) }; return nil
                }
                guard let text = String(data: line, encoding: .utf8), let raw = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first,
                      !raw.isEmpty, raw.range(of: #"^[0-9a-fA-F]+$"#, options: .regularExpression) != nil, let size = Int(raw, radix: 16) else { throw BackendDeckCoreSecurityHTTPParseFailure(status: 400) }
                guard size <= 256 * 1024 - body.count else { throw BackendDeckCoreSecurityHTTPParseFailure(status: 413) }
                if size == 0 { trailers = true; continue }; chunkRemaining = size
            }
            let amount = min(chunkRemaining ?? 0, pending.count)
            if amount > 0 { body.append(pending.prefix(amount)); pending = Data(pending.dropFirst(amount)); chunkRemaining = (chunkRemaining ?? 0) - amount }
            if chunkRemaining == 0 { needsChunkCRLF = true; continue }
            if endOfStream { throw BackendDeckCoreSecurityHTTPParseFailure(status: 400) }; return nil
        }
    }
    private mutating func takeLine(maximum: Int) -> Data? {
        guard let end = pending.range(of: Data([13, 10])), end.lowerBound <= maximum else { return nil }
        let line = Data(pending[..<end.lowerBound]); pending = Data(pending[end.upperBound...]); return line
    }
    private mutating func finish() -> BackendDeckCoreSecurityHTTPRequest {
        completed = true; return .init(method: method ?? "", path: path, headers: headers, body: body)
    }
    private static func header(_ line: String) throws -> (String, String) {
        guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { throw BackendDeckCoreSecurityHTTPParseFailure(status: 400) }
        let name = String(line[..<colon]).lowercased(); let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.range(of: #"^[a-z0-9!#$%&'*+.^_`|~-]+$"#, options: .regularExpression) != nil, !value.contains("\0") else { throw BackendDeckCoreSecurityHTTPParseFailure(status: 400) }
        return (name, value)
    }
}

/// Source-compatible companion to BackendMCPHTTPTransport. The foundation is
/// private/final, so an owned adaptation preserves its connection cancellation
/// while adding fixed/preferred binds and streamed chunked HTTP request bodies.
final class BackendDeckCoreSecurityListener: @unchecked Sendable {
    typealias Request = BackendDeckCoreSecurityHTTPRequest
    typealias Response = BackendDeckCoreSecurityHTTPResponse
    typealias Handler = @Sendable (Request, BackendMCPCancellation) async -> Response
    private let queue = DispatchQueue(label: "dev.terminaldeck.native.deck-core-http", qos: .utility)
    private let handler: Handler
    private var listener: NWListener?
    private var peers: [UUID: Peer] = [:]
    private var starting: CheckedContinuation<Int, any Error>?

    init(handler: @escaping Handler) { self.handler = handler }

    func start(port: Int) async throws -> Int {
        guard (0...65_535).contains(port) else { throw BackendSessionFailure.invalidInput("The requested MCP port is invalid.") }
        return try await startRequested(port: port)
    }

    private func startRequested(port: Int) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard listener == nil, starting == nil else { throw BackendSessionFailure.invalidInput("The MCP listener is already starting.") }
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port == 0 ? .any : NWEndpoint.Port(rawValue: UInt16(port))!)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener; starting = continuation
                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            guard let port = self.listener?.port, let pending = self.starting else { return }
                            self.starting = nil; pending.resume(returning: Int(port.rawValue))
                        case .failed(let error):
                            self.failStartup(error)
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

    private func failStartup(_ error: Error? = nil) {
        guard let pending = starting else { return }
        starting = nil
        listener?.cancel(); listener = nil
        pending.resume(throwing: error ?? BackendSessionFailure.missingCapability("the native loopback MCP listener"))
    }

    private final class Peer: @unchecked Sendable {
        private let connection: NWConnection
        private let queue: DispatchQueue
        private let handler: Handler
        private let onClose: @Sendable () -> Void
        private let cancellation = BackendMCPCancellation()
        private var parser = BackendDeckCoreSecurityHTTPParser()
        private var receivedHeaders = false
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
            onClose()
        }
        private func receive() {
            guard !closed else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] bytes, _, complete, error in
                guard let self, !self.closed else { return }
                if let bytes, !bytes.isEmpty, !self.dispatched { self.consume(bytes) }
                if error != nil { self.close(); return }
                if complete {
                    // A vanished MCP client must not leave an approvable call
                    // behind. These clients keep their HTTP connection alive
                    // while awaiting the JSON reply.
                    if self.dispatched { self.close() }
                    else { self.consume(Data(), endOfStream: true) }
                    return
                }
                self.receive()
            }
        }
        private func consume(_ bytes: Data, endOfStream: Bool = false) {
            let request: Request?
            do { request = try parser.receive(bytes, endOfStream: endOfStream) }
            catch let error as BackendDeckCoreSecurityHTTPParseFailure { reply(.empty(error.status)); return }
            catch { reply(.empty(400)); return }
            if parser.hasHeaders && !receivedHeaders {
                receivedHeaders = true; deadline?.cancel()
                let bodyDeadline = DispatchWorkItem { [weak self] in self?.reply(.empty(408)) }
                deadline = bodyDeadline; queue.asyncAfter(deadline: .now() + .seconds(300), execute: bodyDeadline)
            }
            guard let request else { return }
            dispatched = true
            deadline?.cancel()
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
            case 404: reason = "Not Found"
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
