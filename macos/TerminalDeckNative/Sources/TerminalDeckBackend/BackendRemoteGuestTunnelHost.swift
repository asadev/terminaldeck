import Foundation
@preconcurrency import Network
import TerminalDeckNativeCore

/// One host owns the process-wide 256-stream budget. Each authenticated
/// connection owns at most four tunnels and 64 streams. No bytes ever dial an
/// address authored by a peer: targets come from a fresh native localhost scan.
// Retained during the ownership freeze as pre-merge source. App composition
// uses the public facade below, which has one transferred connection-hub owner.
private actor BackendRemoteGuestTunnelReference {
    public typealias Push = @Sendable (UUID, BackendRemoteServerMessage) async throws -> Void
    private struct Key: Hashable, Sendable { let connection: UUID; let id: String }
    private struct Tunnel { let port: Int; let host: NWEndpoint.Host; let context: BackendRemoteHostContext }
    private struct Stream {
        let connection: NWConnection; let tunnel: Key
        var unacknowledged = 0
        var credit: [CheckedContinuation<Void, Error>] = []
        var task: Task<Void, Never>?
    }
    private let scan: @Sendable () async throws -> [BackendDevPort]
    private let authorize: @Sendable (Int, BackendRemoteHostContext) async throws -> Bool
    private let ownPorts: BackendDevOwnPorts
    private let push: Push
    private let queue = DispatchQueue(label: "native.remote.localhost.host", qos: .userInitiated)
    private var tunnels: [Key: Tunnel] = [:], streams: [Key: Stream] = [:]
    private var lingering: [UUID: (key: Key, connection: NWConnection)] = [:]
    private var opening: [Key: UUID] = [:]
    private var probes: [Key: (token: UUID, connection: NWConnection)] = [:]
    public init(ownPorts: BackendDevOwnPorts, scan: @escaping @Sendable () async throws -> [BackendDevPort],
                authorize: @escaping @Sendable (Int, BackendRemoteHostContext) async throws -> Bool, push: @escaping Push) {
        self.ownPorts = ownPorts; self.scan = scan; self.authorize = authorize; self.push = push
    }
    public func feature() -> BackendRemoteHostFeature {
        .init(capability: "localhost", messageTypes: ["ports", "tunnel.open", "tunnel.close", "net.open", "net.data", "net.ack", "net.close"], policy: .grantedDevice) { [weak self] message, context in
            guard let self else { throw NativeRPCError(code: "localhost-closed", message: "The native localhost service stopped") }
            return try await self.handle(message, context: context)
        }
    }
    public func handle(_ message: BackendRemoteClientMessage, context: BackendRemoteHostContext) async throws -> [BackendRemoteServerMessage] {
        let key = Key(connection: context.connectionID, id: message["id"].string ?? message["ch"].string ?? "")
        switch message.type {
        case "ports":
            let reserved = Set(await ownPorts.ports()); var rows: [NativeRPCValue] = []
            for port in try await scan() where !reserved.contains(port.port) {
                if try await authorize(port.port, context) { rows.append(.object([.init("port", .number(Double(port.port))), .init("process", .string(port.process)), .init("guessed", .bool(port.guessed))])) }
            }
            return [try .init(.ports, fields: [.init("ports", .array(rows))])]
        case "tunnel.open": return try await openTunnel(key, port: Int(message["port"].number!), context: context)
        case "tunnel.close": await closeTunnel(key, tellPeer: false); return [try closed(key.id, "Closed on the client.")]
        case "net.open":
            let tunnel = Key(connection: key.connection, id: message["tunnel"].string!)
            guard streams[key] == nil, streams.count + lingering.count < 256, streams.keys.filter({ $0.connection == key.connection }).count + lingering.values.filter({ $0.key.connection == key.connection }).count < 64,
                  let target = tunnels[tunnel], try await permitted(target.port, context) else { return [try .init(.netClose, fields: [.init("ch", .string(key.id))])] }
            let connection = NWConnection(host: target.host, port: NWEndpoint.Port(rawValue: UInt16(target.port))!, using: .tcp)
            streams[key] = Stream(connection: connection, tunnel: tunnel)
            do {
                try await ready(connection)
                guard streams[key]?.connection === connection else { return [] }
                streams[key]?.task = Task { [weak self] in await self?.readLoop(key) }
                return [] // Actual output is pushed by the native byte stream.
            } catch { if streams[key]?.connection === connection { await closeStream(key, tellPeer: false) }; return [try .init(.netClose, fields: [.init("ch", .string(key.id))])] }
        case "net.data":
            guard let stream = streams[key], let tunnel = tunnels[stream.tunnel], try await permitted(tunnel.port, context),
                  let bytes = Data(base64Encoded: message["data"].string!), bytes.count <= 24576 else { await closeStream(key, tellPeer: false); return [try .init(.netClose, fields: [.init("ch", .string(key.id))])] }
            do {
                try await write(bytes, connection: stream.connection)
                return bytes.isEmpty ? [] : [try .init(.netAck, fields: [.init("ch", .string(key.id)), .init("bytes", .number(Double(bytes.count)))])]
            } catch { await closeStream(key, tellPeer: false); return [try .init(.netClose, fields: [.init("ch", .string(key.id))])] }
        case "net.ack":
            guard let stream = streams[key], let count = message["bytes"].number, count.rounded() == count, count > 0, count <= Double(stream.unacknowledged) else { await closeStream(key, tellPeer: false); return [try .init(.netClose, fields: [.init("ch", .string(key.id))])] }
            streams[key]?.unacknowledged -= Int(count)
            if (streams[key]?.unacknowledged ?? 0) + 24576 <= 262144 { let pending = streams[key]?.credit ?? []; streams[key]?.credit = []; for waiter in pending { waiter.resume() } }
            return []
        case "net.close": await closeStream(key, tellPeer: false, flush: true); return []
        default: throw NativeRPCError.invalidArguments("This is not a localhost frame")
        }
    }
    private func permitted(_ port: Int, _ context: BackendRemoteHostContext) async throws -> Bool {
        let reserved = await ownPorts.ports()
        guard !reserved.contains(port) else { return false }; return try await authorize(port, context)
    }
    private func openTunnel(_ key: Key, port: Int, context: BackendRemoteHostContext) async throws -> [BackendRemoteServerMessage] {
        guard tunnels[key] == nil, opening[key] == nil, (1...65535).contains(port), tunnels.keys.filter({ $0.connection == key.connection }).count + opening.keys.filter({ $0.connection == key.connection }).count < 4 else { return [try closed(key.id, "This connection already has that tunnel or four ports open.")] }
        let token = UUID(); opening[key] = token
        defer { if opening[key] == token { opening[key] = nil }; if probes[key]?.token == token { probes[key]?.connection.cancel(); probes[key] = nil } }
        guard try await permitted(port, context), let entry = try await scan().first(where: { $0.port == port }) else { return [try closed(key.id, "Nothing approved is listening on that port.")] }
        let candidates: [NWEndpoint.Host] = entry.ipv4 && !entry.ipv6 ? [.ipv4(.loopback)] : entry.ipv6 && !entry.ipv4 ? [.ipv6(.loopback)] : [.ipv4(.loopback), .ipv6(.loopback)]
        for host in candidates {
            guard opening[key] == token else { return [] }
            let probe = NWConnection(host: host, port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp); probes[key] = (token, probe)
            do {
                try await ready(probe); probe.cancel(); if probes[key]?.token == token { probes[key] = nil }
                guard opening[key] == token, try await permitted(port, context) else { return [] }
                tunnels[key] = Tunnel(port: port, host: host, context: context)
                return [try .init(.tunnelOpened, fields: [.init("id", .string(key.id)), .init("port", .number(Double(port)))])]
            } catch { probe.cancel(); if probes[key]?.token == token { probes[key] = nil }; if Task.isCancelled { throw CancellationError() } }
        }
        return [try closed(key.id, "That listed port is not accepting loopback connections.")]
    }
    private func readLoop(_ key: Key) async {
        do {
            while let stream = streams[key], let tunnel = tunnels[stream.tunnel] {
                guard try await permitted(tunnel.port, tunnel.context) else { throw NativeRPCError(code: "localhost-denied", message: "The localhost grant was withdrawn") }
                if stream.unacknowledged + 24576 > 262144 { try await withCheckedThrowingContinuation { continuation in streams[key]?.credit.append(continuation) } }
                guard let current = streams[key] else { return }
                let data: Data = try await withCheckedThrowingContinuation { continuation in
                    current.connection.receive(minimumIncompleteLength: 1, maximumLength: 24576) { data, _, complete, error in
                        if let error { continuation.resume(throwing: error) } else if let data, !data.isEmpty { continuation.resume(returning: data) }
                        else { continuation.resume(throwing: NativeRPCError(code: "localhost-stream", message: complete ? "The stream ended" : "No bytes were returned")) }
                    }
                }
                guard streams[key]?.connection === current.connection else { return }
                streams[key]?.unacknowledged += data.count
                try await push(key.connection, .init(.netData, fields: [.init("ch", .string(key.id)), .init("data", .string(data.base64EncodedString()))]))
            }
        } catch { await closeStream(key, tellPeer: true, flush: true) }
    }
    public func close(connectionID: UUID) async {
        for key in opening.keys.filter({ $0.connection == connectionID }) { opening[key] = nil; probes.removeValue(forKey: key)?.connection.cancel() }
        for key in tunnels.keys.filter({ $0.connection == connectionID }) { await closeTunnel(key, tellPeer: false) }
        for key in streams.keys.filter({ $0.connection == connectionID }) { await closeStream(key, tellPeer: false) }
        for id in lingering.filter({ $0.value.key.connection == connectionID }).map(\.key) { lingering.removeValue(forKey: id)?.connection.cancel() }
    }
    public func stop() async {
        opening = [:]; for probe in probes.values { probe.connection.cancel() }; probes = [:]
        for key in Array(tunnels.keys) { await closeTunnel(key, tellPeer: false) }
        for key in Array(streams.keys) { await closeStream(key, tellPeer: false) }
        for value in lingering.values { value.connection.cancel() }; lingering = [:]
    }
    private func closeStream(_ key: Key, tellPeer: Bool, flush: Bool = false) async {
        guard let stream = streams.removeValue(forKey: key) else { return }; stream.task?.cancel()
        if flush {
            let token = UUID(); lingering[token] = (key, stream.connection)
            stream.connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in if error != nil { stream.connection.cancel() } })
            Task { [weak self] in try? await Task.sleep(for: .seconds(5)); await self?.finishLinger(token) }
        } else { stream.connection.cancel() }
        for waiter in stream.credit { waiter.resume(throwing: CancellationError()) }
        if tellPeer { try? await push(key.connection, .init(.netClose, fields: [.init("ch", .string(key.id))])) }
    }
    private func finishLinger(_ id: UUID) { lingering.removeValue(forKey: id)?.connection.cancel() }
    private func closeTunnel(_ key: Key, tellPeer: Bool) async {
        opening[key] = nil; probes.removeValue(forKey: key)?.connection.cancel(); tunnels[key] = nil
        for stream in streams.filter({ $0.value.tunnel == key }).map(\.key) { await closeStream(stream, tellPeer: tellPeer) }
        if tellPeer { try? await push(key.connection, closed(key.id, "Closed on the host.")) }
    }
    private func closed(_ id: String, _ message: String) throws -> BackendRemoteServerMessage { try .init(.tunnelClosed, fields: [.init("id", .string(id)), .init("message", .string(message))]) }
    private func write(_ data: Data, connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in connection.send(content: data, completion: .contentProcessed { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } }) }
    }
    private func ready(_ connection: NWConnection) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let gate = BackendRemoteGuestTunnelReady(continuation)
                connection.stateUpdateHandler = { state in switch state { case .ready: gate.finish(.success(())); case .failed(let error): gate.finish(.failure(error)); case .cancelled: gate.finish(.failure(CancellationError())); default: break } }
                connection.start(queue: queue)
                Task { try? await Task.sleep(for: .seconds(5)); gate.finish(.failure(NativeRPCError(code: "localhost-timeout", message: "The loopback target did not answer"))) }
            }
        } onCancel: { connection.cancel() }
    }
}
private final class BackendRemoteGuestTunnelReady: @unchecked Sendable {
    private let lock = NSLock(); private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Void, Error>) { lock.lock(); let pending = continuation; continuation = nil; lock.unlock(); pending?.resume(with: result) }
}

/// Compatibility facade over the transferred, shared-contract connection
/// hubs. There is one active host transport and one process-wide budget.
public actor BackendRemoteGuestTunnelHost {
    public typealias Push = @Sendable (UUID, BackendRemoteServerMessage) async throws -> Void
    public nonisolated let transport: BackendRemoteServeTransport
    public init(ownPorts: BackendDevOwnPorts, scan: @escaping @Sendable () async throws -> [BackendDevPort],
                authorize: @escaping @Sendable (Int, BackendRemoteHostContext) async throws -> Bool, push: @escaping Push) {
        transport = BackendRemoteServeTransport(ports: BackendRemoteGuestTunnelPortAdapter(ownPorts: ownPorts, scan: scan, authorize: authorize),
            wire: BackendRemoteServeTransportWireAdapter(send: push))
    }
    public init(ports: any BackendRemoteServeTransportPortSource, wire: any BackendRemoteServeTransportWire,
                sockets: any BackendRemoteServeTransportSocketFactory = BackendRemoteServeTransportTCPFactory(), onChange: @escaping @Sendable () -> Void = {}) {
        transport = BackendRemoteServeTransport(ports: ports, wire: wire, sockets: sockets, onChange: onChange)
    }
    public nonisolated func feature() -> BackendRemoteHostFeature { transport.feature() }
    public func handle(_ message: BackendRemoteClientMessage, context: BackendRemoteHostContext) async throws -> [BackendRemoteServerMessage] { try await transport.handle(message, context: context) }
    public func list(connectionID: UUID) async -> [BackendRemoteServeTransportTunnelInfo] { await transport.list(connectionID: connectionID) }
    public func stop(connectionID: UUID, tunnelID: String) async throws -> Bool { try await transport.stop(connectionID: connectionID, tunnelID: tunnelID) }
    public func close(connectionID: UUID) async { await transport.connectionClosed(connectionID) }
    public func stop() async { await transport.stop() }
}

private struct BackendRemoteGuestTunnelPortAdapter: BackendRemoteServeTransportPortSource {
    let ownPorts: BackendDevOwnPorts
    let scan: @Sendable () async throws -> [BackendDevPort]
    let authorize: @Sendable (Int, BackendRemoteHostContext) async throws -> Bool
    func reservedPorts() async -> Set<Int> { Set(await ownPorts.ports()) }
    func permits(port: Int, context: BackendRemoteHostContext) async throws -> Bool {
        let reserved = await reservedPorts()
        guard !reserved.contains(port) else { return false }; return try await authorize(port, context)
    }
    func scan(context: BackendRemoteHostContext) async throws -> [BackendRemoteServeTransportPort] {
        let found = try await scan(); var result: [BackendRemoteServeTransportPort] = []
        for port in found {
            if try await permits(port: port.port, context: context) { result.append(.init(port: port.port, process: port.process, guessed: port.guessed, ipv4: port.ipv4, ipv6: port.ipv6)) }
        }
        return result
    }
}
