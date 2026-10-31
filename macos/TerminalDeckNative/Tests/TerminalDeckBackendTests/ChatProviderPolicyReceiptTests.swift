import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class ChatProviderPolicyReceiptTests: XCTestCase, @unchecked Sendable {
    private let fixture = #"""
import json,sys,os
provider=os.environ.get('TD_POLICY_PROVIDER','codex')
root=os.environ['TD_POLICY_ROOT']
def out(v): print(json.dumps(v),flush=True)
def policy(mode='readOnly'):
 return {'thread':{'id':'session'},'cwd':root,'sandbox':{'type':mode,'networkAccess':mode=='workspaceWrite','writableRoots':[root]},'approvalPolicy':'on-request','runtimeWorkspaceRoots':[root],'activePermissionProfile':{'id':mode},'config':{'secret':'SECRET_CONFIG'}}
with open(root+'/requests.jsonl','a') as f: print(json.dumps({'fixtureStarted':os.getpid()}),file=f)
for line in sys.stdin:
 r=json.loads(line)
 with open(root+'/requests.jsonl','a') as f: print(json.dumps(r),file=f)
 if provider=='claude':
  if r.get('type')=='control_request':
   request=r.get('request',{})
   if request.get('subtype')=='initialize':
    out({'type':'control_response','response':{'subtype':'success','request_id':r['request_id'],'response':{'permissionMode':'bypassPermissions'}}})
    out({'type':'system','subtype':'init','session_id':'session','permissionMode':'plan'})
   elif request.get('subtype')=='set_permission_mode':
    result={} if request.get('mode')=='default' else {'mode':request['mode']}
    out({'type':'control_response','response':{'subtype':'success','request_id':r['request_id'],'response':result}})
  continue
 m=r.get('method'); p=r.get('params',{})
 if m=='initialize': out({'id':r['id'],'result':{}})
 elif m=='thread/start': out({'id':r['id'],'result':policy()})
 elif m=='thread/resume': out({'id':r['id'],'result':policy('workspaceWrite' if p.get('sandbox')=='workspace-write' else 'readOnly')})
 elif m=='skills/list':
  out({'id':r['id'],'result':{'data':[]}})
  if os.environ.get('TD_POLICY_EXIT')=='1': break
 elif m=='turn/start':
  out({'id':r['id'],'result':{'turn':{'id':'client'}}})
  out({'method':'turn/started','params':{'threadId':'session','turn':{'id':'client','status':'inProgress'}}})
 elif m=='turn/interrupt':
  out({'id':r['id'],'result':{}})
  out({'method':'turn/completed','params':{'threadId':'session','turn':{'id':'client','status':'interrupted'}}})
"""#
    private func directory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("td-policy-receipt-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true); return value
    }
    private func launch(_ root: URL, provider: String) -> BackendHootChatLaunch {
        .init(command: "/usr/bin/python3", arguments: ["-u", "-c", fixture], cwd: root.path,
              environment: ["TD_POLICY_PROVIDER": provider, "TD_POLICY_ROOT": root.path],
              setup: .init(cwd: root.path, session: .object([.init("sandbox", .string("danger-full-access")), .init("approvalPolicy", .string("never"))])))
    }

    func testOnlyMatchedStartupResponseBecomesEffectivePolicy() throws {
        var rpc = BackendHootChatRPC(provider: .codex, setup: .init(cwd: "/project", session: .object([.init("sandbox", .string("danger-full-access"))])))
        let hello = try rpc.begin(id: "hello", resume: "session")
        let start = try rpc.receive(.object([.init("id", hello["id"]), .init("result", .object([]))])).send.last!
        let result = try NativeRPCValue.parseJSON(Data(#"{"thread":{"id":"session"},"sandbox":{"type":"readOnly","networkAccess":false},"approvalPolicy":"on-request"}"#.utf8))
        let update = try rpc.receive(.object([.init("id", start["id"]), .init("result", result)]))
        let policy = try XCTUnwrap(update.records.first { $0.value["effectivePolicy"].fields != nil }?.value["effectivePolicy"])
        XCTAssertEqual(policy["sandbox"]["type"].string, "readOnly")
        XCTAssertEqual(policy["approval"].string, "on-request")
        XCTAssertEqual(policy["providerConversationId"].string, "session")
        XCTAssertEqual(policy["source"].string, "thread/resume")
        XCTAssertEqual(policy["network"]["enabled"].bool, false)
        XCTAssertTrue(policy["workspaceTrust"].isNullish)
    }

    func testActualPolicyChangesAreRecordedAndInvalidatedWithoutRestoringHistoricalClaims() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("chat.json")
        let store = try BackendHootChatStore(file: file, provider: .codex)
        do {
            try await store.attach(launch(root, provider: "codex")); try await store.initialize()
            let initial = await store.effectiveProviderPolicy
            XCTAssertEqual(initial["sandbox"]["type"].string, "readOnly")
            XCTAssertEqual(initial["approval"].string, "on-request")
            XCTAssertFalse(initial.compact.contains("SECRET_CONFIG"))
            _ = try await store.providerRequest(method: "thread/resume", params: .object([.init("threadId", .string("session")), .init("sandbox", .string("workspace-write"))]))
            let changed = await store.snapshot(limit: 500)
            XCTAssertEqual(changed["effectivePolicy"]["sandbox"]["type"].string, "workspaceWrite")
            XCTAssertEqual(changed["effectivePolicy"]["network"]["enabled"].bool, true)
            XCTAssertEqual(changed["effectivePolicy"]["source"].string, "thread/resume")
            let historicalBytes = try Data(contentsOf: file)
            _ = try await store.say("Hold the normal client turn")
            do {
                _ = try await store.providerRequest(method: "thread/resume", params: .object([.init("threadId", .string("session")), .init("sandbox", .string("read-only"))]))
                XCTFail("A busy provider policy was reconfigured")
            } catch { }
            await store.stop()
            let stopped = await store.snapshot(limit: 500)
            XCTAssertTrue(stopped["effectivePolicy"].isNullish)
            let clear = stopped["events"].elements?.last { $0["value"]["effectivePolicy"].fields != nil }?["value"]["effectivePolicy"]
            XCTAssertEqual(clear?["source"].string, "provider-policy-not-current")
            XCTAssertTrue(clear?["sandbox"].isNullish == true)
            let historical = root.appendingPathComponent("historical.json")
            try historicalBytes.write(to: historical)
            let reopened = try BackendHootChatStore(file: historical, provider: .codex)
            let snapshot = await reopened.snapshot()
            XCTAssertTrue(snapshot["effectivePolicy"].isNullish, "A historical receipt must not establish a new process's boundary")
            let calls = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n").map { try NativeRPCValue.parseJSON(Data($0.utf8)) }
            XCTAssertEqual(calls.filter { $0["method"].string == "thread/resume" }.count, 1)
        } catch { await store.stop(); throw error }
    }

    func testClaudeExplicitModeReplyIsEvidenceButEmptyAcknowledgementClearsOldClaim() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try BackendHootChatStore(file: root.appendingPathComponent("chat.json"), provider: .claude)
        do {
            try await store.attach(launch(root, provider: "claude")); try await store.initialize()
            try await until { await store.effectiveProviderPolicy["approval"].string == "plan" }
            let initial = await store.effectiveProviderPolicy
            XCTAssertEqual(initial["source"].string, "system/init")
            XCTAssertTrue(initial["sandbox"].isNullish)
            _ = try await store.providerRequest(method: "set_permission_mode", params: .object([.init("mode", .string("acceptEdits"))]))
            let changed = await store.effectiveProviderPolicy
            XCTAssertEqual(changed["approval"].string, "acceptEdits")
            XCTAssertEqual(changed["source"].string, "set_permission_mode")
            _ = try await store.providerRequest(method: "set_permission_mode", params: .object([.init("mode", .string("default"))]))
            let unconfirmed = await store.snapshot(limit: 500)
            XCTAssertTrue(unconfirmed["effectivePolicy"].isNullish)
            XCTAssertEqual(unconfirmed["events"].elements?.last { $0["value"]["effectivePolicy"].fields != nil }?["value"]["effectivePolicy"]["source"].string, "provider-policy-not-current")
            await store.stop()
        } catch { await store.stop(); throw error }
    }

    func testPassiveProviderFeaturesDoNotRestartADeadChat() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("provider")
        try Data(("#!/usr/bin/python3\n" + fixture).utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let environment = ["PATH": "/usr/bin:/bin", "TD_POLICY_ROOT": root.path, "TD_POLICY_EXIT": "1"]
        let manager = BackendPTYManager(inheritedEnvironment: environment, onEvent: { _ in })
        let chats = BackendSessionChats(manager: manager, directory: root.appendingPathComponent("chats"), publish: { _, _ in })
        var input = BackendCreateSessionInput(cwd: root.path, provider: "codex"); input.chat = true
        let meta = try await chats.launch(input, spawn: .init(provider: "codex", command: script.path, args: [], path: "/usr/bin:/bin"))
        do {
            try await until {
                let snapshot = try? await chats.read(meta.id, cursor: nil, limit: 1)
                return snapshot?["alive"].bool == false
            }
            _ = try await chats.providerFeature(meta.id, operation: "capabilities")
            _ = try await chats.providerFeature(meta.id, operation: "children/list")
            let policy = try await chats.providerFeature(meta.id, operation: "policy/read")
            XCTAssertTrue(policy["effectivePolicy"].isNullish)
            for operation in ["catalogue/list", "mcp/status", "goals/read", "policy/change"] {
                do {
                    _ = try await chats.providerFeature(meta.id, operation: operation, arguments: operation == "policy/change" ? .object([.init("sandbox", .string("read-only"))]) : .object([]))
                    XCTFail("A stopped provider was restarted for " + operation)
                } catch let error as NativeRPCError { XCTAssertEqual(error.code, "provider-not-running") }
            }
            await chats.close(meta.id)
        } catch { await chats.close(meta.id); throw error }
        let calls = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n").map { try NativeRPCValue.parseJSON(Data($0.utf8)) }
        XCTAssertEqual(calls.filter { $0["fixtureStarted"].number != nil }.count, 1)
        XCTAssertFalse(calls.contains { $0["method"].string == "thread/resume" })
    }

    private func until(_ check: () async -> Bool) async throws {
        for _ in 0..<200 { if await check() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw NativeRPCError(code: "test-timeout", message: "The provider policy fixture did not reach the expected state.")
    }
}
