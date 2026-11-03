#if TD_HOST_ACCOUNT_BRIDGE && TD_HOST_INTEGRATED
import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// U177: real scratch PTYs and lifecycle owners; supplied helper callbacks record quit outcomes.
final class SessionKeeperBoundaryTests: XCTestCase, @unchecked Sendable {
    private func fixture() async throws -> SessionKeeperTestFixture {
        let f = try await SessionKeeperTestFixture.make()
        addTeardownBlock { await f.close() }
        return f
    }
    func testQuitDecisionUsesLiveProcessesAndTheSavedPreference() async throws {
        let f = try await fixture(), quit = f.quit(trace: KeeperTrace())
        guard case .quit = await quit.decision() else { return XCTFail("No live sessions should quit directly") }
        _ = try f.shell()
        try await f.service.authority.setQuitBehavior(.ask)
        guard case .confirm(let asked) = await quit.decision() else { return XCTFail("Ask must confirm live sessions") }
        XCTAssertEqual(asked, 1)
        try await f.service.authority.setQuitBehavior(.keep)
        guard case .background(let kept) = await quit.decision() else { return XCTFail("Keep must retain the session") }
        XCTAssertEqual(kept, 1)
        try await f.service.authority.setQuitBehavior(.stop)
        guard case .quit = await quit.decision() else { return XCTFail("Stop must allow quit") }
    }
    func testKeepingALocalSessionDoesNotCloseHelperResourcesOrItsProcess() async throws {
        let f = try await fixture(), trace = KeeperTrace(), session = try f.shell()
        let pid = try XCTUnwrap(f.manager.pidOf(session.id)), quit = f.quit(trace: trace)
        guard case .background(let live) = await quit.apply(keep: true) else { return XCTFail("Local PTYs require the app to stay resident") }
        XCTAssertEqual(live, 1); XCTAssertEqual(f.manager.pidOf(session.id), pid); XCTAssertTrue(trace.values.isEmpty)
        await quit.foreground()
        XCTAssertEqual(f.manager.pidOf(session.id), pid)
    }
    func testHostedKeepDetachesWithoutClosingAccountResources() async throws {
        let f = try await fixture(), trace = KeeperTrace()
        guard case .detached = await f.quit(trace: trace).apply(keep: true) else { return XCTFail("Helper keep should detach") }
        XCTAssertEqual(trace.values, ["detach"])
    }
    func testRefusedDetachReportsTheReasonAndReopensSessionAdmission() async throws {
        let f = try await fixture(), trace = KeeperTrace()
        guard case .blocked(let message) = await f.quit(trace: trace, detachFails: true).apply(keep: true) else { return XCTFail("A refused detach must stay open") }
        XCTAssertTrue(message.contains("Fixture detach refused")); XCTAssertEqual(trace.values, ["detach"])
        let generation = await f.lifecycle.pauseForHostedKeep()
        XCTAssertNotNil(generation, "A failed keep must undo its own pause")
        await f.lifecycle.resumeAfterBlockedHostedKeep(generation)
    }
    func testStopDrainsProcessesBeforeReturningTheHelpersLeaseResult() async throws {
        let f = try await fixture(), trace = KeeperTrace(), session = try f.shell()
        guard case .stopped(let leases) = await f.quit(trace: trace).apply(keep: false) else { return XCTFail("Stop should drain the owned PTY") }
        XCTAssertEqual(leases, ["fixture": .removed]); XCTAssertNil(f.manager.pidOf(session.id))
        XCTAssertEqual(trace.values, ["deferred", "switches", "close"])
    }
    func testFailedHelperCleanupNeverReportsASuccessfulStop() async throws {
        let f = try await fixture(), trace = KeeperTrace()
        guard case .blocked(let message) = await f.quit(trace: trace, closeFails: true).apply(keep: false) else { return XCTFail("Unconfirmed cleanup must block quit") }
        XCTAssertTrue(message.contains("Fixture cleanup refused")); XCTAssertEqual(trace.values, ["deferred", "switches", "close"])
    }

    private func event(_ session: String?, pid: Int32, provider: String = "claude", conversation: String? = "known", payload: NativeRPCValue = .object([])) -> BackendSessionHookEvent {
        .init(provider: provider, event: "Stop", sessionID: session, cliSessionID: conversation, cwd: nil, toolName: nil,
              receivedAt: Date(), payload: payload, agentEnvironment: nil, peerPID: pid)
    }
    func testHooksRejectWrongProcessProviderConversationAndSidechainBeforePublishing() async throws {
        let f = try await fixture(), hooks = try await f.startHooks(), session = try f.shell(provider: "claude")
        let pid = try XCTUnwrap(f.manager.pidOf(session.id))
        f.manager.setAgentSessionId(session.id, conversationId: "known")
        let rejected = [event(nil, pid: pid), event("gone", pid: pid), event(session.id, pid: pid + 1),
            event(session.id, pid: pid, provider: "codex"), event(session.id, pid: pid, conversation: "other"),
            event(session.id, pid: pid, payload: .object([.init("isSidechain", .bool(true))])),
            event(session.id, pid: pid, payload: .object([.init("is_sidechain", .bool(true))]))]
        for value in rejected { let accepted = await hooks.receive(value); XCTAssertFalse(accepted) }
        let before = await hooks.snapshot(), receipts = await hooks.accepted(after: 0)
        XCTAssertTrue(before.isEmpty); XCTAssertTrue(receipts.isEmpty)
        let accepted = await hooks.receive(event(session.id, pid: pid))
        XCTAssertTrue(accepted)
        let after = await hooks.snapshot()
        XCTAssertEqual(after.count, 1); XCTAssertEqual(after.first?.conversationID, "known"); XCTAssertEqual(after.first?.status, .completed)
    }
    func testHookReceiptHistoryIsBoundedAndExitedSessionsLeaveTheSnapshot() async throws {
        let f = try await fixture(), hooks = try await f.startHooks(), session = try f.shell(provider: "claude")
        let pid = try XCTUnwrap(f.manager.pidOf(session.id))
        for _ in 0..<130 { let accepted = await hooks.receive(event(session.id, pid: pid)); XCTAssertTrue(accepted) }
        let retained = await hooks.accepted(after: 0), latest = await hooks.accepted(after: 128)
        XCTAssertEqual(retained.count, 128); XCTAssertEqual(retained.first?.sequence, 3); XCTAssertEqual(latest.map(\.sequence), [129, 130])
        f.manager.killAll(); _ = await f.manager.drain(); await hooks.processExited(session.id)
        let snapshot = await hooks.snapshot(), accepted = await hooks.receive(event(session.id, pid: pid))
        XCTAssertTrue(snapshot.isEmpty); XCTAssertFalse(accepted)
    }
    func testHookEndpointCannotCloseWithoutProcessDrainAndIsUnavailableAfterStop() async throws {
        let f = try await fixture(), hooks = try await f.startHooks()
        do { try await hooks.stop(afterProcessDrain: false); XCTFail("Unconfirmed drain must retain hooks") } catch {}
        _ = try await hooks.endpoint()
        try await hooks.stop(afterProcessDrain: true)
        do { _ = try await hooks.endpoint(); XCTFail("A stopped endpoint must not be handed out") } catch {}
        let accepted = await hooks.receive(event("gone", pid: 1)), receipts = await hooks.accepted(after: 0)
        XCTAssertFalse(accepted); XCTAssertTrue(receipts.isEmpty)
    }
    func testMixedLeaseRoutingKeepsChatsTasksAndAppBoundLaunchesLocal() {
        let base = BackendCreateSessionInput(cwd: "/scratch", provider: "shell")
        XCTAssertTrue(BackendHOSTMixedLeaseRoute.eligible(base, .init()))
        var chat = base; chat.chat = true
        var task = base; task.taskID = "fixture"
        var project = base; project.taskProject = "fixture"
        var app = base; app.originApp = "fixture"
        var routine = base; routine.originRoutineId = "fixture"
        var run = base; run.originRunId = "fixture"
        for input in [chat, task, project, app, routine, run] { XCTAssertFalse(BackendHOSTMixedLeaseRoute.eligible(input, .init())) }
        XCTAssertFalse(BackendHOSTMixedLeaseRoute.eligible(base, .init(appFenceID: "fixture")))
        XCTAssertFalse(BackendHOSTMixedLeaseRoute.eligible(base, .init(isAppComposed: true)))
    }
    func testAccountFrontendReauthorizesLocalHandlersAndRefusesMutationsBeforeRunningThem() async throws {
        let f = try await fixture(), trace = KeeperTrace(), data = f.root.appendingPathComponent("frontend")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let paths = try BackendHOSTPaths(dataDirectory: data)
        _ = try paths.secret(create: true)
        let server = try BackendHOSTServer(paths: paths, hostVersion: "fixture", manager: f.manager,
            launch: { try f.manager.hostCreate($0) }, snapshot: { f.manager.hostSnapshot($0) }, onIdle: {})
        defer { server.stopListening() }
        let client = try BackendHOSTClient(paths: paths)
        defer { client.detach() }
        let attachment = UUID(), context = NativeRPCContext(caller: .nativeApp, ownerID: "original-owner")
        let authority = BackendHOSTAccountControlAuthority(hostInstance: client.hello.instance, currentAttachment: { attachment },
            authorizeRPC: { actual, _, _ in XCTAssertEqual(actual.ownerID, context.ownerID); trace.add("rpc") },
            authorizeMetadata: { _ in trace.add("metadata") }, authorizeMutation: { _ in throw BackendAccountFailure("Fixture mutation denied") })
        let frontend = BackendHOSTAccountControlFrontend(client: client, authority: authority)
        await frontend.installLocalAccountHandler { channel, _, actual, older in
            XCTAssertEqual(actual.ownerID, context.ownerID); XCTAssertFalse(older); trace.add(channel); return .array([])
        }
        let listed = try await frontend.invoke("profiles:api:list", args: [], context: context)
        XCTAssertEqual(listed, .array([])); XCTAssertEqual(trace.values, ["rpc", "metadata", "profiles:api:list"])
        do { _ = try await frontend.invoke("profiles:api:remove", args: [], context: context); XCTFail("Denied mutation reached the handler") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Fixture mutation denied")) }
        XCTAssertEqual(trace.values, ["rpc", "metadata", "profiles:api:list", "rpc"])
        await frontend.close()
        do { _ = try await frontend.invoke("profiles:api:list", args: [], context: context); XCTFail("Closed frontend ran a handler") } catch {}
        XCTAssertEqual(trace.values.count, 4)
    }
}
#endif
