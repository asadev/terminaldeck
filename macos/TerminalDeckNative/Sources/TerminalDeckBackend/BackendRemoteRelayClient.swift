import Foundation
import Network
import TerminalDeckNativeCore

public struct BackendRemoteRelayState: Sendable {
    public let url: String
    public let hostID: String
    public let publicKey: String
    public let fingerprint: String
    public let connected: Bool
    public let channels: Int
    public let reason: String?
    public let retryAt: Double?
}
public struct BackendRemoteRelayMCPReply: Sendable {
    public let status: Int
    public let contentType: String?
    public let body: Data
    public init(status: Int, contentType: String?, body: Data) { self.status = status; self.contentType = contentType; self.body = body }
}

/// One relay socket and independent authenticated Noise transport per channel.
/// Relay loss closes all endpoint handles and aborts every in-flight MCP task.
public actor BackendRemoteRelayClient {
    public typealias MCPHandler = @Sendable (BackendRelayPacketCodec.MCPRequestHead, Data) async throws -> BackendRemoteRelayMCPReply
    private let url: URL
    private let identity: BackendRemoteHostIdentity
    private let trust: BackendRemoteTrustStore?
    private let host: BackendRemoteHost?
    private let beaconOffer: String?
    private let mcp: MCPHandler?
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var connectDeadline: Task<Void, Never>?
    private var pongDeadline: Task<Void, Never>?
    private var stopped = true
    private var connected = false
    private var attempts = 0
    private var reason: String?
    private var retryAt: Double?
    private var channels: [Data: Channel] = [:]
    private var mcpPending: [Data: Task<Void, Never>] = [:]
    private var queuedBytes = 0
    private var generation = UUID()
    private var readyWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    public var onState: (@Sendable (BackendRemoteRelayState) -> Void)?
    /// 31 Oct (Macky study: it stayed offline after sleep or a network change until "Go Online" was pressed): the
    /// network coming back dials at once, with a fresh backoff. Started with the client, cancelled with it.
    private var pathMonitor: NWPathMonitor?
    private var pathSatisfied = true
    /// Every live client, for `nudgeAll` (the app calls it when the Mac wakes or the screen unlocks).
    private static let live = BackendRemoteRelayLive()
    /// A ping every `heartbeatSeconds`; no pong within `pongSeconds` (three missed beats) ends the link.
    static let heartbeatSeconds = 10, pongSeconds = 30
    /// Retry delays double from 1 s to at most 30 s, each spread by ±20 % so many phones and Macs never retry together.
    static func retryDelay(attempt: Int, jitter: Double = Double.random(in: 0.8...1.2)) -> Int {
        min(30_000, Int((Double(1_000 * (1 << min(max(attempt, 1) - 1, 5))) * jitter).rounded()))
    }
    private struct Channel: Sendable {
        var transport: BackendSealedTransport?
        var endpoint: UUID?
        var peer: Data?
        var chain: Task<Void, Never>?
    }
    public init(url: String, identity: BackendRemoteHostIdentity, trust: BackendRemoteTrustStore, host: BackendRemoteHost, mcp: MCPHandler? = nil) throws {
        self.url = try Self.target(url); self.identity = identity; self.trust = trust; self.host = host; self.mcp = mcp; beaconOffer = nil
    }
    init(url: String, identity: BackendRemoteHostIdentity, beaconOffer: String) throws {
        self.url = try Self.target(url); self.identity = identity; self.beaconOffer = beaconOffer; trust = nil; host = nil; mcp = nil
    }
    /// Where the relay link says what it is doing (the app's log). One line on connect, one when it ends or fails.
    private static let logLock = NSLock()
    nonisolated(unsafe) private static var logSink: (@Sendable (String) -> Void)?
    public static func setLog(_ sink: (@Sendable (String) -> Void)?) { logLock.withLock { logSink = sink } }
    public static func note(_ line: String) { let sink = logLock.withLock { logSink }; sink?(line) }
    private var lastLogged: String?
    /// The reach frame's payload that says "this Mac serves MCP".
    public static let reachServing = Data([1])
    public func setStateHandler(_ handler: (@Sendable (BackendRemoteRelayState) -> Void)?) { onState = handler }
    public func state() -> BackendRemoteRelayState { .init(url: url.absoluteString, hostID: identity.hostID,
        publicKey: BackendRemoteTrustStorage.base64URL(identity.keys.publicKey), fingerprint: identity.fingerprint,
        connected: connected, channels: channels.count, reason: connected ? nil : reason, retryAt: retryAt) }
    public func start() {
        guard stopped else { return }
        stopped = false
        Self.live.add(self)
        watchNetwork()
        dial()
    }
    public func stop() async {
        stopped = true; retry?.cancel(); retry = nil
        pathMonitor?.cancel(); pathMonitor = nil
        Self.live.remove(self)
        await drop("The relay was stopped.", retrying: false)
    }
    public func ready(timeoutMilliseconds: Int = 6000) async -> Bool {
        if connected { return true }
        if stopped { return false }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            readyWaiters[id] = continuation
            Task { [weak self] in try? await Task.sleep(for: .milliseconds(timeoutMilliseconds)); await self?.expireWaiter(id) }
        }
    }
    private func expireWaiter(_ id: UUID) { readyWaiters.removeValue(forKey: id)?.resume(returning: false) }

    /// Something says the network may be back (it came back, the Mac woke, the screen unlocked): a link that is down
    /// dials now with a fresh backoff instead of waiting out its retry; a link that is up checks itself with a ping.
    public func nudge(_ why: String) async {
        guard !stopped else { return }
        if connected { await ping(generation); return }
        Self.note("relay: \(why) Connecting again now.")
        attempts = 0
        retry?.cancel(); retry = nil
        if socket == nil { dial() }
    }

    /// Every live relay client checks itself (the Mac woke, the screen unlocked).
    public static func nudgeAll(_ why: String) {
        for client in live.all() { Task { await client.nudge(why) } }
    }

    private func watchNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { await self?.pathChanged(satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "dev.terminaldeck.relay.path"))
        pathMonitor = monitor
    }

    private func pathChanged(_ satisfied: Bool) async {
        let cameBack = satisfied && !pathSatisfied
        pathSatisfied = satisfied
        if cameBack { await nudge("The network came back.") }
    }
    private func dial() {
        guard !stopped, socket == nil else { return }
        generation = UUID(); let epoch = generation
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.path = BackendRelayPacketCodec.hostPath; components.query = nil; components.fragment = nil
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.setValue(BackendRemoteTrustStorage.base64URL(identity.hostSecret), forHTTPHeaderField: BackendRelayPacketCodec.secretHeader)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = .infinity
        let delegate = BackendRemoteRelayDelegate(opened: { [weak self] in Task { await self?.opened(epoch) } },
            failed: { [weak self] in Task { await self?.failed(epoch) } })
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        let socket = session.webSocketTask(with: request); socket.maximumMessageSize = 98321
        self.session = session; self.socket = socket
        connected = false; reason = "Connecting to the relay…"; retryAt = nil; announce()
        socket.resume()
        connectDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15)); guard !Task.isCancelled else { return }
            await self?.connectExpired(epoch)
        }
        receiver = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    if case .data(let data) = message { await self?.packet(data, epoch: epoch) }
                    // Text is ignored like source relay-client: probes cannot
                    // disconnect actual session channels.
                }
            } catch { await self?.failed(epoch) }
        }
    }
    private func opened(_ epoch: UUID) async {
        guard epoch == generation, !stopped, !connected else { return }
        connectDeadline?.cancel(); connectDeadline = nil
        connected = true; attempts = 0; reason = nil; retryAt = nil
        for waiter in readyWaiters.values { waiter.resume(returning: true) }; readyWaiters = [:]
        announce()
        Self.note("relay: connected to \(url.host ?? "the relay") as host \(identity.hostID); the tools door (MCP) is \(mcp != nil ? "open" : "not offered")."); lastLogged = nil
        // The relay marks this Mac as serving MCP only when the reach frame's first byte is 1 (relay rendezvous.ts
        // fromHostMcp; the Electron app sent [on ? 1 : 0]). An empty payload read as "not serving", so every
        // AI app or CRM calling https://relay…/mcp/<host> got 404 "Nothing answered at this address" (CRM-LINK, 12 Oct).
        // The internet switch for keys is still enforced per request on this Mac (answerRelay → keys.internet()).
        if mcp != nil { try? await envelope(.mcpReach, channel: BackendRelayPacketCodec.noRequest, payload: Self.reachServing) }
        if host != nil { await BackendRCVRelayLink.shared.opened { [weak self] type, channel, payload in
            try await self?.receiverEnvelope(type, channel: channel, payload: payload, epoch: epoch)
        } } // RCV
        heartbeat = Task { [weak self] in
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(Self.heartbeatSeconds)); guard !Task.isCancelled else { return }; await self?.ping(epoch) }
        }
    }
    private func connectExpired(_ epoch: UUID) async { if epoch == generation && !connected { await drop("The relay did not finish connecting.") } }
    private func failed(_ epoch: UUID) async { if epoch == generation && !stopped { await drop("The connection to the relay ended.") } }
    private func ping(_ epoch: UUID) async {
        guard epoch == generation, let socket, connected else { return }
        // One deadline per outstanding ping: a beat whose pong is late does not move the deadline (three missed beats end it).
        if pongDeadline == nil {
            pongDeadline = Task { [weak self] in try? await Task.sleep(for: .seconds(Self.pongSeconds)); guard !Task.isCancelled else { return }; await self?.failed(epoch) }
        }
        do { try await socket.backendSendPing(); pongDeadline?.cancel(); pongDeadline = nil } catch { await failed(epoch) }
    }
    private func packet(_ data: Data, epoch: UUID) async {
        guard epoch == generation, let packet = BackendRelayPacketCodec.decodeBoundedHostPacket(data) else { return }
        if !connected { await opened(epoch) }
        switch packet.type {
        case 1:
            guard channels[packet.channel] == nil else { return }
            guard channels.count < 16 else { try? await envelope(.close, channel: packet.channel, payload: Data()); return }
            channels[packet.channel] = Channel(); announce()
        case 2:
            guard let channel = channels[packet.channel] else { return }
            let previous = channel.chain
            let task = Task { [weak self] in await previous?.value; guard !Task.isCancelled else { return }; await self?.channelData(packet.channel, payload: packet.payload, epoch: epoch) }
            channels[packet.channel]?.chain = task
        case 3: await closeChannel(packet.channel)
        case 0x10: await mcpRequest(packet.channel, payload: packet.payload)
        case 0x12: mcpPending.removeValue(forKey: packet.channel)?.cancel()
        case 0x21, 0x23:
            if host != nil {
                let type = packet.type, channel = packet.channel, payload = packet.payload
                Task { await BackendRCVRelayLink.shared.frame(type: type, channel: channel, payload: payload) }
            } // RCV
        default: break
        }
    }
    private func channelData(_ id: Data, payload: Data, epoch: UUID) async {
        guard epoch == generation, let channel = channels[id] else { return }
        if channel.transport == nil {
            do {
                let policy = await trust?.handshakePolicy()
                let response = try BackendSealedHost.respondRelayFrame(identity: identity.keys, frame: payload,
                    approvedKeys: policy?.knownKeys ?? [], permitUnknownPeer: beaconOffer != nil || policy?.permitUnknown == true)
                guard epoch == generation, channels[id] != nil else { return }
                channels[id]?.transport = response.transport; channels[id]?.peer = response.devicePublicKey
                try await envelope(.data, channel: id, payload: response.reply)
                if let beaconOffer { try await channelSend(id, text: beaconOffer); return }
                if let host {
                    let endpoint = await host.accept(.init(address: "relay:" + response.devicePublicKey.map { String(format: "%02x", $0) }.joined(),
                        peerPublicKey: response.devicePublicKey, send: { [weak self] text in try await self?.channelSend(id, text: text) },
                        close: { [weak self] _, _ in await self?.closeChannel(id) }))
                    channels[id]?.endpoint = endpoint
                    if endpoint == nil { await closeChannel(id) }
                }
            } catch { await closeChannel(id) }
            return
        }
        do {
            let clear = try await channel.transport!.receive(payload)
            guard clear.count <= 65536, let text = String(data: clear, encoding: .utf8) else { await closeChannel(id); return }
            // 29 Oct: a read is answered alongside the reads before it, so the next frame is opened at once; any other
            // frame is waited for, as before (BackendRemoteHost.take).
            if let endpoint = channel.endpoint, let host, let taken = await host.take(endpoint, text: text), !taken.alongside { await taken.answered.value }
        } catch { await closeChannel(id) }
    }
    private func channelSend(_ id: Data, text: String) async throws {
        guard let transport = channels[id]?.transport else { throw NativeRPCError(code: "relay-channel", message: "The relay channel is closed") }
        let sealed = try await transport.send(Data(text.utf8))
        try await envelope(.data, channel: id, payload: sealed)
    }
    private func closeChannel(_ id: Data) async {
        guard let channel = channels.removeValue(forKey: id) else { return }
        try? await envelope(.close, channel: id, payload: Data())
        channel.chain?.cancel()
        if let endpoint = channel.endpoint { await host?.closed(endpoint) }
        announce()
    }
    private func mcpRequest(_ id: Data, payload: Data) async {
        guard let mcp, mcpPending[id] == nil, mcpPending.count < 8,
              let request = BackendRelayPacketCodec.decodeMCPRequest(payload), request.body.count <= 65536 else { return }
        let epoch = generation
        mcpPending[id] = Task { [weak self] in
            do {
                let result = try await mcp(request.head, request.body)
                try Task.checkCancellation()
                guard result.body.count <= 8 * 1024 * 1024 else { throw NativeRPCError(code: "relay-mcp", message: "The MCP reply exceeds its bounded size") }
                await self?.mcpReply(id, response: result, epoch: epoch)
            } catch {
                if !Task.isCancelled { await self?.mcpReply(id, response: .init(status: 404, contentType: "application/json", body: Data(BackendRelayPacketCodec.mcpNotFoundBody.utf8)), epoch: epoch) }
            }
            await self?.finishMCP(id)
        }
    }
    private func finishMCP(_ id: Data) { mcpPending[id] = nil }
    private func mcpReply(_ id: Data, response: BackendRemoteRelayMCPReply, epoch: UUID) async {
        guard epoch == generation, mcpPending[id] != nil else { return }
        var at = 0
        repeat {
            let end = min(at + 61440, response.body.count)
            let first = at == 0, last = end == response.body.count
            let flags: UInt8 = (first ? 1 : 0) | (last ? 2 : 0)
            let head = first ? BackendRelayPacketCodec.MCPReplyHead(status: response.status, contentType: response.contentType) : nil
            do { try await envelope(.mcpReply, channel: id, payload: BackendRelayPacketCodec.encodeMCPReply(flags: flags, head: head, chunk: response.body.subdata(in: at..<end))) }
            catch { return }
            at = end
        } while at < response.body.count
    }
    private func envelope(_ kind: BackendRelayPacketCodec.Kind, channel: Data, payload: Data) async throws {
        guard let socket, connected, payload.count <= 98304, queuedBytes + payload.count <= 8 * 1024 * 1024 else { throw NativeRPCError(code: "relay-output", message: "The relay output is unavailable or backed up") }
        let data = try BackendRelayPacketCodec.encodeEnvelope(kind: kind, channel: channel, payload: payload)
        queuedBytes += data.count; defer { queuedBytes -= data.count }
        try await socket.send(.data(data))
    }
    /// RCV: output remains bound to the actual current relay connection.
    func receiverEnvelope(_ type: UInt8, channel: Data, payload: Data, epoch: UUID) async throws {
        guard epoch == generation, BackendRCVWire.isFrame(type), let socket, connected, payload.count <= 98304,
              queuedBytes + payload.count <= 8 * 1024 * 1024 else { throw NativeRPCError(code: "relay-output", message: "The relay output is unavailable or backed up") }
        let data = try BackendRelayPacketCodec.encodeEnvelope(type: type, channel: channel, payload: payload)
        queuedBytes += data.count; defer { queuedBytes -= data.count }
        try await socket.send(.data(data))
    }
    private func drop(_ why: String, retrying: Bool = true) async {
        generation = UUID(); connected = false
        connectDeadline?.cancel(); connectDeadline = nil; pongDeadline?.cancel(); pongDeadline = nil; heartbeat?.cancel(); heartbeat = nil; receiver?.cancel(); receiver = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
        for channel in channels.values { channel.chain?.cancel(); if let endpoint = channel.endpoint { await host?.closed(endpoint) } }
        channels = [:]
        for task in mcpPending.values { task.cancel() }; mcpPending = [:]
        if host != nil { await BackendRCVRelayLink.shared.closed() } // RCV
        reason = why
        // One line per new reason, so a relay that keeps failing the same way does not fill the log.
        if lastLogged != why { lastLogged = why; Self.note("relay: not connected: \(why)\(!stopped && retrying ? " Trying again." : "")") }
        if !stopped && retrying {
            attempts += 1
            let delay = Self.retryDelay(attempt: attempts)
            retryAt = Date().timeIntervalSince1970 * 1000 + Double(delay)
            retry?.cancel(); retry = Task { [weak self] in try? await Task.sleep(for: .milliseconds(delay)); guard !Task.isCancelled else { return }; await self?.retryDial() }
        } else { retryAt = nil; for waiter in readyWaiters.values { waiter.resume(returning: false) }; readyWaiters = [:] }
        announce()
    }
    private func retryDial() { retry = nil; dial() }
    private func announce() { onState?(state()) }
    public static func target(_ raw: String) throws -> URL {
        guard let value = URL(string: raw), value.user == nil, value.password == nil, value.fragment == nil,
              value.scheme == "wss" || value.scheme == "ws" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(value.host?.lowercased() ?? "") else {
            throw NativeRPCError.invalidArguments("A relay must use wss://; ws:// is allowed only on this machine")
        }
        return value
    }
}

private final class BackendRemoteRelayDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    let opened: @Sendable () -> Void
    let failed: @Sendable () -> Void
    init(opened: @escaping @Sendable () -> Void, failed: @escaping @Sendable () -> Void) { self.opened = opened; self.failed = failed }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) { opened() }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) { failed() }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { if error != nil { failed() } }
}

extension URLSessionWebSocketTask {
    /// Foundation only offers the callback form of `sendPing`; this awaits the
    /// pong (or the failure), which is what both relay heartbeats rely on.
    func backendSendPing() async throws {
        // 21 Oct: Foundation can answer one sendPing twice (a socket that drops mid-ping reports its error and then
        // its completion); a continuation resumed twice ends the whole app (crash report 23:07, Asad). Only the first
        // answer counts.
        let once = BackendPingOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            sendPing { error in
                guard once.claim() else { return }
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}

/// One answer per ping: the first caller claims it, every later one is ignored.
private final class BackendPingOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if claimed { return false }; claimed = true; return true }
}

/// The relay clients now running (weakly), so a wake or an unlock reaches each of them.
final class BackendRemoteRelayLive: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [ObjectIdentifier: WeakClient] = [:]
    private struct WeakClient { weak var client: BackendRemoteRelayClient? }
    func add(_ client: BackendRemoteRelayClient) { lock.withLock { clients[ObjectIdentifier(client)] = WeakClient(client: client) } }
    func remove(_ client: BackendRemoteRelayClient) { lock.withLock { clients[ObjectIdentifier(client)] = nil } }
    func all() -> [BackendRemoteRelayClient] { lock.withLock { clients.values.compactMap(\.client) } }
}
