import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// link.keep (17 Nov 2026, LINK-KEEP-CONTRACT.md; Asad: "Once the connection is built and it is connected already, it
/// should hold that until I close the application"): a direct link that ends hands the connection back to the relay
/// with nothing lost or repeated, and a fresh link follows. Without the capability, today's behaviour.
@Suite("Link keep: a link may end, the connection stays", .serialized)
struct LinkKeepTests {
    /// A link channel that records what it was handed and refuses everything after `accepts`.
    final class Channel: BackendLinkConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var took: [String] = []
        var accepts = Int.max
        func offer() async throws -> String { "" }
        func accept(answer: String) async throws {}
        func add(candidate: String, mid: String?, index: Int32) {}
        func send(_ data: Data, lane: BackendLinkLane) -> Bool {
            lock.withLock {
                guard took.count < accepts else { return false }
                took.append(String(decoding: data, as: UTF8.self)); return true
            }
        }
        func close() {}
        var handed: [String] { lock.withLock { took } }
    }
    actor Relay {
        var sent: [String] = []
        func carry(_ text: String) { sent.append(text) }
    }
    private static func output(_ n: Int) -> String { #"{"t":"output","id":"s1","data":"\#(n)"}"# }

    private func path(outbox: Bool, relay: Relay) -> BackendRemoteLinkPath {
        let path = BackendRemoteLinkPath(relay: { await relay.carry($0) }, outboxOff: { !outbox })
        path.keeps = true
        path.set(.link(clientOnly: true))
        return path
    }

    @Test("frames in flight across the move back are neither lost nor repeated", arguments: [false, true])
    func nothingLostNothingRepeated(outbox: Bool) async throws {
        let relay = Relay(), channel = Channel()
        let path = path(outbox: outbox, relay: relay)
        path.attach(channel, failure: nil)
        try await path.write(BackendRemoteLinkPath.movedText)
        for n in 0..<10 { try await path.write(Self.output(n)) }
        #expect(channel.handed.count == 10)
        // The phone handled the first 6; the link ends; two more are written while the phone's count is on its way.
        _ = path.beginBack()
        #expect(path.isReturning)
        try await path.write(BackendRemoteLinkPath.backText(got: 10))
        for n in 10..<12 { try await path.write(Self.output(n)) }
        try await path.write(#"{"t":"pong"}"#)
        try await path.write(BackendRemoteLinkPath.backDonePrefix + "6")
        try await path.write(Self.output(12))
        let sent = await relay.sent
        #expect(sent.first == BackendRemoteLinkPath.movedText)
        let after = Array(sent.dropFirst())
        #expect(after == [BackendRemoteLinkPath.backText(got: 10), #"{"t":"pong"}"#] + (6..<13).map(Self.output),
                "the link.back and the pong at once; then 6...9 resent once, 10 and 11 that waited, then 12 straight on the relay")
        #expect(!path.isReturning && path.currentMode == .wire)
    }

    @Test("what the link refused, and what its outbox still held, go over the relay after the resent ones")
    func refusedAndWaitingFramesFollow() async throws {
        let relay = Relay(), channel = Channel()
        channel.accepts = 4
        let path = path(outbox: true, relay: relay)
        path.attach(channel, failure: nil)
        try await path.write(BackendRemoteLinkPath.movedText)
        for n in 0..<8 { try await path.write(Self.output(n)) }
        #expect(channel.handed.count == 4)
        _ = path.beginBack()
        try await path.write(BackendRemoteLinkPath.backDonePrefix + "3")
        let resent = await relay.sent.dropFirst()
        #expect(Array(resent) == (3..<8).map(Self.output), "3 resent, 4...7 never handed: each exactly once, in order")
    }

    @Test("a count the Mac no longer holds closes the connection instead of guessing")
    func anImpossibleCountFails() async throws {
        let relay = Relay(), channel = Channel()
        let path = path(outbox: false, relay: relay)
        path.attach(channel, failure: nil)
        try await path.write(BackendRemoteLinkPath.movedText)
        for n in 0..<3 { try await path.write(Self.output(n)) }
        _ = path.beginBack()
        await #expect(throws: (any Error).self) { try await path.write(BackendRemoteLinkPath.backDonePrefix + "5") }
    }

    @Test("link.back parses; without link.keep a path never holds or resends")
    func framesAndTheOffSwitch() async throws {
        guard case .message(let message) = BackendRemoteProtocol.parseClientMessage(#"{"t":"link.back","got":7}"#) else {
            Issue.record("link.back did not parse"); return
        }
        #expect(message["got"].number == 7)
        #expect(BackendRemoteHost.linkKeepCapability == "link.keep")
        #expect(BackendRemoteHost.relayCarries("link.back"))
        let relay = Relay(), channel = Channel()
        let path = BackendRemoteLinkPath(relay: { await relay.carry($0) }, outboxOff: { true })
        path.set(.link(clientOnly: true))
        path.attach(channel, failure: nil)
        try await path.write(BackendRemoteLinkPath.movedText)
        try await path.write(Self.output(0))
        #expect(path.handedCount == 0, "nothing is kept for a resend without link.keep")
        #expect(channel.handed == [Self.output(0)])
    }
}

/// The same, end to end with the real WebRTC engine and the test phone of `LinkPipelineTests`.
extension LinkPipelineTests {
    @Test(.timeLimit(.minutes(1))) func withoutLinkKeepTheWelcomeDoesNotOfferIt() async throws {
        let run = try await start(link: (Self.stun, "all"), oneWay: 30)
        #expect(!(await run.client.welcomeCapabilities.contains(BackendRemoteHost.linkKeepCapability)))
        #expect(try await run.waitMoved() != nil)
        await run.client.killLink()
        let deadline = V.now() + 10_000
        while V.now() < deadline, !(await run.wireClosed.on) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await run.wireClosed.on, "today's rule: the connection closes with its link")
        await run.cleanup()
    }

    @Test(.timeLimit(.minutes(1))) func withLinkKeepALinkEndKeepsTheConnectionAndAFreshLinkFollows() async throws {
        let run = try await start(link: (Self.stun, "all"), oneWay: 30, keep: true)
        #expect(await run.client.welcomeCapabilities.contains(BackendRemoteHost.linkKeepCapability))
        #expect(try await run.waitMoved() != nil)
        let before = try await run.echoes(3, label: "before")
        #expect(before.allSatisfy { $0.isFinite })
        await run.client.killLink()
        // The move back: both link.backs, then the answers come over the relay.
        var deadline = V.now() + 10_000
        while V.now() < deadline, await run.client.backsDone == 0, !(await run.wireClosed.on) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await run.client.backsDone == 1, "the host answered the move back")
        #expect(!(await run.wireClosed.on), "the connection stayed")
        let between = try await run.echoes(2, label: "relay")
        #expect(between.allSatisfy { $0.isFinite }, "requests are answered over the relay meanwhile")
        // A fresh offer follows (after about 1 s) and the connection moves onto it.
        deadline = V.now() + 15_000
        while V.now() < deadline {
            let offers = await run.client.offers, moved = await run.client.moved
            if offers >= 2 && moved { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await run.client.offers >= 2, "a fresh link was offered")
        #expect(await run.client.moved, "and moved onto")
        let after = try await run.echoes(3, label: "after")
        #expect(after.allSatisfy { $0.isFinite })
        #expect(!(await run.wireClosed.on))
        await run.cleanup()
    }

    /// Cross-check 17 Nov item 6: both sides send `link.back` at once (the phone's arrives while the host's is still
    /// leaving). The move back finishes on the phone's, and no deadline is left behind to close a second move back
    /// that is under way 10 s later.
    @Test(.timeLimit(.minutes(1))) func aCrossingMoveBackLeavesNoDeadlineForTheNextOne() async throws {
        let run = try await start(link: (Self.stun, "all"), oneWay: 30, keep: true, slowBackMs: 300)
        #expect(try await run.waitMoved() != nil)
        func cross() async throws {
            let token = try #require(await run.host.live[run.id]?.link.token)
            async let phone: Void = run.client.moveBack()
            await run.host.linkEnded(run.id, token, why: "test crossing", tell: true)
            await phone
        }
        try await cross()
        let first = V.now()
        var deadline = V.now() + 5_000
        while V.now() < deadline, await run.client.backsDone < 1 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await run.client.backsDone == 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await run.host.live[run.id]?.link.backWaiting == false)
        #expect(await run.host.live[run.id]?.link.backDeadline == nil, "the crossing left a 10 s deadline running")
        // The fresh link, then a second move back that is still waiting when a left-over deadline would fire.
        deadline = V.now() + 8_000
        while V.now() < deadline {
            if await run.client.moved, await run.host.live[run.id]?.link.open == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await run.client.moved, "moved onto the fresh link")
        let wait = first + 9_900 - V.now()
        if wait > 0 { try await Task.sleep(for: .milliseconds(Int(wait))) }
        try await cross()
        deadline = V.now() + 5_000
        while V.now() < deadline, await run.client.backsDone < 2, !(await run.wireClosed.on) { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(500))
        #expect(await run.client.backsDone == 2, "the second move back finished")
        #expect(!(await run.wireClosed.on), "the second move back was not cut short")
        await run.cleanup()
    }

    /// Cross-check item 7: a phone's `link.back` kept for a move back that is not made (a fresh link after a move back,
    /// never moved onto) is not left behind for a later link; the connection stays on the relay.
    @Test(.timeLimit(.minutes(1))) func aClientBackForALinkNeverMovedOntoIsNotKept() async throws {
        // 400 ms each way: the fresh offer's answer cannot reach the host for 800 ms, so the phone's link.back is first.
        let run = try await start(link: (Self.stun, "all"), oneWay: 400, keep: true)
        #expect(try await run.waitMoved(20_000) != nil)
        await run.client.moveBack()
        var deadline = V.now() + 10_000
        while V.now() < deadline, await run.client.backsDone < 1 { try await Task.sleep(for: .milliseconds(20)) }
        deadline = V.now() + 10_000
        while V.now() < deadline {
            if await run.host.live[run.id]?.link.relinked == true, await run.host.live[run.id]?.link.token != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await run.host.live[run.id]?.link.token != nil, "a fresh link is under way")
        await run.client.toHost.carry(#"{"t":"link.back","got":0}"#)
        deadline = V.now() + 3_000
        while V.now() < deadline, await run.host.live[run.id]?.link.token != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await run.host.live[run.id]?.link.token == nil, "the phone's link.back ended the fresh link")
        let stayed = await run.host.live[run.id] != nil, closed = await run.wireClosed.on
        #expect(stayed && !closed, "the connection stayed")
        #expect(await run.host.live[run.id]?.link.clientBack == nil, "its count was not left for the next link")
        await run.cleanup()
    }

    /// The late `link.moved` (cross-check, "only a live run"): a marker that comes before the phone's answer to the
    /// current offer belongs to an ended link and does not mark the current one as moved.
    @Test(.timeLimit(.minutes(1))) func aMarkerBeforeTheAnswerIsAnEndedLinks() async throws {
        // 400 ms each way: the phone's answer cannot reach the host for 800 ms after the welcome.
        let run = try await start(link: (Self.stun, "all"), oneWay: 400, only: false, keep: true)
        #expect(await run.host.live[run.id]?.link.token != nil)
        #expect(await run.host.live[run.id]?.link.answered == false)
        _ = await run.host.take(run.id, text: BackendRemoteLinkPath.movedText)
        #expect(await run.host.live[run.id]?.link.clientMoved == false, "a marker before the answer is ignored")
        await run.cleanup()
    }
}

