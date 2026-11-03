// Part 12 (18 Oct): the session keeper never stalls or freezes on one gone session, a burst or a slow start.
#if TD_HOST_ACCOUNT_BRIDGE
import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class HOSTKeeperStallTests: XCTestCase {
    private func accepted(_ sequence: UInt64, session: String?) throws -> BackendHOSTAcceptedHookEvent {
        try .init(sequence: sequence, actual: BackendSessionHookEvent(provider: "claude", event: "Stop", sessionID: session, cliSessionID: nil,
            cwd: nil, toolName: nil, receivedAt: Date(), payload: .object([]), agentEnvironment: nil, peerPID: 42))
    }

    // #44: an event of a session that has gone is passed over (the caller moves on), never thrown as a wall.
    func testGoneSessionEventIsSkippedNotThrown() throws {
        let live: (String) -> Bool = { $0 == "alive" }
        XCTAssertNil(BackendHOSTAcceptedHookEvent.deliverable(try accepted(1, session: "gone"), live: live))
        XCTAssertNil(BackendHOSTAcceptedHookEvent.deliverable(try accepted(2, session: nil), live: live))
        XCTAssertEqual(BackendHOSTAcceptedHookEvent.deliverable(try accepted(3, session: "alive"), live: live)?.sessionID, "alive")
    }

    // #47: a trigger that arrives while a fetch runs is kept and gives exactly one more pass.
    func testTriggerDuringFetchReadsOnceMore() {
        var gate = BackendHOSTHookFetchGate()
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.begin()); XCTAssertFalse(gate.begin())
        XCTAssertTrue(gate.again()); XCTAssertFalse(gate.again())
        gate.end()
        XCTAssertTrue(gate.begin()); XCTAssertFalse(gate.again()); gate.end()
        XCTAssertFalse(gate.inFlight)
    }

    private func scratch() throws -> URL {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().appendingPathComponent("tdk-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    private func launch(_ root: URL) throws -> BackendHOSTProtocol.Launch {
        let input = BackendCreateSessionInput(cwd: root.path, provider: "shell")
        let spawn = BackendSpawnSpec(provider: "shell", command: "/bin/sh", args: ["-c", "read line"], path: "/usr/bin:/bin", env: [:])
        return try .init(id: UUID().uuidString.lowercased(), input: input, spawn: spawn, inheritedEnvironment: ["HOME": root.path])
    }

    #if TD_HOST_PTY_GATE_INTEGRATED
    // #48: while one new session waits in the host's pre-exec check, every other caller of the manager carries on.
    func testSlowPreExecCheckDoesNotFreezeOtherSessions() throws {
        let root = try scratch(), manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        let entered = DispatchSemaphore(value: 0), launched = expectation(description: "the gated session started")
        try manager.setHostBeforeExec { _, _ in entered.signal(); Thread.sleep(forTimeInterval: 1.5) }
        let value = try launch(root)
        DispatchQueue.global().async { do { _ = try manager.hostCreate(value) } catch { XCTFail("\(error)") }; launched.fulfill() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        let started = Date()
        XCTAssertFalse(manager.list().contains { $0.id == value.id })
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "listing waited for the pre-exec check")
        wait(for: [launched], timeout: 10)
        XCTAssertTrue(manager.list().contains { $0.id == value.id && $0.exitCode == nil })
        let drained = expectation(description: "drained")
        manager.killAll(); Task { _ = await manager.drain(); drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }
    #endif

    #if TD_HOST_INTEGRATED
    // #81: a chat start or a Codex fork waits up to 90 s for its reply, and the frame reader accepts that deadline.
    func testSlowRequestsGetTheirOwnReplyDeadline() throws {
        var chat = BackendHOSTProtocol.Request(secret: "s", operation: .create)
        var input = BackendCreateSessionInput(cwd: "/tmp", provider: "claude"); input.chat = true
        chat.launch = try launch(URL(fileURLWithPath: "/tmp")); chat.launch?.input = input
        var fork = BackendHOSTProtocol.Request(secret: "s", operation: .resource); fork.resourceMethod = "chats.provider"
        var other = BackendHOSTProtocol.Request(secret: "s", operation: .resource); other.resourceMethod = "hooks.accepted"
        XCTAssertEqual(BackendHOSTClient.replyDeadlineMilliseconds(chat), 90_000)
        XCTAssertEqual(BackendHOSTClient.replyDeadlineMilliseconds(fork), 90_000)
        XCTAssertEqual(BackendHOSTClient.replyDeadlineMilliseconds(other), 10_000)
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { Darwin.close(pair[0]); Darwin.close(pair[1]) }
        try BackendHOSTSocket.write(["answer": 1], to: pair[0], maximum: 1024)
        XCTAssertEqual(try BackendHOSTSocket.read([String: Int].self, from: pair[1], frameTimeoutMilliseconds: 90_000), ["answer": 1])
    }
    #endif

    // #142: the hook is answered within the bound; context that comes later rides on the session's next hook.
    func testLateHookContextComesWithTheNextHook() async {
        let contexts = BackendSessionHookContextWait(bound: 0.2)
        let started = Date()
        let first = await contexts.answer(session: "s1") { try? await Task.sleep(nanoseconds: 600_000_000); return "late context" }
        XCTAssertNil(first); XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        try? await Task.sleep(nanoseconds: 700_000_000)
        let other = await contexts.answer(session: "s2") { "fresh" }
        XCTAssertEqual(other, "fresh")
        let next = await contexts.answer(session: "s1") { "fresh" }
        XCTAssertEqual(next, "late context\n\nfresh")
        let after = await contexts.answer(session: "s1") { nil }
        XCTAssertNil(after)
    }

    private struct SlowProvider: BackendProviderLaunchResolver {
        let readiness: BackendLaunchReadiness = .ready
        func loginPath() async throws -> String { "/usr/bin:/bin" }
        func resolve(_ input: BackendCreateSessionInput, loginPath: String) async throws -> BackendProviderSpec {
            try await Task.sleep(nanoseconds: 1_500_000_000); throw BackendAccountFailure("No provider in this test.")
        }
    }
    private struct Unconfined: BackendConfinementLaunchResolver {
        let readiness: BackendLaunchReadiness = .ready
        func resolve(command: String, args: [String], input: BackendCreateSessionInput,
            account: BackendAccountLaunch, context: BackendLaunchContext) async throws -> BackendConfinedLaunch { .init(command: command, args: args) }
    }
    private struct NoInstructions: BackendInstructionLaunchResolver {
        let readiness: BackendLaunchReadiness = .ready
        func arguments(_ input: BackendCreateSessionInput, provider: BackendProviderSpec, context: BackendLaunchContext) async throws -> [String] { [] }
    }
    private struct NoProjectTools: BackendProjectMCPSource {
        let readiness: BackendLaunchReadiness = .ready
        func resolve(cwd: String, provider: String, loginPath: String) async throws -> BackendProjectMCPDefinition? { nil }
    }

    // #413: while one start is still preparing (here a slow provider), another session's exit is cleaned up at once.
    func testASlowStartDoesNotHoldBackAnotherSessionsExit() async throws {
        let runtime = try await BackendF4Runtime.wire()
        do {
            let data = runtime.configuration.dataDirectory, manager = BackendPTYManager(inheritedEnvironment: [:]) { _ in }
            let ledger = try await BackendNativeLedger.activate(store: runtime.state)
            let launcher = BackendSessionLauncher(manager: manager, dependencies: try .init(providers: SlowProvider(), accounts: runtime.adapter,
                confinement: Unconfined(), instructions: NoInstructions(), ledger: ledger))
            let endpoint = BackendTestMCPEndpoint(readiness: .ready, description: { nil }, catalogue: { [] },
                register: { _, _ in throw BackendAccountFailure("No session tools in this test.") }, bind: { _, _, _ in }, revoke: { _ in })
            let launch = try BackendCoordinatedSessionLaunch(launcher: launcher, providers: SlowProvider(),
                sessionTools: try BackendSessionToolLeases(endpoint: endpoint, userData: data),
                projectTools: try BackendProjectToolComposition(source: NoProjectTools(), userData: data, inheritedEnvironment: [:]),
                reach: BackendBrowserToolReachAdapter(readiness: .ready, reachesDeviceWindows: { _ in false }, hostHoldsWindows: { false }))
            let slow = Task { try await launch.create(.init(cwd: runtime.root.path, provider: "shell")) }
            try await Task.sleep(nanoseconds: 300_000_000)
            let started = Date()
            await launch.processExited(UUID().uuidString.lowercased())
            XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "an exit waited for another session's start to prepare")
            do { _ = try await slow.value; XCTFail("The slow start has no provider in this test.") } catch {}
            await runtime.dispose(removeRoot: true)
        } catch { await runtime.dispose(removeRoot: true); throw error }
    }
}
#endif
