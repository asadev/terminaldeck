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
    /// `body` runs whenever the control channel's queue drops to `below` bytes or fewer (the channel's own low-water
    /// notice; it may run on the library's thread).
    func whenControlDrains(below: UInt64, _ body: @escaping @Sendable () -> Void)
}

extension BackendLinkConnection {
    public var overTCP: Bool { false }
    public func queued(_ lane: BackendLinkLane) -> UInt64 { 0 }
    public func whenControlDrains(below: UInt64, _ body: @escaping @Sendable () -> Void) {}
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
    static let relayTypes: Set<String> = ["welcome", "enrolled", "device.access", "link.peer", "link.moved", "resume.ticket", "resume.no"]
    /// Messages waiting for the move: at most this many bytes (more means the link has failed).
    static let mostWaitingBytes = 4 * 1024 * 1024
    private let lock = NSLock()
    private let relay: @Sendable (String) async throws -> Void
    private var link: (any BackendLinkConnection)?
    private var moved = false
    /// A TURN phone takes video lanes immediately while control stays on the relay socket.
    private var videoFlag = false
    private var mode = Mode.wire
    private var waiting: [String] = []
    private var waitingBytes = 0
    private var relayGone = false
    private var failure: (@Sendable (String) -> Void)?
    // link.keep (17 Nov, LINK-KEEP-CONTRACT.md): the move back from a link to the relay without loss or repeat.
    /// Both sides claimed `link.keep`: a link that ends hands its connection back to the relay.
    private var keep = false
    /// The td.ctl messages handed to the current link's channel, in the order handed (the newest `mostSentBytes`).
    private var sent: [String] = []
    private var sentBytes = 0
    /// How many handed messages were trimmed from the front of `sent` (message number = sentBase + index + 1).
    private var sentBase = 0
    /// Between this side's `link.back` and the other side's: app messages wait in `waiting`, in order.
    private var returning = false
    /// What the ended link never took: its outbox's contents, then messages refused by the channel or the stopped outbox.
    private var leftover: [String] = []
    /// Something meant for the link was thrown away: the move back cannot be made safely (the connection closes).
    private var backBroken = false
    static let mostSentBytes = 8 * 1024 * 1024
    /// The other side's `link.back` came: written through the connection's one ordered writer (never sent anywhere), so
    /// the resend lands exactly between what was written before and after it, like `link.moved`.
    static let backDonePrefix = "\u{1}link.back.done:"
    static func backText(got: Int) -> String { #"{"t":"link.back","got":"# + String(got) + "}" }
    var keeps: Bool {
        get { lock.withLock { keep } }
        set { lock.withLock { keep = newValue } }
    }
    var isReturning: Bool { lock.withLock { returning } }
    /// 15 Nov hidden off switch for the phone-link outbox (no screen shows it): while `outboxOffKey` is YES in the
    /// app's own defaults, every link that starts after that sends the plain way, as 0220ze did (straight onto the
    /// channel, nothing queued here, nothing dropped). Read at each link start, so a phone reconnect is enough.
    ///   defaults write dev.terminaldeck.app TDLinkOutboxOff -bool YES    (back on: defaults delete dev.terminaldeck.app TDLinkOutboxOff)
    static let outboxOffKey = "TDLinkOutboxOff"
    static let outboxOffDomain = "dev.terminaldeck.app"
    /// The app and the session host's Mac reach both run links; either may sit outside that domain (a dev copy, a
    /// helper), so both its own defaults and the app's domain are read.
    static func outboxSwitchedOff() -> Bool {
        UserDefaults.standard.bool(forKey: outboxOffKey) || (UserDefaults(suiteName: outboxOffDomain)?.bool(forKey: outboxOffKey) ?? false)
    }
    private let outboxOff: @Sendable () -> Bool
    init(relay: @escaping @Sendable (String) async throws -> Void,
         outboxOff: @escaping @Sendable () -> Bool = BackendRemoteLinkPath.outboxSwitchedOff) {
        self.relay = relay; self.outboxOff = outboxOff
    }

    /// 14 Nov phone link: what goes on the link waits here, answers first, never more than the channel takes at once.
    private var outbox: BackendRemoteLinkOutbox?
    private var resyncing: (@Sendable (String) -> Void)?
    private var listsLost: (@Sendable () -> Void)?
    private var named = "a device"
    /// The device's name in the outbox's log lines (set when the link opens).
    var deviceName: String {
        get { lock.withLock { named } }
        set { lock.withLock { named = newValue } }
    }
    /// The host sends a session afresh to this connection when its output fell behind (`BackendRemoteLinkOutbox`).
    func onResync(_ body: @escaping @Sendable (String) -> Void) { lock.withLock { resyncing = body } }
    /// An unasked list was thrown away with a link: the host must not count it as delivered.
    func onListsLost(_ body: @escaping @Sendable () -> Void) { lock.withLock { listsLost = body } }
    func resyncAbandoned(_ session: String) { lock.withLock { outbox }?.resyncAbandoned(session) }
    /// Bytes waiting in the outbox (not yet handed to the channel).
    var outboxWaitingBytes: Int { lock.withLock { outbox }?.waitingBytes ?? 0 }
    /// The link has had more than a little waiting for over a second (`BackendRemoteLinkOutbox.isSlow`).
    var isSlow: Bool { lock.withLock { outbox }?.isSlow ?? false }

    func attach(_ link: (any BackendLinkConnection)?, failure: (@Sendable (String) -> Void)?) {
        let keeping = lock.withLock { () -> Bool in
            if link != nil { sent = []; sentBytes = 0; sentBase = 0; leftover = []; backBroken = false }
            return keep
        }
        let made = outboxOff() ? nil : link.map { link in
            BackendRemoteLinkOutbox(send: { [weak self] data in
                    let ok = link.send(data, lane: .control)
                    if ok, keeping { self?.handed(data) }
                    return ok
                }, queued: { link.queued(.control) },
                failed: { why in failure?(why) },
                resync: { [weak self] session in
                    guard let self else { return }
                    let body = self.lock.withLock { self.resyncing }
                    body?(session)
                },
                listsLost: { [weak self] in
                    guard let self else { return }
                    let body = self.lock.withLock { self.listsLost }
                    body?()
                },
                log: { BackendRemoteRelayClient.note($0) },
                label: { [weak self] in self?.deviceName ?? "a device" })
        }
        made?.keepOnFailure = keeping
        if let link, let made {
            // The channel's own "queue is low" notice tops it up (off its callback thread: a send from inside it could
            // call back in); the outbox's slow timer is only the safety net.
            link.whenControlDrains(below: BackendRemoteLinkOutbox.lowMark) { [weak made] in
                DispatchQueue.global(qos: .userInitiated).async { made?.pump() }
            }
        }
        let previous = lock.withLock { () -> BackendRemoteLinkOutbox? in
            let old = outbox
            self.link = link; self.failure = failure; outbox = made; videoFlag = false
            return old
        }
        previous?.stop()
    }
    func set(_ mode: Mode) { lock.withLock { self.mode = mode } }
    var currentMode: Mode { lock.withLock { mode } }
    var hasMoved: Bool { lock.withLock { moved } }
    func videoOnLink() { lock.withLock { videoFlag = true } }
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
        if text.hasPrefix(Self.backDonePrefix) {
            try await finishBack(peerGot: Int(text.dropFirst(Self.backDonePrefix.count)) ?? -1)
            return
        }
        if text.hasPrefix(#"{"t":"link.proven""#) { if !relayIsGone { try await relay(text) }; return }
        if text.hasPrefix(#"{"t":"link.back""#) { if !relayIsGone { try await relay(text) }; return }
        let held = lock.withLock { () -> Bool in
            guard returning else { return false }
            let type = Self.type(of: text) ?? ""
            if ["link.peer", "ping", "pong"].contains(type) { return false }
            waiting.append(text); waitingBytes += text.utf8.count
            if waitingBytes > Self.mostWaitingBytes { backBroken = true }
            return true
        }
        if held { return }
        if text == Self.movedText {
            if !relayIsGone { try? await relay(text) }
            // Everything that waited for the move goes first, in order (§11.2).
            let (queued, link, failure) = lock.withLock { () -> ([String], (any BackendLinkConnection)?, (@Sendable (String) -> Void)?) in
                moved = link != nil
                defer { waiting = []; waitingBytes = 0 }
                return (moved ? waiting : [], link, self.failure)
            }
            for message in queued { try sendOnLink(message, link, failure) }
            return
        }
        let route = lock.withLock { () -> (mode: Mode, moved: Bool, link: (any BackendLinkConnection)?, failure: (@Sendable (String) -> Void)?, relayGone: Bool) in
            (mode, moved, link, failure, relayGone)
        }
        switch route.mode {
        case .wire:
            // dc2 terms: control stays on the relay until the Mac moves; signalling always uses the relay.
            if text.hasPrefix(Self.signalPrefix) {
                if !route.relayGone { try await relay(text) }
                return
            }
            guard route.moved else { try await relay(text); return }
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
        // Through this link's outbox (answers first, the channel never handed more than it takes; 14 Nov phone link).
        let keeping = keeps
        if let link, let outbox = lock.withLock({ (self.link as AnyObject?) === (link as AnyObject) ? outbox : nil }) {
            if outbox.put(text) { return }
            if keeping { lock.withLock { leftover.append(text) }; return }
            throw NativeRPCError(code: "unavailable", message: "The direct link ended.")
        }
        if let link, link.send(Data(text.utf8), lane: .control) {
            if keeping { handed(Data(text.utf8)) }
            return
        }
        if keeping, link != nil || lock.withLock({ returning }) {
            // The link refused it (or is already gone): it goes over the relay with the move back.
            lock.withLock { leftover.append(text) }
            failure?("A message could not go on the direct link.")
            return
        }
        failure?("A message could not go on the direct link.")
        throw NativeRPCError(code: "unavailable", message: "The direct link ended.")
    }

    /// Video (contract §6): nil before the move unless enabled on a TURN link, true when it went on `lane`, false when it was
    /// dropped (the moving channel is full; the viewer asks for a keyframe).
    func direct(_ data: Data, lane: BackendLinkLane) -> Bool? {
        guard let link = lock.withLock({ moved || videoFlag ? link : nil }) else { return nil }
        // M5: over TCP every video message goes the reliable way (one channel, one order; nothing is ever given up).
        return link.send(data, lane: lane == .moving && link.overTCP ? .still : lane)
    }

    /// How video goes on the link now (M5): also available before the move on a kept TURN link.
    func video() -> BackendLinkVideo? {
        guard let link = lock.withLock({ moved || videoFlag ? link : nil }) else { return nil }
        return BackendLinkVideo(reliableOnly: link.overTCP, queuedMoving: link.queued(.moving), queuedStill: link.queued(.still))
    }

    /// One td.ctl message handed to the channel (link.keep).
    private func handed(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        lock.withLock {
            sent.append(text); sentBytes += text.utf8.count
            while sentBytes > Self.mostSentBytes, !sent.isEmpty { sentBytes -= sent.removeFirst().utf8.count; sentBase += 1 }
        }
    }
    /// Tests: how many td.ctl messages went to the current link's channel.
    var handedCount: Int { lock.withLock { sentBase + sent.count } }

    /// link.keep: the link ended. It is let go; from now on app messages wait (in `waiting`, after anything that
    /// already waited for a move) until the other side's `link.back`, and the relay carries everything afterwards.
    /// The outbox's contents are kept to go over the relay. Returns the link to close.
    func beginBack() -> (any BackendLinkConnection)? {
        let (link, box) = lock.withLock { () -> ((any BackendLinkConnection)?, BackendRemoteLinkOutbox?) in
            defer { self.link = nil; failure = nil; outbox = nil; returning = true; moved = false; videoFlag = false; mode = .wire }
            return (self.link, outbox)
        }
        if let box {
            let left = box.takeAll()
            lock.withLock {
                if let left { leftover.insert(contentsOf: left.map { String(decoding: $0, as: UTF8.self) }, at: 0) } else { backBroken = true }
            }
        }
        return link
    }

    /// The other side's `link.back` (it handled the first `peerGot` of this side's td.ctl messages): every later one,
    /// what the link never took, then what waited, all over the relay, in that order. Throws when that cannot be done
    /// exactly (the connection then closes, as without link.keep).
    private func finishBack(peerGot: Int) async throws {
        let out = lock.withLock { () -> [String]? in
            defer { sent = []; sentBytes = 0; sentBase = 0; leftover = []; waiting = []; waitingBytes = 0; returning = false }
            guard returning, !backBroken, peerGot >= sentBase, peerGot <= sentBase + sent.count else { return nil }
            return Array(sent[(peerGot - sentBase)...]) + leftover + waiting
        }
        guard let out, !relayIsGone else { throw NativeRPCError(code: "unavailable", message: "The direct link ended.") }
        for text in out { try await relay(text) }
    }

    func detach() -> (any BackendLinkConnection)? {
        let (link, box) = lock.withLock { () -> ((any BackendLinkConnection)?, BackendRemoteLinkOutbox?) in
            defer { self.link = nil; failure = nil; waiting = []; waitingBytes = 0; outbox = nil; videoFlag = false }
            return (self.link, outbox)
        }
        box?.stop()
        return link
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
    /// When every channel opened (host clock, ms): unasked lists wait until the link has settled (14 Nov phone link).
    var openedAt: Double = 0
    var open = false
    var route = ""
    /// The client's `link.moved` came over the relay: its link messages may be handled.
    var clientMoved = false
    /// The client said `link.only` (§11): it sends nothing app-level on the relay, so its link messages are never held,
    /// late candidates go on the link, and the link outlives the relay channel.
    var clientOnly = false
    /// This phone was welcomed on dc2 terms: relay data is accepted until the Mac's marker.
    var relayFirst = false
    /// Its open link uses TURN: control stays on the relay socket, video may use the link.
    var keptOnRelay = false
    var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    var feed: AsyncStream<(Data, BackendLinkLane)>.Continuation?
    var reader: Task<Void, Never>?
    var task: Task<Void, Never>?
    /// Remote candidates taken for this link (Security S4: at most `PeerLink.mostRemoteCandidates`-like 32).
    var candidates = 0
    /// The device whose TURN login was made ready at this connection's sealed handshake (before its hello, which may
    /// still be refused): the connection closing withdraws it like any other (Reviewer 27 #2).
    var prewarmed: String?
    // link.keep (LINK-KEEP-CONTRACT.md)
    /// Both sides claimed `link.keep`.
    var keep = false
    var prove = false
    var proofID = ""
    var proof: BackendRemoteLinkProof?
    var proofTask: Task<Void, Never>?
    var peerProven = false
    var pendingMoved = false
    var phoneRoute = "direct"
    var probeOnly = false
    var localOnly = false
    var retry = true
    /// td.ctl messages from the client on the current link handed to `take` (this side's `got`).
    var got = 0
    /// This side sent its `link.back` and waits for the client's (with its deadline).
    var backWaiting = false
    var backDeadline: Task<Void, Never>?
    /// The client's `link.back` being handled (a ping right behind it is answered after it).
    var backTask: Task<Void, Never>?
    /// The client's `link.back` came before this side had ended the link (its count, used once this side's is out).
    var clientBack: Int?
    /// The client's `link.peer answer` for the current link came over the relay (set in `take`, in arrival order).
    /// Its `link.moved` for this link can only come after it (one ordered relay), so one that comes before is a late
    /// marker of a link that already ended and is ignored (cross-check 17 Nov, "late link.moved").
    var answered = false
    /// Fresh offers made since the last link opened (the wait between them grows).
    var relinks = 0
    /// This connection's link is a fresh one after a move back: the client's link messages wait for its `link.moved`.
    var relinked = false
    var relinkTask: Task<Void, Never>?
    init(path: BackendRemoteLinkPath) { self.path = path }
}

extension BackendRemoteHost {
    /// The client says it takes a link (hello capabilities); the host says it offers one (welcome capabilities).
    public static let linkCapability = "link.dc2"
    /// §11 "link only" (m5-direct-only): the relay carries no data, only the meeting (hello, signalling).
    public static let linkOnlyCapability = "link.only"
    /// link.keep (17 Nov, LINK-KEEP-CONTRACT.md): a link that ends hands the connection back to the relay (no loss, no
    /// repeat: `link.back` with a count, both ways) and a fresh link is offered. Only when both sides claim it.
    public static let linkKeepCapability = "link.keep"
    /// How long this side waits for the client's `link.back` after sending its own.
    static let linkBackMs = 10_000
    /// The waits before each fresh offer after a move back (then the last one again).
    static let relinkWaitsMs = [1_000, 2_000, 4_000, 8_000, 16_000, 30_000]
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
        let proving = live[id]?.link.prove == true
        live[id]?.link.proofID = proving ? token.uuidString : ""
        live[id]?.link.proof = nil; live[id]?.link.peerProven = false; live[id]?.link.pendingMoved = false
        live[id]?.link.phoneRoute = "direct"; live[id]?.link.probeOnly = false; live[id]?.link.localOnly = false
        live[id]?.link.got = 0; live[id]?.link.candidates = 0; live[id]?.link.clientMoved = false
        live[id]?.link.clientBack = nil; live[id]?.link.answered = false; live[id]?.link.keptOnRelay = false
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
            let askedAt = Date()
            let (servers, policy) = await engine.servers(device: device)
            BackendRemoteRelayClient.note("conn: ICE servers in \(Int(Date().timeIntervalSince(askedAt) * 1_000)) ms (\(servers.contains { $0.urls.contains { $0.hasPrefix("turn") } } ? "with TURN" : "STUN only"))")
            guard let self, await self.linkCurrent(id, token) else { return }
            let events = BackendLinkEvents(
                candidate: { [weak self] sdp, mid, index in Task { await self?.linkCandidate(id, token, sdp: sdp, mid: mid, index: index) } },
                open: { [weak self] route in Task { await self?.linkOpened(id, token, route: route) } },
                closed: { [weak self] why in Task { await self?.linkEnded(id, token, why: why, tell: true) } },
                message: { [weak self] data, lane in
                    // Probes bypass the app reader: it may be waiting for a marker or a slow app answer.
                    if proving, lane == .control, BackendRemoteLinkProof.internalFrame(data) {
                        if inbox.add(data.count) > Self.linkHoldBytes {
                            inbox.remove(data.count)
                            Task { await self?.linkEnded(id, token, why: "Too many delivery proofs waited.", tell: true) }
                        } else {
                            Task { await self?.linkProofInbound(id, token, data, lane); inbox.remove(data.count) }
                        }
                        return
                    }
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
                let phoneServers = proving ? BackendRemoteLinkProof.withTLS(servers) : servers
                let signal = try BackendRemoteServerMessage(.linkPeer, fields: [
                    .init("op", .string("offer")), .init("sdp", .string(offer)), .init("fp", .string(fingerprint)),
                    .init("bind", .string(bind)), .init("ice", .array(phoneServers.map(\.wire))), .init("policy", .string(policy))]
                    + (proving ? [.init("proof", .string(token.uuidString))] : []))
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

    /// Every channel is open: direct links move control onto the link; TURN phones keep it on the relay socket.
    private func linkOpened(_ id: UUID, _ token: UUID, route: String) async {
        guard linkCurrent(id, token), let row = live[id], let connection = row.link.connection, !row.link.open else { return }
        let route = linkRouteForTests ?? route
        // A local-only answer must never turn into an internet path, even if native ICE chooses one unexpectedly.
        if row.link.prove, row.link.localOnly, route != "host" {
            await linkEnded(id, token, why: "The local-only attempt did not select a host path.", tell: true)
            return
        }
        live[id]?.link.open = true
        live[id]?.link.openedAt = clock()
        live[id]?.link.relinks = 0
        row.link.path.deviceName = row.device?.name ?? "a device"
        live[id]?.link.route = row.link.prove ? (row.link.phoneRoute == "wrapped" ? "wrapped" : route == "host" && !row.link.probeOnly ? "host" : "direct") : route
        row.link.path.attach(connection, failure: { [weak self] why in Task { await self?.linkEnded(id, token, why: why, tell: true) } })
        if row.link.prove {
            var proof = BackendRemoteLinkProof(id: row.link.proofID, opened: BackendRemoteLinkProof.now,
                fast: route == "host" && row.link.phoneRoute == "direct" && !row.link.probeOnly, probeOnly: row.link.probeOnly)
            proof.peer = row.link.peerProven
            // Before this side opened, only a host-path marker could have been legitimate. An older attempt's
            // delayed marker must not release a non-local link before the current phone's ordered marker.
            if !proof.fast, !row.link.peerProven { live[id]?.link.pendingMoved = false }
            live[id]?.link.proof = proof
            let took = Int((clock() - row.link.offeredAt).rounded())
            BackendRemoteRelayClient.note("link: up \(live[id]?.link.route ?? "direct") in \(took) ms (\(row.device?.name ?? "a device"))")
            await linkProofTick(id, token)
            return
        }
        let keptOnRelay = row.link.relayFirst && route == "turn"
        live[id]?.link.keptOnRelay = keptOnRelay
        if keptOnRelay {
            // No control message goes on this link: dc2 phones would hold it waiting for a marker that never comes.
            row.link.path.videoOnLink()
        } else {
            // The marker, then everything that waited for the link (§11.2), through the one ordered writer.
            do { try await row.writer.send(BackendRemoteLinkPath.movedText) }
            catch { await linkEnded(id, token, why: "The hand-over could not be sent.", tell: true); return }
        }
        let took = Int((clock() - row.link.offeredAt).rounded())
        BackendRemoteRelayClient.note("link: up \(route)\(connection.overTCP ? " over TCP" : "") in \(took) ms (\(row.device?.name ?? "a device")\(row.link.clientOnly ? ", link only" : ""))")
        if keptOnRelay { BackendRemoteRelayClient.note("link: \(row.device?.name ?? "a device") stays on the relay socket (turn)") }
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
        let moved = row.link.path.hasMoved || row.link.clientMoved || row.link.prove && row.link.pendingMoved
        let linkOnly = row.link.path.currentMode != .wire || row.link.relayFirst
        let keepBack = row.link.keep && !row.link.path.relayIsGone && moved
        let connection = (keepBack ? row.link.path.beginBack() : row.link.path.detach()) ?? row.link.connection
        live[id]?.link.connection = nil; live[id]?.link.open = false; live[id]?.link.token = nil; live[id]?.link.keptOnRelay = false
        row.link.task?.cancel(); row.link.proofTask?.cancel(); live[id]?.link.proofTask = nil
        live[id]?.link.proof = nil
        row.link.feed?.finish(); live[id]?.link.feed = nil
        for waiter in row.link.waiters.values { waiter.resume(returning: false) }
        live[id]?.link.waiters = [:]
        connection?.close()
        if !row.link.prove || why != "stalled" {
            BackendRemoteRelayClient.note("link: ended for \(row.device?.name ?? "a device"): \(why)")
        }
        // A client's `link.back` kept for a move back that is not made must not be left for a later link.
        if !keepBack { live[id]?.link.clientBack = nil }
        // link.keep: after a move the connection goes back to the relay instead of closing; a fresh link that never
        // opened just leaves it there. The first link after the welcome that never opened keeps today's rule.
        if row.link.prove, !moved, !row.link.path.relayIsGone {
            row.link.path.set(.wire)
            let completion: [NativeRPCValue.Field] = why == "quiet retest finished"
                ? [.init("proof", .string(row.link.proofID)), .init("reason", .string("retest-complete"))] : []
            if tell, let signal = try? BackendRemoteServerMessage(.linkPeer, fields: [.init("op", .string("end"))] + completion) { try? await linkSignal(id, signal) }
            linkScheduleRelink(id)
            return
        }
        if row.link.keep, !row.link.path.relayIsGone, moved || row.link.relinked {
            if moved { await linkMoveBack(id); return }
            if tell, let signal = try? BackendRemoteServerMessage(.linkPeer, fields: [.init("op", .string("end"))]) { try? await linkSignal(id, signal) }
            linkScheduleRelink(id)
            return
        }
        if moved {
            await disconnect(id, code: 1001, reason: "The direct link ended.")
            return
        }
        if tell, let signal = try? BackendRemoteServerMessage(.linkPeer, fields: [.init("op", .string("end"))]) { try? await linkSignal(id, signal) }
        if linkOnly { await disconnect(id, code: 1001, reason: Self.unreachable) }
    }

    /// link.keep: this side's `link.back` with its count, then the wait for the client's (the link is already let go
    /// by `beginBack`, called from `linkEnded`'s detach below).
    private func linkMoveBack(_ id: UUID) async {
        guard let row = live[id] else { return }
        live[id]?.link.backWaiting = true
        do { try await row.writer.send(BackendRemoteLinkPath.backText(got: row.link.got)) }
        catch { await disconnect(id, code: 1001, reason: "The direct link ended."); return }
        // The client's `link.back` may have crossed ours and finished the move back while ours was being sent.
        guard live[id]?.link.backWaiting == true else { return }
        if let got = live[id]?.link.clientBack { await linkBackDone(id, peerGot: got); return }
        live[id]?.link.backDeadline?.cancel()
        live[id]?.link.backDeadline = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.linkBackMs)); guard !Task.isCancelled else { return }
            await self?.linkBackExpired(id)
        }
    }
    private func linkBackExpired(_ id: UUID) async {
        guard live[id]?.link.backWaiting == true else { return }
        BackendRemoteRelayClient.note("link: \(live[id]?.device?.name ?? "a device") never answered the move back")
        await disconnect(id, code: 1001, reason: "The direct link ended.")
    }

    /// The client's `link.back` came over the relay (handled in `take`, ahead of every queue).
    func linkClientBack(_ id: UUID, got: Int) async {
        guard let row = live[id], row.link.keep else { return }
        if let token = row.link.token {
            // The client ended the link first: this side ends it too (and sends its own `link.back`).
            live[id]?.link.clientBack = got
            await linkEnded(id, token, why: "The device moved back to the relay.", tell: false)
            return
        }
        if row.link.backWaiting { await linkBackDone(id, peerGot: got) }
    }

    private func linkBackDone(_ id: UUID, peerGot: Int) async {
        guard let row = live[id], row.link.backWaiting else { return }
        live[id]?.link.backWaiting = false; live[id]?.link.clientBack = nil
        row.link.backDeadline?.cancel(); live[id]?.link.backDeadline = nil
        do { try await row.writer.send(BackendRemoteLinkPath.backDonePrefix + String(peerGot)) }
        catch {
            BackendRemoteRelayClient.note("link: the move back for \(row.device?.name ?? "a device") could not be made exactly; closing")
            await disconnect(id, code: 1001, reason: "The direct link ended.")
            return
        }
        if row.link.prove {
            BackendRemoteRelayClient.note("link: \(row.link.route) moved back to the relay socket for \(row.device?.name ?? "a device")")
        } else {
            BackendRemoteRelayClient.note("link: \(row.device?.name ?? "a device") carries on over the relay")
        }
        linkScheduleRelink(id)
    }

    /// A fresh offer after a growing wait (1 s, 2 s, 4 s ... 30 s; back to 1 s once a link opens).
    private func linkScheduleRelink(_ id: UUID) {
        guard let row = live[id], row.link.keep, row.link.token == nil, row.link.retry else { return }
        let wait = Self.relinkWaitsMs[min(row.link.relinks, Self.relinkWaitsMs.count - 1)]
        live[id]?.link.relinks += 1
        row.link.relinkTask?.cancel()
        live[id]?.link.relinkTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(wait)); guard !Task.isCancelled else { return }
            await self?.linkRelink(id)
        }
    }
    private func linkRelink(_ id: UUID) {
        guard let row = live[id], row.link.keep, row.link.token == nil, !row.link.backWaiting, !row.link.path.relayIsGone, row.link.retry else { return }
        live[id]?.link.relinked = true
        startLink(id)
    }

    /// Why a link-only connection closed before its link opened (§11.3).
    static let unreachable = "This device can't be reached directly."

    /// The client's `link.moved` came over the relay (handled in `take`, in arrival order).
    func linkClientMoved(_ id: UUID) {
        guard let row = live[id], row.link.token != nil else { return }
        // link.keep: a marker before this link's answer belongs to a link that already ended.
        if row.link.keep && !row.link.answered { return }
        if row.link.prove, row.link.proof?.mayMove != true {
            // The phone may open (or finish its proof) before this side's open/proven callback is handled.
            // Preserve its ordered marker, but release no app traffic until this side also permits the move.
            if row.link.proof == nil || row.link.peerProven { live[id]?.link.pendingMoved = true }
            return
        }
        live[id]?.link.pendingMoved = false
        live[id]?.link.clientMoved = true
        let waiters = live[id]?.link.waiters ?? [:]
        live[id]?.link.waiters = [:]
        for waiter in waiters.values { waiter.resume(returning: true) }
    }

    private func linkWaitForClient(_ id: UUID, _ token: UUID) async -> Bool {
        // A link-only client sends nothing app-level on the relay: nothing to order against, nothing to hold (§11.2).
        // link.keep: on a fresh link after a move back the client sent app messages on the relay, so its marker counts.
        if live[id]?.link.clientMoved == true || live[id]?.link.clientOnly == true && live[id]?.link.relinked != true { return true }
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
        // link.keep: counted only when handed on (a message read after the link ended is resent by the client).
        guard linkCurrent(id, token) else { return }
        live[id]?.link.got += 1
        if let taken = take(id, text: text, viaLink: true), !taken.alongside, backlogged(id) { await taken.answered.value }
    }

    /// The client's signalling: its answer (checked against this pairing), its candidates, or the end.
    func handleLinkPeer(_ id: UUID, _ message: BackendRemoteClientMessage) async {
        guard let row = live[id] else { return }
        if row.link.prove {
            if message["op"].string == "end", message["retry"].bool == false, message["localOnly"].bool != true {
                live[id]?.link.retry = false
                row.link.relinkTask?.cancel(); live[id]?.link.relinkTask = nil
            }
            if message["op"].string == "retry" {
                live[id]?.link.retry = true
                if row.link.token == nil, !row.link.backWaiting { startLink(id) }
                return
            }
        }
        guard let token = row.link.token else { return }
        switch message["op"].string {
        case "answer":
            guard let connection = row.link.connection, let binding = row.wire.channelBinding,
                  let sdp = message["sdp"].string, let fingerprint = message["fp"].string, let bind = message["bind"].string,
                  BackendLinkBinding.fingerprint(in: sdp) == fingerprint,
                  BackendLinkBinding.check(bind, binding: binding, role: "client", fingerprint: fingerprint) else {
                await linkEnded(id, token, why: "The device's answer did not match this pairing.", tell: true)
                return
            }
            if row.link.prove {
                guard let route = message["route"].string, ["direct", "wrapped"].contains(route) else {
                    await linkEnded(id, token, why: "The device did not name its route.", tell: true); return
                }
                let localOnly = message["localOnly"].bool == true
                if localOnly, route != "direct" || message["probeOnly"].bool == true || !BackendLinkCandidate.hostsOnly(in: sdp) {
                    await linkEnded(id, token, why: "The local-only answer included a non-local route.", tell: true); return
                }
                live[id]?.link.localOnly = localOnly
                live[id]?.link.phoneRoute = route
                live[id]?.link.probeOnly = message["probeOnly"].bool == true
            }
            do { try await connection.accept(answer: sdp) }
            catch { await linkEnded(id, token, why: "The device's answer could not be used.", tell: true) }
        case "cand":
            // Security S4: at most 32, and never loopback, unspecified or multicast addresses.
            guard let candidate = message["c"].string, row.link.candidates < Self.linkMostCandidates,
                  BackendLinkCandidate.usable(candidate), !row.link.localOnly || BackendLinkCandidate.host(candidate) else { return }
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
        row.link.backDeadline?.cancel(); row.link.relinkTask?.cancel(); row.link.proofTask?.cancel()
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
        // Account devices are not on the pairing roster: one still admitted keeps its link through a trust change of
        // some other device (REACH-CUT); a removed one was already forgotten by `dropReachDevices`.
        for id in linkEligible where await trust.isReachDevice(id) { eligible.insert(id) }
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

    /// Video on the link (contract §6): also available on a TURN link whose control stays on the relay socket.
    public func sendDirect(_ id: UUID, data: Data, lane: BackendLinkLane) -> Bool? {
        live[id]?.link.path.direct(data, lane: lane)
    }

    /// How video goes on a connection's link now (M5), including a kept TURN link.
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

    static func host(_ line: String) -> Bool {
        let words = (line.hasPrefix("a=") ? String(line.dropFirst(2)) : line).split(separator: " ")
        return words.count >= 8 && words[6] == "typ" && words[7] == "host"
    }

    static func hostsOnly(in sdp: String) -> Bool {
        sdp.components(separatedBy: .newlines).filter { $0.hasPrefix("a=candidate:") }.allSatisfy(host)
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
        case "link.proven": return r.base.setting("id", .string(try r.text("id", reason: "link.proven without an attempt", bytes: 64)))
        case "link.back": return r.base.setting("got", .number(try r.whole("got", 0, 1_000_000_000, reason: "link.back with an unusable count")))
        case "link.peer":
            let op = try r.named("op", allowed: ["answer", "cand", "end", "retry"], reason: "link.peer with an unusable op")
            var m = r.base.setting("op", .string(op))
            try r.optional("route", into: &m) { .string(try r.named("route", allowed: ["direct", "wrapped"], reason: "link.peer with an unusable route")) }
            try r.optional("localOnly", into: &m) { guard let b = r["localOnly"].bool else { throw r.bad("link.peer with unusable localOnly") }; return .bool(b) }
            try r.optional("probeOnly", into: &m) { guard let b = r["probeOnly"].bool else { throw r.bad("link.peer with unusable probeOnly") }; return .bool(b) }
            try r.optional("retry", into: &m) { guard let b = r["retry"].bool else { throw r.bad("link.peer with unusable retry") }; return .bool(b) }
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
