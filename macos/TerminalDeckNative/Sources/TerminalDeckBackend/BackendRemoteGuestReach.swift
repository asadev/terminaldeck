import Foundation
@preconcurrency import Network
import TerminalDeckNativeCore

/// Opaque byte forwarding to an explicitly opened, host-approved localhost port.
/// Local listeners bind only loopback; HTTP/WebSocket/SSE stay the app's bytes.
public actor BackendRemoteGuestReach {
    public struct Opened: Sendable {
        public let url: URL, port: Int, localPort: UInt16
        public var value: NativeRPCValue { .object([.init("ok", .bool(true)), .init("url", .string(url.absoluteString)), .init("port", .number(Double(port))), .init("localPort", .number(Double(localPort))), .init("sameNumber", .bool(port == Int(localPort)))]) }
    }
    private let guest: BackendRemoteGuest
    private let ownPorts: BackendDevOwnPorts
    private let queue = DispatchQueue(label: "native.machine.localhost", qos: .userInitiated)
    private var tunnels: [String: Tunnel] = [:]
    private var streams: [String: Stream] = [:]
    private var lingering: [UUID: NWConnection] = [:]
    private var opening: [Int: Task<Opened, Error>] = [:]
    private struct Tunnel { let remoteID: String; let listener: NWListener; let address: Opened }
    private struct Stream {
        let connection: NWConnection
        let tunnel: String
        var unacknowledged = 0
        var credit: [CheckedContinuation<Void, Error>] = []
        var task: Task<Void, Never>?
    }
    public init(guest: BackendRemoteGuest, ownPorts: BackendDevOwnPorts) { self.guest = guest; self.ownPorts = ownPorts }
    public func open(port: Int) async throws -> Opened {
        if let existing = tunnels.values.first(where: { $0.address.port == port }) { return existing.address }
        if let pending = opening[port] { return try await pending.value }
        let task = Task { try await self.openTunnel(port: port) }; opening[port] = task
        defer { opening[port] = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func openTunnel(port: Int) async throws -> Opened {
        guard (1...65535).contains(port), tunnels.count < 16 else { throw NativeRPCError.invalidArguments("The remote localhost port or tunnel limit is invalid") }
        let id = UUID().uuidString.lowercased()
        let reply: NativeRPCValue
        do { reply = try await guest.request(type: "tunnel.open", fields: [.init("port", .number(Double(port)))], capability: "localhost",
            replies: ["tunnel.opened", "tunnel.closed"], correlation: "id", requestID: id, timeoutMilliseconds: 20000) }
        catch { try? await guest.send(type: "tunnel.close", fields: [.init("id", .string(id))], capability: "localhost"); throw error }
        guard reply["t"].string == "tunnel.opened", reply["port"].number == Double(port) else { throw NativeRPCError(code: "machine-reach", message: reply["message"].string ?? "That machine did not open the localhost port") }
        var selected: (NWListener, UInt16, Bool)?
        do {
            for ipv6 in [false, true] {
                try Task.checkCancellation()
                if await occupied(port: UInt16(port), ipv6: ipv6) { continue }
                if let bound = try? await bind(port: UInt16(port), ipv6: ipv6, tunnel: id) { selected = (bound.0, bound.1, ipv6); break }
            }
            if selected == nil { let bound = try await bind(port: 0, ipv6: false, tunnel: id); selected = (bound.0, bound.1, false) }
            try Task.checkCancellation()
        } catch { selected?.0.cancel(); try? await guest.send(type: "tunnel.close", fields: [.init("id", .string(id))], capability: "localhost"); throw error }
        let (listener, localPort, ipv6) = selected!
        let address = Opened(url: URL(string: "http://\(ipv6 ? "[::1]" : "127.0.0.1"):\(localPort)/")!, port: port, localPort: localPort)
        tunnels[id] = Tunnel(remoteID: id, listener: listener, address: address)
        await ownPorts.claim(Int(localPort)); return address
    }
    public func close(port: Int) async {
        opening.removeValue(forKey: port)?.cancel()
        if let pair = tunnels.first(where: { $0.value.address.port == port }) { await closeTunnel(pair.key) }
    }
    public func stop() async { for task in opening.values { task.cancel() }; opening = [:]; for id in Array(tunnels.keys) { await closeTunnel(id) }; for connection in lingering.values { connection.cancel() }; lingering = [:] }
    private func accepted(_ connection: NWConnection, tunnel: String) async {
        guard tunnels[tunnel] != nil, streams.count + lingering.count < 64 else { connection.cancel(); return }
        let id = UUID().uuidString.lowercased()
        streams[id] = Stream(connection: connection, tunnel: tunnel)
        connection.start(queue: queue)
        do { try await guest.send(type: "net.open", fields: [.init("ch", .string(id)), .init("tunnel", .string(tunnel))], capability: "localhost") }
        catch { await closeStream(id, tellPeer: false); return }
        streams[id]?.task = Task { [weak self] in await self?.readLoop(id) }
    }
    private func readLoop(_ id: String) async {
        do {
            while let stream = streams[id] {
                if stream.unacknowledged + 24576 > 262144 { try await waitCredit(id) }
                guard let current = streams[id] else { return }
                let bytes: Data = try await withCheckedThrowingContinuation { continuation in
                    current.connection.receive(minimumIncompleteLength: 1, maximumLength: 24576) { bytes, _, complete, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let bytes, !bytes.isEmpty { continuation.resume(returning: bytes) }
                        else { continuation.resume(throwing: NativeRPCError(code: "machine-stream", message: complete ? "The local byte stream closed" : "The local byte stream returned no data")) }
                    }
                }
                guard streams[id]?.connection === current.connection else { return }
                streams[id]?.unacknowledged += bytes.count
                try await guest.send(type: "net.data", fields: [.init("ch", .string(id)), .init("data", .string(bytes.base64EncodedString()))], capability: "localhost")
            }
        } catch { await closeStream(id, tellPeer: true, flush: true) }
    }
    public func handle(_ frame: NativeRPCValue) async {
        guard let type = frame["t"].string else { return }
        if type == "tunnel.closed", let id = frame["id"].string { await closeTunnel(id); return }
        guard let id = frame["ch"].string, let stream = streams[id] else { return }
        switch type {
        case "net.data":
            guard let encoded = frame["data"].string, encoded.utf16.count <= 32768, let bytes = Data(base64Encoded: encoded), bytes.count <= 24576 else { await closeStream(id, tellPeer: true); return }
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    stream.connection.send(content: bytes, completion: .contentProcessed { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } })
                }
                if !bytes.isEmpty { try await guest.send(type: "net.ack", fields: [.init("ch", .string(id)), .init("bytes", .number(Double(bytes.count)))], capability: "localhost") }
            } catch { await closeStream(id, tellPeer: true) }
        case "net.ack":
            guard let amount = frame["bytes"].number, amount.rounded() == amount, amount > 0, amount <= Double(stream.unacknowledged) else { await closeStream(id, tellPeer: true); return }
            streams[id]?.unacknowledged -= Int(amount)
            if (streams[id]?.unacknowledged ?? 0) + 24576 <= 262144 {
                let waiters = streams[id]?.credit ?? []; streams[id]?.credit = []; for waiter in waiters { waiter.resume() }
            }
        case "net.close": await closeStream(id, tellPeer: false, flush: true)
        default: break
        }
    }
    private func waitCredit(_ id: String) async throws {
        guard streams[id] != nil else { throw CancellationError() }
        try await withCheckedThrowingContinuation { continuation in streams[id]?.credit.append(continuation) }
    }
    private func closeStream(_ id: String, tellPeer: Bool, flush: Bool = false) async {
        guard let stream = streams.removeValue(forKey: id) else { return }
        stream.task?.cancel()
        if flush {
            let token = UUID(); lingering[token] = stream.connection
            stream.connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in if error != nil { stream.connection.cancel() } })
            Task { [weak self] in try? await Task.sleep(for: .seconds(5)); await self?.finishLinger(token) }
        } else { stream.connection.cancel() }
        for waiter in stream.credit { waiter.resume(throwing: CancellationError()) }
        if tellPeer { try? await guest.send(type: "net.close", fields: [.init("ch", .string(id))], capability: "localhost") }
    }
    private func finishLinger(_ id: UUID) { lingering.removeValue(forKey: id)?.cancel() }
    private func closeTunnel(_ id: String) async {
        guard let tunnel = tunnels.removeValue(forKey: id) else { return }
        tunnel.listener.cancel()
        await ownPorts.release(Int(tunnel.address.localPort))
        for stream in streams.filter({ $0.value.tunnel == id }).map(\.key) { await closeStream(stream, tellPeer: true) }
        try? await guest.send(type: "tunnel.close", fields: [.init("id", .string(id))], capability: "localhost")
    }
    private func bind(port: UInt16, ipv6: Bool, tunnel: String) async throws -> (NWListener, UInt16) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: ipv6 ? .ipv6(.loopback) : .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        do {
            let bound: UInt16 = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let gate = BackendRemoteGuestReachReady(continuation)
                    listener.stateUpdateHandler = { state in
                        switch state { case .ready: if let port = listener.port?.rawValue { gate.finish(.success(port)) }; case .failed(let error): gate.finish(.failure(error)); case .cancelled: gate.finish(.failure(CancellationError())); default: break }
                    }
                    listener.newConnectionHandler = { [weak self] connection in Task { await self?.accepted(connection, tunnel: tunnel) } }
                    listener.start(queue: queue)
                    Task { try? await Task.sleep(for: .seconds(5)); gate.finish(.failure(NativeRPCError(code: "machine-bind", message: "The local tunnel listener did not start in time"))) }
                }
            } onCancel: { listener.cancel() }
            return (listener, bound)
        } catch { listener.cancel(); throw error }
    }
    private func occupied(port: UInt16, ipv6: Bool) async -> Bool {
        let connection = NWConnection(host: ipv6 ? .ipv6(.loopback) : .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let gate = BackendRemoteGuestReachProbe(continuation)
                connection.stateUpdateHandler = { state in
                    switch state { case .ready: gate.finish(true); connection.cancel(); case .failed(let error):
                        if case .posix(let code) = error, code == .ECONNREFUSED { gate.finish(false) } else { gate.finish(true) }; connection.cancel()
                    case .cancelled: gate.finish(true); default: break }
                }
                connection.start(queue: queue)
                Task { try? await Task.sleep(for: .milliseconds(600)); gate.finish(true); connection.cancel() }
            }
        } onCancel: { connection.cancel() }
    }
}

private final class BackendRemoteGuestReachReady: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?
    init(_ continuation: CheckedContinuation<UInt16, Error>) { self.continuation = continuation }
    func finish(_ result: Result<UInt16, Error>) { lock.lock(); let value = continuation; continuation = nil; lock.unlock(); value?.resume(with: result) }
}
private final class BackendRemoteGuestReachProbe: @unchecked Sendable {
    private let lock = NSLock(); private var continuation: CheckedContinuation<Bool, Never>?
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func finish(_ value: Bool) { lock.lock(); let pending = continuation; continuation = nil; lock.unlock(); pending?.resume(returning: value) }
}
