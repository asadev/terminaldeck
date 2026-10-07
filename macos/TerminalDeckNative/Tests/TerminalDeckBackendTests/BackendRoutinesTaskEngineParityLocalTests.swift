import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendRoutinesTaskEngineParityLocalTests: XCTestCase {
    private typealias F = BackendRoutinesTaskEngineParityFixture
    private typealias E = BackendRoutinesTaskEngineParityExpect
    private static func settings(_ rig: F) async throws {
        let prior = try BackendRoutinesTaskEngineParityUnwrap(try await rig.config.agent("builder"))
        _ = try await rig.config.saveAgent(prior.merging(F.obj([("effort", .string("high")), ("instructions", .string("Work on a branch. Run the tests before you finish.")), ("toolsPreferred", .array([.string("Read"), .string("Grep")])), ("toolsAvoided", .array([.string("WebFetch")])), ("skills", .array([.string("frontend-design")]))])))
    }
    func testStandingInstructionsAdviceSkillsModelAndEffort() async throws { try await F.withFixture { rig in
        try await Self.settings(rig); _ = try await rig.give("u-builder"); let start = try BackendRoutinesTaskEngineParityUnwrap(await rig.probe.launches.first), controls = await rig.probe.controls
        for phrase in ["## How you work (Builder, builder)", "Work on a branch. Run the tests before you finish.", "Prefer these tools: Read, Grep.", "Do not use these tools: WebFetch.", "your own permission settings still apply", "Use these skills when they fit: frontend-design."] { XCTAssertTrue(start.brief.contains(phrase), phrase) }
        let instruction = try XCTUnwrap(start.brief.range(of: "## How you work")), task = try XCTUnwrap(start.brief.range(of: "## The task")); XCTAssertLessThan(instruction.lowerBound, task.lowerBound)
        XCTAssertEqual(controls, [F.obj([("sessionId", .string("s-1")), ("control", .string("model")), ("value", .string("opus"))]), F.obj([("sessionId", .string("s-1")), ("control", .string("effort")), ("value", .string("high"))])])
    } }
    func testAdviceDoesNotBecomeEnforcedToolLimits() async throws { try await F.withFixture { rig in
        try await Self.settings(rig); _ = try await rig.give("u-builder"); let agent = try BackendRoutinesTaskEngineParityUnwrap(await rig.probe.launches.first).agent
        XCTAssertEqual(agent["toolsAvoided"], .array([.string("WebFetch")])); XCTAssertEqual(agent["blockedTools"], .array([])); XCTAssertEqual(agent["skillsOff"], .bool(false))
    } }
    func testOwnerBlockedToolsAndSkillsOffAreEnforcedAndExplained() async throws { try await F.withFixture { rig in
        try await Self.settings(rig); let prior = try BackendRoutinesTaskEngineParityUnwrap(try await rig.config.agent("builder")); _ = try await rig.config.saveAgent(prior.setting("blockedTools", .array([.string("WebFetch"), .string("mcp__deck-control")])).setting("skillsOff", .bool(true)))
        _ = try await rig.give("u-builder"); let start = try BackendRoutinesTaskEngineParityUnwrap(await rig.probe.launches.first)
        XCTAssertEqual(start.agent["blockedTools"], .array([.string("WebFetch"), .string("mcp__deck-control")])); XCTAssertEqual(start.agent["skillsOff"], .bool(true)); XCTAssertFalse(start.task.value.has("blockTools")); XCTAssertTrue(start.brief.contains("These tools are switched off for you: WebFetch, mcp__deck-control.")); XCTAssertTrue(start.brief.contains("Skills are switched off for you."))
    } }
    func testResumingUsesCurrentSettingsAndExactConversation() async throws { try await F.withFixture { rig in
        try await Self.settings(rig); _ = try await rig.give("u-builder", id: "resume"); try await rig.finish("s-1", answer: "Done."); await rig.move(30 * 60_000)
        let prior = try BackendRoutinesTaskEngineParityUnwrap(try await rig.config.agent("builder")); _ = try await rig.config.saveAgent(prior.setting("effort", .string("max")).setting("instructions", .string("Keep commits small.")))
        let answer = try await rig.api.call("comment", keyID: F.key, input: F.obj([("eventId", .string("rs-1")), ("externalTaskId", .string("resume")), ("externalCommentId", .string("crm-rs-1")), ("author", .string("u-asad")), ("body", .string("One more fix.")), ("mentions", .array([.string("u-builder")]))])); XCTAssertTrue(answer.ok)
        let start = try BackendRoutinesTaskEngineParityUnwrap(await rig.probe.launches.last), controls = await rig.probe.controls.filter { $0["sessionId"].string == "s-2" }
        XCTAssertEqual(start.resume, "conv-1"); XCTAssertEqual(start.agent["provider"], .string("claude")); XCTAssertEqual(start.agent["account"], .string("Work")); XCTAssertTrue(start.brief.contains("One more fix.")); XCTAssertTrue(start.brief.contains("Keep commits small.")); XCTAssertEqual(controls.map { $0["value"] }, [.string("opus"), .string("max")])
    } }
    func testRefusedControlIsRecordedAndWorkContinues() async throws { try await F.withFixture { rig in
        try await Self.settings(rig); await rig.probe.refuseEffort(); _ = try await rig.give("u-builder"); let comments = await rig.probe.comments("progress")
        XCTAssertTrue(comments.contains { $0["body"].string == "Could not set effort high: this agent has no effort setting." }); await E.statuses(rig, ["Working on it"])
    } }
    func testUnassignedAndHumanTasksEditWithoutStartingOrPosting() async throws { try await F.withFixture { rig in
        let nobody = try await rig.local.create(F.obj([("title", .string("Plan the release")), ("instructions", .string("Dates and owners."))])), mine = try await rig.local.create(F.obj([("title", .string("Write the notes")), ("assignee", .string("me")), ("status", .string("In Progress"))]))
        XCTAssertTrue(nobody.isLocal); XCTAssertEqual(nobody.assigneeKind, "none"); XCTAssertEqual(nobody.value["crmStatus"], .string("To-Do")); XCTAssertEqual(nobody.process, "idle"); XCTAssertEqual(nobody.value["keyId"], .string("local")); XCTAssertEqual(mine.assigneeKind, "human"); XCTAssertEqual(mine.agentID, "me"); XCTAssertEqual(mine.process, "idle")
        _ = try await rig.local.update(nobody.id, input: F.obj([("title", .string("Plan the 0.18 release")), ("instructions", .string("Dates, owners, risks.")), ("project", .string("/work/app")), ("status", .string("Done"))]))
        try await E.fields(rig, nobody.id, F.obj([("title", .string("Plan the 0.18 release")), ("instructions", .string("Dates, owners, risks.")), ("project", .string("/work/app")), ("crmStatus", .string("Done"))])); let notes = try await rig.notes(nobody.id), starts = await rig.probe.launches, posts = await rig.probe.posts
        XCTAssertEqual(notes, ["me/edited: Created, assigned to nobody.", "me/edited: Changed the title, details, project.", "me/status: Status: Done"]); XCTAssertTrue(starts.isEmpty); XCTAssertTrue(posts.isEmpty)
    } }
    func testLocalTaskRefusalsNameTheActualProblem() async throws { try await F.withFixture { rig in
        let cases: [(NativeRPCValue, String)] = [(F.obj([("title", .string(" "))]), "title cannot be empty"), (F.obj([("title", .string("x")), ("assignee", .string("builder"))]), "project folder the agent should work in"), (F.obj([("title", .string("x")), ("assignee", .string("nobody-here"))]), "one of your task agents"), (F.obj([("title", .string("x")), ("status", .string("Cancelled"))]), "status has to be one of"), (F.obj([("title", .string("x")), ("project", .string("relative/path"))]), "not a full folder path")]
        for (input, text) in cases { await E.error(text) { _ = try await rig.local.create(input) } }; await E.error("no longer exists") { _ = try await rig.local.update("local:missing", input: F.obj([("status", .string("Done"))])) }
    } }
    func testLocalQuestionHandsToHumanAndReplyReturnsToSameWorker() async throws { try await F.withFixture { rig in
        let task = try await rig.local.create(F.obj([("title", .string("Fix the login bug")), ("instructions", .string("It throws on an empty password.")), ("project", .string("/work/app")), ("assignee", .string("builder"))])); let start = try BackendRoutinesTaskEngineParityUnwrap(await rig.probe.launches.first)
        XCTAssertEqual(start.cwd, "/work/app"); XCTAssertEqual(start.agent["provider"], .string("claude")); XCTAssertEqual(start.agent["account"], .string("Work")); try await E.fields(rig, task.id, F.obj([("crmStatus", .string("Working on it")), ("sessionId", .string("s-1"))]))
        try await rig.engine.noteStatus(sessionID: "s-1", status: .working); try await rig.engine.noteNeedsInput(sessionID: "s-1", screen: "Allow this edit?"); let blocked = try await rig.record(task.id), before = try await rig.notes(task.id)
        XCTAssertEqual(blocked.assigneeKind, "human"); XCTAssertEqual(blocked.value["handedFrom"], .string("builder")); XCTAssertEqual(blocked.value["crmStatus"], .string("Stuck")); XCTAssertEqual(Array(before.suffix(3)), ["builder/question: The agent is asking something. Reply on this task to answer.", "builder/status: Status: Stuck", "builder/assigned: Handed to you."])
        _ = try await rig.local.reply(task.id, text: "Yes, allow it."); let final = try await rig.record(task.id), notes = try await rig.notes(task.id), sends = await rig.probe.sends, posts = await rig.probe.posts
        XCTAssertEqual(sends.last, F.obj([("sessionId", .string("s-1")), ("text", .string("Yes, allow it."))])); XCTAssertEqual(final.agentID, "builder"); XCTAssertEqual(final.value["handedFrom"], .null); XCTAssertEqual(final.value["crmStatus"], .string("Working on it")); XCTAssertTrue(notes.contains("me/reply: Yes, allow it.")); XCTAssertTrue(posts.isEmpty)
    } }
    func testUncheckedLocalFinishReturnsToHumanAndReplyUsesSameSession() async throws { try await F.withFixture { rig in
        let task = try await rig.local.create(F.obj([("title", .string("Fix it")), ("project", .string("/work/app")), ("assignee", .string("builder"))])); try await rig.finish("s-1", answer: "Fixed: the empty password is refused now.")
        let finished = try await rig.record(task.id), notes = try await rig.notes(task.id), told = await rig.probe.told; XCTAssertEqual(finished.assigneeKind, "human"); XCTAssertEqual(finished.value["handedFrom"], .string("builder")); XCTAssertEqual(finished.value["result"]["verified"], .bool(false)); XCTAssertTrue(notes.contains("builder/completion: Finished. Check it and mark it Done.")); XCTAssertTrue(told.isEmpty)
        _ = try await rig.local.reply(task.id, text: "Add a test for it too."); let sends = await rig.probe.sends; XCTAssertEqual(sends.last, F.obj([("sessionId", .string("s-1")), ("text", .string("Add a test for it too."))])); _ = try await rig.local.update(task.id, input: F.obj([("status", .string("Done"))])); try await E.fields(rig, task.id, F.obj([("crmStatus", .string("Done"))]))
    } }
    func testCheckedLocalFinishStaysWithAgentAndIsDone() async throws { try await F.withFixture { rig in
        let task = try await rig.local.create(F.obj([("title", .string("Run the tests")), ("project", .string("/work/app")), ("assignee", .string("tester"))])); try await rig.finish("s-1", answer: "40 passed."); let saved = try await rig.record(task.id), notes = try await rig.notes(task.id)
        XCTAssertEqual(saved.agentID, "tester"); XCTAssertEqual(saved.assigneeKind, "agent"); XCTAssertEqual(saved.value["crmStatus"], .string("Done")); XCTAssertEqual(saved.value["result"]["verified"], .bool(true)); XCTAssertTrue(notes.contains("tester/completion: Finished, and the check passed."))
    } }
    func testTakingTaskBackStopsWorkerAndLaterAssignmentStartsFresh() async throws { try await F.withFixture { rig in
        let task = try await rig.local.create(F.obj([("title", .string("Fix it")), ("project", .string("/work/app")), ("assignee", .string("builder"))])); _ = try await rig.local.update(task.id, input: F.obj([("assignee", .string("me"))])); let stops = await rig.probe.stops, notes = try await rig.notes(task.id), saved = try await rig.record(task.id)
        XCTAssertEqual(stops, ["s-1"]); XCTAssertEqual(saved.assigneeKind, "human"); XCTAssertEqual(saved.process, "idle"); XCTAssertNil(saved.sessionID); XCTAssertTrue(notes.contains("me/assigned: Assigned to you."))
        _ = try await rig.local.update(task.id, input: F.obj([("assignee", .string("none"))])); _ = try await rig.local.update(task.id, input: F.obj([("assignee", .string("builder"))])); let starts = await rig.probe.launches; XCTAssertEqual(starts.count, 2); XCTAssertNil(starts.last?.resume)
    } }
    func testHootCreatesLocalChildWithoutCRMEvents() async throws { try await F.withFixture { rig in
        let parent = try await rig.local.create(F.obj([("title", .string("Ship 0.18")), ("project", .string("/work/app")), ("assignee", .string("hoot"))])); _ = try await rig.delegation.delegate(taskID: parent.id, agent: "builder", title: "Fix the bug", instructions: "Now.", project: nil)
        let all = try await rig.store.all(), starts = await rig.probe.launches, posts = await rig.probe.posts, told = await rig.probe.told
        let child = try XCTUnwrap(all.first { $0.value["parentExternalTaskId"] == parent.value["externalTaskId"] }); XCTAssertTrue(child.isLocal); XCTAssertEqual(child.value["title"], .string("Fix the bug")); XCTAssertEqual(child.agentID, "builder"); XCTAssertEqual(child.project, "/work/app"); XCTAssertEqual(child.value["hops"], .number(1)); XCTAssertEqual(starts.count, 1); XCTAssertTrue(posts.isEmpty); XCTAssertFalse(told.isEmpty)
    } }
    func testCRMFieldsOnLocalTasksAndOneActivityPerActualChange() async throws { try await F.withFixture { rig in
        let task = try await rig.local.create(F.obj([("title", .string("Launch page")), ("priority", .string("High")), ("dueDate", .string("2026-10-09")), ("board", .string("Launch")), ("labels", .array([.string("web"), .string("web"), .string(" ops ")]))])); try await E.fields(rig, task.id, F.obj([("priority", .string("High")), ("dueDate", .string("2026-10-09")), ("board", .string("Launch")), ("labels", .array([.string("web"), .string("ops")])), ("taskType", .string("task")), ("completedAt", .null)]))
        let changes = F.obj([("priority", .null), ("startDate", .string("2026-10-08")), ("startTime", .string("09:30")), ("dueTime", .string("17:00")), ("taskType", .string("milestone")), ("estimateMinutes", .number(90)), ("board", .null)]); _ = try await rig.local.update(task.id, input: changes); try await E.fields(rig, task.id, changes)
        let before = try await rig.record(task.id).value["notes"].elements ?? []; XCTAssertEqual(before.last?["text"], .string("Changed the priority, start date, start time, due time, board, type, estimate.")); _ = try await rig.local.update(task.id, input: F.obj([("priority", .null), ("taskType", .string("milestone"))])); let after = try await rig.record(task.id).value["notes"].elements ?? []; XCTAssertEqual(after.count, before.count)
    } }
    func testDoneReopenArchiveRestoreTimestamps() async throws { try await F.withFixture { rig in
        let task = try await rig.local.create(F.obj([("title", .string("Ship")), ("status", .string("Done"))])); XCTAssertEqual(task.value["completedAt"].number, rig.clock.now())
        _ = try await rig.local.update(task.id, input: F.obj([("status", .string("In Progress"))])); try await E.fields(rig, task.id, F.obj([("completedAt", .null)])); _ = try await rig.local.update(task.id, input: F.obj([("archived", .bool(true))])); try await E.fields(rig, task.id, F.obj([("archivedAt", .number(rig.clock.now()))])); _ = try await rig.local.update(task.id, input: F.obj([("archived", .bool(false))])); try await E.fields(rig, task.id, F.obj([("archivedAt", .null)])); let notes = try await rig.record(task.id).value["notes"].elements ?? []; XCTAssertEqual(notes.suffix(2).map { $0["text"] }, [.string("Archived."), .string("Restored from the archive.")])
    } }
    func testLocalFieldRefusalsMatchCRM() async throws { try await F.withFixture { rig in
        let rows: [(String, NativeRPCValue, String)] = [("priority", .string("Urgent"), "priority has to be one of"), ("dueDate", .string("2026-02-30"), "due date has to be a date"), ("dueTime", .string("25:00"), "due time has to be a time"), ("labels", .array((0..<21).map { .string("t\($0)") }), "at most 20 tags"), ("labels", .array([.string(String(repeating: "x", count: 41))]), "at most 40 characters"), ("taskType", .string("epic"), "task or a milestone"), ("estimateMinutes", .number(-1), "whole number of minutes"), ("board", .string(String(repeating: "b", count: 41)), "at most 40 characters")]
        for (key, value, message) in rows { await E.error(message) { _ = try await rig.local.create(F.obj([("title", .string("x")), (key, value)])) } }
    } }
    func testDeleteStopsTheWorkerBeforeTaskDisappears() async throws { try await F.withFixture { rig in
        let task = try await rig.local.create(F.obj([("title", .string("Fix it")), ("project", .string("/work/app")), ("assignee", .string("builder"))])); try await rig.local.remove(task.id); let stops = await rig.probe.stops, found = try await rig.store.byID(task.id); XCTAssertEqual(stops, ["s-1"]); XCTAssertNil(found)
    } }
    func testLocalRecordsAndWholeHistorySurviveDiskRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("task-engine-parity-" + UUID().uuidString); defer { try? FileManager.default.removeItem(at: directory) }
        let clock = BackendRoutinesTaskEngineParityClock()
        try await BackendTaskClockContext.withClock(clock) {
            let persistence = try BackendTaskPersistence(directory: directory, ownership: .exclusive), rig = try await F.make(clock: clock, persistence: persistence)
            let task = try await rig.local.create(F.obj([("title", .string("Book the venue")), ("instructions", .string("Friday.")), ("assignee", .string("me"))])); _ = try await rig.local.update(task.id, input: F.obj([("status", .string("In Progress"))])); try await rig.stop()
            let restored = BackendTaskStore(persistence: persistence); try await restored.start(); let record = try BackendRoutinesTaskEngineParityUnwrap(try await restored.byID(task.id)); XCTAssertTrue(record.isLocal); XCTAssertEqual(record.value["title"], .string("Book the venue")); XCTAssertEqual(record.value["instructions"], .string("Friday.")); XCTAssertEqual(record.value["crmStatus"], .string("In Progress")); XCTAssertEqual(record.assigneeKind, "human"); XCTAssertEqual(record.agentID, "me"); XCTAssertEqual(record.value["notes"].elements?.map { $0["text"] }, [.string("Created, assigned to you."), .string("Status: In Progress")]); try await restored.stop()
        }
    }
}
