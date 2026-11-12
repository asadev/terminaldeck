import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class HootStuckTests: XCTestCase, @unchecked Sendable {
    private static let provider = #"""
import json,sys,os,queue,threading,subprocess
lines=queue.Queue()
def read():
 for line in sys.stdin: lines.put(line)
 lines.put(None)
threading.Thread(target=read,daemon=True).start()
n=0
waiting=False
def out(v): print(json.dumps(v),flush=True)
def finish():
 out({'type':'assistant','session_id':'scratch-hoot','message':{'id':'answer-'+str(n),'content':[{'type':'text','text':'Finished answer '+str(n)}]}})
 out({'type':'result','subtype':'success','is_error':False,'session_id':'scratch-hoot','stop_reason':'end_turn'})
while True:
 if waiting and os.path.exists('release'):
  waiting=False
  finish()
 try: line=lines.get(timeout=0.02)
 except queue.Empty: continue
 if line is None: break
 r=json.loads(line)
 if r.get('type')=='control_request':
  subtype=r.get('request',{}).get('subtype')
  if subtype=='initialize': out({'type':'control_response','response':{'subtype':'success','request_id':r['request_id'],'response':{}}})
  if subtype=='interrupt':
   open('interrupted','w').close()
   waiting=False
   finish()
  continue
 n+=1
 with open('inputs.jsonl','a') as f: f.write(json.dumps(r)+'\n')
 out({'type':'system','subtype':'init','session_id':'scratch-hoot'})
 out({'type':'system','subtype':'session_state_changed','state':'running'})
 if n==1:
  # A real background watcher process (9 Nov): a task with no live process is shown finished.
  subprocess.Popen(['/bin/sleep','20'],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  out({'type':'system','subtype':'task_started','task_id':'disk-watch','description':'Scratch background watcher','task_type':'local_bash'})
 if n==1 and not os.path.exists('release'): waiting=True
 else: finish()
"""#
    private struct Fixture: Sendable {
        let root: URL
        let store: BackendHootChatStore
        var launch: BackendHootChatLaunch { .init(command: "/usr/bin/python3", arguments: ["-u", "-c", HootStuckTests.provider], cwd: root.path, environment: [:]) }
        func release() throws { try Data().write(to: root.appendingPathComponent("release")) }
        func inputs() throws -> [NativeRPCValue] {
            let file = root.appendingPathComponent("inputs.jsonl")
            guard FileManager.default.fileExists(atPath: file.path) else { return [] }
            return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map { try .parseJSON(Data($0.utf8)) }
        }
        func close() async { await store.stop(); try? FileManager.default.removeItem(at: root) }
    }
    private func fixture(released: Bool = false) async throws -> Fixture {
        let root = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().appendingPathComponent("hs-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try BackendHootChatStore(file: root.appendingPathComponent("chat.json"))
        let f = Fixture(root: root, store: store)
        if released { try f.release() }
        try await store.attach(f.launch); try await store.initialize()
        return f
    }
    private func until(_ check: () async throws -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < end {
            if try await check() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Scratch provider did not reach the requested state")
        throw NativeRPCError(code: "test-timeout", message: "Scratch provider did not finish")
    }
    private func completed(_ store: BackendHootChatStore, count: Int) async -> Bool {
        await store.snapshot(limit: 500)["events"].elements?.filter { $0["kind"].string == "completed" }.count == count
    }

    private actor PreparingGate {
        var entered = false
        private var released = false
        private var waiter: CheckedContinuation<Void, Never>?
        func wait() async {
            entered = true
            if !released { await withCheckedContinuation { waiter = $0 } }
        }
        func release() { released = true; waiter?.resume(); waiter = nil }
    }

    func testFix29StopCancelsPreparingQueuedSendAndAllowsExplicitResume() async throws {
        let f = try await fixture()
        addTeardownBlock { await f.close() }
        _ = try await f.store.say("first", clientMessageID: "first")
        _ = try await f.store.say("second", clientMessageID: "second")
        let gate = PreparingGate()
        await f.store.setDesk { text, _ in
            if text == "second" { await gate.wait() }
            return ""
        }
        try f.release()
        try await until { await gate.entered }
        try await f.store.interrupt()
        await gate.release()
        try await until {
            let queue = await f.store.snapshot()["queuedMessages"].elements
            return queue?.first?["held"].bool == true && queue?.first?["deliveryPending"].bool == false
        }
        XCTAssertEqual(try f.inputs().count, 1, "Stop must cancel the message suspended in desk preparation")
        _ = try await f.store.queueFeature("queue/resume", arguments: .object([.init("id", .string("second"))]))
        try await until { await self.completed(f.store, count: 2) }
        XCTAssertEqual(try f.inputs().count, 2)
    }

    func testFix29CancelledWriterGateDoesNotWriteToProvider() async throws {
        let f = try await fixture(released: true)
        addTeardownBlock { await f.close() }
        let child = BackendHootChatProcess()
        try child.start(f.launch)
        let gate = BackendHootChatInputGate()
        gate.cancel()
        do { try await child.send(BackendHootChatCLI.user("must not arrive"), gate: gate); XCTFail("Cancelled write accepted") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "queued-send-stopped") }
        XCTAssertFalse(gate.writeStarted)
        await child.stopAndWait()
        XCTAssertEqual(try f.inputs().count, 0)
        let writing = BackendHootChatInputGate()
        try writing.beginWrite(); writing.cancel()
        XCTAssertTrue(writing.writeStarted, "A write already started stays uncertain until its receipt")
    }

    func testFix29UncertainDeliveryCannotContinueAfterRestartOrQueueRemoval() async throws {
        let f = try await fixture(released: true)
        addTeardownBlock { await f.close() }
        _ = try await f.store.say("first", clientMessageID: "first")
        try await until { await self.completed(f.store, count: 1) }
        await f.store.stop()
        let file = f.root.appendingPathComponent("chat.json")
        var saved = try NativeRPCValue.parseJSON(Data(contentsOf: file))
        var events = saved["events"].elements ?? []
        events.append(HootChatEvent(conversationID: f.store.conversationID, turnID: "uncertain-turn", sequence: Int(events.last?["sequence"].number ?? 0) + 1,
            provider: .claude, record: .init(.user, value: .object([.init("text", .string("held private message")), .init("clientMessageId", .string("uncertain"))])),
            at: Date().timeIntervalSince1970 * 1000 - 1000).wireValue)
        var queued = BackendHootQueuedMessage(id: "uncertain", text: "held private message", attachments: [], context: .object([]), caller: .local)
        queued.deliveryPending = true
        saved = saved.setting("events", .array(events)).setting("queuedMessages", .array([queued.wire]))
        try saved.encodedJSON().write(to: file)
        let reopened = try BackendHootChatStore(file: file)
        addTeardownBlock { await reopened.stop() }
        let restored = await reopened.snapshot()
        XCTAssertEqual(restored["resuming"].bool, false)
        let continuation = await reopened.takeContinuation()
        XCTAssertNil(continuation)
        try await reopened.attach(f.launch); try await reopened.initialize()
        try await reopened.continueCutOff(turn: "uncertain-turn", text: "held private message")
        _ = try await reopened.queueFeature("queue/remove", arguments: .object([.init("id", .string("uncertain"))]))
        try await reopened.continueCutOff(turn: "uncertain-turn", text: "held private message")
        await reopened.stop()
        XCTAssertEqual(try f.inputs().count, 1, "Neither restart nor removing the queue entry may replay uncertain text")
    }

    func testFinalResultOverridesRunningStatusWithoutStoppingBackgroundTask() async throws {
        let f = try await fixture(released: true)
        addTeardownBlock { await f.close() }
        _ = try await f.store.say("first", clientMessageID: "first")
        try await until { await self.completed(f.store, count: 1) }
        let state = await f.store.snapshot()
        XCTAssertEqual(state["busy"].bool, true)
        XCTAssertEqual(state["foreground"].bool, false)
        XCTAssertEqual(state["answering"].bool, false)
        XCTAssertEqual(state["children"].elements?.first?["status"].string, "running")
        _ = try await f.store.say("second", clientMessageID: "second")
        try await until { await self.completed(f.store, count: 2) }
        XCTAssertEqual(try f.inputs().count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("interrupted").path))
    }

    func testQueuedSendsPersistAndDrainInOrderOnceWithDuplicateIdentity() async throws {
        let f = try await fixture()
        addTeardownBlock { await f.close() }
        _ = try await f.store.say("first", clientMessageID: "first")
        try await until { await f.store.snapshot()["children"].elements?.isEmpty == false }
        let queued = try await f.store.say("second", clientMessageID: "second")
        XCTAssertEqual(queued["queued"].bool, true)
        XCTAssertEqual(queued["queueNotice"].string, "Hoot is still writing — your message will send when it finishes.")
        _ = try await f.store.say("second", clientMessageID: "second")
        _ = try await f.store.say("third", clientMessageID: "third")
        let saved = try NativeRPCValue.parseJSON(Data(contentsOf: f.root.appendingPathComponent("chat.json")))
        XCTAssertEqual(saved["queuedMessages"].elements?.count, 2)
        XCTAssertEqual(try f.inputs().count, 1)
        try f.release()
        try await until {
            let done = await self.completed(f.store, count: 3)
            let state = await f.store.snapshot()
            return done && state["queuedMessages"].elements?.isEmpty == true
        }
        XCTAssertEqual(try f.inputs().count, 3)
        let users = await f.store.snapshot(limit: 500)["events"].elements?.filter { $0["kind"].string == "user" }.compactMap { $0["value"]["text"].string }
        XCTAssertEqual(users, ["first", "second", "third"])
    }

    func testStopHoldsQueueAndExistingToolDoorCanResumeOrRemoveIt() async throws {
        let f = try await fixture()
        addTeardownBlock { await f.close() }
        _ = try await f.store.say("first")
        _ = try await f.store.say("held", clientMessageID: "held")
        try await f.store.interrupt()
        try await until { await self.completed(f.store, count: 1) }
        var queue = try await f.store.queueFeature("queue/list", arguments: .object([]))
        XCTAssertEqual(queue["items"].elements?.first?["held"].bool, true)
        XCTAssertEqual(try f.inputs().count, 1)
        XCTAssertFalse(BackendChatProviderFeaturePolicy.changes("queue/list"))
        XCTAssertTrue(BackendChatProviderFeaturePolicy.changes("queue/resume"))
        _ = try await f.store.queueFeature("queue/resume", arguments: .object([.init("id", .string("held"))]))
        try await until { await self.completed(f.store, count: 2) }
        queue = try await f.store.queueFeature("queue/list", arguments: .object([]))
        XCTAssertEqual(queue["items"].elements?.count, 0)
    }

    func testRestoredCompletedAnswerDoesNotInventAnotherTurnOrResume() async throws {
        let f = try await fixture(released: true)
        addTeardownBlock { await f.close() }
        _ = try await f.store.say("first")
        try await until { await self.completed(f.store, count: 1) }
        await f.store.stop()
        let reopened = try BackendHootChatStore(file: f.root.appendingPathComponent("chat.json"))
        let state = await reopened.snapshot()
        XCTAssertEqual(state["foreground"].bool, false)
        XCTAssertEqual(state["answering"].bool, false)
        XCTAssertEqual(state["resuming"].bool, false)
        let continuation = await reopened.takeContinuation()
        XCTAssertNil(continuation)
    }

    func testRestoredQueueHoldsUncertainWriteAndCanBeRemoved() async throws {
        let f = try await fixture()
        addTeardownBlock { await f.close() }
        _ = try await f.store.say("first")
        _ = try await f.store.say("waiting", clientMessageID: "waiting")
        await f.store.stop()
        let file = f.root.appendingPathComponent("chat.json")
        var saved = try NativeRPCValue.parseJSON(Data(contentsOf: file))
        let entries = try XCTUnwrap(saved["queuedMessages"].elements)
        saved = saved.setting("queuedMessages", .array(entries.map { $0.setting("deliveryPending", .bool(true)) }))
        try saved.encodedJSON().write(to: file)
        let reopened = try BackendHootChatStore(file: file)
        let queue = try await reopened.queueFeature("queue/list", arguments: .object([]))
        XCTAssertEqual(queue["items"].elements?.first?["held"].bool, true)
        do { _ = try await reopened.queueFeature("queue/resume", arguments: .object([.init("id", .string("waiting"))])); XCTFail("Uncertain send retried") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "uncertain-delivery") }
        _ = try await reopened.queueFeature("queue/remove", arguments: .object([.init("id", .string("waiting"))]))
        let empty = try await reopened.queueFeature("queue/list", arguments: .object([]))
        XCTAssertEqual(empty["items"].elements?.count, 0)
    }

    func testRestoredQueueSkipsInputWhoseDeliveryReceiptWasAlreadySaved() async throws {
        let f = try await fixture()
        addTeardownBlock { await f.close() }
        _ = try await f.store.say("first")
        _ = try await f.store.say("waiting", clientMessageID: "waiting")
        await f.store.stop()
        let file = f.root.appendingPathComponent("chat.json")
        var saved = try NativeRPCValue.parseJSON(Data(contentsOf: file))
        var events = saved["events"].elements ?? []
        events.append(HootChatEvent(conversationID: f.store.conversationID, turnID: "delivered", sequence: Int(events.last?["sequence"].number ?? 0) + 1,
            provider: .claude, record: .init(.session, value: .object([.init("clientMessageId", .string("waiting")), .init("deliveryConfirmed", .bool(true))]))).wireValue)
        saved = saved.setting("events", .array(events))
        try saved.encodedJSON().write(to: file)
        let reopened = try BackendHootChatStore(file: file)
        let queue = try await reopened.queueFeature("queue/list", arguments: .object([]))
        XCTAssertEqual(queue["items"].elements?.count, 0)
    }

    func testReattachedAppUsesCurrentHostForegroundReceipt() async throws {
        let f = try await fixture(released: true)
        addTeardownBlock { await f.close() }
        _ = try await f.store.say("first")
        try await until { await self.completed(f.store, count: 1) }
        let hostRoot = f.root.appendingPathComponent("host-fixture")
        try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)
        let paths = try BackendHOSTPaths(dataDirectory: hostRoot)
        _ = try paths.secret(create: true)
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        let server = try BackendHOSTServer(paths: paths, hostVersion: "scratch-hoot-stuck", manager: manager,
            launch: { _ in throw BackendHOSTFailure.unavailable }, snapshot: { manager.chatHostSnapshot($0) }, onIdle: {},
            resource: { method, _ in
                if method == "chats.inventory" { return try NativeRPCValue.object([.init("jobs", .array([])), .init("sessions", .array([]))]).encodedJSON() }
                return try await f.store.snapshot().encodedJSON()
            }, chatUpdates: { AsyncStream { _ in } })
        let client = try BackendHOSTClient(paths: paths)
        addTeardownBlock { client.detach(); server.stopListening() }
        let projection = try BackendHootChatStore(file: f.root.appendingPathComponent("app-projection.json"))
        try await projection.connectHosted(client, sessionID: "scratch-session")
        let state = await projection.snapshot()
        let foreground = await projection.foregroundWorking
        XCTAssertEqual(state["busy"].bool, true)
        XCTAssertEqual(state["foreground"].bool, false)
        XCTAssertFalse(foreground, "Reopening the app must not turn child work into a foreground answer")
        await projection.stop()
        client.detach(); server.stopListening()
    }

    func testPhoneFramesUseForegroundStateOnReconnectForBothPhoneKinds() async throws {
        let f = try await fixture(released: true)
        addTeardownBlock { await f.close() }
        _ = try await f.store.say("first")
        try await until { await self.completed(f.store, count: 1) }
        let adapter = BackendPhoneChats(engine: .init(read: { _ in await f.store.snapshot() }, isChat: { _ in true },
            say: { _, text in _ = try await f.store.say(text) }, interrupt: { _ in try await f.store.interrupt() },
            answer: { _, _, _ in }, start: { _ in throw BackendSessionFailure.missingSession }),
            host: .init(send: { _, _ in }, stillSees: { _, _ in true }, admitStarted: { _, _ in }))
        // iPhone and Android consume this same chats.events frame. A reconnect does not replay busy from a child.
        for _ in ["iphone", "android"] {
            let frame = try await adapter.conversation("scratch")
            XCTAssertEqual(frame.value["busy"].bool, false)
            let current = await f.store.snapshot()
            XCTAssertFalse(BackendHootChatStore.foreground(in: current))
        }
        await adapter.stop()
    }

    func testPhoneSendsQueueThroughSharedHostEngineWithoutInterrupting() async throws {
        let f = try await fixture()
        addTeardownBlock { await f.close() }
        _ = try await f.store.say("first")
        var engine = BackendPhoneChats.Engine(read: { _ in await f.store.snapshot() }, isChat: { _ in true },
            say: { _, text in _ = try await f.store.say(text) }, interrupt: { _ in try await f.store.interrupt() },
            answer: { _, _, _ in }, start: { _ in throw BackendSessionFailure.missingSession })
        engine.sendIdentified = { _, text, id, _ in _ = try await f.store.say(text, clientMessageID: id) }
        let adapter = BackendPhoneChats(engine: engine, host: .init(send: { _, _ in }, stillSees: { _, _ in true }, admitStarted: { _, _ in }))
        for device in ["iphone", "android"] {
            let context = BackendRemoteHostContext(connectionID: UUID(), deviceID: device, kind: .mine, address: "scratch", peerPublicKey: nil,
                claimedCapabilities: [], reach: .init(kind: .mine, unrestricted: true, folders: [], accounts: nil, drivesWindows: false), phoneAccess: .work)
            guard case .message(let message) = BackendRemoteProtocol.parseClientMessage("{\"t\":\"chats.say\",\"id\":\"scratch\",\"text\":\"\(device)\",\"clientMessageId\":\"\(device)\"}") else { return XCTFail("Invalid fixture") }
            _ = try await adapter.handle(message, context: context)
        }
        let queue = await f.store.snapshot()["queuedMessages"].elements
        XCTAssertEqual(queue?.count, 2)
        try f.release()
        try await until { await self.completed(f.store, count: 3) }
        XCTAssertEqual(try f.inputs().count, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("interrupted").path))
        await adapter.stop()
    }

    func testInvalidQueuedAttachmentAndDecisionBoundSourceAreNotAccepted() async throws {
        let f = try await fixture()
        addTeardownBlock { await f.close() }
        _ = try await f.store.say("first")
        do { _ = try await f.store.say("invalid", attachments: [.object([.init("type", .string("path"))])]); XCTFail("Invalid attachment queued") } catch { }
        do {
            _ = try await BackendPCDecisionDelivery.$required.withValue(true) { try await f.store.say("decision-bound") }
            XCTFail("Deferred decision validation escaped its source")
        } catch { }
        let queue = await f.store.snapshot()["queuedMessages"].elements
        XCTAssertEqual(queue?.count, 0)
    }
}
