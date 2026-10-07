import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendRoutinesTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = 1_787_000_000_000.0
    private var timers: [UUID: (Double, @Sendable () async -> Void)] = [:]
    var now: Double { lock.withLock { instant } }
    var pending: Int { lock.withLock { timers.count } }
    func jump(_ ms: Double) { lock.withLock { instant += ms } }
    func set(_ callback: @escaping @Sendable () async -> Void, _ ms: Double) -> BackendRoutinesTimer {
        let id = UUID(); lock.withLock { timers[id] = (instant + max(0, ms), callback) }
        return BackendRoutinesTimer { [weak self] in self?.remove(id) }
    }
    private func remove(_ id: UUID) { lock.withLock { timers[id] = nil } }
    func advance(_ ms: Double) async {
        let target = now + ms
        for _ in 0..<1000 {
            let callback: (@Sendable () async -> Void)? = lock.withLock {
                guard let due = timers.filter({ $0.value.0 <= target }).min(by: { $0.value.0 < $1.value.0 }) else { return nil }
                timers[due.key] = nil; instant = due.value.0; return due.value.1
            }
            guard let callback else { break }; await callback(); await BackendRoutinesTestRig.settle()
        }
        lock.withLock { instant = target }; await BackendRoutinesTestRig.settle()
    }
}
actor BackendRoutinesTestRunner: BackendRoutinesRunner {
    nonisolated let cancellable = true
    private(set) var calls: [BackendRoutinesRunRequest] = []
    private var gated = false, outcome = BackendRoutinesRunOutcome(ok: true)
    private var waiting: [CheckedContinuation<BackendRoutinesRunOutcome, Never>] = []
    func configure(gated: Bool = false, outcome: BackendRoutinesRunOutcome = .init(ok: true)) { self.gated = gated; self.outcome = outcome }
    func run(_ request: BackendRoutinesRunRequest) async -> BackendRoutinesRunOutcome {
        calls.append(request); guard gated else { return outcome }
        return await withCheckedContinuation { waiting.append($0) }
    }
    func finish(_ result: BackendRoutinesRunOutcome = .init(ok: true)) { if !waiting.isEmpty { waiting.removeFirst().resume(returning: result) } }
}
actor BackendRoutinesChainTestRunner: BackendRoutinesRunner {
    private(set) var calls: [BackendRoutinesRunRequest] = []
    func run(_ request: BackendRoutinesRunRequest) -> BackendRoutinesRunOutcome { calls.append(request); return .init(ok: true, sessionIds: ["child-" + request.runId]) }
}
final class BackendRoutinesTestActions: BackendRoutinesActionAppending, @unchecked Sendable {
    private let lock = NSLock(); private var values: [NativeRPCValue] = []
    var rows: [NativeRPCValue] { lock.withLock { values } }
    func appendRoutineAction(_ value: NativeRPCValue) { lock.withLock { values.append(value) } }
}
struct BackendRoutinesTestRig: Sendable {
    let directory: URL, store: BackendRoutinesStore, runtime: BackendRoutinesRuntimeState, engine: BackendRoutinesEngine
    let clock: BackendRoutinesTestClock, runner: BackendRoutinesTestRunner, actions: BackendRoutinesTestActions
    static let project = "/tmp/td-routines-project"
    static func make(runnerAvailable: Bool = true, control: BackendRoutinesToolCaller? = nil, global: Double = 60, unwired: Bool = false,
                     allow: @escaping @Sendable (String) -> String? = { _ in nil }) async throws -> Self {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("td-routines-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("routines"), withIntermediateDirectories: true)
        let clock = BackendRoutinesTestClock(), runner = BackendRoutinesTestRunner(), actions = BackendRoutinesTestActions()
        let store = BackendRoutinesStore(directory: dir.appendingPathComponent("routines")), runtime = BackendRoutinesRuntimeState(file: dir.appendingPathComponent("state.json"), now: { clock.now }, debounceMs: 0)
        let engine = BackendRoutinesEngine(options: .init(store: store, runtime: runtime, log: BackendRoutinesLogging.logger(using: actions), runner: runnerAvailable ? runner : nil, control: control, allowFolder: allow, globalMaxRunsPerHour: { global }, now: { clock.now }, setTimer: { clock.set($0, $1) }, watchFiles: { _, _ in {} }, watchGit: { _, _ in {} }))
        if !unwired { for kind in ["session-finished", "session-failed", "session-idle", "alert", "file-change", "git-change"] { await engine.markSource(kind, subscribed: true) } }
        return .init(directory: dir, store: store, runtime: runtime, engine: engine, clock: clock, runner: runner, actions: actions)
    }
    func write(_ id: String, when: String = "manual", extra: String = "", folder: String = project) throws {
        let text = "# A routine\n\nwhen: \(when)\nin: \(folder)\n\(extra)\n---\n\nDo the thing.\n"
        try text.write(to: directory.appendingPathComponent("routines/" + id + ".md"), atomically: true, encoding: .utf8)
    }
    func clean() async { await engine.stop(); try? FileManager.default.removeItem(at: directory) }
    /// Lets work hopping between actors and the cooperative pool finish: yields
    /// alone only reschedule the caller, so also give real time (the clock is
    /// fake, so this never delays a timer, only the other executors).
    static func settle() async { for _ in 0..<40 { await Task.yield() }; try? await Task.sleep(nanoseconds: 4_000_000); for _ in 0..<10 { await Task.yield() } }
}

@MainActor final class BackendRoutinesExecutionTests: XCTestCase {
    func testFinishFailureAndFolderScope() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }
        try rig.write("finish", when: "session-finished"); try rig.write("fail", when: "session-failed"); await rig.engine.reload()
        await rig.engine.noteSessionStarted(id: "outside", cwd: "/tmp/other"); await rig.engine.noteSessionExit(sessionId: "outside", exitCode: 0)
        await rig.engine.noteSessionStarted(id: "good", cwd: BackendRoutinesTestRig.project); await rig.engine.noteSessionExit(sessionId: "good", exitCode: 0)
        await rig.engine.noteSessionStarted(id: "bad", cwd: BackendRoutinesTestRig.project); await rig.engine.noteSessionExit(sessionId: "bad", exitCode: 1)
        await BackendRoutinesTestRig.settle(); let calls = await rig.runner.calls
        XCTAssertEqual(Set(calls.map { $0.routine.id }), ["finish", "fail"]); XCTAssertTrue(calls.allSatisfy { !$0.attended })
    }
    func testIdleIsEventDrivenAndCancelledByOutputOrInput() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }
        try rig.write("idle", when: "session-idle 15m"); await rig.engine.reload(); await rig.engine.noteSessionStarted(id: "s", cwd: BackendRoutinesTestRig.project)
        await rig.engine.noteSessionStatus(sessionId: "s", status: .idle); await rig.clock.advance(14 * 60_000)
        await rig.engine.noteSessionStatus(sessionId: "s", status: .working); await rig.clock.advance(60 * 60_000)
        await rig.engine.noteSessionStatus(sessionId: "s", status: .input); await rig.clock.advance(60 * 60_000)
        let before = await rig.runner.calls.count; XCTAssertEqual(before, 0)
        await rig.engine.noteSessionStatus(sessionId: "s", status: .waiting); await rig.clock.advance(15 * 60_000)
        let after = await rig.runner.calls; XCTAssertEqual(after.count, 1); XCTAssertEqual(after.first?.cause, .sessionIdle(sessionId: "s", afterMs: 900_000))
    }
    func testStableAlertsFireOnlyWhenNewAndMatching() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }
        try rig.write("alerts", when: "alert critical", extra: "quiet-for: 1s"); await rig.engine.reload()
        func report(_ id: String, severity: String) -> NativeRPCValue { .object([.init("projectPath", .string(BackendRoutinesTestRig.project)), .init("alerts", .array([.object([.init("id", .string(id)), .init("kind", .string("session-blocked")), .init("severity", .string(severity)), .init("title", .string(id))])]))]) }
        await rig.engine.noteAlertReport(report("one", severity: "critical")); await BackendRoutinesTestRig.settle()
        await rig.engine.noteAlertReport(report("one", severity: "critical")); await rig.clock.advance(2000)
        await rig.engine.noteAlertReport(report("two", severity: "warning")); await BackendRoutinesTestRig.settle()
        let calls = await rig.runner.calls.count; XCTAssertEqual(calls, 1)
    }
    func testOriginAtSpawnAndOutcomeBackstopPreventSelfLoop() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }
        try rig.write("spawner", when: "session-finished", extra: "quiet-for: 1s"); await rig.engine.reload()
        await rig.runner.configure(outcome: .init(ok: true, sessionIds: ["backstop"]))
        await rig.engine.noteSessionStarted(id: "root", cwd: BackendRoutinesTestRig.project); await rig.engine.noteSessionExit(sessionId: "root", exitCode: 0); await BackendRoutinesTestRig.settle()
        let run = await rig.runner.calls.first; XCTAssertNotNil(run)
        await rig.engine.noteSessionStarted(id: "labelled", cwd: BackendRoutinesTestRig.project, originRoutineId: "spawner", originRunId: run?.runId)
        await rig.engine.noteSessionExit(sessionId: "labelled", exitCode: 0); await rig.engine.noteSessionExit(sessionId: "backstop", exitCode: 0); await rig.clock.advance(2000)
        let calls = await rig.runner.calls.count; XCTAssertEqual(calls, 1); XCTAssertEqual(rig.actions.rows.filter { $0["action"] == .string("routine.skip") }.count, 2)
    }
    func testQueueIsOneDeepAndQuietPeriodCoalescesBursts() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }
        try rig.write("slow", when: "session-finished", extra: "quiet-for: 30s"); await rig.engine.reload(); await rig.runner.configure(gated: true)
        for n in 0..<4 { await rig.engine.noteSessionStarted(id: "s\(n)", cwd: BackendRoutinesTestRig.project); await rig.engine.noteSessionExit(sessionId: "s\(n)", exitCode: 0) }
        await BackendRoutinesTestRig.settle(); let first = await rig.runner.calls.count, queued = await rig.engine.get("slow")?.pending
        XCTAssertEqual(first, 1); XCTAssertEqual(queued, true)
        await rig.runner.configure(); await rig.runner.finish(); await BackendRoutinesTestRig.settle(); await rig.clock.advance(31_000)
        let final = await rig.runner.calls.count; XCTAssertEqual(final, 2)
    }
    func testSkipAndCancelNeverRunTwoAtOnce() async throws {
        for policy in ["skip", "cancel"] {
            let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }
            try rig.write("slow", extra: "overlap: \(policy)\nquiet-for: 1s"); await rig.engine.reload(); await rig.runner.configure(gated: true)
            _ = await rig.engine.runNow("slow"); await BackendRoutinesTestRig.settle(); _ = await rig.engine.runNow("slow"); await BackendRoutinesTestRig.settle()
            let calls = await rig.runner.calls, view = await rig.engine.get("slow")
            XCTAssertEqual(calls.count, 1); XCTAssertEqual(view?.pending, policy == "cancel"); XCTAssertEqual(calls.first?.cancellation.isCancelled, policy == "cancel")
            await rig.runner.configure(); await rig.runner.finish(); await BackendRoutinesTestRig.settle(); await rig.clock.advance(2000)
            let final = await rig.runner.calls.count; XCTAssertEqual(final, policy == "cancel" ? 2 : 1)
        }
    }
    func testReloadRetainsCancellationGraceAndRunningCompletion() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }
        try rig.write("latest", extra: "overlap: cancel\nquiet-for: 1s"); await rig.engine.reload(); await rig.runner.configure(gated: true)
        _ = await rig.engine.runNow("latest"); await BackendRoutinesTestRig.settle(); _ = await rig.engine.runNow("latest"); rig.clock.jump(5_000)
        try rig.write("latest", extra: "overlap: cancel\nquiet-for: 1s"); await rig.engine.reload(); await rig.clock.advance(6_000)
        let pending = await rig.engine.get("latest")?.pending; XCTAssertEqual(pending, false)
        await rig.runner.configure(); await rig.runner.finish(); await BackendRoutinesTestRig.settle()
        let running = await rig.engine.get("latest")?.running, calls = await rig.runner.calls.count; XCTAssertEqual(running, false); XCTAssertEqual(calls, 1)
    }
    func testPersistedBudgetsApplyToManualAndRecoverByWallClock() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }
        try rig.write("chatty", extra: "max-runs-per-hour: 2\nquiet-for: 1s"); await rig.engine.reload()
        _ = await rig.engine.runNow("chatty"); await rig.clock.advance(2000); _ = await rig.engine.runNow("chatty"); await rig.clock.advance(2000)
        let denied = await rig.engine.runNow("chatty", by: "copilot"); XCTAssertFalse(denied.started); XCTAssertTrue(denied.reason?.contains("ceiling of 2") == true)
        let restored = BackendRoutinesRuntimeState(file: rig.directory.appendingPathComponent("state.json"), now: { rig.clock.now }, debounceMs: 0)
        XCTAssertEqual(restored.get("chatty").runs.count, 2)
        await rig.clock.advance(61 * 60_000); let state = await rig.engine.get("chatty")?.state; XCTAssertEqual(state, "armed")
    }
    func testAppBudgetIsSharedAndSupportsFractionalSetting() async throws {
        let rig = try await BackendRoutinesTestRig.make(global: 1.5); addTeardownBlock { await rig.clean() }
        try rig.write("a"); try rig.write("b"); await rig.engine.reload()
        _ = await rig.engine.runNow("a"); _ = await rig.engine.runNow("b"); let refused = await rig.engine.runNow("a")
        XCTAssertFalse(refused.started); XCTAssertTrue(refused.reason?.contains("this app's ceiling") == true)
    }
    func testFailurePausePersistsAndResumeDoesNotRewriteInstruction() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }
        try rig.write("doomed", extra: "quiet-for: 1s"); await rig.engine.reload(); await rig.runner.configure(outcome: .init(ok: false, error: "cannot deliver"))
        let file = rig.directory.appendingPathComponent("routines/doomed.md"), before = try Data(contentsOf: file)
        for _ in 0..<5 { _ = await rig.engine.runNow("doomed"); await rig.clock.advance(2000) }
        let view = await rig.engine.get("doomed"); XCTAssertEqual(view?.state, "paused"); XCTAssertTrue(view?.reason?.contains("5 failures in a row") == true)
        XCTAssertEqual(try Data(contentsOf: file), before)
        let restored = BackendRoutinesRuntimeState(file: rig.directory.appendingPathComponent("state.json"), debounceMs: 0); XCTAssertNotNil(restored.get("doomed").pausedReason)
        let resumed = await rig.engine.resume("doomed"); XCTAssertTrue(resumed)
    }
    func testHealthNamesMissingDependenciesDisabledBrokenAndStale() async throws {
        let rig = try await BackendRoutinesTestRig.make(unwired: true); addTeardownBlock { await rig.clean() }
        try rig.write("unwired", when: "alert"); try rig.write("off", extra: "enabled: no"); try rig.write("stale", extra: "expect-every: 1h")
        try "# Typo\nwhen: sesion-finished\nin: /tmp/p\n---\nGo.".write(to: rig.directory.appendingPathComponent("routines/broken.md"), atomically: true, encoding: .utf8); await rig.engine.reload()
        let views = await rig.engine.list(); XCTAssertEqual(Dictionary(uniqueKeysWithValues: views.map { ($0.id, $0.state) }), ["unwired": "unarmed", "off": "disabled", "stale": "stale", "broken": "broken"])
        await rig.engine.noteAlertReport(.object([.init("projectPath", .string(BackendRoutinesTestRig.project)), .init("alerts", .array([]))])); let armed = await rig.engine.get("unwired")?.state; XCTAssertEqual(armed, "armed")
        await rig.engine.setRunner(nil); await rig.engine.reload(); let missing = await rig.engine.get("unwired")?.reason; XCTAssertTrue(missing?.contains("Hoot is not running") == true)
    }
    func testScheduleUsesOneTimerAndWakeProducesOneCatchupRun() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }
        try rig.write("one", when: "schedule every 10m"); try rig.write("two", when: "schedule every 20m"); await rig.engine.reload(); XCTAssertEqual(rig.clock.pending, 1)
        // start's disk watch is real, but no build/test execution happens in this migration lane.
        try await rig.engine.start(); rig.clock.jump(11 * 60_000); await rig.engine.wake(); await BackendRoutinesTestRig.settle()
        let calls = await rig.runner.calls; XCTAssertEqual(calls.count, 1); XCTAssertEqual(calls.first?.cause.kind, "schedule"); XCTAssertEqual(rig.clock.pending, 1)
    }
    func testLexicalScopeRejectsSiblingAndParentTraversal() {
        XCTAssertTrue(BackendRoutinesEngine.within("/work/api", child: "/work/api/sub")); XCTAssertFalse(BackendRoutinesEngine.within("/work/api", child: "/work/api-two")); XCTAssertFalse(BackendRoutinesEngine.within("/work/api", child: "/work/api/../secret"))
    }
    func testRingStopsAtThreeRoutinesWithoutSpendingOwnDescendantBudget() async throws {
        let rig = try await BackendRoutinesTestRig.make(), chainRunner = BackendRoutinesChainTestRunner(); addTeardownBlock { await rig.clean() }
        for id in ["a", "b", "c", "d"] { try rig.write(id, when: "session-finished", extra: "max-runs-per-hour: 60\nmax-runs-per-day: 500\nquiet-for: 1s") }
        await rig.engine.setRunner(chainRunner); await rig.engine.reload(); await rig.engine.noteSessionStarted(id: "root", cwd: BackendRoutinesTestRig.project); await rig.engine.noteSessionExit(sessionId: "root", exitCode: 0)
        var consumed = 0
        for _ in 0..<4 {
            await BackendRoutinesTestRig.settle(); let calls = await chainRunner.calls; rig.clock.jump(2000)
            for call in calls.dropFirst(consumed) { await rig.engine.noteSessionExit(sessionId: "child-" + call.runId, exitCode: 0) }; consumed = calls.count
        }
        await BackendRoutinesTestRig.settle(); let calls = await chainRunner.calls
        XCTAssertGreaterThan(calls.count, 4); XCTAssertTrue(calls.allSatisfy { $0.chain.count <= 3 }); XCTAssertLessThanOrEqual(calls.count, 40)
        XCTAssertTrue(rig.actions.rows.contains { $0["detail"].string?.contains("Refused after 3 routines") == true })
    }
    func testDailyCeilingSurvivesNewEngineAndFailureCountCannotOverflow() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }
        try rig.write("daily", extra: "max-runs-per-hour: 60\nmax-runs-per-day: 1\nquiet-for: 1s"); await rig.engine.reload()
        _ = await rig.engine.runNow("daily"); await rig.clock.advance(61 * 60_000)
        let denied = await rig.engine.runNow("daily"); XCTAssertFalse(denied.started); XCTAssertTrue(denied.reason?.contains("daily ceiling of 1") == true)
        await rig.engine.stop()
        let runtime = BackendRoutinesRuntimeState(file: rig.directory.appendingPathComponent("state.json"), now: { rig.clock.now }, debounceMs: 0), store = BackendRoutinesStore(directory: rig.store.directory)
        let engine = BackendRoutinesEngine(options: .init(store: store, runtime: runtime, log: BackendRoutinesLogging.logger(using: rig.actions), runner: rig.runner, now: { rig.clock.now }, setTimer: { rig.clock.set($0, $1) }))
        addTeardownBlock { await engine.stop() }; await engine.reload(); let restartDenied = await engine.runNow("daily"); XCTAssertFalse(restartDenied.started)
        await rig.clock.advance(24 * 60 * 60_000); runtime.update("daily", change: { $0.consecutiveFailures = Int.max }, immediate: true); await rig.runner.configure(outcome: .init(ok: false, error: "still failed"))
        _ = await engine.runNow("daily"); await BackendRoutinesTestRig.settle(); XCTAssertEqual(runtime.get("daily").consecutiveFailures, Int.max); XCTAssertNotNil(runtime.get("daily").pausedReason)
    }
}
