import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Real task engine, memory-only storage and a stand-in Hoot. No app, host or AI is launched.
final class HootWake19Tests: XCTestCase {
    private typealias F = BackendRoutinesTaskEngineParityFixture
    private static let carryOn = "The app restarted. Carry on where you left off."

    private static func interrupted(_ rig: F, queued: Bool = false) async throws -> String {
        // The previous app wrote this running mark; this start must clear and remember it.
        let task = try await rig.local.create(F.obj([("title", .string("Fix the sign-in")),
            ("instructions", .string("Check the empty password.")), ("project", .string("/work/app")), ("assignee", .string("hoot"))]))
        if queued { _ = try await rig.store.update(task.id, patch: F.obj([("process", .string("queued")), ("hootTurnOpen", .bool(true))])) }
        try await rig.engine.stop()
        try await rig.engine.start()
        return task.id
    }

    private static func bind(_ rig: F) async -> FORKTASKSHoot {
        let hoot = FORKTASKSHoot()
        await rig.engine.setHootTaskTurns { turn, progress in try await hoot.run(turn, progress: progress) }
        return hoot
    }

    func testSlowWakeAfterTwelveSecondsResumesExactlyOnce() async throws {
        try await F.withFixture { rig in
            let id = try await Self.interrupted(rig), hoot = await Self.bind(rig)
            rig.clock.move(by: 12_000) // No launch record or wall-clock fallback is used.
            let first = try await rig.engine.continueInterruptedTask(id, text: Self.carryOn)
            let second = try await rig.engine.continueInterruptedTask(id, text: Self.carryOn)
            await rig.engine.settleHootTurns()
            let turns = await hoot.turns
            XCTAssertTrue(first); XCTAssertFalse(second)
            XCTAssertEqual(turns.map(\.taskID), [id])
            XCTAssertTrue(turns.first?.brief.contains(Self.carryOn) == true)
        }
    }

    func testNormalWakeResumesExactlyOnce() async throws {
        try await F.withFixture { rig in
            let id = try await Self.interrupted(rig), hoot = await Self.bind(rig)
            rig.clock.move(by: 1_000)
            let resumed = try await rig.engine.continueInterruptedTask(id, text: Self.carryOn)
            await rig.engine.settleHootTurns()
            let turns = await hoot.turns, pending = await rig.engine.interruptedTaskIDs()
            XCTAssertTrue(resumed); XCTAssertEqual(turns.count, 1); XCTAssertTrue(pending.isEmpty)
        }
    }

    func testQueuedTaskStillResumesAfterAnHour() async throws {
        try await F.withFixture { rig in
            let id = try await Self.interrupted(rig, queued: true), hoot = await Self.bind(rig)
            rig.clock.move(by: 3_600_000)
            let resumed = try await rig.engine.continueInterruptedTask(id, text: Self.carryOn)
            await rig.engine.settleHootTurns()
            let turns = await hoot.turns
            XCTAssertTrue(resumed); XCTAssertEqual(turns.count, 1)
        }
    }

    func testNothingPendingStartsNothing() async throws {
        try await F.withFixture { rig in
            let hoot = await Self.bind(rig)
            rig.clock.move(by: 12_000)
            let pending = await rig.engine.interruptedTaskIDs()
            let resumed = try await rig.engine.continueInterruptedTask("local:absent", text: Self.carryOn)
            await rig.engine.settleHootTurns()
            let turns = await hoot.turns
            XCTAssertTrue(pending.isEmpty); XCTAssertFalse(resumed); XCTAssertTrue(turns.isEmpty)
        }
    }

    func testAnEditWhileHootWakesDoesNotLosePendingWork() async throws {
        try await F.withFixture { rig in
            let id = try await Self.interrupted(rig), hoot = await Self.bind(rig)
            _ = try await rig.local.update(id, input: F.obj([("title", .string("Check sign-in on phones"))]))
            rig.clock.move(by: 12_000)
            let resumed = try await rig.engine.continueInterruptedTask(id, text: Self.carryOn)
            await rig.engine.settleHootTurns()
            let turns = await hoot.turns
            XCTAssertTrue(resumed); XCTAssertEqual(turns.count, 1)
            XCTAssertEqual(turns.first?.title, "Check sign-in on phones")
        }
    }

    func testConcurrentWakeCallbacksResumeOnlyOnce() async throws {
        try await F.withFixture { rig in
            let id = try await Self.interrupted(rig), hoot = await Self.bind(rig)
            async let first = rig.engine.continueInterruptedTask(id, text: Self.carryOn)
            async let second = rig.engine.continueInterruptedTask(id, text: Self.carryOn)
            let results = try await [first, second]
            await rig.engine.settleHootTurns()
            let turns = await hoot.turns
            XCTAssertEqual(results.filter { $0 }.count, 1); XCTAssertEqual(turns.count, 1)
        }
    }

    func testReplyThroughTaskToolsBeforeWakePreventsAutomaticResume() async throws {
        try await F.withFixture { rig in
            let id = try await Self.interrupted(rig), hoot = await Self.bind(rig)
            _ = try await rig.local.reply(id, text: "Continue with my new instruction.")
            await rig.engine.settleHootTurns()
            rig.clock.move(by: 12_000)
            let resumed = try await rig.engine.continueInterruptedTask(id, text: Self.carryOn)
            let turns = await hoot.turns
            XCTAssertFalse(resumed); XCTAssertEqual(turns.count, 1)
            XCTAssertFalse(turns.first?.brief.contains(Self.carryOn) == true)
        }
    }

    func testStoppedFinishedArchivedReassignedAndAlreadyRunningTasksStayQuiet() async throws {
        for patch in [F.obj([("stopped", .bool(true))]), F.obj([("result", .string("Done."))]),
                      F.obj([("crmStatus", .string("Done"))]), F.obj([("completedAt", .number(1))]),
                      F.obj([("archivedAt", .number(1))]), F.obj([("sessionId", .string("another-session"))]),
                      F.obj([("hootTurnOpen", .bool(true))]), F.obj([("process", .string("queued"))]),
                      F.obj([("lastTurn", .string("a-new-turn"))]), F.obj([("questionOpen", .bool(true))]),
                      F.obj([("assignee", BackendTaskLocalService.assignment("me", kind: "human"))])] {
            try await F.withFixture { rig in
                let id = try await Self.interrupted(rig), hoot = await Self.bind(rig)
                _ = try await rig.store.update(id, patch: patch)
                rig.clock.move(by: 12_000)
                let resumed = try await rig.engine.continueInterruptedTask(id, text: Self.carryOn)
                await rig.engine.settleHootTurns()
                let turns = await hoot.turns
                XCTAssertFalse(resumed); XCTAssertTrue(turns.isEmpty)
            }
        }
    }

    func testOldStopNoteAloneIsNeverResumedByALaterStart() async throws {
        try await F.withFixture { rig in
            let id = try await Self.interrupted(rig)
            try await rig.engine.stop(); try await rig.engine.start()
            let hoot = await Self.bind(rig)
            let pending = await rig.engine.interruptedTaskIDs()
            let resumed = try await rig.engine.continueInterruptedTask(id, text: Self.carryOn)
            let turns = await hoot.turns
            XCTAssertTrue(pending.isEmpty); XCTAssertFalse(resumed); XCTAssertTrue(turns.isEmpty)
        }
    }

    func testInterruptedAgentKeepsItsConversation() async throws {
        try await F.withFixture { rig in
            let task = try await rig.local.create(F.obj([("title", .string("Fix the footer")),
                ("instructions", .string("Check phones.")), ("project", .string("/work/app")), ("assignee", .string("builder"))]))
            let session = try XCTUnwrap(task.sessionID)
            await rig.probe.forgetSessions()
            try await rig.engine.stop(); try await rig.engine.start()
            rig.clock.move(by: 12_000)
            let resumed = try await rig.engine.continueInterruptedTask(task.id, text: Self.carryOn)
            let again = try await rig.engine.continueInterruptedTask(task.id, text: Self.carryOn)
            let starts = await rig.probe.launches
            XCTAssertTrue(resumed); XCTAssertFalse(again); XCTAssertEqual(starts.count, 2)
            let resumedTask = try await rig.record(task.id)
            XCTAssertEqual(starts.last?.resume, "conv-1"); XCTAssertNotEqual(resumedTask.sessionID, session)
        }
    }
}
