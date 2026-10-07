import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Bindings over the real goal owner and the real detail owner; nothing here replaces a system under test.
enum BackendRoutinesTaskStoreParityBindings {
    static let subtree: (@Sendable (BackendGoalStore, String) async throws -> [NativeRPCValue])? = { goals, id in try await goals.subtree(id) }
    static let removeAnswer: (@Sendable (BackendGoalStore, String, BackendTaskStore) async throws -> NativeRPCValue)? = { goals, id, tasks in try await goals.remove(id, tasks: tasks) }
    static let observe: (@Sendable (BackendGoalStore, @escaping @Sendable () async -> Void) async throws -> NativeRPCSubscription)? = { goals, listener in await goals.observe(listener) }
    /// Moves the fake clock to the instant, then runs one due pass of the production detail owner and waits for it.
    static let runDue: (@Sendable (BackendTaskDetailService, Double) async throws -> Void)? = { detail, instant in
        if let clock = BackendTaskClockContext.clock as? BackendRoutinesTaskEngineParityClock, instant > clock.now() { clock.move(by: instant - clock.now()) }
        await detail.runDueNow()
    }
}

@Suite("Exact goal-store.test.ts parity")
struct BackendRoutinesTaskStoreParityGoals {
    @Test func makesChangesAndChainsGoals() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(memory: true); defer { try? FileManager.default.removeItem(at: r.root) }
        let root = try await r.goals.save(routinesTaskObject([("title", .string("A Mac release every fortnight")), ("description", .string("Steady cadence."))]))
        let release = try await r.goals.save(routinesTaskObject([("title", .string("Ship 0.18")), ("parentId", root["id"]), ("project", .string("/work/app")), ("status", .string("planned"))]))
        let notes = try await r.goals.save(routinesTaskObject([("title", .string("Release notes")), ("parentId", release["id"])]))
        routinesTaskMatches(root, routinesTaskObject([("status", .string("active")), ("parentId", .null), ("project", .null), ("description", .string("Steady cadence."))]))
        routinesTaskMatches(release, routinesTaskObject([("status", .string("planned")), ("parentId", root["id"]), ("project", .string("/work/app"))]))
        #expect(try await r.goals.chain(notes["id"].string!).map { $0["title"].string! } == ["Release notes", "Ship 0.18", "A Mac release every fortnight"])
        let subtree = try #require(BackendRoutinesTaskStoreParityBindings.subtree)
        #expect(try await subtree(r.goals, root["id"].string!).map { $0["id"] } == [root["id"], release["id"], notes["id"]])
        _ = try await r.goals.save(routinesTaskObject([("id", release["id"]), ("status", .string("achieved")), ("title", .string("Ship 0.18.0"))]))
        routinesTaskMatches(try await r.goals.byID(release["id"].string!)!, routinesTaskObject([("status", .string("achieved")), ("title", .string("Ship 0.18.0")), ("project", .string("/work/app"))]))
        }
    }
    @Test func refusesInvalidGoalsAndLoops() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(memory: true); defer { try? FileManager.default.removeItem(at: r.root) }
        for (input, fragment) in [(routinesTaskObject([("title", .string("  "))]), "title cannot be empty"),
            (routinesTaskObject([("title", .string("x")), ("status", .string("done"))]), "planned, active, achieved, cancelled"),
            (routinesTaskObject([("title", .string("x")), ("project", .string("relative"))]), "not a full folder path"),
            (routinesTaskObject([("title", .string("x")), ("parentId", .string("goal-nope"))]), "parent goal no longer exists")] {
            #expect(await routinesTaskError { _ = try await r.goals.save(input) }.contains(fragment))
        }
        let a = try await r.goals.save(routinesTaskObject([("title", .string("A"))])), b = try await r.goals.save(routinesTaskObject([("title", .string("B")), ("parentId", a["id"])]))
        for parent in [a["id"], b["id"]] { #expect(await routinesTaskError { _ = try await r.goals.save(routinesTaskObject([("id", a["id"]), ("parentId", parent)])) }.contains("cannot sit under itself")) }
        }
    }
    @Test func keepsTreeAtMostEightDeep() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(memory: true); defer { try? FileManager.default.removeItem(at: r.root) }
        var parent = try await r.goals.save(routinesTaskObject([("title", .string("level 1"))]))
        for level in 2...8 { parent = try await r.goals.save(routinesTaskObject([("title", .string("level \(level)")), ("parentId", parent["id"])])) }
        let final = parent
        #expect(await routinesTaskError { _ = try await r.goals.save(routinesTaskObject([("title", .string("one too deep")), ("parentId", final["id"])])) }.contains("at most 8 deep"))
        }
    }
    @Test func removedGoalReturnsParentAndRelinksChildren() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(memory: true); defer { try? FileManager.default.removeItem(at: r.root) }
        let root = try await r.goals.save(routinesTaskObject([("title", .string("Root"))])), middle = try await r.goals.save(routinesTaskObject([("title", .string("Middle")), ("parentId", root["id"])])), leaf = try await r.goals.save(routinesTaskObject([("title", .string("Leaf")), ("parentId", middle["id"])]))
        let remove = try #require(BackendRoutinesTaskStoreParityBindings.removeAnswer)
        #expect(try await remove(r.goals, middle["id"].string!, r.store)["parentId"] == root["id"])
        #expect(try await r.goals.byID(leaf["id"].string!)?["parentId"] == root["id"])
        #expect(try await r.goals.byID(middle["id"].string!) == nil)
        #expect(await routinesTaskError { _ = try await remove(r.goals, middle["id"].string!, r.store) }.contains("no longer exists"))
        }
    }
    @Test func listenersCanUnsubscribeAfterOneChange() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(memory: true), heard = BackendRoutinesTaskStoreParitySignal(); defer { try? FileManager.default.removeItem(at: r.root) }
        let observe = try #require(BackendRoutinesTaskStoreParityBindings.observe)
        let stop = try await observe(r.goals, { await heard.hit() })
        _ = try await r.goals.save(routinesTaskObject([("title", .string("A"))])); await stop.cancelAndWait()
        _ = try await r.goals.save(routinesTaskObject([("title", .string("B"))])); #expect(await heard.count == 1)
        }
    }
    @Test func diskRestartIsPrivateAndBrokenParentBecomesNone() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(); defer { try? FileManager.default.removeItem(at: r.root) }
        let root = try await r.goals.save(routinesTaskObject([("title", .string("Root"))]))
        (BackendTaskClockContext.clock as? BackendRoutinesTaskEngineParityClock)?.move(by: 1)
        _ = try await r.goals.save(routinesTaskObject([("title", .string("Child")), ("parentId", root["id"]), ("description", .string("Under root."))]))
        let file = r.root.appendingPathComponent("goals.json")
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let again = BackendGoalStore(persistence: r.persistence); try await again.start()
        #expect(try await again.all().map { $0["title"].string! } == ["Root", "Child"])
        let raw = try NativeRPCValue.parseJSON(Data(contentsOf: file)); let rows = (raw["goals"].elements ?? []).filter { $0["title"].string != "Root" } + [routinesTaskObject([("id", .string("junk"))])]
        try r.persistence.write("goals.json", value: raw.setting("goals", .array(rows)))
        let broken = BackendGoalStore(persistence: r.persistence); try await broken.start()
        let all = try await broken.all(); #expect(all.count == 1)
        routinesTaskMatches(try #require(all.first), routinesTaskObject([("title", .string("Child")), ("parentId", .null)]))
        }
    }
}

@Suite("Exact task-trash.test.ts parity")
struct BackendRoutinesTaskStoreParityTrash {
    @Test func trashKeepsWholeTaskAndFilesAcrossRestart() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(); defer { try? FileManager.default.removeItem(at: r.root) }
        let task = try await r.task("Disposable draft", fields: [("labels", routinesTaskText(["temp"]))])
        _ = await r.detail.call("addTaskComment", arguments: [.string(task.id), .string("A note to keep")])
        let upload = await r.detail.call("uploadTaskFile", arguments: [.string(task.id), routinesTaskObject([("name", .string("n.txt")), ("type", .string("text/plain")), ("bytes", .bytes(Data([1, 2, 3])))])])
        #expect(upload["ok"].bool == true)
        let storage = try #require(upload["attachment"]["storagePath"].string)
        let file = r.root.appendingPathComponent("task-files").appendingPathComponent(storage)
        let before = await r.detail.call("listTaskActivity", arguments: [.string(task.id)])["rows"].elements?.count ?? 0
        try await r.local.remove(task.id)
        #expect(try await r.store.byID(task.id) == nil); #expect(try await !r.store.all().contains { $0.id == task.id })
        #expect(try await r.store.inTrash().map(\.id) == [task.id]); #expect(try await r.store.byID(task.id, includeTrash: true)?.value["deletedAt"].number != nil)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(await r.detail.call("fetchTaskDetailBundle", arguments: [.string(task.id)]) == routinesTaskObject([("ok", .bool(false)), ("error", .string("That task no longer exists."))]))
        let again = try await BackendRoutinesTaskStoreParityRig.make(root: r.root)
        #expect(try await again.store.byID(task.id) == nil); #expect(try await again.store.inTrash().map { $0.value["title"].string! } == ["Disposable draft"])
        let back = try await again.local.restore(task.id)
        routinesTaskMatches(back.value, routinesTaskObject([("title", .string("Disposable draft")), ("labels", routinesTaskText(["temp"])), ("deletedAt", .null)]))
        #expect(try await again.store.byID(task.id) != nil); #expect(try await again.store.inTrash().isEmpty)
        #expect(await again.detail.call("listTaskComments", arguments: [.string(task.id)])["comments"].elements?.map { $0["body"].string! } == ["A note to keep"])
        #expect(await again.detail.call("listTaskActivity", arguments: [.string(task.id)])["rows"].elements?.count ?? 0 >= before)
        #expect(back.value["notes"].elements?.suffix(2).map { $0["text"].string! } == ["Moved to Trash.", "Restored from Trash."])
        #expect(await again.detail.call("fetchTaskDetailBundle", arguments: [.string(task.id)])["bundle"]["attachments"].elements?.map { $0["fileName"].string! } == ["n.txt"])
        let third = try await BackendRoutinesTaskStoreParityRig.make(root: r.root); #expect(try await third.store.byID(task.id)?.value["title"].string == "Disposable draft")
        #expect(await routinesTaskError { _ = try await third.local.restore(task.id) } == "That task is not in the Trash.")
        }
    }
    @Test func deleteStopsAgentAndRestoreStartsNone() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(memory: true); defer { try? FileManager.default.removeItem(at: r.root) }
        let task = try await r.task("Agent job", fields: [("assignee", .string("builder")), ("project", .string("/work/app"))])
        await r.recorder.clearAccepted(); _ = try await r.store.update(task.id, patch: routinesTaskObject([("sessionId", .string("s-1")), ("process", .string("running"))]))
        try await r.local.remove(task.id); #expect(await r.recorder.cancelled == [task.id])
        _ = try await r.local.restore(task.id); #expect(await r.recorder.accepted.isEmpty)
        routinesTaskMatches(try await r.store.byID(task.id)!.value, routinesTaskObject([("sessionId", .null), ("assignee", routinesTaskObject([("identity", .string("builder"))]))]))
        }
    }
    @Test func mergePreservesSourceHistoryAndMovesContents() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(memory: true); defer { try? FileManager.default.removeItem(at: r.root) }
        let source = try await r.task("Duplicate report"), target = try await r.task("Report")
        _ = await r.detail.call("addTaskComment", arguments: [.string(source.id), .string("From the duplicate")]); _ = await r.detail.call("addTaskSubtask", arguments: [.string(source.id), .string("Check the totals")])
        let up = await r.detail.call("uploadTaskFile", arguments: [.string(source.id), routinesTaskObject([("name", .string("figures.csv")), ("type", .string("text/csv")), ("bytes", .bytes(Data([9])))])])
        let path = try #require(up["attachment"]["storagePath"].string)
        let file = r.root.appendingPathComponent("task-files").appendingPathComponent(path)
        let lines = await r.detail.call("listTaskActivity", arguments: [.string(source.id)])["rows"].elements?.count ?? 0
        #expect(await r.detail.call("mergeTaskInto", arguments: [.string(source.id), .string(target.id)]) == routinesTaskObject([("ok", .bool(true))]))
        #expect(try await r.store.byID(source.id) == nil); #expect(try await r.store.inTrash().map(\.id) == [source.id])
        #expect(await r.detail.call("listTaskComments", arguments: [.string(target.id)])["comments"].elements?.contains { $0["body"].string == "From the duplicate" } == true)
        let onTarget = await r.detail.call("fetchTaskDetailBundle", arguments: [.string(target.id)])["bundle"]
        #expect(onTarget["attachments"].elements?.map { $0["fileName"].string! } == ["figures.csv"]); #expect(onTarget["subtasks"].elements?.map { $0["title"].string! } == ["Check the totals"])
        #expect(FileManager.default.fileExists(atPath: file.path)); _ = try await r.local.restore(source.id)
        #expect(await r.detail.call("listTaskActivity", arguments: [.string(source.id)])["rows"].elements?.count ?? 0 >= lines)
        #expect(await r.detail.call("listTaskComments", arguments: [.string(source.id)])["comments"].elements?.contains { $0["body"].string == "From the duplicate" } == true)
        #expect(FileManager.default.fileExists(atPath: file.path))
        }
    }
    @Test func convertingSubtaskKeepsRestorableWholeSource() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(memory: true); defer { try? FileManager.default.removeItem(at: r.root) }
        let child = try await r.task("Book the venue"), parent = try await r.task("Plan the launch")
        #expect(await r.detail.call("convertToSubtask", arguments: [.string(child.id), .string(parent.id)]) == routinesTaskObject([("ok", .bool(true))]))
        #expect(try await r.store.byID(child.id) == nil); #expect(try await r.store.inTrash().map { $0.value["title"].string! } == ["Book the venue"])
        _ = try await r.local.restore(child.id); #expect(try await r.store.byID(child.id)?.value["title"].string == "Book the venue")
        #expect(try await r.store.byID(parent.id)?.value["detail"]["subtasks"].elements?.map { $0["title"].string! } == ["Book the venue"])
        }
    }
    @Test func trashedRemindersSettleButScheduledCommentsWaitForRestore() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(memory: true); defer { try? FileManager.default.removeItem(at: r.root) }
        let due = BackendTaskClockContext.clock.now(), task = try await r.task("Trashed with plans")
        _ = await r.detail.call("setReminder", arguments: [.string(task.id), .string(BackendTaskOutbox.iso(due + 60_000)), .string("Ping")])
        let later = await r.detail.call("addTaskCommentWith", arguments: [.string(task.id), .string("Later on"), routinesTaskObject([("scheduledFor", .string(BackendTaskOutbox.iso(due + 120_000)))])])
        try await r.local.remove(task.id)
        let runDue = try #require(BackendRoutinesTaskStoreParityBindings.runDue)
        try await runDue(r.detail, due + 180_000)
        #expect(await r.notices.count == 0)
        let trashed = try #require(try await r.store.byID(task.id, includeTrash: true))
        #expect(trashed.value["detail"]["reminders"].elements?.first?["lastError"].string == "skipped: the task was deleted")
        #expect(trashed.value["detail"]["commentMeta"][later["id"].string!]["deliveredAt"] == .null)
        _ = try await r.local.restore(task.id); try await runDue(r.detail, due + 180_000)
        #expect(await r.notices.count == 0)
        #expect(await r.detail.call("fetchCommentExtras", arguments: [.string(task.id)])["extras"]["meta"][later["id"].string!]["deliveredAt"].string != nil)
        }
    }
    @Test func trashedRoutineRootMakesNoMoreCopiesUntilRestored() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let clock = try #require(BackendTaskClockContext.clock as? BackendRoutinesTaskEngineParityClock)
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let instant = utc.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 9))!.timeIntervalSince1970 * 1_000
        clock.move(by: instant - clock.now())
        let r = try await BackendRoutinesTaskStoreParityRig.make(memory: true); defer { try? FileManager.default.removeItem(at: r.root) }
        try await r.detail.start()
        do {
        let root = try await r.task("Weekly", fields: [("dueDate", .string("2026-10-09"))])
        let rule = routinesTaskObject([("frequency", .string("weekly")), ("interval", .number(1)), ("unit", .string("week")), ("weekdays", .array([])), ("monthly", .null), ("trigger", .string("status")), ("triggerStatus", .string("Done")), ("timeOfDay", .string("08:00")), ("ends", routinesTaskObject([("type", .string("never"))])), ("createNew", .bool(true)), ("updateStatusTo", .string("To-Do")), ("syncToDue", .bool(true)), ("skipWeekends", .bool(false)), ("perAssignee", .bool(false)), ("missedPolicy", .string("leave_open")), ("pausedAt", .null), ("stoppedAt", .null), ("rootTaskId", .null), ("anchor", .null)])
        #expect(await r.detail.call("saveRoutine", arguments: [.string(root.id), rule, .number(0)])["ok"].bool == true)
        _ = try await r.local.update(root.id, input: routinesTaskObject([("status", .string("Done"))])); await r.detail.settled()
        let copy = try #require(try await r.store.all().first { $0.value["detail"]["routine"]["rootTaskId"].string == root.id })
        try await r.local.remove(root.id); _ = try await r.local.update(copy.id, input: routinesTaskObject([("status", .string("Done"))])); await r.detail.settled()
        #expect(try await r.store.all().filter { $0.value["detail"]["routine"]["rootTaskId"].string == root.id }.count == 1)
        _ = try await r.local.restore(root.id); _ = try await r.local.update(copy.id, input: routinesTaskObject([("status", .string("To-Do"))])); _ = try await r.local.update(copy.id, input: routinesTaskObject([("status", .string("Done"))])); await r.detail.settled()
        #expect(try await r.store.all().filter { $0.value["detail"]["routine"]["rootTaskId"].string == root.id }.map { $0.value["dueDate"].string! }.sorted() == ["2026-10-16", "2026-10-23"])
        await r.detail.stop()
        } catch { await r.detail.stop(); throw error }
        }
    }
    @Test func capNeverPurgesLocalTasksOrTrash() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(memory: true); defer { try? FileManager.default.removeItem(at: r.root) }
        for index in 0..<505 { _ = try await r.store.put(routinesTaskObject([("id", .string("local:\(index)")), ("keyId", .string("local")), ("externalTaskId", .string("\(index)")), ("title", .string("Mine \(index)")), ("local", .bool(true)), ("process", .string("idle"))])) }
        let trashed = try #require(try await r.store.all().first?.id); try await r.store.moveToTrash(trashed)
        for index in 0..<505 { _ = try await r.store.put(routinesTaskObject([("id", .string("k1:\(index)")), ("keyId", .string("k1")), ("externalTaskId", .string("\(index)")), ("title", .string("CRM \(index)")), ("local", .bool(false)), ("process", .string("idle"))])) }
        #expect(try await r.store.all().filter(\.isLocal).count == 504); #expect(try await r.store.all().filter { !$0.isLocal }.count == 500); #expect(try await r.store.inTrash().map(\.id) == [trashed])
        }
    }
}
