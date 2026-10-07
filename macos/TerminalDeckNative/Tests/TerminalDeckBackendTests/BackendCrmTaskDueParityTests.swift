import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("task-due-local.test.ts case parity")
struct BackendCrmTaskDueParityTests {
    func rig(_ notify: Bool = true) async throws -> any BackendCrmTaskDueParityDriver {
        let make = try #require(BackendCrmTaskDueParityBinding.make, "Bind the production due lifecycle to fake now/timers and settled().")
        let driver = try await make(notify); await driver.setNow(at("2026-10-07", "09:00")); return driver
    }
    func at(_ day: String, _ time: String) -> Double { BackendCrmRoutineRules.localInstant(day, time)!.timeIntervalSince1970 * 1000 }
    func repeatTask(_ f: BackendCrmTaskDetailParityFixture, _ title: String, patch: NativeRPCValue = .object([])) async throws -> String {
        let id = try await f.make(title, crmParityValue(["startDate": "2026-10-08", "dueDate": "2026-10-09"]))
        var rule = RoutineRule(); rule.unit = "week"
        let saved = await f.call("saveRoutine", .string(id), BackendCrmWire.native(Routine.serialize(rule)).merging(patch), .number(0))
        #expect(saved["ok"].bool == true); return id
    }
    func status(_ d: any BackendCrmTaskDueParityDriver, _ id: String, _ status: String) async throws {
        _ = try await d.fixture.local.update(id, input: crmParityValue(["status": status])); try await d.settled()
    }
    func routine(_ f: BackendCrmTaskDetailParityFixture, _ id: String) async -> NativeRPCValue { await f.call("fetchRoutine", .string(id))["routine"] }
    @Test func u01FinishCopiesDatesPartsAndHistoryExactlyOnce() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let d = try await rig(), f = d.fixture, id = try await repeatTask(f, "Weekly report")
            let sub = await f.call("addTaskSubtask", .string(id), .string("Gather numbers")); _ = await f.call("setTaskSubtaskDone", .string(id), sub["id"], .bool(true))
            let list = await f.call("addChecklist", .string(id), .string("Send")), item = await f.call("addChecklistItem", list["id"], .string("Email it")); _ = await f.call("setChecklistItemDone", item["id"], .bool(true))
            try await status(d, id, "Done")
            let first = try #require(try await f.copyIDs(id).first); #expect(try await f.copyIDs(id).count == 1)
            #expect(crmParityMatches(try await f.row(first), crmParityValue(["title": "Weekly report", "crmStatus": "To-Do", "dueDate": "2026-10-16", "startDate": "2026-10-15", "recurrence": "weekly", "assignee": ["identity": "me"]])))
            let b = await f.bundle(first)
            #expect(crmParityMatches(b["subtasks"].elements?.first ?? .missing, crmParityValue(["title": "Gather numbers", "done": false])))
            #expect(crmParityMatches(b["checklists"].elements?.first?["items"].elements?.first ?? .missing, crmParityValue(["title": "Email it", "done": false])))
            let firstView = await routine(f, first)
            #expect(firstView["isRoot"].bool == false && firstView["rootTaskId"].string == id)
            #expect(crmParityMatches(await routine(f, id)["history"].elements?.first ?? .missing, crmParityValue(["occurrenceDate": "2026-10-16", "spawnedTaskId": first, "status": "open"])))
            try await status(d, id, "To-Do"); _ = try await f.local.update(id, input: crmParityValue(["dueDate": "2026-10-17"])); try await status(d, id, "Done")
            #expect(try await f.copyIDs(id).count == 1)
            try await status(d, first, "Done")
            var dates: [String] = []; for copy in try await f.copyIDs(id) { dates.append(try await f.row(copy)["dueDate"].string ?? "") }
            #expect(dates.sorted() == ["2026-10-16", "2026-10-23"])
            let history = await routine(f, id)["history"].elements ?? []
            #expect(history.map { [$0["occurrenceDate"].string ?? "", $0["status"].string ?? ""] } == [["2026-10-23", "open"], ["2026-10-16", "done"]])
            #expect(await routine(f, id)["datesSoFar"].number == 2)
        
        }
    }
    @Test func u02ReuseTaskOnlyOnItsTriggerStatus() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let d = try await rig(), f = d.fixture, id = try await repeatTask(f, "Water the plants", patch: crmParityValue(["createNew": false, "triggerStatus": "In Progress"]))
            try await status(d, id, "Stuck"); #expect(try await f.row(id)["dueDate"].string == "2026-10-09")
            try await status(d, id, "In Progress"); #expect(try await f.store.all().count == 1)
            #expect(crmParityMatches(try await f.row(id), crmParityValue(["crmStatus": "To-Do", "dueDate": "2026-10-16", "startDate": "2026-10-15", "completedAt": NSNull()])))
            try await status(d, id, "Done")
            #expect(await routine(f, id)["history"].elements?.map { [$0["occurrenceDate"].string ?? "", $0["status"].string ?? ""] } == [["2026-10-16", "done"]])
            #expect(try await f.row(id)["dueDate"].string == "2026-10-16")
        
        }
    }
    @Test func u03ResetIntoTriggerStatusDoesNotRecurForever() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let d = try await rig(), f = d.fixture, id = try await repeatTask(f, "Escalate", patch: crmParityValue(["createNew": false, "triggerStatus": "Stuck", "updateStatusTo": "Stuck"]))
            try await status(d, id, "Stuck")
            #expect(crmParityMatches(try await f.row(id), crmParityValue(["crmStatus": "Stuck", "dueDate": "2026-10-16"])))
            #expect(await routine(f, id)["history"].elements?.count == 1)
        
        }
    }
    @Test func u04CountPauseStopArchiveAndRestart() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let d = try await rig(), f = d.fixture, counted = try await repeatTask(f, "Three times", patch: crmParityValue(["ends": ["type": "count", "count": 2]]))
            try await status(d, counted, "Done"); let first = try #require(try await f.copyIDs(counted).first); try await status(d, first, "Done")
            var second: String?; for id in try await f.copyIDs(counted) { if try await f.row(id)["dueDate"].string == "2026-10-23" { second = id } }
            try await status(d, try #require(second), "Done"); #expect(try await f.copyIDs(counted).count == 2)
            let paused = try await repeatTask(f, "Paused one"); _ = await f.call("pauseRoutine", .string(paused), .bool(true)); try await status(d, paused, "Done")
            #expect(try await f.copyIDs(paused).isEmpty)
            _ = await f.call("pauseRoutine", .string(paused), .bool(false)); let view = await routine(f, paused)
            #expect(view["canRestart"].bool == true && view["stuck"].string?.contains("Nothing more will come") == true)
            let restarted = try await f.ok("restartRoutine", .string(paused)), restartID = try #require(restarted["taskId"].string)
            #expect(crmParityMatches(try await f.row(restartID), crmParityValue(["dueDate": "2026-10-16", "crmStatus": "To-Do"])))
            #expect(crmParityEqual(await f.call("restartRoutine", .string(paused)), crmParityFailure("This routine is not stuck: one of its tasks is still open.")))
            try await status(d, paused, "To-Do"); try await status(d, paused, "Done"); #expect(try await f.copyIDs(paused).count == 1)
            let stopped = try await repeatTask(f, "Stopped one"); _ = await f.call("stopRoutine", .string(stopped)); try await status(d, stopped, "Done"); #expect(try await f.copyIDs(stopped).isEmpty)
            let archived = try await repeatTask(f, "Archived one"); try await status(d, archived, "Done"); _ = await f.call("setArchived", .string(archived), .bool(true))
            try await status(d, try #require(try await f.copyIDs(archived).first), "Done"); #expect(try await f.copyIDs(archived).count == 1)
        
        }
    }
    @Test func u05PerPersonPartialFailureRetriesOnlyMissingCopy() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let d = try await rig(), f = d.fixture, id = try await repeatTask(f, "Stand-up notes", patch: crmParityValue(["perAssignee": true]))
            _ = await f.call("addTaskAssignee", .string(id), .string("builder")); try await status(d, id, "Done")
            var people: [String] = []; for copy in try await f.copyIDs(id) { people.append(try await f.row(copy)["assignee"]["identity"].string ?? "") }
            #expect(people == ["me"])
            #expect(await routine(f, id)["lastError"]["message"].string?.hasPrefix("Not every copy was made (1 of 2): Builder: Choose the project folder") == true)
            _ = try await f.local.update(id, input: crmParityValue(["project": "/work/app"])); try await status(d, id, "To-Do"); try await status(d, id, "Done")
            people = []; for copy in try await f.copyIDs(id) { people.append(try await f.row(copy)["assignee"]["identity"].string ?? ""); #expect(try await f.row(copy)["dueDate"].string == "2026-10-16") }
            let retriedView = await routine(f, id)
            #expect(people.sorted() == ["builder", "me"] && retriedView["lastError"] == .null)
        
        }
    }
    @Test func u06EngineStatusAlsoBringsTheNextOccurrence() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let d = try await rig(), f = d.fixture, id = try await repeatTask(f, "Nightly check")
            _ = try await f.store.update(id, patch: crmParityValue(["crmStatus": "Done", "completedAt": at("2026-10-07", "09:00")]))
            try await d.noteStatus(id); try await d.settled(); #expect(try await f.copyIDs(id).count == 1)
        
        }
    }
    @Test func u07ScheduledCatchupCreatesLatestAndMarksGapsMissed() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let d = try await rig(), f = d.fixture, id = try await repeatTask(f, "Weekly invoice", patch: crmParityValue(["trigger": "schedule", "timeOfDay": "08:00", "missedPolicy": "mark_missed"]))
            #expect(try await f.detail.nextDueAt() == at("2026-10-16", "08:00"))
            await d.setNow(at("2026-10-16", "07:59")); try await d.runDue(); #expect(try await f.copyIDs(id).isEmpty)
            await d.setNow(at("2026-10-16", "08:00")); try await d.runDue(); let first = try #require(try await f.copyIDs(id).first)
            #expect(crmParityMatches(try await f.row(first), crmParityValue(["dueDate": "2026-10-16", "crmStatus": "To-Do"])))
            try await status(d, first, "Done"); #expect(try await f.copyIDs(id).count == 1); try await status(d, first, "To-Do")
            await d.setNow(at("2026-11-06", "09:30")); try await d.runDue()
            var dates: [String] = []; for copy in try await f.copyIDs(id) { dates.append(try await f.row(copy)["dueDate"].string ?? "") }; #expect(dates.sorted() == ["2026-10-16", "2026-11-06"])
            #expect(await routine(f, id)["history"].elements?.map { [$0["occurrenceDate"].string ?? "", $0["status"].string ?? ""] } == [["2026-11-06", "open"], ["2026-10-30", "skipped"], ["2026-10-23", "skipped"], ["2026-10-16", "missed"]])
            #expect(try await f.row(first)["labels"].elements?.contains(.string("Missed")) == true)
            #expect(await routine(f, id)["datesSoFar"].number == 2)
            #expect(try await f.detail.nextDueAt() == at("2026-11-13", "08:00")); try await d.runDue(); #expect(try await f.copyIDs(id).count == 2)
        
        }
    }
    @Test func u08ScheduleCanReuseItsOwnTask() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let d = try await rig(), f = d.fixture, id = try await repeatTask(f, "Check the backups", patch: crmParityValue(["trigger": "schedule", "createNew": false, "timeOfDay": "06:30"]))
            await d.setNow(at("2026-10-16", "06:30")); try await d.runDue()
            #expect(try await f.store.all().count == 1)
            #expect(crmParityMatches(try await f.row(id), crmParityValue(["dueDate": "2026-10-16", "startDate": "2026-10-15", "crmStatus": "To-Do"])))
            #expect(try await f.detail.nextDueAt() == at("2026-10-23", "06:30"))
        
        }
    }
    @Test func u09ReminderDeliversExactlyOnceAtItsMoment() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let d = try await rig(), f = d.fixture, id = try await f.make("Call the bank\nabout the card"), when = at("2026-10-07", "10:00")
            #expect(await f.call("fetchTaskMore", .string(id))["more"]["remindersLive"].bool == true)
            _ = await f.call("setReminder", .string(id), .string(CrmTime.iso(when)), .string("Before noon")); #expect(try await f.detail.nextDueAt() == when)
            await d.setNow(when - 1); try await d.runDue(); #expect(await f.recorder.notices.isEmpty)
            await d.setNow(when); try await d.runDue(); try await d.runDue()
            #expect(await f.recorder.notices == [crmParityValue(["taskId": id, "title": "Call the bank", "body": "Before noon"])])
            #expect(await f.call("fetchTaskMore", .string(id))["more"]["reminders"].elements == []); #expect(try await f.detail.nextDueAt() == nil)
        
        }
    }
    @Test func u10ReminderRetriesFiveTimesThenSettlesRefusedAndArchived() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let d = try await rig(), f = d.fixture, id = try await f.make("Pay rent"), when = at("2026-10-07", "09:01")
            await f.recorder.setDelivery(BackendTaskReminderDelivery(delivered: false, reason: "the notification did not show", retry: true))
            _ = await f.call("setReminder", .string(id), .string(CrmTime.iso(when)), .null); await d.setNow(when); try await d.runDue()
            let initialNotices = await f.recorder.notices, waiting = await f.call("fetchTaskMore", .string(id))
            #expect(initialNotices.count == 1 && waiting["more"]["reminders"].elements?.count == 1)
            #expect(try await f.detail.nextDueAt() == when + 60_000)
            try await d.runDue(); #expect(await f.recorder.notices.count == 1)
            for _ in 0..<10 { if let next = try await f.detail.nextDueAt() { await d.setNow(next) }; try await d.runDue() }
            let finalNotices = await f.recorder.notices
            #expect(finalNotices.count == 5 && finalNotices.first?["body"].string == "You asked to be reminded about this task.")
            #expect(await f.call("fetchTaskMore", .string(id))["more"]["reminders"].elements == [])
            await f.recorder.setDelivery(BackendTaskReminderDelivery(delivered: false, reason: "notifications are switched off for the app", retry: false))
            let base = when + 20 * 60_000, before = await f.recorder.notices.count
            _ = await f.call("setReminder", .string(id), .string(CrmTime.iso(base + 1000)), .string("x")); await d.setNow(base + 1000); try await d.runDue(); try await d.runDue()
            #expect(await f.recorder.notices.count == before + 1)
            await f.recorder.setDelivery(BackendTaskReminderDelivery(delivered: true))
            _ = await f.call("setReminder", .string(id), .string(CrmTime.iso(base + 2000)), .string("y")); _ = await f.call("setArchived", .string(id), .bool(true)); await d.setNow(base + 2000); try await d.runDue()
            #expect(await f.recorder.notices.count == before + 1); #expect(try await f.detail.nextDueAt() == nil)
        
        }
    }
    @Test func u11ClearedReminderNeverGoes() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let d = try await rig(), f = d.fixture, id = try await f.make("Renew passport"), when = at("2026-10-07", "09:00") + 1000
            let set = await f.call("setReminder", .string(id), .string(CrmTime.iso(when)), .null)
            _ = try await f.ok("clearReminder", .string(id), set["id"])
            await d.setNow(when + 1000); try await d.runDue(); #expect(await f.recorder.notices.isEmpty)
        
        }
    }
    @Test func u12ScheduledCommentPublishesOneActivityAndAgentReply() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let d = try await rig(), f = d.fixture, id = try await f.make("Fix the build", crmParityValue(["assignee": "builder", "project": "/work/app"])), when = at("2026-10-07", "09:30")
            let posted = await f.call("addTaskCommentWith", .string(id), .string("@Builder check the logs first"), crmParityValue(["scheduledFor": CrmTime.iso(when)])), cid = try #require(posted["id"].string)
            #expect(crmParityMatches(await f.call("fetchCommentExtras", .string(id))["extras"]["meta"][cid], crmParityValue(["scheduledFor": CrmTime.iso(when), "deliveredAt": NSNull()])))
            #expect(await f.rows(id).contains { $0["kind"].string == "comment" } == false)
            #expect(await f.recorder.replies.isEmpty); #expect(try await f.detail.nextDueAt() == when)
            await d.setNow(when); try await d.runDue()
            #expect(await f.call("fetchCommentExtras", .string(id))["extras"]["meta"][cid]["deliveredAt"].string != nil)
            #expect(await f.rows(id).filter { $0["kind"].string == "comment" }.count == 1)
            #expect(await f.recorder.replies == [crmParityValue(["id": id, "text": "@Builder check the logs first"])])
            try await d.runDue(); #expect(await f.recorder.replies.count == 1); #expect(try await f.detail.nextDueAt() == nil)
        
        }
    }
    @Test func u13AbsentNotificationAdapterDoesNotKeepDeadReminders() async throws {
        let parityClock = BackendCrmTaskClockParityVirtualClock()
        parityClock.set(BackendCrmTime.parseInstant("2026-10-07T09:00:00Z")!.timeIntervalSince1970 * 1000)
        parityClock.setReadStep(0)
        try await BackendTaskClockContext.withClock(parityClock) {
            let f = try await BackendCrmTaskDetailParityFixture.make(), id = try await f.make("No reminders here")
            #expect(await f.call("fetchTaskMore", .string(id))["more"]["remindersLive"].bool == false)
            #expect(crmParityEqual(await f.call("setReminder", .string(id), .string("2099-01-01T00:00:00Z"), .null), crmParityFailure("Nothing on this computer delivers reminders.")))
            #expect(try await f.detail.nextDueAt() == nil)
        
        }
    }
}
