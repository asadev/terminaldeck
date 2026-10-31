import Foundation
import Darwin
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Holds every app-side tool call until released, ignoring cancellation, so a
/// handler that is slow to unwind can be reproduced.
private final class RelayGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var open = false
    private(set) var entered = 0
    func pass() async {
        await withCheckedContinuation { continuation in
            let now = lock.withLock { () -> Bool in entered += 1; if open { return true }; waiting.append(continuation); return false }
            if now { continuation.resume() }
        }
    }
    func release() { let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in open = true; defer { waiting = [] }; return waiting }; all.forEach { $0.resume() } }
    var count: Int { lock.withLock { entered } }
}

/// 18 Oct (#109, #162): a full call table means a busy app. Only that call is refused, with
/// words that say so; the relay stays attached for every other session.
final class HOSTAppRelayBusyTests: XCTestCase, @unchecked Sendable {
    private struct Fixture { let relay: BackendHOSTAppRelayServer; let app: BackendHOSTAppRelayClient; let gate: RelayGate; let tool: BackendMCPTool }
    private func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().appendingPathComponent("tdh-busy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = try BackendHOSTPaths(dataDirectory: root); _ = try paths.secret(create: true)
        let hello = BackendHOSTProtocol.Hello(protocolVersion: BackendHOSTProtocol.version, hostVersion: "busy-fixture", hostPID: getpid(), instance: UUID())
        let relay = try BackendHOSTAppRelayServer(paths: paths, host: hello), gate = RelayGate()
        addTeardownBlock { relay.stop() }
        let app = try BackendHOSTAppRelayClient(paths: paths, host: hello, handler: { _ in await gate.pass(); return .value(.object([])) })
        addTeardownBlock { gate.release(); app.detach() }
        let tool = try BackendMCPTool(id: "fixture.read", wireName: "fixture_read", description: "Scratch busy read.",
            inputSchema: .object([.init("type", .string("object")), .init("properties", .object([]))]), tier: .read)
        return .init(relay: relay, app: app, gate: gate, tool: tool)
    }
    private func call(_ f: Fixture, _ scope: BackendMCPCancellation = BackendMCPCancellation()) async -> BackendMCPToolReply {
        let context = BackendMCPCallContext(sessionID: "scratch-session", machineID: "", projectRoot: nil, attended: false,
            allowedTools: ["fixture.read"], allowedTiers: [.read], cancellation: scope)
        return await f.relay.invoke(tool: f.tool, context: context, taskProject: nil, arguments: .object([]))
    }
    private func until(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), what)
    }
    private func text(_ reply: BackendMCPToolReply) -> String? { reply.content.first?["text"].string }

    func testFullHostTableSaysBusyNotDisconnected() async throws {
        let f = try fixture(), limit = BackendHOSTAppRelayProtocol.maximumCalls
        let running = (0..<limit).map { _ in Task { await self.call(f) } }
        try await until("every call reached the app") { f.gate.count == limit && f.relay.projection().pendingCalls == limit }
        let refused = await call(f)
        XCTAssertTrue(refused.isError)
        XCTAssertEqual(text(refused), BackendHOSTAppRelayProtocol.busy)
        XCTAssertTrue(f.relay.projection().attached)
        f.gate.release()
        for task in running { let reply = await task.value; XCTAssertFalse(reply.isError, "\(reply)") }
        let next = await call(f)
        XCTAssertFalse(next.isError, "\(next)")
    }

    /// U108 #152: a private host control the app refuses comes back with the app's own reason.
    func testControlRefusalCarriesTheAppsOwnReason() async throws {
        let f = try fixture()
        f.app.setControlHandler { _ in throw NativeRPCError(code: "refused", message: "That account no longer exists.") }
        try await until("the app attached") { f.relay.projection().attached }
        do {
            _ = try await f.relay.invokeControl(operation: .accountAuthorize, arguments: .object([]))
            XCTFail("A refused control succeeded")
        } catch { XCTAssertEqual(error.localizedDescription, "That account no longer exists.") }
        XCTAssertNil(BackendHOSTAppRelayClient.refusal(CancellationError()))
    }

    func testCancelledCallsStillUnwindingRefuseOneCallAndKeepTheRelay() async throws {
        let f = try fixture(), limit = BackendHOSTAppRelayProtocol.maximumCalls
        let scopes = (0..<limit).map { _ in BackendMCPCancellation() }
        let running = scopes.map { scope in Task { await self.call(f, scope) } }
        try await until("every call reached the app") { f.gate.count == limit }
        scopes.forEach { $0.cancel() }
        for task in running { _ = await task.value }
        XCTAssertEqual(f.relay.projection().pendingCalls, 0, "The host forgets cancelled calls at once")
        // The app still holds all of them (their handlers have not unwound): the next call is refused alone.
        let refused = await call(f)
        XCTAssertTrue(refused.isError)
        XCTAssertEqual(text(refused), BackendHOSTAppRelayProtocol.busy)
        XCTAssertTrue(f.app.isAttached, "A full app table must not tear down the relay")
        XCTAssertTrue(f.relay.projection().attached)
        f.gate.release()
        var answered = false
        for _ in 0..<500 where !answered { answered = !(await call(f).isError); if !answered { try await Task.sleep(nanoseconds: 10_000_000) } }
        XCTAssertTrue(answered, "Once the handlers unwind the same relay answers again")
        XCTAssertTrue(f.app.isAttached)
    }
}
