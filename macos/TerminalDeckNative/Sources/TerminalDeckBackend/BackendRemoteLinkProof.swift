import Foundation
import TerminalDeckNativeCore

/// link.prove, MOBILE-DATA-DESIGN.md WIRE revision 2. These are transport messages, never app messages:
/// counting them in link.keep would make the two ends disagree about what needs replaying.
struct BackendRemoteLinkProof: Sendable {
    static let pad = String(repeating: "x", count: 16_384)
    static let turnsURL = "turns:turn.cloudflare.com:443?transport=tcp"
    static let stallMs = 4_000.0, deadlineMs = 10_000.0, retestMs = 60_000.0
    static var now: Double { ProcessInfo.processInfo.systemUptime * 1_000 }
    let id: String
    let opened: Double
    let fast: Bool
    let probeOnly: Bool
    var nextProbe: Double
    var sent = 0
    var echoes = Set<Int>()
    var received = Set<Int>()
    var lastEcho: Double
    var local = false
    var peer = false
    var moving = false

    init(id: String, opened: Double, fast: Bool, probeOnly: Bool) {
        self.id = id; self.opened = opened; self.fast = fast; self.probeOnly = probeOnly
        nextProbe = opened; lastEcho = opened
    }
    var mayMove: Bool { !probeOnly && (fast || local && peer) }
    var due: Double {
        min(nextProbe, lastEcho + Self.stallMs,
            probeOnly ? opened + Self.retestMs : !fast && !(local && peer) ? opened + Self.deadlineMs : .infinity)
    }
    func failure(at now: Double) -> String? {
        if now - lastEcho >= Self.stallMs { return "stalled" }
        if !fast && !(local && peer), now - opened >= Self.deadlineMs { return "never proved" }
        if probeOnly, now - opened >= Self.retestMs { return "quiet retest finished" }
        return nil
    }
    mutating func prove(at now: Double) -> Bool {
        guard !local, !fast, echoes.count >= 7, received.count >= 7,
              now - opened >= 3_000, now - lastEcho <= 1_000 else { return false }
        local = true
        return true
    }
    mutating func probe(at now: Double) -> Data? {
        guard now >= nextProbe else { return nil }
        guard sent < 1_000_000 else { nextProbe = lastEcho + Self.stallMs; return nil }
        sent += 1
        // Only recent outstanding echoes are useful to a four-second watchdog; bound memory on long-lived links.
        echoes = echoes.filter { $0 > sent - 32 }
        nextProbe = now + (local || fast ? 2_000 : 500)
        return Self.frame("link.probe", id: id, seq: sent)
    }
    static func frame(_ type: String, id: String, seq: Int) -> Data {
        Data(#"{"t":"\#(type)","id":"\#(id)","seq":\#(seq),"pad":"\#(pad)"}"#.utf8)
    }
    static func internalFrame(_ data: Data) -> Bool {
        guard let v = try? NativeRPCValue.parseJSON(data) else { return false }
        return v["t"].string == "link.probe" || v["t"].string == "link.echo"
    }
    /// Add TLS 443 only to a Cloudflare login. A different TURN provider's password must never be sent there.
    static func withTLS(_ servers: [BackendPhonePeerServer]) -> [BackendPhonePeerServer] {
        guard !servers.contains(where: { $0.urls.contains(turnsURL) }),
              let index = servers.firstIndex(where: { server in
                  server.username != nil && server.credential != nil && server.urls.contains { url in
                      url.hasPrefix("turn:turn.cloudflare.com:") || url.hasPrefix("turns:turn.cloudflare.com:")
                  }
              }) else { return servers }
        var result = servers
        result[index].urls.append(turnsURL)
        return result
    }
}

extension BackendRemoteHost {
    public static let linkProveCapability = "link.prove"

    /// One deadline, re-armed by delivery events. No idle polling or extra heartbeat thread.
    func linkProofArm(_ id: UUID, _ token: UUID) {
        guard linkCurrent(id, token), let proof = live[id]?.link.proof else { return }
        live[id]?.link.proofTask?.cancel()
        let delay = max(1, proof.due - BackendRemoteLinkProof.now)
        live[id]?.link.proofTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay.rounded(.up))))
            guard !Task.isCancelled else { return }
            await self?.linkProofTick(id, token)
        }
    }

    func linkProofTick(_ id: UUID, _ token: UUID, now: Double = BackendRemoteLinkProof.now) async {
        guard linkCurrent(id, token), var proof = live[id]?.link.proof else { return }
        if let why = proof.failure(at: now) {
            if why == "stalled" {
                let seconds = Int((now - proof.opened) / 1_000)
                BackendRemoteRelayClient.note("link: stalled \(live[id]?.link.route ?? "direct") after \(seconds) s for \(live[id]?.device?.name ?? "a device"); \(live[id]?.link.path.hasMoved == true ? "moving back to" : "staying on") the relay socket")
            }
            await linkEnded(id, token, why: why, tell: true)
            return
        }
        let becameProven = proof.prove(at: now)
        let data = proof.probe(at: now)
        live[id]?.link.proof = proof
        if let data, live[id]?.link.connection?.send(data, lane: .control) != true {
            await linkEnded(id, token, why: "The proof could not be sent.", tell: true); return
        }
        if becameProven {
            BackendRemoteRelayClient.note("link: proven \(live[id]?.link.route ?? "direct") in \(Int(now - proof.opened)) ms (\(live[id]?.device?.name ?? "a device"))")
            do { try await live[id]?.writer.send(#"{"t":"link.proven","id":"\#(proof.id)"}"#) }
            catch { await linkEnded(id, token, why: "The proof result could not be sent.", tell: true); return }
        }
        await linkProofMove(id, token)
        linkProofArm(id, token)
    }

    /// Called outside the app reader: a slow attach or an app-marker hold cannot hide a delivered echo.
    func linkProofInbound(_ id: UUID, _ token: UUID, _ data: Data, _ lane: BackendLinkLane) async {
        guard linkCurrent(id, token), lane == .control, var proof = live[id]?.link.proof,
              let value = try? NativeRPCValue.parseJSON(data) else { return }
        guard value["id"].string == proof.id else { return }
        guard let n = value["seq"].number, n >= 1, n <= 1_000_000, n.rounded() == n,
              value["pad"].string == BackendRemoteLinkProof.pad else {
            await linkEnded(id, token, why: "The delivery proof was malformed.", tell: true); return
        }
        let now = BackendRemoteLinkProof.now
        if proof.failure(at: now) != nil { await linkProofTick(id, token, now: now); return }
        let seq = Int(n), type = value["t"].string
        if type == "link.probe" {
            proof.received.insert(seq)
            if proof.received.count > 32 { proof.received = Set(proof.received.sorted().suffix(32)) }
            live[id]?.link.proof = proof
            if live[id]?.link.connection?.send(BackendRemoteLinkProof.frame("link.echo", id: proof.id, seq: seq), lane: .control) != true {
                await linkEnded(id, token, why: "The delivery echo could not be sent.", tell: true); return
            }
        } else if type == "link.echo", seq <= proof.sent, seq > proof.sent - 32, proof.echoes.insert(seq).inserted {
            proof.lastEcho = now
            live[id]?.link.proof = proof
        }
        await linkProofTick(id, token)
    }

    func linkPeerProven(_ id: UUID, proofID: String) async {
        guard let token = live[id]?.link.token, live[id]?.link.prove == true,
              live[id]?.link.proofID == proofID else { return }
        live[id]?.link.peerProven = true
        live[id]?.link.proof?.peer = true
        await linkProofTick(id, token)
    }

    func linkProofMove(_ id: UUID, _ token: UUID) async {
        guard linkCurrent(id, token), let row = live[id], let proof = row.link.proof,
              proof.mayMove, !proof.moving else { return }
        live[id]?.link.proof?.moving = true
        do {
            try await row.writer.send(BackendRemoteLinkPath.movedText)
            if linkCurrent(id, token), live[id]?.link.pendingMoved == true { linkClientMoved(id) }
        }
        catch { await linkEnded(id, token, why: "The hand-over could not be sent.", tell: true) }
    }
}
