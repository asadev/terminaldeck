import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// One method per source case; every deadline uses a manually advanced clock.
@Suite("window-asks.test.ts exact port")
struct BackendRemoteServeWindowPortAsks: Sendable {
    @Test func namesDeviceSessionVerbAndNothingElse() async {
        let (desk, wire, _) = fixture()
        await desk.serve(wire)
        let answer = Task { await desk.call(deviceID: "dev-1", sessionID: "sess-1", tool: "browser.read", arguments: "{\"selector\":\"h1\"}") }
        let sent = await wire.next()
        #expect(sent.deviceID == "dev-1")
        #expect(await wire.count == 1)
        #expect(sent.frame.kind == .windowCall)
        #expect(sent.frame.value.fields?.map(\.key).sorted() == ["args", "id", "session", "t", "tool"])
        #expect(sent.frame.value["session"].string == "sess-1")
        #expect(sent.frame.value["tool"].string == "browser.read")
        #expect(await desk.answer(id: sent.frame.value["id"].string!, result: .init(ok: true, body: "{\"title\":\"Example\"}")))
        #expect(await answer.value == .init(ok: true, body: "{\"title\":\"Example\"}"))
        #expect(await desk.waiting == 0)
    }
    @Test func unheardPeerRefusesWithoutAdvancingTime() async {
        let (desk, wire, clock) = fixture(heard: 0)
        await desk.serve(wire)
        let result = await desk.call(deviceID: "dev-1", sessionID: "sess-1", tool: "browser.read", arguments: "{}")
        #expect(!result.ok)
        #expect(result == .refusal("the computer holding that browser window is not connected right now. Say what you would have done on the page and let the person do it."))
        #expect(await desk.waiting == 0)
        #expect(await clock.now == 0)
    }
    @Test func unansweredPeerRefusesWhenFakeClockAdvances1000Milliseconds() async {
        let (desk, wire, clock) = fixture(timeout: 1_000)
        await desk.serve(wire)
        let answer = Task { await desk.call(deviceID: "dev-1", sessionID: "sess-1", tool: "browser.read", arguments: "{}") }
        _ = await wire.next(); await clock.waitForSleepers(1)
        #expect(await desk.waiting == 1)
        await clock.advance(1_000)
        #expect(await answer.value == .refusal("the computer holding that browser window did not answer. It may be asleep or the app may be closed there. Say what you would have done on the page and let the person do it."))
        #expect(await desk.waiting == 0)
    }
    @Test func disconnectSettlesEveryQuestionOnlyForThatPeer() async {
        let (desk, wire, _) = fixture(); await desk.serve(wire)
        let mine = Task { await desk.call(deviceID: "dev-1", sessionID: "s", tool: "browser.read", arguments: "{}") }
        _ = await wire.next()
        let other = Task { await desk.call(deviceID: "dev-2", sessionID: "s", tool: "browser.read", arguments: "{}") }
        _ = await wire.next(); #expect(await desk.waiting == 2)
        await desk.gone("dev-1")
        #expect(await mine.value == .refusal("the computer holding that browser window disconnected before it answered. Say what you would have done on the page and let the person do it."))
        #expect(await desk.waiting == 1)
        await desk.stop(); #expect(await other.value == .refusal("this app is shutting down."))
    }
    @Test func dropsUnknownAnswerWithoutThrowing() async {
        let (desk, wire, _) = fixture(); await desk.serve(wire)
        #expect(await desk.answer(id: "never-asked", result: .init(ok: true, body: "{}")) == false)
    }
    @Test func deadlineFitsBetweenHandoverAndMCP() {
        #expect(BackendRemoteServeWindowAsks.timeoutMilliseconds > 45_000)
        #expect(BackendRemoteServeWindowAsks.timeoutMilliseconds < 60_000)
    }
    @Test func namesTheDeviceThatClaimedTheSession() async {
        let (desk, _, _) = fixture(); await desk.held(deviceID: "mac", sessions: ["sess-1", "sess-2"])
        #expect(await desk.holdersOf("sess-1") == ["mac"])
        #expect(await desk.holdersOf("sess-3") == [])
    }
    @Test func replacingWholeHoldSetDeliversDetaches() async {
        let (desk, _, _) = fixture(); await desk.held(deviceID: "mac", sessions: ["sess-1", "sess-2"])
        await desk.held(deviceID: "mac", sessions: ["sess-2"])
        #expect(await desk.holdersOf("sess-1") == [])
        #expect(await desk.holdersOf("sess-2") == ["mac"])
        await desk.held(deviceID: "mac", sessions: [])
        #expect(await desk.holdersOf("sess-2") == [])
    }
    @Test func namesEveryHolderWithoutChoosingOne() async {
        let (desk, _, _) = fixture(); await desk.held(deviceID: "mac", sessions: ["sess-1"])
        await desk.held(deviceID: "laptop", sessions: ["sess-1"])
        #expect(await desk.holdersOf("sess-1") == ["mac", "laptop"])
    }
    @Test func disconnectKeepsTheClaimWhileTheComputerIsAway() async {
        let (desk, wire, _) = fixture(); await desk.serve(wire)
        await desk.held(deviceID: "mac", sessions: ["sess-1"]); await desk.gone("mac")
        #expect(await desk.holdersOf("sess-1") == ["mac"])
    }
    @Test func reachesChecksCapabilityWithoutSending() async {
        let (desk, wire, _) = fixture(); await desk.serve(wire)
        #expect(await desk.reaches("mac")); #expect(await desk.reaches("phone-1") == false)
        #expect(await desk.reaches("") == false); #expect(await wire.count == 0)
    }
    private func fixture(heard: Int = 1, timeout: Int = 55_000) -> (BackendRemoteServeWindowAsks, BackendRemoteServeWindowPortWire, BackendRemoteServeWindowPortClock) {
        let clock = BackendRemoteServeWindowPortClock(), wire = BackendRemoteServeWindowPortWire(heard: heard)
        let desk = BackendRemoteServeWindowAsks(timeoutMilliseconds: timeout, sleep: { try await clock.sleep($0) })
        return (desk, wire, clock)
    }
}

private actor BackendRemoteServeWindowPortWire: BackendRemoteServeWindowWire {
    struct Sent: Sendable { let deviceID: String, frame: BackendRemoteServerMessage }
    let heard: Int
    private var queued: [Sent] = []
    private var waiter: CheckedContinuation<Sent, Never>?
    private(set) var count = 0
    init(heard: Int) { self.heard = heard }
    func ask(deviceID: String, message: BackendRemoteServerMessage) -> Int {
        count += 1; let sent = Sent(deviceID: deviceID, frame: message)
        if let waiter { self.waiter = nil; waiter.resume(returning: sent) } else { queued.append(sent) }
        return heard
    }
    func reaches(deviceID: String) -> Bool { deviceID == "mac" }
    func next() async -> Sent {
        if !queued.isEmpty { return queued.removeFirst() }
        return await withCheckedContinuation { waiter = $0 }
    }
}
private actor BackendRemoteServeWindowPortClock {
    private struct Pending { let deadline: Int, continuation: CheckedContinuation<Void, Error> }
    private var sleepers: [UUID: Pending] = [:]
    private var armed: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var now = 0
    func sleep(_ milliseconds: Int) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                sleepers[id] = .init(deadline: now + milliseconds, continuation: continuation)
                let ready = armed.filter { sleepers.count >= $0.0 }; armed.removeAll { sleepers.count >= $0.0 }
                ready.forEach { $0.1.resume() }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    func waitForSleepers(_ count: Int) async { if sleepers.count < count { await withCheckedContinuation { armed.append((count, $0)) } } }
    func advance(_ milliseconds: Int) {
        now += milliseconds
        for id in Array(sleepers.keys) where sleepers[id]!.deadline <= now { sleepers.removeValue(forKey: id)?.continuation.resume() }
    }
    private func cancel(_ id: UUID) { sleepers.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError()) }
}
