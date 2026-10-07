import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

actor BackendCrmSharedParityRecorder {
    var calls: [NativeRPCValue] = [], events: [NativeRPCValue] = []
    let reply: NativeRPCValue
    init(reply: NativeRPCValue) { self.reply = reply }
    func call(_ name: String, _ args: [NativeRPCValue]) -> NativeRPCValue { calls.append(.object([.init("fn",.string(name)),.init("args",.array(args))])); return reply }
    func event(_ value: NativeRPCValue) { events.append(value) }
}
struct BackendCrmSharedParityRig: Sendable {
    let registry: NativeChannelRegistry, recorder: BackendCrmSharedParityRecorder, contribution: BackendCrmRegistration.Contribution
    static func make(reply: NativeRPCValue = crmParityOK()) async throws -> Self {
        let f = try await BackendCrmTaskDetailParityFixture.make(), registry = NativeChannelRegistry(), recorder = BackendCrmSharedParityRecorder(reply:reply)
        let contribution = try await BackendCrmRegistration.register(registry:registry,ownerID:"crm-parity",configuration:f.config,detailOwnership:.ownsDetailChannel,state:{ crmParityValue(["agents":[],"tasks":[]]) },subscribeChanges:{ _ in NativeRPCSubscription {} },installSuppliers:{ _ in
            .init(dispatcher:.init(implementedFunctions:Set(BackendCrmDetailContract.functions),call:{ name,args,_ in await recorder.call(name,args) }),supplierLease:NativeRPCSubscription {})
        },problem:{ #expect(false,"\($0.message)") })
        return Self(registry:registry,recorder:recorder,contribution:contribution)
    }
    func call(_ name: String, _ args: [NativeRPCValue]) async throws -> NativeRPCValue { try await registry.invoke("tasks:local-detail",context:.init(caller:.nativeApp,ownerID:"native-window"),arguments:[.string(name),.array(args)]) }
}

enum BackendCrmSharedParityBridgeMode: Sendable { case recording, throwing(String), missingAnswer, absent }
/// These are client operations, not already-manufactured invoke arguments.
/// The counterpart currently lives in NativeTaskDetailModel (app target) and
/// uses EngineBridge.shared. Bind its genuine injectable client extraction;
/// never implement these defaults/failure conversions as a fake test SUT.
protocol BackendCrmSharedParityNativeClient: Sendable {
    func addChecklist(_ task: String) async -> NativeRPCValue
    func saveRoutine(_ task: String, rule: CrmValue?) async -> NativeRPCValue
    func setReminder(_ task: String, at: String) async -> NativeRPCValue
    func invoke(_ function: String, arguments: [NativeRPCValue]) async -> NativeRPCValue
    func calls() async -> [NativeRPCValue]
}
actor BackendCrmSharedParityClientLog {
    var rows: [NativeRPCValue] = []
    func add(_ function: String, _ arguments: [NativeRPCValue]) { rows.append(.object([.init("fn", .string(function)), .init("args", .array(arguments))])) }
}
/// The production client (BackendCrmDetailClient, which the app's task popup model calls) over a recording or failing transport.
struct BackendCrmSharedParityNativeClientImpl: BackendCrmSharedParityNativeClient {
    let client: BackendCrmDetailClient, log: BackendCrmSharedParityClientLog
    func addChecklist(_ task: String) async -> NativeRPCValue { await client.addChecklist(task) }
    func saveRoutine(_ task: String, rule: CrmValue?) async -> NativeRPCValue { await client.saveRoutine(task, rule: rule) }
    func setReminder(_ task: String, at: String) async -> NativeRPCValue { await client.setReminder(task, at: at) }
    func invoke(_ function: String, arguments: [NativeRPCValue]) async -> NativeRPCValue { await client.call(function, arguments) }
    func calls() async -> [NativeRPCValue] { await log.rows }
}
enum BackendCrmSharedParityNativeClientBinding {
    static let make: (@Sendable (BackendCrmSharedParityBridgeMode) async throws -> any BackendCrmSharedParityNativeClient)? = { mode in
        let log = BackendCrmSharedParityClientLog(), client: BackendCrmDetailClient
        switch mode {
        case .recording: client = BackendCrmDetailClient(isReady: true) { function, arguments in await log.add(function, arguments); return crmParityOK() }
        case .throwing(let message): client = BackendCrmDetailClient(isReady: true) { _, _ in throw NativeRPCError(code: "test-bridge", message: message) }
        case .missingAnswer: client = BackendCrmDetailClient(isReady: true) { _, _ in nil }
        case .absent: client = BackendCrmDetailClient(isReady: false) { _, _ in nil }
        }
        return BackendCrmSharedParityNativeClientImpl(client: client, log: log)
    }
}

@Suite("Renderer CRM tests: native backend/shared-contract intent")
struct BackendCrmSharedParityTests {
    @Test func a01EveryActionKeepsNameAndArgumentOrder() async throws {
        let r = try await BackendCrmSharedParityRig.make()
        let samples: [(String,[NativeRPCValue])] = [
            ("setTaskStatus",[.string("local:a"),.string("Done")]),("updateTask",[.string("local:a"),crmParityValue(["title":"New","priority":"High"])]),
            ("addTaskSubtask",[.string("local:a"),.string("Write it")]),("setTaskSubtaskDone",[.string("local:a"),.string("s1"),.bool(true)]),
            ("addTaskDependency",[.string("local:a"),.string("local:b"),.string("blocks")]),("addTaskTimeEntry",[.string("local:a"),crmParityValue(["seconds":600,"date":"2026-10-01","note":NSNull(),"billable":false])]),
            ("addTaskCommentWith",[.string("local:a"),.string("Hi @Builder"),crmParityValue(["parentId":"c1","assigneeUserId":NSNull(),"scheduledFor":NSNull()])]),
            ("toggleCommentReaction",[.string("local:a"),.string("c1"),.string("👍")]),("setLabelColor",[.string("web"),.string("red")])]
        let expectedNames = ["fetchTaskDetailBundle", "listTaskComments", "listTaskActivity", "setTaskStatus", "updateTask", "assignTask", "addTaskAssignee", "removeTaskAssignee", "addTaskSubtask", "setTaskSubtaskDone", "deleteTaskSubtask", "setTaskSubtaskAssignee", "addChecklist", "renameChecklist", "deleteChecklist", "addChecklistItem", "setChecklistItemDone", "setChecklistItemAssignee", "deleteChecklistItem", "addTaskDependency", "removeTaskDependency", "attachExistingDocument", "detachTaskAttachment", "addTaskComment", "fetchTaskPageExtras", "setTaskType", "setTaskLabels", "setTaskLinks", "moveTask", "setTimeEstimate", "setTaskRecurrence", "setSubtaskMeta", "startTaskTimer", "stopTaskTimer", "addTaskTimeEntry", "deleteTaskTimeEntry", "duplicateTask", "fetchRoutine", "saveRoutine", "stopRoutine", "pauseRoutine", "restartRoutine", "fetchTaskMore", "setReminder", "clearReminder", "setArchived", "mergeTaskInto", "convertToSubtask", "setSyncSubtaskDates", "setTaskTimes", "setLabelColor", "deleteLabelEverywhere", "setTimeEntryTags", "fetchDescriptionHistory", "fetchCommentExtras", "addTaskCommentWith", "toggleCommentReaction", "setCommentResolved", "assignComment", "sendScheduledNow", "chooseTaskFiles", "openTaskFile"]
        let sampleArgs = Dictionary(uniqueKeysWithValues:samples)
        for name in expectedNames { _ = try await r.call(name,sampleArgs[name] ?? [.string("local:a"),.string("x")]) }
        let recorded = await r.recorder.calls
        #expect(recorded.map { $0["fn"].string ?? "" } == expectedNames)
        for name in expectedNames { #expect(BackendCrmDetailContract.functions.contains(name)) }
        for (name,args) in samples { let seen = try #require(recorded.first { $0["fn"].string == name }); #expect(crmParityEqual(seen["args"],.array(args))) }
        await r.contribution.lease.cancelAndWait()
    }
    @Test func a02OptionalArgumentsKeepExplicitNullSlots() async throws {
        let make = try #require(BackendCrmSharedParityNativeClientBinding.make,"Need genuine injectable native detail client"), client = try await make(.recording)
        _ = await client.addChecklist("local:a"); _ = await client.saveRoutine("local:a",rule:nil)
        _ = await client.setReminder("local:a",at:"2026-10-09T08:00:00.000Z")
        #expect(crmParityEqual(.array(await client.calls()),crmParityValue([["fn":"addChecklist","args":["local:a",NSNull()]],["fn":"saveRoutine","args":["local:a",NSNull(),NSNull()]],["fn":"setReminder","args":["local:a","2026-10-09T08:00:00.000Z",NSNull()]]])))
    }
    @Test func a03DropAndPasteCarryFileNameMimeAndExactBytes() async throws {
        let reply = crmParityValue(["ok":true,"attachment":["id":"f1"]]), r = try await BackendCrmSharedParityRig.make(reply:reply)
        let file = BackendCrmDetailContract.LocalUpload(name:"notes.txt",type:"text/plain",bytes:Data("hello".utf8))
        #expect(crmParityEqual(try await r.call("uploadTaskFile",[.string("local:a"),file.wire]),reply))
        let call = try #require(await r.recorder.calls.first), upload = try #require(call["args"].elements?.last)
        #expect(call["fn"].string == "uploadTaskFile" && call["args"].elements?.first?.string == "local:a")
        #expect(upload["name"].string == "notes.txt" && upload["type"].string == "text/plain" && upload["bytes"] == .bytes(Data("hello".utf8)))
        #expect(BackendCrmDetailContract.LocalUpload(name:"a.md",type:"text/plain",bytes:Data("x".utf8)).wire["name"].string == "a.md")
        await r.contribution.lease.cancelAndWait()
    }
    @Test func a04FailuresRemainSentencesAndMissingAnswersAreExplicit() async throws {
        let make = try #require(BackendCrmSharedParityNativeClientBinding.make,"Need genuine injectable native detail client")
        let throwing = try await make(.throwing("the main process went away")), missing = try await make(.missingAnswer), absent = try await make(.absent)
        #expect(crmParityEqual(await throwing.invoke("fetchTaskDetailBundle",arguments:[.string("local:a")]),crmParityFailure("the main process went away")))
        #expect(crmParityEqual(await missing.invoke("listTaskComments",arguments:[.string("local:a")]),crmParityFailure("Terminal Deck did not answer that.")))
        #expect(crmParityEqual(await absent.invoke("setTaskStatus",arguments:[.string("local:a"),.string("Done")]),crmParityFailure("This build cannot change tasks.")))
    }
    @Test func a06FieldCallsKeepTheirSourceNamesAndPayloads() async throws {
        let r = try await BackendCrmSharedParityRig.make()
        let calls:[(String,[NativeRPCValue])] = [("listTaskFields",[.string("local:a")]),("createTaskField",[.string("local:a"),crmParityValue(["label":"Votes","kind":"voting"])]),("toggleTaskFieldVote",[.string("f1")]),("pressTaskFieldButton",[.string("f2")]),("reorderTaskFields",[.string("local:a"),crmParityValue(["f2","f1"])]),("uploadTaskFile",[.string("local:a"),BackendCrmDetailContract.LocalUpload(name:"x.txt",type:"text/plain",bytes:Data("x".utf8)).wire])]
        for (name,args) in calls { _ = try await r.call(name,args) }
        let seen = await r.recorder.calls
        #expect(seen.map { $0["fn"].string ?? "" } == calls.map(\.0))
        #expect(crmParityEqual(seen[1]["args"],crmParityValue(["local:a",["label":"Votes","kind":"voting"]])))
        await r.contribution.lease.cancelAndWait()
    }
    @Test func a07SearchAndProjectUseTheSameDetailChannel() async throws {
        let r = try await BackendCrmSharedParityRig.make(reply:crmParityValue(["ok":true,"hits":[]]))
        _ = try await r.call("searchTags",[.string("person"),.string("Bu")]); _ = try await r.call("setTaskProject",[.string("local:a"),.string("/work/app")]); _ = try await r.call("chooseTaskProject",[.string("local:a")])
        #expect(crmParityEqual(.array(await r.recorder.calls),crmParityValue([["fn":"searchTags","args":["person","Bu"]],["fn":"setTaskProject","args":["local:a","/work/app"]],["fn":"chooseTaskProject","args":["local:a"]]])))
        await r.contribution.lease.cancelAndWait()
    }
    @Test func w03OneChannelIsGuardedForTheNativeWindow() async throws {
        let r = try await BackendCrmSharedParityRig.make()
        #expect(await r.registry.channels() == ["tasks:local-detail"])
        do { _ = try await r.registry.invoke("tasks:local-detail",context:.init(caller:.page,ownerID:"page"),arguments:[.string("fetchTaskDetailBundle"),.array([.string("local:a")])]); #expect(false) }
        catch { #expect((error as? NativeRPCError)?.code == "access-denied") }
        #expect(crmParityEqual(try await r.registry.invoke("tasks:local-detail",context:.init(caller:.nativeApp,ownerID:"window"),arguments:[.string("invented"),.array([])]),crmParityFailure("That is not something the task popup can do.")))
        await r.contribution.lease.cancelAndWait()
    }
    @Test func w04ActualDispatcherAnswersEveryPopupContractFunction() async throws {
        let f = try await BackendCrmTaskDetailParityFixture.make()
        let dispatcher = BackendCrmRegistration.DetailDispatcher(service:f.detail)
        #expect(Set(BackendCrmDetailContract.functions).subtracting(dispatcher.implementedFunctions).isEmpty)
        for fn in BackendCrmDetailContract.functions {
            let result = await f.call(fn,.string("local:missing"),.null)
            #expect(result["ok"].bool != nil, "\(fn) must answer in the source result envelope")
            #expect(result["error"].string?.contains("is unavailable") != true, "Unported contract function: \(fn)")
        }
    }
    @Test func w05TaskOpenAndChangedEventsKeepSourceEnvelopes() async throws {
        let r = try await BackendCrmSharedParityRig.make(), listener = try await r.registry.subscribeAll(ownerID:"native-window") { await r.recorder.event($0.wireValue) }
        try await r.contribution.suppliers.openTask("local:task"); try await r.contribution.suppliers.changed()
        #expect(crmParityEqual(.array(await r.recorder.events),crmParityValue([["channel":"tasks:open","args":["local:task"]],["channel":"tasks:changed","args":[]]])))
        await listener.cancelAndWait(); await r.contribution.lease.cancelAndWait()
        // Window focus/React panel routing are renderer/Electron-only; wake
        // behavior is exercised by c03WakeCatchesUpAndStoppedClockDoesNothing.
    }
    @Test func w06SinglePersonTaskDoesNotPretendToShareOrUnfollow() async throws {
        let f = try await BackendCrmTaskDetailParityFixture.make(), id = try await f.make("Private local task")
        for (fn,value) in [("setFollowing",NativeRPCValue.bool(false)),("addFollower",.string("hoot")),("removeFollower",.string("me"))] {
            #expect(crmParityEqual(await f.call(fn,.string(id),value),crmParityFailure("Only you see tasks on this computer, so there is nobody else to follow this one — and nothing to unfollow.")))
        }
        // link=null/header copy/share strings and DOM controls belong to the
        // retired renderer; their native UI replacement is outside backend tests.
    }
}
