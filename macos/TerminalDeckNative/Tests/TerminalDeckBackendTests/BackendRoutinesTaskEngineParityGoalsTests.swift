import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendRoutinesTaskEngineParityGoalsTests: XCTestCase {
    private typealias F = BackendRoutinesTaskEngineParityFixture
    private typealias E = BackendRoutinesTaskEngineParityExpect
    private static func goal(_ rig: F, title: String = "Ship 0.18", parent: String? = nil, description: String = "") async throws -> NativeRPCValue { try await rig.goals.save(F.obj([("title", .string(title)), ("parentId", parent.map(NativeRPCValue.string) ?? .null), ("description", .string(description))])) }
    private static func bindKnowledge(_ rig: F) async throws -> NativeRPCSubscription {
        let subscribe = try XCTUnwrap(BackendRoutinesTaskEngineParityBindings.knowledgeEvents)
        let service = try XCTUnwrap(rig.knowledgeService)
        return try await subscribe(service) { await rig.probe.noteKnowledge($0) }
    }
    private static func workspace(_ task: BackendTaskRecord) async throws -> String {
        if task.project == "/work/broken" { throw NativeRPCError(code: "workspace", message: "the repository has no commits yet") }
        return task.value["useWorkspace"].bool == true ? "/work/.workspaces/" + String(task.id.dropFirst(6).prefix(8)) : task.project
    }
    func testGoalChainTaskContextAndProjectKnowledgeInBrief() async throws { try await F.withFixture(knowledge: true) { rig in
        let root = try await Self.goal(rig, title: "Fortnightly Mac releases", description: "One every two weeks."), release = try await Self.goal(rig, parent: root["id"].string, description: "Mac only.")
        let task = try await rig.local.create(F.obj([("title", .string("Fix sign-in")), ("instructions", .string("It throws on an empty password.")), ("project", .string("/work/app")), ("goalId", release["id"])]))
        _ = try await rig.store.update(task.id, patch: F.obj([("detail", F.obj([("comments", .array([F.obj([("id", .string("c1")), ("authorUserId", .string("me")), ("body", .string("Keep the old error text.")), ("at", .number(1))])]))]))])); _ = try await rig.local.update(task.id, input: F.obj([("assignee", .string("builder"))]))
        let start = try BackendRoutinesTaskEngineParityUnwrap(await rig.probe.launches.first), asked = await rig.probe.knowledgeAsked
        XCTAssertTrue(start.brief.contains("## The goal this serves")); let broad = try XCTUnwrap(start.brief.range(of: "Fortnightly Mac releases")), narrow = try XCTUnwrap(start.brief.range(of: "Ship 0.18")); XCTAssertLessThan(broad.lowerBound, narrow.lowerBound)
        XCTAssertTrue(start.brief.contains("It throws on an empty password.")); XCTAssertTrue(start.brief.contains("- You: Keep the old error text.")); XCTAssertTrue(start.brief.contains("## What is known about this project\n\n- This project builds with pnpm (verified).")); XCTAssertEqual(asked, [F.obj([("project", .string("/work/app")), ("query", .string("Fix sign-in\nIt throws on an empty password.")), ("goalId", release["id"])])])
    } }
    func testGoalBriefDelegatedEventClause() async throws { try await F.withFixture(knowledge: true) { rig in
        let lease = try await Self.bindKnowledge(rig); defer { lease.cancel() }; let release = try await Self.goal(rig)
        let task = try await rig.local.create(F.obj([("title", .string("Fix sign-in")), ("instructions", .string("It throws on an empty password.")), ("project", .string("/work/app")), ("goalId", release["id"]), ("assignee", .string("builder"))]))
        let event = try BackendRoutinesTaskEngineParityUnwrap(await rig.probe.knowledgeEvents.first)
        for (key, value) in [("kind", NativeRPCValue.string("delegated")), ("project", .string("/work/app")), ("taskId", .string(task.id)), ("goalId", release["id"]), ("agentId", .string("builder")), ("sessionId", .string("s-1"))] { XCTAssertEqual(event[key], value) }
    } }
    func testAbsentGoalAndKnowledgeSeamsKeepPriorExecution() async throws { try await F.withFixture(goalsEnabled: false) { rig in
        let goal = try await Self.goal(rig); let task = try await rig.local.create(F.obj([("title", .string("Fix sign-in")), ("project", .string("/work/app")), ("goalId", goal["id"]), ("assignee", .string("builder"))])); let start = try BackendRoutinesTaskEngineParityUnwrap(await rig.probe.launches.first)
        XCTAssertEqual(start.cwd, "/work/app"); XCTAssertFalse(start.brief.contains("## The goal this serves")); XCTAssertFalse(start.brief.contains("What is known")); try await E.fields(rig, task.id, F.obj([("process", .string("running"))]))
    } }
    func testDelegatedLocalPartInheritsWholeGoal() async throws { try await F.withFixture { rig in
        let goal = try await Self.goal(rig), parent = try await rig.local.create(F.obj([("title", .string("Ship it")), ("project", .string("/work/app")), ("assignee", .string("hoot")), ("goalId", goal["id"])])); _ = try await rig.delegation.delegate(taskID: parent.id, agent: "builder", title: "Fix the bug", instructions: "Now.", project: nil)
        let all = try await rig.store.all(), child = try XCTUnwrap(all.first { $0.value["title"].string == "Fix the bug" }); XCTAssertEqual(child.value["goalId"], goal["id"])
    } }
    func testWorkspaceFolderFallbackAndPreparationFailure() async throws { try await F.withFixture(workspace: Self.workspace) { rig in
        let own = try await rig.local.create(F.obj([("title", .string("In a worktree")), ("project", .string("/work/a")), ("assignee", .string("builder")), ("useWorkspace", .bool(true))])), shared = try await rig.local.create(F.obj([("title", .string("In the checkout")), ("project", .string("/work/b")), ("assignee", .string("fixer"))])), broken = try await rig.local.create(F.obj([("title", .string("Cannot")), ("project", .string("/work/broken")), ("assignee", .string("tester")), ("useWorkspace", .bool(true))]))
        let starts = await rig.probe.launches, notes = try await rig.notes(broken.id); XCTAssertEqual(starts.map(\.cwd), ["/work/.workspaces/" + String(own.id.dropFirst(6).prefix(8)), "/work/b"]); XCTAssertEqual(shared.value["useWorkspace"], .missing); XCTAssertTrue(notes.contains { $0.contains("Could not prepare the folder Tester works in: the repository has no commits yet") })
    } }
    func testCheckRunsInActualWorkspace() async throws { try await F.withFixture(workspace: Self.workspace) { rig in
        _ = try await rig.local.create(F.obj([("title", .string("Tested")), ("project", .string("/work/a")), ("assignee", .string("tester")), ("useWorkspace", .bool(true))])); try await rig.finish("s-1", answer: "Done."); let checks = await rig.probe.checked; XCTAssertTrue(checks.first?["cwd"].string?.hasPrefix("/work/.workspaces/") == true)
    } }
    func testFinishedThenVerifiedKnowledgeTimelineAndEvidence() async throws { try await F.withFixture(knowledge: true) { rig in
        let lease = try await Self.bindKnowledge(rig); defer { lease.cancel() }; let task = try await rig.local.create(F.obj([("title", .string("Run the suite")), ("project", .string("/work/app")), ("assignee", .string("tester"))])); try await rig.finish("s-1", answer: "All green.")
        let events = await rig.probe.knowledgeEvents; XCTAssertEqual(events.compactMap { $0["kind"].string }, ["delegated", "finished", "verified"]); XCTAssertEqual(events.last?["taskId"], .string(task.id)); XCTAssertEqual(events.last?["evidence"], .array([.string("check: npm test")]))
    } }
    func testOnlyWorkerToWorkerAssignmentEmitsReassigned() async throws { try await F.withFixture(knowledge: true) { rig in
        let lease = try await Self.bindKnowledge(rig); defer { lease.cancel() }; let task = try await rig.local.create(F.obj([("title", .string("Fix it")), ("project", .string("/work/app"))])); _ = try await rig.local.update(task.id, input: F.obj([("assignee", .string("builder"))])); _ = try await rig.local.update(task.id, input: F.obj([("assignee", .string("fixer"))]))
        let events = await rig.probe.knowledgeEvents; XCTAssertEqual(events.compactMap { $0["kind"].string }, ["delegated", "reassigned", "delegated"]); XCTAssertEqual(events.dropFirst().first?["summary"], .string("From Builder to Fixer."))
    } }
    func testKnowledgeLookupFailureNeverStopsWork() async throws { try await F.withFixture(knowledgeThrows: true) { rig in
        let task = try await rig.local.create(F.obj([("title", .string("Fix it")), ("project", .string("/work/app")), ("assignee", .string("builder"))])); let start = try BackendRoutinesTaskEngineParityUnwrap(await rig.probe.launches.first); XCTAssertFalse(start.brief.contains("What is known")); try await E.fields(rig, task.id, F.obj([("process", .string("running"))]))
    } }
    func testKnowledgeEventFailureNeverStopsWork() async throws { try await F.withFixture(knowledge: true, knowledgeThrows: true, knowledgeEventFailure: true) { rig in
        let task = try await rig.local.create(F.obj([("title", .string("Fix it")), ("project", .string("/work/app")), ("assignee", .string("builder"))])); try await E.fields(rig, task.id, F.obj([("process", .string("running"))])); let start = try BackendRoutinesTaskEngineParityUnwrap(await rig.probe.launches.first); XCTAssertFalse(start.brief.contains("What is known"))
    } }
    func testBlockedTaskQueuesUntilDependencyIsDone() async throws { try await F.withFixture { rig in
        let first = try await rig.local.create(F.obj([("title", .string("Build the API")), ("project", .string("/work/api"))])), second = try await rig.local.create(F.obj([("title", .string("Build the page")), ("project", .string("/work/web"))])); _ = try await rig.store.update(second.id, patch: F.obj([("detail", F.obj([("dependencies", .array([F.obj([("kind", .string("blocked_by")), ("otherTaskId", .string(first.id)), ("at", .number(1))])]))]))]))
        _ = try await rig.local.update(second.id, input: F.obj([("assignee", .string("fixer"))])); _ = try await rig.local.update(first.id, input: F.obj([("assignee", .string("builder"))])); let before = await rig.probe.launches; XCTAssertEqual(before.map(\.cwd), ["/work/api"]); try await E.fields(rig, second.id, F.obj([("process", .string("queued"))]))
        _ = try await rig.local.update(first.id, input: F.obj([("status", .string("Done"))])); let after = await rig.probe.launches; XCTAssertEqual(after.map(\.cwd), ["/work/api", "/work/web"])
    } }
    func testQuietBoundaryStallsExactlyAtFifteenMinutesAndClearsOnWork() async throws { try await F.withFixture { rig in
        let task = try await rig.local.create(F.obj([("title", .string("Fix it")), ("project", .string("/work/app")), ("assignee", .string("builder"))])); XCTAssertEqual(rig.clock.nextDue, rig.clock.now() + 900_000)
        await rig.move(899_999); let before = try await rig.record(task.id); XCTAssertTrue(before.value["stalled"].isNullish); await rig.move(1); let stalled = try await rig.record(task.id), notes = try await rig.notes(task.id)
        XCTAssertEqual(stalled.value["stalled"]["reason"], .string("quiet")); XCTAssertEqual(stalled.value["crmStatus"], .string("Stuck")); XCTAssertTrue(notes.contains { $0.hasPrefix("builder/blocker: Stalled: No sign of work for 15 minutes") }); XCTAssertEqual(rig.clock.nextDue, rig.clock.now() + 45 * 60_000)
        try await rig.engine.noteStatus(sessionID: "s-1", status: .working); let again = try await rig.record(task.id), againNotes = try await rig.notes(task.id); XCTAssertTrue(again.value["stalled"].isNullish); XCTAssertEqual(again.value["crmStatus"], .string("Working on it")); XCTAssertTrue(againNotes.contains("builder/progress: Working again."))
    } }
    func testQuietStallKnowledgeEventClause() async throws { try await F.withFixture(knowledge: true) { rig in
        let lease = try await Self.bindKnowledge(rig); defer { lease.cancel() }; let task = try await rig.local.create(F.obj([("title", .string("Fix it")), ("project", .string("/work/app")), ("assignee", .string("builder"))])); await rig.move(900_000); let events = await rig.probe.knowledgeEvents; XCTAssertTrue(events.contains { $0["kind"].string == "stalled" && $0["taskId"].string == task.id })
    } }
    func testReplyRestartsQuietClockForKeptOpenSession() async throws { try await F.withFixture { rig in
        let task = try await rig.local.create(F.obj([("title", .string("Fix it")), ("project", .string("/work/app")), ("assignee", .string("builder"))])); try await rig.finish("s-1"); await rig.move(20 * 60_000); _ = try await rig.local.reply(task.id, text: "Also the logout button.")
        XCTAssertEqual(rig.clock.nextDue, rig.clock.now() + 900_000); await rig.move(60_000); let saved = try await rig.record(task.id); XCTAssertTrue(saved.value["stalled"].isNullish)
    } }
    func testWorkingWorkerHasNoStallDeadline() async throws { try await F.withFixture { rig in
        let task = try await rig.local.create(F.obj([("title", .string("Long build")), ("project", .string("/work/app")), ("assignee", .string("builder"))])); try await rig.engine.noteStatus(sessionID: "s-1", status: .working)
        XCTAssertEqual(rig.clock.nextDue, rig.clock.now() + 60 * 60_000); await rig.move(3 * 900_000); let saved = try await rig.record(task.id); XCTAssertTrue(saved.value["stalled"].isNullish)
    } }
    func testUnfinishedExitStallsHandsToHumanAndTellsPlanner() async throws { try await F.withFixture { rig in
        let task = try await rig.local.create(F.obj([("title", .string("Fix it")), ("project", .string("/work/app"))])); _ = try await rig.store.update(task.id, patch: F.obj([("requestedBy", .string("hoot"))])); _ = try await rig.local.update(task.id, input: F.obj([("assignee", .string("builder"))])); await rig.probe.exit("s-1", code: 1); try await rig.engine.noteExit(sessionID: "s-1", exitCode: 1)
        let saved = try await rig.record(task.id), told = await rig.probe.told; XCTAssertEqual(saved.value["stalled"]["reason"], .string("exited")); XCTAssertEqual(saved.assigneeKind, "human"); XCTAssertTrue(told.last?.contains("has stalled") == true); XCTAssertTrue(told.last?.contains("tasks_retry") == true)
    } }
    func testUnfinishedExitKnowledgeEventClause() async throws { try await F.withFixture(knowledge: true) { rig in
        let lease = try await Self.bindKnowledge(rig); defer { lease.cancel() }; let task = try await rig.local.create(F.obj([("title", .string("Fix it")), ("project", .string("/work/app")), ("assignee", .string("builder"))])); await rig.probe.exit("s-1", code: 1); try await rig.engine.noteExit(sessionID: "s-1", exitCode: 1); let events = await rig.probe.knowledgeEvents; XCTAssertTrue(events.contains { $0["kind"].string == "stalled" && $0["taskId"].string == task.id })
    } }
    func testRetryIsFreshSameAgentAndBriefWithReason() async throws { try await F.withFixture { rig in
        let task = try await rig.local.create(F.obj([("title", .string("Fix it")), ("instructions", .string("The login bug.")), ("project", .string("/work/app")), ("assignee", .string("builder"))])); await rig.probe.exit("s-1", code: 1); try await rig.engine.noteExit(sessionID: "s-1", exitCode: 1); try await rig.engine.retry(task.id, note: "Run the migration first.")
        let start = try BackendRoutinesTaskEngineParityUnwrap(await rig.probe.launches.last), saved = try await rig.record(task.id); XCTAssertEqual(start.cwd, "/work/app"); XCTAssertNil(start.resume); XCTAssertTrue(start.brief.contains("The login bug.")); XCTAssertTrue(start.brief.contains("## Tried again")); XCTAssertTrue(start.brief.contains("Run the migration first.")); XCTAssertTrue(saved.value["stalled"].isNullish); XCTAssertEqual(saved.agentID, "builder"); XCTAssertEqual(saved.value["retry"]["count"], .number(1))
    } }
    func testHootReviewRequiresEvidenceAndMarksDone() async throws { try await F.withFixture { rig in
        let task = try await rig.local.create(F.obj([("title", .string("Fix it")), ("project", .string("/work/app"))])); _ = try await rig.store.update(task.id, patch: F.obj([("requestedBy", .string("hoot"))])); _ = try await rig.local.update(task.id, input: F.obj([("assignee", .string("builder"))])); try await rig.finish("s-1", answer: "Fixed the login bug.")
        let told = await rig.probe.told, before = try await rig.record(task.id); XCTAssertTrue(told.last?.contains("tasks_review") == true); XCTAssertEqual(before.assigneeKind, "agent"); await E.error("evidence") { try await rig.engine.review(task.id, pass: true, evidence: [], reasons: "") }
        try await rig.engine.review(task.id, pass: true, evidence: ["src/login.ts", "npm test: 120 passed"], reasons: ""); let saved = try await rig.record(task.id); XCTAssertEqual(saved.value["crmStatus"], .string("Done")); XCTAssertEqual(saved.value["result"]["verified"], .bool(true))
    } }
    func testHootReviewVerifiedEventRetainsEvidence() async throws { try await F.withFixture(knowledge: true) { rig in
        let lease = try await Self.bindKnowledge(rig); defer { lease.cancel() }; let task = try await rig.local.create(F.obj([("title", .string("Fix it")), ("project", .string("/work/app")), ("assignee", .string("builder"))])); try await rig.finish("s-1"); try await rig.engine.review(task.id, pass: true, evidence: ["src/login.ts", "npm test: 120 passed"], reasons: ""); let events = await rig.probe.knowledgeEvents; XCTAssertEqual(events.last?["kind"], .string("verified")); XCTAssertEqual(events.last?["evidence"], .array([.string("src/login.ts"), .string("npm test: 120 passed")]))
    } }
    func testRejectedReviewReturnsReasonsToSameConversation() async throws { try await F.withFixture { rig in
        let task = try await rig.local.create(F.obj([("title", .string("Fix it")), ("project", .string("/work/app")), ("assignee", .string("builder"))])); try await rig.finish("s-1"); let human = try await rig.record(task.id); XCTAssertEqual(human.assigneeKind, "human")
        try await rig.engine.review(task.id, pass: false, evidence: ["src/login.ts"], reasons: "The empty password still throws."); let sends = await rig.probe.sends, saved = try await rig.record(task.id); XCTAssertTrue(sends.last?["text"].string?.contains("The empty password still throws.") == true); XCTAssertEqual(sends.last?["sessionId"], .string("s-1")); XCTAssertEqual(saved.agentID, "builder"); XCTAssertEqual(saved.value["result"], .null); XCTAssertEqual(saved.value["crmStatus"], .string("Working on it")); await E.error("not finished") { try await rig.engine.review(task.id, pass: true, evidence: ["x"], reasons: "") }
    } }
    func testRejectedReviewKnowledgeEventClause() async throws { try await F.withFixture(knowledge: true) { rig in
        let lease = try await Self.bindKnowledge(rig); defer { lease.cancel() }; let task = try await rig.local.create(F.obj([("title", .string("Fix it")), ("project", .string("/work/app")), ("assignee", .string("builder"))])); try await rig.finish("s-1"); try await rig.engine.review(task.id, pass: false, evidence: ["src/login.ts"], reasons: "The empty password still throws."); let events = await rig.probe.knowledgeEvents; XCTAssertEqual(events.last?["kind"], .string("rejected")); XCTAssertEqual(events.last?["summary"], .string("The empty password still throws."))
    } }
}
