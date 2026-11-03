import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class ChatProviderAutonomousTurnTests: XCTestCase, @unchecked Sendable {
    private func json(_ value: String) throws -> NativeRPCValue { try .parseJSON(Data(value.utf8)) }
    private func ready() throws -> BackendHootChatRPC {
        var rpc = BackendHootChatRPC(provider: .codex, setup: .init(cwd: "/project"))
        let hello = try rpc.begin(id: "hello", resume: nil)
        let start = try rpc.receive(.object([.init("id", hello["id"]), .init("result", .object([]))])).send.last!
        _ = try rpc.receive(.object([.init("id", start["id"]), .init("result", try json(#"{"thread":{"id":"session"}}"#))]))
        return rpc
    }

    func testExactIdleProviderTurnIsAdoptedWithoutClientRequestAndRetiredStartsStayIgnored() throws {
        var rpc = try ready()
        XCTAssertTrue(try rpc.receive(json(#"{"method":"turn/started","params":{"threadId":"foreign","turn":{"id":"foreign-turn","status":"inProgress"}}}"#)).records.isEmpty)
        XCTAssertTrue(try rpc.receive(json(#"{"method":"turn/started","params":{"threadId":"session","turn":{"id":"historical","status":"completed"}}}"#)).records.isEmpty)
        let started = try rpc.receive(json(#"{"method":"turn/started","params":{"threadId":"session","turn":{"id":"goal","status":"inProgress"}}}"#))
        XCTAssertEqual(started.records.first?.value["providerTurnStarted"]["turnId"].string, "provider:goal")
        XCTAssertTrue(started.send.isEmpty)
        XCTAssertFalse(started.records.contains { $0.kind == .user })
        XCTAssertThrowsError(try rpc.user("must wait", attachments: [], id: "client"))
        XCTAssertThrowsError(try rpc.review(arguments: .object([]), id: "review"))
        XCTAssertTrue(try rpc.receive(json(#"{"method":"turn/started","params":{"threadId":"session","turn":{"id":"other","status":"inProgress"}}}"#)).records.isEmpty)
        XCTAssertEqual(try rpc.receive(json(#"{"method":"item/agentMessage/delta","params":{"threadId":"session","turnId":"goal","itemId":"a","delta":"actual output"}}"#)).records.first?.value["text"].string, "actual output")
        let stop = try rpc.interrupt()
        XCTAssertEqual(stop["params"]["threadId"].string, "session")
        XCTAssertEqual(stop["params"]["turnId"].string, "goal")
        _ = try rpc.receive(json(#"{"method":"turn/completed","params":{"threadId":"session","turn":{"id":"goal","status":"completed"}}}"#))
        XCTAssertTrue(try rpc.receive(json(#"{"method":"turn/started","params":{"threadId":"session","turn":{"id":"goal","status":"inProgress"}}}"#)).records.isEmpty)
        XCTAssertNoThrow(try rpc.user("next real user", attachments: [], id: "client-next"))
    }

    func testClientStartedAndChildTurnsNeverBecomeAutonomousParentTurns() throws {
        var rpc = try ready()
        _ = try rpc.user("normal", attachments: [], id: "client")
        let normal = try rpc.receive(json(#"{"method":"turn/started","params":{"threadId":"session","turn":{"id":"client-turn","status":"inProgress"}}}"#))
        XCTAssertTrue(normal.records.isEmpty)
        _ = try rpc.receive(json(#"{"id":"client","result":{"turn":{"id":"client-turn"}}}"#))
        _ = try rpc.receive(json(#"{"method":"turn/completed","params":{"threadId":"session","turn":{"id":"client-turn","status":"completed"}}}"#))
        _ = try rpc.receive(json(#"{"method":"thread/started","params":{"thread":{"id":"child","parentThreadId":"session"}}}"#))
        let child = try rpc.receive(json(#"{"method":"turn/started","params":{"threadId":"child","turn":{"id":"child-turn","status":"inProgress"}}}"#))
        XCTAssertFalse(child.records.contains { $0.value["providerTurnStarted"].fields != nil })
        XCTAssertNoThrow(try rpc.user("parent is idle", attachments: [], id: "parent-next"))
    }

    func testConfirmedResumeGoalIsTrackedDuringCatalogueWaitWithoutSkippingToolVerification() throws {
        var rpc = BackendHootChatRPC(provider: .codex, setup: .init(cwd: "/project", expectedTools: ["deck": ["read"]]))
        let hello = try rpc.begin(id: "hello", resume: "session")
        let resume = try rpc.receive(.object([.init("id", hello["id"]), .init("result", .object([]))])).send.last!
        XCTAssertTrue(try rpc.receive(json(#"{"method":"turn/started","params":{"threadId":"unconfirmed","turn":{"id":"bad","status":"inProgress"}}}"#)).records.isEmpty)
        let loading = try rpc.receive(.object([.init("id", resume["id"]), .init("result", try json(#"{"thread":{"id":"session"}}"#))]))
        let catalogue = try XCTUnwrap(loading.send.first { $0["method"].string == "mcpServerStatus/list" })
        XCTAssertFalse(loading.ready)
        let started = try rpc.receive(json(#"{"method":"turn/started","params":{"threadId":"session","turn":{"id":"resumed-goal","status":"inProgress"}}}"#))
        XCTAssertEqual(started.records.first?.value["providerTurnStarted"]["turnId"].string, "provider:resumed-goal")
        XCTAssertFalse(started.ready)
        XCTAssertThrowsError(try rpc.user("not initialized", attachments: [], id: "client"))
        let output = try rpc.receive(json(#"{"method":"item/agentMessage/delta","params":{"threadId":"session","turnId":"resumed-goal","itemId":"a","delta":"Visible during discovery"}}"#))
        XCTAssertEqual(output.records.first?.value["text"].string, "Visible during discovery")
        XCTAssertFalse(output.ready)
        _ = try rpc.receive(json(#"{"method":"turn/completed","params":{"threadId":"session","turn":{"id":"resumed-goal","status":"completed"}}}"#))
        let waiting = try rpc.receive(.object([.init("id", catalogue["id"]), .init("result", try json(#"{"data":[{"name":"deck","tools":{},"runtimeStatus":"starting"}]}"#))]))
        XCTAssertFalse(waiting.ready)
        let next = try rpc.receive(json(#"{"method":"turn/started","params":{"threadId":"session","turn":{"id":"catalogue-wait-goal","status":"inProgress"}}}"#))
        XCTAssertEqual(next.records.first?.value["providerTurnStarted"]["providerTurnId"].string, "catalogue-wait-goal")
        XCTAssertFalse(next.ready)
        let refreshed = try rpc.receive(json(#"{"method":"mcpServerStatus/updated","params":{"threadId":"session","name":"deck","status":"connected"}}"#))
        let refreshedCatalogue = try XCTUnwrap(refreshed.send.first)
        let ready = try rpc.receive(.object([.init("id", refreshedCatalogue["id"]), .init("result", try json(#"{"data":[{"name":"deck","tools":{"read":{}},"runtimeStatus":"connected"}]}"#))]))
        XCTAssertTrue(ready.ready)
        XCTAssertEqual(try rpc.interrupt()["params"]["turnId"].string, "catalogue-wait-goal")
    }

    func testPureTurnUsesActualProviderStartAnchorRatherThanPreviousUser() throws {
        let rows = try json(#"[{"kind":"user","turnId":"previous","value":{"text":"earlier user"}},{"kind":"completed","turnId":"previous","value":{}},{"kind":"session","turnId":"provider:goal","value":{"providerTurnStarted":{"providerSessionId":"session","providerTurnId":"goal","turnId":"provider:goal"}}},{"kind":"message","turnId":"provider:goal","value":{"text":"Goal answer"}},{"kind":"completed","turnId":"provider:goal","value":{}}]"#)
        let snapshot = NativeRPCValue.object([.init("events", rows), .init("busy", .bool(false)), .init("sequence", .number(5))])
        let done = BackendSessionChats.turn(of: snapshot)
        XCTAssertEqual(done.turnID, "provider:goal")
        XCTAssertEqual(done.state, .done(answer: "Goal answer"))
        let pending = NativeRPCValue.array([.object([.init("requestId", .string("101"))])])
        let waiting = BackendSessionChats.turn(of: snapshot.setting("busy", .bool(true)).setting("pending", pending))
        XCTAssertEqual(waiting.turnID, "provider:goal")
        if case .needsPermission = waiting.state { } else { XCTFail("Provider turn permission was not exposed") }
        XCTAssertEqual(rows.elements?.filter { $0["kind"].string == "user" }.count, 1)
    }

    private let fixture = #"""
import json,sys,os
goals=0
def out(v): print(json.dumps(v),flush=True)
def notice(method,params): out({'method':method,'params':params})
for line in sys.stdin:
 r=json.loads(line)
 with open(os.environ['TD_GOAL_LOG'],'a') as f: print(json.dumps(r),file=f)
 m=r.get('method'); p=r.get('params',{})
 if m=='initialize': out({'id':r['id'],'result':{}})
 elif m=='thread/start': out({'id':r['id'],'result':{'thread':{'id':'session'}}})
 elif m=='skills/list': out({'id':r['id'],'result':{'data':[]}})
 elif m=='turn/start':
  out({'id':r['id'],'result':{'turn':{'id':'client'}}})
  notice('turn/started',{'threadId':'session','turn':{'id':'client','status':'inProgress'}})
  notice('item/completed',{'threadId':'session','turnId':'client','item':{'id':'client-answer','type':'agentMessage','text':'Client answer'}})
  notice('turn/completed',{'threadId':'session','turn':{'id':'client','status':'completed'}})
 elif m=='thread/goal/set':
  goals+=1
  out({'id':r['id'],'result':{'goal':{'threadId':'session','status':'active'}}})
  turn='goal' if goals==1 else 'goal-two'
  notice('turn/started',{'threadId':'session','turn':{'id':turn,'status':'inProgress'}})
  if goals==1:
   notice('item/agentMessage/delta',{'threadId':'session','turnId':turn,'itemId':'goal-answer','delta':'Provider is working'})
   out({'id':101,'method':'item/fileChange/requestApproval','params':{'threadId':'session','turnId':turn,'itemId':'edit','reason':'A provider goal proposes an edit'}})
  else:
   notice('item/completed',{'threadId':'session','turnId':turn,'item':{'id':'second-answer','type':'agentMessage','text':'Second provider answer'}})
   notice('turn/completed',{'threadId':'session','turn':{'id':turn,'status':'completed'}})
 elif r.get('id')==101 and 'result' in r:
  notice('item/completed',{'threadId':'session','turnId':'goal','item':{'id':'goal-answer','type':'agentMessage','text':'Provider answer after permission'}})
 elif m=='turn/interrupt':
  out({'id':r['id'],'result':{}})
  notice('turn/completed',{'threadId':'session','turn':{'id':p['turnId'],'status':'interrupted'}})
  notice('turn/started',{'threadId':'session','turn':{'id':p['turnId'],'status':'inProgress'}})
  notice('turn/started',{'threadId':'foreign','turn':{'id':'unowned','status':'inProgress'}})
 elif m=='thread/goal/get': out({'id':r['id'],'result':{'goal':None}})
"""#

    func testRealPipeProviderTurnOwnsBusyPermissionsOutputStopAndCompletionWithoutFakeUser() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("td-provider-goal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("requests.jsonl")
        let store = try BackendHootChatStore(file: directory.appendingPathComponent("chat.json"), provider: .codex)
        do {
            try await store.attach(.init(command: "/usr/bin/python3", arguments: ["-u", "-c", fixture], cwd: directory.path,
                environment: ["TD_GOAL_LOG": log.path], setup: .init(cwd: directory.path)))
            try await store.initialize()
            _ = try await store.say("Only real user message")
            try await until { await store.isBusy == false }
            _ = try await store.providerRequest(method: "thread/goal/set", params: .object([.init("threadId", .string("session")), .init("objective", .string("Fixture goal"))]))
            try await until { await store.snapshot()["pending"].elements?.count == 1 }
            let waiting = await store.snapshot(limit: 500)
            XCTAssertEqual(waiting["busy"].bool, true)
            let active = await store.activeTurnID
            XCTAssertEqual(active, "provider:goal")
            let permission = try XCTUnwrap(waiting["pending"].elements?.first?["requestId"].string)
            try await store.answer(id: permission, allowed: true)
            try await until { await store.snapshot()["events"].elements?.contains { $0["value"]["text"].string == "Provider answer after permission" } == true }
            try await store.interrupt()
            try await until { await store.isBusy == false }
            let stopped = await store.snapshot(limit: 500)
            XCTAssertEqual(stopped["alive"].bool, true)
            XCTAssertEqual(stopped["events"].elements?.filter { $0["value"]["providerTurnStarted"].fields != nil }.count, 1)
            _ = try await store.providerRequest(method: "thread/goal/set", params: .object([.init("threadId", .string("session")), .init("status", .string("active"))]))
            try await until { await store.snapshot()["events"].elements?.contains { $0["turnId"].string == "provider:goal-two" && $0["kind"].string == "completed" } == true }
            let done = await store.snapshot(limit: 500)
            XCTAssertEqual(done["busy"].bool, false)
            XCTAssertEqual(done["events"].elements?.filter { $0["kind"].string == "user" }.count, 1)
            let turn = BackendSessionChats.turn(of: done)
            XCTAssertEqual(turn.turnID, "provider:goal-two")
            XCTAssertEqual(turn.state, .done(answer: "Second provider answer"))
            await store.stop()
            let requests = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map { try json(String($0)) }
            XCTAssertEqual(requests.filter { $0["method"].string == "turn/start" }.count, 1)
            let stop = try XCTUnwrap(requests.first { $0["method"].string == "turn/interrupt" })
            XCTAssertEqual(stop["params"]["threadId"].string, "session")
            XCTAssertEqual(stop["params"]["turnId"].string, "goal")
            XCTAssertEqual(requests.first { $0["id"].number == 101 }?["result"]["decision"].string, "accept")
        } catch { await store.stop(); throw error }
    }

    func testOneShotJobsCannotSetEditOrResumeProviderGoals() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("td-job-goals-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fixture.py"), log = directory.appendingPathComponent("requests.jsonl")
        try Data(fixture.utf8).write(to: script)
        let environment = ["PATH": "/usr/bin:/bin", "TD_GOAL_LOG": log.path]
        let manager = BackendPTYManager(inheritedEnvironment: environment, onEvent: { _ in })
        let chats = BackendSessionChats(manager: manager, directory: directory.appendingPathComponent("chats"), publish: { _, _ in })
        var input = BackendCreateSessionInput(cwd: directory.path, provider: "codex"); input.chat = true
        input.teamJob = .init(fromID: "from", fromName: "From", agentID: "agent", agentName: "Agent", title: "One-shot fixture")
        let spawn = BackendSpawnSpec(provider: "codex", command: "/usr/bin/python3", args: ["-u", script.path], path: "/usr/bin:/bin")
        var launch = try BackendHOSTProtocol.Launch(id: UUID().uuidString.lowercased(), input: input, spawn: spawn, inheritedEnvironment: environment)
        launch.preparedChat = true; launch.chatSetup = .init(cwd: directory.path)
        let meta = try await chats.launch(input, spawn: spawn, hostLaunch: launch)
        do {
            for operation in ["goals/set", "goals/edit", "goals/resume"] {
                do {
                    _ = try await chats.providerFeature(meta.id, operation: operation, arguments: .object([.init("objective", .string("Must not schedule"))]))
                    XCTFail("A one-shot job was allowed to schedule a provider goal")
                } catch let error as NativeRPCError { XCTAssertEqual(error.code, "unsupported-job-feature") }
            }
            _ = try await chats.providerFeature(meta.id, operation: "goals/read")
            await chats.close(meta.id)
        } catch { await chats.close(meta.id); throw error }
        let requests = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map { try json(String($0)) }
        XCTAssertFalse(requests.contains { $0["method"].string == "thread/goal/set" })
        XCTAssertTrue(requests.contains { $0["method"].string == "thread/goal/get" })
    }

    private func until(_ check: () async -> Bool) async throws {
        for _ in 0..<200 { if await check() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw NativeRPCError(code: "test-timeout", message: "The autonomous-turn fixture did not reach the expected state.")
    }
}
