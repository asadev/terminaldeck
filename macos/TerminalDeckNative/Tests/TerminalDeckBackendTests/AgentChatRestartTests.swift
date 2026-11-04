import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor AgentRestartPushes {
    var values: [NativeRPCValue] = []
    func note(_ value: NativeRPCValue) { values.append(value) }
}
private actor AgentRestartWaitResult {
    var finished = false
    func finish() { finished = true }
}

@Suite("Agent chats: machine restart and explicit same-thread Resume", .serialized)
struct AgentChatRestartTests {
    private static let fake = #"""
    #!/usr/bin/python3
    import json, os, sys
    provider = os.path.basename(sys.argv[0])
    def out(value): print(json.dumps(value), flush=True)
    open('launch-args.json', 'w').write(json.dumps(sys.argv[1:]))
    for line in sys.stdin:
        r = json.loads(line)
        with open('requests.jsonl', 'a') as f: f.write(json.dumps(r) + '\n')
        m = r.get('method')
        if r.get('type') == 'control_request':
            out({'type':'control_response','response':{'subtype':'success','request_id':r['request_id'],'response':{}}}); continue
        if m == 'initialize':
            out({'id':r['id'],'result':{} if provider == 'codex' else {'protocolVersion':1,'agentCapabilities':{'loadSession':True,'mcpCapabilities':{'http':True}}}})
        elif m in ['thread/resume', 'session/load']:
            if os.path.exists('lost-thread'):
                out({'id':r['id'],'error':{'message':'no rollout found'}})
            else: out({'id':r['id'],'result':{'thread':{'id':'saved-thread'}} if provider == 'codex' else {'sessionId':'saved-thread'}})
        elif m in ['thread/start', 'session/new']:
            out({'id':r['id'],'result':{'thread':{'id':'replacement-thread'}} if provider == 'codex' else {'sessionId':'replacement-thread'}})
        elif m in ['skills/list', 'mcpServerStatus/list']: out({'id':r['id'],'result':{'data':[]}})
        elif m == 'turn/start':
            out({'id':r['id'],'result':{'turn':{'id':'resumed-turn'}}})
            if os.path.exists('permission'):
                out({'id':7,'method':'item/commandExecution/requestApproval','params':{'threadId':'saved-thread','turnId':'resumed-turn','itemId':'tool','command':'scratch only'}})
                continue
            out({'method':'item/completed','params':{'threadId':'saved-thread','turnId':'resumed-turn','item':{'id':'answer','type':'agentMessage','text':'Resumed saved work'}}})
            out({'method':'turn/completed','params':{'threadId':'saved-thread','turn':{'id':'resumed-turn','status':'completed'}}})
        elif m == 'session/prompt':
            out({'method':'session/update','params':{'sessionId':'saved-thread','update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'Resumed saved work'}}}})
            out({'id':r['id'],'result':{'stopReason':'end_turn'}})
        elif r.get('type') == 'user':
            out({'type':'system','subtype':'init','session_id':'saved-thread'})
            out({'type':'assistant','message':{'role':'assistant','content':[{'type':'text','text':'Resumed saved work'}]}})
            out({'type':'result','subtype':'success','is_error':False,'session_id':'saved-thread','result':'Resumed saved work'})
    """#

    private struct Fixture {
        let root: URL
        let chats: BackendSessionChats
        let manager: BackendPTYManager
        let record: BackendTeamChatRecord
        let spawn: BackendSpawnSpec
        let pushes: AgentRestartPushes
        func requests() throws -> [NativeRPCValue] {
            guard let text = try? String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8) else { return [] }
            return try text.split(separator: "\n").map { try NativeRPCValue.parseJSON(Data($0.utf8)) }
        }
        func clean() async {
            await chats.endAllForQuit()
            manager.killAll()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func fixture(provider: HootChatProvider = .codex, legacy: Bool = false, completed: Bool = false, savedThread: Bool = true) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-restart-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cli = root.appendingPathComponent(provider.rawValue)
        try Data(Self.fake.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let home = root.appendingPathComponent("home"), claudeConfig = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeConfig, withIntermediateDirectories: true)
        let environment = ["HOME": home.path, "CLAUDE_CONFIG_DIR": claudeConfig.path, "PATH": "/usr/bin:/bin"]
        let manager = BackendPTYManager(inheritedEnvironment: environment, onEvent: { _ in })
        let spawn = BackendSpawnSpec(provider: provider.rawValue, command: cli.path, args: [], path: "/usr/bin:/bin", env: environment)
        var input = BackendCreateSessionInput(cwd: root.path, provider: provider.rawValue)
        input.chat = true; input.projectId = "project"; input.agentProfileID = "builder"; input.agentInstructions = "private-agent-notes"
        input.deniedTools = ["dangerous-tool"]; input.permissionMode = "ask"
        input.teamJob = .init(fromID: "commander", fromName: "Commander", agentID: "builder", agentName: "Builder", title: "Saved work")
        input.teamJob?.starterSessionID = "starter-session"
        let id = UUID().uuidString.lowercased()
        let meta = BackendSessionMeta(id: id, input: input, spawn: spawn)
        var record = BackendTeamChatRecord(session: meta, job: input.teamJob!, key: id)
        if !legacy { record.resumeInput = input }
        if completed { record.finishedAt = Date(); record.result = "Already finished" }
        let directory = root.appendingPathComponent("chats"), folder = BackendSessionChats.tabFolder(directory, key: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: folder.appendingPathComponent("job.json"))
        let event = HootChatEvent(conversationID: "app-chat", turnID: "saved-turn", sequence: 1, provider: provider,
            record: .text(.user, "Finish the saved job"), at: Date().timeIntervalSince1970 * 1000 - 1000)
        let history = NativeRPCValue.object([.init("version", .number(1)), .init("provider", .string(provider.rawValue)),
            .init("conversationId", .string("app-chat")), .init("sessionId", savedThread ? .string("saved-thread") : .null),
            .init("contextKey", .string("system:" + root.standardizedFileURL.path)), .init("events", .array([event.wireValue]))])
        try history.encodedJSON().write(to: BackendSessionChats.historyFile(folder, provider: provider))
        let pushes = AgentRestartPushes()
        let chats = BackendSessionChats(manager: manager, directory: directory, publish: { _, snapshot in await pushes.note(snapshot) })
        return .init(root: root, chats: chats, manager: manager, record: record, spawn: spawn, pushes: pushes)
    }

    @Test func startupKeepsRestartHandleStarterAndHistoryWithoutStartingProcessesOrLeakingNotes() async throws {
        let f = try fixture()
        defer { Task { await f.clean() } }
        try await f.chats.restoreJobHistory()
        let row = try #require(await f.chats.conversation(f.record.session.id))
        #expect(row.canResume && row.isFinished)
        #expect(row.result == "Ended by restart — Resume")
        #expect(row.resumeHandle["do"].string == "resume")
        #expect(row.restartEvent["starterSessionId"].string == "starter-session")
        #expect(row.wire["resumeInput"].isNullish)
        #expect(try !String(decoding: row.wire.encodedJSON(), as: UTF8.self).contains("private-agent-notes"))
        #expect(f.manager.list().isEmpty)
        #expect(try f.requests().isEmpty)
        #expect(await f.pushes.values.contains { $0["restartEvent"]["resume"]["sessionId"].string == row.session.id })
        let snapshot = try await f.chats.read(row.session.id, cursor: 0, limit: 10)
        #expect(snapshot["readOnly"].bool == true)
        #expect(snapshot["events"].elements?.contains { $0["value"]["text"].string == "Finish the saved job" } == true)
    }

    @Test(arguments: [HootChatProvider.claude, .codex, .gemini])
    func explicitResumeReconnectsTheSavedProviderThreadAndContinuesOnlyAfterTheCheckedAction(provider: HootChatProvider) async throws {
        let f = try fixture(provider: provider)
        defer { Task { await f.clean() } }
        try await f.chats.restoreJobHistory()
        var input = try await f.chats.jobResumeInput(f.record.session.id)
        #expect(input.resumeConversationId == "saved-thread")
        #expect(input.permissionMode == BackendTAGLaunchArguments.newSessionPermission(provider: provider.rawValue))
        #expect(input.deniedTools == ["dangerous-tool"])
        input.agentSettings = .init(provider: provider.rawValue, hooks: [.init(command: "/usr/bin/true")], environment: ["FIXTURE_VALUE": "scratch-setting"])
        let new = try await f.chats.launch(input, spawn: f.spawn)
        let savedInput = try #require(await f.chats.conversation(new.id)?.resumeInput)
        #expect(savedInput.agentSettings?.environment.isEmpty == true && savedInput.agentSettings?.hooks.isEmpty == true)
        #expect(new.id != f.record.session.id)
        let beforeContinue = try f.requests()
        #expect(!beforeContinue.contains { $0["method"].string == "turn/start" || $0["method"].string == "session/prompt" || $0["type"].string == "user" })
        if provider == .claude {
            let args = try NativeRPCValue.parseJSON(Data(contentsOf: f.root.appendingPathComponent("launch-args.json")))
            #expect(args.elements?.contains(.string("--resume")) == true)
            #expect(args.elements?.contains(.string("saved-thread")) == true)
        } else {
            let method = provider == .codex ? "thread/resume" : "session/load"
            let field = provider == .codex ? "threadId" : "sessionId"
            #expect(beforeContinue.contains { $0["method"].string == method && $0["params"][field].string == "saved-thread" })
            #expect(!beforeContinue.contains { ["thread/start", "session/new"].contains($0["method"].string ?? "") })
        }
        #expect(await f.chats.conversation(f.record.session.id)?.resumedBySessionID == new.id)
        await #expect(throws: (any Error).self) { try await f.chats.jobResumeInput(f.record.session.id) }
        _ = try await f.chats.continueResumedJob(new.id)
        #expect(try await f.chats.waitForTurn(new.id, timeout: .seconds(5)).state == .done(answer: "Resumed saved work"))
        let snapshot = try await f.chats.read(new.id, cursor: 0, limit: 500)
        #expect(snapshot["providerConversationId"].string == "saved-thread")
        #expect(snapshot["events"].elements?.filter { $0["kind"].string == "user" }.count == 1)
    }

    @Test func legacyUnfinishedJobsCanResumeButFinishedJobsCannot() async throws {
        let legacy = try fixture(legacy: true)
        let completed = try fixture(completed: true)
        defer { Task { await legacy.clean(); await completed.clean() } }
        try await legacy.chats.restoreJobHistory(); try await completed.chats.restoreJobHistory()
        let input = try await legacy.chats.jobResumeInput(legacy.record.session.id)
        #expect(input.agentProfileID == "builder" && input.resumeConversationId == "saved-thread")
        #expect(input.teamJob?.starterSessionID == "starter-session")
        await #expect(throws: (any Error).self) { try await completed.chats.jobResumeInput(completed.record.session.id) }
        #expect(await completed.chats.conversation(completed.record.session.id)?.interruptedAt == nil)
    }

    @Test func missingOrRejectedProviderThreadsRefuseWithoutSendingTheBriefOrClaimingTheOriginalJob() async throws {
        let missing = try fixture(savedThread: false), lost = try fixture()
        defer { Task { await missing.clean(); await lost.clean() } }
        try await missing.chats.restoreJobHistory(); try await lost.chats.restoreJobHistory()
        await #expect(throws: (any Error).self) { try await missing.chats.jobResumeInput(missing.record.session.id) }
        try Data().write(to: lost.root.appendingPathComponent("lost-thread"))
        let input = try await lost.chats.jobResumeInput(lost.record.session.id)
        await #expect(throws: (any Error).self) { try await lost.chats.launch(input, spawn: lost.spawn) }
        #expect(await lost.chats.conversation(lost.record.session.id)?.canResume == true)
        #expect(try !lost.requests().contains { $0["method"].string == "turn/start" })
    }

    @Test func starterEventsReportRestartAndCurrentPermissionWithAnswerHandleAndExcludeAnotherSeat() async throws {
        let f = try fixture()
        defer { Task { await f.clean() } }
        try await f.chats.restoreJobHistory()
        let initial = try await f.chats.starterEvents(fromID: "commander", starterSessionID: "starter-session")
        #expect(initial["events"].elements?.count == 1)
        #expect(initial["events"].elements?.first?["resume"]["do"].string == "resume")
        var input = try await f.chats.jobResumeInput(f.record.session.id)
        // Codex's Ask choice maps to default/on-request, not the UI label "ask".
        input.permissionMode = "default"
        let new = try await f.chats.launch(input, spawn: f.spawn)
        try Data().write(to: f.root.appendingPathComponent("permission"))
        let before = try await f.chats.starterEvents(fromID: "commander")
        let change = Task { try await f.chats.starterEvents(fromID: "commander", after: before["sequence"].number.map(Int.init), timeout: .seconds(5)) }
        _ = try await f.chats.continueResumedJob(new.id)
        _ = try await change.value
        let turn = try await f.chats.waitForTurn(new.id, timeout: .seconds(5))
        guard case .needsPermission = turn.state else { Issue.record("The scratch AI did not ask its expected permission"); return }
        let events = try await f.chats.starterEvents(fromID: "commander")
        let question = try #require(events["events"].elements?.first { $0["kind"].string == "needs-permission" })
        #expect(question["sessionId"].string == new.id)
        #expect(question["answer"]["do"].string == "answer")
        #expect(question["answer"]["request"].string == question["request"]["requestId"].string)
        #expect(try await f.chats.starterEvents(fromID: "another-seat")["events"].elements?.isEmpty == true)
    }

    @Test func concurrentResumeStartsOnlyOneProviderProcess() async throws {
        let f = try fixture()
        defer { Task { await f.clean() } }
        try await f.chats.restoreJobHistory()
        let input = try await f.chats.jobResumeInput(f.record.session.id)
        let first = Task { try? await f.chats.launch(input, spawn: f.spawn) }
        let second = Task { try? await f.chats.launch(input, spawn: f.spawn) }
        let results = await [first.value, second.value].compactMap { $0 }
        #expect(results.count == 1)
        #expect(try f.requests().filter { $0["method"].string == "thread/resume" }.count == 1)
        #expect(f.manager.list().count == 1)
    }

    @Test func anotherSeatsChangesNeitherAdvanceTheStarterCursorNorWakeItsWait() async throws {
        let f = try fixture()
        defer { Task { await f.clean() } }
        let otherID = UUID().uuidString.lowercased()
        var otherInput = try #require(f.record.resumeInput)
        otherInput.teamJob?.fromID = "another-seat"; otherInput.teamJob?.starterSessionID = "another-session"
        let otherMeta = BackendSessionMeta(id: otherID, input: otherInput, spawn: f.spawn)
        var other = BackendTeamChatRecord(session: otherMeta, job: otherInput.teamJob!, key: otherID)
        other.resumeInput = otherInput
        let directory = f.root.appendingPathComponent("chats")
        let otherFolder = BackendSessionChats.tabFolder(directory, key: otherID)
        try FileManager.default.copyItem(at: BackendSessionChats.tabFolder(directory, key: f.record.key), to: otherFolder)
        try JSONEncoder().encode(other).write(to: otherFolder.appendingPathComponent("job.json"))
        try await f.chats.restoreJobHistory()
        let before = try await f.chats.starterEvents(fromID: "commander", starterSessionID: "starter-session")
        let cursor = try #require(before["sequence"].number.map(Int.init))
        let outcome = AgentRestartWaitResult()
        let waiting = Task {
            let value = try await f.chats.starterEvents(fromID: "commander", starterSessionID: "starter-session", after: cursor, timeout: .seconds(5))
            await outcome.finish()
            return value
        }
        // Reads no longer publish a seen marker. A real resume must notify only its own starter.
        let otherResume = try await f.chats.jobResumeInput(otherID)
        _ = try await f.chats.launch(otherResume, spawn: f.spawn)
        let afterOther = try await f.chats.starterEvents(fromID: "commander", starterSessionID: "starter-session")
        #expect(afterOther["sequence"].number == Double(cursor))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await outcome.finished == false)
        _ = try await f.chats.read(f.record.session.id, cursor: nil, limit: 1, seen: 0)
        let afterRead = try await f.chats.starterEvents(fromID: "commander", starterSessionID: "starter-session")
        #expect(afterRead["sequence"].number == Double(cursor))
        #expect(await outcome.finished == false)
        let ownResume = try await f.chats.jobResumeInput(f.record.session.id)
        _ = try await f.chats.launch(ownResume, spawn: f.spawn)
        let result = try await waiting.value
        #expect((result["sequence"].number ?? 0) > Double(cursor))
    }
}
