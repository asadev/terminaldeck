import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// tasks-ipc.test.ts hands the channel a stand-in detail owner. The channels take any BackendTaskDetailCalling, so the
/// real registration runs over the real stores and only the detail owner is a recorder.
enum BackendRoutinesTaskAPIParityChannelBindings {
    private struct Forwarder: BackendTaskDetailCalling {
        let callback: @Sendable (String, [NativeRPCValue]) async -> NativeRPCValue
        func isRunning() async -> Bool { true }
        func callDetail(_ function: String, arguments: [NativeRPCValue]) async -> NativeRPCValue { await callback(function, arguments) }
        func poke() async {}
    }
    static let detailCallback: (@Sendable (@escaping @Sendable (String, [NativeRPCValue]) async -> NativeRPCValue) async throws -> NativeChannelRegistry)? = { callback in
        let rig = try await BackendRoutinesTaskStoreParityRig.make(memory: true), registry = NativeChannelRegistry()
        _ = try await BackendTaskChannels.register(registry: registry, ownerID: "parity", view: rig.view, local: rig.local, engine: rig.engine, detail: Forwarder(callback: callback),
            dependencies: .init(keyViews: { [] }, makeCRMKey: nil))
        return registry
    }
}
actor BackendRoutinesTaskAPIParityKeys {
    var made: [String] = []
    func create(_ name: String) -> (id: String, key: String) { let id = "crm-\(made.count + 1)"; made.append(id); return (id, "ak_secret_for_" + name.replacingOccurrences(of: " ", with: "_")) }
    func views() -> [NativeRPCValue] { made.map { routinesTaskObject([("id", .string($0)), ("name", .string("Sales CRM (CRM)")), ("crmOnly", .bool(true)), ("lastApp", .null)]) } }
}
actor BackendRoutinesTaskAPIParityCalls {
    var values: [NativeRPCValue] = []
    func add(_ fn: String, _ args: [NativeRPCValue]) { values.append(.array([.string(fn), .array(args)])) }
}
@Suite("Exact goals-ipc.test.ts parity")
struct BackendRoutinesTaskAPIParityGoalChannels {
    @Test func goalSaveReturnsEveryGoalWithProgressAndTaskFields() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(memory: true); defer { try? FileManager.default.removeItem(at: r.root) }
        let made = try await r.call("tasks:goal-save", [routinesTaskObject([("title", .string("Ship 0.18")), ("description", .string("Mac only."))])])
        #expect(made["ok"].bool == true); let goal = try #require(made["state"]["goals"].elements?.first)
        routinesTaskMatches(goal, routinesTaskObject([("title", .string("Ship 0.18")), ("description", .string("Mac only.")), ("status", .string("active")), ("parentId", .null), ("progress", routinesTaskObject([("total", .number(0))]))]))
        _ = try await r.task("Write the notes", fields: [("goalId", goal["id"]), ("status", .string("Done"))])
        let changed = try await r.call("tasks:goal-save", [routinesTaskObject([("id", goal["id"]), ("status", .string("achieved"))])])
        routinesTaskMatches(try #require(changed["state"]["goals"].elements?.first), routinesTaskObject([("status", .string("achieved")), ("progress", routinesTaskObject([("total", .number(1)), ("done", .number(1)), ("unverified", .number(1))]))]))
        routinesTaskMatches(try #require(changed["state"]["tasks"].elements?.first), routinesTaskObject([("goalId", goal["id"]), ("useWorkspace", .bool(false)), ("stalled", .null), ("waitingOn", .array([]))]))
        }
    }
    @Test func goalErrorsUsePageWordsAndRejectStranger() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(memory: true); defer { try? FileManager.default.removeItem(at: r.root) }
        routinesTaskMatches(try await r.call("tasks:goal-save", [routinesTaskObject([("title", .string(" "))])]), routinesTaskObject([("ok", .bool(false)), ("message", .string("The goal’s title cannot be empty."))]))
        routinesTaskMatches(try await r.call("tasks:goal-remove", [.string("goal-gone")]), routinesTaskObject([("ok", .bool(false)), ("message", .string("That goal no longer exists."))]))
        #expect(await routinesTaskError { _ = try await r.call("tasks:goal-save", [routinesTaskObject([("title", .string("x"))])], stranger: true) }.contains("only the app’s own window"))
        }
    }
    @Test func goalRemovalRelinksLiveAndTrashedTasks() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(memory: true); defer { try? FileManager.default.removeItem(at: r.root) }
        let root = try await r.goals.save(routinesTaskObject([("title", .string("Releases"))])), release = try await r.goals.save(routinesTaskObject([("title", .string("Ship 0.18")), ("parentId", root["id"])]))
        let below = try await r.goals.save(routinesTaskObject([("title", .string("Notes")), ("parentId", release["id"])])), made = try await r.task("Write them", fields: [("goalId", release["id"])]), trashed = try await r.task("Old draft", fields: [("goalId", release["id"])])
        try await r.store.moveToTrash(trashed.id); #expect(try await r.call("tasks:goal-remove", [release["id"]])["ok"].bool == true)
        #expect(try await r.goals.byID(below["id"].string!)?["parentId"] == root["id"])
        #expect(try await r.store.byID(made.id)?.value["goalId"] == root["id"]); #expect(try await r.store.byID(trashed.id, includeTrash: true)?.value["goalId"] == root["id"])
        }
    }
    @Test func queuedTaskNamesOpenBlockers() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(memory: true); defer { try? FileManager.default.removeItem(at: r.root) }
        let first = try await r.task("Build the API"), second = try await r.task("Build the page")
        _ = try await r.store.update(second.id, patch: routinesTaskObject([("process", .string("queued")), ("detail", routinesTaskObject([("dependencies", .array([routinesTaskObject([("kind", .string("blocked_by")), ("otherTaskId", .string(first.id)), ("at", .number(1))])]))]))]))
        #expect(try await r.view.state()["tasks"].elements?.first { $0["id"].string == second.id }?["waitingOn"] == routinesTaskText(["Build the API"]))
        }
    }
}
@Suite("Exact tasks-ipc.test.ts parity")
struct BackendRoutinesTaskAPIParityTaskChannels {
    private func form(_ over: [(String, NativeRPCValue)] = []) -> NativeRPCValue {
        routinesTaskObject([("eventsUrl", .null), ("hootIdentity", .null), ("allowedSenders", .array([])), ("folders", .array([])), ("maxHops", .number(3)), ("identities", .object([])), ("statuses", BackendTaskConfiguration.defaultStatuses)]).merging(routinesTaskObject(over))
    }
    @Test func savesFormAndPreservesPrivateSecret() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(); defer { try? FileManager.default.removeItem(at: r.root) }
        let expected = form([("eventsUrl", .string("https://crm.example.com/td-events")), ("allowedSenders", routinesTaskText(["u-asad"])), ("hootIdentity", .string("u-hoot")), ("folders", routinesTaskText(["/work/app", "/work/site"])), ("maxHops", .number(2)), ("identities", routinesTaskObject([("u-builder", .string("builder")), ("u-tester", .string("tester"))]))])
        let patch = expected.setting("allowedSenders", routinesTaskText(["u-asad", "u-asad"])).setting("hootIdentity", .string(" u-hoot "))
        let saved = try await r.call("tasks:connection-save", [.string("k1"), patch]); #expect(saved["ok"].bool == true); #expect(saved["secret"] == .missing)
        let state = try await r.call("tasks:state"), shown = try #require(state["connections"].elements?.first)
        routinesTaskMatches(shown, expected.setting("hasEventsSecret", .bool(true))); #expect(!state.compact.contains(BackendRoutinesTaskStoreParityRig.secret))
        let raw = try #require(try r.persistence.read("task-config.json"))["connections"].elements!.first!
        #expect(raw["eventsSecret"].string == BackendRoutinesTaskStoreParityRig.secret); #expect(raw["enabled"].bool == false)
        }
    }
    @Test func formRefusalsSayWhyAndChangeNothing() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(); defer { try? FileManager.default.removeItem(at: r.root) }
        let cases: [(NativeRPCValue, String)] = [(form([("eventsUrl", .string("http://crm.example.com/hook"))]), "https"), (form([("folders", routinesTaskText(["work/app"]))]), "not a full folder path"), (form([("hootIdentity", .string("u-builder")), ("identities", routinesTaskObject([("u-builder", .string("builder"))]))]), "cannot also be an agent"), (form([("identities", routinesTaskObject([("u-ghost", .string("nobody"))]))]), "does not exist"), (form([("maxHops", .number(9))]), "1 to 5"), (form([("statuses", BackendTaskConfiguration.defaultStatuses.setting("onStarted", .string("Doing")))]), "has to be one of")]
        for (patch, why) in cases { let answer = try await r.call("tasks:connection-save", [.string("k1"), patch]); #expect(answer["ok"].bool == false); #expect(answer["message"].string?.contains(why) == true) }
        routinesTaskMatches(try await r.config.connection("k1")!, routinesTaskObject([("eventsUrl", .null), ("folders", .array([])), ("hootIdentity", .null), ("identities", .object([]))]))
        }
    }
    @Test func enabledToggleKeepsOtherFields() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(); defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(try await r.call("tasks:connection-save", [.string("k1"), routinesTaskObject([("enabled", .bool(true))])])["ok"].bool == true)
        routinesTaskMatches(try await r.config.connection("k1")!, routinesTaskObject([("enabled", .bool(true)), ("eventsSecret", .string(BackendRoutinesTaskStoreParityRig.secret)), ("allowedSenders", .array([]))]))
        #expect(try await r.call("tasks:connection-save", [.string("k1"), routinesTaskObject([("enabled", .bool(false))])])["ok"].bool == true); #expect(try await r.config.connection("k1")?["enabled"].bool == false)
        }
    }
    @Test func connectionSaveRejectsOtherWindow() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(); defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(await routinesTaskError { _ = try await r.call("tasks:connection-save", [.string("k1"), routinesTaskObject([("enabled", .bool(true))])], stranger: true) }.contains("only the app’s own window"))
        #expect(try await r.config.connection("k1")?["enabled"].bool == false)
        }
    }
    @Test func agentLifecycleStateAndExactRefusals() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(); defer { try? FileManager.default.removeItem(at: r.root) }
        let paused = try await r.call("tasks:agent-status", [.string("builder"), .string("pause")]); #expect(paused["ok"].bool == true)
        #expect(paused["state"]["agents"].elements?.first { $0["id"].string == "builder" }?["status"].string == "paused")
        routinesTaskMatches(try await r.call("tasks:agent-status", [.string("builder"), .string("pause")]), routinesTaskObject([("ok", .bool(false)), ("message", .string("Builder is already paused."))]))
        for (action, status) in [("archive", "archived"), ("restore", "active")] { #expect(try await r.call("tasks:agent-status", [.string("builder"), .string(action)])["state"]["agents"].elements?.first { $0["id"].string == "builder" }?["status"].string == status) }
        routinesTaskMatches(try await r.call("tasks:agent-status", [.string("ghost"), .string("pause")]), routinesTaskObject([("ok", .bool(false)), ("message", .string("That agent no longer exists."))]))
        #expect(try await r.call("tasks:agent-status", [.number(7), .string("pause")])["ok"].bool == false)
        }
    }
    @Test func agentStatusRejectsOtherWindow() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(memory: true); defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(await routinesTaskError { _ = try await r.call("tasks:agent-status", [.string("builder"), .string("pause")], stranger: true) }.contains("only the app"))
        #expect(try await r.config.agent("builder")?["status"].string == "active")
        }
    }
    @Test func localChannelsCreateEditReplyAndRefuseExactly() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(); defer { try? FileManager.default.removeItem(at: r.root) }
        let made = try await r.call("tasks:local-create", [routinesTaskObject([("title", .string("Write the notes")), ("assignee", .string("me")), ("status", .string("To-Do"))])]); #expect(made["ok"].bool == true)
        let task = try #require(made["state"]["tasks"].elements?.first)
        routinesTaskMatches(task, routinesTaskObject([("local", .bool(true)), ("title", .string("Write the notes")), ("assignee", .string("me")), ("agent", .string("Me")), ("crmStatus", .string("To-Do")), ("process", .string("idle"))]))
        #expect(made["state"]["localStatuses"] == routinesTaskText(["To-Do", "Working on it", "In Progress", "Done", "Stuck"]))
        #expect(try await r.call("tasks:local-update", [task["id"], routinesTaskObject([("assignee", .string("tester"))])])["message"].string == "Choose the project folder the agent should work in.")
        let moved = try await r.call("tasks:local-update", [task["id"], routinesTaskObject([("status", .string("Done")), ("assignee", .string("tester")), ("project", .string("/work/app"))])])
        let changed = try #require(moved["state"]["tasks"].elements?.first); routinesTaskMatches(changed, routinesTaskObject([("crmStatus", .string("Done")), ("assignee", .string("tester")), ("agent", .string("Tester"))]))
        #expect(changed["notes"].elements?.map { $0["text"].string! } == ["Created, assigned to you.", "Changed the project.", "Status: Done", "Assigned to Tester."])
        let refused = try await r.call("tasks:local-update", [task["id"], routinesTaskObject([("status", .string("Cancelled"))])]); #expect(refused["ok"].bool == false); #expect(refused["message"].string?.contains("status has to be one of") == true)
        #expect(try await r.call("tasks:local-reply", [task["id"], .string("hello")])["ok"].bool == true)
        #expect(await routinesTaskError { _ = try await r.call("tasks:local-create", [routinesTaskObject([("title", .string("x"))])], stranger: true) }.contains("only the app’s own window"))
        }
    }
    @Test func trashChannelsDeleteRestoreAndRejectStranger() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(); defer { try? FileManager.default.removeItem(at: r.root) }
        let made = try await r.call("tasks:local-create", [routinesTaskObject([("title", .string("Disposable")), ("assignee", .string("me"))])]), id = try #require(made["state"]["tasks"].elements?.first?["id"])
        let deleted = try await r.call("tasks:local-delete", [id]); #expect(!(deleted["state"]["tasks"].elements ?? []).contains { $0["id"] == id })
        let trash = deleted["state"]["trash"].elements ?? []; #expect(trash.count == 1); #expect(trash.first?["id"] == id); #expect(trash.first?["title"].string == "Disposable"); #expect(trash.first?["deletedAt"].number != nil)
        #expect(await routinesTaskError { _ = try await r.call("tasks:local-restore", [id], stranger: true) }.contains("only the app’s own window"))
        let restored = try await r.call("tasks:local-restore", [id]); #expect(restored["ok"].bool == true); #expect(restored["state"]["tasks"].elements?.contains { $0["id"] == id } == true); #expect(restored["state"]["trash"] == .array([]))
        #expect(try await r.call("tasks:local-restore", [id])["message"].string == "That task is not in the Trash.")
        }
    }
    @Test func popupChannelMatchesWindowContract() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(memory: true); defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(BackendCrmDetailContract.channel == "tasks:local-detail"); #expect(await r.registry.has("tasks:local-detail"))
        }
    }
    @Test func popupForwardsFunctionAndArgumentsAndReturnsResult() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let bind = try #require(BackendRoutinesTaskAPIParityChannelBindings.detailCallback)
        let seen = BackendRoutinesTaskAPIParityCalls(), registry = try await bind { fn, args in await seen.add(fn, args); return routinesTaskObject([("ok", .bool(true)), ("id", .string("sub-1"))]) }
        let value = try await registry.invoke("tasks:local-detail", context: .init(caller: .nativeApp, ownerID: "parity"), arguments: [.string("addTaskSubtask"), .array([.string("local:a"), .string("Write it")])])
        #expect(value == routinesTaskObject([("ok", .bool(true)), ("id", .string("sub-1"))])); #expect(await seen.values == [.array([.string("addTaskSubtask"), .array([.string("local:a"), .string("Write it")])])])
        }
    }
    @Test func popupRejectsStrangerUnknownVerbAndNonArray() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(memory: true); defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(await routinesTaskError { _ = try await r.call("tasks:local-detail", [.string("addTaskSubtask"), .array([.string("local:a"), .string("x")])], stranger: true) }.contains("only the app’s own window"))
        #expect(try await r.call("tasks:local-detail", [.string("dropDatabase"), .array([])]) == routinesTaskObject([("ok", .bool(false)), ("error", .string("That is not something the task popup can do."))]))
        let bind = try #require(BackendRoutinesTaskAPIParityChannelBindings.detailCallback)
        let seen = BackendRoutinesTaskAPIParityCalls(), registry = try await bind { fn, args in await seen.add(fn, args); return routinesTaskObject([("ok", .bool(true))]) }
        #expect(try await registry.invoke("tasks:local-detail", context: .init(caller: .nativeApp, ownerID: "parity"), arguments: [.string("addTaskSubtask"), .string("local:a")]) == routinesTaskObject([("ok", .bool(false)), ("error", .string("That request was not understood."))]))
        #expect(await seen.values.isEmpty)
        }
    }
    @Test func popupReportsTasksNotRunning() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(memory: true); defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(try await r.call("tasks:local-detail", [.string("listTaskComments"), .array([.string("local:a")])]) == routinesTaskObject([("ok", .bool(false)), ("error", .string("Tasks are not running on this computer right now."))]))
        }
    }
    @Test func CRMKeyRequiresConfirmedPressAndReturnsKeyOnce() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let keys = BackendRoutinesTaskAPIParityKeys(), r = try await BackendRoutinesTaskStoreParityRig.make(makeKey: { await keys.create($0) }, keyViews: { await keys.views() }); defer { try? FileManager.default.removeItem(at: r.root) }
        for input in [routinesTaskObject([("name", .string("Sales CRM"))]), routinesTaskObject([("name", .string("  ")), ("confirmed", .bool(true))])] { #expect(try await r.call("tasks:connection-create", [input])["ok"].bool == false) }; #expect(await keys.made.isEmpty)
        let answer = try await r.call("tasks:connection-create", [routinesTaskObject([("name", .string("Sales CRM")), ("confirmed", .bool(true))])]); #expect(answer["ok"].bool == true); #expect(answer["key"].string == "ak_secret_for_Sales_CRM")
        routinesTaskMatches(try #require(answer["state"]["connections"].elements?.first { $0["keyId"].string == "crm-1" }), routinesTaskObject([("name", .string("Sales CRM")), ("enabled", .bool(false))]))
        #expect(await routinesTaskError { _ = try await r.call("tasks:connection-create", [routinesTaskObject([("name", .string("X")), ("confirmed", .bool(true))])], stranger: true) }.contains("only the app")); #expect(await keys.made == ["crm-1"])
        }
    }
}
