import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("task-detail-local.test.ts case parity")
struct BackendCrmTaskDetailParityTests {
    @Test func d01PrimaryAssigneeAndAdditionalPeople() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(1000)
        try await BackendTaskClockContext.withClock(parityClock) {
            let f = try await BackendCrmTaskDetailParityFixture.make(), id = try await f.make("Ship the docs")
            #expect(crmParityEqual(await f.call("assignTask", .string(id), .string("builder")), crmParityFailure("Choose the project folder the agent should work in.")))
            #expect(crmParityEqual(await f.call("setTaskProject", .string(id), .string("/work/app")), crmParityValue(["ok": true, "project": "/work/app"])))
            #expect(crmParityEqual(await f.call("assignTask", .string(id), .string("builder")), crmParityOK()))
            #expect(await f.recorder.reassigned == [crmParityValue(["id": id, "to": "builder"])])
            #expect(crmParityEqual(await f.call("addTaskAssignee", .string(id), .string("hoot")), crmParityOK()))
            #expect(await f.call("addTaskAssignee", .string(id), .string("stranger"))["ok"].bool == false)
            let bundle = await f.bundle(id)
            #expect(crmParityMatches(bundle["people"]["primary"], crmParityValue(["id": "builder", "name": "Builder"])))
            #expect(crmParityStrings(bundle["people"]["others"], "id") == ["hoot"])
            #expect(crmParityEqual(await f.call("removeTaskAssignee", .string(id), .string("hoot")), crmParityOK()))
            let rows = await f.rows(id)
            #expect(Set(rows.compactMap { $0["kind"].string }).isSuperset(of: ["assigned", "unassigned", "field"]))
            #expect(rows.contains { $0["kind"].string == "assigned" && $0["payload"]["primary"].bool == true && crmParityMatches($0["payload"], crmParityValue(["user_id": "builder", "name": "Builder"])) })
            #expect(rows.contains { $0["kind"].string == "field" && crmParityMatches($0["payload"], crmParityValue(["label": "Project folder", "to": "/work/app"])) })
        
        }
    }
    @Test func d02TaskEditsAndSingleActivityLines() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(1000)
        try await BackendTaskClockContext.withClock(parityClock) {
            let f = try await BackendCrmTaskDetailParityFixture.make(), id = try await f.make("First line", crmParityValue(["instructions": "Old details"]))
            #expect(crmParityEqual(await f.call("updateTask", .string(id), crmParityValue(["title": "Better line", "description": "New details", "priority": "High", "startDate": "2026-10-08", "dueDate": "2026-10-09"])), crmParityOK()))
            #expect(crmParityMatches(try await f.row(id), crmParityValue(["title": "Better line", "instructions": "New details", "priority": "High", "startDate": "2026-10-08", "dueDate": "2026-10-09"])))
            _ = try await f.ok("setTaskStatus", .string(id), .string("In Progress"))
            #expect(await f.call("setTaskStatus", .string(id), .string("Cancelled"))["ok"].bool == false)
            #expect(crmParityEqual(await f.call("updateTask", .string(id), .object([])), crmParityFailure("Nothing to update")))
            let rows = await f.rows(id)
            for kind in ["status", "title"] { #expect(rows.filter { $0["kind"].string == kind }.count == 1) }
            #expect(rows.contains { $0["kind"].string == "status" && crmParityEqual($0["payload"], crmParityValue(["from": "To-Do", "to": "In Progress"])) })
            #expect(rows.contains { $0["kind"].string == "priority" && crmParityEqual($0["payload"], crmParityValue(["from": NSNull(), "to": "High"])) })
            #expect(rows.contains { $0["kind"].string == "dates" && crmParityMatches($0["payload"], crmParityValue(["start_to": "2026-10-08", "due_to": "2026-10-09"])) })
            #expect(rows.contains { $0["kind"].string == "created" })
            #expect(crmParityMatches(rows.first?["actor"] ?? .missing, crmParityValue(["id": "me", "name": "You"])))
            let history = await f.call("fetchDescriptionHistory", .string(id))
            #expect(history["versions"].elements?.count == 1)
            #expect(crmParityMatches(history["versions"].elements?.first ?? .missing, crmParityValue(["from": "Old details", "to": "New details", "by": "me"])))
            _ = await f.call("setTaskTimes", .string(id), crmParityValue(["dueTime": "17:00"]))
            _ = await f.call("updateTask", .string(id), crmParityValue(["dueDate": ""]))
            let cleared = try await f.row(id)
            #expect(cleared["dueDate"] == .null && cleared["dueTime"] == .null)
        
        }
    }
    @Test func d03SubtasksJoinPeopleAndRetainMetadata() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(1000)
        try await BackendTaskClockContext.withClock(parityClock) {
            let f = try await BackendCrmTaskDetailParityFixture.make(), id = try await f.make("Parent")
            let sub = try #require(await f.call("addTaskSubtask", .string(id), .string("  Write tests "))["id"].string)
            #expect(crmParityEqual(await f.call("addTaskSubtask", .string(id), .string(String(repeating: "x", count: 301))), crmParityFailure("Subtask title is required (max 300 chars)")))
            for (fn, arg) in [("setTaskSubtaskDone", NativeRPCValue.bool(true)), ("setTaskSubtaskAssignee", .string("tester"))] { _ = try await f.ok(fn, .string(id), .string(sub), arg) }
            _ = try await f.ok("setSubtaskMeta", .string(id), .string(sub), crmParityValue(["priority": "Critical", "dueDate": "2026-10-20"]))
            #expect(crmParityEqual(await f.call("setSubtaskMeta", .string(id), .string(sub), crmParityValue(["priority": "Huge"])), crmParityFailure("Invalid priority")))
            let b = await f.bundle(id)
            #expect(crmParityEqual(b["subtasks"], crmParityValue([["id": sub, "title": "Write tests", "done": true, "sortOrder": 0, "assigneeUserId": "tester"]])))
            #expect(crmParityStrings(b["people"]["others"], "id") == ["tester"])
            #expect(crmParityEqual(await f.call("fetchTaskPageExtras", .string(id))["extras"]["subtaskMeta"][sub], crmParityValue(["priority": "Critical", "dueDate": "2026-10-20"])))
            let rows = await f.rows(id)
            #expect(rows.contains { $0["kind"].string == "subtask_added" && crmParityEqual($0["payload"], crmParityValue(["subtask_id": sub, "title": "Write tests"])) })
            #expect(rows.contains { $0["kind"].string == "subtask_done" && crmParityEqual($0["payload"], crmParityValue(["subtask_id": sub, "title": "Write tests", "done": true])) })
            _ = try await f.ok("deleteTaskSubtask", .string(id), .string(sub))
            #expect(crmParityEqual(await f.call("deleteTaskSubtask", .string(id), .string(sub)), crmParityFailure("Subtask not found")))
        
        }
    }
    @Test func d04ChecklistsAddressItemsByOwnIDs() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(1000)
        try await BackendTaskClockContext.withClock(parityClock) {
            let f = try await BackendCrmTaskDetailParityFixture.make(), id = try await f.make("Checklist host")
            let list = try #require(await f.call("addChecklist", .string(id), .null)["id"].string)
            let item = try #require(await f.call("addChecklistItem", .string(list), .string("Buy milk"))["id"].string)
            #expect(crmParityEqual(await f.call("addChecklistItem", .string(list), .string("")), crmParityFailure("Item is required (max 300 chars)")))
            _ = try await f.ok("setChecklistItemDone", .string(item), .bool(true)); _ = try await f.ok("setChecklistItemAssignee", .string(item), .string("hoot"))
            _ = try await f.ok("renameChecklist", .string(list), .string("Errands"))
            let listRow = await f.bundle(id)["checklists"].elements?.first ?? .missing
            #expect(listRow["title"].string == "Errands")
            #expect(crmParityMatches(listRow["items"].elements?.first ?? .missing, crmParityValue(["title": "Buy milk", "done": true, "assigneeUserId": "hoot"])))
            let rows = await f.rows(id)
            #expect(rows.contains { $0["kind"].string == "checklist_added" && $0["payload"]["title"].string == "Checklist" })
            #expect(rows.filter { $0["kind"].string == "checklist_item" }.map { $0["payload"]["done"] } == [.bool(true), .null])
            _ = try await f.ok("deleteChecklistItem", .string(item)); _ = try await f.ok("deleteChecklist", .string(list))
            #expect(crmParityEqual(await f.call("renameChecklist", .string(list), .string("Gone")), crmParityFailure("Checklist not found")))
            #expect(await f.bundle(id)["checklists"].elements == [])
        
        }
    }
    @Test func d05DependenciesMirrorAndRemoveFromEitherSide() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(1000)
        try await BackendTaskClockContext.withClock(parityClock) {
            let f = try await BackendCrmTaskDetailParityFixture.make(), a = try await f.make("A"), b = try await f.make("B")
            #expect(crmParityEqual(await f.call("addTaskDependency", .string(a), .string(a), .string("blocks")), crmParityFailure("A task cannot depend on itself")))
            #expect(crmParityEqual(await f.call("addTaskDependency", .string(a), .string("k1:crm-task"), .string("blocks")), crmParityFailure("Other task not found or not yours")))
            #expect(crmParityEqual(await f.call("addTaskDependency", .string(a), .string(b), .string("sideways")), crmParityFailure("Invalid dependency kind")))
            for _ in 0..<2 { _ = try await f.ok("addTaskDependency", .string(a), .string(b), .string("blocks")) }
            #expect(crmParityEqual(await f.bundle(a)["dependencies"], crmParityValue([["kind": "blocks", "otherTaskId": b, "otherTitle": "B", "otherDone": false]])))
            _ = await f.call("setTaskStatus", .string(a), .string("Done"))
            #expect(crmParityEqual(await f.bundle(b)["dependencies"], crmParityValue([["kind": "blocked_by", "otherTaskId": a, "otherTitle": "A", "otherDone": true]])))
            _ = try await f.ok("removeTaskDependency", .string(b), .string(a), .string("blocked_by"))
            #expect(await f.bundle(a)["dependencies"].elements == [])
            #expect(crmParityEqual(await f.call("removeTaskDependency", .string(b), .string(a), .string("blocked_by")), crmParityFailure("Dependency not found")))
            #expect(await f.rows(a).contains { $0["kind"].string == "dependency" && crmParityMatches($0["payload"], crmParityValue(["kind": "blocks", "title": "B", "removed": false])) })
        
        }
    }
    @Test func d06UploadsChoosersAndOpenUseMemoryIO() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(1000)
        try await BackendTaskClockContext.withClock(parityClock) {
            let make = try #require(BackendCrmTaskDetailParityIOBinding.make, "Missing production attachment/chooser memory-IO adapter")
            let io = try await make(), f = io.fixture, id = try await f.make("Files")
            let png = Data([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a,1,2,3,4])
            let up = try await f.ok("uploadTaskFile", .string(id), BackendCrmDetailContract.LocalUpload(name: "shot.png", type: "image/png", bytes: png).wire)
            #expect(crmParityMatches(up["attachment"], crmParityValue(["kind": "upload", "fileName": "shot.png", "mimeType": "image/png", "sizeBytes": png.count, "previewUrl": "data:image/png;base64," + png.base64EncodedString()])))
            let path = try #require(up["attachment"]["storagePath"].string); #expect(try await io.readFile(path) == png)
            #expect(await f.call("uploadTaskFile", .string(id), BackendCrmDetailContract.LocalUpload(name: "tool.exe", type: "", bytes: png).wire)["error"].string?.contains("cannot be attached") == true)
            try await io.putFile("/picked/notes.txt", bytes: Data("hello".utf8)); try await io.putFile("/picked/empty.txt", bytes: Data())
            await io.chooseFiles(["/picked/notes.txt", "/picked/empty.txt"])
            let picked = try await f.ok("chooseTaskFiles", .string(id)), attachment = try #require(picked["attachments"].elements?.first)
            #expect(crmParityMatches(attachment, crmParityValue(["fileName": "notes.txt", "mimeType": "text/plain", "previewUrl": NSNull()])))
            #expect(picked["errors"] == crmParityValue(["The file is empty."]))
            _ = try await f.ok("openTaskFile", .string(id), attachment["id"])
            #expect(await io.opened().first?.hasSuffix("notes.txt") == true)
            await io.openAnswer("No application knows how to open it")
            #expect(await f.call("openTaskFile", .string(id), attachment["id"])["error"].string?.contains("No application") == true)
            #expect(await f.rows(id).filter { $0["kind"].string == "attachment" }.compactMap { $0["payload"]["file_name"].string } == ["notes.txt", "shot.png"])
        
        }
    }
    @Test func d07DocumentPointersRetainBytesUntilLastReference() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(1000)
        try await BackendTaskClockContext.withClock(parityClock) {
            let make = try #require(BackendCrmTaskDetailParityIOBinding.make), io = try await make(), f = io.fixture
            let a = try await f.make("Owner"), b = try await f.make("Other"), png = Data([0x89,0x50,0x4e,0x47])
            let up = try await f.ok("uploadTaskFile", .string(a), BackendCrmDetailContract.LocalUpload(name: "plan.pdf", type: "", bytes: png).wire)
            let hit = try #require(await f.call("searchTags", .string("file"), .string("pla"))["hits"].elements?.first)
            #expect(crmParityMatches(hit, crmParityValue(["id": a + "/" + (up["attachment"]["id"].string ?? ""), "label": "plan.pdf", "secondary": "Owner"])))
            _ = try await f.ok("attachExistingDocument", .string(b), hit["id"])
            let linked = try #require(await f.bundle(b)["attachments"].elements?.first)
            #expect(crmParityMatches(linked, crmParityValue(["kind": "document", "fileName": "plan.pdf", "documentId": hit["id"].string ?? "", "mimeType": "application/pdf"])))
            let path = try #require(up["attachment"]["storagePath"].string)
            _ = try await f.ok("detachTaskAttachment", up["attachment"]["id"]); #expect(await io.exists(path))
            _ = try await f.ok("openTaskFile", .string(b), linked["id"])
            _ = try await f.ok("detachTaskAttachment", linked["id"]); #expect(await io.exists(path) == false)
        
        }
    }
    @Test func d08TrashRetainsFilesAfterLastExternalPointerIsRemoved() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(1000)
        try await BackendTaskClockContext.withClock(parityClock) {
            let make = try #require(BackendCrmTaskDetailParityIOBinding.make), io = try await make(), f = io.fixture
            let a = try await f.make("Disposable"), b = try await f.make("Points at it")
            let up = try await f.ok("uploadTaskFile", .string(a), BackendCrmDetailContract.LocalUpload(name: "a.txt", type: "text/plain", bytes: Data([1,2,3])).wire)
            let path = try #require(up["attachment"]["storagePath"].string)
            let linked = try await f.ok("attachExistingDocument", .string(b), .string(a + "/" + (up["attachment"]["id"].string ?? "")))
            try await f.local.remove(a); #expect(await io.exists(path))
            #expect(crmParityEqual(await f.call("fetchTaskDetailBundle", .string(a)), crmParityFailure("That task no longer exists.")))
            _ = try await f.ok("detachTaskAttachment", linked["id"]); #expect(await io.exists(path))
            _ = try await f.local.restore(a)
            #expect(crmParityStrings(await f.bundle(a)["attachments"], "fileName") == ["a.txt"])
            _ = try await f.ok("openTaskFile", .string(a), up["attachment"]["id"]); #expect(await io.opened() == [io.pathForFile(path)])
        
        }
    }
    @Test func d09AllCustomFieldActions() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(1000)
        try await BackendTaskClockContext.withClock(parityClock) {
            let f = try await BackendCrmTaskDetailParityFixture.make(), id = try await f.make("Fields"), other = try await f.make("Linked task")
            let price = try await f.ok("createTaskField", .string(id), crmParityValue(["label": "Price", "kind": "number", "value": 12.345]))
            #expect(crmParityMatches(price["field"], crmParityValue(["label": "Price", "kind": "number", "value": 12.35, "taskId": id])))
            #expect(crmParityEqual(await f.call("createTaskField", .string(id), crmParityValue(["label": "price", "kind": "text"])), crmParityFailure("This task already has a field called “price”")))
            let qty = try await f.ok("createTaskField", .string(id), crmParityValue(["label": "Qty", "kind": "number"])), total = try await f.ok("createTaskField", .string(id), crmParityValue(["label": "Total", "kind": "formula", "config": ["expression": "{Price} * {Qty}"]]))
            #expect(await f.call("updateTaskFieldValue", qty["field"]["id"], .number(3))["field"]["value"] == .number(3))
            #expect(await f.call("updateTaskFieldValue", total["field"]["id"], .number(1))["ok"].bool == false)
            #expect(await f.call("renameTaskField", qty["field"]["id"], .string("Count"))["formulas"].elements?.first?["config"]["expression"].string == "{Price} * {Count}")
            let owners = try await f.ok("createTaskField", .string(id), crmParityValue(["label": "Owners", "kind": "people"])), links = try await f.ok("createTaskField", .string(id), crmParityValue(["label": "See also", "kind": "tasks"]))
            #expect(await f.call("updateTaskFieldValue", owners["field"]["id"], crmParityValue(["builder", "me"]))["field"]["value"] == crmParityValue(["builder", "me"]))
            #expect(await f.call("updateTaskFieldValue", owners["field"]["id"], crmParityValue(["ghost"]))["ok"].bool == false)
            #expect(crmParityEqual(await f.call("updateTaskFieldValue", links["field"]["id"], crmParityValue([["id": other, "label": "x"]]))["field"]["value"], crmParityValue([["id": other, "label": "Linked task"]])))
            #expect(crmParityEqual(await f.call("updateTaskFieldValue", links["field"]["id"], crmParityValue([["id": id, "label": "me"]])), crmParityFailure("A task cannot link to itself")))
            let vote = try await f.ok("createTaskField", .string(id), crmParityValue(["label": "Votes", "kind": "voting"]))
            #expect(crmParityEqual(await f.call("toggleTaskFieldVote", vote["field"]["id"])["field"]["value"], crmParityValue(["votes": ["me": true]])))
            #expect(await f.call("toggleTaskFieldVote", vote["field"]["id"])["field"]["value"] == .null)
            let progress = try await f.ok("createTaskField", .string(id), crmParityValue(["label": "Progress", "kind": "progress_auto"]))
            #expect(progress["field"]["kind"].string == "progress_auto")
            let sub = try await f.ok("addTaskSubtask", .string(id), .string("One")); _ = await f.call("addTaskSubtask", .string(id), .string("Two")); _ = await f.call("setTaskSubtaskDone", .string(id), sub["id"], .bool(true))
            let listed = try await f.ok("listTaskFields", .string(id))
            #expect(crmParityEqual(listed["auto"], crmParityValue(["subtasks": ["done": 1, "total": 2], "checklists": ["done": 0, "total": 0]])))
            #expect(listed["people"]["builder"]["name"].string == "Builder" && listed["viewerId"].string == "me")
            #expect(crmParityStrings(listed["fields"], "label") == ["Price", "Count", "Total", "Owners", "See also", "Votes", "Progress"])
            let button = try await f.ok("createTaskField", .string(id), crmParityValue(["label": "Finish", "kind": "button", "config": ["action": ["type": "status", "status": "Done"]]]))
            #expect(crmParityMatches(await f.call("pressTaskFieldButton", button["field"]["id"]), crmParityValue(["ok": true, "status": "Done", "field": ["value": ["count": 1, "lastBy": "me"]]])))
            #expect(try await f.row(id)["crmStatus"].string == "Done")
            let ids = Array((listed["fields"].elements ?? []).map { $0["id"] }.reversed())
            #expect(crmParityEqual(await f.call("reorderTaskFields", .string(id), .array(ids)), crmParityFailure("The fields changed — reload and try again")))
            _ = try await f.ok("reorderTaskFields", .string(id), .array([button["field"]["id"]] + ids)); _ = try await f.ok("deleteTaskField", price["field"]["id"])
            #expect(Set(await f.rows(id).filter { $0["kind"].string == "field" }.compactMap { $0["payload"]["action"].string }).isSuperset(of: ["added", "changed", "renamed", "voted", "pressed", "removed"]))
        
        }
    }
    @Test func d10CommentThreadsReactionsResolveAndSchedule() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(1000)
        try await BackendTaskClockContext.withClock(parityClock) {
            let f = try await BackendCrmTaskDetailParityFixture.make(), id = try await f.make("Talk")
            let first = try await f.ok("addTaskComment", .string(id), .string("Hello there")), reply = try await f.ok("addTaskCommentWith", .string(id), .string("A reply"), .object([.init("parentId", first["id"])]))
            let deeper = try await f.ok("addTaskCommentWith", .string(id), .string("Deeper"), .object([.init("parentId", reply["id"])]))
            #expect(crmParityEqual(await f.call("addTaskComment", .string(id), .string("   ")), crmParityFailure("Comment is required (max 2000 chars)")))
            #expect(crmParityEqual(await f.call("toggleCommentReaction", .string(id), first["id"], .string("👍")), crmParityValue(["ok": true, "on": true])))
            #expect(crmParityEqual(await f.call("toggleCommentReaction", .string(id), first["id"], .string("🦄")), crmParityFailure("That reaction is not offered")))
            _ = try await f.ok("setCommentResolved", .string(id), first["id"], .bool(true))
            var extras = await f.call("fetchCommentExtras", .string(id))["extras"]
            #expect(extras["meta"][deeper["id"].string ?? ""]["parentId"] == first["id"] && extras["meta"][first["id"].string ?? ""]["resolvedBy"].string == "me")
            #expect(crmParityEqual(extras["reactions"][first["id"].string ?? ""], crmParityValue([["emoji": "👍", "userIds": ["me"]]])))
            #expect(crmParityEqual(await f.call("toggleCommentReaction", .string(id), first["id"], .string("👍")), crmParityValue(["ok": true, "on": false])))
            _ = try await f.ok("assignComment", .string(id), first["id"], .string("tester")); extras = await f.call("fetchCommentExtras", .string(id))["extras"]
            #expect(crmParityMatches(extras["meta"][first["id"].string ?? ""], crmParityValue(["assigneeUserId": "tester", "resolvedBy": NSNull()])))
            #expect(!extras["reactions"].has(first["id"].string ?? ""))
            #expect(crmParityEqual(await f.call("addTaskCommentWith", .string(id), .string("Too late"), crmParityValue(["scheduledFor": "2000-01-01T00:00:00Z"])), crmParityFailure("Pick a time in the future")))
            let later = try await f.ok("addTaskCommentWith", .string(id), .string("Later"), crmParityValue(["scheduledFor": "2026-10-07T10:00:00.000Z"]))
            _ = try await f.ok("sendScheduledNow", .string(id), later["id"])
            #expect(crmParityEqual(await f.call("sendScheduledNow", .string(id), later["id"]), crmParityValue(["ok": true, "alreadySent": true])))
            #expect(await f.call("fetchCommentExtras", .string(id))["extras"]["meta"][later["id"].string ?? ""]["deliveredAt"].string != nil)
            let comments = await f.call("listTaskComments", .string(id))["comments"]
            #expect(crmParityStrings(comments, "body") == ["Hello there", "A reply", "Deeper", "Later"])
            #expect(crmParityMatches(comments.elements?.first ?? .missing, crmParityValue(["authorUserId": "me", "authorName": "You"])))
        
        }
    }
    @Test func d11AgentNotesMentionsRepliesAndDeduplication() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(1000)
        try await BackendTaskClockContext.withClock(parityClock) {
            let f = try await BackendCrmTaskDetailParityFixture.make(), id = try await f.make("Agent work", crmParityValue(["project": "/work/app"]))
            _ = await f.call("assignTask", .string(id), .string("builder"))
            try await f.store.note(id, by: "builder", kind: "question", text: "Which port?"); try await f.store.note(id, by: "builder", kind: "progress", text: "Started.")
            let question = try #require(await f.call("listTaskComments", .string(id))["comments"].elements?.first { $0["body"].string == "Which port?" })
            #expect(crmParityMatches(question, crmParityValue(["authorUserId": "builder", "authorName": "Builder"])))
            _ = await f.call("addTaskComment", .string(id), .string("Note to self")); #expect(await f.recorder.replies.isEmpty)
            _ = try await f.ok("addTaskComment", .string(id), .string("@Builder use 8080"))
            _ = await f.call("addTaskCommentWith", .string(id), .string("And restart it"), .object([.init("parentId", question["id"])]))
            _ = await f.call("addTaskComment", .string(id), .string("@Tester look"))
            #expect(await f.recorder.replies.compactMap { $0["text"].string } == ["@Builder use 8080", "And restart it"])
            try await f.store.note(id, by: "me", kind: "reply", text: "@Builder use 8080"); try await f.store.note(id, by: "me", kind: "reply", text: "An older reply")
            let comments = await f.call("listTaskComments", .string(id))["comments"].elements ?? []
            #expect(comments.filter { $0["body"].string == "@Builder use 8080" }.count == 1 && comments.contains { $0["body"].string == "An older reply" })
            #expect(crmParityEqual(await f.call("toggleCommentReaction", .string(id), question["id"], .string("✅")), crmParityValue(["ok": true, "on": true])))
        
        }
    }
    @Test func d12HandedBackAgentStillReceivesMentions() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(1000)
        try await BackendTaskClockContext.withClock(parityClock) {
            let f = try await BackendCrmTaskDetailParityFixture.make(), id = try await f.make("Handed back")
            _ = try await f.store.update(id, patch: crmParityValue(["handedFrom": "tester"]))
            _ = await f.call("addTaskComment", .string(id), .string("@tester done, carry on"))
            #expect(await f.recorder.replies == [crmParityValue(["id": id, "text": "@tester done, carry on"])])
            _ = try await f.store.update(id, patch: crmParityValue(["handedFrom": "gone-agent"]))
            #expect(await f.call("addTaskComment", .string(id), .string("nobody named"))["ok"].bool == true)
        
        }
    }
    @Test func d13HistoricalNotesBecomeSingleActivityRows() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(1000)
        try await BackendTaskClockContext.withClock(parityClock) {
            let f = try await BackendCrmTaskDetailParityFixture.make(), id = try await f.make("Old style")
            _ = try await f.store.update(id, patch: crmParityValue(["crmStatus": "Stuck"]))
            try await f.store.note(id, by: "builder", kind: "status", text: "Status: Stuck")
            try await f.store.note(id, by: "builder", kind: "assigned", text: "Handed to you.")
            try await f.store.note(id, by: "me", kind: "edited", text: "Changed the title, details.")
            let rows = await f.rows(id)
            #expect(rows.compactMap { $0["kind"].string } == ["title", "description", "assigned", "status", "created"])
            #expect(rows.contains { $0["kind"].string == "status" && crmParityMatches($0, crmParityValue(["actorUserId": "builder", "payload": ["from": NSNull(), "to": "Stuck"]])) })
            #expect(rows.contains { $0["kind"].string == "assigned" && $0["payload"]["user_id"].string == "me" })
            _ = await f.call("setTaskStatus", .string(id), .string("Done"))
            #expect(crmParityEqual(.array(await f.rows(id).filter { $0["kind"].string == "status" }.map { $0["payload"] }), crmParityValue([["from": "Stuck", "to": "Done"], ["from": NSNull(), "to": "Stuck"]])))
        
        }
    }
    @Test func d14TimersManualEntriesAndEntryTags() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(1000)
        try await BackendTaskClockContext.withClock(parityClock) {
            let factory = try #require(BackendCrmTaskDueParityBinding.make), driver = try await factory(false), f = driver.fixture
            let a = try await f.make("A"), b = try await f.make("B")
            #expect(await f.call("startTaskTimer", .string(a))["entry"]["endedAt"] == .null)
            let base = f.clock.now()
            await driver.setNow(base + 1000); _ = await f.call("startTaskTimer", .string(b))
            let aEntry = try #require(await f.call("fetchTaskPageExtras", .string(a))["extras"]["timeEntries"].elements?.first)
            #expect(aEntry["endedAt"].string != nil && (aEntry["seconds"].number ?? 0) > 0)
            #expect(await f.rows(a).contains { $0["kind"].string == "time_tracked" })
            await driver.setNow(base + 2000)
            #expect((await f.call("stopTaskTimer", .string(b))["entry"]["seconds"].number ?? 0) > 0)
            #expect(crmParityEqual(await f.call("stopTaskTimer", .string(b)), crmParityValue(["ok": true, "entry": NSNull()])))
            let manual = try await f.ok("addTaskTimeEntry", .string(a), crmParityValue(["seconds": 5400, "date": "2026-10-05", "note": "review"]))
            #expect(manual["entry"]["seconds"].number == 5400)
            #expect(crmParityEqual(await f.call("addTaskTimeEntry", .string(a), crmParityValue(["seconds": 60, "date": "2099-01-01"])), crmParityFailure("That day has not happened yet")))
            #expect(crmParityEqual(await f.call("addTaskTimeEntry", .string(a), crmParityValue(["seconds": 90000])), crmParityFailure("Enter a time between 1 minute and 24 hours")))
            #expect(crmParityEqual(await f.call("setTimeEntryTags", .string(a), manual["entry"]["id"], crmParityValue(["billing", "Billing", " ops "])), crmParityValue(["ok": true, "tags": ["billing", "ops"]])))
            #expect(await f.call("fetchTaskMore", .string(a))["more"]["entryTags"][manual["entry"]["id"].string ?? ""] == crmParityValue(["billing", "ops"]))
            _ = try await f.ok("setTimeEstimate", .string(a), .number(90)); #expect(try await f.row(a)["estimateMinutes"].number == 90)
            _ = try await f.ok("deleteTaskTimeEntry", .string(a), manual["entry"]["id"])
            #expect(crmParityEqual(await f.call("deleteTaskTimeEntry", .string(a), manual["entry"]["id"]), crmParityFailure("Time entry not found or not yours")))
        
        }
    }
    @Test func d15DuplicateArchiveMoveTypeTagsAndTimes() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(1000)
        try await BackendTaskClockContext.withClock(parityClock) {
            let f = try await BackendCrmTaskDetailParityFixture.make(), id = try await f.make("Original", crmParityValue(["project": "/work/app", "labels": ["web"]]))
            _ = await f.call("assignTask", .string(id), .string("builder")); _ = await f.call("addTaskSubtask", .string(id), .string("Sub"))
            let copy = try #require(await f.call("duplicateTask", .string(id))["id"].string)
            #expect(crmParityMatches(try await f.row(copy), crmParityValue(["title": "Original (copy)", "labels": ["web"], "project": "/work/app", "assignee": ["identity": "me"]])))
            #expect(crmParityStrings(await f.bundle(copy)["subtasks"], "title") == ["Sub"])
            #expect(crmParityStrings(await f.bundle(copy)["people"]["others"], "id") == ["builder"])
            _ = try await f.ok("setArchived", .string(id), .bool(true)); #expect(await f.call("fetchTaskMore", .string(id))["more"]["archivedAt"].string != nil)
            _ = try await f.ok("moveTask", .string(id), .string("Launch")); #expect(try await f.row(id)["board"].string == "Launch")
            _ = try await f.ok("moveTask", .string(id), .string("")); #expect(try await f.row(id)["board"] == .null)
            _ = try await f.ok("setTaskType", .string(id), .string("milestone"))
            #expect(crmParityEqual(await f.call("setTaskType", .string(id), .string("epic")), crmParityFailure("Invalid task type")))
            _ = try await f.ok("setTaskLabels", .string(id), crmParityValue(["web", "Docs", "docs"])); #expect(try await f.row(id)["labels"] == crmParityValue(["web", "Docs"]))
            _ = try await f.ok("setTaskTimes", .string(id), crmParityValue(["startTime": "09:30"]))
            #expect(crmParityEqual(await f.call("setTaskTimes", .string(id), crmParityValue(["startTime": "9am"])), crmParityFailure("Invalid time")))
            #expect(Set(await f.rows(id).compactMap { $0["kind"].string }).isSuperset(of: ["archived", "moved", "task_type", "tags", "dates"]))
            #expect(crmParityEqual(await f.call("setTaskLinks", .string(id), .array([])), crmParityFailure("Related records live in a CRM; local tasks cannot link to them.")))
        
        }
    }
    @Test func d16MergeAndConvertPreservePartsAndRemoveSourceRows() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(1000)
        try await BackendTaskClockContext.withClock(parityClock) {
            let factory = try #require(BackendCrmTaskDetailParityIOBinding.make), io = try await factory(), f = io.fixture
            let source = try await f.make("Source"), target = try await f.make("Target")
            _ = await f.call("addTaskSubtask", .string(source), .string("Moved subtask")); _ = await f.call("addTaskComment", .string(source), .string("Moved comment")); _ = await f.call("addTaskAssignee", .string(source), .string("tester"))
            let up = try await f.ok("uploadTaskFile", .string(source), BackendCrmDetailContract.LocalUpload(name: "keep.txt", type: "text/plain", bytes: Data([1])).wire)
            #expect(crmParityEqual(await f.call("mergeTaskInto", .string(source), .string(source)), crmParityFailure("Pick another task")))
            _ = try await f.ok("mergeTaskInto", .string(source), .string(target)); #expect(try await f.store.byID(source) == nil)
            let bundle = await f.bundle(target)
            #expect(crmParityStrings(bundle["subtasks"], "title") == ["Moved subtask"] && crmParityStrings(bundle["people"]["others"], "id") == ["tester"] && crmParityStrings(bundle["attachments"], "fileName") == ["keep.txt"])
            #expect(await io.exists(up["attachment"]["storagePath"].string ?? ""))
            #expect(crmParityStrings(await f.call("listTaskComments", .string(target))["comments"], "body") == ["Moved comment"])
            #expect(await f.rows(target).contains { $0["kind"].string == "merged" && crmParityMatches($0["payload"], crmParityValue(["title": "Source", "people_added": ["tester"]])) })
            let child = try await f.make("Becomes a subtask\nwith more text"); _ = await f.call("setTaskStatus", .string(child), .string("Done"))
            _ = try await f.ok("convertToSubtask", .string(child), .string(target)); #expect(try await f.store.byID(child) == nil)
            #expect(crmParityMatches(await f.bundle(target)["subtasks"].elements?.last ?? .missing, crmParityValue(["title": "Becomes a subtask", "done": true, "assigneeUserId": "me"])))
        
        }
    }
    @Test func d17SubtaskDatesCanDriveParentDates() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(1000)
        try await BackendTaskClockContext.withClock(parityClock) {
            let f = try await BackendCrmTaskDetailParityFixture.make(), id = try await f.make("Span")
            let one = try await f.ok("addTaskSubtask", .string(id), .string("One")), two = try await f.ok("addTaskSubtask", .string(id), .string("Two"))
            _ = await f.call("setSubtaskMeta", .string(id), one["id"], crmParityValue(["dueDate": "2026-10-12"])); _ = await f.call("setSubtaskMeta", .string(id), two["id"], crmParityValue(["dueDate": "2026-10-20"]))
            #expect(crmParityEqual(await f.call("setSyncSubtaskDates", .string(id), .bool(true)), crmParityValue(["ok": true, "startDate": "2026-10-12", "dueDate": "2026-10-20"])))
            #expect(crmParityMatches(try await f.row(id), crmParityValue(["startDate": "2026-10-12", "dueDate": "2026-10-20"])))
            _ = await f.call("setSubtaskMeta", .string(id), two["id"], crmParityValue(["dueDate": "2026-10-25"]))
            #expect(try await f.row(id)["dueDate"].string == "2026-10-25")
            #expect(await f.call("fetchTaskMore", .string(id))["more"]["syncSubtaskDates"].bool == true)
        
        }
    }
    @Test func d18FollowersReminderAvailabilityAndGlobalTagColors() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(1000)
        try await BackendTaskClockContext.withClock(parityClock) {
            let make = try #require(BackendCrmTaskDetailParityIOBinding.make), io = try await make(), f = io.fixture
            let a = try await f.make("A", crmParityValue(["labels": ["urgent"]])), b = try await f.make("B", crmParityValue(["labels": ["Urgent", "web"]]))
            #expect(crmParityMatches(await f.call("fetchTaskMore", .string(a))["more"], crmParityValue(["iFollow": true, "followers": [["userId": "me"]], "remindersLive": false, "canColorTags": true, "canRemoveFollowers": false])))
            for (fn, value) in [("setFollowing", NativeRPCValue.bool(false)), ("addFollower", .string("hoot")), ("removeFollower", .string("me"))] {
                #expect(crmParityEqual(await f.call(fn, .string(a), value), crmParityFailure("Only you see tasks on this computer, so there is nobody else to follow this one — and nothing to unfollow.")))
            }
            #expect(crmParityEqual(await f.call("setReminder", .string(a), .string("2099-01-01T00:00:00Z"), .string("Ping")), crmParityFailure("Nothing on this computer delivers reminders.")))
            #expect(await f.call("fetchTaskMore", .string(a))["more"]["reminders"].elements == [])
            _ = try await f.ok("setLabelColor", .string("Urgent"), .string("red"))
            #expect(await io.hasSettingsFile())
            #expect(crmParityEqual(await f.call("setLabelColor", .string("Urgent"), .string("neon")), crmParityFailure("Invalid colour")))
            #expect(crmParityEqual(await f.call("fetchTaskMore", .string(b))["more"]["labelColors"], crmParityValue(["urgent": "red"])))
            let fresh = try await io.freshDetail()
            #expect(crmParityEqual(await fresh.call("fetchTaskMore", arguments: [.string(b)])["more"]["labelColors"], crmParityValue(["urgent": "red"])))
            #expect(crmParityEqual(await f.call("deleteLabelEverywhere", .string("URGENT")), crmParityValue(["ok": true, "removed": 2, "keptElsewhere": 0, "taskIds": [a,b]])))
            let aRow = try await f.row(a), bRow = try await f.row(b)
            #expect(aRow["labels"].elements == [] && bRow["labels"] == crmParityValue(["web"]))
            #expect(await f.call("fetchTaskMore", .string(b))["more"]["labelColors"].fields == [])
        
        }
    }
    @Test func d19RoutineRuleVersionPauseStopAndLegacyMirror() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(1000)
        try await BackendTaskClockContext.withClock(parityClock) {
            let f = try await BackendCrmTaskDetailParityFixture.make(), id = try await f.make("Weekly report", crmParityValue(["dueDate": "2026-10-09"]))
            #expect(crmParityMatches(await f.call("fetchRoutine", .string(id))["routine"], crmParityValue(["rule": NSNull(), "next": [], "version": 0])))
            var rule = RoutineRule(); rule.unit = "week"; rule.weekdays = [5]
            #expect(crmParityEqual(await f.call("saveRoutine", .string(id), BackendCrmWire.native(Routine.serialize(rule)), .number(0)), crmParityValue(["ok": true, "rootTaskId": id, "version": 1])))
            #expect(try await f.row(id)["recurrence"].string == "weekly")
            let view = await f.call("fetchRoutine", .string(id))["routine"]
            #expect(view["next"] == crmParityValue(["2026-10-16", "2026-10-23", "2026-10-30"]) && view["rule"]["anchor"].string == "2026-10-09")
            #expect(await f.call("saveRoutine", .string(id), .null, .number(0))["ok"].bool == false)
            _ = try await f.ok("pauseRoutine", .string(id), .bool(true)); #expect(await f.call("fetchRoutine", .string(id))["routine"]["next"].elements == [])
            _ = try await f.ok("stopRoutine", .string(id)); #expect(try await f.row(id)["recurrence"] == .null)
            #expect(crmParityEqual(await f.call("stopRoutine", .string(id)), crmParityFailure("This task does not repeat.")))
            _ = try await f.ok("setTaskRecurrence", .string(id), .string("daily"), .null); #expect(try await f.row(id)["recurrence"].string == "daily")
            _ = try await f.ok("updateTask", .string(id), crmParityValue(["recurrence": NSNull()])); #expect(try await f.row(id)["recurrence"] == .null)
            #expect(await f.rows(id).filter { $0["kind"].string == "recurrence" }.count > 2)
        
        }
    }
    @Test func d20LocalTagSearchStartsAtTwoCharacters() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(1000)
        try await BackendTaskClockContext.withClock(parityClock) {
            let f = try await BackendCrmTaskDetailParityFixture.make(), id = try await f.make("Refactor the parser")
            #expect(crmParityEqual(await f.call("searchTags", .string("person"), .string("b")), crmParityValue(["ok": true, "hits": []])))
            #expect(crmParityStrings(await f.call("searchTags", .string("person"), .string("bui"))["hits"], "id") == ["builder"])
            let hit = try #require(await f.call("searchTags", .string("task"), .string("pars"))["hits"].elements?.first)
            #expect(crmParityMatches(hit, crmParityValue(["id": id, "status": "To-Do", "href": "/tasks?task=" + id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()")))! /* encodeURIComponent, task-detail-local.test.ts:579 */])))
            #expect(crmParityEqual(await f.call("searchTags", .string("listing"), .string("anything")), crmParityValue(["ok": true, "hits": []])))
        
        }
    }
    @Test func d21ProjectChooserCancelAndFullPathRefusal() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(1000)
        try await BackendTaskClockContext.withClock(parityClock) {
            let make = try #require(BackendCrmTaskDetailParityIOBinding.make), io = try await make(), f = io.fixture, id = try await f.make("Needs a folder")
            #expect(crmParityEqual(await f.call("chooseTaskProject", .string(id)), crmParityValue(["ok": true, "project": "", "chosen": false])))
            await io.chooseFolder("/work/site")
            #expect(crmParityEqual(await f.call("chooseTaskProject", .string(id)), crmParityValue(["ok": true, "project": "/work/site", "chosen": true])))
            #expect(crmParityEqual(await f.call("setTaskProject", .string(id), .string("relative/path")), crmParityFailure("relative/path is not a full folder path.")))
        
        }
    }
    @Test func d22ForeignTasksAreHiddenAndOnlyWritesEmitChanges() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(1000)
        try await BackendTaskClockContext.withClock(parityClock) {
            let f = try await BackendCrmTaskDetailParityFixture.make(), seed = try await f.make("temp")
            _ = try await f.store.put(try await f.row(seed).setting("id", .string("k1:crm")).setting("keyId", .string("k1")).setting("externalTaskId", .string("crm")).setting("local", .missing))
            for id in ["k1:crm", "local:nope"] { #expect(crmParityEqual(await f.call("fetchTaskDetailBundle", .string(id)), crmParityFailure("That task no longer exists."))) }
            let id = try await f.make("Count changes"); await f.recorder.resetChanges()
            _ = await f.call("listTaskComments", .string(id)); #expect(await f.recorder.changes == 0)
            _ = await f.call("addTaskComment", .string(id), .string("hi")); #expect(await f.recorder.changes == 1)
            #expect(crmParityEqual(await f.call("addTaskSubtask", .number(42), .string("x")), crmParityFailure("That request was not understood.")))
        
        }
    }
}
