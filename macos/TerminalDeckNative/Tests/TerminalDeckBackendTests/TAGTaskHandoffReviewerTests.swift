import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class TAGTaskHandoffReviewerTests: XCTestCase {
    private typealias F = BackendRoutinesTaskEngineParityFixture
    private typealias E = BackendRoutinesTaskEngineParityExpect
    func testAssignedAgentCreatesChildWithOriginAndCannotBorrowAnotherParent() async throws { try await F.withFixture { rig in
        let parent = try await rig.local.create(F.obj([("title", .string("Root")), ("project", .string("/work/root")), ("assignee", .string("builder"))]), notificationKeyID: "A")
        let delegated = try await rig.delegation.delegate(taskID: parent.id, agent: "fixer", title: "Partner work", instructions: "Inspect the data.", project: "/work/partner", by: "taskagent:builder")
        let child = try await rig.record(try delegated["task"].requireString("task"))
        XCTAssertEqual(child.value["parentTaskId"].string, parent.id); XCTAssertEqual(child.value["hops"].number, 1); XCTAssertEqual(child.value["notificationKeyId"].string, "A"); XCTAssertEqual(child.value["requestedBy"].string, "taskagent:builder")
        let count = try await rig.store.all().count
        await E.error("only its own") { _ = try await rig.delegation.delegate(taskID: parent.id, agent: "fixer", title: "Forged", instructions: "Wrong", project: nil, by: "taskagent:fixer") }
        let after = try await rig.store.all().count; XCTAssertEqual(after, count)
    } }
    func testAssignedCRMWorkerDelegatesUsingOwnIdentityAndRootChain() async throws { try await F.withFixture { rig in
        let parent = try await rig.give("u-builder", id: "parent")
        _ = try await rig.delegation.delegate(taskID: parent, agent: "tester", title: "Tests", instructions: "Run checks", project: "/work/child", by: "taskagent:builder")
        let request = await rig.probe.posts.first { $0["type"].string == "task.delegate_requested" }; XCTAssertEqual(request?["actor"].string, "u-builder")
        let created = try await rig.api.call("create", keyID: F.key, input: F.obj([("eventId", .string("child")), ("externalTaskId", .string("child")), ("parentExternalTaskId", .string("parent")), ("assignee", .string("u-tester")), ("requestedBy", .string("u-builder")), ("title", .string("Tests"))]))
        XCTAssertTrue(created.ok); let child = try await rig.record(F.key + ":child"); XCTAssertEqual(child.value["parentTaskId"].string, parent); XCTAssertEqual(child.value["notificationKeyId"].string, F.key)
        let forged = try await rig.api.call("create", keyID: F.key, input: F.obj([("eventId", .string("forged")), ("externalTaskId", .string("forged")), ("parentExternalTaskId", .string("parent")), ("assignee", .string("u-tester")), ("requestedBy", .string("u-tester")), ("title", .string("Forged"))]))
        XCTAssertFalse(forged.ok); XCTAssertEqual(forged.code, "not_allowed")
    } }
    func testLocalAndCRMHandOffLimitsStillApply() async throws { try await F.withFixture { rig in
        let parent = try await rig.local.create(F.obj([("title", .string("Root")), ("project", .string("/work/root")), ("assignee", .string("hoot"))]))
        _ = try await rig.store.update(parent.id, patch: F.obj([("hops", .number(3))]))
        await E.error("hand-off limit") { _ = try await rig.delegation.delegate(taskID: parent.id, agent: "fixer", title: "Too far", instructions: "No", project: nil) }
        let crm = try await rig.give("u-builder", id: "deep"); _ = try await rig.store.update(crm, patch: F.obj([("hops", .number(3))]))
        await E.error("hand-off limit") { _ = try await rig.delegation.delegate(taskID: crm, agent: "tester", title: "Too far", instructions: "No", project: nil, by: "taskagent:builder") }
    } }
    func testChildFinishReportsBackToExactParentSession() async throws { try await F.withFixture { rig in
        let parent = try await rig.local.create(F.obj([("title", .string("Root")), ("project", .string("/work/root")), ("assignee", .string("builder"))]))
        _ = try await rig.delegation.delegate(taskID: parent.id, agent: "tester", title: "Tests", instructions: "Check", project: "/work/child", by: "taskagent:builder")
        try await rig.finish("s-2", answer: "40 pass")
        let sends = await rig.probe.sends; XCTAssertEqual(sends.last?["sessionId"].string, "s-1"); XCTAssertTrue(sends.last?["text"].string?.contains("40 pass") == true)
    } }
    private static func reviewer(_ rig: F) async throws {
        let prior = try BackendRoutinesTaskEngineParityUnwrap(try await rig.config.agent("builder"))
        _ = try await rig.config.saveAgent(prior.setting("reviewerAgent", .string("fixer")))
    }
    private static let workspace: @Sendable (BackendTaskRecord) async throws -> String = { task in task.value["reviewOfTaskId"].string == nil ? task.project : task.project + "/review-workspace" }
    func testReviewerIsActualChildAgentAndPassNeedsEvidence() async throws { try await F.withFixture(workspace: Self.workspace) { rig in
        try await Self.reviewer(rig)
        let parent = try await rig.local.create(F.obj([("title", .string("Fix")), ("project", .string("/work/root")), ("assignee", .string("builder"))]), notificationKeyID: "A")
        try await rig.finish("s-1", answer: "Fixed"); try await rig.engine.pump()
        let saved = try await rig.record(parent.id), child = try await rig.record(try saved.value["reviewerTaskId"].requireString("reviewerTaskId")), starts = await rig.probe.launches
        XCTAssertEqual(child.agentID, "fixer"); XCTAssertEqual(child.value["reviewOfTaskId"].string, parent.id); XCTAssertEqual(child.value["notificationKeyId"].string, "A"); XCTAssertEqual(starts.count, 2); XCTAssertTrue(starts[1].brief.contains("tasks_review")); XCTAssertEqual(starts[1].cwd, "/work/root/review-workspace")
        await E.error("name its evidence") { try await BackendTaskActor.withActor("taskagent:fixer") { try await rig.engine.review(parent.id, pass: true, evidence: [], reasons: "") } }
        let unchanged = try await rig.record(parent.id); XCTAssertEqual(unchanged.value["result"]["verified"], .bool(false))
        try await BackendTaskActor.withActor("taskagent:fixer") { try await rig.engine.review(parent.id, pass: true, evidence: ["Tests: 40 passed"], reasons: "") }
        try await rig.finish("s-2", answer: "Pass, tests checked")
        let final = try await rig.record(parent.id), review = try await rig.record(child.id)
        XCTAssertEqual(final.value["result"]["verified"], .bool(true)); XCTAssertEqual(final.value["crmStatus"].string, "Done"); XCTAssertEqual(review.value["result"]["verified"], .bool(true))
    } }
    func testForgedAndStaleReviewerCannotChangeResultOrStatus() async throws { try await F.withFixture(workspace: Self.workspace) { rig in
        try await Self.reviewer(rig)
        let id = try await rig.give("u-builder"); try await rig.finish("s-1"); try await rig.engine.pump()
        let before = try await rig.record(id).value
        await E.error("assigned reviewer") { try await BackendTaskActor.withActor("taskagent:tester") { try await rig.engine.verify(id, verified: true, note: "Forged evidence") } }
        let denied = try await rig.record(id).value; XCTAssertEqual(denied["result"], before["result"]); XCTAssertEqual(denied["crmStatus"], before["crmStatus"]); XCTAssertEqual(denied["reviewVerdict"], before["reviewVerdict"])
        _ = try await rig.store.update(id, patch: F.obj([("lastTurn", .string("newer-turn"))]))
        await E.error("assigned reviewer") { try await BackendTaskActor.withActor("taskagent:fixer") { try await rig.engine.verify(id, verified: true, note: "Stale evidence") } }
        let stale = try await rig.record(id).value; XCTAssertEqual(stale["result"], before["result"]); XCTAssertEqual(stale["crmStatus"], before["crmStatus"])
    } }
    func testReviewerFailReturnsFixesToWorkerAndCompletesReviewChild() async throws { try await F.withFixture(workspace: Self.workspace) { rig in
        try await Self.reviewer(rig)
        let parent = try await rig.local.create(F.obj([("title", .string("Fix")), ("project", .string("/work/root")), ("assignee", .string("builder"))]))
        try await rig.finish("s-1"); try await rig.engine.pump()
        let before = try await rig.record(parent.id), childID = try before.value["reviewerTaskId"].requireString("reviewerTaskId")
        try await BackendTaskActor.withActor("taskagent:fixer") { try await rig.engine.review(parent.id, pass: false, evidence: ["Read login test"], reasons: "The empty input still crashes") }
        let failed = try await rig.record(parent.id), sends = await rig.probe.sends
        XCTAssertTrue(failed.value["result"].isNullish); XCTAssertEqual(failed.value["reviewVerdict"]["pass"], .bool(false)); XCTAssertEqual(failed.value["crmStatus"].string, "Working on it")
        XCTAssertEqual(sends.last?["sessionId"].string, "s-1"); XCTAssertTrue(sends.last?["text"].string?.contains("empty input still crashes") == true)
        try await rig.finish("s-2", answer: "Fail, returned fixes")
        let reviewed = try await rig.record(childID); XCTAssertEqual(reviewed.value["result"]["verified"], .bool(true))
    } }
    func testCancelledParentRejectsLateReviewerWithoutChangingResultOrStatus() async throws { try await F.withFixture(workspace: Self.workspace) { rig in
        try await Self.reviewer(rig)
        let id = try await rig.give("u-builder"); try await rig.finish("s-1"); try await rig.engine.pump()
        try await rig.engine.cancel(id, reason: "No longer needed")
        let before = try await rig.record(id).value
        await E.error("assigned reviewer") { try await BackendTaskActor.withActor("taskagent:fixer") { try await rig.engine.verify(id, verified: true, note: "Late verdict") } }
        let after = try await rig.record(id).value; XCTAssertEqual(after["result"], before["result"]); XCTAssertEqual(after["crmStatus"], before["crmStatus"]); XCTAssertEqual(after["reviewVerdict"], before["reviewVerdict"]); XCTAssertEqual(after["stopped"], .bool(true))
    } }
    func testReviewerCannotCreateChildPastHandOffLimit() async throws { try await F.withFixture(workspace: Self.workspace) { rig in
        try await Self.reviewer(rig)
        let id = try await rig.give("u-builder"); _ = try await rig.store.update(id, patch: F.obj([("hops", .number(3))]))
        try await rig.finish("s-1")
        let task = try await rig.record(id), starts = await rig.probe.launches, blockers = await rig.probe.comments("blocker")
        XCTAssertTrue(task.value["reviewerTaskId"].isNullish); XCTAssertEqual(task.value["result"]["verified"], .bool(false)); XCTAssertEqual(starts.count, 1)
        XCTAssertTrue(blockers.last?["body"].string?.contains("hand-off limit") == true)
    } }
    func testReviewerWithoutVerdictLeavesParentUnverifiedAndVisibleBlocker() async throws { try await F.withFixture(workspace: Self.workspace) { rig in
        try await Self.reviewer(rig)
        let parent = try await rig.local.create(F.obj([("title", .string("Fix")), ("project", .string("/work/root")), ("assignee", .string("builder"))]))
        try await rig.finish("s-1"); try await rig.engine.pump(); try await rig.finish("s-2", answer: "Looks good")
        let saved = try await rig.record(parent.id); XCTAssertEqual(saved.value["result"]["verified"], .bool(false)); XCTAssertEqual(saved.value["crmStatus"].string, "Stuck")
        let notes = try await rig.notes(parent.id); XCTAssertTrue(notes.contains { $0.contains("without recording a verdict") })
        let starts = await rig.probe.launches; XCTAssertEqual(starts.count, 2)
    } }
    func testUntilCloseSurvivesTimeRoomAndReviewerUsesSeparateWorkspace() async throws { try await F.withFixture(workspace: Self.workspace) { rig in
        try await Self.reviewer(rig); let agent = try BackendRoutinesTaskEngineParityUnwrap(try await rig.config.agent("builder")); _ = try await rig.config.saveAgent(agent.setting("keepAliveUntilClose", .bool(true)))
        let id = try await rig.give("u-builder"); try await rig.finish("s-1"); try await rig.engine.pump(); await rig.move(25 * 60 * 60_000)
        let saved = try await rig.record(id), stops = await rig.probe.stops, starts = await rig.probe.launches
        XCTAssertEqual(saved.sessionID, "s-1"); XCTAssertEqual(saved.value["keepAliveUntilClose"], .bool(true)); XCTAssertFalse(stops.contains("s-1")); XCTAssertEqual(starts.count, 2)
        let read = try await rig.api.snapshot(saved); XCTAssertEqual(read["keepAliveUntilClose"], .bool(true))
        try await rig.engine.closeSession(id); let closed = try await rig.record(id); XCTAssertNil(closed.sessionID); XCTAssertEqual(closed.value["keepAliveUntilClose"], .bool(false))
    } }
}
