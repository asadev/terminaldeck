import Foundation
import TerminalDeckBackend

/// Whether WebRTC is in this process. The session-host executable links it weakly: run from its copy in the data
/// folder (no framework beside it) dyld leaves it out, and no WebRTC class may be touched there.
public enum TerminalDeckPeerLibrary {
    public static var isLoaded: Bool { NSClassFromString("LKRTCPeerConnectionFactory") != nil }
}

/// The app's WebRTC layer for the host's link (stream step 2, dc2): the Mac offers, the phone or browser answers.
///
/// ICE servers: the device's OWN Cloudflare Realtime TURN login from our Worker (`POST /v1/turn {"device"}`, ≤ 1 h; one
/// per device, never shared — Security M2) plus Cloudflare's STUN; without one (the Worker has none, refuses, is not
/// deployed) Cloudflare's STUN alone (same network and internet peer-to-peer still work; only the TURN rung is missing).
/// A cached login is reused for that device's own reconnects while it has more than 10 minutes left (asking again for
/// the same device withdraws the old one at the Worker). `release` forgets it and withdraws it (`/v1/turn/revoke`).
/// Debug builds only (Security S3): `TD_PEER_WORKER_TURN=0` / the `TDPeerWorkerTURN` default (Worker off),
/// `TD_PEER_ICE_SERVERS` (JSON list) and `TD_PEER_POLICY` (`all` / `nohost` / `relay`) for measurements.
public final class TerminalDeckPeerEngine: BackendLinkEngine, @unchecked Sendable {
    public typealias TURN = @Sendable (_ device: String) async -> BackendRemoteRelayClient.TURNLogin?
    public typealias Revoke = @Sendable (_ device: String, _ login: String?) async -> Bool
    private let turn: TURN
    private let revoke: Revoke
    private let environment: [String: String]
    private let lock = NSLock()
    private var cached: [String: BackendRemoteRelayClient.TURNLogin] = [:]
    /// A login being asked for now, per device.
    private var asking: [String: Task<BackendRemoteRelayClient.TURNLogin?, Never>] = [:]
    /// Bumped by every withdrawal: a login asked for before it is not kept.
    private var released: [String: Int] = [:]
    /// Bumped each time a device gets a new login: a withdrawal still retrying for an older one stops (Security R1).
    private var issued: [String: Int] = [:]
    private let retryWaits: [Double]
    /// A cached login is reused only while it has more than this left (the contract's "about 10 minutes").
    static let reuseMarginMs = 10.0 * 60 * 1_000
    /// Withdrawals the Worker could not do at once are tried again after these waits (contract: 502/503 = retry).
    public static let revokeRetries: [Double] = [5, 30, 120]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                turn: @escaping TURN = { device in await BackendRemoteRelayClient.liveTURNLogin(device: device, ttl: 3_600) },
                revoke: @escaping Revoke = { device, login in await BackendRemoteRelayClient.liveRevokeTURN(device: device, login: login) },
                retryWaits: [Double] = TerminalDeckPeerEngine.revokeRetries) {
        #if DEBUG
        self.environment = environment
        #else
        self.environment = [:]   // Security S3: nothing outside the app can steer a shipped build's links.
        #endif
        self.turn = turn; self.revoke = revoke; self.retryWaits = retryWaits
    }

    public var workerTURN: Bool {
        #if DEBUG
        if let flag = environment["TD_PEER_WORKER_TURN"] { return flag != "0" }
        return UserDefaults.standard.object(forKey: "TDPeerWorkerTURN") as? Bool ?? true
        #else
        return true
        #endif
    }

    static var stun: BackendPhonePeerServer { BackendPhonePeerServer(urls: PeerICEServer.cloudflareSTUN.urls) }

    public func servers(device: String) async -> (servers: [BackendPhonePeerServer], policy: String) {
        let policy = PeerPolicy(rawValue: environment["TD_PEER_POLICY"] ?? "all")?.rawValue ?? PeerPolicy.all.rawValue
        if let json = environment["TD_PEER_ICE_SERVERS"], let given = Self.parse(json) { return (given, policy) }
        guard workerTURN else { return ([Self.stun], policy) }
        guard let login = await login(device) else { return ([Self.stun], policy) }
        return (Self.withSTUN(login.servers), policy)
    }

    /// m5-direct-only: the login is asked as soon as the device's sealed handshake names it (before its hello), so the
    /// offer after the welcome finds it ready.
    public func prewarm(device: String) async {
        guard environment["TD_PEER_ICE_SERVERS"] == nil, workerTURN else { return }
        _ = await login(device)
    }

    /// The device's login: cached while it has more than `reuseMarginMs` left, else one ask to the Worker — shared by
    /// every caller meanwhile (asking twice would withdraw the first login at the Worker).
    private func login(_ device: String) async -> BackendRemoteRelayClient.TURNLogin? {
        let now = Date().timeIntervalSince1970 * 1_000
        let (hit, running) = lock.withLock { (cached[device], asking[device]) }
        if let hit, hit.expiresAtMs - now > Self.reuseMarginMs { return hit }
        if let running { return await running.value }
        let turn = self.turn
        let task = Task<BackendRemoteRelayClient.TURNLogin?, Never> { await turn(device) }
        let withdrawn = lock.withLock { () -> Int in asking[device] = task; return released[device, default: 0] }
        let login = await task.value
        let current = lock.withLock { () -> Bool in
            asking[device] = nil
            // Withdrawn while it was being asked for (unpaired, access off): it is never kept.
            guard released[device, default: 0] == withdrawn else { return false }
            if let login { cached[device] = login; issued[device, default: 0] += 1 }
            return true
        }
        if !current, login != nil { _ = await revoke(device, login?.login); return nil }
        return login
    }

    /// `force` (unpaired, access off): withdraw whatever the device holds, unconditionally. Otherwise (its last link
    /// closed): withdraw only the login this run handed it, named, so a fresh one after a reconnect survives; the
    /// retries stop as soon as the device is given a new login (Security R1).
    public func release(device: String, force: Bool) async {
        let (held, generation) = lock.withLock { () -> (BackendRemoteRelayClient.TURNLogin?, Int) in
            if force { released[device, default: 0] += 1 }
            return (cached.removeValue(forKey: device), issued[device, default: 0])
        }
        guard held != nil || force, workerTURN else { return }
        let login = force ? nil : held?.login
        if await revoke(device, login) { return }
        for wait in retryWaits {
            try? await Task.sleep(for: .seconds(wait))
            if !force, lock.withLock({ issued[device, default: 0] }) != generation { return }
            if await revoke(device, login) { return }
        }
    }

    /// Security S1 (27): the host is stopping. Every held login is withdrawn at once, each by name, in parallel; a login
    /// still being asked for is never kept (it is withdrawn when its answer comes). One try each, at most
    /// `releaseAllWait` seconds in all, so switching device access off stays quick: the relay goes right after.
    public func releaseAll() async {
        let held = lock.withLock { () -> [(String, String?)] in
            for device in Set(cached.keys).union(asking.keys) { released[device, default: 0] += 1 }
            let all = cached.map { ($0.key, $0.value.login) }
            cached.removeAll()
            return all
        }
        guard workerTURN, !held.isEmpty else { return }
        let revoke = self.revoke, wait = Self.releaseAllWait
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withTaskGroup(of: Void.self) { each in
                    for (device, login) in held { each.addTask { _ = await revoke(device, login) } }
                }
            }
            group.addTask { try? await Task.sleep(for: .seconds(wait)) }
            await group.next()
            group.cancelAll()
        }
    }
    /// The longest `releaseAll` holds up a stop (seconds).
    static let releaseAllWait = 3.0

    /// For tests: the device ids holding a cached login.
    public var holders: Set<String> { lock.withLock { Set(cached.keys) } }

    static func withSTUN(_ servers: [BackendPhonePeerServer]) -> [BackendPhonePeerServer] {
        servers.contains(where: { $0.urls.contains(where: { $0.hasPrefix("stun:") }) }) ? servers : [stun] + servers
    }

    public func connect(servers: [BackendPhonePeerServer], policy: String, events: BackendLinkEvents) throws -> any BackendLinkConnection {
        let link = try PeerLink(role: .offerer, servers: servers.map { PeerICEServer(urls: $0.urls, username: $0.username, credential: $0.credential) },
                                policy: PeerPolicy(rawValue: policy) ?? .all,
                                events: .init(candidate: events.candidate, open: events.open, closed: events.closed,
                                              message: { data, lane in events.message(data, BackendLinkLane(rawValue: lane.rawValue) ?? .control) }))
        return TerminalDeckPeerConnection(link)
    }

    /// `[{"urls":[…],"username":…,"credential":…}]`.
    public static func parse(_ json: String) -> [BackendPhonePeerServer]? {
        guard let rows = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] else { return nil }
        let servers = rows.compactMap { row -> BackendPhonePeerServer? in
            let urls = (row["urls"] as? [String]) ?? (row["urls"] as? String).map { [$0] } ?? []
            return urls.isEmpty ? nil : BackendPhonePeerServer(urls: urls, username: row["username"] as? String, credential: row["credential"] as? String)
        }
        return servers.isEmpty ? nil : servers
    }
}

/// `PeerLink` as the host sees it.
public final class TerminalDeckPeerConnection: BackendLinkConnection, @unchecked Sendable {
    public let link: PeerLink
    public init(_ link: PeerLink) { self.link = link }
    public func offer() async throws -> String { try await link.makeOffer() }
    public func accept(answer: String) async throws { try await link.accept(answer: answer) }
    public func add(candidate: String, mid: String?, index: Int32) { link.add(candidate: candidate, mid: mid, index: index) }
    public func send(_ data: Data, lane: BackendLinkLane) -> Bool { link.send(data, lane: PeerLane(rawValue: lane.rawValue) ?? .control) }
    public var overTCP: Bool { link.overTCP }
    public func queued(_ lane: BackendLinkLane) -> UInt64 { link.queued(PeerLane(rawValue: lane.rawValue) ?? .control) }
    public func close() { link.close() }
}

/// This Mac as a guest of another computer (Devices › Machines): the answering side of the same link (3 Nov,
/// m5-direct-only; the phones' client side, `BackendRemoteGuest`).
public struct TerminalDeckPeerAnswerer: BackendLinkAnswering {
    public init() {}
    public func answer(servers: [BackendPhonePeerServer], policy: String, events: BackendLinkEvents) throws -> any BackendLinkAnswerConnection {
        let link = try PeerLink(role: .answerer, servers: servers.map { PeerICEServer(urls: $0.urls, username: $0.username, credential: $0.credential) },
                                policy: PeerPolicy(rawValue: policy) ?? .all,
                                events: .init(candidate: events.candidate, open: events.open, closed: events.closed,
                                              message: { data, lane in events.message(data, BackendLinkLane(rawValue: lane.rawValue) ?? .control) }))
        return TerminalDeckPeerAnswer(link)
    }
}

/// `PeerLink` as a guest sees it.
public final class TerminalDeckPeerAnswer: BackendLinkAnswerConnection, @unchecked Sendable {
    public let link: PeerLink
    public init(_ link: PeerLink) { self.link = link }
    public func answer(offer: String) async throws -> String { try await link.answer(offer: offer) }
    public func add(candidate: String, mid: String?, index: Int32) { link.add(candidate: candidate, mid: mid, index: index) }
    public func send(_ data: Data, lane: BackendLinkLane) -> Bool { link.send(data, lane: PeerLane(rawValue: lane.rawValue) ?? .control) }
    public var isOpen: Bool { link.isOpen }
    public func close() { link.close() }
}
