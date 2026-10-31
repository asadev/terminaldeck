import Foundation
import Darwin
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class ChatProviderSideLifecycleTests: XCTestCase, @unchecked Sendable {
    /// The parent answers its handshake. Its separate side child deliberately stalls at
    /// initialization, before a BackendChatSideConversation can be installed on the Live item.
    private let fixture = #"""
import json,os,signal,sys
root=os.environ['TD_SIDE_LIFECYCLE_ROOT']
side='--disable' in sys.argv
def ended(sig,frame):
 if not side:
  try:
   with open(root+'/side.pid') as f: pid=int(f.read())
   try: os.kill(pid,0); state='alive'
   except ProcessLookupError: state='gone'
  except Exception: state='unknown'
  with open(root+'/parent.release','w') as f: f.write(state)
 sys.exit(0)
signal.signal(signal.SIGTERM,ended)
if side:
 with open(root+'/side.pid','w') as f: f.write(str(os.getpid()))
 with open(root+'/side.pids','a') as f: f.write(str(os.getpid())+'\n')
for line in sys.stdin:
 request=json.loads(line)
 if side: continue
 method=request.get('method')
 if method=='initialize': result={}
 elif method=='thread/start': result={'thread':{'id':'parent'}}
 elif method=='skills/list': result={'data':[]}
 else: continue
 print(json.dumps({'id':request['id'],'result':result}),flush=True)
"""#

    func testChatProviderPendingSideFactoryIsReapedBeforeSideCloseSessionCloseAndQuitReturn() async throws {
        for action in ["side-close", "session-close", "quit"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("td-side-lifecycle-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let script = directory.appendingPathComponent("provider.py")
            try Data(fixture.utf8).write(to: script)
            let environment = ["PATH": "/usr/bin:/bin", "TD_SIDE_LIFECYCLE_ROOT": directory.path]
            let manager = BackendPTYManager(inheritedEnvironment: environment, onEvent: { _ in })
            let chats = BackendSessionChats(manager: manager, directory: directory.appendingPathComponent("chats"), publish: { _, _ in })
            var input = BackendCreateSessionInput(cwd: directory.path, provider: "codex"); input.chat = true
            let spawn = BackendSpawnSpec(provider: "codex", command: "/usr/bin/python3", args: ["-u", script.path], path: "/usr/bin:/bin")
            var launch = try BackendHOSTProtocol.Launch(id: UUID().uuidString.lowercased(), input: input, spawn: spawn,
                                                        inheritedEnvironment: environment)
            launch.preparedChat = true; launch.chatSetup = .init(cwd: directory.path)
            let meta = try await chats.launch(input, spawn: spawn, hostLaunch: launch)
            let opening = Task { try await chats.providerFeature(meta.id, operation: "side/open") }
            let pidfile = directory.appendingPathComponent("side.pid")
            var pid: Int32?
            for _ in 0..<200 {
                pid = (try? String(contentsOf: pidfile, encoding: .utf8)).flatMap(Int32.init)
                if pid != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard let pid else {
                opening.cancel(); await chats.close(meta.id)
                XCTFail("Side fixture failed to start for " + action); continue
            }
            if action == "side-close" {
                _ = try await chats.providerFeature(meta.id, operation: "side/close")
                let parent = try await chats.read(meta.id, cursor: nil, limit: 1)
                XCTAssertEqual(parent["alive"].bool, true, "Side close stopped its parent")
            } else if action == "session-close" { await chats.close(meta.id) }
            else { await chats.endAllForQuit() }
            let killResult = kill(pid, 0), errorNumber = errno
            XCTAssertEqual(killResult, -1, "A pending side child survived " + action)
            XCTAssertEqual(errorNumber, ESRCH)
            do { _ = try await opening.value; XCTFail("Cancelled side factory attached after " + action) } catch { }
            if action == "side-close" { await chats.close(meta.id) }
            XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("parent.release"), encoding: .utf8), "gone",
                           "Parent resources were released while the side child was alive")
            await chats.close(meta.id)
        }
    }

    /// Review chat-backend #2: two side/open calls at once must start exactly one side child.
    func testChatProviderDoubleSideOpenStartsOnlyOneChild() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("td-side-double-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("provider.py")
        try Data(fixture.utf8).write(to: script)
        let environment = ["PATH": "/usr/bin:/bin", "TD_SIDE_LIFECYCLE_ROOT": directory.path]
        let manager = BackendPTYManager(inheritedEnvironment: environment, onEvent: { _ in })
        let chats = BackendSessionChats(manager: manager, directory: directory.appendingPathComponent("chats"), publish: { _, _ in })
        var input = BackendCreateSessionInput(cwd: directory.path, provider: "codex"); input.chat = true
        let spawn = BackendSpawnSpec(provider: "codex", command: "/usr/bin/python3", args: ["-u", script.path], path: "/usr/bin:/bin")
        var launch = try BackendHOSTProtocol.Launch(id: UUID().uuidString.lowercased(), input: input, spawn: spawn, inheritedEnvironment: environment)
        launch.preparedChat = true; launch.chatSetup = .init(cwd: directory.path)
        let meta = try await chats.launch(input, spawn: spawn, hostLaunch: launch)
        let first = Task { try await chats.providerFeature(meta.id, operation: "side/open") }
        let second = Task { try await chats.providerFeature(meta.id, operation: "side/open") }
        let pids = directory.appendingPathComponent("side.pids")
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: pids.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(700))
        let started = ((try? String(contentsOf: pids, encoding: .utf8)) ?? "").split(separator: "\n").count
        XCTAssertEqual(started, 1, "A double side/open started \(started) side children")
        first.cancel(); second.cancel()
        await chats.close(meta.id)
    }
}
