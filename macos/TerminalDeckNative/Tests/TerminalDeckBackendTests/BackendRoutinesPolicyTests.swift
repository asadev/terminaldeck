import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor final class BackendRoutinesPolicyTests: XCTestCase {
    func testQueueEachIsFIFOAndRefusesNewestAtLimit() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }
        try rig.write("fifo", extra: "overlap: queue-all\nmax-pending: 2\nquiet-for: 1s")
        await rig.engine.reload(); await rig.runner.configure(gated: true)
        for by in ["first", "second", "third", "overflow"] { _ = await rig.engine.runNow("fifo", by: by) }
        await BackendRoutinesTestRig.settle()
        let before = await rig.runner.calls; XCTAssertEqual(before.count, 1)
        let queued = await rig.engine.get("fifo"); XCTAssertEqual(queued?.pendingCount, 2); XCTAssertEqual(queued?.skippedCount, 1)
        XCTAssertTrue(queued?.queueReason?.contains("full") == true)
        await rig.runner.finish(); await BackendRoutinesTestRig.settle()
        await rig.runner.finish(); await BackendRoutinesTestRig.settle()
        let calls = await rig.runner.calls
        XCTAssertEqual(calls.map(\.cause), [.manual(by: "first"), .manual(by: "second"), .manual(by: "third")])
        await rig.runner.finish(); await BackendRoutinesTestRig.settle()
    }
    func testQuietQueueSurvivesReloadAndDisableDropsIt() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }
        try rig.write("quiet", when: "session-finished", extra: "overlap: queue-all\nquiet-for: 30s")
        await rig.engine.reload()
        _ = await rig.engine.runNow("quiet"); await BackendRoutinesTestRig.settle()
        await rig.engine.noteSessionStarted(id: "one", cwd: BackendRoutinesTestRig.project)
        await rig.engine.noteSessionExit(sessionId: "one", exitCode: 0)
        await rig.engine.reload()
        let retained = await rig.engine.get("quiet"); XCTAssertEqual(retained?.pendingCount, 1); XCTAssertEqual(retained?.state, "armed")
        try rig.write("quiet", when: "session-finished", extra: "overlap: queue-all\nquiet-for: 30s\nenabled: no")
        await rig.engine.reload(); await rig.clock.advance(31_000)
        let calls = await rig.runner.calls.count, cleared = await rig.engine.get("quiet")
        XCTAssertEqual(calls, 1); XCTAssertEqual(cleared?.pendingCount, 0)
    }
    func testReplayIsSerialCappedDeduplicatedAndManualDoesNotMoveCursor() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }
        try rig.write("replay", when: "schedule every 5m", extra: "catch-up: replay\nmax-catch-up: 3\nquiet-for: 1s")
        try await rig.engine.start()
        let initial = rig.runtime.get("replay").scheduleCursors
        _ = await rig.engine.runNow("replay"); await BackendRoutinesTestRig.settle()
        XCTAssertEqual(rig.runtime.get("replay").scheduleCursors, initial)
        await rig.runner.configure(gated: true)
        rig.clock.jump(26 * 60_000); await rig.engine.wake(); await BackendRoutinesTestRig.settle()
        await rig.engine.reload(); await rig.clock.advance(0)
        let view = await rig.engine.get("replay"), first = await rig.runner.calls.count
        XCTAssertEqual(first, 2); XCTAssertEqual(view?.pendingCount, 2); XCTAssertTrue((view?.skippedCount ?? 0) > 0)
        XCTAssertEqual(rig.runtime.get("replay").scheduleCursors, initial, "Only completed or refused work advances the durable cursor")
        for _ in 0..<3 { await rig.runner.finish(); await BackendRoutinesTestRig.settle() }
        let calls = await rig.runner.calls
        XCTAssertEqual(calls.count, 4)
        let scheduled = calls.compactMap { if case .schedule(let due, _) = $0.cause { return due }; return nil }
        XCTAssertEqual(scheduled, scheduled.sorted()); XCTAssertEqual(Set(scheduled).count, 3)
        XCTAssertEqual(rig.runtime.get("replay").scheduleCursors["every 5m"], rig.clock.now)
        let restored = BackendRoutinesRuntimeState(file: rig.runtime.fileURL, now: { rig.clock.now }, debounceMs: 0)
        XCTAssertEqual(restored.get("replay").scheduleCursors, rig.runtime.get("replay").scheduleCursors)
    }
    func testLaterRefusalsCannotConsumePastAcceptedReplay() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }
        try rig.write("ceiling", when: "schedule every 5m", extra: "catch-up: replay\nmax-catch-up: 3\nmax-runs-per-hour: 1")
        try await rig.engine.start(); await rig.runner.configure(gated: true)
        let cursor = rig.runtime.get("ceiling").scheduleCursors
        rig.clock.jump(26 * 60_000); await rig.engine.wake(); await BackendRoutinesTestRig.settle()
        let count = await rig.runner.calls.count; XCTAssertEqual(count, 1)
        XCTAssertEqual(rig.runtime.get("ceiling").scheduleCursors, cursor)
        await rig.runner.finish(); await BackendRoutinesTestRig.settle()
        XCTAssertEqual(rig.runtime.get("ceiling").scheduleCursors["every 5m"], rig.clock.now)
    }
    func testCheckpointFailureDoesNotStartRunner() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }
        try rig.write("disk")
        let failed = BackendRoutinesRuntimeState(file: rig.directory, now: { rig.clock.now }, debounceMs: 0)
        let engine = BackendRoutinesEngine(options: .init(store: rig.store, runtime: failed, log: BackendRoutinesLogging.logger(using: rig.actions), runner: rig.runner, now: { rig.clock.now }, setTimer: { rig.clock.set($0, $1) }))
        addTeardownBlock { await engine.stop() }
        await engine.reload(); let result = await engine.runNow("disk"); await BackendRoutinesTestRig.settle()
        XCTAssertFalse(result.started); XCTAssertTrue(result.reason?.contains("checkpoint") == true)
        let count = await rig.runner.calls.count; XCTAssertEqual(count, 0)
        let view = await engine.get("disk"); XCTAssertEqual(view?.state, "paused")
    }
    func testExplicitSkipAndOnceAndNewScheduleStartFromNow() async throws {
        for (policy, expected) in [("skip", 0), ("once", 1)] {
            let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }
            try rig.write("catchup", when: "schedule every 5m", extra: "catch-up: \(policy)")
            try await rig.engine.start(); rig.clock.jump(26 * 60_000); await rig.engine.wake(); await BackendRoutinesTestRig.settle()
            let count = await rig.runner.calls.count; XCTAssertEqual(count, expected)
            let cursor = rig.runtime.get("catchup").scheduleCursors["every 5m"]
            XCTAssertEqual(cursor, rig.clock.now)
        }
    }
    func testUnknownRunAfterRestartIsHeldUntilExplicitResume() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }
        try rig.write("interrupted", when: "schedule every 5m", extra: "catch-up: replay")
        rig.runtime.update("interrupted", change: { $0.activeRunID = "previous-process"; $0.pendingAtCheckpoint = 2 }, immediate: true)
        await rig.engine.reload(); await rig.clock.advance(60 * 60_000)
        let view = await rig.engine.get("interrupted"), count = await rig.runner.calls.count
        XCTAssertEqual(view?.state, "paused"); XCTAssertTrue(view?.reason?.contains("previous app process") == true); XCTAssertEqual(count, 0)
        _ = await rig.engine.resume("interrupted"); await rig.clock.advance(0)
        let resumedCount = await rig.runner.calls.count; XCTAssertEqual(resumedCount, 0)
        XCTAssertNil(rig.runtime.get("interrupted").activeRunID)
    }
    func testLateCompletionCannotChangeReplacementOrStartStaleQueue() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }
        try rig.write("replace", extra: "overlap: queue-all")
        await rig.engine.reload(); await rig.runner.configure(gated: true)
        _ = await rig.engine.runNow("replace"); _ = await rig.engine.runNow("replace"); await BackendRoutinesTestRig.settle()
        try FileManager.default.removeItem(at: rig.store.directory.appendingPathComponent("replace.md")); await rig.engine.reload()
        try rig.write("replace"); await rig.engine.reload()
        let held = await rig.engine.runNow("replace"); XCTAssertFalse(held.started)
        let unsafeResume = await rig.engine.resume("replace"); XCTAssertFalse(unsafeResume)
        XCTAssertNotNil(rig.runtime.get("replace").activeRunID)
        await rig.runner.finish(.init(ok: false, error: "stale")); await BackendRoutinesTestRig.settle()
        let view = await rig.engine.get("replace"), count = await rig.runner.calls.count
        XCTAssertEqual(view?.pendingCount, 0); XCTAssertEqual(count, 1)
    }
    func testBoundedOccurrenceProjectionAndCalendarDST() {
        let interval = BackendRoutinesPolicies.occurrences(.every(intervalMs: 300_000), after: 0, through: 1_000_000_000_000, limit: 3)
        XCTAssertEqual(interval.times, [300_000, 600_000, 900_000]); XCTAssertTrue(interval.hasMore)
        XCTAssertTrue(BackendRoutinesPolicies.occurrences(.every(intervalMs: 300_000), after: 100, through: 0, limit: 3).times.isEmpty)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 9))!.timeIntervalSince1970 * 1000
        let daily = BackendRoutinesPolicies.occurrences(.at(minutes: 9 * 60, days: nil), after: start, through: start + 3 * 86_400_000, limit: 5, calendar: calendar)
        XCTAssertEqual(daily.times.count, 3); XCTAssertEqual(daily.times[0] - start, 23 * 3_600_000)
    }
    func testMCPPartialUpdatePreservesPoliciesUnknownHeadersAndExtraTriggers() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }
        try rig.write("settings", when: "schedule every 5m", extra: "when: session-failed\noverlap: queue-all\ncatch-up: replay\nmax-pending: 7\nmax-catch-up: 3\nfuture: keep")
        await rig.engine.reload()
        let service = BackendRoutinesRegisteredAppAdapter(api: BackendRoutinesAPI(engine: rig.engine, store: rig.store))
        let loaded = try await BackendDeckToolsAppRoutines.currentDraft(service, "settings")
        let base = try XCTUnwrap(loaded)
        let patch = try BackendDeckToolsAppRoutines.patch(.object([.init("name", .string("Changed"))]))
        let saved = try await service.update("settings", draft: base.merging(patch))
        XCTAssertEqual(saved["ok"], .bool(true)); XCTAssertEqual(saved["view"]["maxPending"], .number(7))
        XCTAssertEqual(saved["view"]["catchUp"], .string("replay")); XCTAssertEqual(saved["view"]["pendingCount"], .number(0))
        let routine = try XCTUnwrap(rig.store.read("settings").routine)
        XCTAssertEqual(routine.triggers.count, 2); XCTAssertEqual(routine.unknown["future"], ["keep"])
        XCTAssertEqual(routine.maxCatchUp, 3); XCTAssertEqual(routine.overlap, .queueAll)
        let resetPatch = try BackendDeckToolsAppRoutines.patch(.object([.init("catchUp", .string("legacy"))]))
        let currentDraft = try await BackendDeckToolsAppRoutines.currentDraft(service, "settings")
        let current = try XCTUnwrap(currentDraft)
        let reset = try await service.update("settings", draft: current.merging(resetPatch))
        XCTAssertEqual(reset["ok"], .bool(true)); XCTAssertEqual(reset["view"]["catchUp"], .null)
        let resetRoutine = try XCTUnwrap(rig.store.read("settings").routine)
        XCTAssertNil(resetRoutine.catchUp); XCTAssertEqual(resetRoutine.name, "Changed")
        XCTAssertEqual(resetRoutine.triggers, routine.triggers); XCTAssertEqual(resetRoutine.unknown, routine.unknown)
        XCTAssertEqual(resetRoutine.maxPending, 7); XCTAssertEqual(resetRoutine.maxCatchUp, 3)
    }
    func testNewHeadersRoundTripValidateAndToolPatch() throws {
        let text = "# Policies\nwhen: schedule every 5m\nwhen: manual\nin: /tmp/project\noverlap: queue-all\ncatch-up: replay\nmax-pending: 7\nmax-catch-up: 3\nfuture: keep\n---\nGo"
        let routine = try XCTUnwrap(BackendRoutinesFormat.parseRoutine("policies", text: text).routine)
        XCTAssertEqual(routine.maxPending, 7); XCTAssertEqual(routine.catchUp, .replay)
        XCTAssertEqual(BackendRoutinesFormat.parseRoutine("policies", text: BackendRoutinesFormat.serializeRoutine(routine)).routine, routine)
        for invalid in ["max-pending: 101", "max-pending: 0", "max-catch-up: 51", "max-catch-up: 2.5", "catch-up: surprise"] {
            XCTAssertFalse(BackendRoutinesFormat.parseRoutine("bad", text: text.replacingOccurrences(of: "future: keep", with: invalid)).ok)
        }
        let patch = try BackendDeckToolsAppRoutines.patch(.object([.init("catchUp", .string("once")), .init("maxPending", .number(9))]))
        XCTAssertEqual(patch["catchUp"], .string("once")); XCTAssertEqual(patch["maxPending"], .number(9)); XCTAssertEqual(patch["overlap"], .missing)
    }
}
