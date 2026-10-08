import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("local-task-tools.test.ts case parity")
struct BackendCrmTaskToolsParityTests {
    @Test func l01SchemasAreIndexedClosedAndUseSourceNames() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let r = try await BackendCrmTaskToolsParityFixture.make(localOnly: true)
            let ids = ["tasks.local", "tasks.local_change", "tasks.local_parts", "tasks.local_schedule", "tasks.agents", "hoot.island"]
            for id in ids {
                let spec = try r.spec(id)
                #expect(spec.wireName == id.replacingOccurrences(of: ".", with: "_") && spec.description.count > 20 && !spec.advertised)
                #expect(spec.inputSchema["type"].string == "object" && spec.inputSchema["additionalProperties"].bool == false)
                #expect(spec.inputSchema["required"].elements?.contains(.string("do")) == true)
                #expect(spec.inputSchema["properties"]["do"]["enum"].elements != nil)
            }
            #expect(r.registrations.filter { ids.contains($0.0.id) }.count == 6)
        
        }
    }
    @Test func l02EveryVerbUsesItsSourceTier() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let r = try await BackendCrmTaskToolsParityFixture.make(localOnly: true)
            #expect(try r.spec("tasks.local").tier == .read)
            let groups: [(String,[String],BackendMCPTier)] = [("tasks.local_change",["status","comment","reply"],.act),("tasks.local_change",["create","update","assign","archive","unarchive","delete","restore"],.alter),("tasks.local_parts",["subtask_add","subtask_done","checklist_item_done","field_set","time_start","time_add"],.act),("tasks.local_parts",["subtask_remove","checklist_remove","field_remove","attach_file","attachment_remove","time_remove"],.alter),("tasks.local_schedule",["reminder_set","comment_schedule"],.act),("tasks.local_schedule",["repeat_set","repeat_stop","repeat_restart"],.alter),("tasks.agents",["list"],.read),("tasks.agents",["save"],.alter)]
            for (id, verbs, expected) in groups {
                for verb in verbs {
                    let before = await r.audit.tiers.count
                    let input = id == "tasks.agents" && verb == "save" ? crmParityValue(["do": verb, "agent": ["id": "builder", "name": "Builder"]]) : crmParityValue(["do": verb])
                    do { _ = try await r.call(id, input) } catch {}
                    let tiers = await r.audit.tiers
                    #expect(tiers.count > before && tiers.last == expected, "\(id) \(verb)")
                }
            }
            #expect(try r.spec("hoot.island").tier == .read)
        
        }
    }
    @Test func l03TasksSwitchAndHootAudienceAreEnforced() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let r = try await BackendCrmTaskToolsParityFixture.make(localOnly: true)
            #expect(await r.refused("tasks.local", crmParityValue(["do": "list"]), caller: "key-off").contains("may not use your tasks"))
            #expect(await r.refused("tasks.local", crmParityValue(["do": "list"]), caller: "key-off").contains("Settings → Connect an AI app → Your tasks"))
            #expect(try await r.call("tasks.local", crmParityValue(["do": "list"]), caller: "key-on")["tasks"].elements == [])
            for caller in ["hoot", "key-on"] { for id in ["tasks.local","tasks.local_change","tasks.local_parts","tasks.local_schedule","tasks.agents"] { #expect(try r.spec(id).id == id); _ = caller } }
            #expect(await r.refused("hoot.island", crmParityValue(["do": "get"]), caller: "key-on").contains("Hoot’s own tool"))
        
        }
    }
    @Test func l04FolderScopedReadsHideOutsideRecords() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let r = try await BackendCrmTaskToolsParityFixture.make(localOnly: true), inside = try await r.create("Inside", crmParityValue(["project": "/work/app"])), outside = try await r.create("No folder")
            #expect(crmParityStrings(try await r.call("tasks.local", crmParityValue(["do":"list"]), caller:"key-on", folder:"/work/app")["tasks"], "task") == [inside])
            #expect(await r.refused("tasks.local", crmParityValue(["do":"get","task":outside]), caller:"key-on", folder:"/work/app") == "there is no task \(outside)")
            #expect(await r.refused("tasks.local", crmParityValue(["do":"get","task":"local:nope"]), caller:"key-on", folder:"/work/app") == "there is no task local:nope")
            #expect(await r.refused("tasks.local_change", crmParityValue(["do":"create","title":"Loose"]), caller:"key-on", folder:"/work/app").contains("limited to some folders"))
            #expect(try await r.create("Scoped one", crmParityValue(["project":"/work/app"]), caller:"key-on", folder:"/work/app").hasPrefix("local:"))
        
        }
    }
    @Test func l05OpenFolderAndCRMAuthorityAreRequired() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let r = try await BackendCrmTaskToolsParityFixture.make(localOnly: true)
            #expect(await r.refused("tasks.local_change", crmParityValue(["do":"create","title":"Elsewhere","project":"/etc"])).contains("not inside a folder Terminal Deck has open"))
            let id = try await r.create("Seed"), seed = try await r.f.row(id)
            _ = try await r.f.store.put(seed.setting("id", .string("k1:42")).setting("keyId", .string("k1")).setting("externalTaskId", .string("42")).setting("local", .bool(false)))
            #expect(await r.refused("tasks.local_change", crmParityValue(["do":"status","task":"k1:42","status":"Done"])).contains("CRM task: the CRM owns it"))
        
        }
    }
    @Test func l06CRUDCommentsAndActivityRetainCallerIdentity() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let r = try await BackendCrmTaskToolsParityFixture.make(localOnly: true), id = try await r.create("Ship the notes", crmParityValue(["details":"For 0.19","priority":"High","labels":["docs"]]))
            #expect(crmParityMatches(try await r.f.row(id), crmParityValue(["title":"Ship the notes","instructions":"For 0.19","priority":"High","labels":["docs"],"crmStatus":"To-Do"])))
            #expect(crmParityMatches(try await r.f.row(id)["notes"].elements?.first ?? .missing, crmParityValue(["by":"hoot","text":"Created, assigned to you."])))
            _ = try await r.call("tasks.local_change", crmParityValue(["do":"update","task":id,"due_date":"2026-10-20","board":"Release"]))
            _ = try await r.call("tasks.local_change", crmParityValue(["do":"status","task":id,"status":"In Progress"]))
            #expect(crmParityMatches(try await r.f.row(id), crmParityValue(["dueDate":"2026-10-20","board":"Release","crmStatus":"In Progress"])))
            #expect(await r.refused("tasks.local_change", crmParityValue(["do":"assign","task":id,"assignee":"builder"])).contains("project folder"))
            _ = try await r.call("tasks.local_change", crmParityValue(["do":"assign","task":id,"assignee":"builder","project":"/work/app"]))
            #expect(await r.f.recorder.started == [id])
            let comment = try await r.call("tasks.local_change", crmParityValue(["do":"comment","task":id,"text":"Started on it"]))
            let comments = try await r.call("tasks.local", crmParityValue(["do":"comments","task":id]))["comments"].elements ?? []
            #expect(comments.filter { $0["id"] == comment["comment"] }.count == 1)
            #expect(comments.contains { $0["id"] == comment["comment"] && crmParityMatches($0, crmParityValue(["authorUserId":"hoot","body":"Started on it"])) })
            let app = try await r.create("From the app", caller:"key-on")
            #expect(try await r.f.row(app)["notes"].elements?.first?["by"].string == "app:Claude Desktop")
            #expect(try await r.call("tasks.local", crmParityValue(["do":"activity","task":app]), caller:"key-on")["activity"].compact.contains("\"by\":\"me\"") == false)
        
        }
    }
    @Test func l07ArchiveTrashAndRestoreNeverPurge() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let r = try await BackendCrmTaskToolsParityFixture.make(localOnly:true), id = try await r.create("Old idea")
            _ = try await r.call("tasks.local_change", crmParityValue(["do":"archive","task":id])); #expect(try await r.f.row(id)["archivedAt"].number != nil)
            #expect(crmParityStrings(try await r.call("tasks.local", crmParityValue(["do":"list","archived":true]))["tasks"],"task") == [id])
            _ = try await r.call("tasks.local_change", crmParityValue(["do":"unarchive","task":id]))
            #expect(try await r.call("tasks.local_change", crmParityValue(["do":"delete","task":id]))["trashed"].string == id)
            #expect(try await r.f.store.byID(id) == nil)
            #expect(crmParityStrings(try await r.call("tasks.local", crmParityValue(["do":"trash"]))["trash"],"task") == [id])
            _ = try await r.call("tasks.local_change", crmParityValue(["do":"restore","task":id])); #expect(try await r.f.row(id)["title"].string == "Old idea")
        
        }
    }
    @Test func l08PartsFieldsAttachmentsAndTimeUsePopupOperations() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let r = try await BackendCrmTaskToolsParityFixture.make(localOnly:true), id = try await r.create("Launch", crmParityValue(["project":"/work/app"])), other = try await r.create("Write the post", crmParityValue(["project":"/work/app"]))
            try await r.io.putFile("/work/app/plan.txt",bytes:Data("the plan".utf8))
            let sub = try await r.call("tasks.local_parts", crmParityValue(["do":"subtask_add","task":id,"text":"Book the venue"]))["id"]
            _ = try await r.call("tasks.local_parts", .object([.init("do",.string("subtask_done")),.init("task",.string(id)),.init("item",sub),.init("done",.bool(true))]))
            let list = try await r.call("tasks.local_parts", crmParityValue(["do":"checklist_add","task":id,"text":"Before"]))["id"]
            let item = try await r.call("tasks.local_parts", .object([.init("do",.string("checklist_item_add")),.init("task",.string(id)),.init("checklist",list),.init("text",.string("Send invites"))]))["id"]
            _ = try await r.call("tasks.local_parts", .object([.init("do",.string("checklist_item_done")),.init("task",.string(id)),.init("item",item),.init("done",.bool(true))]))
            _ = try await r.call("tasks.local_parts", crmParityValue(["do":"dependency_add","task":id,"other":other,"kind":"blocked_by"]))
            let field = try await r.call("tasks.local_parts", crmParityValue(["do":"field_create","task":id,"label":"Venue","kind":"text"]))["field"]["id"]
            _ = try await r.call("tasks.local_parts", .object([.init("do",.string("field_set")),.init("task",.string(id)),.init("field",field),.init("value",.string("North hall"))]))
            let attached = try await r.call("tasks.local_parts", crmParityValue(["do":"attach_file","task":id,"path":"/work/app/plan.txt"]))
            _ = try await r.call("tasks.local_parts", crmParityValue(["do":"time_add","task":id,"duration":"1h 20m"]))
            let full = try await r.call("tasks.local", crmParityValue(["do":"get","task":id]))
            #expect(full["subtasks"].elements?.first?["done"].bool == true && full["subtasks"].elements?.first?["title"].string == "Book the venue")
            #expect(full["dependencies"].elements?.first?["kind"].string == "blocked_by" && full["checklists"].elements?.first?["items"].elements?.first?["done"].bool == true)
            #expect(crmParityMatches(full["fields"].elements?.first ?? .missing, crmParityValue(["label":"Venue","value":"North hall"])))
            #expect(crmParityStrings(full["attachments"],"fileName") == ["plan.txt"] && attached["attachment"].fields != nil)
            #expect(crmParityMatches(full["timeEntries"].elements?.first ?? .missing, crmParityValue(["seconds":4800,"userId":"hoot"])))
            #expect(await r.refused("tasks.local_parts", .object([.init("do",.string("subtask_done")),.init("task",.string(other)),.init("item",sub),.init("done",.bool(false))])).contains("has no subtask"))
            #expect(await r.refused("tasks.local_parts", crmParityValue(["do":"attach_file","task":id,"path":"/etc/hosts"])).contains("not inside a folder"))
        
        }
    }
    @Test func l09HootTimerCannotStopThePersonsTimer() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let r = try await BackendCrmTaskToolsParityFixture.make(localOnly:true), id = try await r.create("Pair on it")
            _ = await r.f.detail.call("startTaskTimer", arguments:[.string(id)], by:"me")
            _ = try await r.call("tasks.local_parts", crmParityValue(["do":"time_start","task":id]))
            var running = try await r.f.row(id)["detail"]["time"].elements ?? []
            #expect(running.filter { $0["endedAt"] == .null }.compactMap { $0["userId"].string }.sorted() == ["hoot","me"])
            _ = try await r.call("tasks.local_parts", crmParityValue(["do":"time_stop","task":id])); running = try await r.f.row(id)["detail"]["time"].elements ?? []
            #expect(running.filter { $0["endedAt"] == .null }.compactMap { $0["userId"].string } == ["me"])
        
        }
    }
    @Test func l10RepeatReminderAndScheduledCommentTools() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let r = try await BackendCrmTaskToolsParityFixture.make(localOnly:true), id = try await r.create("Weekly report", crmParityValue(["due_date":"2026-10-09"]))
            var rule = RoutineRule(); rule.unit = "week"
            _ = try await r.call("tasks.local_schedule", crmParityValue(["do":"repeat_set","task":id]).setting("rule",BackendCrmWire.native(Routine.serialize(rule))))
            #expect(try await r.call("tasks.local", crmParityValue(["do":"routine","task":id]))["routine"]["rule"]["frequency"].string == "weekly")
            _ = try await r.call("tasks.local_schedule", crmParityValue(["do":"repeat_pause","task":id]))
            _ = try await r.call("tasks.local_schedule", crmParityValue(["do":"reminder_set","task":id,"at":"2026-10-07T10:00:00.000Z","note":"Check"]))
            #expect(try await r.call("tasks.local", crmParityValue(["do":"get","task":id]))["reminders"].elements?.count == 1)
            #expect(try await r.call("tasks.local_schedule", crmParityValue(["do":"comment_schedule","task":id,"text":"Reminder for the team","at":"2026-10-07T11:00:00.000Z"]))["id"].string != nil)
        
        }
    }
    @Test func l11AgentCRUDAndHootIsland() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let r = try await BackendCrmTaskToolsParityFixture.make(localOnly:true)
            #expect(crmParityStrings(try await r.call("tasks.agents",crmParityValue(["do":"list"]))["agents"],"id") == ["builder"])
            _ = try await r.call("tasks.agents",crmParityValue(["do":"save","agent":["name":"Reviewer","role":"review","instructions":"Read before you write."]]))
            #expect(try await r.f.config.allAgents().compactMap { $0["name"].string } == ["Builder","Reviewer"])
            _ = try await r.call("tasks.agents",crmParityValue(["do":"save","agent":["id":"builder","model":"opus"]]))
            #expect(crmParityMatches(try await r.f.config.agent("builder") ?? .missing,crmParityValue(["name":"Builder","model":"opus"])))
            let reviewer = try #require(try await r.f.config.allAgents().first { $0["name"].string == "Reviewer" }?["id"].string)
            _ = try await r.call("tasks.agents",crmParityValue(["do":"remove","id":reviewer])); #expect(try await r.f.config.allAgents().compactMap { $0["id"].string } == ["builder"])
            #expect(crmParityEqual(try await r.call("hoot.island",crmParityValue(["do":"get"])),crmParityValue(["enabled":true])))
            #expect(crmParityEqual(try await r.call("hoot.island",crmParityValue(["do":"set","enabled":false])),crmParityValue(["enabled":false])))
        
        }
    }
    @Test func l12AgentPauseArchiveRestoreAndPickability() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let r = try await BackendCrmTaskToolsParityFixture.make(localOnly:true)
            #expect(crmParityEqual(try await r.call("tasks.agents",crmParityValue(["do":"pause","id":"builder"])),crmParityValue(["agent":"builder","status":"paused"])))
            #expect(crmParityEqual(try await r.call("tasks.agents",crmParityValue(["do":"archive","id":"builder"])),crmParityValue(["agent":"builder","status":"archived"])))
            #expect(try await r.f.config.allAgents().filter { $0["status"].string == "active" }.isEmpty)
            #expect(try await r.call("tasks.agents",crmParityValue(["do":"list"]))["agents"].elements?.first?["status"].string == "archived")
            #expect(crmParityEqual(try await r.call("tasks.agents",crmParityValue(["do":"restore","id":"builder"])),crmParityValue(["agent":"builder","status":"active"])))
            #expect(try r.spec("tasks.agents").inputSchema["properties"]["do"]["enum"].elements?.contains(.string("archive")) == true)
        
        }
    }
    @Test func l13KeysCanAddBlocksButOnlyOwnerCanLiftThem() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let r = try await BackendCrmTaskToolsParityFixture.make(localOnly:true)
            _ = try await r.f.config.saveAgent(try await r.f.config.agent("builder")!.merging(crmParityValue(["provider":"claude","blockedTools":["WebFetch"],"skillsOff":true])))
            #expect(await r.refused("tasks.agents",crmParityValue(["do":"save","agent":["id":"builder","blockedTools":[],"skillsOff":false,"model":"opus"]])).contains("Removing the WebFetch block needs the owner"))
            _ = try await r.call("tasks.agents",crmParityValue(["do":"save","agent":["id":"builder","model":"opus","blockedTools":["WebFetch","Edit"]]]))
            #expect(crmParityMatches(try await r.f.config.agent("builder") ?? .missing,crmParityValue(["model":"opus","blockedTools":["WebFetch","Edit"],"skillsOff":true])))
            _ = try await r.call("tasks.agents",crmParityValue(["do":"save","agent":["name":"Fresh","provider":"claude","blockedTools":["Bash"],"skillsOff":true]]))
            #expect(crmParityMatches(try await r.f.config.allAgents().first { $0["name"].string == "Fresh" } ?? .missing,crmParityValue(["blockedTools":["Bash"],"skillsOff":true])))
        
        }
    }
    @Test func l14UnknownVerbIsRefusedBeforeWorkRuns() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let r = try await BackendCrmTaskToolsParityFixture.make(localOnly:true)
            #expect(await r.refused("tasks.local_change",crmParityValue(["do":"purge","task":"x"])).contains("do must be one of"))
            #expect(try r.spec("tasks.local_change").inputSchema["properties"]["do"]["enum"].elements?.contains(.string("purge")) == false)
            #expect(try await r.f.store.all().isEmpty)
        
        }
    }
}

@Suite("goal-tools.test.ts case parity")
struct BackendCrmGoalToolsParityTests {
    let goalIDs = ["tasks.goals","tasks.plan","tasks.progress","tasks.retry","tasks.reassign","tasks.review"]
    @Test func g01SixHootGoalToolsAndTheirTiers() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let r = try await BackendCrmTaskToolsParityFixture.make()
            #expect(try goalIDs.map { try r.spec($0).wireName } == ["tasks_goals","tasks_plan","tasks_progress","tasks_retry","tasks_reassign","tasks_review"])
            for id in goalIDs { let spec = try r.spec(id); #expect(!spec.advertised && spec.description.count > 20 && spec.id.hasPrefix("tasks.")) }
            for (id,tier) in [("tasks.plan",BackendMCPTier.alter),("tasks.retry",.alter),("tasks.reassign",.alter),("tasks.review",.act),("tasks.progress",.read)] { #expect(try r.spec(id).tier == tier) }
            for (verb,tier) in [("list",BackendMCPTier.read),("create",.act),("remove",.alter)] { let count = await r.audit.tiers.count; do { _ = try await r.call("tasks.goals",crmParityValue(["do":verb])) } catch {}; let tiers = await r.audit.tiers; #expect(tiers.count > count && tiers.last == tier) }
        
        }
    }
    @Test func g02EveryGoalToolRefusesAIAppKeys() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let r = try await BackendCrmTaskToolsParityFixture.make()
            for id in goalIDs { #expect(await r.refused(id,crmParityValue(["do":"list","goal":"x","task":"x","tasks":[],"verdict":"pass","evidence":["x"]]),caller:"key-on").contains("Hoot’s own tool")) }
        
        }
    }
    @Test func g03GoalCRUDLinksAndRemovalMoveTasksUp() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let r = try await BackendCrmTaskToolsParityFixture.make()
            let root = try #require(try await r.call("tasks.goals",crmParityValue(["do":"create","title":"Fortnightly releases"]))["created"]["id"].string)
            let release = try #require(try await r.call("tasks.goals",crmParityValue(["do":"create","title":"Ship 0.18","parent":root,"project":"/work/app"]))["created"]["id"].string)
            let id = try await r.f.make("Write the notes",crmParityValue(["project":"/work/app"]))
            _ = try await r.call("tasks.goals",crmParityValue(["do":"link","task":id,"goal":release])); #expect(try await r.f.row(id)["goalId"].string == release)
            #expect(crmParityMatches(try await r.f.row(id)["notes"].elements?.last ?? .missing,crmParityValue(["by":"hoot","text":"Part of the goal “Ship 0.18”."])))
            let got = try await r.call("tasks.goals",crmParityValue(["do":"get","goal":release]))
            #expect(crmParityEqual(got["above"],crmParityValue([["goal":root,"title":"Fortnightly releases","status":"active"]])))
            #expect(got["goal"]["progress"]["total"].number == 1)
            _ = try await r.call("tasks.goals",crmParityValue(["do":"update","goal":release,"status":"achieved"])); #expect(try await r.f.goals.byID(release)?["status"].string == "achieved")
            _ = try await r.call("tasks.goals",crmParityValue(["do":"remove","goal":release])); #expect(try await r.f.goals.byID(release) == nil); #expect(try await r.f.row(id)["goalId"].string == root)
            #expect(await r.refused("tasks.goals",crmParityValue(["do":"create","title":"x","project":"/somewhere/else"])).contains("not inside a folder Terminal Deck has open"))
            #expect(await r.refused("tasks.goals",crmParityValue(["do":"link","task":id,"goal":"goal-gone"])).contains("there is no goal goal-gone"))
        
        }
    }
    @Test func g04PlanInstallsWaitsBeforeAssignmentsAndUsesHootIdentity() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let r = try await BackendCrmTaskToolsParityFixture.make(), goal = try await r.f.goals.save(crmParityValue(["title":"Ship 0.18","project":"/work/app"]))
            let plan = try await r.call("tasks.plan",crmParityValue(["goal":goal["id"].string!,"tasks":[["key":"api","title":"Build the API","details":"REST, two routes.","agent":"Builder"],["key":"page","title":"Build the page","agent":"builder","after":["api"],"workspace":true],["key":"test","title":"Test it end to end","agent":"Tester","after":["api","page"]],["key":"notes","title":"Write the notes"]]]))
            let made = try #require(plan["tasks"].elements)
            #expect(made.map { $0["key"].string ?? "" } == ["api","page","test","notes"])
            #expect(made.map { $0["agent"] } == [.string("Builder"),.string("Builder"),.string("Tester"),.null])
            #expect(made.map { $0["waitsFor"] } == [crmParityValue([]),crmParityValue(["api"]),crmParityValue(["api","page"]),crmParityValue([])])
            var records: [BackendTaskRecord] = []; for step in made { records.append(try #require(try await r.f.store.byID(step["task"].string!))) }
            for row in records { #expect(crmParityMatches(row.value,crmParityValue(["goalId":goal["id"].string!,"requestedBy":"hoot","project":"/work/app"]))) }
            #expect(records[0].value["instructions"].string == "REST, two routes." && records[1].value["useWorkspace"].bool == true && records[3].assigneeKind == "none")
            #expect(await r.f.recorder.started == Array(records.prefix(3)).map(\.id))
            #expect(BackendGoalStore.blockers(records[2],all:records).compactMap { $0.value["title"].string } == ["Build the API","Build the page"])
            #expect(records[0].value["notes"].elements?.allSatisfy { $0["by"].string == "hoot" } == true)
        
        }
    }
    @Test func g05InvalidPlansMakeNothing() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let r = try await BackendCrmTaskToolsParityFixture.make(), goal = try await r.f.goals.save(crmParityValue(["title":"Ship 0.18"]))
            let base = crmParityValue(["goal":goal["id"].string!,"project":"/work/app"])
            let invalid: [([[String:Any]],String)] = [([["title":"x","agent":"Nobody"]],"no task agent called Nobody"),([["key":"a","title":"x","after":["b"]]],"waits for b, which is not in this plan"),([["key":"a","title":"x","after":["b"]],["key":"b","title":"y","after":["a"]]],"loop back")]
            for (steps,text) in invalid {
                #expect(await r.refused("tasks.plan",base.setting("tasks",crmParityValue(steps))).contains(text))
            }
            #expect(await r.refused("tasks.plan",crmParityValue(["goal":goal["id"].string!,"tasks":[["title":"x","agent":"Builder"]]])).contains("project is required"))
            #expect(await r.refused("tasks.plan",base.setting("project",.string("/elsewhere")).setting("tasks",crmParityValue([["title":"x"]]))).contains("not inside a folder"))
            #expect(try await r.f.store.all().isEmpty)
        
        }
    }
    @Test func g06ProgressIncludesPeopleAndAllGoalTotals() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let r = try await BackendCrmTaskToolsParityFixture.make(), goal = try await r.f.goals.save(crmParityValue(["title":"Ship 0.18","project":"/work/app"]))
            _ = try await r.call("tasks.plan",crmParityValue(["goal":goal["id"].string!,"tasks":[["key":"a","title":"Build","agent":"Builder"],["key":"b","title":"Check","after":["a"]]]]))
            let report = try await r.call("tasks.progress",.object([.init("goal",goal["id"])]))
            #expect(crmParityMatches(report,crmParityValue(["total":2,"done":0,"blocked":1])))
            #expect(report["tasks"].elements?.map { ($0["title"].string ?? "") + ":" + ($0["assigneeName"].string ?? "") } == ["Build:Builder","Check:Nobody"])
            #expect(try await r.call("tasks.progress",.object([]))["goals"].elements?.first?["progress"]["total"].number == 2)
        
        }
    }
    @Test func g07KnowledgeComesWithProgressAndPlanWithProvenance() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let make = try #require(BackendCrmTaskToolsParityKnowledgeBinding.make), driver = try await make(), r = driver.tools
            try await driver.record(project:"/work/app",kind:"constraint",subject:"release.mobile-versions",statement:"A release that bumps the version needs the owner to approve the phone version lines.",source:"owner")
            let goal = try await r.f.goals.save(crmParityValue(["title":"Ship the release","description":"release build and version","project":"/work/app"]))
            let report = try await r.call("tasks.progress",.object([.init("goal",goal["id"])]))
            #expect(report["knowledge"]["text"].string?.contains("phone version lines") == true && report["knowledge"]["text"].string?.contains("owner") == true && report["knowledge"]["counts"]["claim"].number == 1)
            #expect(try await r.call("tasks.plan",crmParityValue(["goal":goal["id"].string!,"tasks":[["key":"a","title":"Bump the version"]]]))["knowledge"]["text"].string?.contains("phone version lines") == true)
        
        }
    }
    @Test func g08UnknownOrAbsentKnowledgeAddsNoField() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let make = try #require(BackendCrmTaskToolsParityKnowledgeBinding.make), driver = try await make(), r = driver.tools
            let goal = try await r.f.goals.save(crmParityValue(["title":"Ship the release","project":"/work/app"]))
            #expect(try await r.call("tasks.progress",.object([.init("goal",goal["id"])] )).has("knowledge") == false)
            let plain = try await BackendCrmTaskToolsParityFixture.make(), g = try await plain.f.goals.save(crmParityValue(["title":"Ship the release","project":"/work/app"]))
            #expect(try await plain.call("tasks.progress",.object([.init("goal",g["id"])] )).has("knowledge") == false)
        
        }
    }
    @Test func g09KnowledgeNeverCrossesProjectBoundaries() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let make = try #require(BackendCrmTaskToolsParityKnowledgeBinding.make), driver = try await make(), r = driver.tools
            try await driver.record(project:"/work/other",kind:"decision",subject:"release.channel",statement:"Releases go out on the beta channel first.",source:"owner")
            let goal = try await r.f.goals.save(crmParityValue(["title":"Ship the release","description":"release channel","project":"/work/app"]))
            #expect(try await r.call("tasks.progress",.object([.init("goal",goal["id"])] )).has("knowledge") == false)
        
        }
    }
    @Test func g10RetryPassesTaskAndNoteAndRefusesCRMTask() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let make = try #require(BackendCrmTaskToolsParityControlBinding.make,"Need native retry/review request-capture dependency"), control = try await make(), r = control.tools
            let id = try await r.f.make("Fix it",crmParityValue(["project":"/work/app","assignee":"builder"]))
            _ = try await r.call("tasks.retry",crmParityValue(["task":id,"note":"Run the migration first."]))
            #expect(await control.retried() == [crmParityValue(["task":id,"note":"Run the migration first."])])
            _ = try await r.f.store.put(try await r.f.row(id).setting("id",.string("key-1:crm-1")).setting("keyId",.string("key-1")).setting("externalTaskId",.string("crm-1")).setting("local",.bool(false)))
            #expect(await r.refused("tasks.retry",crmParityValue(["task":"key-1:crm-1","note":"x"])).contains("CRM task"))
        
        }
    }
    @Test func g11ReassignRefusesSameAgentThenPreservesHootNote() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let r = try await BackendCrmTaskToolsParityFixture.make(), id = try await r.f.make("Fix it",crmParityValue(["project":"/work/app","assignee":"builder"]))
            #expect(await r.refused("tasks.reassign",crmParityValue(["task":id,"agent":"Builder"])).contains("already has it"))
            #expect(await r.refused("tasks.reassign",crmParityValue(["task":id,"agent":"Builder"])).contains("tasks_retry"))
            let before = await r.f.recorder.started.count
            _ = try await r.call("tasks.reassign",crmParityValue(["task":id,"agent":"Tester","note":"Builder is stuck on the database."]))
            #expect(await r.f.recorder.started.dropFirst(before) == [id]); #expect(try await r.f.row(id)["assignee"]["agentId"].string == "tester")
            #expect(try await r.f.row(id)["notes"].elements?.contains { $0["by"].string == "hoot" && $0["text"].string == "Given to Tester: Builder is stuck on the database." } == true)
        
        }
    }
    @Test func g12ReviewValidatesEvidenceAndReasonsBeforeEngine() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let make = try #require(BackendCrmTaskToolsParityControlBinding.make,"Need native retry/review request-capture dependency"), control = try await make(), r = control.tools
            let id = try await r.f.make("Fix it",crmParityValue(["project":"/work/app"]))
            #expect(await r.refused("tasks.review",crmParityValue(["task":id,"verdict":"pass"])).contains("must name its evidence"))
            #expect(await r.refused("tasks.review",crmParityValue(["task":id,"verdict":"fail","evidence":["a.ts"]])).contains("must give reasons"))
            _ = try await r.call("tasks.review",crmParityValue(["task":id,"verdict":"pass","evidence":["src/login.ts"," ","npm test: 120 passed"]]))
            #expect(await control.reviewed() == [crmParityValue(["task":id,"pass":true,"evidence":["src/login.ts","npm test: 120 passed"],"reasons":""])])
        
        }
    }
}
