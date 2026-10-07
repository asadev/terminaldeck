import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

enum BackendRoutinesTaskEngineParityExpect {
    static func fields(_ rig: BackendRoutinesTaskEngineParityFixture, _ id: String, _ wanted: NativeRPCValue) async throws {
        let value = try await rig.record(id).value
        for field in wanted.fields ?? [] { XCTAssertEqual(value[field.key], field.value, field.key) }
    }
    static func statuses(_ rig: BackendRoutinesTaskEngineParityFixture, _ wanted: [String]) async { let actual = await rig.probe.statuses(); XCTAssertEqual(actual, wanted) }
    static func error(_ fragment: String, operation: @escaping @Sendable () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected refusal: " + fragment) } catch { XCTAssertTrue(error.localizedDescription.contains(fragment), error.localizedDescription) }
    }
}

final class BackendRoutinesTaskEngineParityTests: XCTestCase {
    private typealias F = BackendRoutinesTaskEngineParityFixture
    private typealias E = BackendRoutinesTaskEngineParityExpect
    func testCodingAgentAccountModelAndCRMActor() async throws { try await F.withFixture { rig in
        let id = try await rig.give("u-builder", id: "one"), starts = await rig.probe.launches, controls = await rig.probe.controls, comments = await rig.probe.comments("progress")
        let start = try XCTUnwrap(starts.first); XCTAssertEqual(start.cwd, "/work/app"); XCTAssertEqual(start.agent["provider"], .string("claude")); XCTAssertEqual(start.agent["account"], .string("Work")); XCTAssertEqual(start.task.value["externalTaskId"], .string("one")); XCTAssertTrue(start.brief.contains("Fix the login bug."))
        XCTAssertEqual(controls, [F.obj([("sessionId", .string("s-1")), ("control", .string("model")), ("value", .string("opus"))])]); await E.statuses(rig, ["Working on it"])
        XCTAssertEqual(comments.first?["actor"], .string("u-builder")); XCTAssertEqual(comments.first?["body"], .string("Builder started on this.")); try await E.fields(rig, id, F.obj([("process", .string("running")), ("sessionId", .string("s-1")), ("conversationId", .string("conv-1"))]))
    } }
    func testOneTaskPerAgentThenNextAfterFinish() async throws { try await F.withFixture { rig in
        let first = try await rig.give("u-builder", id: "a", patch: F.obj([("project", .string("/work/a"))])), second = try await rig.give("u-builder", id: "b", patch: F.obj([("project", .string("/work/b"))]))
        let before = await rig.probe.launches; XCTAssertEqual(before.count, 1); try await E.fields(rig, second, F.obj([("process", .string("queued"))]))
        try await rig.finish("s-1"); try await rig.engine.pump(); let after = await rig.probe.launches, saved = try await rig.record(first)
        XCTAssertEqual(after.map(\.cwd), ["/work/a", "/work/b"]); XCTAssertNotNil(saved.value["keepOpenUntil"].number)
    } }
    func testDoneOnlyAfterPassingCheckAndFailedOutputIsStuck() async throws { try await F.withFixture { rig in
        let good = try await rig.give("u-tester", id: "good", patch: F.obj([("project", .string("/work/a"))])); try await rig.finish("s-1", answer: "All green.")
        await E.statuses(rig, ["Working on it", "Done"]); let goodValue = try await rig.record(good).value, complete = await rig.probe.comments("completion"); XCTAssertEqual(goodValue["result"]["verified"], .bool(true)); XCTAssertEqual(goodValue["result"]["answer"], .string("All green.")); XCTAssertTrue(complete.first?["body"].string?.contains("the check passed") == true)
        await rig.probe.checkResult(ok: false, output: "2 tests failed: login.spec.ts"); let bad = try await rig.give("u-tester", id: "bad", patch: F.obj([("project", .string("/work/b"))])); try await rig.finish("s-2", answer: "Done, I think.")
        await E.statuses(rig, ["Working on it", "Done", "Working on it", "Stuck"]); let badValue = try await rig.record(bad).value, blockers = await rig.probe.comments("blocker"); XCTAssertEqual(badValue["result"]["verified"], .bool(false)); XCTAssertTrue(blockers.last?["body"].string?.contains("2 tests failed: login.spec.ts") == true)
    } }
    func testHootChecksUncheckedCRMTaskAndVerdictCompletesIt() async throws { try await F.withFixture { rig in
        let id = try await rig.give("u-builder"); try await rig.finish("s-1", answer: "The login bug is fixed."); await E.statuses(rig, ["Working on it"])
        let comments = await rig.probe.comments("completion"), told = await rig.probe.told; XCTAssertTrue(comments.first?["body"].string?.contains("Hoot is checking it") == true); XCTAssertTrue(told.last?.contains("tasks_verify") == true)
        try await rig.engine.verify(id, verified: true, note: "Checked the diff and the tests."); await E.statuses(rig, ["Working on it", "Done"])
        let last = await rig.probe.comments("completion").last; XCTAssertEqual(last?["actor"], .string("u-hoot")); XCTAssertEqual(last?["body"], .string("Checked the diff and the tests."))
    } }
    func testFinishedTurnIsHandledOnce() async throws { try await F.withFixture { rig in
        _ = try await rig.give("u-builder"); try await rig.finish("s-1"); try await rig.engine.noteFinishedTurn(sessionID: "s-1", turnID: "turn-1", answer: "Fixed.")
        let comments = await rig.probe.comments("completion"); XCTAssertEqual(comments.count, 1)
    } }
    func testQuestionAndAllowedReplyUseTheSameSession() async throws { try await F.withFixture { rig in
        let id = try await rig.give("u-builder", id: "q"); try await rig.engine.noteStatus(sessionID: "s-1", status: .working); try await rig.engine.noteNeedsInput(sessionID: "s-1", screen: "Allow this edit? 1. Yes  2. No")
        let questions = await rig.probe.comments("question"); XCTAssertTrue(questions.first?["body"].string?.contains("Allow this edit?") == true); await E.statuses(rig, ["Working on it", "Stuck"])
        let answered = try await rig.api.call("comment", keyID: F.key, input: F.obj([("eventId", .string("c-1")), ("externalTaskId", .string("q")), ("externalCommentId", .string("crm-c-1")), ("author", .string("u-asad")), ("body", .string("Yes, go ahead."))])); XCTAssertTrue(answered.ok); XCTAssertEqual(answered.value["outcome"], .string("answered"))
        let sent = await rig.probe.sends; XCTAssertEqual(sent, [F.obj([("sessionId", .string("s-1")), ("text", .string("Yes, go ahead."))])]); await E.statuses(rig, ["Working on it", "Stuck", "Working on it"]); let saved = try await rig.record(id); XCTAssertEqual(saved.sessionID, "s-1")
    } }
    func testKeepOpenDeadlineClosesAndResumesExactConversation() async throws { try await F.withFixture { rig in
        let id = try await rig.give("u-builder", id: "kept"); try await rig.finish("s-1"); let kept = try await rig.record(id); XCTAssertEqual(kept.value["keepOpenUntil"].number, rig.clock.now() + 30 * 60_000)
        await rig.move(30 * 60_000); let stopped = await rig.probe.stops; XCTAssertEqual(stopped, ["s-1"]); try await E.fields(rig, id, F.obj([("sessionId", .null), ("conversationId", .string("conv-1")), ("process", .string("exited"))])); XCTAssertEqual(rig.clock.pending, 0)
        let reply = try await rig.api.call("comment", keyID: F.key, input: F.obj([("eventId", .string("c-2")), ("externalTaskId", .string("kept")), ("externalCommentId", .string("crm-c-2")), ("author", .string("u-asad")), ("body", .string("Also fix the logout button.")), ("mentions", .array([.string("u-builder")]))])); XCTAssertTrue(reply.ok)
        let resumed = await rig.probe.launches.last; XCTAssertEqual(resumed?.resume, "conv-1"); XCTAssertEqual(resumed?.cwd, "/work/app"); XCTAssertTrue(resumed?.brief.contains("Also fix the logout button.") == true)
    } }
    func testWorkingAgainClearsKeepOpenClock() async throws { try await F.withFixture { rig in
        let id = try await rig.give("u-builder"); try await rig.finish("s-1"); await rig.move(20 * 60_000); try await rig.engine.noteStatus(sessionID: "s-1", status: .working)
        try await E.fields(rig, id, F.obj([("keepOpenUntil", .null)])); await rig.move(20 * 60_000); let stopped = await rig.probe.stops; XCTAssertTrue(stopped.isEmpty)
    } }
    func testMaxRunDeadlineStopsAndExplainsTheLimit() async throws { try await F.withFixture { rig in
        let id = try await rig.give("u-builder"); await rig.move(60 * 60_000); let stopped = await rig.probe.stops, blockers = await rig.probe.comments("blocker")
        XCTAssertTrue(stopped.contains("s-1")); XCTAssertTrue(blockers.last?["body"].string?.contains("Stopped after 60 minutes") == true); await E.statuses(rig, ["Working on it", "Stuck"]); try await E.fields(rig, id, F.obj([("sessionId", .null)]))
    } }
    func testRestartReleasesMissingSessionAndPreservesConversation() async throws { try await F.withFixture { rig in
        let id = try await rig.give("u-builder"); try await rig.engine.stop(); await rig.probe.forgetSessions(); try await rig.engine.start()
        try await E.fields(rig, id, F.obj([("sessionId", .null), ("process", .string("exited")), ("conversationId", .string("conv-1"))])); let blockers = await rig.probe.comments("blocker"); XCTAssertTrue(blockers.last?["body"].string?.contains("Terminal Deck restarted") == true); await E.statuses(rig, ["Working on it", "Stuck"])
    } }
    func testStatusNeedsCreatorOrMainAssigneeAndNeverEchoesCurrentStatus() async throws { try await F.withFixture { rig in
        _ = try await rig.give("u-builder", patch: F.obj([("mainAssignee", .string("u-someone")), ("creator", .string("u-asad"))])); await E.statuses(rig, []); let progress = await rig.probe.comments("progress"); XCTAssertEqual(progress.count, 1)
        _ = try await rig.give("u-builder", patch: F.obj([("project", .string("/work/b")), ("status", .string("Working on it"))])); await E.statuses(rig, [])
    } }
    func testNoTimerWhenNothingIsDue() async throws { try await F.withFixture { rig in XCTAssertEqual(rig.clock.pending, 0) } }
    func testHootDelegatesCRMChildrenAndGetsTheirCompletionDigest() async throws { try await F.withFixture { rig in
        let parent = try await rig.give("u-hoot", id: "root"); let initial = await rig.probe.told; XCTAssertTrue(initial.first?.contains("tasks_delegate") == true); await E.statuses(rig, ["Working on it"])
        _ = try await rig.delegation.delegate(taskID: parent, agent: "tester", title: "Run the tests", instructions: "npm test", project: nil)
        let requested = await rig.probe.posts.first { $0["type"].string == "task.delegate_requested" }; XCTAssertEqual(requested?["actor"], .string("u-hoot")); XCTAssertEqual(requested?["externalTaskId"], .string("root")); XCTAssertEqual(requested?["delegate"]["assignee"], .string("u-tester")); XCTAssertEqual(requested?["delegate"]["project"], .string("/work/app"))
        let child = try await rig.api.call("create", keyID: F.key, input: F.obj([("eventId", .string("e-child")), ("externalTaskId", .string("child-1")), ("parentExternalTaskId", .string("root")), ("title", .string("Run the tests")), ("instructions", .string("npm test")), ("assignee", .string("u-tester")), ("requestedBy", .string("u-hoot")), ("creator", .string("u-hoot"))])); XCTAssertEqual(child.value["outcome"], .string("accepted"))
        try await E.fields(rig, F.key + ":child-1", F.obj([("hops", .number(1)), ("originExternalTaskId", .string("root")), ("externalThreadId", .string("th-root"))])); try await rig.finish("s-1", answer: "All 40 tests pass.")
        let comments = await rig.probe.comments("completion"), told = await rig.probe.told; XCTAssertEqual(comments.last?["externalTaskId"], .string("child-1")); XCTAssertEqual(comments.last?["originExternalTaskId"], .string("root")); XCTAssertEqual(comments.last?["actor"], .string("u-tester")); XCTAssertTrue(told.last?.contains("Every task you handed on") == true); XCTAssertTrue(told.last?.contains("All 40 tests pass.") == true)
    } }
    func testCreateDeduplicatesAndResultChangesOnlyAfterCheckedFinish() async throws { try await F.withFixture { rig in
        let input = F.obj([("eventId", .string("dup")), ("externalTaskId", .string("R-1")), ("title", .string("Run it")), ("project", .string("/work/app")), ("assignee", .string("u-tester")), ("requestedBy", .string("u-asad"))])
        let first = try await rig.api.call("create", keyID: F.key, input: input), again = try await rig.api.call("create", keyID: F.key, input: input), before = try await rig.api.call("result", keyID: F.key, input: F.obj([("externalTaskId", .string("R-1"))])); XCTAssertEqual(first.value["outcome"], .string("accepted")); XCTAssertEqual(again.value["duplicate"], .bool(true)); XCTAssertEqual(before.value["finished"], .bool(false)); XCTAssertEqual(before.value["answer"], .null)
        let starts = await rig.probe.launches; XCTAssertEqual(starts.count, 1); try await rig.finish("s-1", answer: "40 passed, 0 failed.")
        let result = try await rig.api.call("result", keyID: F.key, input: F.obj([("externalTaskId", .string("R-1"))])), read = try await rig.api.call("get", keyID: F.key, input: F.obj([("externalTaskId", .string("R-1"))])); XCTAssertEqual(result.value["finished"], .bool(true)); XCTAssertEqual(result.value["verified"], .bool(true)); XCTAssertEqual(result.value["answer"], .string("40 passed, 0 failed.")); XCTAssertEqual(result.value["crmStatus"], .string("Done")); XCTAssertEqual(read.value["task"]["finished"], .bool(true)); XCTAssertEqual(read.value["task"]["verified"], .bool(true))
    } }
    func testCRMAssignmentToAnotherWorkerStartsFromBeginning() async throws { try await F.withFixture { rig in
        let id = try await rig.give("u-builder", id: "move"); let moved = try await rig.api.call("assign", keyID: F.key, input: F.obj([("eventId", .string("as-1")), ("externalTaskId", .string("move")), ("assignee", .string("u-tester")), ("requestedBy", .string("u-asad"))])); XCTAssertEqual(moved.value["outcome"], .string("accepted"))
        let starts = await rig.probe.launches, stopped = await rig.probe.stops, progress = await rig.probe.comments("progress"), saved = try await rig.record(id)
        XCTAssertEqual(stopped, ["s-1"]); XCTAssertEqual(starts.map { $0.agent["provider"].string! }, ["claude", "codex"]); XCTAssertNil(starts.last?.resume); XCTAssertEqual(saved.agentID, "tester"); XCTAssertEqual(saved.value["assignee"]["identity"], .string("u-tester")); XCTAssertEqual(saved.sessionID, "s-2"); await E.statuses(rig, ["Working on it"]); XCTAssertEqual(progress.last?["body"], .string("Tester started on this.")); XCTAssertEqual(progress.last?["actor"], .string("u-tester"))
    } }
    func testAssignmentOutsideOurCRMIdentitiesOnlyStopsWork() async throws { try await F.withFixture { rig in
        let id = try await rig.give("u-builder", id: "release"), before = await rig.probe.statuses()
        let answer = try await rig.api.call("assign", keyID: F.key, input: F.obj([("eventId", .string("as-2")), ("externalTaskId", .string("release")), ("assignee", .string("u-dot")), ("requestedBy", .string("u-asad"))])); XCTAssertEqual(answer.value["outcome"], .string("released")); await E.statuses(rig, before)
        let progress = await rig.probe.comments("progress"), stops = await rig.probe.stops; XCTAssertEqual(stops, ["s-1"]); XCTAssertEqual(progress.last?["body"], .string("Stopped: it was assigned to somebody else in the CRM.")); try await E.fields(rig, id, F.obj([("stopped", .bool(true)), ("sessionId", .null)]))
    } }
    func testCRMCancelPreservesStatusAndRejectsLateReplies() async throws { try await F.withFixture { rig in
        _ = try await rig.give("u-builder", id: "cancel"); let cancelled = try await rig.api.call("cancel", keyID: F.key, input: F.obj([("eventId", .string("cx-1")), ("externalTaskId", .string("cancel")), ("requestedBy", .string("u-asad")), ("reason", .string("not needed"))])); XCTAssertEqual(cancelled.value["outcome"], .string("cancelled")); await E.statuses(rig, ["Working on it"])
        let progress = await rig.probe.comments("progress"), stops = await rig.probe.stops; XCTAssertEqual(stops, ["s-1"]); XCTAssertEqual(progress.last?["body"], .string("Stopped: cancelled in the CRM: not needed"))
        let late = try await rig.api.call("comment", keyID: F.key, input: F.obj([("eventId", .string("cm-9")), ("externalTaskId", .string("cancel")), ("externalCommentId", .string("crm-9")), ("author", .string("u-asad")), ("body", .string("Go on")), ("mentions", .array([.string("u-builder")]))])); XCTAssertEqual(late.value["outcome"], .string("ignored_not_addressed")); let starts = await rig.probe.launches; XCTAssertEqual(starts.count, 1)
    } }
    func testExternalStatusIsRecordedWithoutSessionOperations() async throws { try await F.withFixture { rig in
        let id = try await rig.give("u-builder", id: "status"), before = await rig.probe.launches.count
        let answer = try await rig.api.call("status", keyID: F.key, input: F.obj([("eventId", .string("st-1")), ("externalTaskId", .string("status")), ("status", .string("In Progress")), ("changedBy", .string("u-asad"))])); XCTAssertEqual(answer.value["outcome"], .string("recorded")); XCTAssertEqual(answer.value["task"]["crmStatus"], .string("In Progress")); let after = await rig.probe.launches.count, stops = await rig.probe.stops; XCTAssertEqual(after, before); XCTAssertTrue(stops.isEmpty); try await E.fields(rig, id, F.obj([("sessionId", .string("s-1"))]))
    } }
    func testOnlyAllowedAddressedCommentsReachTheWorker() async throws { try await F.withFixture { rig in
        _ = try await rig.give("u-builder", id: "comment")
        let base = F.obj([("externalTaskId", .string("comment")), ("mentions", .array([.string("u-builder")]))])
        let own = try await rig.api.call("comment", keyID: F.key, input: base.merging(F.obj([("eventId", .string("cm-1")), ("externalCommentId", .string("crm-1")), ("author", .string("u-builder")), ("body", .string("Working on it"))]))), asked = try await rig.api.call("comment", keyID: F.key, input: base.merging(F.obj([("eventId", .string("cm-2")), ("externalCommentId", .string("crm-2")), ("author", .string("u-asad")), ("body", .string("Use the new API."))])))
        XCTAssertEqual(own.value["outcome"], .string("ignored_own_agent")); XCTAssertEqual(asked.value["outcome"], .string("answered")); let sends = await rig.probe.sends; XCTAssertEqual(sends, [F.obj([("sessionId", .string("s-1")), ("text", .string("Use the new API."))])])
    } }
}
