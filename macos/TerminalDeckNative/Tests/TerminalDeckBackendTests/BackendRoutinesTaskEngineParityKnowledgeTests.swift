import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// These use the actual production adapter and knowledge owner's public stored
/// outputs. Raw payload/order assertions remain separate, never a fake SUT.
final class BackendRoutinesTaskEngineParityKnowledgeTests: XCTestCase {
    private typealias F = BackendRoutinesTaskEngineParityFixture
    func testDelegatedFinishedVerifiedReachProductionKnowledgeStore() async throws { try await F.withFixture(knowledge: true) { rig in
        let service = try XCTUnwrap(rig.knowledgeService), goal = try await rig.goals.save(F.obj([("title", .string("Release"))])), task = try await rig.local.create(F.obj([("title", .string("Run the suite")), ("project", .string("/work/app")), ("goalId", goal["id"]), ("assignee", .string("tester"))]))
        let before = try await service.list("/work/app", superseded: true); let delegated = try XCTUnwrap(before.first?.record); XCTAssertEqual(delegated.kind, "task-history"); XCTAssertTrue(delegated.statement.hasPrefix("Delegated “Run the suite” to tester.")); XCTAssertEqual(delegated.provenance.taskId, task.id); XCTAssertEqual(delegated.provenance.goalId, goal["id"].string); XCTAssertEqual(delegated.provenance.agentId, "tester"); XCTAssertEqual(delegated.provenance.sessionId, "s-1")
        try await rig.finish("s-1", answer: "All green."); let after = try await service.list("/work/app", superseded: true), results = after.map(\.record).filter { $0.kind == "result" }
        XCTAssertEqual(results.count, 2); XCTAssertTrue(results.contains { $0.statement.contains("All green.") && $0.status == "superseded" }); let verified = try XCTUnwrap(results.first { $0.status == "verified" }); XCTAssertEqual(verified.provenance.evidence, ["check: npm test"]); XCTAssertEqual(verified.provenance.taskId, task.id); XCTAssertEqual(verified.provenance.agentId, "tester")
    } }
    func testReassignedAndRejectedReachProductionKnowledgeStore() async throws { try await F.withFixture(knowledge: true) { rig in
        let service = try XCTUnwrap(rig.knowledgeService), task = try await rig.local.create(F.obj([("title", .string("Fix it")), ("project", .string("/work/app"))])); _ = try await rig.local.update(task.id, input: F.obj([("assignee", .string("builder"))])); _ = try await rig.local.update(task.id, input: F.obj([("assignee", .string("fixer"))])); let moved = try await service.list("/work/app", superseded: true)
        XCTAssertEqual(moved.filter { $0.record.statement.hasPrefix("Delegated") }.count, 2); XCTAssertTrue(moved.contains { $0.record.statement.contains("From Builder to Fixer.") })
        try await rig.finish("s-2"); try await rig.engine.review(task.id, pass: false, evidence: ["src/login.ts"], reasons: "The empty password still throws.")
        let after = try await service.list("/work/app", superseded: true); XCTAssertTrue(after.contains { $0.record.kind == "task-history" && $0.record.statement.contains("Review rejected") && $0.record.statement.contains("The empty password still throws.") })
    } }
    func testQuietAndExitStallsReachProductionKnowledgeStore() async throws { try await F.withFixture(knowledge: true) { rig in
        let service = try XCTUnwrap(rig.knowledgeService), quiet = try await rig.local.create(F.obj([("title", .string("Quiet worker")), ("project", .string("/work/quiet")), ("assignee", .string("builder"))])); await rig.move(900_000)
        let quietRecords = try await service.list("/work/quiet", superseded: true); XCTAssertTrue(quietRecords.contains { $0.record.statement.contains("stalled") && $0.record.provenance.taskId == quiet.id })
        let exited = try await rig.local.create(F.obj([("title", .string("Exited worker")), ("project", .string("/work/exited")), ("assignee", .string("fixer"))])); await rig.probe.exit("s-2", code: 1); try await rig.engine.noteExit(sessionID: "s-2", exitCode: 1)
        let exitRecords = try await service.list("/work/exited", superseded: true); XCTAssertTrue(exitRecords.contains { $0.record.statement.contains("stalled") && $0.record.statement.contains("exit code 1") && $0.record.provenance.taskId == exited.id })
    } }
    // Current production review forwards evidence to its knowledge adapter.
    // Exercise the stored result as well as the separate raw-payload assertions.
    func testHootReviewPublishesVerifiedResultWithNamedEvidence() async throws { try await F.withFixture(knowledge: true) { rig in
        let service = try XCTUnwrap(rig.knowledgeService), task = try await rig.local.create(F.obj([("title", .string("Fix it")), ("project", .string("/work/app"))])); _ = try await rig.store.update(task.id, patch: F.obj([("requestedBy", .string("hoot"))])); _ = try await rig.local.update(task.id, input: F.obj([("assignee", .string("builder"))])); try await rig.finish("s-1"); try await rig.engine.review(task.id, pass: true, evidence: ["src/login.ts", "npm test: 120 passed"], reasons: "")
        let views = try await service.list("/work/app", superseded: true), verified = try XCTUnwrap(views.map(\.record).first { $0.status == "verified" && $0.provenance.taskId == task.id }); XCTAssertEqual(verified.provenance.evidence, ["src/login.ts", "npm test: 120 passed"])
    } }
}
