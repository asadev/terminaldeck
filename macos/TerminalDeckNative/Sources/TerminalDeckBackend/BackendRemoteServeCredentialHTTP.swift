import Foundation
@preconcurrency import Network
import TerminalDeckNativeCore

/// Dedicated text HTTP endpoint for the existing git helper; never binds LAN.
/// Construction does no IO; start() and stop() explicitly own the listener.
public final class BackendRemoteServeCredentialHTTP: @unchecked Sendable {
    public struct Request: Sendable {
        public let method: String; public let path: String
        public let headers: [String: String]; public let body: Data
    }
    public struct Response: Sendable {
        public let status: Int; public let body: Data; public let nosniff: Bool
        public init(status: Int, body: String, nosniff: Bool = false) {
            self.status = status; self.nosniff = nosniff
            self.body = Data((body.hasSuffix("\n") ? body : body + "\n").utf8)
        }
        static func empty(_ status: Int) -> Self {
            .init(status: status, body: status == 413 ? "that request was too large" : "that did not work")
        }
    }
    public typealias Handler = @Sendable (Request) async -> Response
    public typealias HeaderHandler = @Sendable (String, String, [String: String]) async -> Response?
    private let queue = DispatchQueue(label: "dev.terminaldeck.native.credential-http", qos: .utility)
    private let handler: Handler
    private let headerHandler: HeaderHandler
    private var listener: NWListener?
    private var peers: [UUID: Peer] = [:]
    private var starting: CheckedContinuation<Int, any Error>?

    public init(headerHandler: @escaping HeaderHandler = { _, _, _ in nil }, handler: @escaping Handler) {
        self.headerHandler = headerHandler; self.handler = handler
    }

    public func start() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard listener == nil, starting == nil else { throw BackendSessionFailure.invalidInput("The credential listener is already starting.") }
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
                        let peer = Peer(connection: connection, queue: self.queue, headerHandler: self.headerHandler, handler: self.handler) { [weak self] in self?.peers[id] = nil }
                        self.peers[id] = peer; peer.start()
                    }
                    listener.start(queue: queue)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    public func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                listener?.cancel(); listener = nil
                failStartup()
                let current = Array(peers.values); peers.removeAll()
                for peer in current { peer.close() }
                continuation.resume()
            }
        }
    }

    private func failStartup() {
        guard let pending = starting else { return }
        starting = nil
        listener?.cancel(); listener = nil
        pending.resume(throwing: BackendSessionFailure.missingCapability("the native loopback credential listener"))
    }

    private final class Peer: @unchecked Sendable {
        private let connection: NWConnection
        private let queue: DispatchQueue
        private let handler: Handler
        private let headerHandler: HeaderHandler
        private let onClose: @Sendable () -> Void
        private var data = Data()
        private var parsedHeaders: (method: String, path: String, headers: [String: String], bodyOffset: Int, length: Int)?
        private var closed = false
        private var dispatched = false
        private var headersAuthorized = false
        private var task: Task<Void, Never>?
        private var deadline: DispatchWorkItem?

        init(connection: NWConnection, queue: DispatchQueue, headerHandler: @escaping HeaderHandler, handler: @escaping Handler, onClose: @escaping @Sendable () -> Void) {
            self.connection = connection; self.queue = queue; self.handler = handler; self.onClose = onClose
            self.headerHandler = headerHandler
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
            task?.cancel(); task = nil
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
                    // A vanished git helper must not hold a response or credential task.
                    if self.dispatched { self.close() }
                    else { self.reply(.empty(400)) }
                    return
                }
                self.receive()
            }
        }
        private func consume() {
            guard data.count <= 48 * 1024 else { reply(.empty(413)); return }
            if parsedHeaders == nil {
                guard let separator = data.range(of: Data([13, 10, 13, 10])) else {
                    if data.count > 16 * 1024 { reply(.empty(431)) }
                    return
                }
                guard separator.lowerBound <= 16 * 1024, let headerText = String(data: data[..<separator.lowerBound], encoding: .utf8) else { reply(.empty(400)); return }
                let lines = headerText.components(separatedBy: "\r\n")
                let first = (lines.first ?? "").components(separatedBy: " ")
                guard first.count == 3, ["HTTP/1.1", "HTTP/1.0"].contains(first[2]), first[1].hasPrefix("/"), !first[1].contains("\0") else { reply(.empty(400)); return }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { reply(.empty(400)); return }
                    let name = String(line[..<colon]).lowercased()
                    let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty, name.range(of: #"^[a-z0-9!#$%&'*+.^_`|~-]+$"#, options: .regularExpression) != nil,
                          headers[name] == nil, !value.contains("\0") else { reply(.empty(400)); return }
                    headers[name] = value
                }
                let chunked = headers["transfer-encoding"]?.lowercased() == "chunked"
                guard headers["transfer-encoding"] == nil || chunked,
                      !(chunked && headers["content-length"] != nil) else { reply(.empty(400)); return }
                let length = chunked ? -1 : Int(headers["content-length"] ?? "0")
                guard let length, chunked || length >= 0 else { reply(.empty(400)); return }
                parsedHeaders = (first[0], first[1], headers, separator.upperBound, length)
                deadline?.cancel(); deadline = nil
                let bodyDeadline = DispatchWorkItem { [weak self] in self?.reply(.empty(408)) }
                deadline = bodyDeadline
                queue.asyncAfter(deadline: .now() + .milliseconds(94_000), execute: bodyDeadline)
                let method = first[0], path = first[1], parsed = headers
                task = Task { [weak self] in
                    guard let self else { return }
                    let failure = await self.headerHandler(method, path, parsed)
                    self.queue.async { [weak self] in
                        guard let self, !self.closed else { return }
                        if let failure { self.reply(failure); return }
                        self.headersAuthorized = true; self.consume()
                    }
                }
            }
            guard let parsedHeaders, headersAuthorized else { return }
            guard parsedHeaders.length <= 16 * 1024 else { reply(.empty(413)); return }
            let body: Data
            if parsedHeaders.length == -1 {
                do { guard let decoded = try chunkedBody(Data(data[parsedHeaders.bodyOffset...])) else { return }; body = decoded }
                catch { reply(.empty(413)); return }
            } else {
                guard data.count >= parsedHeaders.bodyOffset + parsedHeaders.length else { return }
                guard data.count == parsedHeaders.bodyOffset + parsedHeaders.length else { reply(.empty(400)); return }
                body = Data(data[parsedHeaders.bodyOffset...])
            }
            dispatched = true
            deadline?.cancel()
            let request = Request(method: parsedHeaders.method, path: parsedHeaders.path, headers: parsedHeaders.headers,
                body: body)
            data.removeAll()
            // Source whole-request bound: decide 60000 + reach 4000 + 30000 ms.
            let deadline = DispatchWorkItem { [weak self] in
                self?.task?.cancel(); self?.reply(.empty(504))
            }
            self.deadline = deadline
            queue.asyncAfter(deadline: .now() + .milliseconds(94_000), execute: deadline)
            task = Task { [weak self] in
                guard let self else { return }
                let result = await self.handler(request)
                self.queue.async { [weak self] in self?.reply(result) }
            }
        }
        private func chunkedBody(_ bytes: Data) throws -> Data? {
            var at = 0, output = Data()
            let crlf = Data([13, 10])
            while true {
                guard let line = bytes.range(of: crlf, in: at..<bytes.count) else { return nil }
                let token = String(decoding: bytes[at..<line.lowerBound], as: UTF8.self).components(separatedBy: ";")[0]
                guard !token.isEmpty, token.range(of: "^[0-9a-fA-F]+$", options: .regularExpression) != nil,
                      let count = Int(token, radix: 16), count <= 16 * 1024 - output.count else { throw NativeRPCError.malformed("Oversized credential body") }
                at = line.upperBound
                if count == 0 {
                    if bytes.count >= at + 2, bytes[at..<at + 2] == crlf { return output }
                    guard bytes.range(of: Data([13,10,13,10]), in: at..<bytes.count) != nil else { return nil }
                    return output
                }
                guard bytes.count >= at + count + 2 else { return nil }
                guard bytes[at + count..<at + count + 2] == crlf else { throw NativeRPCError.malformed("Malformed credential chunk") }
                output.append(bytes[at..<at + count]); at += count + 2
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
            let head = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n" + (response.nosniff ? "X-Content-Type-Options: nosniff\r\n" : "") + "\r\n"
            connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { [weak self] _ in self?.close() })
        }
    }
}
