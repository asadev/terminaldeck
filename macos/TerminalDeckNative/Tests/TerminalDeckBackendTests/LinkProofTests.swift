import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

extension LinkKeepTests {
    @Test("proof needs real payloads both ways for three seconds; the watchdog is exactly four seconds")
    func deliveryProofBoundaries() throws {
        var proof = BackendRemoteLinkProof(id: UUID().uuidString, opened: 0, fast: false, probeOnly: false)
        for n in 1...7 {
            let next = proof.probe(at: Double(n - 1) * 500)
            let data = try #require(next)
            let frame = try NativeRPCValue.parseJSON(data)
            #expect(frame["pad"].string?.utf8.count == 16_384)
            #expect(frame["seq"].number == Double(n))
            proof.echoes.insert(n)
        }
        proof.lastEcho = 3_000
        let oneWay = proof.prove(at: 3_000)
        #expect(!oneWay, "one-way delivery is not proof")
        proof.received = Set(1...7)
        let early = proof.prove(at: 2_999)
        let ready = proof.prove(at: 3_000)
        #expect(!early)
        #expect(ready)
        #expect(!proof.mayMove, "a local proof alone never moves data")
        proof.peer = true
        #expect(proof.mayMove)
        #expect(proof.failure(at: 6_999) == nil)
        #expect(proof.failure(at: 7_000) == "stalled")
        var quiet = BackendRemoteLinkProof(id: "quiet", opened: 0, fast: false, probeOnly: true)
        quiet.local = true; quiet.peer = true; quiet.lastEcho = 59_999
        #expect(!quiet.mayMove)
        #expect(quiet.failure(at: 60_000) == "quiet retest finished")
        var waiting = BackendRemoteLinkProof(id: "waiting", opened: 0, fast: false, probeOnly: false)
        waiting.lastEcho = 9_999
        #expect(waiting.failure(at: 9_999) == nil)
        #expect(waiting.failure(at: 10_000) == "never proved")
    }

    @Test("local-only wire accepts its boolean marker and only host candidate SDP")
    func localOnlyWireAndCandidates() throws {
        let text = #"{"t":"link.peer","op":"end","localOnly":true}"#
        if case .message(let message) = BackendRemoteProtocol.parseClientMessage(text) { #expect(message["localOnly"].bool == true) }
        else { Issue.record("local-only end was rejected") }
        if case .message = BackendRemoteProtocol.parseClientMessage(#"{"t":"link.peer","op":"end","localOnly":"yes"}"#) {
            Issue.record("non-boolean localOnly was accepted")
        }
        let host = "candidate:1 1 udp 1 192.168.1.2 3000 typ host"
        let remote = "candidate:2 1 udp 1 198.51.100.2 3000 typ srflx"
        #expect(BackendLinkCandidate.host(host))
        #expect(!BackendLinkCandidate.host(remote))
        #expect(BackendLinkCandidate.hostsOnly(in: "a=" + host + "\r\n"))
        #expect(!BackendLinkCandidate.hostsOnly(in: "a=" + host + "\r\na=" + remote + "\r\n"))
    }

    @Test("TLS 443 is additive and only reuses the matching Cloudflare login")
    func wrappedServerCredentialsStayWithTheirProvider() {
        let servers = [BackendPhonePeerServer(urls: ["stun:stun.cloudflare.com:3478"]),
            BackendPhonePeerServer(urls: ["turn:turn.cloudflare.com:3478?transport=udp"], username: "synthetic", credential: "synthetic")]
        let fixed = BackendRemoteLinkProof.withTLS(servers)
        #expect(fixed[0] == servers[0])
        #expect(fixed[1].urls == servers[1].urls + [BackendRemoteLinkProof.turnsURL])
        #expect(fixed[1].username == servers[1].username && fixed[1].credential == servers[1].credential)
        #expect(BackendRemoteLinkProof.withTLS(fixed) == fixed)
        let other = [BackendPhonePeerServer(urls: ["turn:other.invalid:3478"], username: "synthetic", credential: "synthetic")]
        #expect(BackendRemoteLinkProof.withTLS(other) == other)
    }
}

extension LinkPipelineTests {
    final class ProofLog: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        var saved: [String] { lock.withLock { lines } }
    }

    @Test(.timeLimit(.minutes(1))) func wrappedLinkProvesBeforeMovingThenStallsBackWithoutRepeats() async throws {
        let log = ProofLog()
        BackendRemoteRelayClient.setLog { log.add($0) }
        defer { BackendRemoteRelayClient.setLog(nil) }
        let run = try await start(link: (Self.stun, "all"), oneWay: 30, keep: true, routeForTests: "turn", prove: true, proofRoute: "wrapped")
        #expect(await run.client.welcomeCapabilities.contains("link.prove"))
        #expect(!(await run.client.welcomeCapabilities.contains("link.only")))
        var deadline = V.now() + 8_000
        while V.now() < deadline, await run.host.live[run.id]?.link.proof == nil { try await Task.sleep(for: .milliseconds(10)) }
        let pending = try #require(await run.host.live[run.id]?.link)
        #expect(pending.open && !pending.path.hasMoved)
        #expect(await run.host.linkVideo(run.id) == nil, "no unproven video")
        #expect(try await run.echoes(2, label: "during-proof").allSatisfy { $0.isFinite }, "app traffic already works on the socket")
        #expect(try await run.waitMoved() == "wrapped")
        let proof = try #require(await run.host.live[run.id]?.link.proof)
        #expect(proof.local && proof.peer && proof.echoes.count >= 7 && proof.received.count >= 7)
        #expect(await run.client.movedAt! - run.client.proofStarted >= 3_000)
        #expect(try await run.echoes(3, label: "after-proof").allSatisfy { $0.isFinite })
        await run.drained()
        #expect(await pending.path.handedCount == run.client.gotOnLink, "the many probes never enter the replay count")
        // Refuse future offers after the move back so the following assertions describe the relay, not a new link.
        await run.host.stopProofRetries(run.id)
        await run.client.dropEchoes()
        deadline = V.now() + 7_000
        var tick = 0
        while V.now() < deadline, await run.client.backsDone == 0 {
            #expect(try await run.echoes(1, label: "watchdog-app-\(tick)").allSatisfy { $0.isFinite })
            tick += 1
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(await run.client.backsDone == 1)
        #expect(await run.host.live[run.id]?.link.path.currentMode == .wire)
        #expect(!(await run.wireClosed.on))
        for n in 1...8 { await run.client.send(#"{"t":"settings.apply","rid":"a\#(n)","key":"general.restoreSessions","value":"on"}"#) }
        deadline = V.now() + 5_000
        while V.now() < deadline, await run.client.ordered.count < 8 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await run.seen.applied == Array(1...8))
        #expect(await run.client.ordered == Array(1...8), "no loss or repetition after the watchdog's move back")
        #expect(try await run.echoes(2, label: "after-stall").allSatisfy { $0.isFinite })
        #expect(log.saved.contains { $0.hasPrefix("link: up wrapped ") })
        #expect(log.saved.contains { $0.hasPrefix("link: proven wrapped in ") })
        #expect(log.saved.contains { $0.contains("link: stalled wrapped after") && $0.contains("moving back") })
        await run.cleanup()
    }

    @Test(.timeLimit(.minutes(1))) func unprovenFirstLinkKeepsTheSocketAndOffersTheNextRoute() async throws {
        let run = try await start(link: (Self.stun, "all"), oneWay: 30, keep: true, routeForTests: "internet", prove: true)
        await run.client.dropEchoes()
        let deadline = V.now() + 10_000
        while V.now() < deadline, await run.client.offers < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await run.client.offers >= 2)
        #expect(await run.client.backsDone == 0, "never moved, so no link.back")
        #expect(!(await run.wireClosed.on))
        #expect(try await run.echoes(2, label: "never-proved").allSatisfy { $0.isFinite })
        await run.client.send(#"{"t":"link.peer","op":"end","retry":false}"#)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await run.host.live[run.id]?.link.retry == false)
        #expect(await run.host.live[run.id]?.link.token == nil)
        await run.client.send(#"{"t":"link.peer","op":"retry"}"#)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await run.host.live[run.id]?.link.token != nil)
        await run.cleanup()
    }

    @Test(.timeLimit(.minutes(1))) func localNetworkStillMovesAtOpenAndQuietRetestsNeverMove() async throws {
        let local = try await start(link: (Self.stun, "all"), oneWay: 30, keep: true, routeForTests: "host", prove: true)
        #expect(try await local.waitMoved() == "host")
        #expect(await local.client.movedAt! - local.client.proofStarted < 3_000)
        await local.cleanup()
        let quiet = try await start(link: (Self.stun, "all"), oneWay: 30, keep: true, routeForTests: "internet", prove: true, quietProof: true)
        let deadline = V.now() + 9_000
        while V.now() < deadline, await quiet.host.live[quiet.id]?.link.proof?.peer != true { try await Task.sleep(for: .milliseconds(10)) }
        let state = try #require(await quiet.host.live[quiet.id]?.link)
        #expect(state.proof?.local == true && state.proof?.peer == true)
        let phoneMoved = await quiet.client.moved
        #expect(!state.path.hasMoved && !phoneMoved)
        #expect(await quiet.host.linkVideo(quiet.id) == nil)
        #expect(try await quiet.echoes(2, label: "quiet-proof").allSatisfy { $0.isFinite })
        // Advance only the protocol clock to the boundary, representing echoes that continued throughout the minute.
        await quiet.host.completeQuietProofForTest(quiet.id)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await quiet.client.relayLinkFrames.contains { $0.contains("retest-complete") && $0.contains(state.proofID) })
        #expect(await quiet.client.backsDone == 0)
        #expect(!(await quiet.wireClosed.on))
        await quiet.cleanup()
    }

    @Test(.timeLimit(.minutes(1))) func unansweredLocalAttemptKeepsTheSocketAndAcceptsTheNextWrappedOffer() async throws {
        let run = try await start(link: (Self.stun, "all"), oneWay: 30, keep: true, routeForTests: "turn",
                                  prove: true, proofRoute: "wrapped", endFirstLocal: true)
        let deadline = V.now() + 9_000
        while V.now() < deadline, await run.client.offers < 2 { try await Task.sleep(for: .milliseconds(10)) }
        let offers = await run.client.offerFrames
        #expect(offers.count >= 2)
        #expect(offers.first?["proof"].string != offers.last?["proof"].string, "a fresh attempt, not the ended local offer")
        #expect(await run.host.live[run.id]?.link.retry == true, "local failure never exhausts the route ladder")
        #expect(await run.client.backsDone == 0)
        #expect(!(await run.wireClosed.on))
        #expect(try await run.echoes(2, label: "after-local-deadline").allSatisfy { $0.isFinite })
        #expect(try await run.waitMoved() == "wrapped")
        #expect(await run.host.live[run.id]?.link.answered == true)
        await run.cleanup()
    }

    @Test(.timeLimit(.minutes(1))) func localOnlyAnswerMovesOnlyOnHost() async throws {
        let local = try await start(link: ([], "all"), oneWay: 30, keep: true, routeForTests: "host", prove: true, localOnly: true)
        #expect(try await local.waitMoved() == "host")
        #expect(await local.host.live[local.id]?.link.localOnly == true)
        #expect(await local.client.movedAt! - local.client.proofStarted < 3_000)
        await local.cleanup()
        let remote = try await start(link: ([], "all"), oneWay: 30, keep: true, routeForTests: "internet", prove: true, localOnly: true)
        let deadline = V.now() + 5_000
        while V.now() < deadline, await remote.client.offers < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await remote.client.offers >= 2, "non-host opens retire only the attempt")
        #expect(await remote.host.live[remote.id]?.link.path.hasMoved == false)
        #expect(await remote.client.hostMoved == false)
        #expect(!(await remote.wireClosed.on))
        #expect(try await remote.echoes(2, label: "non-local-refused").allSatisfy { $0.isFinite })
        await remote.cleanup()
    }

    @Test(.timeLimit(.minutes(1))) func aMarkerBeforeProofCannotAuthorizeTheMove() async throws {
        let run = try await start(link: (Self.stun, "all"), oneWay: 30, keep: true, routeForTests: "internet", prove: true)
        var deadline = V.now() + 6_000
        while V.now() < deadline, await run.host.live[run.id]?.link.proof == nil { try await Task.sleep(for: .milliseconds(10)) }
        // A marker from an older attempt (or a premature sender) cannot stand in for the current proof/marker.
        await run.client.toHost.carry(BackendRemoteLinkPath.movedText)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await run.host.live[run.id]?.link.pendingMoved == false)
        #expect(await run.host.live[run.id]?.link.clientMoved == false)
        #expect(await run.host.live[run.id]?.link.path.hasMoved == false)
        #expect(try await run.waitMoved() == "direct")
        // waitMoved observes the two senders' moves; the phone's marker still has to cross the relay.
        deadline = V.now() + 1_000
        while V.now() < deadline, await run.host.live[run.id]?.link.clientMoved != true { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await run.host.live[run.id]?.link.clientMoved == true)
        #expect(await run.host.live[run.id]?.link.pendingMoved == false)
        #expect(try await run.echoes(2, label: "early-marker").allSatisfy { $0.isFinite })
        await run.cleanup()
    }

    @Test(.timeLimit(.minutes(1))) func oldPhonesAndProveWithoutKeepGetExactlyTheOldLinkFrames() async throws {
        for claim in [false, true] {
            let run = try await start(link: (Self.stun, "all"), oneWay: 30, routeForTests: "host", prove: claim)
            #expect(try await run.waitMoved() == "host")
            await run.drained()
            #expect(!(await run.client.welcomeCapabilities.contains("link.prove")))
            #expect(await run.client.offerFrames.allSatisfy { $0["proof"].isNullish })
            let offer = try #require(await run.client.offerFrames.first)
            let expected = try BackendRemoteServerMessage(.linkPeer, fields: [
                .init("op", .string("offer")), .init("sdp", offer["sdp"]), .init("fp", offer["fp"]),
                .init("bind", offer["bind"]), .init("ice", offer["ice"]), .init("policy", offer["policy"])])
            #expect(await run.client.relayLinkFrames.contains(try BackendRemoteProtocol.serialize(expected)), "the offer is byte-for-byte the 0.23.0 frame with its current SDP/login")
            #expect(await run.client.relayLinkFrames.filter { !$0.contains("link.peer") } == [BackendRemoteLinkPath.movedText])
            #expect(await run.host.live[run.id]?.link.proof == nil)
            #expect(try await run.echoes(2, label: "old-frames").allSatisfy { $0.isFinite })
            await run.cleanup()
        }
    }
}

extension BackendRemoteHost {
    func stopProofRetries(_ id: UUID) { live[id]?.link.retry = false }
    func completeQuietProofForTest(_ id: UUID) async {
        guard let token = live[id]?.link.token, let proof = live[id]?.link.proof else { return }
        let end = proof.opened + 60_000
        live[id]?.link.proof?.lastEcho = end
        await linkProofTick(id, token, now: end)
    }
}
