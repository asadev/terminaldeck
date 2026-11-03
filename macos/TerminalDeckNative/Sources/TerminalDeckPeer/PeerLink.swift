import CryptoKit
import Foundation
import LiveKitWebRTC

// stream step 2 (dc2, 2 Nov; Asad: "No Tailscale, no VPN. Wherever I am, just use it." / "one mechanism"): ONE WebRTC
// peer connection per sealed connection between this Mac and a paired phone, carrying the whole protocol — the
// terminal, every message, input — on an ordered data channel, and the screen's H.264 (`sims.video`) on two more.
// Path order is the ICE ladder: same network (host) → across the internet (STUN, hole punching) → Cloudflare Realtime
// TURN; when no path connects, everything keeps going over the relay as before. Contract: stream-step2-contract.md.
//
// The same file is compiled into the Mac (target TerminalDeckPeer) and the iPhone app (project.yml), so both ends speak
// exactly the same channels, binding and checks. Foundation + LiveKitWebRTC + CryptoKit only.
//
// Library: LiveKitWebRTC 150.7871.04 (Chromium M150), Google's WebRTC (BSD-3-Clause + patent grant), pinned by checksum.

/// One ICE server (STUN or TURN), as the Worker's `/v1/turn` answers it (`urls`, `username`, `credential`).
public struct PeerICEServer: Sendable, Equatable {
    public var urls: [String]
    public var username: String?
    public var credential: String?
    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls; self.username = username; self.credential = credential
    }
    /// Cloudflare's public STUN (no key, anycast; Dubai answers in ~10 ms): what is used when no TURN logins exist.
    public static let cloudflareSTUN = PeerICEServer(urls: ["stun:stun.cloudflare.com:3478"])
}

/// Which ICE paths may be used. `all` is the product (the ladder); the others exist to measure one rung at a time.
public enum PeerPolicy: String, Sendable {
    /// Host (same network), server-reflexive (internet peer-to-peer) and relayed (TURN), best first.
    case all
    /// No same-network path: internet peer-to-peer or TURN (measures the hole-punched path).
    case noHost = "nohost"
    /// TURN only (measures Cloudflare Realtime TURN).
    case relayOnly = "relay"
}

/// The pairing tag of a DTLS fingerprint: HMAC-SHA256 keyed by the sealed channel's Noise channel binding (the final
/// handshake hash) over `td.link.v2|<role>|<fingerprint>` (role `host` for the offer, `client` for the answer).
/// The binding is NOT secret (Security S2, 2 Nov): anyone who saw the handshake and knows the Mac's public key can work
/// it out, the relay included, so this tag is a consistency check, not a signature. What protects the link is that each
/// fingerprint travels only inside the sealed channel (Noise-encrypted end to end between the paired keys) and that
/// libwebrtc refuses any DTLS certificate whose fingerprint differs from the SDP's. So only the paired client and this
/// host can finish the handshake.
public enum PeerBinding {
    static func data(role: String, fingerprint: String) -> Data { Data("td.link.v2|\(role)|\(fingerprint)".utf8) }
    public static func make(binding: Data, role: String, fingerprint: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: data(role: role, fingerprint: fingerprint), using: SymmetricKey(data: binding))
        return Data(mac).base64EncodedString()
    }
    public static func check(_ bind: String, binding: Data, role: String, fingerprint: String) -> Bool {
        guard let given = Data(base64Encoded: bind), given.count == 32 else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(given, authenticating: data(role: role, fingerprint: fingerprint),
                                                      using: SymmetricKey(data: binding))
    }
}

/// The link's three channels (contract §4).
public enum PeerLane: Int32, Sendable, CaseIterable {
    /// `td.rt`: moving video frames (deltas), ordered, retried for at most `PeerLink.movingLifetimeMs`.
    case moving = 1
    /// `td.rel`: keyframes and the still frame's parts (M5; over TCP or on a lossy path every video frame), ordered and
    /// reliable.
    case still = 2
    /// `td.ctl`: every other protocol message, both ways, ordered and reliable.
    case control = 3
    var label: String { switch self { case .moving: "td.rt"; case .still: "td.rel"; case .control: "td.ctl" } }
}

/// One peer connection with three negotiated data channels (`PeerLane`). Messages are UTF-8 JSON texts sent as binary
/// messages; a text over `mostMessageBytes` goes in parts (first byte 0x01 more / 0x02 last), which the receiver joins.
public final class PeerLink: NSObject, @unchecked Sendable {
    public enum Role: String, Sendable { case offerer, answerer }
    public struct Events: Sendable {
        public var candidate: @Sendable (_ sdp: String, _ mid: String?, _ index: Int32) -> Void
        /// All three channels are open; `path` is "host", "internet" or "turn" (the selected candidate pair).
        public var open: @Sendable (_ path: String) -> Void
        /// The connection failed or closed (never called twice, never after `close()`).
        public var closed: @Sendable (_ why: String) -> Void
        /// One whole message (parts already joined) and the channel it came on.
        public var message: @Sendable (_ data: Data, _ lane: PeerLane) -> Void
        public init(candidate: @escaping @Sendable (String, String?, Int32) -> Void, open: @escaping @Sendable (String) -> Void,
                    closed: @escaping @Sendable (String) -> Void, message: @escaping @Sendable (Data, PeerLane) -> Void) {
            self.candidate = candidate; self.open = open; self.closed = closed; self.message = message
        }
    }
    public enum Failure: Error, Sendable { case noConnection, noDescription(String), noFingerprint }

    /// One factory per process (it owns WebRTC's threads); SSL is set up once before it.
    private static let factory: LKRTCPeerConnectionFactory = {
        _ = LKRTCInitializeSSL()
        return LKRTCPeerConnectionFactory()
    }()

    /// The moving channel's queue is never allowed past this (a moving frame that cannot go at once is dropped).
    public static let mostQueued: UInt64 = 1_500_000
    /// How long a moving frame's packets are retried on the moving channel.
    public static let movingLifetimeMs = 150
    /// A data-channel message is at most this large (SCTP's usual 256 KiB limit with room to spare); longer texts go in parts.
    public static let mostMessageBytes = 200_000
    /// A message joined from parts is at most this large; more means the link has failed.
    public static let mostJoinedBytes = 4 * 1024 * 1024
    /// ICE "disconnected" for longer than this ends the link (contract §7; a Wi-Fi blip shorter than it recovers).
    public static let disconnectedSeconds = 5.0

    public let role: Role
    public let policy: PeerPolicy
    private let events: Events
    private let lock = NSLock()
    private var connection: LKRTCPeerConnection?
    private var channels: [PeerLane: LKRTCDataChannel] = [:]
    private var joining: [PeerLane: Data] = [:]
    private var disconnectedSince: DispatchWorkItem?
    private var remoteSet = false
    private var queuedCandidates: [LKRTCIceCandidate] = []
    private var remoteCandidates = 0
    private var announced = false
    private var finished = false
    private var pair: (local: String, remote: String) = ("", "")
    public private(set) var path = ""
    private var tcp = false
    /// The selected path crosses TCP (M5): a TURN relay that this side or the other side reaches over TCP or TLS (UDP
    /// blocked). SCTP then never loses a packet, and a frame with a lifetime can only ever expire in a queue, so the
    /// host sends video the reliable way and paces it instead.
    public var overTCP: Bool { lock.withLock { tcp } }

    public init(role: Role, servers: [PeerICEServer], policy: PeerPolicy = .all, events: Events) throws {
        self.role = role; self.policy = policy; self.events = events
        super.init()
        let configuration = LKRTCConfiguration()
        configuration.iceServers = servers.map { LKRTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        configuration.sdpSemantics = LKRTCSdpSemantics(rawValue: 1)!                       // unified plan
        configuration.bundlePolicy = LKRTCBundlePolicy(rawValue: 2)!                      // max bundle
        configuration.rtcpMuxPolicy = LKRTCRtcpMuxPolicy(rawValue: 1)!                    // require
        configuration.continualGatheringPolicy = LKRTCContinualGatheringPolicy(rawValue: 1)! // Wi-Fi ↔ cellular
        switch policy {
        case .all: configuration.iceTransportPolicy = LKRTCIceTransportPolicy(rawValue: 3)!
        case .noHost: configuration.iceTransportPolicy = LKRTCIceTransportPolicy(rawValue: 2)!
        case .relayOnly: configuration.iceTransportPolicy = LKRTCIceTransportPolicy(rawValue: 1)!
        }
        // No TCP candidates (Security M1, 2 Nov): libwebrtc would otherwise open a listening TCP socket for passive
        // host candidates while a link is up. UDP ICE sockets only; TURN over TCP/TLS (from `servers`) still works.
        configuration.tcpCandidatePolicy = LKRTCTcpCandidatePolicy(rawValue: 1)!                 // disabled
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let made = Self.factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else { throw Failure.noConnection }
        connection = made
        for lane in PeerLane.allCases {
            guard let channel = made.dataChannel(forLabel: lane.label, configuration: Self.channel(lane)) else { made.close(); throw Failure.noConnection }
            channel.delegate = self
            channels[lane] = channel
        }
    }

    deinit { close() }

    private static func channel(_ lane: PeerLane) -> LKRTCDataChannelConfiguration {
        let configuration = LKRTCDataChannelConfiguration()
        configuration.isNegotiated = true      // both ends create it with the same id: nothing to announce in band
        configuration.channelId = lane.rawValue
        // Both ordered (2 Nov, measured through TURN: an unordered channel hands a retried frame over after the next one,
        // which the phone must treat as a gap and answer with a keyframe ask). Ordered + a lifetime skips a frame given up
        // on and keeps the rest in order.
        configuration.isOrdered = true
        // Moving frames: retried only while they are still worth showing (150 ms), then given up (measured 2 Nov through
        // Cloudflare TURN: with no retries at all, every lost packet cost a keyframe — 25 asks in 4 s, 6× the bytes).
        if lane == .moving { configuration.maxPacketLifeTime = Int32(PeerLink.movingLifetimeMs) }
        return configuration
    }

    // MARK: Offer / answer

    /// Offerer (the Mac): the offer SDP, already set as the local description.
    public func makeOffer() async throws -> String {
        guard let connection = lock.withLock({ self.connection }) else { throw Failure.noConnection }
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let offer: LKRTCSessionDescription = try await withCheckedThrowingContinuation { answer in
            connection.offer(for: constraints) { description, error in
                if let description { answer.resume(returning: description) } else { answer.resume(throwing: error ?? Failure.noDescription("offer")) }
            }
        }
        try await setLocal(offer, on: connection)
        return offer.sdp
    }

    /// Answerer (the phone): applies the offer and answers with the local SDP.
    public func answer(offer sdp: String) async throws -> String {
        guard let connection = lock.withLock({ self.connection }) else { throw Failure.noConnection }
        try await setRemote(LKRTCSessionDescription(type: LKRTCSdpType(rawValue: 0)!, sdp: sdp), on: connection)
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let answer: LKRTCSessionDescription = try await withCheckedThrowingContinuation { answer in
            connection.answer(for: constraints) { description, error in
                if let description { answer.resume(returning: description) } else { answer.resume(throwing: error ?? Failure.noDescription("answer")) }
            }
        }
        try await setLocal(answer, on: connection)
        return answer.sdp
    }

    /// Offerer: applies the phone's answer.
    public func accept(answer sdp: String) async throws {
        guard let connection = lock.withLock({ self.connection }) else { throw Failure.noConnection }
        try await setRemote(LKRTCSessionDescription(type: LKRTCSdpType(rawValue: 2)!, sdp: sdp), on: connection)
    }

    private func setLocal(_ description: LKRTCSessionDescription, on connection: LKRTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            connection.setLocalDescription(description) { error in if let error { done.resume(throwing: error) } else { done.resume() } }
        }
    }

    private func setRemote(_ description: LKRTCSessionDescription, on connection: LKRTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            connection.setRemoteDescription(description) { error in if let error { done.resume(throwing: error) } else { done.resume() } }
        }
        let waiting = lock.withLock { () -> [LKRTCIceCandidate] in remoteSet = true; defer { queuedCandidates = [] }; return queuedCandidates }
        for candidate in waiting { connection.add(candidate) { _ in } }
    }

    /// A candidate from the other side (held until the remote description is set).
    /// At most this many remote candidates per link (Security S4); more are ignored.
    public static let mostRemoteCandidates = 32

    public func add(candidate sdp: String, mid: String?, index: Int32) {
        // Security S4: never make this side send connectivity checks to loopback, unspecified or multicast addresses.
        guard Self.usableRemote(sdp) else { return }
        let candidate = LKRTCIceCandidate(sdp: sdp, sdpMLineIndex: index, sdpMid: mid)
        let now = lock.withLock { () -> LKRTCPeerConnection? in
            guard let connection, !finished, remoteCandidates < Self.mostRemoteCandidates else { return nil }
            remoteCandidates += 1
            if !remoteSet { queuedCandidates.append(candidate); return nil }
            return connection
        }
        now?.add(candidate) { _ in }
    }

    /// A remote candidate line worth trying: not loopback, unspecified, multicast or broadcast; an mDNS `.local` name
    /// passes (a browser's host candidate). Addresses are parsed with inet_pton (Security R3).
    public static func usableRemote(_ sdp: String) -> Bool {
        guard let text = address(sdp.hasPrefix("a=") ? String(sdp.dropFirst(2)) : sdp)?.lowercased() else { return false }
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 { return v4Usable(withUnsafeBytes(of: v4.s_addr) { Array($0) }) }   // network order
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 {
            let b = withUnsafeBytes(of: v6) { Array($0) }
            if b[0] == 0xff { return false }                                                          // multicast
            if b[0..<15].allSatisfy({ $0 == 0 }), b[15] <= 1 { return false }                         // :: and ::1
            if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff { return v4Usable(Array(b[12...15])) } // ::ffff:v4
            return true
        }
        return text.hasSuffix(".local") && text.count <= 255 && text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
    }

    private static func v4Usable(_ b: [UInt8]) -> Bool {
        !(b[0] == 127 || b[0] == 0 || (224...239).contains(b[0]) || b.allSatisfy { $0 == 255 })
    }

    // MARK: Sending

    /// True when `data` went on `lane`; false when the link is not open, the moving channel's queue is full, or the
    /// library refused it (on `control` that means the link has failed: the caller ends it).
    public func send(_ data: Data, lane: PeerLane) -> Bool {
        // The channel's own state decides (not the "open" announcement, which waits for every channel).
        let channel = lock.withLock { () -> LKRTCDataChannel? in finished ? nil : channels[lane] }
        guard let channel, channel.readyState.rawValue == 1 else { return false }
        if lane == .moving, channel.bufferedAmount > Self.mostQueued { return false }
        for part in Self.parts(data) where !channel.sendData(LKRTCDataBuffer(data: part, isBinary: true)) { return false }
        return true
    }

    /// A text as data-channel messages: itself when short enough, else parts (0x01 + bytes … 0x02 + bytes).
    public static func parts(_ data: Data) -> [Data] {
        guard data.count > mostMessageBytes else { return [data] }
        var out: [Data] = [], at = data.startIndex
        let step = mostMessageBytes - 1
        while at < data.endIndex {
            let end = data.index(at, offsetBy: step, limitedBy: data.endIndex) ?? data.endIndex
            var part = Data([end == data.endIndex ? 0x02 : 0x01])
            part.append(data[at..<end])
            out.append(part)
            at = end
        }
        return out
    }

    /// One received message → a whole message (nil while parts are still arriving; `.failure` when they break the rules).
    public enum Joined: Equatable { case whole(Data), waiting, failure }
    public static func join(_ message: Data, into pending: inout Data?) -> Joined {
        guard let first = message.first else { return .failure }
        switch first {
        case 0x01, 0x02:
            var buffer = pending ?? Data()
            buffer.append(message.dropFirst())
            guard buffer.count <= mostJoinedBytes else { pending = nil; return .failure }
            if first == 0x01 { pending = buffer; return .waiting }
            pending = nil
            return .whole(buffer)
        default:
            guard pending == nil else { pending = nil; return .failure }   // a whole message in the middle of parts
            return .whole(message)
        }
    }

    public var isOpen: Bool {
        lock.withLock { !finished && channels.count == PeerLane.allCases.count && channels.values.allSatisfy { $0.readyState.rawValue == 1 } }
    }

    /// Bytes waiting on a channel.
    public func queued(_ lane: PeerLane) -> UInt64 { lock.withLock { channels[lane] }?.bufferedAmount ?? 0 }

    public func close() {
        let parts = lock.withLock { () -> (LKRTCPeerConnection?, [LKRTCDataChannel]) in
            finished = true
            disconnectedSince?.cancel(); disconnectedSince = nil
            defer { connection = nil; channels = [:]; joining = [:] }
            return (connection, Array(channels.values))
        }
        for channel in parts.1 { channel.delegate = nil; channel.close() }
        parts.0?.delegate = nil
        parts.0?.close()
    }

    private func finish(_ why: String) {
        let first = lock.withLock { () -> Bool in defer { finished = true }; return !finished }
        guard first else { return }
        events.closed(why)
        close()
    }

    private func announceIfOpen() {
        let path = lock.withLock { () -> String? in
            guard !announced, !finished, channels.count == PeerLane.allCases.count,
                  channels.values.allSatisfy({ $0.readyState.rawValue == 1 }) else { return nil }
            announced = true
            self.path = Self.pathName(local: pair.local, remote: pair.remote)
            return self.path
        }
        if let path { events.open(path) }
    }

    // MARK: SDP helpers

    /// The DTLS fingerprint an SDP announces ("sha-256 AB:CD:…"), or nil.
    /// Nil too when the SDP names more than one distinct sha-256 fingerprint (Security S2: as the web does).
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

    /// "host", "srflx", "prflx" or "relay" from a candidate line.
    public static func candidateType(_ sdp: String) -> String? {
        let words = sdp.split(separator: " ")
        guard let at = words.firstIndex(of: "typ"), at + 1 < words.count else { return nil }
        return String(words[at + 1])
    }

    /// Strips same-network (host) candidates from a list (the `noHost` measurement also asks libwebrtc not to gather them).
    public static func isHost(_ sdp: String) -> Bool { candidateType(sdp) == "host" }

    /// A relayed candidate whose own leg to its TURN server is TCP or TLS: libwebrtc's type preference (the priority's
    /// top byte) is 2 for relayed UDP, 1 for TCP, 0 for TLS (browsers built on it say the same).
    public static func relayOverTCP(_ sdp: String) -> Bool {
        let words = (sdp.hasPrefix("a=") ? String(sdp.dropFirst(2)) : sdp).split(separator: " ")
        guard candidateType(sdp) == "relay", words.count > 3, let priority = UInt32(words[3]) else { return false }
        return priority >> 24 < 2
    }

    public static func pathName(local: String, remote: String) -> String {
        let types = [candidateType(local), candidateType(remote)]
        if types.contains("relay") { return "turn" }
        // A peer-reflexive candidate is an address learned from the checks themselves: on the same network it is a
        // private one, so the addresses decide, not the type.
        if [local, remote].allSatisfy({ address($0).map(isPrivate) ?? false }) { return "host" }
        if types.contains("srflx") || types.contains("prflx") { return "internet" }
        if types.contains("host") { return "host" }
        return "unknown"
    }

    /// The connection address of a candidate line (the 5th field).
    static func address(_ sdp: String) -> String? {
        let words = sdp.split(separator: " ")
        return words.count > 5 ? String(words[4]) : nil
    }

    /// Loopback, private IPv4 (10/8, 172.16/12, 192.168/16), link-local, or IPv6 ULA / link-local / loopback.
    static func isPrivate(_ address: String) -> Bool {
        let a = address.lowercased()
        if a.contains(":") { return a == "::1" || a.hasPrefix("fe80:") || a.hasPrefix("fc") || a.hasPrefix("fd") }
        let parts = a.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || parts[0] == 127 || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 169 && parts[1] == 254)
    }
}

extension PeerLink: LKRTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        // 4 failed, 6 closed. "Disconnected" (5) may recover on its own (a Wi-Fi blip): it ends the link only after
        // `disconnectedSeconds`; connected (2) / completed (3) again cancel that.
        switch newState.rawValue {
        case 4: finish("The direct connection failed.")
        case 6: finish("The direct connection closed.")
        case 5:
            let wait = DispatchWorkItem { [weak self] in self?.finish("The direct connection was lost.") }
            let armed = lock.withLock { () -> Bool in
                guard !finished, disconnectedSince == nil else { return false }
                disconnectedSince = wait
                return true
            }
            if armed { DispatchQueue.global().asyncAfter(deadline: .now() + Self.disconnectedSeconds, execute: wait) }
        case 2, 3:
            lock.withLock { disconnectedSince?.cancel(); disconnectedSince = nil }
        default: break
        }
    }
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        if policy == .noHost, Self.isHost(candidate.sdp) { return }
        events.candidate(candidate.sdp, candidate.sdpMid, candidate.sdpMLineIndex)
    }
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) {
        // 2 connected (the channels may have opened first), 4 failed, 5 closed.
        if newState.rawValue == 2 { announceIfOpen() }
        if newState.rawValue == 4 { finish("The direct connection failed.") }
        if newState.rawValue == 5 { finish("The direct connection closed.") }
    }
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didChangeLocalCandidate local: LKRTCIceCandidate,
                               remoteCandidate remote: LKRTCIceCandidate, lastReceivedMs lastDataReceivedMs: Int32, changeReason reason: String) {
        let overTCP = Self.relayOverTCP(local.sdp) || Self.relayOverTCP(remote.sdp)
        lock.withLock {
            pair = (local.sdp, remote.sdp)
            tcp = overTCP
            if announced { path = Self.pathName(local: local.sdp, remote: remote.sdp) }
        }
    }
}

extension PeerLink: LKRTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        switch dataChannel.readyState.rawValue {
        case 1: announceIfOpen()
        case 3: finish("The direct connection closed.")
        default: break
        }
    }
    public func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        guard let lane = PeerLane(rawValue: dataChannel.channelId) else { return }
        let joined = lock.withLock { () -> Joined? in
            guard !finished else { return nil }
            var pending = joining[lane]
            defer { joining[lane] = pending }
            return Self.join(buffer.data, into: &pending)
        }
        switch joined {
        case .whole(let data): events.message(data, lane)
        case .failure: finish("The direct connection sent a broken message.")
        case .waiting, nil: break
        }
    }
}
