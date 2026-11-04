import AppKit
import Darwin
import SwiftUI
import XCTest
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// This runner owns only hidden panels, a private defaults suite, a fixture provider and two local sleep commands.
@MainActor final class ChatControlsScratchTests: XCTestCase {
    private var savedDefaults: UserDefaults!
    private var suite = ""
    override func setUp() async throws {
        suite = "dev.terminaldeck.chat-controls." + UUID().uuidString
        savedDefaults = NativeChatOutbox.defaults
        NativeChatOutbox.defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }
    override func tearDown() async throws {
        NativeChatOutbox.defaults.removePersistentDomain(forName: suite)
        NativeChatOutbox.defaults = savedDefaults
    }
    private var proof: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("design-2026-10-10/built.noindex/chat-controls.noindex")
    }
    private func capture(_ model: NativeHootChatModel, width: CGFloat, dark: Bool, name: String) throws {
        let view = NativeHootChat(model: model).environment(\.agkitOffscreenSolid, true)
            .environment(\.colorScheme, dark ? .dark : .light).frame(width: width, height: 700).background(DeckTokens.chatPage)
        let host = NSHostingView(rootView: view)
        let panel = NativePassiveChatPanel(contentRect: .init(x: -30000, y: -30000, width: width, height: 700),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.prepareForPassiveCapture()
        panel.identifier = .init("dev.terminaldeck.chat-controls.scratch")
        panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        panel.contentView = host
        defer { panel.contentView = nil; panel.close() }
        for _ in 0..<4 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.effectiveAppearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
        try FileManager.default.createDirectory(at: proof, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: proof.appendingPathComponent(name + ".png"))
        XCTAssertEqual(bitmap.pixelsWide, Int(width))
        XCTAssertEqual(bitmap.pixelsHigh, 700)
        XCTAssertFalse(panel.isVisible)
    }
    private func shotAll(_ model: NativeHootChatModel, _ name: String) throws {
        for dark in [false, true] { for width: CGFloat in [420, 1000] {
            try capture(model, width: width, dark: dark, name: name + "-\(Int(width))-" + (dark ? "dark" : "light"))
        } }
    }
    private func wait(_ predicate: () async throws -> Bool) async throws {
        for _ in 0..<200 {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Scratch provider did not reach the expected state")
        throw NativeRPCError(code: "scratch-timeout", message: "Scratch provider did not settle")
    }
    private let provider = #"""
import json,sys,subprocess,os,signal
root=os.environ['CHAT_CONTROLS_ROOT']; tasks={}
def out(x): print(json.dumps(x),flush=True)
def close():
 for p in tasks.values():
  if p.poll() is None: p.terminate(); p.wait()
def ended(*args): close(); sys.exit(0)
signal.signal(signal.SIGTERM,ended)
try:
 for line in sys.stdin:
  r=json.loads(line)
  if r.get('type')=='control_request':
   q=r['request']; action=q.get('subtype')
   if action=='stop_task':
    p=tasks[q['task_id']]; p.terminate(); p.wait()
    out({'type':'system','subtype':'task_notification','task_id':q['task_id'],'status':'stopped'})
   response={'output':'Scratch command '+q['task_id']+' is running'} if action=='get_task_output' else {}
   out({'type':'control_response','response':{'subtype':'success','request_id':r['request_id'],'response':response}})
   if action=='interrupt': out({'type':'result','subtype':'success','stop_reason':'interrupted','session_id':'scratch-provider'})
  elif r.get('type')=='user':
   out({'type':'system','subtype':'init','session_id':'scratch-provider'})
   for id in ['one','two']:
    p=subprocess.Popen(['/bin/sleep','120']); tasks[id]=p
    with open(root+'/'+id+'.pid','w') as f: f.write(str(p.pid))
    out({'type':'system','subtype':'task_started','task_id':id,'task_type':'local_bash','description':'Scratch command '+id+' · sleep 120'})
finally: close()
"""#
    func testScriptedScratchTurnWithTwoCommandsAndIndependentStops() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-chat-controls-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try BackendHootChatStore(file: root.appendingPathComponent("chat.json"), provider: .claude)
        addTeardownBlock { await store.stop(); try? FileManager.default.removeItem(at: root) }
        try await store.attach(.init(command: "/usr/bin/python3", arguments: ["-u", "-c", provider], cwd: root.path,
            environment: ["PATH": "/usr/bin:/bin", "CHAT_CONTROLS_ROOT": root.path]))
        try await store.initialize()
        let model = NativeHootChatModel(fixture: await store.snapshot(), chatInvoke: { channel, args in
            if channel.hasSuffix(":child-stop") { return try await store.stopChild(args[1] as? String ?? "").foundation! }
            if channel.hasSuffix(":provider") {
                let query = try NativeRPCValue.fromFoundation(args[2] ?? [:])
                return try await BackendChatBackground.invoke(operation: args[1] as? String ?? "", args: query, provider: .claude,
                    ownedTasks: await store.snapshot()["children"].elements ?? [], request: { method, params in
                        try await store.providerRequest(method: method, params: params)
                    }).foundation!
            }
            if channel.hasSuffix(":stop") { try await store.interrupt() }
            return await store.snapshot().foundation!
        }, source: .session("scratch-chat-controls", provider: "claude"))
        try shotAll(model, "idle")
        _ = try await store.say("Run two background commands and keep answering.")
        try await wait { await store.snapshot()["children"].elements?.count == 2 }
        model.acceptFixtureUpdate(await store.snapshot())
        XCTAssertTrue(model.answering)
        XCTAssertEqual(model.runningTasks.count, 2)
        try shotAll(model, "running")
        model.composerDraft.text = "Please report each command separately."
        try shotAll(model, "running-typed")
        let open = try await model.featureTool("running", action: "open", args: .object([]))
        XCTAssertEqual(open["count"].number, 2)
        XCTAssertEqual(open["expanded"].bool, true)
        try shotAll(model, "tray-open")
        let output = try await model.featureTool("running", action: "output", args: .object([.init("request", .string("two"))]))
        XCTAssertEqual(output["output"].string, "Scratch command two is running")
        // Same send path as the round Queue button: no interruption or extra provider turn.
        model.send()
        XCTAssertEqual(model.queuedMessages.count, 1)
        XCTAssertTrue(model.composerDraft.text.isEmpty)
        let stopped = try await model.featureTool("running", action: "stop", args: .object([.init("request", .string("one"))]))
        try await wait { await store.snapshot()["children"].elements?.first { $0["id"].string == "one" }?["status"].string == "stopped" }
        model.acceptFixtureUpdate(await store.snapshot())
        XCTAssertEqual(stopped["count"].number, 1)
        XCTAssertTrue(model.answering, "Stopping one background command must leave the answer running")
        func pid(_ id: String) throws -> Int32 { try XCTUnwrap(Int32(String(contentsOf: root.appendingPathComponent(id + ".pid"), encoding: .utf8))) }
        let first = try pid("one"), second = try pid("two")
        XCTAssertEqual(kill(first, 0), -1)
        XCTAssertEqual(kill(second, 0), 0)
        try shotAll(model, "one-task-stopped")
        model.stop()
        try await wait { await store.snapshot()["answering"].bool == false }
        try await wait { !model.stopping }
        model.acceptFixtureUpdate(await store.snapshot())
        XCTAssertFalse(model.answering, "The composer Stop must end the foreground turn")
        XCTAssertEqual(model.runningTasks.count, 1, "The other background command keeps its own lifecycle")
        XCTAssertEqual(kill(second, 0), 0)
        XCTAssertTrue(model.queuedMessages.allSatisfy(\.held), "Stop holds queued messages")
        try shotAll(model, "turn-stopped")
        let log = "Scratch provider; real local sleep commands.\nTwo commands running: PASS\nStop one: first process gone, second alive, answer still running: PASS\nQueue while running: one held message after Stop: PASS\nComposer Stop: answer ended, second background process alive: PASS\n24 full frames: 420/1000 pt, light/dark.\n"
        try Data(log.utf8).write(to: proof.appendingPathComponent("proof.txt"))
    }
    func testTrayHidesWhenEmptyAndMCPRejectsUnknownTask() async throws {
        let snapshot = NativeRPCValue.object([.init("conversationId", .string("empty-scratch")), .init("alive", .bool(true)), .init("busy", .bool(false))])
        let model = NativeHootChatModel(fixture: snapshot, source: .session("empty-scratch", provider: "codex"))
        let state = try await model.featureTool("running", action: "open", args: .object([]))
        XCTAssertEqual(state["count"].number, 0)
        XCTAssertEqual(state["expanded"].bool, false)
        do {
            _ = try await model.featureTool("running", action: "stop", args: .object([.init("request", .string("foreign"))]))
            XCTFail("Unknown task must be rejected")
        } catch { XCTAssertEqual((error as? NativeRPCError)?.code, "invalid-arguments") }
    }
    func testBackgroundOnlyKeepsTrayWithoutInventingAnotherAnswer() async throws {
        let at = Date().timeIntervalSince1970 * 1000 - 5000
        let events = [
            HootChatEvent(conversationID: "background-only", turnID: "turn", sequence: 1, provider: .claude,
                record: .text(.user, "Run two background commands and keep answering."), at: at),
            HootChatEvent(conversationID: "background-only", turnID: "turn", sequence: 2, provider: .claude,
                record: .init(.completed), at: at + 2000)]
        let task = NativeRPCValue.object([.init("id", .string("two")), .init("title", .string("Scratch command two · sleep 120")),
            .init("kind", .string("local_bash")), .init("status", .string("running")), .init("startedAt", .number(at))])
        let snapshot = NativeRPCValue.object([.init("conversationId", .string("background-only")), .init("sequence", .number(2)),
            .init("alive", .bool(true)), .init("busy", .bool(true)), .init("answering", .bool(false)),
            .init("children", .array([task])), .init("events", .array(events.map(\.wireValue)))])
        let model = NativeHootChatModel(fixture: snapshot, source: .session("scratch-background-only", provider: "claude"))
        XCTAssertTrue(model.workingState.active)
        XCTAssertEqual(model.runningTasks.count, 1)
        XCTAssertFalse(model.foregroundAnswerActive)
        XCTAssertTrue(HootChatItem.thinking([], live: model.foregroundAnswerActive).isEmpty)
        _ = try await model.featureTool("running", action: "open", args: .object([]))
        try shotAll(model, "background-only-final")
        let ended = snapshot.setting("sequence", .number(3)).setting("busy", .bool(false)).setting("children", .array([]))
        model.acceptFixtureUpdate(ended)
        XCTAssertFalse(model.workingState.active)
        XCTAssertTrue(model.runningTasks.isEmpty)
    }
}
