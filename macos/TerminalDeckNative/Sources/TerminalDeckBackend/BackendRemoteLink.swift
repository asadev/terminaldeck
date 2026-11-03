import CryptoKit
import Foundation
import TerminalDeckNativeCore

// stream step 2 (dc2, 2 Nov 2026; Asad: "whatever it takes, real experience, better speed AND quality, anywhere, no VPN"
// and "one mechanism"): ONE WebRTC peer connection per sealed connection carries the whole protocol — the terminal's
// output and keystrokes, every other message, input events — on an ordered data channel, and the screen's H.264 on two
// more. Path order is ICE's own (same network → internet peer-to-peer → Cloudflare Realtime TURN in Dubai); the Worker
// relay carries pairing, the hello, signalling and pings, and everything when no link comes up.
// Contract: macos/night/codex/stream-step2-contract.md.
//
// The WebRTC library is linked only into the app (target TerminalDeckPeer supplies `BackendLinkEngine`); this file is the
// protocol side and is tested with the real engine and with fakes. The session host builds a `BackendRemoteHost` without
// an engine, so it never offers a link.
//
// The switch point is the connection's one ordered writer (`BackendRemoteServeWireWriter`): everything written before
// `link.moved` goes over the relay, everything after it over the link, so order is kept exactly; the client does the
// same the other way and the receiver holds link messages until the other side's marker has come over the relay. A link
// that dies after the move closes the sealed connection (the client reconnects at once and is sent the session afresh):
// a message lost in flight can never leave a hole in a terminal.
//
// Security (security-step2.md, 2 Nov): signalling only inside the sealed channel (the relay never sees an address, an
// SDP or a candidate); the DTLS fingerprints are protected by travelling only inside that Noise-encrypted channel (the
// `bind` tag over the channel binding is a consistency check, not a secret: the binding is public — S2); a link only for
// a hello'd device with screen or session access on a sealed connection (never Hoot-only or none — M2); no TCP listener
// (TCP candidates off — M1), only ephemeral UDP ICE sockets while a link is up; one TURN login per device, withdrawn when
// the device goes (M2); clients may write only `td.ctl` (S1); at most 32 usable remote candidates (S4); every message
// passes the same checks as over the relay (`take`), and the link closes with the connection.

/// One ICE server (STUN, or TURN logins from the Worker's `/v1/turn`).
public struct BackendPhonePeerServer: Sendable, Equatable {
    public var urls: [String]
    public var username: String?
    public var credential: String?
    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls; self.username = username; self.credential = credential
    }
    var wire: NativeRPCValue {
        var fields: [NativeRPCValue.Field] = [.init("urls", .array(urls.map { .string($0) }))]
        if let username { fields.append(.init("username", .string(username))) }
        if let credential { fields.append(.init("credential", .string(credential))) }
        return .object(fields)
    }
}

/// The link's channels (contract §4).
public enum BackendLinkLane: Int32, Sendable {
    /// `td.rt`: moving video frames, deltas only (retried at most 150 ms).
    case moving = 1
    /// `td.rel`: keyframes and the still frame's parts (M5); over TCP every video frame.
    case still = 2
    /// `td.ctl`: every other message, both ways.
    case control = 3
}

/// What the app's WebRTC layer reports for one link.
public struct BackendLinkEvents: Sendable {
    public var candidate: @Sendable (_ sdp: String, _ mid: String?, _ index: Int32) -> Void
    /// Every channel is open; `path` is "host", "internet" or "turn".
    public var open: @Sendable (_ path: String) -> Void
    /// The link failed or closed (at most once, never after `close()`).
    public var closed: @Sendable (_ why: String) -> Void
    /// One whole message, in arrival order per channel (called on one thread at a time).
    public var message: @Sendable (_ data: Data, _ lane: BackendLinkLane) -> Void
    public init(candidate: @escaping @Sendable (String, String?, Int32) -> Void, open: @escaping @Sendable (String) -> Void,
                closed: @escaping @Sendable (String) -> Void, message: @escaping @Sendable (Data, BackendLinkLane) -> Void) {
        self.candidate = candidate; self.open = open; self.closed = closed; self.message = message
    }
}

public protocol BackendLinkConnection: AnyObject, Sendable {
    /// The offer SDP (already the local description).
    func offer() async throws -> String
    func accept(answer: String) async throws
    func add(candidate: String, mid: String?, index: Int32)
    /// False when the channel is not open, the moving channel is full, or the library refused it.
    func send(_ data: Data, lane: BackendLinkLane) -> Bool
    func close()
    /// The selected path crosses TCP (a TURN leg over TCP/TLS on either side): video goes the reliable way (M5).
    var overTCP: Bool { get }
    /// Bytes waiting to go on `lane`.
    func queued(_ lane: BackendLinkLane) -> UInt64
}

extension BackendLinkConnection {
    public var overTCP: Bool { false }
    public func queued(_ lane: BackendLinkLane) -> UInt64 { 0 }
}

/// How a connection's link carries video now (M5).
public struct BackendLinkVideo: Sendable, Equatable {
    /// Every video frame goes on `td.rel` (the path crosses TCP, where a lifetime only ever expires in a queue).
    public var reliableOnly: Bool
    /// Bytes waiting on `td.rt` and on `td.rel`.
    public var queuedMoving: UInt64
    public var queuedStill: UInt64
    public init(reliableOnly: Bool, queuedMoving: UInt64 = 0, queuedStill: UInt64 = 0) {
        self.reliableOnly = reliableOnly; self.queuedMoving = queuedMoving; self.queuedStill = queuedStill
    }
}

public protocol BackendLinkEngine: Sendable {
    /// The ICE servers for a new link to `device` (that device's own TURN login when the Worker gave one, else STUN) and
    /// the path policy ("all" in the product; "nohost" / "relay" only to measure one rung, debug builds only).
    func servers(device: String) async -> (servers: [BackendPhonePeerServer], policy: String)
    func connect(servers: [BackendPhonePeerServer], policy: String, events: BackendLinkEvents) throws -> any BackendLinkConnection
    /// The device went: forget and withdraw its login. `force`: withdraw even when this run holds none (unpaired or access
    /// off — a login from before a restart may still be live); otherwise only a login this run holds (last connection closed).
    func release(device: String, force: Bool) async
    /// m5-direct-only: have `device`'s ICE servers ready (ask the Worker now unless a login is cached or on its way).
    func prewarm(device: String) async
    /// Security S1 (27): the host is stopping (device access off for the whole app): withdraw every login this run
    /// holds at once, each by name, while the relay can still carry the withdrawal.
    func releaseAll() async
}

extension BackendLinkEngine {
    public func prewarm(device: String) async {}
    public func releaseAll() async {}
}

/// The pairing binding of a DTLS fingerprint (contract §3): HMAC-SHA256 keyed by the sealed channel's Noise binding over
/// `td.link.v2|<role>|<fingerprint>`; the same as `PeerBinding` in TerminalDeckPeer/PeerLink.swift (the iPhone's copy).
public enum BackendLinkBinding {
    static func data(role: String, fingerprint: String) -> Data { Data("td.link.v2|\(role)|\(fingerprint)".utf8) }
    public static func make(binding: Data, role: String, fingerprint: String) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: data(role: role, fingerprint: fingerprint), using: SymmetricKey(data: binding))).base64EncodedString()
    }
    public static func check(_ bind: String, binding: Data, role: String, fingerprint: String) -> Bool {
        guard let given = Data(base64Encoded: bind), given.count == 32 else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(given, authenticating: data(role: role, fingerprint: fingerprint), using: SymmetricKey(data: binding))
    }
    /// The SHA-256 DTLS fingerprint an SDP announces, or nil (also when it names more than one distinct one — S2).
    public static func fingerprint(in sdp: String) -> String? {
        var found: String?
        for line in sdp.split(whereSeparator: \.isNewline) where line.hasPrefix("a=fingerprint:") {
            let value = line.dropFirst("a=fingerprint:".count).trimmingCharacters(in: .whitespaces)
            guard value.lowercased().hasPrefix("sha-256 ") else { continue }
            if let found, found.lowercased() != value.lowercased() { return nil }
            found = found ?? value
        }
        return found
    }
}

/// One connection's way out (m5-direct-only, contract §11 "link only"). It is the writer's only door, and the writer
/// sends one message at a time in order, so the marker splits the stream exactly.
/// - `.wire`: everything through the connection's own wire (before the hello, the loopback web page, Mac guests).
/// - `.link`: a phone or the web on the relay with a link: only the relay's own frames (§11.1) go on the relay; every
///   other message waits in order until this side has moved, then goes on the link — never on the relay.
/// - `.noLink`: a phone or the web on the relay without a link (its access is off): only the relay's own frames go;
///   everything else is dropped.
final class BackendRemoteLinkPath: @unchecked Sendable {
    enum Mode: Equatable { case wire, link(clientOnly: Bool), noLink }
    /// The marker (contract §5), written through the writer like any message.
    static let movedText = #"{"t":"link.moved"}"#
    /// How every `link.peer` this host writes starts (`BackendRemoteProtocol.serialize` puts `t` first).
    static let signalPrefix = #"{"t":"link.peer""#
    /// What may cross the relay from this host to a link client (§11.1); the welcome goes before the mode is set.
    static let relayTypes: Set<String> = ["welcome", "enrolled", "device.access", "link.peer", "link.moved"]
    /// Messages waiting for the move: at most this many bytes (more means the link has failed).
    static let mostWaitingBytes = 4 * 1024 * 1024
    private let lock = NSLock()
    private let relay: @Sendable (String) async throws -> Void
    private var link: (any BackendLinkConnection)?
    private var moved = false
    private var mode = Mode.wire
    private var waiting: [String] = []
    private var waitingBytes = 0
    private var relayGone = false
    private var failure: (@Sendable (String) -> Void)?
    init(relay: @escaping @Sendable (String) async throws -> Void) { self.relay = relay }

    func attach(_ link: (any BackendLinkConnection)?, failure: (@Sendable (String) -> Void)?) {
        lock.withLock { self.link = link; self.failure = failure }
    }
    func set(_ mode: Mode) { lock.withLock { self.mode = mode } }
    var currentMode: Mode { lock.withLock { mode } }
    var hasMoved: Bool { lock.withLock { moved } }
    /// The relay channel under this connection closed while its link carries on (§11.4).
    func relayClosed() { lock.withLock { relayGone = true } }
    var relayIsGone: Bool { lock.withLock { relayGone } }

    /// The message type at the front of a serialized message (`{"t":"…"`).
    static func type(of text: String) -> Substring? {
        guard text.hasPrefix(#"{"t":""#) else { return nil }
        let rest = text.dropFirst(6)
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return rest[..<end]
    }

    func write(_ text: String) async throws {
        if text == Self.movedText {
            if !relayIsGone { try? await relay(text) }
            // Everything that waited for the move goes first, in order (§11.2).
            let (queued, link, failure) = lock.withLock { () -> ([String], (any BackendLinkConnection)?, (@Sendable (String) -> Void)?) in
                moved = link != nil
                defer { waiting = []; waitingBytes = 0 }
                return (moved ? waiting : [], link, self.failure)
            }
            for message in queued where link?.send(Data(message.utf8), lane: .control) != true {
                failure?("A message could not go on the direct link.")
                throw NativeRPCError(code: "unavailable", message: "The direct link ended.")
            }
            return
        }
        let route = lock.withLock { () -> (mode: Mode, moved: Bool, link: (any BackendLinkConnection)?, failure: (@Sendable (String) -> Void)?, relayGone: Bool) in
            (mode, moved, link, failure, relayGone)
        }
        switch route.mode {
        case .wire:
            // The old dc2 hand-over (tests and any wire that has a link without link-only): the link after the move.
            guard route.moved, !text.hasPrefix(Self.signalPrefix) else { try await relay(text); return }
            try sendOnLink(text, route.link, route.failure)
        case .noLink:
            guard let type = Self.type(of: text), Self.relayTypes.contains(String(type)) || type == "pong" else { return }
            try await relay(text)
        case .link(let clientOnly):
            let type = Self.type(of: text).map(String.init) ?? ""
            if Self.relayTypes.contains(type) {
                // Late candidates after the move also go on the link to a link-only client: the relay may be gone (§11.4).
                if type == "link.peer", route.moved, clientOnly {
                    if !route.relayGone { try? await relay(text) }
                    try sendOnLink(text, route.link, route.failure)
                    return
                }
                guard !route.relayGone else { return }
                try await relay(text)
                return
            }
            if route.moved { try sendOnLink(text, route.link, route.failure); return }
            // Not moved yet: wait for the link, in order (§11.2).
            let full = lock.withLock { () -> Bool in
                if moved { return false }
                waiting.append(text); waitingBytes += text.utf8.count
                return waitingBytes > Self.mostWaitingBytes
            }
            // (The writer sends one message at a time, so the move cannot happen between the check above and here.)
            if full {
                route.failure?("Too much waited for the direct link.")
                throw NativeRPCError(code: "unavailable", message: "The direct link ended.")
            }
        }
    }

    private func sendOnLink(_ text: String, _ link: (any BackendLinkConnection)?, _ failure: (@Sendable (String) -> Void)?) throws {
        guard let link, link.send(Data(text.utf8), lane: .control) else {
            failure?("A message could not go on the direct link.")
            throw NativeRPCError(code: "unavailable", message: "The direct link ended.")
        }
    }

    /// Video (contract §6): nil before the move (no link to carry it), true when it went on `lane`, false when it was
    /// dropped (the moving channel is full; the viewer asks for a keyframe).
    func direct(_ data: Data, lane: BackendLinkLane) -> Bool? {
        guard let link = lock.withLock({ moved ? link : nil }) else { return nil }
        // M5: over TCP every video message goes the reliable way (one channel, one order; nothing is ever given up).
        return link.send(data, lane: lane == .moving && link.overTCP ? .still : lane)
    }

    /// How video goes on the link now (M5): nil before the move.
    func video() -> BackendLinkVideo? {
        guard let link = lock.withLock({ moved ? link : nil }) else { return nil }
        return BackendLinkVideo(reliableOnly: link.overTCP, queuedMoving: link.queued(.moving), queuedStill: link.queued(.still))
    }

    func detach() -> (any BackendLinkConnection)? {
        lock.withLock { defer { link = nil; failure = nil; waiting = []; waitingBytes = 0 }; return link }
    }
}

/// Bytes received on a link and not yet handled (the hold limit, contract §5).
final class BackendRemoteLinkInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    func add(_ count: Int) -> Int { lock.withLock { bytes += count; return bytes } }
    func remove(_ count: Int) { lock.withLock { bytes -= count } }
}

/// One connection's link, as the host keeps it.
struct BackendRemoteLinkState: Sendable {
    let path: BackendRemoteLinkPath
    var token: UUID?
    var connection: (any BackendLinkConnection)?
    var offeredAt: Double = 0
    var open = false
    var route = ""
    /// The client's `link.moved` came over the relay: its link messages may be handled.
    var clientMoved = false
    /// The client said `link.only` (§11): it sends nothing app-level on the relay, so its link messages are never held,
    /// late candidates go on the link, and the link outlives the relay channel.
    var clientOnly = false
    var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    var feed: AsyncStream<(Data, BackendLinkLane)>.Continuation?
    var reader: Task<Void, Never>?
    var task: Task<Void, Never>?
    /// Remote candidates taken for this link (Security S4: at most `PeerLink.mostRemoteCandidates`-like 32).
    var candidates = 0
    /// The device whose TURN login was made ready at this connection's sealed handshake (before its hello, which may
    /// still be refused): the connection closing withdraws it like any other (Reviewer 27 #2).
    var prewarmed: String?
    init(path: BackendRemoteLinkPath) { self.path = path }
}

extension BackendRemoteHost {
    /// The client says it takes a link (hello capabilities); the host says it offers one (welcome capabilities).
    public static let linkCapability = "link.dc2"
    /// §11 "link only" (m5-direct-only): the relay carries no data, only the meeting (hello, signalling).
    public static let linkOnlyCapability = "link.only"
    /// Phones and the web reach this Mac only over a link now (§11.5); Mac guests keep their relay connection.
    static func linkClientPlatform(_ platform: String?) -> Bool {
        let name = (platform ?? "").lowercased()
        return ["ios", "ipados", "android", "web"].contains { name.hasPrefix($0) }
    }
    static func cannotLink(_ platform: String?) -> String {
        (platform ?? "").lowercased().hasPrefix("web")
            ? "This browser can't make the direct connection this Mac now uses. Use a current Chrome, Safari, Edge or Firefox."
            : "This phone can't make the direct connection this Mac now uses. Update Terminal Deck on this phone."
    }
    /// No open link this long after the offer → stay on the relay for this connection (contract §2.6).
    static let linkDeadlineMs = 10_000
    /// Link messages held before the client's marker: at most this long and this many bytes (contract §5).
    static let linkHoldMs = 5_000, linkHoldBytes = 4 * 1024 * 1024

    /// At most this many remote candidates per link (Security S4).
    static let linkMostCandidates = 32

    /// Whether this connection gets a link: an engine, a sealed relay connection, a client that asked, and a device with
    /// any access (Security M2, revised 3 Nov for link-only §11.6: Hoot-only too — the link is its only way now; never a
    /// device whose access is off, so that one never gets a TURN login).
    func linkWanted(_ id: UUID, access: BackendINT2PhoneAccessLevel?) -> Bool {
        guard linkEngine != nil, let row = live[id], row.device != nil, (row.wire.channelBinding?.count ?? 0) >= 16 else { return false }
        guard access != nil else { return false }
        return row.capabilities.contains(Self.linkCapability)
    }

    /// Right after the welcome: fetch the ICE servers, open the peer connection, send the offer (inside the sealed channel).
    func startLink(_ id: UUID) {
        guard let engine = linkEngine, let binding = live[id]?.wire.channelBinding, let device = live[id]?.device?.id,
              live[id]?.link.token == nil else { return }
        linkEligible.insert(device)
        let token = UUID()
        let (stream, feed) = AsyncStream<(Data, BackendLinkLane)>.makeStream()
        let inbox = BackendRemoteLinkInbox()
        live[id]?.link.token = token
        live[id]?.link.feed = feed
        live[id]?.link.reader = Task { [weak self] in
            for await (data, lane) in stream {
                guard let self, !Task.isCancelled else { return }
                await self.linkInbound(id, token, data, lane)
                inbox.remove(data.count)
            }
        }
        live[id]?.link.task = Task { [weak self] in
            #if DEBUG
            let askedAt = Date()
            #endif
            let (servers, policy) = await engine.servers(device: device)
            #if DEBUG
            BackendRemoteRelayClient.note("conn: ICE servers in \(Int(Date().timeIntervalSince(askedAt) * 1_000)) ms (\(servers.contains { $0.urls.contains { $0.hasPrefix("turn") } } ? "with TURN" : "STUN only"))")
            #endif
            guard let self, await self.linkCurrent(id, token) else { return }
            let events = BackendLinkEvents(
                candidate: { [weak self] sdp, mid, index in Task { await self?.linkCandidate(id, token, sdp: sdp, mid: mid, index: index) } },
                open: { [weak self] route in Task { await self?.linkOpened(id, token, route: route) } },
                closed: { [weak self] why in Task { await self?.linkEnded(id, token, why: why, tell: true) } },
                message: { [weak self] data, lane in
                    // In arrival order (the library calls one at a time); the reader handles them one by one.
                    if inbox.add(data.count) > Self.linkHoldBytes {
                        Task { await self?.linkEnded(id, token, why: "Too much arrived on the direct link before its hand-over.", tell: true) }
                        return
                    }
                    feed.yield((data, lane))
                })
            do {
                let connection = try engine.connect(servers: servers, policy: policy, events: events)
                guard await self.linkAttach(id, token, connection) else { connection.close(); return }
                let offer = try await connection.offer()
                guard let fingerprint = BackendLinkBinding.fingerprint(in: offer) else { throw NativeRPCError(code: "unavailable", message: "no fingerprint") }
                let bind = BackendLinkBinding.make(binding: binding, role: "host", fingerprint: fingerprint)
                let signal = try BackendRemoteServerMessage(.linkPeer, fields: [
                    .init("op", .string("offer")), .init("sdp", .string(offer)), .init("fp", .string(fingerprint)),
                    .init("bind", .string(bind)), .init("ice", .array(servers.map(\.wire))), .init("policy", .string(policy))])
                guard await self.linkCurrent(id, token) else { return }
                try await self.linkSignal(id, signal)
                try? await Task.sleep(for: .milliseconds(Self.linkDeadlineMs))
                await self.linkDeadline(id, token)
            } catch {
                await self.linkEnded(id, token, why: "The direct link could not start.", tell: true)
            }
        }
    }

    func linkCurrent(_ id: UUID, _ token: UUID) -> Bool { live[id]?.link.token == token }

    private func linkAttach(_ id: UUID, _ token: UUID, _ connection: any BackendLinkConnection) -> Bool {
        guard linkCurrent(id, token) else { return false }
        live[id]?.link.connection = connection
        live[id]?.link.offeredAt = clock()
        return true
    }

    private func linkSignal(_ id: UUID, _ message: BackendRemoteServerMessage) async throws {
        guard let row = live[id] else { return }
        try await row.writer.send(try BackendRemoteProtocol.serialize(message))
    }

    private func linkCandidate(_ id: UUID, _ token: UUID, sdp: String, mid: String?, index: Int32) async {
        guard linkCurrent(id, token) else { return }
        var fields: [NativeRPCValue.Field] = [.init("op", .string("cand")), .init("c", .string(sdp)), .init("idx", .number(Double(index)))]
        if let mid { fields.append(.init("mid", .string(mid))) }
        if let signal = try? BackendRemoteServerMessage(.linkPeer, fields: fields) { try? await linkSignal(id, signal) }
    }

    /// Every channel is open: the marker goes as the last relay message and from then on everything goes on the link.
    private func linkOpened(_ id: UUID, _ token: UUID, route: String) async {
        guard linkCurrent(id, token), let row = live[id], let connection = row.link.connection, !row.link.open else { return }
        live[id]?.link.open = true
        live[id]?.link.route = route
        row.link.path.attach(connection, failure: { [weak self] why in Task { await self?.linkEnded(id, token, why: why, tell: true) } })
        // The marker, then everything that waited for the link (§11.2), through the one ordered writer.
        do { try await row.writer.send(BackendRemoteLinkPath.movedText) }
        catch { await linkEnded(id, token, why: "The hand-over could not be sent.", tell: true); return }
        let took = Int((clock() - row.link.offeredAt).rounded())
        BackendRemoteRelayClient.note("link: up \(route)\(connection.overTCP ? " over TCP" : "") in \(took) ms (\(row.device?.name ?? "a device")\(row.link.clientOnly ? ", link only" : ""))")
    }

    private func linkDeadline(_ id: UUID, _ token: UUID) async {
        guard linkCurrent(id, token), live[id]?.link.open != true else { return }
        await linkEnded(id, token, why: "No direct path within \(Self.linkDeadlineMs / 1_000) s.", tell: true)
    }

    /// The link ended. After either side moved onto it the sealed connection closes too (contract §7: the client
    /// reconnects at once). Before that, a link-only connection (§11.3) closes as well: there is no other way to carry
    /// anything (the client says "Can't reach your Mac"); only the old wire mode stayed on the relay.
    func linkEnded(_ id: UUID, _ token: UUID, why: String, tell: Bool) async {
        guard linkCurrent(id, token), let row = live[id] else { return }
        let moved = row.link.path.hasMoved || row.link.clientMoved
        let linkOnly = row.link.path.currentMode != .wire
        let connection = row.link.path.detach() ?? row.link.connection
        live[id]?.link.connection = nil; live[id]?.link.open = false; live[id]?.link.token = nil
        row.link.task?.cancel()
        row.link.feed?.finish(); live[id]?.link.feed = nil
        for waiter in row.link.waiters.values { waiter.resume(returning: false) }
        live[id]?.link.waiters = [:]
        connection?.close()
        BackendRemoteRelayClient.note("link: ended \(why)")
        if moved {
            await disconnect(id, code: 1001, reason: "The direct link ended.")
            return
        }
        if tell, let signal = try? BackendRemoteServerMessage(.linkPeer, fields: [.init("op", .string("end"))]) { try? await linkSignal(id, signal) }
        if linkOnly { await disconnect(id, code: 1001, reason: Self.unreachable) }
    }

    /// Why a link-only connection closed before its link opened (§11.3).
    static let unreachable = "This device can't be reached directly."

    /// The client's `link.moved` came over the relay (handled in `take`, in arrival order).
    func linkClientMoved(_ id: UUID) {
        guard live[id]?.link.token != nil else { return }
        live[id]?.link.clientMoved = true
        let waiters = live[id]?.link.waiters ?? [:]
        live[id]?.link.waiters = [:]
        for waiter in waiters.values { waiter.resume(returning: true) }
    }

    private func linkWaitForClient(_ id: UUID, _ token: UUID) async -> Bool {
        // A link-only client sends nothing app-level on the relay: nothing to order against, nothing to hold (§11.2).
        if live[id]?.link.clientMoved == true || live[id]?.link.clientOnly == true { return true }
        guard linkCurrent(id, token) else { return false }
        let ticket = UUID()
        let moved = await withCheckedContinuation { (waiter: CheckedContinuation<Bool, Never>) in
            live[id]?.link.waiters[ticket] = waiter
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Self.linkHoldMs))
                await self?.linkHoldExpired(id, ticket)
            }
        }
        return moved
    }

    /// Security N3: the client's marker is read only after the relay frames before it are answered, so while this
    /// connection still has a frame being answered (a slow attach, say) the hold waits on, bounded by the byte limit.
    private func linkHoldExpired(_ id: UUID, _ ticket: UUID) {
        guard let row = live[id], row.link.waiters[ticket] != nil else { return }
        if row.pipeline.settled < row.pipeline.next {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Self.linkHoldMs))
                await self?.linkHoldExpired(id, ticket)
            }
            return
        }
        live[id]?.link.waiters.removeValue(forKey: ticket)?.resume(returning: false)
    }

    /// One message from the link: video lanes at once (they carry nothing from a client); `td.ctl` after the client's
    /// marker, through exactly the same door as the relay's messages.
    private func linkInbound(_ id: UUID, _ token: UUID, _ data: Data, _ lane: BackendLinkLane) async {
        guard linkCurrent(id, token) else { return }
        // Security S1: a client writes only on td.ctl (contract §4); anything on the video channels ends the link.
        guard lane == .control else {
            await linkEnded(id, token, why: "The device wrote on a video channel.", tell: true)
            return
        }
        if !(await linkWaitForClient(id, token)) {
            await linkEnded(id, token, why: "The device's hand-over never came.", tell: true)
            return
        }
        guard let text = String(data: data, encoding: .utf8) else {
            await linkEnded(id, token, why: "The device sent a message that is not text.", tell: true)
            return
        }
        // The next message is read at once (m5-direct-only: an attach or a key never waits behind a slow answer here;
        // order is kept by the pipeline's numbering), unless this connection already has many unanswered.
        if let taken = take(id, text: text, viaLink: true), !taken.alongside, backlogged(id) { await taken.answered.value }
    }

    /// The client's signalling: its answer (checked against this pairing), its candidates, or the end.
    func handleLinkPeer(_ id: UUID, _ message: BackendRemoteClientMessage) async {
        guard let row = live[id], let token = row.link.token else { return }
        switch message["op"].string {
        case "answer":
            guard let connection = row.link.connection, let binding = row.wire.channelBinding,
                  let sdp = message["sdp"].string, let fingerprint = message["fp"].string, let bind = message["bind"].string,
                  BackendLinkBinding.fingerprint(in: sdp) == fingerprint,
                  BackendLinkBinding.check(bind, binding: binding, role: "client", fingerprint: fingerprint) else {
                await linkEnded(id, token, why: "The device's answer did not match this pairing.", tell: true)
                return
            }
            do { try await connection.accept(answer: sdp) }
            catch { await linkEnded(id, token, why: "The device's answer could not be used.", tell: true) }
        case "cand":
            // Security S4: at most 32, and never loopback, unspecified or multicast addresses.
            guard let candidate = message["c"].string, row.link.candidates < Self.linkMostCandidates,
                  BackendLinkCandidate.usable(candidate) else { return }
            live[id]?.link.candidates += 1
            row.link.connection?.add(candidate: candidate, mid: message["mid"].string, index: Int32(message["idx"].number ?? 0))
        case "end":
            await linkEnded(id, token, why: "The device ended it.", tell: false)
        default:
            break
        }
    }

    /// The connection closed: its link goes with it, and when it was the device's last connection its TURN login is
    /// withdrawn (Security M2) — 2 minutes later, if the device has not come back meanwhile (§11.6: a reconnect reuses the
    /// login instead of waiting ~450 ms for a new one).
    func linkClosed(_ row: Connection) {
        let connection = row.link.path.detach() ?? row.link.connection
        row.link.task?.cancel(); row.link.reader?.cancel(); row.link.feed?.finish()
        for waiter in row.link.waiters.values { waiter.resume(returning: false) }
        connection?.close()
        // Its last connection closed: withdraw the login this run handed it (only that login, if still current — R1).
        // Reviewer 27 #2: always, also when no link ever started (a phone refused at its hello, an older computer that
        // never asks for a link): its login may have been made ready at the handshake. Holding none, nothing is asked.
        if let device = row.device?.id ?? row.link.prewarmed, !linkDeviceConnected(device) {
            let grace = loginGraceMs
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(grace))
                await self?.linkReleaseIfGone(device)
            }
        }
    }

    /// Security S1 (27): the host is stopping. The 2-minute grace timers would fire after the relay is gone (no live
    /// client to carry `/v1/turn/revoke`, so every login would live on up to its hour): withdraw them all now, before
    /// the relay stops. The timers then find nothing held.
    public func linkWithdrawAll() async {
        guard let engine = linkEngine else { return }
        await engine.releaseAll()
    }

    /// Tests: how long a TURN login outlives its device's last connection (§11.6; 2 minutes in the app).
    func setLoginGrace(_ milliseconds: Int) { loginGraceMs = milliseconds }

    private func linkReleaseIfGone(_ device: String) {
        guard !linkDeviceConnected(device) else { return }
        linkRelease(device, force: false)
    }

    /// A connection of `device` is live (its hello read, or its login made ready at the handshake).
    private func linkDeviceConnected(_ device: String) -> Bool {
        live.values.contains { $0.device?.id == device || $0.link.prewarmed == device }
    }

    /// The device holding this key (sealed handshake done, hello not yet read): its TURN login is made ready, and the
    /// connection remembers whose it is (so closing it withdraws the login, hello or not).
    func linkPrewarm(_ id: UUID, key: Data) {
        guard let engine = linkEngine else { return }
        let eligible = linkEligible
        Task { [weak self, trust] in
            for device in await trust.listDevices() where eligible.contains(device.id) {
                if await trust.deviceHoldsKey(device.id, key: key) {
                    if await self?.linkPrewarmed(id, device: device.id) == true { await engine.prewarm(device: device.id) }
                    return
                }
            }
        }
    }

    /// False when the connection already went: no login is asked for it.
    private func linkPrewarmed(_ id: UUID, device: String) -> Bool {
        guard live[id] != nil else { return false }
        live[id]?.link.prewarmed = device
        return true
    }

    private func linkRelease(_ device: String, force: Bool) {
        guard let engine = linkEngine else { return }
        Task { await engine.release(device: device, force: force) }
    }

    /// The devices that may hold a TURN login now: paired, approved, with any access but none.
    private func linkEligibleNow() async -> Set<String> {
        var eligible: Set<String> = []
        for device in await trust.listDevices() {
            // §11.6: any access but none (Hoot-only included).
            if await trust.phoneAccess(device.id) != nil, await trust.isApproved(device.id) { eligible.insert(device.id) }
        }
        return eligible
    }

    /// At start and after every trust change (a device unpaired, revoked or its access switched): a device that is no
    /// longer eligible loses its link and its TURN login, withdrawn unconditionally (Security M2). At the first run
    /// (start, or the engine arriving) every paired device without access is withdrawn too: it may still hold a login
    /// from before a restart.
    func linkRefreshLogins() async {
        guard linkEngine != nil else { return }
        let now = await linkEligibleNow()
        let gone = linkEligible.subtracting(now)
        let first = !linkRefreshed
        linkRefreshed = true
        linkEligible = now
        for device in gone {
            for (id, row) in live where row.device?.id == device {
                if let token = row.link.token { await linkEnded(id, token, why: "The device's access changed.", tell: true) }
            }
            linkRelease(device, force: true)
        }
        if first {
            for device in await trust.listDevices() where !now.contains(device.id) { linkRelease(device.id, force: true) }
        }
    }

    /// Video on the link (contract §6): nil when this connection has not moved (send it the usual way).
    public func sendDirect(_ id: UUID, data: Data, lane: BackendLinkLane) -> Bool? {
        live[id]?.link.path.direct(data, lane: lane)
    }

    /// How video goes on a connection's link now (M5): nil when it has not moved.
    public func linkVideo(_ id: UUID) -> BackendLinkVideo? {
        live[id]?.link.path.video()
    }

    /// For tests and the measurement: the path a connection's link runs on ("host", "internet", "turn"), nil off it.
    public func linkRoute(_ id: UUID) -> String? {
        guard let link = live[id]?.link, link.open, link.path.hasMoved else { return nil }
        return link.route
    }

    /// For tests: the connections that said hello, in order of connecting.
    public func linkConnectionIDs() -> [UUID] { live.filter { $0.value.device != nil }.sorted { $0.value.connectedAt < $1.value.connectedAt }.map(\.key) }
}

/// Remote candidate lines the host passes on (Security S4; R3: addresses parsed with inet_pton).
enum BackendLinkCandidate {
    /// Not loopback, unspecified, multicast or broadcast; an mDNS `.local` name passes (a browser's host candidate).
    static func usable(_ line: String) -> Bool {
        let words = (line.hasPrefix("a=") ? String(line.dropFirst(2)) : line).split(separator: " ")
        guard words.count > 5 else { return false }
        return usableAddress(String(words[4]))
    }

    static func usableAddress(_ text: String) -> Bool {
        let address = text.lowercased()
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 { return v4Usable(withUnsafeBytes(of: v4.s_addr) { Array($0) }) }   // network order
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 {
            let b = withUnsafeBytes(of: v6) { Array($0) }
            if b[0] == 0xff { return false }                                                          // multicast
            if b[0..<15].allSatisfy({ $0 == 0 }), b[15] <= 1 { return false }                         // :: and ::1
            if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff { return v4Usable(Array(b[12...15])) } // ::ffff:v4
            return true
        }
        return address.hasSuffix(".local") && address.count <= 255 && address.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
    }

    private static func v4Usable(_ b: [UInt8]) -> Bool {
        !(b[0] == 127 || b[0] == 0 || (224...239).contains(b[0]) || b.allSatisfy { $0 == 255 })
    }
}

extension BackendRemoteProtocol {
    /// The `link.*` frames' shapes (contract §2, §5).
    static func parseLink(_ r: BackendRemoteReader) throws -> NativeRPCValue? {
        switch r.type {
        case "link.moved": return r.base
        case "link.peer":
            let op = try r.named("op", allowed: ["answer", "cand", "end"], reason: "link.peer with an unusable op")
            var m = r.base.setting("op", .string(op))
            try r.optional("sdp", into: &m) { .string(try r.text("sdp", reason: "link.peer with an unusable sdp", bytes: 32_000)) }
            try r.optional("fp", into: &m) { .string(try r.text("fp", reason: "link.peer with an unusable fp", bytes: 200)) }
            try r.optional("bind", into: &m) { .string(try r.text("bind", reason: "link.peer with an unusable bind", bytes: 64)) }
            try r.optional("c", into: &m) { .string(try r.text("c", reason: "link.peer with an unusable candidate", bytes: 2_000)) }
            try r.optional("mid", into: &m) { .string(try r.text("mid", reason: "link.peer with an unusable mid", bytes: 32)) }
            try r.optional("idx", into: &m) { .number(try r.whole("idx", 0, 64, reason: "link.peer with an unusable idx")) }
            return m
        default: return nil
        }
    }
}
