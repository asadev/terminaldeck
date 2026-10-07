import Foundation
@preconcurrency import Network
import CryptoKit
import TerminalDeckNativeCore

/// Source direct path: loopback HTTP behind Tailscale Serve's tailnet-only TLS
/// proxy. This listener never exposes an unencrypted socket on a LAN address.
public actor BackendRemoteHostListener {
    private let host: BackendRemoteHost
    private let allowedHosts: Set<String>
    private let webRoot: URL?
    private let queue = DispatchQueue(label: "native.remote.listener", qos: .userInitiated)
    private var listener: NWListener?
    private var listenerToken: UUID?
    private var boundPort: UInt16?
    private var failureReason: String?
    private var ready: CheckedContinuation<UInt16, Error>?
    private var starting: (id: UUID, port: UInt16, task: Task<UInt16, Error>)?
    private var stopping: (id: UUID, task: Task<Void, Never>)?
    private var peers: [UUID: BackendRemoteHostWebSocket] = [:]
    public init(host: BackendRemoteHost, allowedHosts: [String], webRoot: URL?) {
        self.host = host; self.allowedHosts = Set(allowedHosts.map { $0.lowercased() }); self.webRoot = webRoot
    }
    public func start(port: UInt16 = 8443) async throws -> UInt16 {
        if let stopping { await stopping.task.value; return try await start(port: port) }
        if let starting {
            guard starting.port == port else { throw NativeRPCError.invalidArguments("The direct listener is starting on a different port") }
            return try await starting.task.value
        }
        if let boundPort, listener != nil {
            guard port == 0 || port == boundPort else { throw NativeRPCError.invalidArguments("The direct listener is already open on a different port") }
            return boundPort
        }
        guard !allowedHosts.isEmpty else { throw NativeRPCError.invalidArguments("The direct remote listener requires explicit hosts and a port") }
        let id = UUID(), task = Task { try await self.bind(port: port, token: id) }
        starting = (id, port, task)
        defer { if starting?.id == id { starting = nil } }
        return try await task.value
    }
    private func bind(port: UInt16, token: UUID) async throws -> UInt16 {
        try Task.checkCancellation()
        guard let port = NWEndpoint.Port(rawValue: port) else { throw NativeRPCError.invalidArguments("The direct listener port is invalid") }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        let value = try NWListener(using: parameters)
        listener = value; listenerToken = token; boundPort = nil; failureReason = nil
        value.stateUpdateHandler = { [weak self] state in Task { await self?.changed(state, token: token) } }
        value.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { await self.accept(connection, token: token) }
        }
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in ready = continuation; value.start(queue: queue) }
            } onCancel: { [weak self] in value.cancel(); Task { await self?.cancelBinding(token) } }
        } catch { cancelBinding(token); throw error }
    }
    private func cancelBinding(_ token: UUID) {
        guard listenerToken == token else { return }
        let value = listener; listener = nil; listenerToken = nil; boundPort = nil
        let pending = ready; ready = nil; value?.cancel(); pending?.resume(throwing: CancellationError())
    }
    public func state() -> BackendRemoteServeHostServiceListenerState { .init(listening: listener != nil && boundPort != nil, reason: failureReason) }
    private func changed(_ state: NWListener.State, token: UUID) async {
        guard listenerToken == token else { return }
        switch state {
        case .ready: if let port = listener?.port?.rawValue { boundPort = port; ready?.resume(returning: port); ready = nil }
        case .failed(let error), .waiting(let error):
            failureReason = error.localizedDescription
            let value = listener; listener = nil; listenerToken = nil; boundPort = nil
            ready?.resume(throwing: error); ready = nil; value?.cancel()
            let old = Array(peers)
            await closePeers(old.map(\.value), code: 1011, reason: "The direct listener failed.")
            for (id, _) in old { peers[id] = nil }
        case .cancelled:
            failureReason = "The direct listener stopped."
            listener = nil; listenerToken = nil; boundPort = nil
            ready?.resume(throwing: CancellationError()); ready = nil
            let old = Array(peers)
            await closePeers(old.map(\.value), code: 1001, reason: "The direct listener stopped.")
            for (id, _) in old { peers[id] = nil }
        default: break
        }
    }
    private func accept(_ connection: NWConnection, token: UUID) {
        guard listenerToken == token, listener != nil, peers.count < 64 else { connection.cancel(); return }
        let id = UUID()
        let peer = BackendRemoteHostWebSocket(connection: connection, host: host, allowedHosts: allowedHosts, webRoot: webRoot, queue: queue)
        peers[id] = peer
        Task { [weak self] in await peer.run(); await self?.forget(id) }
    }
    private func forget(_ id: UUID) { peers[id] = nil }
    public func stop() async {
        if let stopping { await stopping.task.value; return }
        let oldListener = listener; listener = nil; listenerToken = nil; boundPort = nil
        let pending = starting?.task; pending?.cancel()
        ready?.resume(throwing: CancellationError()); ready = nil
        let oldPeers = Array(peers.values); peers = [:]
        let id = UUID(), task = Task {
            oldListener?.cancel()
            if let pending { _ = await pending.result }
            await self.closePeers(oldPeers, code: 1001, reason: "The direct listener stopped.")
        }
        stopping = (id, task); await task.value
        if stopping?.id == id { stopping = nil }
    }
    private func closePeers(_ peers: [BackendRemoteHostWebSocket], code: Int, reason: String) async {
        await withTaskGroup(of: Void.self) { group in
            for peer in peers { group.addTask { await peer.close(code, reason) } }
        }
    }
}

private actor BackendRemoteHostWebSocket {
    private let connection: NWConnection
    private let host: BackendRemoteHost
    private let hosts: Set<String>
    private let root: URL?
    private let queue: DispatchQueue
    private let output: BackendRemoteServeHostServiceOutput
    private var buffer = Data()
    private var closed = false
    private var upgraded = false
    private var closing: Task<Void, Never>?
    private var endpointID: UUID?
    private var sendingBytes = 0
    private var heartbeat: Task<Void, Never>?
    private var awaitingPong = false
    init(connection: NWConnection, host: BackendRemoteHost, allowedHosts: Set<String>, webRoot: URL?, queue: DispatchQueue) {
        self.connection = connection; self.host = host; hosts = allowedHosts; root = webRoot; self.queue = queue
        output = .init { data, done in connection.send(content: data, completion: .contentProcessed { done($0) }) }
    }
    func run() async {
        guard !closed else { return }
        connection.start(queue: queue)
        let timeout = Task { [weak self] in try? await Task.sleep(for: .seconds(10)); guard !Task.isCancelled else { return }; await self?.close(1008, "The request stayed silent.") }
        do {
            let (method, path, headers) = try await readHeaders()
            guard let named = headers["host"]?.lowercased(), hosts.contains(named) else { try await http(403, "Forbidden", Data()); throw CancellationError() }
            if let origin = headers["origin"], let url = URL(string: origin) {
                let originHost = (url.host ?? "") + (url.port.map { ":\($0)" } ?? "")
                guard ["http", "https"].contains(url.scheme ?? ""), hosts.contains(originHost.lowercased()) else { try await http(403, "Forbidden", Data()); throw CancellationError() }
            } else if headers["origin"] != nil { throw NativeRPCError.malformed("The request origin is unusable") }
            if path == "/ws", method == "GET" {
                guard headers["upgrade"]?.lowercased() == "websocket", headers["connection"]?.lowercased().split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }) == true,
                      headers["sec-websocket-version"] == "13", let key = headers["sec-websocket-key"], Data(base64Encoded: key)?.count == 16 else {
                    throw NativeRPCError.malformed("A valid WebSocket upgrade is required")
                }
                let proof = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
                try await sendRaw(Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(proof)\r\n\r\n".utf8))
                guard !closed else { throw CancellationError() }
                upgraded = true
                timeout.cancel()
                let address: String
                if case .hostPort(let host, _) = connection.endpoint { address = String(describing: host) } else { address = "direct" }
                endpointID = await host.accept(.init(address: address, send: { [weak self] text in
                    guard let self else { throw NativeRPCError(code: "disconnected", message: "The remote socket closed") }
                    try await self.sendText(text)
                }, close: { [weak self] code, text in await self?.close(code, text) }))
                guard !closed, let endpointID else { await notifyEndpointClosed(); throw CancellationError() }
                heartbeat = Task { [weak self] in
                    while !Task.isCancelled { try? await Task.sleep(for: .seconds(30)); guard !Task.isCancelled else { return }; await self?.ping() }
                }
                var fragments = Data(), fragmentOpcode: UInt8?
                while !closed {
                    let frame = try await frame()
                    guard !closed else { break }
                    switch frame.opcode {
                    case 8: await close(1000, "The client closed.")
                    case 9: try await sendFrame(opcode: 10, payload: frame.payload)
                    case 10: awaitingPong = false
                    case 2: await close(1003, "Binary session messages are unsupported.")
                    case 1, 0:
                        if frame.opcode == 1 { guard fragmentOpcode == nil else { throw NativeRPCError.malformed("A fragmented message was interrupted") }; fragmentOpcode = 1 }
                        else { guard fragmentOpcode != nil else { throw NativeRPCError.malformed("A continuation has no message") } }
                        fragments.append(frame.payload)
                        guard fragments.count <= 65536 else { await close(1009, "The message is too large."); break }
                        if frame.final {
                            guard let text = String(data: fragments, encoding: .utf8) else { throw NativeRPCError.malformed("The WebSocket message is not UTF-8") }
                            fragments = Data(); fragmentOpcode = nil
                            await host.receive(endpointID, text: text)
                        }
                    default: throw NativeRPCError.malformed("Unsupported WebSocket opcode")
                    }
                }
            } else {
                guard method == "GET" || method == "HEAD", let root else { try await http(404, "Not Found", Data()); throw CancellationError() }
                let component = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
                guard let decoded = component.removingPercentEncoding, !decoded.contains("\0"), !decoded.contains("\\") else { throw NativeRPCError.malformed("Invalid static path") }
                let relative = decoded == "/" ? "index.html" : String(decoded.drop(while: { $0 == "/" }))
                let directory = root.standardizedFileURL.resolvingSymlinksInPath()
                let file = directory.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
                guard file.path.hasPrefix(directory.path + "/"), (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16 * 1024 * 1024 else { try await http(404, "Not Found", Data()); throw CancellationError() }
                let data = try Data(contentsOf: file)
                let types = ["html": "text/html; charset=utf-8", "js": "application/javascript", "css": "text/css", "json": "application/json", "svg": "image/svg+xml", "png": "image/png", "ico": "image/x-icon", "woff2": "font/woff2"]
                try await http(200, "OK", method == "HEAD" ? Data() : data, contentType: types[file.pathExtension] ?? "application/octet-stream", length: data.count)
            }
        } catch { if !closed { await close(1002, "The request could not be read.") } }
        timeout.cancel(); heartbeat?.cancel()
        if let closing { await closing.value }
        closed = true; connection.cancel(); await output.stop(); await notifyEndpointClosed()
    }
    private func ping() async {
        if awaitingPong { await close(1001, "The client stopped answering."); return }
        awaitingPong = true
        do { try await sendFrame(opcode: 9, payload: Data()) } catch { await close(1001, "The client stopped answering.") }
    }
    func sendText(_ text: String) async throws { try await sendFrame(opcode: 1, payload: Data(text.utf8)) }
    func close(_ code: Int, _ reason: String) async {
        if let closing { await closing.value; return }
        guard !closed else { return }
        closed = true; heartbeat?.cancel()
        let task = Task { await self.finishClose(code, reason) }; closing = task
        await task.value; closing = nil
    }
    private func finishClose(_ code: Int, _ reason: String) async {
        let deadline = Task { [connection, output] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            connection.cancel(); await output.stop()
        }
        defer { deadline.cancel() }
        // Release authenticated ownership before the bounded wire drain. No
        // late packet/push may keep device resources alive during close.
        await notifyEndpointClosed()
        var payload = Data([UInt8(code >> 8), UInt8(code & 255)])
        for scalar in reason.unicodeScalars {
            let data = Data(String(scalar).utf8)
            if payload.count + data.count > 125 { break }; payload.append(data)
        }
        if upgraded { try? await sendFrame(opcode: 8, payload: payload, permitClosed: true) }
        connection.cancel(); await output.stop(); await notifyEndpointClosed()
    }
    private func notifyEndpointClosed() async {
        guard let id = endpointID else { return }; endpointID = nil
        await host.closed(id)
    }
    private func readHeaders() async throws -> (String, String, [String: String]) {
        let separator = Data("\r\n\r\n".utf8)
        while buffer.range(of: separator) == nil {
            buffer.append(try await read())
            guard buffer.count <= 16384 else { throw NativeRPCError.malformed("The HTTP header is too large") }
        }
        let range = buffer.range(of: separator)!
        let count = buffer.distance(from: buffer.startIndex, to: range.lowerBound)
        guard let text = String(data: buffer.prefix(count), encoding: .utf8) else { throw NativeRPCError.malformed("HTTP headers are not UTF-8") }
        buffer = Data(buffer.dropFirst(count + 4))
        let lines = text.components(separatedBy: "\r\n"), words = (lines.first ?? "").split(separator: " ")
        guard words.count == 3, words[2] == "HTTP/1.1" else { throw NativeRPCError.malformed("Unsupported HTTP request") }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let at = line.firstIndex(of: ":") else { throw NativeRPCError.malformed("Malformed HTTP header") }
            let key = line[..<at].lowercased()
            guard fields[key] == nil else { throw NativeRPCError.malformed("Duplicate HTTP header") }
            fields[key] = line[line.index(after: at)...].trimmingCharacters(in: .whitespaces)
        }
        guard fields["transfer-encoding"] == nil, fields["content-length"] == nil || fields["content-length"] == "0" else { throw NativeRPCError.malformed("Remote GET requests cannot carry a body") }
        return (String(words[0]), String(words[1]), fields)
    }
    private func frame() async throws -> (final: Bool, opcode: UInt8, payload: Data) {
        try await fill(2)
        let first = buffer[buffer.startIndex], second = buffer[buffer.startIndex + 1]
        guard first & 0x70 == 0, second & 0x80 != 0 else { throw NativeRPCError.malformed("Client WebSocket frames must be masked") }
        var offset = 2, length = UInt64(second & 0x7f)
        if length == 126 { try await fill(4); length = UInt64(buffer[buffer.startIndex + 2]) << 8 | UInt64(buffer[buffer.startIndex + 3]); offset = 4; guard length >= 126 else { throw NativeRPCError.malformed("Noncanonical WebSocket length") } }
        else if length == 127 {
            try await fill(10); length = 0
            for byte in buffer.dropFirst(2).prefix(8) { length = length << 8 | UInt64(byte) }
            offset = 10; guard length >= 65536 else { throw NativeRPCError.malformed("Noncanonical WebSocket length") }
        }
        let opcode = first & 15, final = first & 0x80 != 0
        guard length <= 65536, opcode < 8 || final && length <= 125 else { throw NativeRPCError.malformed("The WebSocket frame is oversized or malformed") }
        try await fill(offset + 4 + Int(length))
        let bytes = [UInt8](buffer.prefix(offset + 4 + Int(length))), mask = Array(bytes[offset..<offset + 4])
        let payload = Data(bytes[(offset + 4)...].enumerated().map { $0.element ^ mask[$0.offset % 4] })
        buffer = Data(buffer.dropFirst(bytes.count))
        return (final, opcode, payload)
    }
    private func fill(_ size: Int) async throws { while buffer.count < size { buffer.append(try await read()); guard buffer.count <= 131072 else { throw NativeRPCError.malformed("The input buffer is too large") } } }
    private func read() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
            if let error { continuation.resume(throwing: error) } else if let data, !data.isEmpty { continuation.resume(returning: data) }
            else { continuation.resume(throwing: NativeRPCError(code: "disconnected", message: done ? "The remote socket closed" : "The remote socket returned no bytes")) }
        } }
    }
    private func sendFrame(opcode: UInt8, payload: Data, permitClosed: Bool = false) async throws {
        guard permitClosed || !closed else { throw NativeRPCError(code: "disconnected", message: "The remote socket closed") }
        guard payload.count <= 98304 else { throw NativeRPCError(code: "backpressure", message: "The remote output queue is full") }
        var frame = Data([0x80 | opcode])
        if payload.count < 126 { frame.append(UInt8(payload.count)) }
        else if payload.count <= 65535 { frame.append(contentsOf: [126, UInt8(payload.count >> 8), UInt8(payload.count & 255)]) }
        else { frame.append(127); let size = UInt64(payload.count); for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((size >> shift) & 255)) } }
        frame.append(payload)
        guard sendingBytes + frame.count <= 1024 * 1024 else { throw NativeRPCError(code: "backpressure", message: "The remote output queue is full") }
        sendingBytes += frame.count
        defer { sendingBytes -= frame.count }
        try await sendRaw(frame)
    }
    private func sendRaw(_ data: Data) async throws { try await output.send(data) }
    private func http(_ status: Int, _ reason: String, _ data: Data, contentType: String = "text/plain", length: Int? = nil) async throws {
        var response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(length ?? data.count)\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n".utf8)
        response.append(data); try await sendRaw(response)
    }
}
