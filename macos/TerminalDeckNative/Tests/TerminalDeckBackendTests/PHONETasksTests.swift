import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// iOS batch 1, Tasks seat: what the `tasks` panel sends the phone's iLoop-style task screens — each row's `meta`,
/// the list's quick actions, a task's page (its row, actions by access level, and its parts as grouped rows), and
/// the act entry's line-break and field rules. Pure builders; the tool calls are the panel's existing ones.
final class PHONETasksTests: XCTestCase {
    private typealias V = NativeRPCValue
    private func o(_ pairs: [(String, V)]) -> V { .object(pairs.map { .init($0.0, $0.1) }) }

    private let agents: [V] = [
        .object([.init("id", .string("critic")), .init("name", .string("Critic")), .init("status", .string("active"))]),
        .object([.init("id", .string("old")), .init("name", .string("Old")), .init("status", .string("archived"))]),
    ]

    private func task(_ id: String = "local:1", status: String = "In Progress", assignee: String = "critic") -> V {
        o([("task", .string(id)), ("title", .string("Ship it")), ("status", .string(status)), ("assignee", .string(assignee)),
           ("assigneeName", .string("Critic")), ("project", .string("/Projects/Phone")), ("priority", .string("High")),
           ("startDate", .null), ("dueDate", .string("2026-10-28")), ("labels", .array([.string("ios"), .string("tasks")])),
           ("board", .null), ("type", .string("task")), ("repeats", .null), ("agentWorking", .bool(true))])
    }

    private func meta(_ value: V) -> [String: V] {
        Dictionary(uniqueKeysWithValues: (value.fields ?? []).map { ($0.key, $0.value) })
    }

    func testARowCarriesTheTasksOwnWordsAsData() {
        let m = meta(BackendINT2PhoneTasks.meta(task()))
        XCTAssertEqual(m["status"]?.string, "In Progress")
        XCTAssertEqual(m["assignee"]?.string, "critic")
        XCTAssertEqual(m["assigneeKind"]?.string, "agent")
        XCTAssertEqual(m["priority"]?.string, "High")
        XCTAssertEqual(m["due"]?.string, "2026-10-28")
        XCTAssertNil(m["start"], "a date the task does not have is not sent")
        XCTAssertEqual(m["tags"]?.elements?.compactMap(\.string), ["ios", "tasks"])
        XCTAssertEqual(m["working"]?.string, "1")
        XCTAssertNil(m["type"], "an ordinary task says nothing about its type")
        XCTAssertEqual(BackendINT2PhoneTasks.kind(of: "me"), "human")
        XCTAssertEqual(BackendINT2PhoneTasks.kind(of: "hoot"), "hoot")
        XCTAssertEqual(BackendINT2PhoneTasks.kind(of: "none"), "none")
    }

    func testAssigningOffersYouHootTheWorkingAgentsAndNobody() {
        let choices = BackendINT2PhoneTasks.assignChoices(agents: agents)
        XCTAssertEqual(choices.map(\.id), ["me", "hoot", "critic", "none"], "an archived agent is not offered")
        XCTAssertEqual(choices.map(\.label), ["You", "Hoot", "Critic", "Unassigned"])
    }

    func testQuickActionsFollowTheAccessLevel() {
        XCTAssertTrue(BackendINT2PhoneTasks.quickActions(statuses: TaskStatuses.all, level: .look).isEmpty)
        let work = BackendINT2PhoneTasks.quickActions(statuses: TaskStatuses.all, level: .work).compactMap { $0["id"].string }
        XCTAssertEqual(work, ["quick_status", "quick_due"], "Trash is Full control only (the Work gate refuses it)")
        let full = BackendINT2PhoneTasks.quickActions(statuses: TaskStatuses.all, level: .full)
        XCTAssertEqual(full.compactMap { $0["id"].string }, ["quick_status", "quick_due", "quick_delete"])
        XCTAssertEqual(full[2]["destructive"].bool, true)
        let statusField = full[0]["fields"].elements?.last
        XCTAssertEqual(statusField?["choices"].elements?.compactMap(\.string), TaskStatuses.all)
    }

    func testTheNewTaskFormHasILoopsFields() {
        let ids = BackendINT2PhoneTasks.createFields(statuses: TaskStatuses.all, agents: agents).compactMap { $0["id"].string }
        XCTAssertEqual(ids, ["status", "priority", "due_date", "start_date", "assignee"])
    }

    private func page(level: BackendINT2PhoneAccessLevel, details: String = "Line one\nLine two") -> V {
        let base = o([("id", .string("local:1")), ("title", .string("Ship it")), ("value", .string("In Progress")),
                      ("actions", .array([BackendINT2PhoneTasks.action("comment", "Comment", fields: [BackendINT2PhoneTasks.field("comment", "Comment", required: true)])])),
                      ("sessionId", .string("s-1"))])
        let full = o([
            ("details", .string(details)),
            ("people", o([("primary", o([("id", .string("critic")), ("name", .string("Critic"))])), ("others", .array([o([("id", .string("hoot")), ("name", .string("Hoot"))])]))])),
            ("subtasks", .array([o([("id", .string("s1")), ("title", .string("Write tests")), ("done", .bool(true)), ("assigneeUserId", .null)]),
                                 o([("id", .string("s2")), ("title", .string("Ship")), ("done", .bool(false)), ("assigneeUserId", .string("critic"))])])),
            ("checklists", .array([o([("id", .string("c1")), ("title", .string("Release")), ("items", .array([o([("id", .string("i1")), ("title", .string("Notes")), ("done", .bool(false))])]))])])),
            ("dependencies", .array([o([("kind", .string("blocked_by")), ("otherTaskId", .string("local:2")), ("otherTitle", .string("Design")), ("otherDone", .bool(false))])])),
            ("attachments", .array([o([("id", .string("f1")), ("fileName", .string("plan.pdf")), ("kind", .string("upload")), ("sizeBytes", .number(2048))])])),
            ("fields", .array([o([("id", .string("x1")), ("label", .string("Effort")), ("kind", .string("number")), ("value", .number(3))])])),
            ("timeEntries", .array([o([("id", .string("t1")), ("userId", .string("me")), ("startedAt", .string("2026-10-27T01:00:00.000Z")), ("endedAt", .string("2026-10-27T01:30:00.000Z")), ("seconds", .number(1800))])])),
        ])
        let thread = o([("comments", .array([
            o([("id", .string("c1")), ("authorName", .string("Asad")), ("authorUserId", .string("me")), ("body", .string("Looks good")), ("createdAt", .string("2026-10-27T01:00:00.000Z")), ("authorKind", .string("human"))]),
            o([("id", .string("c2")), ("authorName", .string("Critic")), ("authorUserId", .string("critic")), ("body", .string("   ")), ("authorKind", .string("agent"))]),
        ]))])
        let activity = o([("activity", .array([
            o([("id", .string("a1")), ("taskId", .string("local:1")), ("kind", .string("status")), ("payload", o([("from", .string("To-Do")), ("to", .string("In Progress"))])),
               ("actor", o([("id", .string("me")), ("name", .string("You"))])), ("actorUserId", .string("me")), ("createdAt", .string("2026-10-27T00:00:00.000Z"))]),
        ]))])
        return BackendINT2PhoneTasks.assemble("local:1", base: base, task: task(), full: full, thread: thread, activity: activity, trouble: [],
                                              request: .init(path: "/Projects/Phone", scope: "task:local:1", query: nil),
                                              tasks: [task(), task("local:2")], agents: agents, statuses: TaskStatuses.all, level: level,
                                              now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testATasksPageIsItsRowThenItsPartsInILoopsOrder() {
        let answer = page(level: .full)
        let rows = answer["rows"].elements ?? []
        XCTAssertEqual(answer["view"].string, "task:local:1")
        XCTAssertEqual(answer["path"].string, "/Projects/Phone")
        XCTAssertEqual(rows.first?["id"].string, "local:1")
        XCTAssertEqual(rows.first?["body"].string, "Line one\nLine two", "the description keeps its lines")
        XCTAssertEqual(rows.first?["sessionId"].string, "s-1", "the row keeps its session")
        XCTAssertEqual(rows.first?["meta"]["tracked"].string, "1800")
        let ids = rows.dropFirst().compactMap { $0["id"].string }
        XCTAssertEqual(ids, ["subtask:s1", "subtask:s2", "person:critic", "person:hoot", "checklist:c1", "item:i1",
                             "dep:blocked_by:local:2", "field:x1", "file:f1", "time:t1", "activity:a1", "comment:c1"],
                       "an empty comment is left out")
        let groups = rows.dropFirst().compactMap { $0["group"].string }
        XCTAssertEqual(Array(NSOrderedSet(array: groups)) as? [String], ["Subtasks", "People", "Checklists", "Relationships", "Fields", "Files", "Time", "Activity", "Comments"])
        let sub = rows.first { $0["id"].string == "subtask:s1" }
        XCTAssertEqual(sub?["value"].string, "done")
        XCTAssertEqual(sub?["actions"].elements?.compactMap { $0["id"].string }, ["subtask_undo", "subtask_remove"])
        XCTAssertEqual(rows.first { $0["id"].string == "subtask:s2" }?["meta"]["assigneeName"].string, "Critic")
        XCTAssertEqual(rows.first { $0["id"].string == "person:critic" }?["actions"].elements?.count ?? 0, 0, "the main person is changed by Assign, not taken off")
        XCTAssertEqual(rows.first { $0["id"].string == "field:x1" }?["value"].string, "3")
        XCTAssertEqual(rows.first { $0["id"].string == "file:f1" }?["detail"].string?.isEmpty, false)
        XCTAssertEqual(rows.first { $0["id"].string == "activity:a1" }?["title"].string?.contains("In Progress".uppercased()), true,
                       "activity is said in the Mac's own words")
        let comment = rows.first { $0["id"].string == "comment:c1" }
        XCTAssertEqual(comment?["title"].string, "Asad")
        XCTAssertEqual(comment?["body"].string, "Looks good")
        XCTAssertEqual(comment?["value"].string, "human")
        XCTAssertEqual(comment?["meta"]["authorId"].string, "me")
    }

    func testThePageOffersPartsTrashAndTheTimerAtFullControlOnly() {
        func offered(_ level: BackendINT2PhoneAccessLevel) -> [String] {
            (page(level: level)["rows"].elements?.first?["actions"].elements ?? []).compactMap { $0["id"].string }
        }
        let full = offered(.full)
        for id in ["comment", "status", "priority", "dates", "assign", "tags", "details", "subtask_add", "checklist_add", "time_add", "delete",
                   "person_add", "dependency_add", "time_start"] {
            XCTAssertTrue(full.contains(id), "Full control offers \(id)")
        }
        let work = offered(.work)
        XCTAssertEqual(Set(work), ["comment", "status", "priority", "dates", "assign", "tags", "details"])
        XCTAssertEqual(offered(.look), ["comment"], "Look only adds nothing (the row's own actions are the list's)")
        let parts = page(level: .work)["rows"].elements?.dropFirst().flatMap { $0["actions"].elements ?? [] } ?? []
        XCTAssertTrue(parts.isEmpty, "no part offers an action the Work gate would refuse")
    }

    func testALongDescriptionIsEditedOnTheMac() {
        let ids = (page(level: .full, details: String(repeating: "x", count: 2_100))["rows"].elements?.first?["actions"].elements ?? []).compactMap { $0["id"].string }
        XCTAssertFalse(ids.contains("details"), "a value over the wire's 2,048 bytes is never offered for editing")
    }

    func testLineBreaksCrossTheWireAsLineSeparators() {
        XCTAssertEqual(BackendINT2PhoneTasks.text("First\u{2028}Second  "), "First\nSecond")
        XCTAssertEqual(BackendINT2PhoneTasks.formValue("a\nb\r\nc\u{7}"), "a\u{2028}b\u{2028}c")
        XCTAssertFalse(BackendRemoteProtocol.containsControls(BackendINT2PhoneTasks.formValue("x\ny")), "a prefilled value passes the wire's control check")
    }

    func testAnActionNamesItsTask() {
        let request = BackendRemotePanelRequest(path: "/P", scope: "task:local:9", query: nil)
        XCTAssertEqual(BackendINT2PhoneTasks.taskID(.init(panel: request, action: "subtask_done", id: "subtask:s1", fields: [:])), "local:9")
        XCTAssertEqual(BackendINT2PhoneTasks.taskID(.init(panel: .init(path: "/P", scope: nil, query: nil), action: "quick_status", id: nil, fields: ["task": "local:3"])), "local:3")
        XCTAssertEqual(try BackendINT2PhoneTasks.part(.init(panel: request, action: "subtask_done", id: "subtask:s1", fields: [:]), "subtask"), "s1")
        XCTAssertThrowsError(try BackendINT2PhoneTasks.part(.init(panel: request, action: "subtask_done", id: "item:s1", fields: [:]), "subtask"))
        XCTAssertFalse(BackendINT2PhoneTasks.handled.contains("edit"), "edit, move and run stay with the panel's own code")
    }

    func testTrackedTimeCountsTheRunningEntry() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let started = ISO8601DateFormatter().string(from: now.addingTimeInterval(-90))
        let result = BackendINT2PhoneTasks.tracked([o([("seconds", .number(60)), ("endedAt", .string("x"))]),
                                                    o([("startedAt", .string(started)), ("endedAt", .null), ("userId", .string("app:Phone"))])], now: now)
        XCTAssertEqual(result.seconds, 150)
        XCTAssertEqual(result.running?["userId"].string, "app:Phone")
    }

    /// 27 Oct walk (e): moving a task to the Trash from its own page is answered with the project's list, never with a
    /// re-read of the trashed task's page ("This task is no longer in this project."). Other page actions keep the page.
    func testATaskTrashedFromItsPageIsAnsweredWithTheList() {
        let page = BackendRemotePanelRequest(path: "/Projects/Phone", scope: "task:local:7", query: nil)
        let after = BackendINT2PhoneTasks.answering(page, removed: true)
        XCTAssertEqual(after.path, "/Projects/Phone"); XCTAssertNil(after.scope)
        XCTAssertEqual(BackendINT2PhoneTasks.answering(page, removed: false).scope, "task:local:7")
        let list = BackendRemotePanelRequest(path: "/Projects/Phone", scope: "open", query: "q")
        XCTAssertEqual(BackendINT2PhoneTasks.answering(list, removed: true).scope, "open")
    }

    /// 27 Oct walk (f): a phone's change is named by the phone ("Asad's iPhone"), never "AI app (AI app)".
    func testAPhonesChangeIsNamedByThePhone() {
        let phone = BackendTaskActor.deviceActor("Asad’s iPhone")
        XCTAssertEqual(phone, "device:Asad’s iPhone")
        XCTAssertEqual(BackendTaskActor.outsideActorName(phone), "Asad’s iPhone")
        XCTAssertEqual(BackendTaskBriefComposition.person(phone), "Asad’s iPhone")
        XCTAssertEqual(BackendTaskActor.outsideActorName("app:Cursor"), "Cursor (AI app)", "an AI app keeps its own wording")
        XCTAssertNil(BackendTaskActor.outsideActorName("me"))
        XCTAssertEqual(BackendTaskActor.deviceActor("  \n "), "device:Phone")
        XCTAssertEqual(BackendTaskActor.deviceActor(String(repeating: "x", count: 100)).count, "device:".count + 64)
        // A timer this phone started is still the one it may stop, by its new name and its older one.
        XCTAssertTrue(BackendINT2PhoneTasks.startedHere(.object([.init("userId", .string(phone))])))
        XCTAssertTrue(BackendINT2PhoneTasks.startedHere(.object([.init("userId", .string("app:Phone"))])))
        XCTAssertFalse(BackendINT2PhoneTasks.startedHere(.object([.init("userId", .string("me"))])))
    }
}
