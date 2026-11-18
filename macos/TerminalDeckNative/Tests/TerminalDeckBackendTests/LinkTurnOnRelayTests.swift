import Foundation
import Testing
import TerminalDeckNativeCore
import TerminalDeckPeer
@testable import TerminalDeckBackend

/// The real loopback link exercises the phone's dc2 receive terms; only the host's selected-route decision is forced.
@Suite("TURN phones keep control on the relay socket", .serialized)
struct LinkTurnOnRelayTests {
    typealias Pipeline = LinkPipelineTests
    typealias V = VideoPipelineTests

    @Test(.timeLimit(.minutes(1))) func aTurnPhoneKeepsControlOnRelayAndVideoOnLink() async throws {
        let run = try await Pipeline().start(link: (Pipeline.stun, "all"), oneWay: 30, routeForTests: "turn")
        #expect(!(await run.client.welcomeCapabilities.contains(BackendRemoteHost.linkOnlyCapability)))
        #expect(await run.client.welcomeCapabilities.contains(BackendRemoteHost.linkCapability))
        var deadline = V.now() + 12_000
        while V.now() < deadline {
            if await run.host.live[run.id]?.link.open == true, await run.client.moved { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let state = try #require(await run.host.live[run.id]?.link)
        #expect(state.open && state.relayFirst && state.clientOnly && state.keptOnRelay)
        #expect(state.path.currentMode == .wire && !state.path.hasMoved)
        #expect(await run.host.linkRoute(run.id) == nil)
        #expect(!(await run.client.hostOnly))
        #expect(BackendRemoteHost.pushMayGo(link: state, now: state.openedAt), "unasked lists do not wait for a move")
        await run.drained()
        let relayBefore = await run.client.viaRelay, linkBefore = await run.client.viaLink
        let times = try await run.echoes(4, label: "turn-relay")
        #expect(times.allSatisfy { $0.isFinite })
        #expect(await run.client.viaRelay >= relayBefore + 4, "requests on the link are answered over the relay")
        #expect(await run.client.viaLink == linkBefore && linkBefore == 0, "no td.ctl starts the phone's hold timer")
        #expect(!(await run.client.hostMoved), "the Mac sent no link.moved")
        #expect(await run.client.held.isEmpty)
        #expect(await run.host.linkVideo(run.id) != nil)
        #expect(await run.host.sendDirect(run.id, data: Data("{}".utf8), lane: .moving) == true)
        #expect(await run.host.sendDirect(run.id, data: Data("{}".utf8), lane: .still) == true)
        deadline = V.now() + 5_000
        while V.now() < deadline {
            let moving = await run.client.lanes[PeerLane.moving.rawValue, default: 0]
            let still = await run.client.lanes[PeerLane.still.rawValue, default: 0]
            if moving > 0 && still > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await run.client.lanes[PeerLane.moving.rawValue, default: 0] > 0)
        #expect(await run.client.lanes[PeerLane.still.rawValue, default: 0] > 0)
        #expect(!(await run.wireClosed.on))
        #expect(await run.host.live[run.id] != nil)
        await run.cleanup()
        #expect(state.path.direct(Data(), lane: .moving) == nil && state.path.video() == nil, "detach clears video permission")
        // Attach and move-back also clear the video-only permission independently of detach.
        let channel = LinkKeepTests.Channel()
        state.path.videoOnLink()
        state.path.attach(channel, failure: nil)
        #expect(state.path.video() == nil, "attach clears video permission")
        state.path.videoOnLink()
        #expect(state.path.video() != nil)
        _ = state.path.beginBack()
        #expect(state.path.video() == nil, "move-back clears video permission")
    }

    @Test(.timeLimit(.minutes(1))) func aDirectPhoneMovesAndSurvivesRelayClose() async throws {
        let run = try await Pipeline().start(link: (Pipeline.stun, "all"), oneWay: 30, routeForTests: "host")
        #expect(!(await run.client.welcomeCapabilities.contains(BackendRemoteHost.linkOnlyCapability)))
        #expect(try await run.waitMoved() == "host")
        await run.drained()
        #expect(await run.client.hostMoved)
        #expect(await run.host.live[run.id]?.link.keptOnRelay == false)
        let before = await run.client.viaLink
        #expect(try await run.echoes(3, label: "direct").allSatisfy { $0.isFinite })
        #expect(await run.client.viaLink >= before + 3)
        await run.host.closed(run.id)
        let state = try #require(await run.host.live[run.id]?.link)
        #expect(state.path.relayIsGone, "the existing relay-close survival rule still applies")
        await run.drained()
        let relayBefore = await run.client.viaRelay
        try await state.path.write(#"{"t":"link.peer","op":"cand"}"#)
        await run.drained()
        #expect(await run.client.viaRelay == relayBefore, "a late candidate is dropped after the relay closes")
        #expect(try await run.echoes(2, label: "after-relay-close").allSatisfy { $0.isFinite })
        #expect(!(await run.wireClosed.on))
        await run.cleanup()
    }

    @Test(.timeLimit(.minutes(1))) func disablingTheRuleKeepsLinkOnlyTermsOnTurn() async throws {
        let run = try await Pipeline().start(link: (Pipeline.stun, "all"), oneWay: 30, turnOnRelay: false, routeForTests: "turn")
        #expect(await run.client.welcomeCapabilities.contains(BackendRemoteHost.linkOnlyCapability))
        #expect(try await run.waitMoved() == "turn")
        await run.drained()
        #expect(await run.client.hostMoved)
        #expect(await run.client.hostOnly)
        #expect(await run.host.live[run.id]?.link.relayFirst == false)
        #expect(await run.host.live[run.id]?.link.keptOnRelay == false)
        let before = await run.client.viaLink
        #expect(try await run.echoes(3, label: "rule-off").allSatisfy { $0.isFinite })
        #expect(await run.client.viaLink >= before + 3)
        await run.cleanup()
    }

    @Test(.timeLimit(.minutes(1))) func anOlderPhoneStillMovesOnTurn() async throws {
        let run = try await Pipeline().start(link: (Pipeline.stun, "all"), oneWay: 30, only: false, routeForTests: "turn")
        #expect(!(await run.client.welcomeCapabilities.contains(BackendRemoteHost.linkOnlyCapability)))
        #expect(try await run.waitMoved() == "turn")
        await run.drained()
        #expect(await run.client.hostMoved)
        #expect(await run.host.live[run.id]?.link.relayFirst == false)
        #expect(await run.host.live[run.id]?.link.keptOnRelay == false)
        let before = await run.client.viaLink
        #expect(try await run.echoes(3, label: "old-phone").allSatisfy { $0.isFinite })
        #expect(await run.client.viaLink >= before + 3)
        await run.cleanup()
    }
}

extension BackendRemoteHost {
    /// Test-target-only access to plain stored properties; no production setting, environment or IPC door.
    func configureTurnOnRelay(_ enabled: Bool, route: String?) {
        linkTurnOnRelay = enabled
        linkRouteForTests = route
    }
}
