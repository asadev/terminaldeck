import CoreGraphics
import Foundation
import Testing
import TerminalDeckNativeCore
import TerminalDeckPeer
@testable import TerminalDeckBackend

/// stream step 2 (dc2): the whole protocol over ONE WebRTC link per connection (LiveKitWebRTC 150.7871.04, real data
/// channels), against the real `BackendRemoteHost`. The relay is simulated at today's measured Dubai relay (263 ms
/// keystroke echo → 132 ms each way, 20 Mbit/s) and carries only the hello and the signalling (3 Nov, contract §11
/// "link only"); the client is a contract-exact link-only client (the rules the iPhone, Android and web clients
/// implement; `only: false` is a 0.20.3–0.20.x phone). Paths:
///   host     — the ICE ladder as shipped (same machine here, so the same-network rung wins)
///   internet — no host candidates: server-reflexive only (needs router hairpin on one machine; reported, not required)
///   turn     — Cloudflare Realtime TURN only (needs `TD_PEER_TEST_TURN`, a JSON file of minted ICE servers)
/// Measurement: `swift test --filter LinkPipelineTests` (prints `MEASURE link-<path> <key>=<value>`).
@Suite("The link: the whole protocol over one WebRTC connection", .serialized)
struct LinkPipelineTests {
    typealias V = VideoPipelineTests
    static let binding = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    /// Today's relay, each way (item 70: 263 ms keystroke echo from Dubai).
    static let relayOneWay = 132.0

    /// One direction of the relay: in order, after `oneWay` ms, at `capacity` bits a second.
    actor Pipe {
        let oneWay: Double, capacity: Double
        var free = 0.0
        var tail: Task<Void, Never>?
        var deliver: (@Sendable (String) async -> Void)?
        var open = true
        init(oneWay: Double, capacity: Double = 20_000_000) { self.oneWay = oneWay; self.capacity = capacity }
        func set(_ deliver: @escaping @Sendable (String) async -> Void) { self.deliver = deliver }
        func carry(_ text: String) {
            guard open else { return }
            let now = V.now(), done = max(now, free) + Double(text.utf8.count) * 8_000 / capacity
            free = done
            let due = done + oneWay, previous = tail, deliver = self.deliver
            tail = Task {
                await previous?.value
                let wait = due - V.now()
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000)) }
                await deliver?(text)
            }
        }
        func shut() { open = false }
        /// Everything carried so far has arrived (a close shuts the pipe first, so nothing more comes after it).
        func drained() async { await tail?.value }
    }

    actor Flag {
        var on = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func set() { on = true; for waiter in waiters { waiter.resume() }; waiters.removeAll() }
        /// Until it is set: no clock, so a busy machine cannot make it race.
        func wait() async { if on { return }; await withCheckedContinuation { waiters.append($0) } }
    }

    /// What the host's settings feature saw, in order (the hand-over test).
    actor Seen { var applied: [Int] = []; func add(_ n: Int) { applied.append(n) } }

    /// A dc2 client exactly as the contract says (stream-step2-contract.md §2–§7, and §11 when `only`).
    actor Client {
        let toHost: Pipe
        let forge: Bool
        /// Link only (§11): nothing app-level on the relay (queued until this side moved), no hold of the host's td.ctl.
        let only: Bool
        var waiting: [String] = []
        /// App messages that came over the relay (link-only: none may).
        var relayApp = 0
        var relayAppTypes: [String] = []
        var refusal: String?
        let phone = V.Phone()
        var link: PeerLink?
        var moved = false, hostMoved = false
        var held: [Data] = []
        var route = "", ended: String?
        var welcomedAt: Double?, movedAt: Double?
        var echoes: [String: Double] = [:]
        var welcomeCapabilities: [String] = []
        var hostCandidates: [String] = []
        var offers = 0
        /// A message sent on the relay just before the marker (the N3 case: a slow request right at the hand-over).
        var beforeMarker: String?
        func setBeforeMarker(_ text: String) { beforeMarker = text }
        var echoWaiters: [String: CheckedContinuation<Double, Never>] = [:]
        var ordered: [Int] = []
        var viaLink = 0, viaRelay = 0
        var lastSeq = -1, keyAsks = 0, videoLink = 0, videoRelay = 0, stale = 0, gaps = 0, dropped = 0
        let feed: AsyncStream<(Data, PeerLane)>.Continuation
        let stream: AsyncStream<(Data, PeerLane)>
        var reader: Task<Void, Never>?
        init(toHost: Pipe, forge: Bool, only: Bool) {
            self.toHost = toHost; self.forge = forge; self.only = only
            (stream, feed) = AsyncStream<(Data, PeerLane)>.makeStream()
        }

        static func parse(_ data: Data) -> NativeRPCValue? { try? NativeRPCValue.parseJSON(data) }
        static func text(_ fields: [NativeRPCValue.Field]) -> String { String(decoding: (try? NativeRPCValue.object(fields).encodedJSON()) ?? Data(), as: UTF8.self) }

        /// Every message out: link-only, the relay carries only the hello and the signalling; the rest waits for the
        /// move and then goes on `td.ctl`. Old (`only` false): the relay until this side moved (and `ping` always).
        func send(_ text: String) async {
            if moved, only || !text.hasPrefix(#"{"t":"ping""#) {
                if let link, link.send(Data(text.utf8), lane: .control) { return }
                ended = ended ?? "a send on the link was refused"
                return
            }
            if only, !["hello", "enroll", "link.peer", "link.moved"].contains(where: { text.hasPrefix(#"{"t":""# + $0 + #"""#) }) {
                waiting.append(text); return
            }
            await toHost.carry(text)
        }

        func fromRelay(_ text: String) async {
            guard let value = Self.parse(Data(text.utf8)) else { return }
            viaRelay += 1
            switch value["t"].string {
            case "link.peer": await signal(value)
            case "link.moved":
                hostMoved = true
                let waiting = held; held = []
                for data in waiting { await linked(data) }
            default:
                if !["welcome", "device.access", "error"].contains(value["t"].string ?? "") { relayApp += 1; relayAppTypes.append(value["t"].string ?? "?") }
                if value["t"].string == "error" { refusal = value["message"].string }
                await handle(value, link: false)
            }
        }

        var lanes: [Int32: Int] = [:]
        func fromLink(_ data: Data, _ lane: PeerLane) async {
            lanes[lane.rawValue, default: 0] += 1
            if lane == .control, !hostMoved, !only { held.append(data); return }
            await linked(data)
        }

        private func linked(_ data: Data) async {
            guard let value = Self.parse(data) else { return }
            viaLink += 1
            await handle(value, link: true)
        }

        private func handle(_ value: NativeRPCValue, link: Bool) async {
            switch value["t"].string {
            case "welcome":
                welcomedAt = V.now()
                welcomeCapabilities = value["capabilities"].elements?.compactMap(\.string) ?? []
            case "settings.state":
                guard let rid = value["rid"].string else { return }
                let at = V.now()
                echoes[rid] = at
                echoWaiters.removeValue(forKey: rid)?.resume(returning: at)
            case "settings.applied":
                if let rid = value["rid"].string, let n = Int(rid.dropFirst()) { ordered.append(n) }
            case "detached":
                detachedAt = V.now()
                for waiter in detachWaiters { waiter.resume(returning: V.now()) }
                detachWaiters = []
            case "sims.video":
                if link { videoLink += 1 } else { videoRelay += 1 }
                await video(value)
            default: break
            }
        }

        var detachedAt: Double?
        var detachWaiters: [CheckedContinuation<Double, Never>] = []
        func waitDetached() async -> Double {
            if let detachedAt { return detachedAt }
            Task { try? await Task.sleep(for: .seconds(5)); self.detachTimedOut() }
            return await withCheckedContinuation { detachWaiters.append($0) }
        }
        private func detachTimedOut() { for waiter in detachWaiters { waiter.resume(returning: .infinity) }; detachWaiters = [] }

        /// When the answer to `rid` came (at most 15 s: a connection that closed answers nothing; then +infinity).
        func waitEcho(_ rid: String) async -> Double {
            if let at = echoes[rid] { return at }
            Task { try? await Task.sleep(for: .seconds(15)); self.echoTimedOut(rid) }
            return await withCheckedContinuation { echoWaiters[rid] = $0 }
        }
        private func echoTimedOut(_ rid: String) { echoWaiters.removeValue(forKey: rid)?.resume(returning: .infinity) }

        private func signal(_ value: NativeRPCValue) async {
            switch value["op"].string {
            case "offer":
                offers += 1
                guard let sdp = value["sdp"].string, let fp = value["fp"].string, let bind = value["bind"].string,
                      PeerLink.fingerprint(in: sdp) == fp,
                      PeerBinding.check(bind, binding: LinkPipelineTests.binding, role: "host", fingerprint: fp) else {
                    await send(Self.text([.init("t", .string("link.peer")), .init("op", .string("end"))])); return
                }
                let servers = (value["ice"].elements ?? []).map {
                    PeerICEServer(urls: $0["urls"].elements?.compactMap(\.string) ?? [], username: $0["username"].string, credential: $0["credential"].string)
                }
                let feed = self.feed
                let events = PeerLink.Events(
                    candidate: { [weak self] sdp, mid, index in
                        var fields: [NativeRPCValue.Field] = [.init("t", .string("link.peer")), .init("op", .string("cand")), .init("c", .string(sdp)),
                                                              .init("idx", .number(Double(index)))]
                        if let mid { fields.append(.init("mid", .string(mid))) }
                        let text = Client.text(fields)
                        Task { await self?.send(text) }
                    },
                    open: { [weak self] route in Task { await self?.opened(route) } },
                    closed: { [weak self] why in Task { await self?.closed(why) } },
                    message: { data, lane in feed.yield((data, lane)) })
                guard let made = try? PeerLink(role: .answerer, servers: servers, policy: PeerPolicy(rawValue: value["policy"].string ?? "all") ?? .all,
                                               events: events) else { return }
                link = made
                if reader == nil {
                    let stream = self.stream
                    reader = Task { [weak self] in for await (data, lane) in stream { await self?.fromLink(data, lane) } }
                }
                guard let answer = try? await made.answer(offer: sdp), let mine = PeerLink.fingerprint(in: answer) else { return }
                let key = forge ? Data(repeating: 1, count: 32) : LinkPipelineTests.binding
                await send(Self.text([.init("t", .string("link.peer")), .init("op", .string("answer")), .init("sdp", .string(answer)),
                                      .init("fp", .string(mine)), .init("bind", .string(PeerBinding.make(binding: key, role: "client", fingerprint: mine)))]))
            case "cand":
                if let c = value["c"].string { hostCandidates.append(c) }
                if let c = value["c"].string { link?.add(candidate: c, mid: value["mid"].string, index: Int32(value["idx"].number ?? 0)) }
            case "end":
                link?.close(); link = nil
            default: break
            }
        }

        /// Every channel open: the marker as the last relay message, then everything on the link.
        private func opened(_ route: String) async {
            guard !moved else { return }
            self.route = route
            if let beforeMarker { await toHost.carry(beforeMarker) }
            await toHost.carry(BackendRemoteLinkPath.movedText)
            moved = true
            movedAt = V.now()
            let queued = waiting; waiting = []
            for text in queued where link?.send(Data(text.utf8), lane: .control) != true { ended = ended ?? "a queued send was refused" }
        }

        private func closed(_ why: String) { ended = ended ?? why }

        /// Joins, gap-checks, decodes and acks (contract §6), with the viewers' rules as the iPhone, Android and web apply
        /// them: a late frame is stale; after a gap deltas are dropped until a keyframe, which is asked at once (at most 4
        /// a second; once a second while still waiting). M5: only a frame handed to the decoder moves "the last one
        /// handed on" (`lastSeq`); a dropped delta never does, so a keyframe that comes late on td.rel is never stale.
        private var awaitingKey = true, askedAt = -Double.infinity
        private func video(_ value: NativeRPCValue) async {
            let seq = Int(value["seq"].number ?? -1), parts = Int(value["parts"].number ?? 1), part = Int(value["part"].number ?? 0)
            let id = value["id"].string ?? "", key = value["key"].bool == true
            guard part == parts - 1 || parts == 1 else { _ = await phone.arrived(value, changedAt: value["ct"].number ?? 0); return }
            if seq <= lastSeq { stale += 1; await phone.discard(seq); await ack(id, seq); return }
            if key { awaitingKey = false } else {
                if !awaitingKey, seq != lastSeq + 1 { awaitingKey = true; gaps += 1; await askKey(id, force: true) }
                if awaitingKey { dropped += 1; await phone.discard(seq); await ack(id, seq); await askKey(id, force: false); return }
            }
            lastSeq = seq
            guard await phone.arrived(value, changedAt: value["ct"].number ?? 0) != nil else { return }
            await ack(id, seq)
        }

        private func askKey(_ id: String, force: Bool) async {
            let now = V.now()
            guard force || now - askedAt > 1_000, now - askedAt > 250 else { return }
            askedAt = now
            keyAsks += 1
            await send(#"{"t":"sims.key","id":"\#(id)"}"#)
        }

        private func ack(_ id: String, _ seq: Int) async { await send(#"{"t":"sims.ack","id":"\#(id)","seq":\#(seq)}"#) }

        func killLink() { link?.close() }
        /// Security S1: a client must never write on the video channels.
        func writeOnVideoLane() -> Bool { link?.send(Data(#"{"t":"ping"}"#.utf8), lane: .moving) ?? false }
        func close() { link?.close(); link = nil; reader?.cancel(); feed.finish() }
    }

    final class Engine: BackendLinkEngine, @unchecked Sendable {
        let servers: [BackendPhonePeerServer]
        let policy: String
        private let lock = NSLock()
        private var asked: [String] = [], released: [String] = [], warmed: [String] = [], all = 0
        private var releaseWaiters: [(count: Int, waiter: CheckedContinuation<Void, Never>)] = []
        init(servers: [BackendPhonePeerServer], policy: String) { self.servers = servers; self.policy = policy }
        func servers(device: String) async -> (servers: [BackendPhonePeerServer], policy: String) {
            lock.withLock { asked.append(device) }
            return (servers, policy)
        }
        func connect(servers: [BackendPhonePeerServer], policy: String, events: BackendLinkEvents) throws -> any BackendLinkConnection {
            try TerminalDeckPeerEngine(environment: [:]).connect(servers: servers, policy: policy, events: events)
        }
        func release(device: String, force: Bool) async {
            let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                released.append(device)
                let ready = releaseWaiters.filter { $0.count <= released.count }.map(\.waiter)
                releaseWaiters.removeAll { $0.count <= released.count }
                return ready
            }
            for waiter in ready { waiter.resume() }
        }
        /// Until at least `count` withdrawals were asked: no clock.
        func released(atLeast count: Int) async {
            await withCheckedContinuation { waiter in
                let now = lock.withLock { () -> Bool in
                    if released.count >= count { return true }
                    releaseWaiters.append((count, waiter)); return false
                }
                if now { waiter.resume() }
            }
        }
        func releaseAll() async { lock.withLock { all += 1 } }
        func prewarm(device: String) async { lock.withLock { warmed.append(device) } }
        var warmedFor: [String] { lock.withLock { warmed } }
        var releasedAll: Int { lock.withLock { all } }
        var askedFor: [String] { lock.withLock { asked } }
        var releasedFor: [String] { lock.withLock { released } }
    }

    static func turnServers() -> [BackendPhonePeerServer]? {
        guard let path = ProcessInfo.processInfo.environment["TD_PEER_TEST_TURN"], let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return TerminalDeckPeerEngine.parse(text)
    }
    static var stun: [BackendPhonePeerServer] { [BackendPhonePeerServer(urls: PeerICEServer.cloudflareSTUN.urls)] }

    final class Harness: @unchecked Sendable {
        let host: BackendRemoteHost, id: UUID, client: Client, wireClosed: Flag, seen: Seen
        var engine: Engine?, device = "", trust: BackendRemoteTrustStore?
        /// Until every frame the host sent so far reached the client.
        var drained: @Sendable () async -> Void = {}
        let screen: V.PixelScreen?, installation: BackendPhoneDevices.Installation?
        let cleanup: @Sendable () async -> Void
        init(host: BackendRemoteHost, id: UUID, client: Client, wireClosed: Flag, seen: Seen, screen: V.PixelScreen?,
             installation: BackendPhoneDevices.Installation?, cleanup: @escaping @Sendable () async -> Void) {
            self.host = host; self.id = id; self.client = client; self.wireClosed = wireClosed; self.seen = seen
            self.screen = screen; self.installation = installation; self.cleanup = cleanup
        }
        /// Up to `ms` for this connection to move onto its link; its route, or nil.
        func waitMoved(_ ms: Double = 12_000) async throws -> String? {
            let deadline = V.now() + ms
            while V.now() < deadline {
                if let route = await host.linkRoute(id), await client.movedAt != nil { return route }
                if await wireClosed.on { return nil }
                try await Task.sleep(for: .milliseconds(10))
            }
            return nil
        }
        /// `count` keystroke-style round trips (client → host → client, one at a time): the times in ms.
        func echoes(_ count: Int, label: String) async throws -> [Double] {
            var times: [Double] = []
            for n in 0..<count {
                let rid = "\(label)-\(n)", start = V.now()
                await client.send(#"{"t":"settings.read","rid":"\#(rid)"}"#)
                times.append(await client.waitEcho(rid) - start)
                try await Task.sleep(for: .milliseconds(20))
            }
            return times
        }
    }

    /// A host with a sealed-looking connection (a channel binding) and a dc2 client on the simulated relay.
    func start(link: (servers: [BackendPhonePeerServer], policy: String)?, oneWay: Double = LinkPipelineTests.relayOneWay,
               forge: Bool = false, video: Bool = false, access: BackendINT2PhoneAccessLevel? = .full,
               slowApply: Int = 0, only: Bool = true, welcome: Bool = true, key: Bool = false, grace: Int? = nil) async throws -> Harness {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LINK-" + UUID().uuidString)
        let trust = BackendRemoteTrustStore(directory: dir.appendingPathComponent("remote"))
        try await trust.open()
        // `key`: the device's key is named by the sealed handshake (its TURN login is made ready before the hello).
        let publicKey = key ? Data((0..<32).map { _ in UInt8.random(in: 0...255) }) : nil
        let device = try await trust.redeem(try await trust.createPairingOffer().token, name: "Phone", address: "fixture", publicKey: publicKey)
        try await trust.approve(device.device.id, kind: .mine)
        try await trust.setPhoneAccess(device.device.id, level: access)
        let clock = INT2PhoneHostClock()
        let host = BackendRemoteHost(trust: trust, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }), state: NativeStateStore(),
            home: dir.path, hostName: "Fixture", appVersion: "test", privateRoots: [], sleep: { try await clock.sleep($0) }, clock: { V.now() })
        let seen = Seen()
        try await host.register(.init(capability: "settings", messageTypes: ["settings.read", "settings.apply"], policy: .grantedDevice) { message, _ in
            let rid = message["rid"].string ?? ""
            if message.type == "settings.read" { return [try BackendRemoteServerMessage(.settingsState, fields: [.init("rid", .string(rid)), .init("settings", .array([]))])] }
            if rid == "slow", slowApply > 0 { try? await Task.sleep(for: .milliseconds(slowApply)) }
            await seen.add(Int(rid.dropFirst()) ?? -1)
            return [try BackendRemoteServerMessage(.settingsApplied, fields: [.init("rid", .string(rid)), .init("ok", .bool(true)), .init("message", .string("")),
                                                                               .init("setting", .object([]))])]
        })
        var screen: V.PixelScreen?, installation: BackendPhoneDevices.Installation?
        if video {
            let pixels = V.PixelScreen(video: true)
            screen = pixels
            let row = NativeRPCValue.object([.init("id", .string("mac:1")), .init("name", .string("Studio Mac")), .init("platform", .string("mac")),
                .init("kind", .string("display")), .init("state", .string("ready")), .init("canWatch", .bool(true)), .init("canControl", .bool(true))])
            var source = BackendPhoneDevices.Source(
                list: { .object([.init("devices", .array([]))]) }, power: { _, _ in .object([]) }, stream: { _, _ in pixels }, input: { _, _ in },
                shot: { _ in throw NativeRPCError(code: "unavailable", message: "no") }, deliver: { _ in "" }, visibleSessions: { _ in [] },
                send: { [host] id, message in try await host.sendToConnection(id, message: message) }, macRows: { [row] })
            source.direct = { [host] id, data, lane in await host.sendDirect(id, data: data, lane: lane) }
            source.linkVideo = { [host] id in await host.linkVideo(id) }
            installation = try await BackendPhoneDevices.install(on: host, source: source)
        }
        let engine = (link ?? (key ? (Self.stun, "all") : nil)).map { Engine(servers: $0.servers, policy: $0.policy) }
        if let engine { await host.setLinkEngine(engine) }
        if let grace { await host.setLoginGrace(grace) }
        try await host.start()
        let toClient = Pipe(oneWay: oneWay), toHost = Pipe(oneWay: oneWay)
        let client = Client(toHost: toHost, forge: forge, only: only)
        let wireClosed = Flag()
        let timer = clock.scheduled.value() + 1
        var wire = BackendRemoteHostWire(address: "fixture", peerPublicKey: publicKey, send: { text in await toClient.carry(text) },
                                         close: { _, _ in await wireClosed.set(); await toClient.shut(); await toHost.shut() })
        wire.channelBinding = Self.binding
        let id = try #require(await host.accept(wire))
        await clock.scheduled.wait(timer)
        await toClient.set { text in await client.fromRelay(text) }
        await toHost.set { [host] text in if let taken = await host.take(id, text: text), !taken.alongside { await taken.answered.value } }
        let capabilities: [NativeRPCValue] = [.string("device.access")]
            + (link != nil ? [.string(BackendRemoteHost.linkCapability)] + (only ? [.string(BackendRemoteHost.linkOnlyCapability)] : []) : [])
        let hello = NativeRPCValue.object([.init("t", .string("hello")), .init("protocol", .number(1)), .init("token", .string(device.credential)),
            .init("device", .object([.init("name", .string("Phone")), .init("platform", .string("ios"))])), .init("capabilities", .array(capabilities))])
        await client.send(String(decoding: try hello.encodedJSON(), as: UTF8.self))
        // Up to 20 s: the credential check (scrypt) is slow when the machine is busy (seen 2 Nov under a full test run).
        for _ in 0..<2_000 {
            let welcomed = await client.welcomedAt != nil, closed = await wireClosed.on
            if welcomed || closed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        if welcome { #expect(await client.welcomedAt != nil, "welcomed") }
        let installed = installation
        let made = Harness(host: host, id: id, client: client, wireClosed: wireClosed, seen: seen, screen: screen, installation: installation, cleanup: {
            await client.close(); await installed?.stop(); await host.stop(); await trust.close(); try? FileManager.default.removeItem(at: dir)
        })
        made.engine = engine; made.device = device.device.id; made.trust = trust
        made.drained = { await toClient.drained() }
        return made
    }

    static func report(_ label: String, _ out: [String: Double]) {
        for key in out.keys.sorted() { print("MEASURE \(label) \(key)=\(String(format: "%.1f", out[key]!))") }
    }

    // MARK: M2 — keystrokes and every message

    /// One path's keystroke echo: 50 round trips, median and p90, and how long the hand-over took.
    func echoRun(_ label: String, link: (servers: [BackendPhonePeerServer], policy: String)?) async throws -> [String: Double] {
        let run = try await start(link: link)
        var out: [String: Double] = [:]
        var route: String?
        if link != nil {
            route = try await run.waitMoved()
            let welcomed = await run.client.welcomedAt ?? .nan
            out["connectMs"] = (await run.client.movedAt).map { $0 - welcomed } ?? .nan
        }
        out["onLink"] = route == nil ? 0 : 1
        print("MEASURE \(label) route=\(route ?? "none (no link: the connection closes)")")
        // Link only (§11.3): no link means nothing is answered at all.
        let times = route == nil ? [] : try await run.echoes(50, label: label)
        out["echoMs.median"] = V.median(times); out["echoMs.p90"] = V.p90(times); out["echoMs.max"] = times.max() ?? .nan
        out["viaLink"] = Double(await run.client.viaLink); out["viaRelay"] = Double(await run.client.viaRelay)
        out["relayApp"] = Double(await run.client.relayApp)
        print("MEASURE \(label) relayAppTypes=\(await run.client.relayAppTypes)")
        Self.report(label, out)
        await run.cleanup()
        return out
    }

    @Test func keystrokeEchoOnEveryRung() async throws {
        let direct = try await echoRun("link-host", link: (Self.stun, "all"))
        #expect(direct["onLink"]! == 1, "the ladder as shipped moves onto the link: \(direct)")
        // The relay's own round trip would be 2 × 132 ms; the link answers in a fraction of it.
        #expect(direct["echoMs.median"]! < 60, "link: \(direct)")
        #expect(direct["relayApp"]! == 0, "nothing but the hello and signalling crossed the relay: \(direct)")
        // Internet peer-to-peer through this Mac's own router needs hairpinning: reported, not required.
        _ = try await echoRun("link-internet", link: (Self.stun, "nohost"))
        if let servers = Self.turnServers() {
            let turn = try await echoRun("link-turn", link: (servers, "relay"))
            #expect(turn["onLink"]! == 1 && turn["echoMs.median"]! < Self.relayOneWay, "TURN (Dubai): \(turn)")
        }
    }

    /// The hand-over keeps order both ways: 300 ordered writes sent every 3 ms from the hello on reach the host in order
    /// and their answers come back in order, none lost. Link only: they wait for the link and all go on it (none on the
    /// relay); an older phone (`only` false): some over the relay before its link opened, its answers all on the link.
    @Test(arguments: [true, false]) func theHandOverKeepsOrderBothWays(only: Bool) async throws {
        let run = try await start(link: (Self.stun, "all"), only: only)
        let sender = Task {
            for n in 0..<300 {
                await run.client.send(#"{"t":"settings.apply","rid":"o\#(n)","key":"general.restoreSessions","value":"on"}"#)
                try? await Task.sleep(for: .milliseconds(3))
            }
        }
        await sender.value
        let deadline = V.now() + 15_000
        while V.now() < deadline, await run.client.ordered.count < 300 { try await Task.sleep(for: .milliseconds(20)) }
        let route = await run.host.linkRoute(run.id)
        #expect(route != nil, "moved onto the link during the run")
        #expect(await run.seen.applied == Array(0..<300), "the host took them in order")
        #expect(await run.client.ordered == Array(0..<300), "the answers came back in order")
        let viaLink = await run.client.viaLink, relayApp = await run.client.relayApp
        #expect(viaLink >= 300 && relayApp == 0, "every answer on the link, none on the relay (\(viaLink) / \(relayApp))")
        print("MEASURE link-handover only=\(only) viaLink=\(viaLink) relayApp=\(relayApp) route=\(route ?? "none")")
        await run.cleanup()
    }

    /// Security: an answer not bound to this pairing never carries anything; link only (§11.3), nothing else can either:
    /// the connection closes (the phone says "Can't reach your Mac") instead of falling back to the relay.
    @Test func anAnswerNotBoundToThePairingClosesTheConnection() async throws {
        let run = try await start(link: (Self.stun, "all"), oneWay: 30, forge: true)
        let deadline = V.now() + 5_000
        while V.now() < deadline, !(await run.wireClosed.on) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await run.host.linkRoute(run.id) == nil)
        let viaLink = await run.client.viaLink, closed = await run.wireClosed.on, relayApp = await run.client.relayApp
        #expect(viaLink == 0 && closed && relayApp == 0, "closed, nothing carried anywhere")
        await run.cleanup()
    }

    /// §11.5: a phone on the relay that cannot take a link is told so at its hello (no relay data path).
    /// Deterministic (Release saw it race once beside a release build): it waits for the close itself, then for the
    /// frames already on their way (the refusal goes before the close), never for a clock.
    @Test(.timeLimit(.minutes(1))) func aPhoneWithoutTheLinkIsRefusedAtItsHello() async throws {
        let run = try await start(link: nil, oneWay: 10, welcome: false)
        await run.wireClosed.wait()
        await run.drained()
        let connections = await run.host.linkConnectionIDs()
        #expect(connections.isEmpty)
        #expect(await run.client.refusal == BackendRemoteHost.cannotLink("ios"))
        #expect(await run.client.welcomedAt == nil)
        await run.cleanup()
    }

    /// Reviewer 27 #2: the TURN login made ready at the sealed handshake is withdrawn when the connection closes without
    /// ever starting a link (here a phone refused at its hello; an older computer that never asks for a link is the same).
    @Test(.timeLimit(.minutes(1))) func aLoginMadeReadyForARefusedPhoneIsWithdrawn() async throws {
        let run = try await start(link: nil, oneWay: 10, welcome: false, key: true, grace: 200)
        await run.wireClosed.wait()
        await run.drained()
        #expect(await run.client.refusal == BackendRemoteHost.cannotLink("ios"))
        await run.engine?.released(atLeast: 1)
        #expect(run.engine?.warmedFor == [run.device], "made ready at the handshake")
        #expect(run.engine?.releasedFor == [run.device], "withdrawn after the grace, though no link ever started")
        await run.cleanup()
    }

    /// §11.4: the relay channel closing (Cloudflare resets idle-looking sockets every 1–3 min) leaves a link-only
    /// connection up: it answers on the link, nothing reconnects, the login is not withdrawn.
    @Test func theRelayClosingLeavesALinkOnlyConnectionUp() async throws {
        let run = try await start(link: (Self.stun, "all"), oneWay: 30)
        #expect(try await run.waitMoved() != nil)
        await run.host.closed(run.id)
        let times = try await run.echoes(10, label: "relay-gone")
        let closed = await run.wireClosed.on
        #expect(!closed && V.median(times) < 30, "answered on the link after the relay went: \(times)")
        #expect(await run.host.linkRoute(run.id) != nil && run.engine?.releasedFor.isEmpty == true)
        await run.cleanup()
    }

    /// m5-direct-only: opening a session and typing never wait behind a slow answer (the terminal lane); the frames after
    /// a slow one are read at once (the reader waits only when many are unanswered).
    @Test func theTerminalLaneNeverWaitsBehindASlowAnswer() async throws {
        let run = try await start(link: (Self.stun, "all"), oneWay: 5, slowApply: 1_500)
        #expect(try await run.waitMoved() != nil)
        let start = V.now()
        await run.client.send(#"{"t":"settings.apply","rid":"slow","key":"general.restoreSessions","value":"on"}"#)
        await run.client.send(#"{"t":"detach","id":"0b5c1e2a-1111-4222-8333-444455556666"}"#)
        let detachedAt = await run.client.waitDetached() - start
        print("MEASURE link-terminal-lane detachedMs=\(detachedAt.isFinite ? Int(detachedAt) : -1)")
        #expect(detachedAt < 500, "the terminal lane did not wait 1.5 s behind the slow frame: \(detachedAt) ms")
        await run.cleanup()
    }

    /// A link that dies after the move closes the sealed connection (the client reconnects and is sent things afresh).
    @Test func aDeadLinkClosesTheConnection() async throws {
        let run = try await start(link: (Self.stun, "all"), oneWay: 30)
        #expect(try await run.waitMoved() != nil)
        await run.client.killLink()
        let deadline = V.now() + 10_000
        while V.now() < deadline, !(await run.wireClosed.on) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await run.wireClosed.on, "the host closed the connection after its link died")
        await run.cleanup()
    }

    @Test func bindingVectorsAndParts() {
        let key = Data((1...32).map { UInt8($0) }), fp = "sha-256 AA:BB"
        #expect(BackendLinkBinding.make(binding: key, role: "host", fingerprint: fp) == "scKcVc9ozTpB99xM6cQvWCtHQ7CxovvMN0YjRlukFdk=")
        #expect(BackendLinkBinding.make(binding: key, role: "client", fingerprint: fp) == "L1LUTQY2W5fwKdSXV5AvGovxRTLYtyUQSNUX7Pfj5f8=")
        #expect(PeerBinding.make(binding: key, role: "host", fingerprint: fp) == "scKcVc9ozTpB99xM6cQvWCtHQ7CxovvMN0YjRlukFdk=")
        #expect(PeerBinding.check("L1LUTQY2W5fwKdSXV5AvGovxRTLYtyUQSNUX7Pfj5f8=", binding: key, role: "client", fingerprint: fp))
        #expect(!PeerBinding.check("L1LUTQY2W5fwKdSXV5AvGovxRTLYtyUQSNUX7Pfj5f8=", binding: key, role: "host", fingerprint: fp))
        #expect(!BackendLinkBinding.check("scKcVc9ozTpB99xM6cQvWCtHQ7CxovvMN0YjRlukFdk=", binding: Data(repeating: 0, count: 32), role: "host", fingerprint: fp))
        let sdp = "v=0\r\na=group:BUNDLE 0\r\na=fingerprint:sha-256 11:22\r\n"
        #expect(BackendLinkBinding.fingerprint(in: sdp) == "sha-256 11:22" && PeerLink.fingerprint(in: sdp) == "sha-256 11:22")
        // Parts: a short text is itself; a long one splits into 0x01 … 0x02 parts that join back byte for byte.
        let short = Data(#"{"t":"ping"}"#.utf8)
        #expect(PeerLink.parts(short) == [short])
        let long = Data(("{\"t\":\"x\",\"d\":\"" + String(repeating: "a", count: 450_000) + "\"}").utf8)
        let parts = PeerLink.parts(long)
        #expect(parts.count == 3 && parts.dropLast().allSatisfy { $0.first == 0x01 } && parts.last?.first == 0x02)
        #expect(parts.allSatisfy { $0.count <= PeerLink.mostMessageBytes })
        var pending: Data?
        var joined: Data?
        for part in parts { if case .whole(let data) = PeerLink.join(part, into: &pending) { joined = data } }
        #expect(joined == long && pending == nil)
        // A whole message in the middle of parts breaks the rules.
        var broken: Data? = nil
        _ = PeerLink.join(parts[0], into: &broken)
        #expect(PeerLink.join(short, into: &broken) == .failure)
    }

    /// M5: a TURN leg over TCP/TLS on either side marks the path; over it the moving frames go the reliable way.
    @Test func aPathOverTCPSendsVideoTheReliableWay() async throws {
        let udp = "candidate:1 1 udp 41885439 104.30.1.2 50000 typ relay raddr 0.0.0.0 rport 0 generation 0"
        let tcp = "candidate:2 1 udp 25108223 104.30.1.2 50001 typ relay raddr 0.0.0.0 rport 0 generation 0"
        let tls = "a=candidate:3 1 udp 8331007 104.30.1.2 50002 typ relay raddr 0.0.0.0 rport 0 generation 0"
        let host = "candidate:4 1 udp 2122260223 192.168.1.4 50003 typ host generation 0"
        #expect(!PeerLink.relayOverTCP(udp) && PeerLink.relayOverTCP(tcp) && PeerLink.relayOverTCP(tls) && !PeerLink.relayOverTCP(host))
        final class Fake: BackendLinkConnection, @unchecked Sendable {
            let tcp: Bool; var lanes: [BackendLinkLane] = []
            init(tcp: Bool) { self.tcp = tcp }
            func offer() async throws -> String { "" }
            func accept(answer: String) async throws {}
            func add(candidate: String, mid: String?, index: Int32) {}
            func send(_ data: Data, lane: BackendLinkLane) -> Bool { lanes.append(lane); return true }
            func close() {}
            var overTCP: Bool { tcp }
            func queued(_ lane: BackendLinkLane) -> UInt64 { lane == .still ? 7 : 3 }
        }
        for over in [false, true] {
            let fake = Fake(tcp: over)
            let path = BackendRemoteLinkPath(relay: { _ in })
            path.attach(fake, failure: nil)
            #expect(path.direct(Data(), lane: .moving) == nil && path.video() == nil, "nothing on the link before the move")
            try await path.write(BackendRemoteLinkPath.movedText)
            _ = path.direct(Data(), lane: .moving); _ = path.direct(Data(), lane: .still)
            #expect(fake.lanes == (over ? [.still, .still] : [.moving, .still]))
            #expect(path.video() == BackendLinkVideo(reliableOnly: over, queuedMoving: 3, queuedStill: 7))
        }
    }

    @Test func linkFramesParse() {
        let answer = #"{"t":"link.peer","op":"answer","sdp":"v=0","fp":"sha-256 AA","bind":"eA=="}"#
        guard case .message(let message) = BackendRemoteProtocol.parseClientMessage(answer) else { Issue.record("refused"); return }
        #expect(message.type == "link.peer" && message["op"].string == "answer" && message["fp"].string == "sha-256 AA")
        guard case .message(let moved) = BackendRemoteProtocol.parseClientMessage(BackendRemoteLinkPath.movedText) else { Issue.record("refused"); return }
        #expect(moved.type == "link.moved")
        if case .message = BackendRemoteProtocol.parseClientMessage(#"{"t":"link.peer","op":"offer"}"#) { Issue.record("a client never offers") }
        guard case .message(let key) = BackendRemoteProtocol.parseClientMessage(#"{"t":"sims.key","id":"mac:1"}"#) else { Issue.record("refused"); return }
        #expect(key["id"].string == "mac:1")
    }

    // MARK: Security fixes (security-step2.md)

    /// M1: no TCP candidates and no TCP listener while a link is up; M2: the login is asked for this device, and
    /// withdrawn when its last connection closes.
    @Test func noTCPListenerAndOneLoginPerDevice() async throws {
        let run = try await start(link: (Self.stun, "all"), oneWay: 30)
        #expect(try await run.waitMoved() != nil)
        let candidates = await run.client.hostCandidates
        #expect(!candidates.isEmpty && candidates.allSatisfy { !$0.lowercased().contains(" tcp ") }, "\(candidates)")
        let lsof = Process(), pipe = Foundation.Pipe()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-p", String(ProcessInfo.processInfo.processIdentifier)]
        lsof.standardOutput = pipe; lsof.standardError = FileHandle.nullDevice
        try lsof.run(); lsof.waitUntilExit()
        let listening = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").dropFirst().filter { !$0.contains("127.0.0.1") }
        print("MEASURE link-security tcpListeners=\(listening.count) hostCandidates=\(candidates.count)")
        #expect(listening.isEmpty, "no TCP listener while the link is up: \(listening)")
        #expect(run.engine?.askedFor == [run.device])
        // §11.6: withdrawn when the device's last connection closed and it did not come back within the grace.
        await run.host.setLoginGrace(200)
        _ = await run.host.dropConnection(run.id)
        let deadline = V.now() + 3_000
        while V.now() < deadline, run.engine?.releasedFor.isEmpty == true { try await Task.sleep(for: .milliseconds(20)) }
        #expect(run.engine?.releasedFor == [run.device], "the login is withdrawn when the device's last connection closes")
        await run.cleanup()
    }

    /// M2 revised (§11.6): a Hoot-only device gets a link too (the link is its only way now); a device whose access is off
    /// gets none (and no TURN login) but hears `link.only`, so it knows this Mac is new; switching a linked device's
    /// access off ends its link and withdraws its login.
    @Test func anyAccessButNoneGetsALink() async throws {
        let hoot = try await start(link: (Self.stun, "all"), oneWay: 30, access: .hoot)
        #expect(try await hoot.waitMoved() != nil, "Hoot-only moves onto its link")
        await hoot.cleanup()
        let none = try await start(link: (Self.stun, "all"), oneWay: 30, access: nil)
        try await Task.sleep(for: .milliseconds(800))
        let offered = await none.client.welcomeCapabilities
        #expect(!offered.contains(BackendRemoteHost.linkCapability) && offered.contains(BackendRemoteHost.linkOnlyCapability), "\(offered)")
        #expect(await none.client.offers == 0 && none.engine?.askedFor.isEmpty == true)
        await none.cleanup()
        let run = try await start(link: (Self.stun, "all"), oneWay: 30)
        #expect(try await run.waitMoved() != nil)
        try await run.trust?.setPhoneAccess(run.device, level: nil)
        await run.host.refreshGrants()
        let deadline = V.now() + 5_000
        while V.now() < deadline, !(await run.wireClosed.on) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await run.wireClosed.on, "the moved link ended with the access, so the connection closed")
        let released = V.now() + 3_000
        while V.now() < released, run.engine?.releasedFor.contains(run.device) != true { try await Task.sleep(for: .milliseconds(20)) }
        #expect(run.engine?.releasedFor.contains(run.device) == true, "access off: the login is withdrawn at once")
        await run.cleanup()
    }

    /// S1: a client writing on a video channel ends the link (after the move: the connection closes).
    @Test func aClientWritingOnAVideoChannelEndsTheLink() async throws {
        let run = try await start(link: (Self.stun, "all"), oneWay: 30)
        #expect(try await run.waitMoved() != nil)
        #expect(await run.client.writeOnVideoLane())
        let deadline = V.now() + 5_000
        while V.now() < deadline, !(await run.wireClosed.on) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await run.wireClosed.on)
        await run.cleanup()
    }

    /// N3: a slow request (7 s) still being answered at the hand-over does not end the link: the hold waits for it.
    @Test func aSlowRequestAtTheHandOverDoesNotEndTheLink() async throws {
        let run = try await start(link: (Self.stun, "all"), slowApply: 7_000, only: false)
        await run.client.setBeforeMarker(#"{"t":"settings.apply","rid":"slow","key":"general.restoreSessions","value":"on"}"#)
        #expect(try await run.waitMoved(15_000) != nil)
        let start = V.now()
        await run.client.send(#"{"t":"settings.read","rid":"after-slow"}"#)
        let answered = await run.client.waitEcho("after-slow") - start
        let closed = await run.wireClosed.on
        print("MEASURE link-slow-handover answeredMs=\(answered.isFinite ? Int(answered) : -1) closed=\(closed)")
        #expect(!closed && answered > 5_000, "held behind the slow request, then answered on the link")
        await run.cleanup()
    }

    /// M2 across a restart (Security re-check (a)): the devices that may hold a login come from the trust store. At start
    /// a paired device without screen/session access is withdrawn; later, every device that drops off (access off,
    /// unpaired) is withdrawn unconditionally.
    @Test func loginsFollowTheTrustStoreAcrossARestart() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LINK-TRUST-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let trust = BackendRemoteTrustStore(directory: dir.appendingPathComponent("remote"))
        try await trust.open()
        func paired(_ name: String, _ level: BackendINT2PhoneAccessLevel) async throws -> String {
            let made = try await trust.redeem(try await trust.createPairingOffer().token, name: name, address: name, publicKey: nil)
            _ = try await trust.approve(made.device.id, kind: .mine); try await trust.setPhoneAccess(made.device.id, level: level)
            return made.device.id
        }
        let full = try await paired("Full", .full), work = try await paired("Work", .work)
        let off = try await paired("Off", .look)
        try await trust.setPhoneAccess(off, level: nil)
        let host = BackendRemoteHost(trust: trust, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }), state: NativeStateStore(),
            home: dir.path, hostName: "Fixture", appVersion: "test", privateRoots: [])
        let engine = Engine(servers: Self.stun, policy: "all")
        await host.setLinkEngine(engine)
        try await host.start()
        func waitFor(_ count: Int) async throws { let end = V.now() + 3_000; while V.now() < end, engine.releasedFor.count < count { try await Task.sleep(for: .milliseconds(20)) } }
        try await waitFor(1)
        #expect(engine.releasedFor == [off], "at start: the paired device without access")
        try await trust.setPhoneAccess(work, level: nil)
        await host.refreshGrants()
        try await waitFor(2)
        #expect(engine.releasedFor.last == work, "access switched off")
        _ = try await trust.revoke(full)
        await host.refreshGrants()
        try await waitFor(3)
        #expect(engine.releasedFor.last == full, "unpaired")
        // Security S1: stopping the host (device access off for the whole app) withdraws every login at once.
        #expect(engine.releasedAll == 0)
        await host.stop(); await trust.close()
        #expect(engine.releasedAll == 1, "withdrawn at the stop, not 2 minutes later")
    }

    @Test func candidatesAndFingerprintsAreBounded() async throws {
        for bad in ["candidate:1 1 udp 2122260223 127.0.0.1 50000 typ host", "candidate:1 1 udp 2122260223 0.0.0.0 1 typ host",
                    "candidate:1 1 udp 2122260223 224.0.0.251 5353 typ host", "candidate:1 1 udp 2122260223 ::1 50000 typ host",
                    "candidate:1 1 udp 2122260223 ff02::1 50000 typ host", "candidate:garbage",
                    "candidate:1 1 udp 2122260223 ::ffff:127.0.0.1 50000 typ host", "candidate:1 1 udp 2122260223 255.255.255.255 9 typ host",
                    "candidate:1 1 udp 2122260223 127.000.000.001x 9 typ host", "candidate:1 1 udp 2122260223 evil/host.local 9 typ host"] {
            #expect(!BackendLinkCandidate.usable(bad) && !PeerLink.usableRemote(bad), "\(bad)")
        }
        for good in ["candidate:1 1 udp 2122260223 192.168.1.20 50000 typ host", "candidate:2 1 udp 1686052607 94.200.1.2 61000 typ srflx raddr 0.0.0.0 rport 0",
                     "candidate:3 1 udp 2122260223 4f1c2a3b-1111-2222-3333-444455556666.local 50000 typ host", "candidate:4 1 udp 41885439 2606:4700::1 3478 typ relay"] {
            #expect(BackendLinkCandidate.usable(good) && PeerLink.usableRemote(good), "\(good)")
        }
        let two = "v=0\r\na=fingerprint:sha-256 AA:BB\r\na=fingerprint:sha-256 CC:DD\r\n"
        #expect(BackendLinkBinding.fingerprint(in: two) == nil && PeerLink.fingerprint(in: two) == nil)
        let same = "v=0\r\na=fingerprint:sha-256 AA:BB\r\na=fingerprint:sha-256 aa:bb\r\n"
        #expect(BackendLinkBinding.fingerprint(in: same) == "sha-256 AA:BB")
        // The engine: one login per device, reused only for that device, withdrawn on release.
        actor Calls { var asked: [String] = []; var revoked: [String] = []; func ask(_ d: String) { asked.append(d) }; func revoke(_ d: String) { revoked.append(d) } }
        let calls = Calls()
        let engine = TerminalDeckPeerEngine(environment: [:], turn: { device in
            await calls.ask(device)
            return .init(servers: [BackendPhonePeerServer(urls: ["turn:turn.cloudflare.com:3478"], username: "u-" + device, credential: "c")],
                         expiresAtMs: Date().timeIntervalSince1970 * 1_000 + 3_600_000, login: "0123456789abcdef0123456789abcdef")
        }, revoke: { device, login in await calls.revoke(device + "/" + (login ?? "any")); return true })
        let a = await engine.servers(device: "phone-a"), b = await engine.servers(device: "phone-b"), again = await engine.servers(device: "phone-a")
        #expect(a.servers.compactMap(\.username) == ["u-phone-a"] && b.servers.compactMap(\.username) == ["u-phone-b"] && again.servers == a.servers)
        #expect(await calls.asked == ["phone-a", "phone-b"], "reused for the same device only")
        await engine.release(device: "phone-a", force: false)
        #expect(await calls.revoked == ["phone-a/0123456789abcdef0123456789abcdef"] && engine.holders == ["phone-b"], "the last-close withdrawal names its login")
        await engine.release(device: "phone-z", force: true)
        #expect(await calls.revoked.last == "phone-z/any", "unpair / access off: unconditional, even with nothing held")
        // R1: a withdrawal still retrying stops once the device gets a new login.
        let failing = Calls()
        let retrying = TerminalDeckPeerEngine(environment: [:], turn: { device in
            .init(servers: [BackendPhonePeerServer(urls: ["turn:t"], username: "u", credential: "c")], expiresAtMs: Date().timeIntervalSince1970 * 1_000 + 3_600_000,
                  login: "0123456789abcdef0123456789abcdef")
        }, revoke: { device, _ in await failing.revoke(device); return false }, retryWaits: [0.3, 0.3, 0.3])
        _ = await retrying.servers(device: "phone-c")
        let pending = Task { await retrying.release(device: "phone-c", force: false) }
        try await Task.sleep(for: .milliseconds(100))
        _ = await retrying.servers(device: "phone-c")
        await pending.value
        #expect(await failing.revoked == ["phone-c"], "one try, then the retries stopped: the device has a new login")
        // Security S1: the host stopping withdraws every held login at once, each by name; nothing is left held.
        _ = await engine.servers(device: "phone-d")
        await engine.releaseAll()
        let named = "/0123456789abcdef0123456789abcdef"
        #expect(Set(await calls.revoked.suffix(2)) == ["phone-b" + named, "phone-d" + named] && engine.holders.isEmpty)
        // A late grace-timer withdrawal then finds nothing held and asks nothing.
        let count = await calls.revoked.count
        await engine.release(device: "phone-b", force: false)
        #expect(await calls.revoked.count == count)
    }

    // MARK: M3 — the screen's video on the same link

    func videoRun(_ label: String, link: (servers: [BackendPhonePeerServer], policy: String)?, seconds moveFor: Double = 4,
                  timeline: Bool = false) async throws -> [String: Double] {
        var run = try await start(link: link, video: true)
        var out: [String: Double] = [:]
        if link != nil {
            out["onLink"] = try await run.waitMoved() == nil ? 0 : 1
            if out["onLink"] == 0, timeline {
                // A lossy path can lose the whole ICE exchange once (seen 2 Nov at 2 %): one more connection, as a phone
                // would make it.
                print("MEASURE \(label) retry=1")
                await run.cleanup()
                run = try await start(link: link, video: true)
                out["onLink"] = try await run.waitMoved() == nil ? 0 : 1
            }
        }
        guard let screen = run.screen else { throw NativeRPCError(code: "unavailable", message: "no screen") }
        await screen.set(PhoneScreenFixtures.screen(offset: 0))
        await run.client.send(#"{"t":"sims.watch","rid":"w1","id":"mac:1","maxWidth":2560,"quality":60,"fps":60,"video":["h264"]}"#)
        // Measuring only: every 500 ms what waits on each channel, what the phone got and showed, and the pace (the
        // motion starts at t=1.5).
        let t0 = V.now()
        let probe: Task<Void, Never>? = timeline ? Task { [run] in
            while !Task.isCancelled {
                let video = await run.host.linkVideo(run.id), counts = await run.installation?.devices.linkCounts()
                let lanes = await run.client.lanes, shown = await run.client.phone.shown.count, asks = await run.client.keyAsks
                print(String(format: "TIMELINE \(label) t=%.1f q.rt=%llu q.rel=%llu got.rt=%ld got.rel=%ld shown=%ld kbps=%.0f lost=%ld asks=%ld",
                             (V.now() - t0) / 1_000, video?.queuedMoving ?? 0, video?.queuedStill ?? 0, lanes[1] ?? 0, lanes[2] ?? 0, shown,
                             (counts?.bitrate ?? 0) / 1_000, counts?.lost ?? 0, asks))
                try? await Task.sleep(for: .milliseconds(500))
            }
        } : nil
        defer { probe?.cancel() }
        try await Task.sleep(for: .milliseconds(1_500))
        let moveStart = V.now()
        var offset = 0, changes = 0
        while V.now() - moveStart < moveFor * 1_000 {
            offset += 24; changes += 1
            await screen.set(PhoneScreenFixtures.screen(offset: offset))
            let wait = moveStart + Double(changes) * 33.3 - V.now()
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000)) }
        }
        let moveEnd = V.now()
        try await Task.sleep(for: .milliseconds(3_000))
        let all = await run.client.phone.shown
        let moving = all.filter { $0.changedAt >= moveStart && $0.changedAt < moveEnd && !$0.still }
        let seconds = (moveEnd - moveStart) / 1_000
        out["moving.fps"] = Double(moving.count) / seconds
        out["moving.glassMs.median"] = V.median(moving.map { $0.readyAt - $0.changedAt })
        out["moving.glassMs.p90"] = V.p90(moving.map { $0.readyAt - $0.changedAt })
        out["moving.kbPerSecond"] = Double(moving.reduce(0) { $0 + $1.bytes }) / 1_000 / seconds
        out["sharpAgainMs"] = (all.last { $0.still && $0.readyAt > moveEnd }?.readyAt).map { $0 - moveEnd } ?? .nan
        out["decodeFailures"] = Double(await run.client.phone.decodeFailures)
        out["videoOnLink"] = Double(await run.client.videoLink)
        out["videoOnRelay"] = Double(await run.client.videoRelay)
        out["keyAsks"] = Double(await run.client.keyAsks)
        out["gaps"] = Double(await run.client.gaps); out["stale"] = Double(await run.client.stale)
        out["droppedAwaitingKey"] = Double(await run.client.dropped)
        out["moving.shown"] = Double(moving.count)
        // The longest the picture stood still while the screen moved (the stall measure): between shown moving frames,
        // and from the start of the motion to the first one / the last one to the end.
        let times = [moveStart] + moving.map(\.readyAt).sorted() + [moveEnd]
        out["moving.freezeMs.max"] = zip(times.dropFirst(), times).map { $0 - $1 }.max() ?? .nan
        if let counts = await run.installation?.devices.linkCounts() {
            out["host.linkSent"] = Double(counts.sent); out["host.linkDropped"] = Double(counts.dropped)
            out["host.bitrateKbps"] = counts.bitrate / 1_000
            out["host.watches"] = Double(counts.watches); out["host.unacked"] = Double(counts.unacked)
            out["host.lostOnRt"] = Double(counts.lost)
        }
        out["linkAlive"] = await run.host.linkRoute(run.id) == nil ? 0 : 1
        out["wireClosed"] = await run.wireClosed.on ? 1 : 0
        out["client.rt"] = Double(await run.client.lanes[1] ?? 0); out["client.rel"] = Double(await run.client.lanes[2] ?? 0)
        out["client.ctl"] = Double(await run.client.lanes[3] ?? 0)
        if let ended = await run.client.ended { print("MEASURE \(label) ENDED \(ended)") }
        Self.report(label, out)
        await run.client.send(#"{"t":"sims.unwatch","id":"mac:1"}"#)
        await run.cleanup()
        return out
    }

    /// M5: the hard rungs, measured only when `TD_PEER_TEST_PATHS` names them (`label=<ICE servers JSON>,…`, minted
    /// Cloudflare TURN logins): TURN over TLS/TCP only (UDP blocked) and TURN through a lossy UDP hop (scratch proxy).
    /// Each: keystroke echo, then 8 s of the scrolling page.
    @Test func theScreenOnTheHardRungs() async throws {
        guard let paths = ProcessInfo.processInfo.environment["TD_PEER_TEST_PATHS"] else { return }
        BackendRemoteRelayClient.setLog { print("NOTE \($0)") }
        defer { BackendRemoteRelayClient.setLog(nil) }
        for entry in paths.split(separator: ",") {
            let pair = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, let data = FileManager.default.contents(atPath: pair[1]),
                  let servers = TerminalDeckPeerEngine.parse(String(decoding: data, as: UTF8.self)) else { continue }
            _ = try await echoRun("link-\(pair[0])", link: (servers, "relay"))
            let video = try await videoRun("link-video-\(pair[0])", link: (servers, "relay"), seconds: 8, timeline: true)
            #expect(video["onLink"]! == 1, "\(pair[0]): \(video)")
        }
    }

    @Test func theScreenOnTheSameLink() async throws {
        let direct = try await videoRun("link-video-host", link: (Self.stun, "all"))
        #expect(direct["decodeFailures"]! == 0)
        #expect(direct["onLink"]! == 1 && direct["videoOnLink"]! > 0 && direct["videoOnRelay"]! == 0, "only on the link: \(direct)")
        #expect(direct["moving.glassMs.median"]! < 100, "\(direct)")
        #expect(direct["moving.fps"]! >= 25, "\(direct)")
        if let servers = Self.turnServers() {
            let turn = try await videoRun("link-video-turn", link: (servers, "relay"))
            #expect(turn["onLink"]! == 1 && turn["decodeFailures"]! == 0, "\(turn)")
        }
    }
}
