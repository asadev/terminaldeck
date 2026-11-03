import Foundation
import Darwin
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class ChatOwnedTerminalLifecycleTests: XCTestCase, @unchecked Sendable {
    // A protocol fixture only: it never executes the requested shell or a model turn.
    private let fixture = #"""
import base64,json,os,signal,sys
root=os.environ['TD_TERMINAL_LIFECYCLE_ROOT']
private=False; execution=None; process=None
def out(v): print(json.dumps(v),flush=True)
def childstate():
 try:
  with open(root+'/private.pid') as f: pid=int(f.read())
  try: os.kill(pid,0); return 'alive'
  except ProcessLookupError: return 'gone'
 except Exception: return 'unknown'
def ended(sig,frame):
 if not private:
  with open(root+'/parent.release','w') as f: f.write(childstate())
 sys.exit(0)
signal.signal(signal.SIGTERM,ended)
def policy():
 return {'thread':{'id':'session'},'cwd':root,'sandbox':{'type':'readOnly','networkAccess':False},'approvalPolicy':'on-request','activePermissionProfile':{'id':':read-only'},'runtimeWorkspaceRoots':[root]}
for line in sys.stdin:
 r=json.loads(line); m=r.get('method'); p=r.get('params',{})
 if m=='initialize':
  private=p.get('clientInfo',{}).get('name')=='terminaldeck-owned-terminal'
  if private:
   with open(root+'/private.pid','w') as f: f.write(str(os.getpid()))
   if os.environ.get('TD_TERMINAL_HOLD_INIT')=='1': continue
  out({'id':r['id'],'result':{}})
 elif m=='thread/start': out({'id':r['id'],'result':policy()})
 elif m=='thread/resume':
  with open(root+'/policy.release','w') as f: f.write(childstate())
  out({'id':r['id'],'result':policy()})
 elif m=='skills/list': out({'id':r['id'],'result':{'data':[]}})
 elif m=='command/exec':
  execution=r['id']; process=p['processId']
  out({'method':'command/exec/outputDelta','params':{'processId':process,'deltaBase64':base64.b64encode(b'ready').decode(),'stream':'stdout','capReached':False}})
 elif m=='command/exec/terminate':
  out({'id':r['id'],'result':{}})
  if execution: out({'id':execution,'result':{'exitCode':0,'stdout':'','stderr':''}})
"""#

    private func wait(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<250 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NativeRPCError(code: "test-timeout", message: "Owned terminal lifecycle fixture did not settle")
    }
    private func directory() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("td-owned-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func start(_ root: URL, hold: Bool) async throws -> BackendHootChatStore {
        let store = try BackendHootChatStore(file: root.appendingPathComponent("chat.json"), provider: .codex)
        addTeardownBlock { await store.stop() }
        try await store.attach(.init(command: "/usr/bin/python3", arguments: ["-u", "-c", fixture], cwd: root.path,
            environment: ["TD_TERMINAL_LIFECYCLE_ROOT": root.path, "TD_TERMINAL_HOLD_INIT": hold ? "1" : "0"], setup: .init(cwd: root.path)))
        try await store.initialize()
        return store
    }
    private func permit(_ store: BackendHootChatStore) async throws -> BackendChatOwnedTerminals.AppApproval {
        let caps = try await store.ownedTerminalFeature(sessionID: "app-chat", operation: "capabilities", arguments: .object([]), approval: nil)
        return try .mint(sessionID: "app-chat", scopeID: XCTUnwrap(caps["scopeID"].string), operation: "create", arguments: .object([]), origin: .nativeUser)
    }

    func testParentStopAndPolicyChangeReapPrivatePipeBeforeReleasingOwner() async throws {
        for action in ["stop-running", "stop-initializing", "policy-change"] {
            let root = try directory(), hold = action == "stop-initializing"
            let store = try await start(root, hold: hold), approval = try await permit(store)
            let opening = Task { try await store.ownedTerminalFeature(sessionID: "app-chat", operation: "create", arguments: .object([]), approval: approval) }
            let pidfile = root.appendingPathComponent("private.pid")
            try await wait { FileManager.default.fileExists(atPath: pidfile.path) }
            let privatePID = try XCTUnwrap(Int32(try String(contentsOf: pidfile, encoding: .utf8)))
            if !hold { _ = try await opening.value }
            try await wait { await store.snapshot()["ownedTerminalWriters"].number == 1 }
            if action == "policy-change" {
                _ = try await store.providerRequest(method: "thread/resume", params: .object([.init("threadId", .string("session"))]))
                XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("policy.release"), encoding: .utf8), "gone")
                let newApproval = try await permit(store)
                XCTAssertNotEqual(newApproval.scopeID, approval.scopeID)
                do {
                    _ = try await store.ownedTerminalFeature(sessionID: "app-chat", operation: "create", arguments: .object([]), approval: approval)
                    XCTFail("Pre-policy consent crossed the new execution scope")
                } catch { }
            }
            await store.stop()
            if hold { do { _ = try await opening.value; XCTFail("A stopped pending private pipe attached") } catch { } }
            let result = kill(privatePID, 0), errorNumber = errno
            XCTAssertEqual(result, -1, action); XCTAssertEqual(errorNumber, ESRCH, action)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("parent.release"), encoding: .utf8), "gone", action)
            let snapshot = await store.snapshot()
            XCTAssertEqual(snapshot["ownedTerminalWriters"].number, 0)
            XCTAssertGreaterThan(snapshot["ownedTerminalCursor"].number ?? 0, 0)
            XCTAssertFalse(snapshot.compact.contains("activePermissionProfileReported"), "Backend execution evidence leaked into the public snapshot")
        }
    }

    /// Review chat-backend #6: closed terminals must not use up the Chat's terminal limit.
    func testClosingTerminalsDoesNotUseUpTheChatsTerminalLimit() async throws {
        let root = try directory()
        let store = try await start(root, hold: false)
        let caps = try await store.ownedTerminalFeature(sessionID: "app-chat", operation: "capabilities", arguments: .object([]), approval: nil)
        let scopeID = try XCTUnwrap(caps["scopeID"].string)
        for round in 0..<20 {
            let create = try BackendChatOwnedTerminals.AppApproval.mint(sessionID: "app-chat", scopeID: scopeID, operation: "create", arguments: .object([]), origin: .nativeUser)
            let made = try await store.ownedTerminalFeature(sessionID: "app-chat", operation: "create", arguments: .object([]), approval: create)
            let handle = try XCTUnwrap(made["handle"].string, "round \(round)")
            let args = NativeRPCValue.object([.init("handle", .string(handle))])
            let stop = try BackendChatOwnedTerminals.AppApproval.mint(sessionID: "app-chat", scopeID: scopeID, operation: "close", arguments: args, origin: .nativeUser)
            _ = try await store.ownedTerminalFeature(sessionID: "app-chat", operation: "close", arguments: args, approval: stop)
        }
        let list = try await store.ownedTerminalFeature(sessionID: "app-chat", operation: "list", arguments: .object([]), approval: nil)
        XCTAssertLessThanOrEqual(list["terminals"].elements?.count ?? 99, BackendChatOwnedTerminals.finishedKept + 1)
    }

    func testOldHelperRefusesTerminalDoorAndRemainsRunning() async throws {
        let root = try directory(), paths = try BackendHOSTPaths(dataDirectory: root)
        _ = try paths.secret(create: true)
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        let server = try BackendHOSTServer(paths: paths, hostVersion: "old-fixture", manager: manager,
            launch: { _ in throw BackendHOSTFailure.unavailable }, snapshot: { _ in nil }, onIdle: {})
        defer { server.stopListening(); manager.beginShutdown() }
        let client = try BackendHOSTClient(paths: paths)
        defer { client.detach() }
        XCTAssertNil(client.hello.chatOwnedTerminals)
        let owner = BackendHOSTChatClient(client: client)
        do {
            _ = try await owner.call("terminal", id: "app-chat", fields: [.init("operation", .string("capabilities"))])
            XCTFail("Old helper accepted terminal operations")
        } catch let error as NativeRPCError { XCTAssertEqual(error.code, "helper-upgrade-required") }
        let replacement = try BackendHOSTClient(paths: paths)
        defer { replacement.detach() }
        XCTAssertEqual(replacement.hello.instance, client.hello.instance, "Refusal restarted the helper")
    }
}
