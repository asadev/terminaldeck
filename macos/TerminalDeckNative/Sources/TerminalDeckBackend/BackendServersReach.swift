import Foundation
@preconcurrency import Network
import TerminalDeckNativeCore

public struct BackendServersPort: Codable, Equatable, Sendable {
    public let port: Int, process: String, guessed: Bool, ours: Bool
    public var wireValue: NativeRPCValue { .object([.init("port", .number(Double(port))), .init("process", .string(process)), .init("guessed", .bool(guessed)), .init("ours", .bool(false))]) }
}
public struct BackendServersReachBinding: Sendable {
    public let localPort: Int
    public let close: @Sendable () -> Void
    public init(localPort: Int, close: @escaping @Sendable () -> Void) { self.localPort = localPort; self.close = close }
}
/// Listener/dial authority is supplied by native code, never an IPC argument.
/// The default uses Network.framework; tests supply a deterministic fake.
public struct BackendServersReachNetwork: Sendable {
    public let occupied: @Sendable (Int, Bool) async -> Bool
    public let bind: @Sendable (Int, Bool) async throws -> BackendServersReachBinding
    public init(occupied: @escaping @Sendable (Int, Bool) async -> Bool,
                bind: @escaping @Sendable (Int, Bool) async throws -> BackendServersReachBinding) { self.occupied = occupied; self.bind = bind }
}
/// servers:ports, servers:reach, servers:reach:close. There is no idle reaper:
/// one held connection serves the server's pages until it drops or stop runs.
public actor BackendServersReach {
    private let connections: BackendServersConnections, ownPorts: BackendDevOwnPorts
    private let servers: @Sendable () throws -> [BackendServersStoredServer]
    private let facts: @Sendable (String) async throws -> BackendServersFacts
    private let tunnelsDropped: @Sendable (String) async -> Void
    private let network: BackendServersReachNetwork?
    private let queue = DispatchQueue(label: "native.servers.reach", qos: .userInitiated)
    private struct Held { let token: UUID, lease: BackendServersConnectionLease, client: any BackendServersConnection; let subscription: BackendServersUnsubscribe }
    private struct Holding { let token: UUID, task: Task<Held, Error> }
    private struct Opening { let token: UUID, task: Task<NativeRPCValue, Never> }
    private struct Tunnel { let serverID: String, port: Int, localPort: Int, ipv6: Bool, remoteHost: String, binding: BackendServersReachBinding }
    private struct Stream { let tunnelID: String, local: NWConnection, remote: any BackendServersDuplex; var subscriptions: [BackendServersUnsubscribe] = []; var remoteEnded = false; let sequence = BackendServersForwardSequence() }
    private var held: [String: Held] = [:], holding: [String: Holding] = [:]
    private var tunnels: [String: Tunnel] = [:], streams: [UUID: Stream] = [:], opening: [String: Opening] = [:]
    private var accepting: [UUID: String] = [:], generation = 0
    private var serverEpochs: [String: Int] = [:]
    public init(connections: BackendServersConnections, ownPorts: BackendDevOwnPorts,
                servers: @escaping @Sendable () throws -> [BackendServersStoredServer],
                facts: @escaping @Sendable (String) async throws -> BackendServersFacts,
                tunnelsDropped: @escaping @Sendable (String) async -> Void, network: BackendServersReachNetwork? = nil) {
        self.connections = connections; self.ownPorts = ownPorts; self.servers = servers; self.facts = facts; self.tunnelsDropped = tunnelsDropped; self.network = network
    }
    public static func portsFrom(_ listeners: [BackendServersListenerFact]) -> [BackendServersPort] {
        var ports: [Int: BackendServersPort] = [:]
        for listener in listeners {
            if !listener.program.isEmpty && excluded(listener.program) { continue }
            if let existing = ports[listener.port], !existing.guessed || listener.program.isEmpty { continue }
            ports[listener.port] = .init(port: listener.port, process: listener.program, guessed: listener.program.isEmpty, ours: false)
        }
        return ports.values.sorted { $0.guessed == $1.guessed ? $0.port < $1.port : !$0.guessed }
    }
    private static let notPages: Set<String> = ["rapportd", "sshd", "adb", "sharingd", "launchd", "ControlCe", "Spotify", "Dropbox", "iTunes", "AirPlay", "identityservicesd", "remoted", "Google", "Slack", "Postgres", "postgres", "mysqld", "redis-server", "mongod", "Docker", "System", "System Idle Process", "svchost", "services", "lsass", "wininit", "spoolsv", "sqlservr", "MsMpEng", "vmware-hostd", "com.docker.backend", "systemd-resolve", "systemd-resolved", "chronyd", "ntpd", "named", "dnsmasq", "unbound", "rpcbind", "rpc.statd", "smbd", "nmbd", "cupsd", "dovecot", "mariadbd", "memcached", "postmaster", "slapd"]
    private static func excluded(_ name: String) -> Bool { notPages.contains(name) || notPages.contains(name.components(separatedBy: " ").first ?? name) || notPages.contains(String(name.prefix(9))) }
    private func refused(_ message: String) -> NativeRPCValue { .object([.init("ok", .bool(false)), .init("message", .string(message))]) }
    public func ports(_ serverID: String) async -> NativeRPCValue {
        do {
            guard let name = try servers().first(where: { $0.id == serverID })?.name else { return refused("This app does not know that server.") }
            let facts = self.facts
            return try await connections.withConnection(serverID) { client in
                let measured = try await facts(serverID), listeners = measured.listeners
                let ports = Self.portsFrom(listeners.value ?? [])
                let forwards = await BackendServersForward.askWhetherItForwards(BackendServersForward.forwardOn(client), listening: ports.map(\.port))
                if forwards.known == "no" { return .object([.init("ok", .bool(false)), .init("message", .string(forwards.why ?? BackendServersForward.willNotForward))]) }
                let cannot = forwards.known == "cannot" ? "\(name) could not be asked whether it allows this: \(forwards.why ?? "")" : listeners.why
                return .object([.init("ok", .bool(true)), .init("ports", .array(ports.map(\.wireValue))), .init("cannot", cannot.map(NativeRPCValue.string) ?? .null)])
            }
        } catch { return refused(BackendServersProblem.problemFor(error).sentence) }
    }
    private func hold(_ serverID: String) async throws -> Held {
        if let live = held[serverID] { return live }; if let pending = holding[serverID] { return try await pending.task.value }
        let task = Task<Held, Error> {
            let lease = try await connections.acquireLease(serverID)
            do {
                let client = try await connections.withConnection(serverID) { $0 }, token = UUID()
                let cancel = client.onClose { [weak self] in Task { await self?.dropped(serverID, token: token) } }
                return Held(token: token, lease: lease, client: client, subscription: cancel)
            } catch { await connections.release(lease); throw error }
        }
        let token = UUID(), born = generation, serverBorn = serverEpochs[serverID] ?? 0
        holding[serverID] = .init(token: token, task: task)
        defer { if holding[serverID]?.token == token { holding[serverID] = nil } }
        let answer = try await task.value
        guard generation == born, (serverEpochs[serverID] ?? 0) == serverBorn, !task.isCancelled else { answer.subscription(); await connections.release(answer.lease); throw CancellationError() }
        held[serverID] = answer; return answer
    }
    private func dropped(_ serverID: String, token: UUID) async {
        guard held[serverID]?.token == token else { return }
        await closeServer(serverID); await tunnelsDropped(serverID)
    }
    public func reach(_ serverID: String, port: Int) async -> NativeRPCValue {
        let id = serverID + "\0" + String(port)
        if let open = tunnels[id] { return answer(open) }; if let pending = opening[id] { return await pending.task.value }
        let count = tunnels.values.filter { $0.serverID == serverID }.count + opening.keys.filter { $0.hasPrefix(serverID + "\0") }.count
        if count >= BackendServersForward.maximumTunnels { let name = (try? servers().first { $0.id == serverID }?.name) ?? "This server"; return refused("\(name) already has 4 addresses open here. Close one first.") }
        let token = UUID(), task = Task { await self.open(serverID, port: port, id: id, token: token) }; opening[id] = .init(token: token, task: task)
        let result = await task.value; if opening[id]?.token == token { opening[id] = nil }; return result
    }
    private func open(_ serverID: String, port: Int, id: String, token: UUID) async -> NativeRPCValue {
        guard (1...65535).contains(port) else { return refused("That is not a port this app can open.") }
        do {
            guard let name = try servers().first(where: { $0.id == serverID })?.name else { return refused("This app does not know that server.") }
            let connection = try await hold(serverID), forward = BackendServersForward.forwardOn(connection.client)
            var remoteHost: String?, refusal = BackendServersForwardRefusal.unreachable
            for candidate in ["127.0.0.1", "::1"] {
                switch await forward(candidate, port) { case .opened(let channel): channel.close(); remoteHost = candidate; case .refused(let why, _): refusal = why }
                try Task.checkCancellation(); if remoteHost != nil || refusal == .prohibited { break }
            }
            guard let remoteHost else { return refused(BackendServersForward.whyNot(refusal, port: port, name: name)) }
            var selected: (BackendServersReachBinding, Int, Bool)?
            for ipv6 in [false, true] {
                try Task.checkCancellation()
                if await isOccupied(port: port, ipv6: ipv6) { continue }
                if let bound = try? await bindListener(port: port, ipv6: ipv6, tunnelID: id) { selected = (bound, bound.localPort, ipv6); break }
            }
            if selected == nil { let bound = try await bindListener(port: 0, ipv6: false, tunnelID: id); selected = (bound, bound.localPort, false) }
            guard let selected else { throw CancellationError() }
            do { try Task.checkCancellation(); guard opening[id]?.token == token else { throw CancellationError() } } catch { selected.0.close(); throw error }
            let tunnel = Tunnel(serverID: serverID, port: port, localPort: selected.1, ipv6: selected.2, remoteHost: remoteHost, binding: selected.0)
            tunnels[id] = tunnel; await ownPorts.claim(tunnel.localPort); return answer(tunnel)
        } catch { return refused(BackendServersProblem.problemFor(error).sentence) }
    }
    private func answer(_ tunnel: Tunnel) -> NativeRPCValue {
        .object([.init("ok", .bool(true)), .init("url", .string("http://\(tunnel.ipv6 ? "[::1]" : "127.0.0.1"):\(tunnel.localPort)/")), .init("port", .number(Double(tunnel.port))), .init("localPort", .number(Double(tunnel.localPort))), .init("sameNumber", .bool(tunnel.port == tunnel.localPort))])
    }
    public func closeReach(_ serverID: String, port: Int) async -> Bool {
        let id = serverID + "\0" + String(port); opening.removeValue(forKey: id)?.task.cancel()
        guard let tunnel = tunnels.removeValue(forKey: id) else { return true }
        tunnel.binding.close(); await ownPorts.release(tunnel.localPort)
        accepting = accepting.filter { $0.value != id }
        for streamID in streams.filter({ $0.value.tunnelID == id }).map(\.key) { closeStream(streamID) }; return true
    }
    public func openPorts(_ serverID: String) -> [Int] { tunnels.values.filter { $0.serverID == serverID }.map(\.port).sorted() }
    public func stop() async { generation += 1; for pending in opening.values { pending.task.cancel() }; opening = [:]; for pending in holding.values { pending.task.cancel() }; holding = [:]; accepting = [:]; for serverID in Array(held.keys) { await closeServer(serverID) } }
    public func closeServer(_ serverID: String) async {
        serverEpochs[serverID, default: 0] += 1
        holding.removeValue(forKey: serverID)?.task.cancel()
        for id in opening.keys.filter({ $0.hasPrefix(serverID + "\0") }) { opening.removeValue(forKey: id)?.task.cancel() }
        for port in openPorts(serverID) { _ = await closeReach(serverID, port: port) }
        if let entry = held.removeValue(forKey: serverID) { entry.subscription(); await connections.release(entry.lease) }
    }
    private func accepted(_ local: NWConnection, tunnelID: String) async {
        guard let tunnel = tunnels[tunnelID], let connection = held[tunnel.serverID] else { local.cancel(); return }
        let existing = streams.values.filter { tunnels[$0.tunnelID]?.serverID == tunnel.serverID }.count
        let pending = accepting.values.filter { tunnels[$0]?.serverID == tunnel.serverID }.count
        guard existing + pending < BackendServersForward.maximumStreams else { local.cancel(); return }
        let id = UUID(); accepting[id] = tunnelID
        local.start(queue: queue)
        let remote: any BackendServersDuplex
        do { remote = try await connection.client.forward(host: tunnel.remoteHost, port: tunnel.port) } catch { accepting[id] = nil; local.cancel(); return }
        guard accepting.removeValue(forKey: id) != nil, tunnels[tunnelID] != nil else { remote.close(); local.cancel(); return }
        streams[id] = .init(tunnelID: tunnelID, local: local, remote: remote)
        let sequence = streams[id]!.sequence
        let bytes = remote.onBytes { [weak self] chunk in remote.pause(); sequence.append { [weak self] in await self?.deliver(id, bytes: chunk); remote.resume() } }
        let end = remote.onEnd { [weak self] in sequence.append { [weak self] in await self?.endRemote(id) } }
        let close = remote.onClose { [weak self] in sequence.append { [weak self] in await self?.finishRemote(id) } }
        streams[id]?.subscriptions = [bytes, end, close]
        Task { [weak self] in await self?.readLocal(id) }
    }
    private func readLocal(_ id: UUID) async {
        do {
            while let stream = streams[id] {
                let piece: (Data, Bool) = try await withCheckedThrowingContinuation { continuation in stream.local.receive(minimumIncompleteLength: 1, maximumLength: BackendServersForward.maximumChunkBytes) { bytes, _, done, error in if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: (bytes ?? Data(), done)) } } }
                if !piece.0.isEmpty { try await stream.remote.write(piece.0) }
                if piece.1 { try await stream.remote.end(); return }
            }
        } catch { closeStream(id) }
    }
    private func deliver(_ id: UUID, bytes: Data) async {
        guard let stream = streams[id] else { return }
        do { try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in stream.local.send(content: bytes, completion: .contentProcessed { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } }) } }
        catch { closeStream(id) }
    }
    private func endRemote(_ id: UUID) async {
        guard let stream = streams[id], !stream.remoteEnded else { return }; streams[id]?.remoteEnded = true
        do { try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in stream.local.send(content: nil, isComplete: true, completion: .contentProcessed { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } }) } }
        catch { closeStream(id) }
    }
    private func finishRemote(_ id: UUID) async { await endRemote(id); closeStream(id) }
    private func closeStream(_ id: UUID) { guard let stream = streams.removeValue(forKey: id) else { return }; for cancel in stream.subscriptions { cancel() }; stream.remote.close(); stream.local.cancel() }
    private func bind(port: Int, ipv6: Bool, tunnelID: String) async throws -> (NWListener, Int) {
        let parameters = NWParameters.tcp; parameters.requiredLocalEndpoint = .hostPort(host: ipv6 ? .ipv6(.loopback) : .ipv4(.loopback), port: port == 0 ? .any : NWEndpoint.Port(rawValue: UInt16(port))!)
        let listener = try NWListener(using: parameters), gate = BackendServersSSHOnce<Int>()
        listener.stateUpdateHandler = { state in switch state { case .ready: if let port = listener.port { gate.finish(.success(Int(port.rawValue))) }; case .failed(let error): gate.finish(.failure(error)); case .cancelled: gate.finish(.failure(CancellationError())); default: break } }
        listener.newConnectionHandler = { [weak self] in let connection = $0; Task { await self?.accepted(connection, tunnelID: tunnelID) } }
        listener.start(queue: queue)
        let deadline = Task { do { try await Task.sleep(for: .milliseconds(5000)); gate.finish(.failure(CancellationError())); listener.cancel() } catch {} }; defer { deadline.cancel() }
        do { return try await withTaskCancellationHandler { (listener, try await gate.value()) } onCancel: { listener.cancel(); gate.finish(.failure(CancellationError())) } }
        catch { listener.cancel(); throw error }
    }
    private func bindListener(port: Int, ipv6: Bool, tunnelID: String) async throws -> BackendServersReachBinding {
        if let network { return try await network.bind(port, ipv6) }
        let native = try await bind(port: port, ipv6: ipv6, tunnelID: tunnelID)
        return .init(localPort: native.1, close: { native.0.cancel() })
    }
    private func isOccupied(port: Int, ipv6: Bool) async -> Bool { if let network { return await network.occupied(port, ipv6) }; return await occupied(port: port, ipv6: ipv6) }
    private func occupied(port: Int, ipv6: Bool) async -> Bool {
        let connection = NWConnection(host: ipv6 ? .ipv6(.loopback) : .ipv4(.loopback), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp), gate = BackendServersSSHOnce<Bool>()
        connection.stateUpdateHandler = { state in switch state { case .ready: gate.finish(.success(true)); connection.cancel(); case .failed(let error): if case .posix(let code) = error, code == .ECONNREFUSED { gate.finish(.success(false)) } else { gate.finish(.success(true)) }; connection.cancel(); case .cancelled: gate.finish(.success(true)); default: break } }
        connection.start(queue: queue)
        let deadline = Task { do { try await Task.sleep(for: .milliseconds(600)); gate.finish(.success(true)); connection.cancel() } catch {} }; defer { deadline.cancel() }
        return (try? await withTaskCancellationHandler { try await gate.value() } onCancel: { connection.cancel(); gate.finish(.success(true)) }) ?? true
    }
}
