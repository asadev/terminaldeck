import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendRoutinesTaskBriefParityTests: XCTestCase {
    private typealias F = BackendRoutinesTaskEngineParityFixture
    private static func task(_ id: String, patch: NativeRPCValue = .object([]), detail: NativeRPCValue = .object([])) throws -> BackendTaskRecord {
        try BackendTaskRecord(F.obj([("id", .string("local:" + id)), ("keyId", .string("local")), ("externalTaskId", .string(id)), ("local", .bool(true)), ("title", .string("Task " + id)), ("instructions", .string("")), ("project", .string("/work/app")), ("assignee", BackendTaskLocalService.assignment("me", kind: "human")), ("crmStatus", .string("To-Do")), ("process", .string("idle")), ("result", .null), ("notes", .array([])), ("detail", detail)]).merging(patch))
    }
    func testLinksAreReadFromBothSidesAndDoneClearsBlocker() throws {
        let first = try Self.task("first", patch: F.obj([("title", .string("Build the API"))]), detail: F.obj([("dependencies", .array([F.obj([("kind", .string("blocks")), ("otherTaskId", .string("local:third")), ("at", .number(2))])]))])), second = try Self.task("second", patch: F.obj([("title", .string("Build the page"))]), detail: F.obj([("dependencies", .array([F.obj([("kind", .string("blocked_by")), ("otherTaskId", .string("local:first")), ("at", .number(1))])]))])), third = try Self.task("third", patch: F.obj([("title", .string("Ship"))]))
        let all = [first, second, third], context = BackendTaskBriefComposition.context(first, all: all, names: [:]), links = context.components(separatedBy: "\n").filter { $0.hasPrefix("- Needed by:") }
        XCTAssertEqual(links, ["- Needed by: Ship (To-Do)", "- Needed by: Build the page (To-Do)"]); XCTAssertEqual(BackendGoalStore.blockers(second, all: all).map(\.id), [first.id]); XCTAssertEqual(BackendGoalStore.blockers(third, all: all).map(\.id), [first.id])
        let done = try BackendTaskRecord(first.value.setting("crmStatus", .string("Done"))); XCTAssertTrue(BackendGoalStore.blockers(second, all: [done, second, third]).isEmpty); XCTAssertTrue(BackendGoalStore.blockers(third, all: [done, second, third]).isEmpty)
    }
    func testGoalProgressCountsChildrenVerifiedClaimedStalledAndWaiting() async throws { try await F.withFixture { rig in
        let root = try await rig.goals.save(F.obj([("title", .string("g-root"))])), child = try await rig.goals.save(F.obj([("title", .string("g-child")), ("parentId", root["id"])])), other = try await rig.goals.save(F.obj([("title", .string("g-other"))]))
        let result: @Sendable (Bool) -> NativeRPCValue = { F.obj([("at", .number(1)), ("verified", .bool($0)), ("answer", .string($0 ? "ok" : "done?")), ("check", .null)]) }
        let verified = try Self.task("verified", patch: F.obj([("goalId", root["id"]), ("crmStatus", .string("Done")), ("result", result(true))])), claimed = try Self.task("claimed", patch: F.obj([("goalId", child["id"]), ("crmStatus", .string("Working on it")), ("result", result(false))])), stalled = try Self.task("stalled", patch: F.obj([("goalId", child["id"]), ("crmStatus", .string("Stuck")), ("process", .string("running")), ("stalled", F.obj([("at", .number(5)), ("reason", .string("quiet")), ("text", .string("No sign of work."))]))])), waiting = try Self.task("waiting", patch: F.obj([("goalId", root["id"]), ("process", .string("queued"))]), detail: F.obj([("dependencies", .array([F.obj([("kind", .string("blocked_by")), ("otherTaskId", .string(stalled.id)), ("at", .number(1))])]))])), elsewhere = try Self.task("elsewhere", patch: F.obj([("goalId", other["id"])])), archived = try Self.task("archived", patch: F.obj([("goalId", root["id"]), ("archivedAt", .number(9))]))
        let progress = try await rig.goals.progress(root["id"].string!, tasks: [verified, claimed, stalled, waiting, elsewhere, archived])
        for (key, n) in [("total", 4), ("done", 1), ("verified", 1), ("unverified", 1), ("stalled", 1), ("blocked", 1)] { XCTAssertEqual(progress[key], .number(Double(n)), key) }
        for status in ["Done", "Working on it", "Stuck", "To-Do"] { XCTAssertEqual(progress["byStatus"][status], .number(1)) }; for (key, n) in [("running", 1), ("queued", 1), ("idle", 2)] { XCTAssertEqual(progress["byProcess"][key], .number(Double(n))) }
        XCTAssertEqual(progress["children"], .array([F.obj([("goal", child["id"]), ("title", .string("g-child")), ("status", .string("active"))])]))
        let tasks = progress["tasks"].elements ?? []; XCTAssertEqual(tasks.first { $0["task"].string == waiting.id }?["blockedBy"], .array([F.obj([("task", .string(stalled.id)), ("title", stalled.value["title"])])]))
        XCTAssertEqual(tasks.first { $0["task"].string == stalled.id }?["stalled"]["reason"], .string("quiet"))
    } }
    func testGoalChainIsBroadestFirstAndDescriptionsAreBounded() {
        let chain = [F.obj([("title", .string("Ship 0.18")), ("status", .string("active")), ("description", .string("Mac only."))]), F.obj([("title", .string("Fortnightly releases")), ("status", .string("active")), ("description", .string(String(repeating: "x", count: 2000)))])]
        let text = BackendTaskBriefComposition.goals(chain); XCTAssertTrue(text.contains("## The goal this serves")); XCTAssertTrue(text.contains("This task is part of the goals below, from the broadest down to the one it serves directly.")); XCTAssertTrue(text.contains("  - **Ship 0.18** (active) — Mac only.")); XCTAssertLessThan(text.utf16.count, 1000); XCTAssertEqual(BackendTaskBriefComposition.goals([]), "")
        if let broad = text.range(of: "Fortnightly releases"), let narrow = text.range(of: "Ship 0.18") { XCTAssertLessThan(broad.lowerBound, narrow.lowerBound) } else { XCTFail("Both goal titles must survive") }
    }
    func testTaskContextKeepsRelevantLatestInformationAndCapsIt() throws {
        let blocker = try Self.task("blocker", patch: F.obj([("title", .string("Write the migration")), ("crmStatus", .string("In Progress"))]))
        let notes = [("me", "edited", "Changed the title."), ("builder", "blocker", "The test database is down."), ("me", "reply", "Use the local one.")].enumerated().map { F.obj([("at", .number(Double($0.offset + 1))), ("by", .string($0.element.0)), ("kind", .string($0.element.1)), ("text", .string($0.element.2))]) }
        let subject = try Self.task("subject", patch: F.obj([("notes", .array(notes))]), detail: F.obj([("subtasks", .array([F.obj([("id", .string("s1")), ("title", .string("Add the column")), ("done", .bool(true)), ("sortOrder", .number(0))]), F.obj([("id", .string("s2")), ("title", .string("Backfill")), ("done", .bool(false)), ("sortOrder", .number(1))])])), ("dependencies", .array([F.obj([("kind", .string("blocked_by")), ("otherTaskId", .string(blocker.id)), ("at", .number(1))])])), ("comments", .array([F.obj([("id", .string("c1")), ("authorUserId", .string("me")), ("body", .string("Keep the old column for a week.")), ("at", .number(5))])]))]))
        let names = ["me": "You", "builder": "Builder"], text = BackendTaskBriefComposition.context(subject, all: [subject, blocker], names: names)
        for phrase in ["## Already on this task", "- [x] Add the column", "- [ ] Backfill", "- Waits for: Write the migration (In Progress)", "- You: Keep the old column for a week.", "- Builder (blocker): The test database is down.", "- You (reply): Use the local one."] { XCTAssertTrue(text.contains(phrase), phrase) }; XCTAssertFalse(text.contains("Changed the title."))
        let comments = (0..<50).map { F.obj([("id", .string("c\($0)")), ("authorUserId", .string("me")), ("body", .string("\($0) " + String(repeating: "word ", count: 200))), ("at", .number(Double($0)))]) }, noisy = try Self.task("noisy", detail: F.obj([("comments", .array(comments))])), bounded = BackendTaskBriefComposition.context(noisy, all: [noisy], names: names)
        XCTAssertTrue(bounded.contains("- You: 49 ")); XCTAssertFalse(bounded.contains("- You: 41 ")); XCTAssertLessThan(bounded.utf16.count, 6400); XCTAssertEqual(BackendTaskBriefComposition.context(try Self.task("empty"), all: [], names: names), "")
    }
    func testRetrySectionNamesPriorFailureAndExactTryCount() async throws { try await F.withFixture { rig in
        let task = try await rig.local.create(F.obj([("title", .string("Retry task")), ("project", .string("/work/app"))])); _ = try await rig.local.update(task.id, input: F.obj([("assignee", .string("builder"))])); let first = try BackendRoutinesTaskEngineParityUnwrap(await rig.probe.launches.first); XCTAssertFalse(first.brief.contains("## Tried again"))
        await rig.probe.exit("s-1", code: 1); try await rig.engine.noteExit(sessionID: "s-1", exitCode: 1); try await rig.engine.retry(task.id, note: "Run the migration first.")
        let retried = try BackendRoutinesTaskEngineParityUnwrap(await rig.probe.launches.last); XCTAssertTrue(retried.brief.contains("\n\n## Tried again\n\nThis task was started before and did not finish (try 2).\n\nRun the migration first."))
    } }
}
