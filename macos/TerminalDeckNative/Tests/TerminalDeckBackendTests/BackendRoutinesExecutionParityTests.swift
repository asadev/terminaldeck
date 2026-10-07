import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private struct BackendRoutinesExecutionParityMacProvider: BackendRoutinesLaunchEnvironmentProviding {
    func environment(flags: [String], inherited: [String: String]) async throws -> BackendRoutinesLaunchEnvironment { .init(command: "/fake/claude", args: flags, env: inherited) }
}
private enum BackendRoutinesExecutionParityBindings {
    /// runner.test.ts `killPlan(4321, 'darwin')`: the production launcher's own stop plan for a pid. The real stop
    /// sends exactly this signal to the child (no process is launched here).
    static let macKillSignal: (@Sendable (Int) -> String)? = { BackendRoutinesNativeLauncher.killSignal(pid: $0) }
}
final class BackendRoutinesExecutionParityTests: XCTestCase {
    func testExactFinishedFailedAndForeignFolderEvents() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }
        try rig.write("finish", when: "session-finished"); try rig.write("fail", when: "session-failed"); await rig.engine.reload()
        await rig.engine.noteSessionStarted(id: "foreign", cwd: "/tmp/somewhere-else"); await rig.engine.noteSessionExit(sessionId: "foreign", exitCode: 0); await BackendRoutinesTestRig.settle(); let foreignCalls = await rig.runner.calls; XCTAssertEqual(foreignCalls.count, 0)
        await rig.engine.noteSessionStarted(id: "s1", cwd: BackendRoutinesTestRig.project); await rig.engine.noteSessionExit(sessionId: "s1", exitCode: 0); await BackendRoutinesTestRig.settle(); let finished = await rig.runner.calls
        XCTAssertEqual(finished.count, 1); XCTAssertEqual(finished[0].routine.id, "finish"); XCTAssertEqual(finished[0].cause, .sessionFinished(sessionId: "s1", exitCode: 0)); XCTAssertEqual(finished.filter { $0.routine.id == "fail" }.count, 0)
        await rig.engine.noteSessionStarted(id: "s2", cwd: BackendRoutinesTestRig.project); await rig.engine.noteSessionExit(sessionId: "s2", exitCode: 1); await BackendRoutinesTestRig.settle(); let failed = await rig.runner.calls.filter { $0.routine.id == "fail" }
        XCTAssertEqual(failed.count, 1); XCTAssertEqual(failed[0].cause, .sessionFailed(sessionId: "s2", exitCode: 1))
    }
    func testUnresponsiveCancellationDropsReplacementAndLogsExactReason() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }; try rig.write("latest", extra: "overlap: cancel\nquiet-for: 1s"); await rig.engine.reload(); await rig.runner.configure(gated: true)
        _ = await rig.engine.runNow("latest"); await BackendRoutinesTestRig.settle(); _ = await rig.engine.runNow("latest"); let before = await rig.engine.get("latest"); XCTAssertEqual(before?.pending, true)
        await rig.clock.advance(BackendRoutinesEngine.cancelGraceMs + 1000); let after = await rig.engine.get("latest"), calls = await rig.runner.calls
        XCTAssertEqual(after?.pending, false); XCTAssertEqual(calls.count, 1); XCTAssertTrue(rig.actions.rows.contains { $0["action"].string == "routine.cancel" && $0["outcome"].string == "refused" && $0["detail"].string == "The previous run did not stop when it was asked to, so the new one was dropped." })
        await rig.runner.configure(); await rig.runner.finish()
    }
    func testHourlyPauseStateHasRecoveryTimeAndRunsExactlyTwice() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }; try rig.write("chatty", when: "session-finished", extra: "max-runs-per-hour: 2\nquiet-for: 1s"); await rig.engine.reload()
        for n in 0..<5 { await rig.engine.noteSessionStarted(id: "s\(n)", cwd: BackendRoutinesTestRig.project); await rig.engine.noteSessionExit(sessionId: "s\(n)", exitCode: 0); await rig.clock.advance(2000) }
        let calls = await rig.runner.calls, paused = await rig.engine.get("chatty"); XCTAssertEqual(calls.count, 2); XCTAssertEqual(paused?.state, "paused"); XCTAssertTrue(paused?.reason?.contains("hourly ceiling of 2") == true); XCTAssertNotNil(paused?.pausedUntil)
        await rig.clock.advance(61 * 60_000); let recovered = await rig.engine.get("chatty"); XCTAssertEqual(recovered?.state, "armed")
    }
    func testRoutineAPICreateUpdateRunPauseResumeAndDeleteExactViews() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }; let api = BackendRoutinesAPI(engine: rig.engine, store: rig.store)
        let draft = NativeRPCValue.object([.init("name", .string("Nightly sweep")), .init("when", .string("manual")), .init("in", .string("/tmp/td-project")), .init("prompt", .string("Run the tests."))]), id = NativeRPCValue.string("nightly-sweep")
        let created = try await api.create(draft), initial = await api.list(); XCTAssertTrue(created.ok); XCTAssertEqual(created.id, "nightly-sweep"); XCTAssertEqual(initial.count, 1)
        let disk = try String(contentsOf: rig.store.directory.appendingPathComponent("nightly-sweep.md"), encoding: .utf8); XCTAssertTrue(disk.contains("# Nightly sweep")); XCTAssertTrue(disk.contains("when: manual"))
        let updated = try await api.update(id, draft: draft.setting("prompt", .string("Run the tests twice."))), view = await api.get(id), listed = await api.list(); XCTAssertTrue(updated.ok); XCTAssertEqual(view?.prompt, "Run the tests twice."); XCTAssertEqual(listed.count, 1)
        let result = await api.run(id); XCTAssertTrue(result.started); await BackendRoutinesTestRig.settle(); let calls = await rig.runner.calls; XCTAssertEqual(calls.map { $0.routine.id }, ["nightly-sweep"])
        let before = rig.store.readText("nightly-sweep").text, paused = await api.pause(id, reason: .string("Not right now")), pausedView = await api.get(id); XCTAssertTrue(paused); XCTAssertEqual(pausedView?.state, "paused"); XCTAssertEqual(rig.store.readText("nightly-sweep").text, before)
        let refused = await api.run(id, by: "copilot"); XCTAssertFalse(refused.started); XCTAssertTrue(refused.reason?.contains("Not right now") == true)
        let resumed = await api.resume(id), armed = await api.get(id); XCTAssertTrue(resumed); XCTAssertEqual(armed?.state, "armed")
        let removed = try await api.remove(id), absent = try await api.remove(id), final = await api.list(); XCTAssertEqual(removed["ok"], .bool(true)); XCTAssertEqual(absent["ok"], .bool(false)); XCTAssertEqual(final.count, 0)
    }
    func testFiresAndRunsAreCountedSeparately() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }; try rig.write("chatty", when: "session-finished", extra: "max-runs-per-hour: 1\nquiet-for: 1s"); await rig.engine.reload()
        for n in 0..<4 { await rig.engine.noteSessionStarted(id: "s\(n)", cwd: BackendRoutinesTestRig.project); await rig.engine.noteSessionExit(sessionId: "s\(n)", exitCode: 0); await rig.clock.advance(2000) }
        let view = await rig.engine.get("chatty"); XCTAssertEqual(view?.runsLastHour, 1); XCTAssertEqual(view?.firesLastHour, 4)
    }
    func testAppWideThreeRunCeilingAcrossTwoRoutines() async throws {
        let rig = try await BackendRoutinesTestRig.make(global: 3); addTeardownBlock { await rig.clean() }; for id in ["a", "b"] { try rig.write(id, when: "session-finished", extra: "quiet-for: 1s") }; await rig.engine.reload()
        for n in 0..<4 { await rig.engine.noteSessionStarted(id: "s\(n)", cwd: BackendRoutinesTestRig.project); await rig.engine.noteSessionExit(sessionId: "s\(n)", exitCode: 0); await rig.clock.advance(2000) }
        let calls = await rig.runner.calls, view = await rig.engine.get("a"); XCTAssertEqual(calls.count, 3); XCTAssertTrue(view?.reason?.contains("this app's ceiling") == true)
    }
    func testHourlyCeilingCannotBeResetByNewEngine() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }; try rig.write("chatty", extra: "max-runs-per-hour: 2\nquiet-for: 1s"); await rig.engine.reload()
        _ = await rig.engine.runNow("chatty"); await rig.clock.advance(2000); _ = await rig.engine.runNow("chatty"); await rig.clock.advance(2000); await rig.engine.stop()
        let runtime = BackendRoutinesRuntimeState(file: rig.directory.appendingPathComponent("state.json"), now: { rig.clock.now }, debounceMs: 0), store = BackendRoutinesStore(directory: rig.store.directory), engine = BackendRoutinesEngine(options: .init(store: store, runtime: runtime, log: BackendRoutinesLogging.logger(using: rig.actions), runner: rig.runner, now: { rig.clock.now }, setTimer: { rig.clock.set($0, $1) }))
        addTeardownBlock { await engine.stop() }; await engine.reload(); let answer = await engine.runNow("chatty"), calls = await rig.runner.calls; XCTAssertFalse(answer.started); XCTAssertEqual(calls.count, 2)
    }
    func testManualCopilotRunCannotGoAroundOneRunCeiling() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }; try rig.write("chatty", extra: "max-runs-per-hour: 1\nquiet-for: 1s"); await rig.engine.reload()
        let first = await rig.engine.runNow("chatty", by: "copilot"); await rig.clock.advance(2000); let second = await rig.engine.runNow("chatty", by: "copilot"); XCTAssertTrue(first.started); XCTAssertFalse(second.started); XCTAssertTrue(second.reason?.contains("ceiling") == true)
    }
    func testQuietBurstProducesOneTrailingRun() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }; try rig.write("bursty", when: "session-finished", extra: "quiet-for: 30s"); await rig.engine.reload()
        await rig.engine.noteSessionStarted(id: "first", cwd: BackendRoutinesTestRig.project); await rig.engine.noteSessionExit(sessionId: "first", exitCode: 0); await BackendRoutinesTestRig.settle()
        for n in 0..<3 { await rig.engine.noteSessionStarted(id: "extra\(n)", cwd: BackendRoutinesTestRig.project); await rig.engine.noteSessionExit(sessionId: "extra\(n)", exitCode: 0); await rig.clock.advance(1000) }
        let before = await rig.runner.calls.count; XCTAssertEqual(before, 1); await rig.clock.advance(40_000); let after = await rig.runner.calls.count; XCTAssertEqual(after, 2)
    }
    func testUnknownFolderIsExplicitlyUnarmed() async throws {
        let rig = try await BackendRoutinesTestRig.make(allow: { $0 == BackendRoutinesTestRig.project ? nil : "\($0) is not one of your projects." }); addTeardownBlock { await rig.clean() }
        try rig.write("sweep", when: "session-finished", folder: "/"); await rig.engine.reload(); let view = await rig.engine.get("sweep"); XCTAssertEqual(view?.state, "unarmed"); XCTAssertTrue(view?.reason?.contains("not one of your projects") == true)
    }
    func testExpectedCadenceBecomesArmedThenStaleAfterTwentySevenHours() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }; try rig.write("nightly", when: "session-finished", extra: "expect-every: 26h"); await rig.engine.reload(); let initial = await rig.engine.get("nightly"); XCTAssertEqual(initial?.state, "stale")
        await rig.engine.noteSessionStarted(id: "s", cwd: BackendRoutinesTestRig.project); await rig.engine.noteSessionExit(sessionId: "s", exitCode: 0); await BackendRoutinesTestRig.settle(); let active = await rig.engine.get("nightly"); XCTAssertEqual(active?.state, "armed")
        await rig.clock.advance(27 * 3_600_000); let late = await rig.engine.get("nightly"); XCTAssertEqual(late?.state, "stale")
    }
    func testFiveFailurePauseSurvivesASecondEngineAndCanResume() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }; try rig.write("doomed", extra: "quiet-for: 1s"); await rig.engine.reload(); await rig.runner.configure(outcome: .init(ok: false, error: "the prompt could not be delivered"))
        for _ in 0..<5 { _ = await rig.engine.runNow("doomed"); await rig.clock.advance(2000) }; await rig.engine.stop()
        let store = BackendRoutinesStore(directory: rig.store.directory), runtime = BackendRoutinesRuntimeState(file: rig.directory.appendingPathComponent("state.json"), now: { rig.clock.now }, debounceMs: 0), engine = BackendRoutinesEngine(options: .init(store: store, runtime: runtime, log: BackendRoutinesLogging.logger(using: rig.actions), runner: rig.runner, now: { rig.clock.now }, setTimer: { rig.clock.set($0, $1) }))
        addTeardownBlock { await engine.stop() }; await engine.reload(); let paused = await engine.get("doomed"); XCTAssertEqual(paused?.state, "paused"); XCTAssertTrue(paused?.reason?.contains("failures in a row") == true); XCTAssertTrue(paused?.lastError?.contains("could not be delivered") == true)
        let resumed = await engine.resume("doomed"), armed = await engine.get("doomed"); XCTAssertTrue(resumed); XCTAssertEqual(armed?.state, "armed")
    }
    func testDailyScheduleUsesOneDueTimerAndDoesNotRepeatSameDay() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }
        let now = Date(timeIntervalSince1970: rig.clock.now / 1000), day = Calendar.current.startOfDay(for: now), nine = day.addingTimeInterval(9 * 3600).timeIntervalSince1970 * 1000
        rig.clock.jump(nine - rig.clock.now); try rig.write("nightly", when: "schedule 09:30"); try await rig.engine.start(); XCTAssertEqual(rig.clock.pending, 1)
        await rig.clock.advance(29 * 60_000); let before = await rig.runner.calls.count; XCTAssertEqual(before, 0); await rig.clock.advance(2 * 60_000); let after = await rig.runner.calls; XCTAssertEqual(after.count, 1); XCTAssertEqual(after.first?.cause.kind, "schedule")
        let view = await rig.engine.get("nightly"); XCTAssertGreaterThan(view?.nextDueAt ?? 0, rig.clock.now); await rig.clock.advance(60 * 60_000); let final = await rig.runner.calls.count; XCTAssertEqual(final, 1)
    }
    func testThreeMissedSchedulesAreReportedWithoutCatchupStorm() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }; try rig.write("nightly", when: "schedule 09:30")
        let routine = try XCTUnwrap(try rig.store.read("nightly").routine), previous = BackendRoutinesScheduling.nextDue({ if case .schedule(let schedule) = routine.triggers[0] { return schedule }; return .every(intervalMs: 86_400_000) }(), from: rig.clock.now)
        rig.runtime.update("nightly", change: { $0.runs = [previous] }, immediate: true); rig.clock.jump(previous + 3 * 86_400_000 + 60_000 - rig.clock.now); await rig.engine.reload(); let view = await rig.engine.get("nightly"); XCTAssertEqual(view?.missedWhileClosed, 3)
    }
    func testReloadAddsAHandWrittenRoutineAndRunsIt() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }; await rig.engine.reload(); let empty = await rig.engine.list(); XCTAssertTrue(empty.isEmpty); try rig.write("new", when: "session-finished"); await rig.engine.reload(); let added = await rig.engine.list(); XCTAssertEqual(added.count, 1)
        await rig.engine.noteSessionStarted(id: "s", cwd: BackendRoutinesTestRig.project); await rig.engine.noteSessionExit(sessionId: "s", exitCode: 0); await BackendRoutinesTestRig.settle(); let calls = await rig.runner.calls.count; XCTAssertEqual(calls, 1)
    }
    func testReloadRemovesDeletedRoutineAndItsSubscriptions() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }; try rig.write("going", when: "session-finished"); await rig.engine.reload(); try FileManager.default.removeItem(at: rig.store.directory.appendingPathComponent("going.md")); await rig.engine.reload()
        await rig.engine.noteSessionStarted(id: "s", cwd: BackendRoutinesTestRig.project); await rig.engine.noteSessionExit(sessionId: "s", exitCode: 0); await BackendRoutinesTestRig.settle(); let rows = await rig.engine.list(), calls = await rig.runner.calls; XCTAssertTrue(rows.isEmpty); XCTAssertTrue(calls.isEmpty)
    }
    func testEditingDoesNotAbortAnInFlightRun() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }; try rig.write("editing", when: "session-finished"); await rig.engine.reload(); await rig.runner.configure(gated: true)
        await rig.engine.noteSessionStarted(id: "s", cwd: BackendRoutinesTestRig.project); await rig.engine.noteSessionExit(sessionId: "s", exitCode: 0); await BackendRoutinesTestRig.settle(); let run = await rig.runner.calls.first
        try rig.write("editing", when: "session-finished", extra: "overlap: skip"); await rig.engine.reload(); let view = await rig.engine.get("editing"); XCTAssertEqual(view?.running, true); XCTAssertEqual(run?.cancellation.isCancelled, false); await rig.runner.configure(); await rig.runner.finish()
    }
    func testUpdateRefusesMissingRoutineWithoutCreatingAFile() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }; let api = BackendRoutinesAPI(engine: rig.engine, store: rig.store)
        let answer = try await api.update(.string("missing"), draft: .object([])); XCTAssertFalse(answer.ok); XCTAssertEqual(answer.problems, ["There is no routine called `missing`."]); XCTAssertTrue(rig.store.list().isEmpty)
    }
    func testTextEditorRejectsPathIDsAndMissingExistingRoutine() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }; let api = BackendRoutinesAPI(engine: rig.engine, store: rig.store)
        let read = await api.text(.string("../../state")), path = try await api.saveText(.string("../../state"), text: .string("anything")), missing = try await api.saveText(.string("never-existed"), text: .string("anything"))
        XCTAssertEqual(read["ok"], .bool(false)); XCTAssertFalse(path.ok); XCTAssertFalse(missing.ok); let views = await api.list(); XCTAssertTrue(views.isEmpty)
    }
    func testRawTextWriteIsAbsentFromRoutineMCPCatalogue() throws {
        let entries = try BackendDeckToolsAppMetadata.entries().filter { $0.module == "routine-tools" }, ids = Set(entries.map { $0.spec.id })
        XCTAssertEqual(entries.count, 7); for forbidden in ["routines.saveText", "routines.save-text", "routines.text"] { XCTAssertFalse(ids.contains(forbidden)) }
    }
    func testMacLaunchUsesDirectCLIAndPrintIsFirstArgument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("routine-mac-parity-" + UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }; let capture = BackendRoutinesLaunchCapture()
        let runner = BackendRoutinesCopilotRunner(options: .init(mcpConfig: { "/state/unattended.json" }, copilotRoot: root, providers: BackendRoutinesExecutionParityMacProvider(), launch: { await capture.launch($0, text: "NOTHING-TO-REPORT") }, actions: BackendRoutinesTestActions()))
        let routine = BackendRoutinesRoutine(id: "test", name: "Test", triggers: [.manual], folder: "/work/api", prompt: "Check it."); _ = await runner.run(.init(routine: routine, runId: "r", cause: .manual(by: "user"), chain: [])); let input = try BackendRoutinesTaskEngineParityUnwrap(await capture.inputs.first)
        XCTAssertEqual(URL(fileURLWithPath: input.command).lastPathComponent, "claude"); XCTAssertEqual(input.args.first, "--print"); XCTAssertFalse(input.args.contains("/c")); XCTAssertFalse(input.args.contains("-c"))
    }
    func testMacStopSignalsTheCLIWithSIGTERM() throws { let signal = try XCTUnwrap(BackendRoutinesExecutionParityBindings.macKillSignal); XCTAssertEqual(signal(4321), "SIGTERM") }
    func testRefusedCallIsVisibleFromANewEngine() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }; try rig.write("sweep")
        let tool = try BackendMCPTool(id: "demo.alter", wireName: "demo_alter", description: "Alter", inputSchema: .object([.init("type", .string("object")), .init("properties", .object([]))]), tier: .alter), consent = BackendDeckCoreSecurityConsentBroker(ask: { _ in XCTFail("No unattended consent dialog"); return false }), control = try BackendDeckCoreSecurityControl(log: BackendDeckCoreSecurityActionLog(directory: rig.directory.appendingPathComponent("copilot-log")), consent: consent, policies: [.init(tool: tool, summary: { _, _ in "Change something" }, run: { _, _ in XCTFail("An unattended alter must not run"); return .init(value: .null) })])
        let runner = BackendRoutinesToolProbeRunner(); await rig.engine.setRunner(runner); await rig.engine.setControl(.init(control: control)); await rig.engine.reload(); _ = await rig.engine.runNow("sweep"); await BackendRoutinesTestRig.settle(); await rig.engine.stop()
        let runtime = BackendRoutinesRuntimeState(file: rig.directory.appendingPathComponent("state.json"), debounceMs: 0), store = BackendRoutinesStore(directory: rig.store.directory), next = BackendRoutinesEngine(options: .init(store: store, runtime: runtime, log: BackendRoutinesLogging.logger(using: rig.actions), runner: runner)); await next.reload(); let view = await next.get("sweep"); XCTAssertEqual(view?.refusedCalls.first?.tool, "demo.alter"); await next.stop(); await consent.stop()
    }
}
