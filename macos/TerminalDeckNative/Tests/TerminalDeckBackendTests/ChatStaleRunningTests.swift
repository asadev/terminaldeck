import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// 9 Nov (Asad, iMatch chat: "Working · running a background task · 1 running" for two days, its AI process with no
/// child at all). Claude Code writes a background task's finish only at the chat's next turn, so an idle chat never
/// records it. A scratch Claude Code that never sends a finish notice: the record follows the real processes.
final class ChatStaleRunningTests: XCTestCase, @unchecked Sendable {
    private static let provider = #"""
import json,sys,os,subprocess
def out(v): print(json.dumps(v),flush=True)
mode=os.environ['STALE_MODE']
for line in sys.stdin:
 r=json.loads(line)
 if r.get('type')=='control_request':
  if r.get('request',{}).get('subtype')=='initialize': out({'type':'control_response','response':{'subtype':'success','request_id':r['request_id'],'response':{}}})
  continue
 out({'type':'system','subtype':'init','session_id':'stale-0609'})
 if mode in ('alive','ends'):
  out({'type':'assistant','session_id':'stale-0609','message':{'id':'call','content':[{'type':'tool_use','id':'tool-bg','name':'Bash','input':{'command':'sleep','run_in_background':True}}]}})
  p=subprocess.Popen(['/bin/sleep','30' if mode=='alive' else '0.4'],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  open('bg.pid','w').write(str(p.pid))
  out({'type':'system','subtype':'task_started','task_id':'bg-1','tool_use_id':'tool-bg','description':'sleep','task_type':'local_bash'})
  out({'type':'user','session_id':'stale-0609','message':{'content':[{'type':'tool_result','tool_use_id':'tool-bg','content':'Command running in background with ID: bg-1'}]}})
 if mode=='agent':
  out({'type':'system','subtype':'task_started','task_id':'agent-1','description':'Background helper','task_type':'local_agent'})
 out({'type':'assistant','session_id':'stale-0609','message':{'id':'answer','content':[{'type':'text','text':'Started it.'}]}})
 out({'type':'result','subtype':'success','is_error':False,'session_id':'stale-0609','stop_reason':'end_turn'})
"""#
    private func launch(_ root: URL, mode: String) -> BackendHootChatLaunch {
        .init(command: "/usr/bin/python3", arguments: ["-u", "-c", Self.provider], cwd: root.path,
              environment: ["PATH": "/usr/bin:/bin", "STALE_MODE": mode])
    }
    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().appendingPathComponent("stale-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func until(_ seconds: Double = 8, _ check: () async throws -> Bool) async throws -> Bool {
        let end = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < end { if try await check() { return true }; try await Task.sleep(for: .milliseconds(25)) }
        return false
    }
    private func task(_ store: BackendHootChatStore, _ id: String) async -> NativeRPCValue? {
        await store.snapshot(limit: 500)["children"].elements?.first { $0["id"].string == id }
    }
    private func completed(_ store: BackendHootChatStore) async -> Bool {
        await store.snapshot(limit: 500)["events"].elements?.contains { $0["kind"].string == "completed" } == true
    }
    /// Only the scratch provider's own sleep, started by this test, is ever signalled.
    private func endOwnSleep(_ root: URL) {
        if let text = try? String(contentsOf: root.appendingPathComponent("bg.pid"), encoding: .utf8), let pid = Int32(text), pid > 1 { kill(pid, SIGKILL) }
    }

    /// (a) A background shell that is still alive shows running after the answer ended, and the chat says why.
    func testABackgroundShellThatIsStillAliveShowsRunning() async throws {
        let root = try scratch()
        let store = try BackendHootChatStore(file: root.appendingPathComponent("chat.json"))
        addTeardownBlock { await store.stop(); self.endOwnSleep(root); try? FileManager.default.removeItem(at: root) }
        try await store.attach(launch(root, mode: "alive")); try await store.initialize()
        _ = try await store.say("Run a background command")
        let answered = try await until { await self.completed(store) }
        XCTAssertTrue(answered)
        await store.processesChanged()
        let status = await task(store, "bg-1")?["status"].string
        let snapshot = await store.snapshot(limit: 500)
        XCTAssertEqual(status, "running")
        let working = ChatWorkingState.read(snapshot)
        XCTAssertTrue(working.active)
        XCTAssertEqual(working.detail, "running a background task")
        XCTAssertEqual(snapshot["foreground"].bool, false, "the answer itself has ended")
    }

    /// (b) Its process ends and the AI never writes a finish: the task shows finished anyway, and the history keeps it.
    func testABackgroundShellWhoseProcessHasGoneShowsFinishedWithoutAFinishNotice() async throws {
        let root = try scratch()
        let store = try BackendHootChatStore(file: root.appendingPathComponent("chat.json"))
        addTeardownBlock { await store.stop(); try? FileManager.default.removeItem(at: root) }
        try await store.attach(launch(root, mode: "ends")); try await store.initialize()
        _ = try await store.say("Run a short background command")
        let answered = try await until { await self.completed(store) }
        XCTAssertTrue(answered)
        let finished = try await until { await self.task(store, "bg-1")?["status"].string == "completed" }
        XCTAssertTrue(finished, "the shell's own exit closes the record")
        let row = await task(store, "bg-1")
        XCTAssertEqual(row?["endedBy"].string, "process-gone")
        XCTAssertEqual(row?["title"].string, "sleep", "the history row is kept, now finished")
        let snapshot = await store.snapshot(limit: 500)
        XCTAssertEqual(snapshot["busy"].bool, false)
        XCTAssertFalse(ChatWorkingState.isActive(snapshot))
    }

    /// (c) His case: an idle chat whose AI process has no child shows no "Working", even for a task the AI started
    /// under an earlier process (here an in-process background agent) and never reported finished.
    func testAnIdleChatShowsNoWorkingForATaskItsAIProcessNoLongerRuns() async throws {
        let root = try scratch()
        let file = root.appendingPathComponent("chat.json")
        let first = try BackendHootChatStore(file: file)
        addTeardownBlock { await first.stop(); try? FileManager.default.removeItem(at: root) }
        try await first.attach(launch(root, mode: "agent")); try await first.initialize()
        _ = try await first.say("Start a background helper")
        let answered = try await until { await self.completed(first) }
        XCTAssertTrue(answered)
        let live = await task(first, "agent-1")?["status"].string
        XCTAssertEqual(live, "running", "an in-process agent of the live AI is not judged by children")
        await first.stop()
        let reopened = try BackendHootChatStore(file: file)
        addTeardownBlock { await reopened.stop() }
        let saved = await reopened.snapshot(limit: 500)
        XCTAssertTrue(ChatWorkingState.read(saved.setting("alive", .bool(true))).active, "before: the saved record alone still says running")
        try await reopened.attach(launch(root, mode: "quiet")); try await reopened.initialize()
        let finished = try await until { await self.task(reopened, "agent-1")?["status"].string == "completed" }
        XCTAssertTrue(finished)
        let snapshot = await reopened.snapshot(limit: 500)
        XCTAssertEqual(ChatWorkingState.read(snapshot), .idle)
        XCTAssertFalse(ChatWorkingState.isActive(snapshot))
        XCTAssertEqual(snapshot["busy"].bool, false)
    }
}
