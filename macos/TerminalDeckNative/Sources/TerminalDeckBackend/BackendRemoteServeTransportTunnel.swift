import Foundation
import TerminalDeckNativeCore

public struct BackendRemoteServeTransportPort: Sendable {
    public let port: Int, process: String, guessed: Bool
    public let ipv4: Bool?, ipv6: Bool?
    public init(port: Int, process: String, guessed: Bool, ipv4: Bool? = nil, ipv6: Bool? = nil) {
        self.port = port; self.process = process; self.guessed = guessed; self.ipv4 = ipv4; self.ipv6 = ipv6
    }
    public var value: NativeRPCValue { .object([.init("port", .number(Double(port))), .init("process", .string(process)), .init("guessed", .bool(guessed))]) }
}
public protocol BackendRemoteServeTransportPortSource: Sendable {
    /// Must read the current device/folder grants; offered ports and dial checks
    /// deliberately share this function. Never infer a folder from process names.
    func scan(context: BackendRemoteHostContext) async throws -> [BackendRemoteServeTransportPort]
    func reservedPorts() async -> Set<Int>
    /// Recheck live authority on stream open and every read/write; adapters may
    /// use their grant owner directly instead of repeating an OS port scan.
    func permits(port: Int, context: BackendRemoteHostContext) async throws -> Bool
}
extension BackendRemoteServeTransportPortSource {
    public func permits(port: Int, context: BackendRemoteHostContext) async throws -> Bool {
        let reserved = await reservedPorts()
        guard !reserved.contains(port) else { return false }
        return try await scan(context: context).contains { $0.port == port }
    }
}
public protocol BackendRemoteServeTransportWire: Sendable {
    /// Must fail if the authenticated connection is no longer present.
    func send(connectionID: UUID, message: BackendRemoteServerMessage) async throws
}
public struct BackendRemoteServeTransportWireAdapter: BackendRemoteServeTransportWire {
    private let sendFrame: @Sendable (UUID, BackendRemoteServerMessage) async throws -> Void
    public init(send: @escaping @Sendable (UUID, BackendRemoteServerMessage) async throws -> Void) { sendFrame = send }
    public func send(connectionID: UUID, message: BackendRemoteServerMessage) async throws { try await sendFrame(connectionID, message) }
}

/// Real native scan plus the sole folder/port relation: ready app-started dev servers.
public struct BackendRemoteServeTransportNativePorts: BackendRemoteServeTransportPortSource {
    private let discovery: BackendDevPortDiscovery
    private let own: BackendDevOwnPorts
    private let servers: BackendDevServers?
    private let reserved: Set<Int>
    private let currentContext: @Sendable (BackendRemoteHostContext) async throws -> BackendRemoteHostContext
    public init(discovery: BackendDevPortDiscovery, ownPorts: BackendDevOwnPorts, devServers: BackendDevServers? = nil, reserved: Set<Int> = [],
                currentContext: @escaping @Sendable (BackendRemoteHostContext) async throws -> BackendRemoteHostContext) {
        self.discovery = discovery; own = ownPorts; servers = devServers; self.reserved = reserved; self.currentContext = currentContext
    }
    public func reservedPorts() async -> Set<Int> { reserved.union(await own.ports()) }
    public func scan(context: BackendRemoteHostContext) async throws -> [BackendRemoteServeTransportPort] {
        let context = try await refreshed(context)
        var allowed: Set<Int>?
        if context.kind != .mine {
            guard let servers, !context.reach.folders.isEmpty else { return [] }
            var granted: Set<Int> = []
            for folder in context.reach.folders {
                guard let state = try? await servers.status(folder: folder, context: context.rpcContext), state["status"].string == "ready",
                      let port = state["port"].number, port.rounded() == port, (1...65_535).contains(Int(port)) else { continue }
                granted.insert(Int(port))
            }
            guard !granted.isEmpty else { return [] }
            allowed = granted
        }
        return try await discovery.scan(force: true).filter { allowed?.contains($0.port) ?? true }.map {
            .init(port: $0.port, process: $0.process, guessed: $0.guessed, ipv4: $0.ipv4, ipv6: $0.ipv6)
        }
    }
    public func permits(port: Int, context: BackendRemoteHostContext) async throws -> Bool {
        let context = try await refreshed(context), reserved = await reservedPorts()
        guard !reserved.contains(port) else { return false }
        if context.kind == .mine { return true }
        guard let servers else { return false }
        for folder in context.reach.folders {
            if let state = try? await servers.status(folder: folder, context: context.rpcContext), state["status"].string == "ready", state["port"].number == Double(port) { return true }
        }
        return false
    }
    private func refreshed(_ previous: BackendRemoteHostContext) async throws -> BackendRemoteHostContext {
        let current = try await currentContext(previous)
        guard current.connectionID == previous.connectionID, current.deviceID == previous.deviceID else { throw NativeRPCError(code: "access-denied", message: "The tunnel's authenticated connection changed") }
        return current
    }
}

/// One process-wide descriptor budget, shared across all connection hubs.
public final class BackendRemoteServeTransportStreamBudget: @unchecked Sendable {
    public static let maximum = 256
    private let lock = NSLock()
    private let ceiling: Int
    private var used = 0
    public init(ceiling: Int = maximum) { self.ceiling = max(0, ceiling) }
    public func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard used < ceiling else { return false }; used += 1; return true
    }
    public func give() { lock.lock(); if used > 0 { used -= 1 }; lock.unlock() }
}

public struct BackendRemoteServeTransportTunnelInfo: Sendable, Equatable {
    public let id: String, port: Int, streams: Int, openedAt: Double
    public var value: NativeRPCValue { .object([.init("id", .string(id)), .init("port", .number(Double(port))), .init("streams", .number(Double(streams))), .init("openedAt", .number(openedAt))]) }
}

/// Source tunnel.ts: one hub per approved connection; no HTTP interpretation.
public actor BackendRemoteServeTransportTunnelHub {
    public static let maximumTunnels = 4, maximumStreamsPerConnection = 64, dialTimeoutMilliseconds = 5_000, flushLingerMilliseconds = 5_000
    private let connectionID: UUID
    private let ports: any BackendRemoteServeTransportPortSource
    private let wire: any BackendRemoteServeTransportWire
    private let sockets: any BackendRemoteServeTransportSocketFactory
    private let budget: BackendRemoteServeTransportStreamBudget
    private let clock: @Sendable () -> Double
    private let changed: @Sendable () -> Void
    private var closed = false
    private final class Opening: Sendable { let id = UUID() }
    private struct Tunnel { let token = UUID(); let id: String, port: Int, host: BackendRemoteServeTransportLoopback, openedAt: Double; let context: BackendRemoteHostContext; var streams: Set<String> = [] }
    private struct Stream {
        let token: UUID, tunnel: String, socket: any BackendRemoteServeTransportSocket
        var unacked = 0
        var credit: CheckedContinuation<Void, Never>?
        var task: Task<Void, Never>?
    }
    private var opening: [String: Opening] = [:]
    private var tunnels: [String: Tunnel] = [:]
    private var streams: [String: Stream] = [:]
    private struct Closing { let socket: any BackendRemoteServeTransportSocket; let task: Task<Void, Never> }
    private var closing: [UUID: Closing] = [:]
    public init(connectionID: UUID, ports: any BackendRemoteServeTransportPortSource, wire: any BackendRemoteServeTransportWire,
                sockets: any BackendRemoteServeTransportSocketFactory = BackendRemoteServeTransportTCPFactory(),
                budget: BackendRemoteServeTransportStreamBudget, clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1_000 },
                onChange: @escaping @Sendable () -> Void = {}) {
        self.connectionID = connectionID; self.ports = ports; self.wire = wire; self.sockets = sockets; self.budget = budget; self.clock = clock; changed = onChange
    }
    public func handle(_ message: BackendRemoteClientMessage, context: BackendRemoteHostContext) async throws -> [BackendRemoteServerMessage] {
        guard !closed else { throw NativeRPCError(code: "unavailable", message: "The localhost tunnel connection is closed") }
        guard context.connectionID == connectionID else { throw NativeRPCError(code: "access-denied", message: "That frame belongs to a different authenticated connection") }
        switch message.type {
        case "ports":
            let reserved = await ports.reservedPorts()
            let offered = (try? await ports.scan(context: context)) ?? []
            guard !closed else { return [] }
            return [try .init(.ports, fields: [.init("ports", .array(offered.filter { !reserved.contains($0.port) }.map(\.value)))])]
        case "tunnel.open": return try await openTunnel(message["id"].string!, port: Int(message["port"].number!), context: context)
        case "tunnel.close":
            let id = message["id"].string!; _ = closeTunnel(id)
            return [try tunnelClosed(id, "Closed on the phone.")]
        case "net.open": return try await openStream(message["ch"].string!, tunnel: message["tunnel"].string!, context: context)
        case "net.data":
            let id = message["ch"].string!
            guard let stream = streams[id], let target = tunnels[stream.tunnel] else { return [] }
            guard (try? await ports.permits(port: target.port, context: context)) == true else { if streams[id]?.token == stream.token { dropStream(id, flush: false) }; return [try netClosed(id)] }
            guard streams[id]?.token == stream.token, let bytes = Data(base64Encoded: message["data"].string!), !bytes.isEmpty, bytes.count <= Self.chunkBytes else { return [] }
            do { try await stream.socket.write(bytes) }
            catch { if streams[id]?.token == stream.token { dropStream(id, flush: false); return [try netClosed(id)] }; return [] }
            guard streams[id]?.token == stream.token else { return [] }
            return [try .init(.netAck, fields: [.init("ch", .string(id)), .init("bytes", .number(Double(bytes.count)))])]
        case "net.ack":
            let id = message["ch"].string!
            guard var stream = streams[id] else { return [] }
            guard let amount = message["bytes"].number, amount.isFinite, amount.rounded() == amount, amount > 0, amount <= Double(stream.unacked) else { dropStream(id, flush: false); return [try netClosed(id)] }
            stream.unacked -= Int(amount)
            if stream.unacked < Self.windowBytes { let credit = stream.credit; stream.credit = nil; streams[id] = stream; credit?.resume() }
            else { streams[id] = stream }
            return []
        case "net.close": dropStream(message["ch"].string!, flush: true); return []
        default: throw NativeRPCError.invalidArguments("This is not a localhost message")
        }
    }
    public func list() -> [BackendRemoteServeTransportTunnelInfo] {
        tunnels.values.map { .init(id: $0.id, port: $0.port, streams: $0.streams.count, openedAt: $0.openedAt) }.sorted { $0.openedAt < $1.openedAt }
    }
    public func stop(id: String, message: String = "Stopped from the desktop.") async throws -> Bool {
        guard closeTunnel(id) else { return false }
        try await wire.send(connectionID: connectionID, message: tunnelClosed(id, message)); return true
    }
    public func closeAll() {
        closed = true; opening.removeAll()
        for id in Array(streams.keys) { dropStream(id, flush: false) }
        let drains = closing; closing = [:]
        for drain in drains.values { drain.socket.discard(); drain.task.cancel(); budget.give() }
        let had = !tunnels.isEmpty; tunnels.removeAll(); if had { changed() }
    }
    public func waitForDrains() async { let tasks = closing.values.map(\.task); for task in tasks { await task.value } }
    private static let chunkBytes = BackendRemoteProtocol.limits["MAX_NET_CHUNK_BYTES"]!
    private static let windowBytes = BackendRemoteProtocol.limits["NET_WINDOW_BYTES"]!
    private func openTunnel(_ id: String, port: Int, context: BackendRemoteHostContext) async throws -> [BackendRemoteServerMessage] {
        guard tunnels[id] == nil, opening[id] == nil else { return [try tunnelClosed(id, "A tunnel with that id is already open.")] }
        guard tunnels.count + opening.count < Self.maximumTunnels else { return [try tunnelClosed(id, "This phone already has 4 ports open. Close one first.")] }
        let token = Opening(); opening[id] = token
        defer { if opening[id] === token { opening[id] = nil } }
        let reserved = await ports.reservedPorts()
        let offered = reserved.contains(port) ? [] : ((try? await ports.scan(context: context)) ?? [])
        guard !closed, opening[id] === token else { return [] }
        guard let entry = offered.first(where: { $0.port == port }) else {
            return [try tunnelClosed(id, "Nothing is listening on port \(port) on that computer any more.")]
        }
        let tried = BackendRemoteServeTransportLoopback.candidates(ipv4: entry.ipv4, ipv6: entry.ipv6)
        var winner: BackendRemoteServeTransportLoopback?
        for candidate in tried {
            let reachable = await sockets.probe(port: port, host: candidate, timeoutMilliseconds: Self.dialTimeoutMilliseconds)
            guard !closed, opening[id] === token else { return [] }
            if reachable { winner = candidate; break }
        }
        guard let winner else {
            return [try tunnelClosed(id, "Port \(port) is listed as listening but refused a connection on \(tried.map(\.rawValue).joined(separator: " and ")). Whatever holds it is not accepting connections.")]
        }
        guard !closed, opening[id] === token else { return [] }
        let permitted = (try? await ports.permits(port: port, context: context)) == true
        guard !closed, opening[id] === token else { return [] }
        guard permitted else { return [try tunnelClosed(id, "That port is no longer permitted.")] }
        tunnels[id] = Tunnel(id: id, port: port, host: winner, openedAt: clock(), context: context); changed()
        return [try .init(.tunnelOpened, fields: [.init("id", .string(id)), .init("port", .number(Double(port)))])]
    }
    private func closeTunnel(_ id: String) -> Bool {
        if opening.removeValue(forKey: id) != nil { return true }
        guard let tunnel = tunnels.removeValue(forKey: id) else { return false }
        for stream in tunnel.streams { dropStream(stream, flush: false) }
        changed(); return true
    }
    private func openStream(_ id: String, tunnel tunnelID: String, context: BackendRemoteHostContext) async throws -> [BackendRemoteServerMessage] {
        guard let tunnel = tunnels[tunnelID], (try? await ports.permits(port: tunnel.port, context: context)) == true,
              !closed, tunnels[tunnelID]?.token == tunnel.token, streams[id] == nil, streams.count + closing.count < Self.maximumStreamsPerConnection else { return [try netClosed(id)] }
        guard budget.take() else { return [try netClosed(id)] }
        let socket: any BackendRemoteServeTransportSocket
        do { socket = try sockets.connect(port: tunnel.port, host: tunnel.host) }
        catch { budget.give(); return [try netClosed(id)] }
        let token = UUID()
        streams[id] = Stream(token: token, tunnel: tunnelID, socket: socket)
        tunnels[tunnelID]?.streams.insert(id); changed()
        streams[id]?.task = Task { [weak self] in await self?.readStream(id, token: token, socket: socket) }
        return []
    }
    private func readStream(_ id: String, token: UUID, socket: any BackendRemoteServeTransportSocket) async {
        do {
            try await socket.ready(timeoutMilliseconds: Self.dialTimeoutMilliseconds)
            while streams[id]?.token == token {
                guard let tunnelID = streams[id]?.tunnel, let tunnel = tunnels[tunnelID], (try? await ports.permits(port: tunnel.port, context: tunnel.context)) == true else { throw NativeRPCError(code: "access-denied", message: "The localhost grant was withdrawn") }
                guard streams[id]?.token == token else { return }
                if (streams[id]?.unacked ?? 0) >= Self.windowBytes {
                    await withCheckedContinuation { streams[id]?.credit = $0 }
                }
                guard streams[id]?.token == token, !Task.isCancelled else { return }
                let read = try await socket.read(maximumBytes: 65_536)
                guard streams[id]?.token == token else { return }
                guard (try? await ports.permits(port: tunnel.port, context: tunnel.context)) == true else { throw NativeRPCError(code: "access-denied", message: "The localhost grant was withdrawn") }
                guard streams[id]?.token == token else { return }
                for start in stride(from: 0, to: read.data.count, by: Self.chunkBytes) {
                    let piece = read.data.subdata(in: start..<min(start + Self.chunkBytes, read.data.count))
                    streams[id]?.unacked += piece.count
                    try await wire.send(connectionID: connectionID, message: .init(.netData, fields: [.init("ch", .string(id)), .init("data", .string(piece.base64EncodedString()))]))
                    guard streams[id]?.token == token else { return }
                }
                if read.ended { dropStream(id, flush: true); try await wire.send(connectionID: connectionID, message: netClosed(id)); return }
                if read.data.isEmpty { throw NativeRPCError(code: "tunnel-read", message: "The loopback stream returned no data") }
            }
        } catch {
            guard streams[id]?.token == token else { return }
            dropStream(id, flush: false); try? await wire.send(connectionID: connectionID, message: netClosed(id))
        }
    }
    private func dropStream(_ id: String, flush: Bool) {
        guard let stream = streams.removeValue(forKey: id) else { return }
        tunnels[stream.tunnel]?.streams.remove(id); stream.task?.cancel(); stream.credit?.resume()
        if flush {
            let token = UUID()
            let task = Task { [weak self] in await stream.socket.flushAndClose(lingerMilliseconds: Self.flushLingerMilliseconds); await self?.finishedDrain(token) }
            closing[token] = Closing(socket: stream.socket, task: task)
        } else { stream.socket.discard(); budget.give() }
    }
    private func finishedDrain(_ token: UUID) { if closing.removeValue(forKey: token) != nil { budget.give() } }
    private func tunnelClosed(_ id: String, _ message: String) throws -> BackendRemoteServerMessage { try .init(.tunnelClosed, fields: [.init("id", .string(id)), .init("message", .string(message))]) }
    private func netClosed(_ id: String) throws -> BackendRemoteServerMessage { try .init(.netClose, fields: [.init("ch", .string(id))]) }
}

/// Registers the complete localhost group and owns its connection cleanup.
public actor BackendRemoteServeTransport {
    private let ports: any BackendRemoteServeTransportPortSource, wire: any BackendRemoteServeTransportWire
    private let sockets: any BackendRemoteServeTransportSocketFactory
    private let budget = BackendRemoteServeTransportStreamBudget()
    private let changed: @Sendable () -> Void
    private var hubs: [UUID: BackendRemoteServeTransportTunnelHub] = [:]
    private var stopped = false
    public init(ports: any BackendRemoteServeTransportPortSource, wire: any BackendRemoteServeTransportWire,
                sockets: any BackendRemoteServeTransportSocketFactory = BackendRemoteServeTransportTCPFactory(), onChange: @escaping @Sendable () -> Void = {}) {
        self.ports = ports; self.wire = wire; self.sockets = sockets; changed = onChange
    }
    public nonisolated func feature() -> BackendRemoteHostFeature {
        .init(capability: "localhost", messageTypes: ["ports", "tunnel.open", "tunnel.close", "net.open", "net.data", "net.ack", "net.close"], policy: .grantedDevice) { [weak self] message, context in
            guard let self else { throw NativeRPCError(code: "unavailable", message: "The localhost tunnel service stopped") }
            return try await self.handle(message, context: context)
        }
    }
    public func handle(_ message: BackendRemoteClientMessage, context: BackendRemoteHostContext) async throws -> [BackendRemoteServerMessage] {
        guard !stopped else { throw NativeRPCError(code: "unavailable", message: "The native localhost transport stopped") }
        let hub: BackendRemoteServeTransportTunnelHub
        if let existing = hubs[context.connectionID] { hub = existing }
        else { hub = .init(connectionID: context.connectionID, ports: ports, wire: wire, sockets: sockets, budget: budget, onChange: changed); hubs[context.connectionID] = hub }
        return try await hub.handle(message, context: context)
    }
    public func list(connectionID: UUID) async -> [BackendRemoteServeTransportTunnelInfo] { await hubs[connectionID]?.list() ?? [] }
    public func stop(connectionID: UUID, tunnelID: String) async throws -> Bool { try await hubs[connectionID]?.stop(id: tunnelID) ?? false }
    public func connectionClosed(_ id: UUID) async { await hubs.removeValue(forKey: id)?.closeAll() }
    public func stop() async { stopped = true; let old = hubs; hubs = [:]; for hub in old.values { await hub.closeAll() } }
}

public enum BackendRemoteServeTransportChannels {
    public static func register(registry: NativeChannelRegistry, service: BackendRemoteServeTransport,
                                connections: @escaping @Sendable () async throws -> NativeRPCValue,
                                ownerID: String = "remote-serve-tunnels") async throws {
        try await registry.register("remote:tunnel:stop", ownerID: ownerID, policy: { context in
            guard context.caller == .nativeApp || context.caller == .internalEngine else { throw NativeRPCError(code: "access-denied", message: "Only this app's owner may stop a remote tunnel") }
        }) { context, args in
            if let raw = context.argument(0, in: args).string, let connection = UUID(uuidString: raw), let tunnel = context.argument(1, in: args).string {
                _ = try await service.stop(connectionID: connection, tunnelID: tunnel)
            }
            return try await connections()
        }
    }
}
