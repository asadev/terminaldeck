import Foundation
import Darwin
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Helper-owned chats survive app clients", .serialized)
struct HOSTChatSurvivalTests {
    private static let fake = #"""
    #!/usr/bin/python3
    import json, os, sys, time
    provider = os.path.basename(sys.argv[0])
    turn = 0
    def send(x): print(json.dumps(x), flush=True)
    def finish():
        if provider == 'claude':
            send({'type':'assistant','message':{'role':'assistant','content':[{'type':'text','text':'Scratch job complete'}]}})
            send({'type':'result','subtype':'success','is_error':False,'session_id':'scratch-chat','result':'Scratch job complete'})
        elif provider == 'codex':
            send({'method':'item/completed','params':{'threadId':'scratch-chat','turnId':str(turn),'item':{'id':'answer','type':'agentMessage','text':'Scratch job complete'}}})
            send({'method':'turn/completed','params':{'threadId':'scratch-chat','turn':{'id':str(turn),'status':'completed'}}})
        else:
            send({'method':'session/update','params':{'sessionId':'scratch-chat','update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'Scratch job complete'}}}})
            send({'id':prompt,'result':{'stopReason':'end_turn'}})
    for line in sys.stdin:
        r = json.loads(line)
        m = r.get('method')
        if provider == 'claude' and r.get('type') == 'control_request':
            send({'type':'control_response','response':{'subtype':'success','request_id':r['request_id'],'response':{}}}); continue
        if m == 'initialize':
            send({'id':r['id'],'result':{} if provider == 'codex' else {'protocolVersion':1,'agentCapabilities':{'loadSession':True,'mcpCapabilities':{'http':True}}}}); continue
        if m in ['thread/start','thread/resume','session/new','session/load']:
            send({'id':r['id'],'result':{'thread':{'id':'scratch-chat'}} if provider == 'codex' else {'sessionId':'scratch-chat'}}); continue
        if m == 'mcpServerStatus/list': send({'id':r['id'],'result':{'data':[]}}); continue
        if m == 'thread/goal/get': send({'id':r['id'],'result':{'goal':{'threadId':r['params']['threadId'],'objective':'Scratch goal','status':'paused','tokensUsed':3}}}); continue
        if m == 'thread/realtime/start':
            open('voice-started','w').write(str(os.getpid()))
            if os.path.exists('voice-hold-start'):
                while not os.path.exists('voice-release-start'): time.sleep(.01)
            send({'id':r['id'],'result':{}}); continue
        if m == 'thread/realtime/stop':
            if os.path.exists('voice-stop-fail'):
                send({'id':r['id'],'error':{'message':'Scratch voice stop not confirmed'}}); continue
            open('voice-stopped','w').write(str(os.getpid()))
            send({'id':r['id'],'result':{}}); continue
        if r.get('type') == 'user' or m in ['turn/start','session/prompt']:
            turn += 1
            prompt = r.get('id')
            if provider == 'codex': send({'id':prompt,'result':{'turn':{'id':str(turn)}}})
            open('working','w').write(str(os.getpid()))
            while not os.path.exists('release'): time.sleep(.01)
            if os.path.exists('permission'):
                if provider == 'claude': send({'type':'control_request','request_id':'permit','request':{'subtype':'can_use_tool','tool_name':'Bash','input':{'command':'scratch only'}}})
                elif provider == 'codex': send({'id':7,'method':'item/commandExecution/requestApproval','params':{'threadId':'scratch-chat','turnId':str(turn),'itemId':'tool','command':'scratch only'}})
                else: send({'id':7,'method':'session/request_permission','params':{'sessionId':'scratch-chat','toolCall':{'title':'scratch only','toolCallId':'tool'},'options':[{'kind':'allow_once','optionId':'once'},{'kind':'reject_once','optionId':'deny'}]}})
            else: finish()
        elif r.get('type') == 'control_response' or (m is None and r.get('id') == 7):
            open('answered','w').write('yes'); finish()
    """#
    private struct Fixture {
        let root: URL, manager: BackendPTYManager, service: BackendHOSTChats, server: BackendHOSTServer, client: BackendHOSTClient
        let session: BackendSessionMeta
        func app() async throws -> BackendSessionChats {
            let projection = BackendSessionChats(manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }), directory: root.appendingPathComponent("unused-app-history"), publish: { _, _ in })
            try await projection.useHost(client)
            return projection
        }
        func cleanup() async {
            _ = try? await service.invoke("chats.stopAll", payload: Data("{}".utf8))
            server.stopListening(); client.detach()
            try? FileManager.default.removeItem(at: root)
        }
        func release() throws { try Data().write(to: root.appendingPathComponent("release")) }
    }
    private func fixture(provider: String = "claude", team: Bool = true, legacyVoiceDetach: Bool = false) async throws -> Fixture {
        let root = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().appendingPathComponent("ch1-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let binary = root.appendingPathComponent(provider)
        try Data(Self.fake.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        let service = BackendHOSTChats(manager: manager, directory: root.appendingPathComponent("session-chats"))
        let paths = try BackendHOSTPaths(dataDirectory: root)
        _ = try paths.secret(create: true)
        let server = try BackendHOSTServer(paths: paths, hostVersion: "scratch-chat-v1", manager: manager, launch: { _ in throw BackendHOSTFailure.unavailable },
            snapshot: { manager.chatHostSnapshot($0) }, onIdle: {}, resource: { method, payload in
                if legacyVoiceDetach, method == "chats.voice-detach" { throw BackendHOSTFailure.invalid("Unknown chat service operation.") }
                return try await service.invoke(method, payload: payload)
            }, chatUpdates: { try await service.subscribe() })
        let client = try BackendHOSTClient(paths: paths)
        var input = BackendCreateSessionInput(cwd: root.path, provider: provider); input.chat = true
        if team { input.teamJob = .init(fromID: "scratch-sender", fromName: "Scratch sender", agentID: "scratch-agent", agentName: "Scratch agent", title: "Restart proof") }
        let spawn = BackendSpawnSpec(provider: provider, command: binary.path, args: [], path: "/usr/bin:/bin", tabKey: "scratch-tab")
        let launch = try BackendHOSTProtocol.Launch(id: UUID().uuidString.lowercased(), input: input, spawn: spawn, inheritedEnvironment: [:])
        let session = try client.create(launch)
        return .init(root: root, manager: manager, service: service, server: server, client: client, session: session)
    }
    private func wait(_ check: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline { if try await check() { return }; try await Task.sleep(for: .milliseconds(20)) }
        throw NativeRPCError(code: "test-timeout", message: "Scratch chat did not reach the expected state.")
    }
    private actor AttentionPushes {
        var snapshots: [NativeRPCValue] = []
        func append(_ snapshot: NativeRPCValue) { snapshots.append(snapshot) }
        func permission() -> String? {
            snapshots.last?["pending"].elements?.first?["requestId"].string
        }
        func finished() -> Bool {
            guard let snapshot = snapshots.last, snapshot["busy"].bool == false else { return false }
            let events = snapshot["events"].elements ?? []
            return events.contains { $0["kind"].string == "completed" }
                && events.contains { $0["value"]["text"].string == "Scratch job complete" }
        }
    }
    @Test func codexChatDropsFinishedJobKeepsItsAnswerAndCleanExit() async throws {
        let f = try await fixture(provider: "codex"), app = try await f.app()
        defer { Task { await f.cleanup() } }
        _ = try await app.say(f.session.id, text: "Finish this scratch job")
        try f.release()
        try await wait { f.manager.list().first { $0.id == f.session.id }?.exitCode == 0 }
        let snapshot = try await app.read(f.session.id, cursor: nil, limit: 500)
        #expect(BackendSessionChats.plainText(snapshot).contains("Scratch job complete"))
        #expect(try await app.turn(f.session.id).state == .done(answer: "Scratch job complete"))
        #expect(await app.conversation(f.session.id)?.isFinished == true)
        #expect(f.manager.chatHostSnapshot(f.session.id)?.status == .completed)
        #expect(f.manager.pidOf(f.session.id) == nil)
        await app.endAllForQuit(); await f.cleanup()
    }
    @Test(arguments: ["claude", "codex", "gemini"])
    func chatAttentionReceivesPermissionOutputAndCompletionWithoutAChatView(provider: String) async throws {
        let f = try await fixture(provider: provider, team: false), pushes = AttentionPushes()
        defer { Task { await f.cleanup() } }
        let id = f.session.id
        // Only the app's global lifecycle projection is attached. No Chat model/view,
        // window selection, focused app, read polling, or OS notification sink exists.
        let app = BackendSessionChats(manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }),
            directory: f.root.appendingPathComponent("unused-attention-history"), publish: { changed, snapshot in
                if changed == id { await pushes.append(snapshot) }
            })
        try await app.useHost(f.client)
        try Data().write(to: f.root.appendingPathComponent("permission"))
        _ = try await app.say(id, text: "Global attention fixture")
        try f.release()
        try await wait { await pushes.permission() != nil }
        let request = try #require(await pushes.permission())
        _ = try await app.answer(id, request: request, allowed: true, answers: .object([]))
        try await wait { await pushes.finished() }
        #expect(f.manager.pidOf(id) != nil, "Global attention publication must not end the provider session")
        await app.endAllForQuit(); await f.cleanup()
    }
    /// 18 Oct (#76): a removed chat's last snapshot is not kept and replayed to the next app as if it were still the helper's.
    @Test func removedChatIsNotReplayedToTheNextApp() async throws {
        let f = try await fixture(provider: "claude", team: false)
        defer { Task { await f.cleanup() } }
        let removed = f.session.id
        _ = try await f.service.invoke("chats.remove", payload: NativeRPCValue.object([.init("id", .string(removed))]).encodedJSON())
        var input = BackendCreateSessionInput(cwd: f.root.path, provider: "claude"); input.chat = true
        let spawn = BackendSpawnSpec(provider: "claude", command: f.root.appendingPathComponent("claude").path, args: [], path: "/usr/bin:/bin", tabKey: "kept-tab")
        let kept = try f.client.create(try BackendHOSTProtocol.Launch(id: UUID().uuidString.lowercased(), input: input, spawn: spawn, inheritedEnvironment: [:]))
        // What the helper replays to the next app that attaches.
        let stream = try await f.service.subscribe()
        let replayed = Task { () -> Set<String> in
            var ids: Set<String> = []
            for await value in stream { if let id = value["id"].string { ids.insert(id) } }
            return ids
        }
        try await Task.sleep(for: .milliseconds(300))
        replayed.cancel()
        let ids = await replayed.value
        #expect(ids.contains(kept.id))
        #expect(!ids.contains(removed))
        await f.cleanup()
    }
    @Test func helperChatProviderFeaturesUseExistingOwnerAcrossReattach() async throws {
        let f = try await fixture(provider: "codex", team: false), app = try await f.app()
        defer { Task { await f.cleanup() } }
        #expect(f.client.hello.chatFeatures == 1)
        let before = f.manager.pidOf(f.session.id)
        let goal = try await app.providerFeature(f.session.id, operation: "goals/read")
        #expect(goal["goal"]["threadId"].string == "scratch-chat")
        #expect(goal["goal"]["objective"].string == "Scratch goal")
        await app.endAllForQuit()
        let reopened = try await f.app()
        #expect(try await reopened.providerFeature(f.session.id, operation: "goals/read") == goal)
        #expect(f.manager.pidOf(f.session.id) == before)
        #expect(f.manager.list().filter { $0.exitCode == nil }.count == 1)
        do { _ = try await reopened.providerFeature(f.session.id, operation: "config/value/write"); Issue.record("Raw config RPC escaped the feature allowlist") } catch { }
        await reopened.endAllForQuit(); await f.cleanup()
    }
    @Test func frontendQuitStopsRealtimeEvenWithAnotherObserverAndKeepsParent() async throws {
        let f = try await fixture(provider: "codex", team: false), app = try await f.app(), other = try await f.app()
        defer { Task { await f.cleanup() } }
        _ = try await app.providerFeature(f.session.id, operation: "voice/start")
        let pid = try #require(f.manager.pidOf(f.session.id))
        #expect(try await app.read(f.session.id, cursor: nil, limit: 1)["transientVoice"]["activeOrUncertain"].bool == true)
        await app.endAllForQuit()
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("voice-stopped").path))
        #expect(f.manager.pidOf(f.session.id) == pid)
        #expect(kill(pid, 0) == 0)
        #expect(try await other.read(f.session.id, cursor: nil, limit: 1)["transientVoice"]["activeOrUncertain"].bool == false)
        #expect(try await other.providerFeature(f.session.id, operation: "goals/read")["goal"]["objective"].string == "Scratch goal")
        await other.endAllForQuit(); await f.cleanup()
    }
    @Test func abruptLastWatchDisconnectStopsRealtimeWithoutEndingConversation() async throws {
        let f = try await fixture(provider: "codex", team: false)
        defer { Task { await f.cleanup() } }
        let observer = BackendHOSTChatClient(client: f.client)
        try await observer.attach { _, _ in }
        _ = try await observer.call("provider", id: f.session.id, fields: [.init("operation", .string("voice/start")), .init("arguments", .object([]))])
        let pid = try #require(f.manager.pidOf(f.session.id))
        observer.detach()
        try await wait { FileManager.default.fileExists(atPath: f.root.appendingPathComponent("voice-stopped").path) }
        #expect(f.manager.pidOf(f.session.id) == pid)
        #expect(kill(pid, 0) == 0)
        let state = try await f.client.resource("chats.read", arguments: .object([.init("id", .string(f.session.id))]))
        #expect(state["transientVoice"]["activeOrUncertain"].bool == false)
        await f.cleanup()
    }
    @Test func detachWaitsForPendingVoiceStartBeforeStoppingItsTransport() async throws {
        let f = try await fixture(provider: "codex", team: false)
        defer { Task { await f.cleanup() } }
        try Data().write(to: f.root.appendingPathComponent("voice-hold-start"))
        let observer = BackendHOSTChatClient(client: f.client)
        try await observer.attach { _, _ in }
        let start = Task { try await observer.call("provider", id: f.session.id, fields: [.init("operation", .string("voice/start")), .init("arguments", .object([]))]) }
        try await wait { FileManager.default.fileExists(atPath: f.root.appendingPathComponent("voice-started").path) }
        let pid = try #require(f.manager.pidOf(f.session.id))
        observer.detach()
        try Data().write(to: f.root.appendingPathComponent("voice-release-start"))
        _ = try await start.value
        try await wait { FileManager.default.fileExists(atPath: f.root.appendingPathComponent("voice-stopped").path) }
        #expect(f.manager.pidOf(f.session.id) == pid)
        #expect(kill(pid, 0) == 0)
        await f.cleanup()
    }
    @Test func unconfirmedVoiceStopKeepsUncertainFlagAndParentUntilExplicitRetry() async throws {
        let f = try await fixture(provider: "codex", team: false), app = try await f.app()
        defer { Task { await f.cleanup() } }
        _ = try await app.providerFeature(f.session.id, operation: "voice/start")
        let pid = try #require(f.manager.pidOf(f.session.id))
        try Data().write(to: f.root.appendingPathComponent("voice-stop-fail"))
        let failed = try await f.client.resource("chats.voice-detach", arguments: .object([.init("id", .string(f.session.id))]))
        #expect(failed["stopped"].bool == false)
        let state = try await app.read(f.session.id, cursor: nil, limit: 1)
        #expect(state["transientVoice"]["activeOrUncertain"].bool == true)
        #expect(state["transientVoice"]["error"].string?.contains("Scratch voice stop not confirmed") == true)
        #expect(f.manager.pidOf(f.session.id) == pid)
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("voice-stop-fail"))
        let retried = try await f.client.resource("chats.voice-detach", arguments: .object([.init("id", .string(f.session.id))]))
        #expect(retried["stopped"].bool == true)
        #expect(try await app.read(f.session.id, cursor: nil, limit: 1)["transientVoice"]["activeOrUncertain"].bool == false)
        #expect(f.manager.pidOf(f.session.id) == pid)
        await app.endAllForQuit(); await f.cleanup()
    }
    @Test func featureOneHelperWithoutDetachReportsUpgradeWithoutRestartingParent() async throws {
        let f = try await fixture(provider: "codex", team: false, legacyVoiceDetach: true), app = try await f.app()
        defer { Task { await f.cleanup() } }
        _ = try await app.providerFeature(f.session.id, operation: "voice/start")
        let pid = try #require(f.manager.pidOf(f.session.id))
        let client = BackendHOSTChatClient(client: f.client)
        let result = await client.stopTransientVoice(f.session.id)
        #expect(f.client.hello.chatFeatures == 1)
        #expect(result["stopped"].bool == false)
        #expect(result["code"].string == "helper-upgrade-required")
        #expect(result["activeOrUncertain"].bool == true)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("voice-stopped").path))
        #expect(f.manager.pidOf(f.session.id) == pid)
        #expect(kill(pid, 0) == 0)
        await app.endAllForQuit(); await f.cleanup()
    }
    @Test func disconnectAndReconnectMidTurnKeepsSameProcessAndCursor() async throws {
        let f = try await fixture(), app = try await f.app()
        defer { Task { await f.cleanup() } }
        _ = try await app.say(f.session.id, text: "slow job")
        try await wait { FileManager.default.fileExists(atPath: f.root.appendingPathComponent("working").path) }
        let before = try await app.read(f.session.id, cursor: nil, limit: 500)
        let pid = try #require(f.manager.pidOf(f.session.id))
        await app.endAllForQuit()
        #expect(kill(pid, 0) == 0)
        #expect(getpgid(pid) == pid)
        let reopened = try await f.app()
        #expect(try await reopened.turn(f.session.id).state == .working)
        #expect(f.manager.pidOf(f.session.id) == pid)
        try f.release()
        #expect(try await reopened.waitForTurn(f.session.id, timeout: .seconds(5)).state == .done(answer: "Scratch job complete"))
        let replay = try await reopened.read(f.session.id, cursor: Int(before["cursor"].number ?? 0), limit: 500)
        #expect(replay["reset"].bool == false)
        #expect((replay["events"].elements ?? []).contains { $0["value"]["text"].string == "Scratch job complete" })
        // The keeper's send queue (delivery-requests, e36995da) sits beside the tab folders; the journal is in the one tab folder.
        let folders = try FileManager.default.contentsOfDirectory(at: f.root.appendingPathComponent("session-chats"), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != "delivery-requests" }
        #expect(folders.count == 1)
        let journal = try String(contentsOf: #require(folders.first).appendingPathComponent("chat.json"), encoding: .utf8)
        #expect(journal.contains("Scratch job complete"))
        await reopened.endAllForQuit(); await f.cleanup()
    }
    @Test func jobFinishedWhileClosedIsFinishedOnReopen() async throws {
        let f = try await fixture(), app = try await f.app()
        defer { Task { await f.cleanup() } }
        _ = try await app.say(f.session.id, text: "finish while closed")
        await app.endAllForQuit(); try f.release()
        try await wait { f.manager.list().first { $0.id == f.session.id }?.exitCode == 0 }
        let reopened = try await f.app()
        #expect(try await reopened.turn(f.session.id).state == .done(answer: "Scratch job complete"))
        #expect(try await reopened.read(f.session.id, cursor: nil, limit: 500)["readOnly"].bool == true)
        #expect(await reopened.conversation(f.session.id)?.isFinished == true)
        #expect(f.manager.pidOf(f.session.id) == nil)
        await reopened.endAllForQuit(); await f.cleanup()
    }
    @Test(arguments: ["claude", "codex", "gemini"])
    func permissionRaisedWhileClosedCanBeAnsweredAfterReopen(provider: String) async throws {
        let f = try await fixture(provider: provider), app = try await f.app()
        defer { Task { await f.cleanup() } }
        try Data().write(to: f.root.appendingPathComponent("permission"))
        _ = try await app.say(f.session.id, text: "ask after app closes")
        await app.endAllForQuit(); try f.release()
        let reopened = try await f.app()
        try await wait { !(try await reopened.read(f.session.id, cursor: nil, limit: 500)["pending"].elements ?? []).isEmpty }
        let request = try #require(try await reopened.read(f.session.id, cursor: nil, limit: 500)["pending"].elements?.first?["requestId"].string)
        _ = try await reopened.answer(f.session.id, request: request, allowed: true, answers: .object([]))
        #expect(try await reopened.waitForTurn(f.session.id, timeout: .seconds(5)).state == .done(answer: "Scratch job complete"))
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("answered").path))
        await #expect(throws: (any Error).self) { _ = try await reopened.answer(f.session.id, request: request, allowed: true, answers: .object([])) }
        await reopened.endAllForQuit(); await f.cleanup()
    }
    @Test func stopAndDeleteStillEndTheProcessAndRemoveKeptHistory() async throws {
        let f = try await fixture(), app = try await f.app()
        defer { Task { await f.cleanup() } }
        _ = try await app.say(f.session.id, text: "stop this slow job")
        let pid = try #require(f.manager.pidOf(f.session.id))
        _ = try await app.stop(f.session.id)
        #expect(kill(pid, 0) != 0)
        #expect(try await app.turn(f.session.id).state == .failed(reason: "Stopped"))
        let folder = BackendSessionChats.tabFolder(f.root.appendingPathComponent("session-chats"), key: f.session.id)
        try Data("old picture".utf8).write(to: folder.appendingPathComponent("chat.json.pre-media"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("media"), withIntermediateDirectories: true)
        try Data("picture".utf8).write(to: folder.appendingPathComponent("media/picture.png"))
        try await app.deleteJobHistory(f.session.id)
        #expect(f.manager.list().allSatisfy { $0.id != f.session.id })
        // Only hashed retry protection remains; no journal, media, backup or outgoing message survives deletion.
        let history = f.root.appendingPathComponent("session-chats")
        #expect(try FileManager.default.contentsOfDirectory(atPath: history.path) == ["delivery-requests"])
        for registry in [history.appendingPathComponent("delivery-requests"), f.root.appendingPathComponent("chat-outgoing")] {
            #expect(try FileManager.default.contentsOfDirectory(atPath: registry.path) == ["retired.bin"])
        }
        await app.endAllForQuit(); await f.cleanup()
    }
    @Test func ordinaryChatSurvivesQuitAndCanBeExplicitlyRemoved() async throws {
        let f = try await fixture(team: false), app = try await f.app()
        defer { Task { await f.cleanup() } }
        _ = try await app.say(f.session.id, text: "ordinary chat")
        let pid = try #require(f.manager.pidOf(f.session.id))
        await app.endAllForQuit(); let reopened = try await f.app()
        #expect(f.manager.pidOf(f.session.id) == pid)
        try f.release()
        #expect(try await reopened.waitForTurn(f.session.id, timeout: .seconds(5)).state == .done(answer: "Scratch job complete"))
        try await reopened.removeSession(f.session)
        #expect(kill(pid, 0) != 0)
        for registry in [f.root.appendingPathComponent("session-chats/delivery-requests"), f.root.appendingPathComponent("chat-outgoing")] {
            #expect(try FileManager.default.contentsOfDirectory(atPath: registry.path) == ["retired.bin"])
        }
        await reopened.endAllForQuit(); await f.cleanup()
    }
    @Test func oldHelloWithoutCapabilityKeepsInAppChatPath() async throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("ch1-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try BackendHOSTPaths(dataDirectory: root); _ = try paths.secret(create: true)
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        let server = try BackendHOSTServer(paths: paths, hostVersion: "old", manager: manager, launch: { _ in throw BackendHOSTFailure.unavailable }, snapshot: { _ in nil }, onIdle: {})
        defer { server.stopListening() }
        let client = try BackendHOSTClient(paths: paths)
        #expect(client.hello.chatService == nil)
        let oldJSON = try NativeRPCValue.parseJSON(JSONEncoder().encode(client.hello))
        #expect(try JSONDecoder().decode(BackendHOSTProtocol.Hello.self, from: oldJSON.encodedJSON()).chatService == nil)
        let chats = BackendSessionChats(manager: manager, directory: root.appendingPathComponent("session-chats"), publish: { _, _ in })
        try await chats.useHost(client)
        let binary = root.appendingPathComponent("claude")
        try Data(Self.fake.utf8).write(to: binary); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        var input = BackendCreateSessionInput(cwd: root.path, provider: "claude"); input.chat = true
        let session = try await chats.launch(input, spawn: .init(provider: "claude", command: binary.path, args: [], path: "/usr/bin:/bin"))
        #expect(manager.pidOf(session.id) != nil)
        await chats.endAllForQuit()
        #expect(manager.pidOf(session.id) == nil)
        #expect(client.hello.hostPID == getpid())
    }
}
