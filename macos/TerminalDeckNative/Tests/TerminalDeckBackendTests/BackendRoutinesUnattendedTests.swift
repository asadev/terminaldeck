import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

actor BackendRoutinesConsentProbe {
    private(set) var asked: [BackendDeckCoreSecurityConsentRequest] = [], ran = 0
    func ask(_ request: BackendDeckCoreSecurityConsentRequest) -> Bool { asked.append(request); return true }
    func changed() { ran += 1 }
}
actor BackendRoutinesToolProbeRunner: BackendRoutinesRunner {
    private(set) var seen: BackendDeckCoreSecurityCallResult?, attended: Bool?, calls = 0
    func run(_ request: BackendRoutinesRunRequest) async -> BackendRoutinesRunOutcome {
        calls += 1; attended = request.attended
        guard let caller = request.control else { return .init(ok: false, error: "no tool surface") }
        seen = await caller.call("demo.alter", arguments: .object([]), cancellation: request.cancellation); return .init(ok: true)
    }
}
@MainActor final class BackendRoutinesUnattendedTests: XCTestCase {
    func testRoutineReachesRealGateUnattendedRefusesImmediatelyAndNeverAsks() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("td-routine-unattended-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("routines"), withIntermediateDirectories: true)
        let probe = BackendRoutinesConsentProbe(), runner = BackendRoutinesToolProbeRunner(), actions = BackendRoutinesActionLog(userData: dir)
        let consent = BackendDeckCoreSecurityConsentBroker(timeoutMilliseconds: 60_000, ask: { await probe.ask($0) })
        let log = BackendDeckCoreSecurityActionLog(directory: URL(fileURLWithPath: BackendCopilotPaths(userData: dir.path).log))
        let tool = try BackendMCPTool(id: "demo.alter", wireName: "demo_alter", description: "Stand-in alter operation", inputSchema: .object([.init("type", .string("object")), .init("properties", .object([]))]), tier: .alter)
        let control = try BackendDeckCoreSecurityControl(log: log, consent: consent, policies: [.init(tool: tool, summary: { _, _ in "Change something" }, run: { _, _ in await probe.changed(); return .init(value: .object([.init("changed", .bool(true))])) })])
        let store = BackendRoutinesStore(directory: dir.appendingPathComponent("routines")), runtime = BackendRoutinesRuntimeState(file: dir.appendingPathComponent("routine-state.json"), debounceMs: 0)
        _ = try store.save(.init(id: "sweep", name: "Overnight sweep", triggers: [.manual], folder: "/tmp/td-unattended-project", prompt: "Have a look and fix what you can."))
        let engine = BackendRoutinesEngine(options: .init(store: store, runtime: runtime, log: actions.logger, runner: runner, control: .init(control: control)))
        addTeardownBlock { await engine.stop(); await consent.stop(); try? FileManager.default.removeItem(at: dir) }
        await engine.reload(); let started = await engine.runNow("sweep"); XCTAssertTrue(started.started); await BackendRoutinesTestRig.settle()
        let seen = await runner.seen, attended = await runner.attended, asked = await probe.asked, ran = await probe.ran
        XCTAssertEqual(attended, false); XCTAssertEqual(seen?.ok, false); XCTAssertEqual(seen?.refusal, .unattended); XCTAssertTrue(seen?.error?.contains("cannot be confirmed at all") == true); XCTAssertTrue(seen?.error?.contains("Do not retry") == true); XCTAssertTrue(asked.isEmpty); XCTAssertEqual(ran, 0)
        let view = await engine.get("sweep"); XCTAssertEqual(view?.refusedCalls.count, 1); XCTAssertEqual(view?.refusedCalls.first?.tool, "demo.alter"); XCTAssertEqual(view?.refusedCalls.first?.reason, "not-permitted-unattended"); XCTAssertEqual(view?.refusedCalls.first?.runId, started.runId)
        let restored = BackendRoutinesRuntimeState(file: dir.appendingPathComponent("routine-state.json"), debounceMs: 0); XCTAssertEqual(restored.get("sweep").refusals.first?.tool, "demo.alter")
        let rows = await log.tail(50), gate = rows.first { $0["action"] == .string("tool.demo.alter") }, routine = rows.first { $0["action"] == .string("routine.refused") }
        XCTAssertEqual(gate?["outcome"], .string("refused")); XCTAssertEqual(gate?["confirmed"]["reason"], .string("not-permitted-unattended")); XCTAssertEqual(routine?["routine"], .string("sweep")); XCTAssertTrue(routine?["detail"].string?.contains("demo.alter") == true)
        // Same tool through the attended owner route must ask. This rules out
        // a false positive caused by an unimplemented operation or a dead broker.
        let pending = Task { await control.call(name: "demo.alter", arguments: .object([])) }; await BackendRoutinesTestRig.settle()
        let questions = await probe.asked; XCTAssertEqual(questions.count, 1)
        if let question = questions.first { let answered = await consent.respond(id: question.id, approved: false, by: "window"); XCTAssertTrue(answered) }
        let ordinary = await pending.value; XCTAssertEqual(ordinary.refusal, .declined)
    }
    func testNoFabricatedToolSurfaceAndSharedControlCanBeWiredLater() async throws {
        let rig = try await BackendRoutinesTestRig.make(), runner = BackendRoutinesToolProbeRunner(); addTeardownBlock { await rig.clean() }
        try rig.write("bare"); await rig.engine.setRunner(runner); await rig.engine.reload(); _ = await rig.engine.runNow("bare"); await BackendRoutinesTestRig.settle()
        let seen = await runner.seen; XCTAssertNil(seen)
        let state = await rig.engine.get("bare"); XCTAssertEqual(state?.lastError, "no tool surface")
        XCTAssertEqual(state?.refusedCalls, [])
        let consent = BackendDeckCoreSecurityConsentBroker(ask: { _ in XCTFail("late unattended surface must never ask"); return false })
        let log = BackendDeckCoreSecurityActionLog(directory: rig.directory.appendingPathComponent("copilot-log"))
        let tool = try BackendMCPTool(id: "demo.alter", wireName: "demo_alter", description: "Alter operation", inputSchema: .object([.init("type", .string("object")), .init("properties", .object([]))]), tier: .alter)
        let control = try BackendDeckCoreSecurityControl(log: log, consent: consent, policies: [.init(tool: tool, summary: { _, _ in "Change something" }, run: { _, _ in XCTFail("unattended alter must not run"); return .init(value: .null) })])
        await rig.engine.setControl(.init(control: control)); _ = await rig.engine.runNow("bare"); await BackendRoutinesTestRig.settle()
        let late = await runner.seen, view = await rig.engine.get("bare"); XCTAssertEqual(late?.refusal, .unattended); XCTAssertEqual(view?.refusedCalls.first?.tool, "demo.alter"); await consent.stop()
    }
}
