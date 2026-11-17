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
    /// The key was wrong or unknown (told to the relay in the reply head, never to the caller).
    public let refused: Bool
    public init(status: Int, contentType: String?, body: Data, refused: Bool = false) { self.status = status; self.contentType = contentType; self.body = body; self.refused = refused }
}

/// 15 Nov (AI apps through our server): whether this Mac lets AI apps in through the relay right now, i.e.
/// "Let AI apps use this Mac" is on. Every live relay client says it to the relay (frame 0x13, [1] or [0]) when it
/// connects and whenever it changes, so the relay forwards only while it is on and answers 404 otherwise. With no
/// provider set yet the answer is "not now" [0] (review-fixes 6: nothing is "serving" before the switch is read); the
/// key door still refuses per request on this Mac either way.
public final class BackendRelayMCPServing: @unchecked Sendable {
    public static let shared = BackendRelayMCPServing()
    private let lock = NSLock()
    private var provider: (@Sendable () async -> Bool)?
    public init() {}
    public func setProvider(_ provider: (@Sendable () async -> Bool)?) { lock.withLock { self.provider = provider } }
    public func serving() async -> Bool {
        guard let provider = lock.withLock({ provider }) else { return false }
        return await provider()
    }
    private var follower: (@Sendable () async -> Void)?
    /// review-fixes 1: told after every change (the remote host service starts or stops its AI-apps-only link).
    public func setFollower(_ follower: (@Sendable () async -> Void)?) { lock.withLock { self.follower = follower } }
    /// The switch (or the key door) changed: every live relay client re-says it.
    public func changed() async {
        for client in BackendRemoteRelayClient.liveClients() { await client.mcpServingChanged() }
        if let follower = lock.withLock({ follower }) { await follower() }
    }
}

/// review-fixes 6 (15 Nov): what one relay connection last told the relay about serving MCP, told by one caller at a
/// time. A call while another is under way only asks it to read again; after every send the switch is read again and
/// said again if it moved, so the relay always ends on the switch's latest value.
actor BackendRelayServingTeller {
    private(set) var said: Bool?
    private var saying = false, again = false
    /// `live` is false once this connection is gone; `send` throws when it could not be said (said again next time).
    func tell(read: @escaping @Sendable () async -> Bool, live: @escaping @Sendable () async -> Bool,
              send: @escaping @Sendable (Bool) async throws -> Void) async {
        guard !saying else { again = true; return }
        saying = true
        defer { saying = false }
        repeat {
            again = false
            guard await live() else { return }
            let on = await read()
            guard await live() else { return }
            if said != on {
                said = on
                do { try await send(on) } catch { said = nil; return }
            }
            if await read() != on { again = true }
        } while again
    }
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
    /// What this connection last told the relay about serving MCP (nil: nothing yet on this connection).
    private var mcpTeller = BackendRelayServingTeller()
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
    /// relay-drops (2 Nov): the relay's edge resets idle-looking links every 1–3 min, so the first redial after a
    /// drop is immediate (the phones' blink was the 1 s wait plus their own); later attempts keep the back-off.
    static func redialDelay(attempt: Int, jitter: Double = Double.random(in: 0.8...1.2)) -> Int {
        attempt <= 1 ? 0 : retryDelay(attempt: attempt - 1, jitter: jitter)
    }
    /// The real reason per drop, so the log tells a TCP reset, a close by the relay and missed keepalives apart.
    static func dropReason(_ error: Error?) -> String {
        guard let error = error as NSError? else { return "The connection to the relay ended." }
        let code = "\(error.domain) \(error.code)"
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ECONNRESET) { return "The relay's connection was reset (TCP reset, \(code))." }
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorNetworkConnectionLost { return "The relay's connection was reset (network connection lost, \(code))." }
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorNotConnectedToInternet { return "This Mac is offline (\(code))." }
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorTimedOut { return "The relay connection timed out (\(code))." }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ECONNRESET) {
            return "The relay's connection was reset (TCP reset, \(code), POSIX \(underlying.code))."
        }
        return "The connection to the relay failed (\(error.domain) \(error.code))."
    }
    static func closeReason(code: Int, reason: Data?) -> String {
        let words = reason.flatMap { String(data: $0, encoding: .utf8) }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return "The relay closed the connection (close code \(code)\(words.isEmpty ? "" : ": " + String(words.prefix(120))))."
    }
    static let missedKeepalives = "The relay stopped answering (3 missed keepalives)."
    /// The relay (c74cc652) answers the text `td-ping` with `td-pong` from its edge, keeping the link warm, and reaps
    /// a Mac that used it and then went quiet for 30 s. Sent every 10 s beside the protocol ping.
    static let textPing = "td-ping"
    static let textPingSeconds: UInt64 = 10
    private struct Channel: Sendable {
        var transport: BackendSealedTransport?
        var endpoint: UUID?
        var peer: Data?
        var chain: Task<Void, Never>?
        /// Reach by account: the device id from the relay's open mark (`0x52 0x01` + id); nil = a paired join.
        var account: String?
    }
    /// Reach by account (R2): the door and the relay token live in ONE place for this process
    /// (`BackendReachRelayLink`), so a relay client started later picks them up. Never set in the boot helper.
    /// The current link was dialed with this token; a link that never opened then refuses that token (falls back to
    /// an untied dial), so a refused or stale token can never keep pairing out.
    private var dialedWithToken: String?
    private var refusedToken: String?
    /// connect-fix (17 Nov): right after a start, the first dial waits up to this long for the account token, so a
    /// start costs the phones one relay connection instead of two (untied, then tied again a moment later).
    static let firstDialTokenWaitMs = 2_000
    private var firstDialWait: Task<Void, Never>?
    /// connect-fix (17 Nov): only the relay's own answer to the token refuses it (its Worker answers 403 to a host dial
    /// whose token does not verify). A network error, a timeout or a reset leaves the token as it is, so the Mac never
    /// rejoins untied (which refused every phone signing in by account for minutes) because the network blinked.
    static func relayRefusedToken(httpStatus: Int?) -> Bool { httpStatus == 403 }
    /// connect-fix (17 Nov): the WebSocket close code and the relay's short reason, added to a drop's socket error, so
    /// a close by the relay or Cloudflare can be told apart from a reset. Numbers and the short reason only.
    static func withCloseCode(_ why: String, code: Int, reason: Data?) -> String {
        guard code != URLSessionWebSocketTask.CloseCode.invalid.rawValue, !why.hasPrefix("The relay closed the connection") else { return why }
        let words = reason.flatMap { String(data: $0, encoding: .utf8) }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return why + " (close code \(code)\(words.isEmpty ? "" : ": " + String(words.prefix(120))))"
    }
    /// Tests: whether a start is still waiting for the account token before its first dial.
    func waitingForToken() -> Bool { firstDialWait != nil }
    public init(url: String, identity: BackendRemoteHostIdentity, trust: BackendRemoteTrustStore, host: BackendRemoteHost, mcp: MCPHandler? = nil) throws {
        self.url = try Self.target(url); self.identity = identity; self.trust = trust; self.host = host; self.mcp = mcp; beaconOffer = nil
    }
    /// 15 Nov (review-fixes 1): the AI-apps-only link. Started when "Let AI apps use this Mac" is on while remote
    /// access is off, so the address works by itself. It carries the tools door (MCP) and nothing else: no host, no
    /// trust store, no account token, no Receiver; every channel a phone or browser tries to open is closed at once,
    /// so starting it never lets a device in (that stays remote access's own switch).
    public init(url: String, identity: BackendRemoteHostIdentity, aiAppsOnly mcp: @escaping MCPHandler) throws {
        self.url = try Self.target(url); self.identity = identity; self.mcp = mcp; trust = nil; host = nil; beaconOffer = nil
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
    /// ...and the one that says "not now" (the relay then answers every AI app 404 without asking this Mac).
    public static let reachNotServing = Data([0])
    public func setStateHandler(_ handler: (@Sendable (BackendRemoteRelayState) -> Void)?) { onState = handler }
    public func state() -> BackendRemoteRelayState { .init(url: url.absoluteString, hostID: identity.hostID,
        publicKey: BackendRemoteTrustStorage.base64URL(identity.keys.publicKey), fingerprint: identity.fingerprint,
        connected: connected, channels: channels.count, reason: connected ? nil : reason, retryAt: retryAt) }
    public func start() {
        guard stopped else { return }
        stopped = false
        Self.live.add(self)
        watchNetwork()
        // connect-fix (17 Nov): a start before the account token is ready waits briefly for it (it ends at once when
        // the token arrives, `reachTokenChanged`), so phones see one connection per start, tied from the first dial.
        if beaconOffer == nil, host != nil, BackendReachRelayLink.shared.token == nil, Self.firstDialTokenWaitMs > 0 {
            firstDialWait = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Self.firstDialTokenWaitMs)); guard !Task.isCancelled else { return }
                await self?.firstDialDue()
            }
        } else { dial() }
    }
    private func firstDialDue() { firstDialWait = nil; dial() }
    public func stop() async {
        stopped = true; retry?.cancel(); retry = nil
        firstDialWait?.cancel(); firstDialWait = nil
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

    /// One device's TURN login (Security M2): its ICE servers and when the Worker says it expires (Unix ms).
    public struct TURNLogin: Sendable, Equatable {
        public var servers: [BackendPhonePeerServer]
        public var expiresAtMs: Double
        /// The Worker's id for this login (32 hex): a withdrawal naming it touches only this login (Security R1).
        public var login: String?
        public init(servers: [BackendPhonePeerServer], expiresAtMs: Double, login: String? = nil) {
            self.servers = servers; self.expiresAtMs = expiresAtMs; self.login = login
        }
    }

    /// stream step 2 (2 Nov; relay lane/relay-turn-revoke, contract "TURN per device + revoke" in
    /// stream-anywhere-contract.md): ONE short-lived Cloudflare Realtime TURN login for one paired device from this
    /// relay's Worker (`POST /v1/turn {"device","ttl"}`). Asking again for the same device withdraws its previous login,
    /// so the caller caches per device. Only while this Mac's relay socket is open. It goes to that device only, inside
    /// the sealed channel. Nil when the Worker gives none (not deployed, not configured, refused): STUN only.
    public func turnLogin(device: String, ttl: Int = 3_600) async -> TURNLogin? {
        guard connected, let (data, status) = await workerPost("/v1/turn", body: ["device": .string(device), "ttl": .number(Double(max(60, min(3_600, ttl))))]),
              status == 200, let value = try? NativeRPCValue.parseJSON(data), value["ok"].bool == true, value["device"].string == device else { return nil }
        let servers = (value["iceServers"].elements ?? []).prefix(8).compactMap { row -> BackendPhonePeerServer? in
            let urls = (row["urls"].elements?.compactMap(\.string) ?? row["urls"].string.map { [$0] } ?? [])
                .filter { $0.hasPrefix("stun:") || $0.hasPrefix("turn:") || $0.hasPrefix("turns:") }
            return urls.isEmpty ? nil : BackendPhonePeerServer(urls: urls, username: row["username"].string, credential: row["credential"].string)
        }
        guard !servers.isEmpty else { return nil }
        let expires = value["expiresAtMs"].number ?? (Date().timeIntervalSince1970 * 1_000 + Double(value["ttl"].number ?? 3_600) * 1_000)
        let login = value["login"].string.flatMap { $0.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil ? $0 : nil }
        return TURNLogin(servers: Array(servers), expiresAtMs: expires, login: login)
    }

    /// Withdraws a device's TURN login (`POST /v1/turn/revoke {"device","login"?}`; needs only the host secret, not an open
    /// socket). With `login`: only that login, and only while it is still the device's current one (its last link
    /// closed); without: whatever the device holds (unpaired, access off). True when the Worker answered 200 (withdrawn
    /// or nothing held); false means try again later (502/503/no answer).
    public func revokeTURN(device: String, login: String? = nil) async -> Bool {
        var body: [String: NativeRPCValue] = ["device": .string(device)]
        if let login { body["login"] = .string(login) }
        guard let (data, status) = await workerPost("/v1/turn/revoke", body: body), status == 200,
              let value = try? NativeRPCValue.parseJSON(data), value["ok"].bool == true else { return false }
        return true
    }

    /// A POST to this relay's Worker with the host secret (TURN asks and withdrawals): the body and the status.
    private func workerPost(_ path: String, body: [String: NativeRPCValue]) async -> (Data, Int)? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme == "ws" ? "http" : "https"
        components.path = path; components.query = nil; components.fragment = nil
        guard let target = components.url,
              let payload = try? NativeRPCValue.object(body.keys.sorted().map { .init($0, body[$0]!) }).encodedJSON() else { return nil }
        var request = URLRequest(url: target, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue(BackendRemoteTrustStorage.base64URL(identity.hostSecret), forHTTPHeaderField: BackendRelayPacketCodec.secretHeader)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = payload
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request), let status = (response as? HTTPURLResponse)?.statusCode,
              data.count <= 16_384 else { return nil }
        return (data, status)
    }

    /// A device's TURN login from whichever live relay client gives one first.
    public static func liveTURNLogin(device: String, ttl: Int = 3_600) async -> TURNLogin? {
        for client in live.all() { if let login = await client.turnLogin(device: device, ttl: ttl) { return login } }
        return nil
    }

    /// Withdraws a device's TURN login through the live relay clients (true when one of them got a 200).
    public static func liveRevokeTURN(device: String, login: String? = nil) async -> Bool {
        for client in live.all() where await client.revokeTURN(device: device, login: login) { return true }
        return false
    }

    static func liveClients() -> [BackendRemoteRelayClient] { live.all() }
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
        firstDialWait?.cancel(); firstDialWait = nil
        generation = UUID(); let epoch = generation
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.path = BackendRelayPacketCodec.hostPath; components.query = nil; components.fragment = nil
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.setValue(BackendRemoteTrustStorage.base64URL(identity.hostSecret), forHTTPHeaderField: BackendRelayPacketCodec.secretHeader)
        // Reach by account: the room is tied to the account only with a token that still has a minute left.
        dialedWithToken = nil
        if let held = tokenToDial() {
            request.setValue("Bearer " + held, forHTTPHeaderField: "authorization"); dialedWithToken = held
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = .infinity
        let delegate = BackendRemoteRelayDelegate(opened: { [weak self] in Task { await self?.opened(epoch) } },
            failed: { [weak self] why in Task { await self?.failed(epoch, why: why) } })
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
            } catch { await self?.failed(epoch, why: Self.dropReason(error)) }
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
        // 15 Nov: [1] only while "Let AI apps use this Mac" is on (BackendRelayMCPServing), so the relay itself answers
        // 404 while it is off; re-said on every connection and on every change (mcpServingChanged).
        // connect-fix (17 Nov): re-tie on the next good connection. A link that opened untied while a usable account
        // token is held (it arrived during the dial, or the dial that carried it failed) dials again tied at once,
        // instead of waiting for the next token change (`reachTokenChanged`).
        if dialedWithToken == nil, tokenToDial() != nil {
            Self.note("reach: tying this Mac's relay room to the account.")
            await drop("Tying this Mac's relay room to the account.")
            return
        }
        mcpTeller = BackendRelayServingTeller()
        await mcpServingChanged()
        if host != nil { await BackendRCVRelayLink.shared.opened { [weak self] type, channel, payload in
            try await self?.receiverEnvelope(type, channel: channel, payload: payload, epoch: epoch)
        } } // RCV
        heartbeat = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    while !Task.isCancelled { try? await Task.sleep(for: .seconds(Self.heartbeatSeconds)); guard !Task.isCancelled else { return }; await self?.ping(epoch) }
                }
                group.addTask { [weak self] in
                    while !Task.isCancelled { try? await Task.sleep(for: .seconds(Self.textPingSeconds)); guard !Task.isCancelled else { return }; await self?.sendTextPing(epoch) }
                }
            }
        }
    }
    /// The account token a dial carries now: held, not refused by the relay, with a minute left (nil: dial untied).
    private func tokenToDial() -> String? {
        guard beaconOffer == nil, host != nil, let held = BackendReachRelayLink.shared.token, held.token != refusedToken,
              held.expiresAtMs - Date().timeIntervalSince1970 * 1000 > 60_000 else { return nil }
        return held.token
    }
    private func connectExpired(_ epoch: UUID) async { if epoch == generation && !connected { await drop("The relay did not finish connecting.") } }
    private func failed(_ epoch: UUID, why: String) async { if epoch == generation && !stopped { await drop(why) } }
    private func sendTextPing(_ epoch: UUID) async {
        guard epoch == generation, let socket, connected else { return }
        do { try await socket.send(.string(Self.textPing)) } catch { await failed(epoch, why: Self.dropReason(error)) }
    }
    private func ping(_ epoch: UUID) async {
        guard epoch == generation, let socket, connected else { return }
        // One deadline per outstanding ping: a beat whose pong is late does not move the deadline (three missed beats end it).
        if pongDeadline == nil {
            pongDeadline = Task { [weak self] in try? await Task.sleep(for: .seconds(Self.pongSeconds)); guard !Task.isCancelled else { return }; await self?.failed(epoch, why: Self.missedKeepalives) }
        }
        do { try await socket.backendSendPing(); pongDeadline?.cancel(); pongDeadline = nil } catch { await failed(epoch, why: Self.dropReason(error)) }
    }
    private func packet(_ data: Data, epoch: UUID) async {
        guard epoch == generation, let packet = BackendRelayPacketCodec.decodeBoundedHostPacket(data) else { return }
        if !connected { await opened(epoch); guard epoch == generation else { return } }
        switch packet.type {
        case 1:
            guard channels[packet.channel] == nil else { return }
            // The AI-apps-only link (no host, no pairing beacon) opens no device channel at all.
            guard host != nil || beaconOffer != nil else { try? await envelope(.close, channel: packet.channel, payload: Data()); return }
            guard channels.count < 16 else { try? await envelope(.close, channel: packet.channel, payload: Data()); return }
            // R2 decision 1: an unmarked open is today's paired join, exactly as before; a marked one is an account
            // channel and goes only to the reach door; a mark that cannot be read is closed.
            var channel = Channel()
            switch BackendReachWire.openKind(packet.payload) {
            case .paired: break
            case .account(let deviceId): channel.account = deviceId
            case .invalid: try? await envelope(.close, channel: packet.channel, payload: Data()); return
            }
            channels[packet.channel] = channel; announce()
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
        if channel.transport == nil, let account = channel.account {
            await openAccountChannel(id, deviceId: account, payload: payload, epoch: epoch)
            return
        }
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
                    var wire = BackendRemoteHostWire(address: "relay:" + response.devicePublicKey.map { String(format: "%02x", $0) }.joined(),
                        peerPublicKey: response.devicePublicKey, send: { [weak self] text in try await self?.channelSend(id, text: text) },
                        close: { [weak self] _, _ in await self?.closeChannel(id) })
                    wire.channelBinding = response.transport.channelBinding
                    wire.earlyBinding = response.earlyBinding
                    let endpoint = await host.accept(wire)
                    channels[id]?.endpoint = endpoint
                    if endpoint == nil { await closeChannel(id); return }
                    // 13 Nov (phone speed): a resume hello sealed into the first message is this connection's first
                    // frame, answered right behind the handshake's reply (one relay round trip instead of two).
                    if let early = response.early, let endpoint {
                        guard early.count <= 65536, let text = String(data: early, encoding: .utf8) else { await closeChannel(id); return }
                        await host.receive(endpoint, text: text)
                    }
                }
            } catch { await closeChannel(id) }
            return
        }
        do {
            let clear = try await channel.transport!.receive(payload)
            guard clear.count <= 65536, let text = String(data: clear, encoding: .utf8) else { await closeChannel(id); return }
            // 29 Oct: a read is answered alongside the reads before it, so the next frame is opened at once. 3 Nov
            // (m5-direct-only): any other frame too, unless the connection already has many unanswered — the host's
            // pipeline keeps their order (BackendRemoteHost.take, `backlogged`).
            if let endpoint = channel.endpoint, let host, let taken = await host.take(endpoint, text: text), !taken.alongside,
               await host.backlogged(endpoint) { await taken.answered.value }
        } catch { await closeChannel(id) }
    }
    /// An account channel's first frame: the reach door answers only for a key of this account's roster that the
    /// gate admits, for the device the relay's mark names; then the host gets a wire carrying that admission.
    private func openAccountChannel(_ id: Data, deviceId: String, payload: Data, epoch: UUID) async {
        guard let door = BackendReachRelayLink.shared.door, let host, beaconOffer == nil else { await closeChannel(id); return }
        do {
            let opened = try await door.answer(identity: identity.keys, frame: payload, marked: deviceId)
            guard epoch == generation, channels[id] != nil else { return }
            channels[id]?.transport = opened.transport; channels[id]?.peer = opened.admission.reachKey
            try await envelope(.data, channel: id, payload: opened.reply)
            var wire = BackendRemoteHostWire(address: "reach:" + deviceId, peerPublicKey: opened.admission.reachKey,
                send: { [weak self] text in try await self?.channelSend(id, text: text) },
                close: { [weak self] _, _ in await self?.closeChannel(id) })
            wire.channelBinding = opened.transport.channelBinding
            wire.reach = opened.admission
            let endpoint = await host.accept(wire)
            channels[id]?.endpoint = endpoint
            if endpoint == nil { await closeChannel(id) }
        } catch {
            if case BackendReachFailure.refused(let why) = error { Self.note("reach: a device of the account was refused (\(why.rawValue)).") }
            await closeChannel(id)
        }
    }

    /// Reach by account: the shared token changed. A link that is not tied (and should be), or tied while it
    /// should not be, is dialed again; a tied link only keeps the fresh token for its next dial.
    func reachTokenChanged() async {
        guard !stopped, beaconOffer == nil, host != nil else { return }
        // A start still waiting for the token dials now that it is here.
        if firstDialWait != nil { if BackendReachRelayLink.shared.token != nil { dial() }; return }
        let wanted = BackendReachRelayLink.shared.token != nil
        if wanted == (dialedWithToken != nil) { return }
        refusedToken = nil
        Self.note(wanted ? "reach: tying this Mac's relay room to the account." : "reach: untying this Mac's relay room from the account.")
        await drop(wanted ? "Tying this Mac's relay room to the account." : "Untying this Mac's relay room from the account.")
    }
    /// Whether the current link was dialed tied to the account (the page's state).
    public func accountTied() -> Bool { connected && dialedWithToken != nil }
    /// Ends every account channel now (paired ones stay).
    public func closeAccountChannels(_ deviceIds: Set<String>?) async {
        for (id, channel) in channels {
            guard let account = channel.account else { continue }
            if let deviceIds, !deviceIds.contains(account) { continue }
            await closeChannel(id)
        }
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
    /// Tells the relay whether this Mac serves MCP now, when that differs from what this connection last said.
    /// review-fixes 6: told through this connection's one teller (BackendRelayServingTeller): a call while one is under
    /// way makes it read again, and after each send the switch is read again, so overlapping changes never leave a
    /// stale "serving" with the relay.
    public func mcpServingChanged() async {
        guard mcp != nil, connected else { return }
        let epoch = generation, teller = mcpTeller
        await teller.tell(read: { await BackendRelayMCPServing.shared.serving() },
                          live: { [weak self] in await self?.isLive(epoch) ?? false },
                          send: { [weak self] on in
                              guard let self else { throw CancellationError() }
                              try await self.sayServing(on, epoch: epoch)
                          })
    }
    private func isLive(_ epoch: UUID) -> Bool { epoch == generation && connected }
    private func sayServing(_ on: Bool, epoch: UUID) async throws {
        guard epoch == generation, connected else { throw CancellationError() }
        try await envelope(.mcpReach, channel: BackendRelayPacketCodec.noRequest, payload: on ? Self.reachServing : Self.reachNotServing)
    }
    private func mcpReply(_ id: Data, response: BackendRemoteRelayMCPReply, epoch: UUID) async {
        guard epoch == generation, mcpPending[id] != nil else { return }
        var at = 0
        repeat {
            let end = min(at + 61440, response.body.count)
            let first = at == 0, last = end == response.body.count
            let flags: UInt8 = (first ? 1 : 0) | (last ? 2 : 0)
            let head = first ? BackendRelayPacketCodec.MCPReplyHead(status: response.status, contentType: response.contentType, refused: response.refused) : nil
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
        var why = why
        let status = (socket?.response as? HTTPURLResponse)?.statusCode
        if let socket { why = Self.withCloseCode(why, code: socket.closeCode.rawValue, reason: socket.closeReason) }
        // A link dialed with a reach token that the relay refused (its 403): the next dial goes untied, so pairing
        // keeps working whatever the relay thinks of the token. Presence ties the room again with a fresh one.
        // connect-fix (17 Nov): only the relay's refusal counts; a dial that failed on the network keeps the token.
        if let token = dialedWithToken, !connected, Self.relayRefusedToken(httpStatus: status) {
            refusedToken = token; dialedWithToken = nil
            Self.note("reach: the relay did not take this Mac's account token (HTTP \(status ?? 0)); connecting untied.")
        }
        generation = UUID(); connected = false
        connectDeadline?.cancel(); connectDeadline = nil; pongDeadline?.cancel(); pongDeadline = nil; heartbeat?.cancel(); heartbeat = nil; receiver?.cancel(); receiver = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
        // A reset (retrying): a connection whose direct link is up carries on (`closed`, §11.4). Stopped on purpose
        // (remote access off, the app quitting): every connection ends, links included.
        for channel in channels.values {
            channel.chain?.cancel()
            guard let endpoint = channel.endpoint else { continue }
            if !stopped && retrying { await host?.closed(endpoint) } else { _ = await host?.dropConnection(endpoint) }
        }
        channels = [:]
        for task in mcpPending.values { task.cancel() }; mcpPending = [:]
        if host != nil { await BackendRCVRelayLink.shared.closed() } // RCV
        reason = why
        // One line per new reason, so a relay that keeps failing the same way does not fill the log.
        if lastLogged != why { lastLogged = why; Self.note("relay: not connected: \(why)\(!stopped && retrying ? " Trying again." : "")") }
        if !stopped && retrying {
            attempts += 1
            let delay = Self.redialDelay(attempt: attempts)
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
    let failed: @Sendable (String) -> Void
    init(opened: @escaping @Sendable () -> Void, failed: @escaping @Sendable (String) -> Void) { self.opened = opened; self.failed = failed }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) { opened() }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        failed(BackendRemoteRelayClient.closeReason(code: closeCode.rawValue, reason: reason))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { if let error { failed(BackendRemoteRelayClient.dropReason(error)) } }
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

/// Reach by account: this process's one place for the reach door and the relay token. Presence ties and unties
/// every live relay client through it; clients started later read it when they dial.
public final class BackendReachRelayLink: BackendReachRelayDoor, @unchecked Sendable {
    public static let shared = BackendReachRelayLink()
    private let lock = NSLock()
    private var _door: BackendReachAccountDoor?
    private var _token: BackendReachRelayToken?
    public var door: BackendReachAccountDoor? { lock.withLock { _door } }
    public var token: BackendReachRelayToken? { lock.withLock { _token } }
    public func setDoor(_ door: BackendReachAccountDoor?) { lock.withLock { _door = door } }
    public func attachAccount(_ token: BackendReachRelayToken) async throws {
        lock.withLock { _token = token }
        for client in BackendRemoteRelayClient.liveClients() { await client.reachTokenChanged() }
    }
    public func detachAccount() async {
        guard lock.withLock({ () -> Bool in let had = _token != nil; _token = nil; return had }) else { return }
        for client in BackendRemoteRelayClient.liveClients() { await client.reachTokenChanged() }
    }
    /// Ends account channels now (nil = all); paired channels stay.
    public func closeAccountChannels(_ deviceIds: Set<String>?) async {
        for client in BackendRemoteRelayClient.liveClients() { await client.closeAccountChannels(deviceIds) }
    }
    public func tied() async -> Bool {
        for client in BackendRemoteRelayClient.liveClients() where await client.accountTied() { return true }
        return false
    }
}
