import Foundation
import Testing
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private struct ChatDirectoryState: BackendDeckCoreLiveState {
    func listProjects() -> [NativeRPCValue] { [] }
    func appStateRoot() -> String { "/scratch/app" }
    func copilotRoot() -> String { "/scratch/hoot" }
    func readSettings() -> NativeRPCValue { .object([]) }
    func snapshotSettings(reason: String) throws -> NativeRPCValue { .null }
    func writeSettings(_ patch: NativeRPCValue) throws -> NativeRPCValue { .null }
    func writePreferences(_ patch: NativeRPCValue) throws -> NativeRPCValue { .null }
}

@MainActor final class ChatSessionsVisibleScopeTests: XCTestCase {
    func testListingAPeerLeadDoesNotGrantItsFolderOrSessionControls() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("chat-directory-scope-" + UUID().uuidString).resolvingSymlinksInPath()
        let data = scratch.appendingPathComponent("data"), own = scratch.appendingPathComponent("own"), peer = scratch.appendingPathComponent("peer")
        for folder in [data, own, peer] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let store = try NativeStateStore(file: data.appendingPathComponent("state.json"), ownership: .memory)
        _ = try await store.addProject(own.path); _ = try await store.addProject(peer.path)
        let root = try BackendCompositionRoot(dataRoot: data, state: store, environment: [:], home: scratch.path)
        let state = await BackendCompositionState.make(store: store, settings: root.settings, dataRoot: data,
            registry: root.registry, copilotRoot: { _ in data.appendingPathComponent("hoot").path })
        let configuration = try BackendAccountConfiguration(dataDirectory: data, homeDirectory: scratch,
            appName: "Chat directory fixture", appID: "terminaldeck", helperExecutable: scratch.appendingPathComponent("never-run"),
            inheritedEnvironment: root.preparedSessions.environment)
        let contexts = BackendDeckCoreToolContextAuthority()
        let authority = try BackendCompositionAuthority(prepared: root.preparedSessions, state: state, configuration: configuration,
            coreContexts: contexts, gate: .init(authorize: { _, _, _, _, _, _ in }, record: { _, _, _, _ in }), hidden: .init())
        let center = DeckMemorySessionCenter(dataRoot: data, manager: root.preparedSessions.manager, services: .files(memoryRoot: { scratch.appendingPathComponent("memory") }))
        let previous = DeckMemorySessionCenter.shared
        DeckMemorySessionCenter.shared = center
        addTeardownBlock {
            DeckMemorySessionCenter.shared = previous
            authority.close(); await state.stop(); try await root.shutdown()
            try? FileManager.default.removeItem(at: scratch)
        }
        for (id, folder) in [("decker", own), ("commander", peer)] {
            var input = BackendCreateSessionInput(cwd: folder.path, provider: "codex"); input.chat = true
            let meta = BackendSessionMeta(id: id, input: input, spawn: .init(provider: "codex", command: "/never-run", args: [], path: "/usr/bin"))
            try root.preparedSessions.manager.registerChat(meta, controls: .init(send: { _ in }, stop: {}, text: { "" }, pid: { nil }))
            let owner = DeckMemorySessionOwner(kind: .lead, id: id, name: id, project: id)
            let entry = NativeRPCValue.object([.init("owner", try .parseJSON(JSONEncoder().encode(owner))), .init("provider", .string("codex")),
                .init("largeWindow", .bool(false)), .init("working", .bool(false))])
            let directory = DeckMemorySessionHook.session(center.root, id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try entry.encodedJSON().write(to: directory.appendingPathComponent("state.json"))
        }
        let scope = BackendCompositionDeckToolsScope(gate: .init(authority: authority, authorize: { _, _, _, _ in }, noteResult: { _, _ in }),
            deviceFolders: nil, workspaces: nil, browserSlots: { _, _ in [] })
        let context = BackendDeckCoreSecurityCallContext(native: .init(sessionID: "decker", machineID: "", projectRoot: nil,
            attended: true, allowedTools: BackendOrdinarySessionToolGrant.names, allowedTiers: [.read, .act], cancellation: .init()),
            caller: .init(kind: .session, tiers: [.read, .act], sessionID: "decker"), callID: "directory-scope", attended: true,
            granted: BackendOrdinarySessionToolGrant.names, sessionLimits: .object([]), now: { 0 }, startedByCopilot: { _ in false }, noteStarted: { _ in })
        let reply = try await contexts.invoke(handler: { native, _ in
            let rows = try await scope.sessions(native), folders = try await scope.knownFolders(native)
            var folderRefused = false, controlsRefused = false
            do { _ = try await scope.knownFolder(peer.path, native: native) } catch { folderRefused = true }
            do { _ = try await scope.session("commander", native: native) } catch { controlsRefused = true }
            return .value(.object([.init("ids", .array(rows.map { $0["id"] })), .init("folders", .array(folders.sorted().map(NativeRPCValue.string))),
                .init("folderRefused", .bool(folderRefused)), .init("controlsRefused", .bool(controlsRefused))]))
        }, arguments: .object([]), context: context)
        let value = try XCTUnwrap(reply.structuredContent)
        XCTAssertEqual(Set(value["ids"].elements?.compactMap(\.string) ?? []), ["decker", "commander"])
        XCTAssertEqual(value["folders"].elements, [.string(own.path)])
        XCTAssertEqual(value["folderRefused"].bool, true)
        XCTAssertEqual(value["controlsRefused"].bool, true)
    }
}

@Suite("One directory for terminal, Chat and team sessions", .serialized)
struct ChatSessionsVisibleTests {
    private func meta(_ id: String, cwd: String, chat: Bool = true, job: Bool = false) -> BackendSessionMeta {
        var input = BackendCreateSessionInput(cwd: cwd, provider: "claude")
        input.chat = chat; input.origin = job ? .copilot : .user
        return .init(id: id, input: input, spawn: .init(provider: "claude", command: "/bin/false", args: [], path: "/usr/bin:/bin",
            agentSessionId: "provider-" + id, tabKey: "tab-" + id))
    }
    private func row(_ id: String, cwd: String, lead: Bool = false, chat: Bool = true, job: Bool = false) -> NativeRPCValue {
        BackendSessionDirectory.row(meta(id, cwd: cwd, chat: chat, job: job), owner: lead ? .init(kind: .lead, id: id, name: id, project: id) : .plain)
    }
    private func context(_ caller: BackendDeckCoreSecurityCaller = .local) -> BackendDeckCoreSecurityCallContext {
        .init(native: .init(sessionID: caller.sessionID ?? "", machineID: "", projectRoot: caller.projectRoot,
                           attended: true, allowedTools: BackendOrdinarySessionToolGrant.names, allowedTiers: caller.tiers, cancellation: .init()),
            caller: caller, callID: UUID().uuidString, attended: true, granted: BackendOrdinarySessionToolGrant.names,
            sessionLimits: .missing, now: { 100 }, startedByCopilot: { _ in false }, noteStarted: { _ in })
    }
    private func surface(manager: BackendPTYManager, rows: [NativeRPCValue]? = nil,
                         send: (@Sendable (String, String) async throws -> Void)? = nil) throws -> BackendDeckCoreLiveSurface {
        let scope = NativeTranscriptScope(configDirectory: "/scratch/no-transcripts")
        return try .init(manager: manager, state: ChatDirectoryState(),
            evidence: BackendDeckCoreNativeEvidence(scopeForProject: { _ in scope }, scopeForPath: { _ in scope }),
            projectEvidence: BackendDeckCoreTestPortS1LiveSurfaceNoProcesses(), ownership: .exclusive,
            startSession: { _ in throw BackendSessionFailure.closed },
            writeToSession: { _, _ in throw BackendSessionFailure.invalidInput("Chat must not type into a terminal or draft") },
            closeSession: { _ in throw BackendSessionFailure.closed }, sessionStatus: { _ in .null }, windows: { _ in [] },
            readSessions: rows.map { held in { @Sendable in held } }, sendChat: send)
    }

    @Test func everyKindKeepsItsAppIDViewAndSeat() throws {
        let rows = [row("terminal", cwd: "/one", chat: false), row("chat", cwd: "/two", lead: true), row("job", cwd: "/three", job: true)]
        let surface = try surface(manager: .init(inheritedEnvironment: [:], onEvent: { _ in }), rows: rows)
        let values = surface.listSessions().map { BackendDeckCoreCatalogueBuiltins.viewOf(surface: surface, context: context(), metadata: $0) }
        #expect(values.map { $0["id"].string } == ["terminal", "chat", "job"])
        #expect(values.map { $0["kind"].string } == ["terminal", "chat", "team-job"])
        #expect(values.map { $0["view"].string } == ["terminal", "chat", "chat"])
        #expect(values[1]["seat"]["key"].string == "lead:chat")
        #expect(values[1]["agent"].string == "chat")
        for value in values { #expect(value["status"].string != nil) }
    }

    @Test func aliasesResolveOnlyWhenUnambiguousAndAnAppIDWins() throws {
        let one = row("one", cwd: "/one"), two = row("two", cwd: "/two").setting("agentSessionId", .string("provider-one"))
        #expect(try BackendSessionDirectory.resolve("tab-one", rows: [one])?["id"].string == "one")
        #expect(try BackendSessionDirectory.resolve("provider-one", rows: [one])?["id"].string == "one")
        #expect(throws: NativeRPCError.self) { try BackendSessionDirectory.resolve("provider-one", rows: [one, two]) }
        #expect(try BackendSessionDirectory.resolve("one", rows: [one, two.setting("agentSessionId", .string("one"))]) == one)
        #expect(try BackendSessionDirectory.resolve("a-chat-store-id", rows: [one]) == nil)
    }

    @Test func directoryDetailsDoNotChangeTheHelperLaunchMetadata() throws {
        // The old helper signs the encoded launch too. Display-only fields must
        // stay outside that wire shape when the app is updated before its helper.
        var input = BackendCreateSessionInput(cwd: "/work", provider: "claude")
        input.chat = true; input.origin = .copilot
        input.teamJob = .init(fromID: "lead", fromName: "Lead", agentID: "worker", agentName: "Worker", title: "Job")
        let meta = BackendSessionMeta(id: "job", input: input, spawn: .init(provider: "claude", command: "/never-run", args: [], path: "/usr/bin"))
        let wire = try NativeRPCValue.parseJSON(JSONEncoder().encode(meta))
        for field in ["kind", "view", "seat", "agent", "teamJob"] { #expect(wire[field] == .missing) }
        #expect(BackendSessionDirectory.row(meta, owner: .plain)["kind"].string == "team-job")
    }

    @Test func leadsListAndMessagePeersWithoutReadingOrControllingTheirProjects() async throws {
        let rows = [row("decker", cwd: "/deck", lead: true), row("commander", cwd: "/imatch", lead: true), row("worker", cwd: "/private")]
        let caller = BackendDeckCoreSecurityCaller(kind: .session, tiers: [.read, .act, .alter], sessionID: "decker")
        let surface = try surface(manager: .init(inheritedEnvironment: [:], onEvent: { _ in }), rows: rows)
        let listed = try await BackendDeckCoreCatalogueBuiltins.run(id: "sessions.list", arguments: .object([]), context: context(caller), surface: surface)
        #expect(Set((listed.value["sessions"].elements ?? []).compactMap { $0["id"].string }) == ["decker", "commander"])
        #expect(try BackendDeckCoreCatalogueBuiltins.requireSession(surface: surface, context: context(caller), id: "commander", message: true)["id"].string == "commander")
        #expect(throws: NativeRPCError.self) { try BackendDeckCoreCatalogueBuiltins.requireSession(surface: surface, context: context(caller), id: "commander") }
        #expect(!BackendSessionDirectory.permits(rows[2], rows: rows, caller: caller, message: true))
        let task = BackendDeckCoreSecurityCaller(kind: .session, tiers: [.read, .act], sessionID: "decker", projectRoot: "/deck", taskProject: "/deck")
        #expect(!BackendSessionDirectory.permits(rows[1], rows: rows, caller: task, message: true))
    }

    @Test func ordinaryWorkersAndKeysKeepTheirFolderLimits() {
        let rows = [row("worker", cwd: "/work"), row("child", cwd: "/work/child"), row("other", cwd: "/work-other", lead: true)]
        let caller = BackendDeckCoreSecurityCaller(kind: .session, tiers: [.read, .act], sessionID: "worker")
        #expect(BackendSessionDirectory.permits(rows[1], rows: rows, caller: caller, message: true))
        #expect(!BackendSessionDirectory.permits(rows[2], rows: rows, caller: caller, message: true))
        let key = BackendDeckCoreSecurityCaller(kind: .key, tiers: [.read, .act], folders: ["/work"])
        #expect(!BackendSessionDirectory.permits(rows[2], rows: rows, caller: key, message: true))
        #expect(BackendSessionDirectory.permits(rows[0], rows: rows, caller: caller, message: true))
    }

    @Test func grantsKeepExplicitAllowedAndBlockedToolsInCharge() throws {
        let names = BackendTAGToolPolicy.sessionNames(taskID: nil)
        for tool in ["sessions.list", "sessions.send", "sessions.get", "sessions.wait", "sessions.screen", "sessions.chat"] {
            #expect(names.contains(tool)); #expect(names.contains(tool.replacingOccurrences(of: ".", with: "_")))
        }
        let denied = BackendTAGToolPolicy.filter(names, server: "deck-control", allowed: nil, denied: ["mcp__deck-control__sessions_send"])
        #expect(!denied.contains("sessions.send") && !denied.contains("sessions_send"))
        let limited = BackendTAGToolPolicy.filter(names, server: "deck-control", allowed: ["mcp__deck-control__sessions_list"], denied: [])
        #expect(limited == ["sessions.list", "sessions_list"])
        let catalogue = try BackendDeckCoreCatalogueLiterals.builtins() + BackendDeckCoreCatalogueDescribe.tools(catalogue: { [] }).metadata
        let answer = try BackendDeckCoreCatalogueDescribe.answer(.object([.init("area", .string("sessions"))]), catalogue: catalogue,
            granted: ["tools.describe"], caller: .init(kind: .session, tiers: [.read])).value
        #expect(answer["note"].string?.contains("Tools and servers") == true)
        #expect(answer["note"].string?.contains("Blocked tools") == true)
    }

    @Test func chatStatusComesFromPendingRequestsAndBusyState() {
        #expect(BackendSessionDirectory.status(.object([.init("pending", .array([.object([])])), .init("busy", .bool(true))])) == .input)
        #expect(BackendSessionDirectory.status(.object([.init("busy", .bool(true))])) == .working)
        #expect(BackendSessionDirectory.status(.object([])) == .idle)
    }

    @Test func realChatIsListedAndReceivesSayAndSendByThatID() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-directory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("chat-fixture")
        let script = #"""
        #!/usr/bin/python3
        import sys,json
        def emit(value):
            print(json.dumps(value),flush=True)
        for raw in sys.stdin:
            value=json.loads(raw)
            if value.get('type')=='control_request':
                emit({'type':'control_response','response':{'subtype':'success','request_id':value['request_id'],'response':{}}})
            elif value.get('type')=='user':
                emit({'type':'system','subtype':'init','session_id':'isolated-provider-id'})
                emit({'type':'assistant','message':{'role':'assistant','content':[{'type':'text','text':'received in isolated chat'}]}})
                emit({'type':'result','subtype':'success','is_error':False,'session_id':'isolated-provider-id','result':'received in isolated chat'})
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let manager = BackendPTYManager(inheritedEnvironment: ["HOME": root.path, "PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude").path], onEvent: { _ in })
        let chats = BackendSessionChats(manager: manager, directory: root.appendingPathComponent("chats"), publish: { _, _ in })
        var input = BackendCreateSessionInput(cwd: root.path, provider: "claude"); input.chat = true
        let meta = try await chats.launch(input, spawn: .init(provider: "claude", command: executable.path, args: [], path: "/usr/bin:/bin", tabKey: "saved-tab"))
        do {
            let surface = try surface(manager: manager, send: { id, text in _ = try await BackendSessionDirectory.say(id, text: text, chats: chats, rows: manager.list().map { BackendSessionDirectory.row($0) }) })
            let listed = try await BackendDeckCoreCatalogueBuiltins.run(id: "sessions.list", arguments: .object([]), context: context(), surface: surface)
            let id = try #require(listed.value["sessions"].elements?.first?["id"].string)
            #expect(id == meta.id)
            let said = try await BackendSessionDirectory.say(id, text: "isolated say", chats: chats, rows: surface.listSessions())
            #expect(said["sessionId"].string == id)
            _ = try await chats.waitForTurn(id, timeout: .seconds(5))
            let peerRows = [row("decker", cwd: "/other-project", lead: true),
                BackendSessionDirectory.row(meta, owner: .init(kind: .lead, id: "imatch", name: "Commander", project: "imatch"))]
            let leadSurface = try self.surface(manager: manager, rows: peerRows, send: { target, text in
                _ = try await BackendSessionDirectory.say(target, text: text, chats: chats, rows: peerRows)
            })
            let lead = BackendDeckCoreSecurityCaller(kind: .session, tiers: [.read, .act, .alter], sessionID: "decker")
            let sent = try await BackendDeckCoreCatalogueBuiltins.run(id: "sessions.send", arguments: .object([.init("sessionId", .string(id)), .init("text", .string("isolated send"))]), context: context(lead), surface: leadSurface)
            #expect(sent.value["sessionId"].string == id)
            _ = try await chats.waitForTurn(id, timeout: .seconds(5))
            let snapshot = try await chats.read(id, cursor: nil, limit: 500)
            let text = snapshot.compact
            #expect(text.contains("isolated say")); #expect(text.contains("isolated send")); #expect(text.contains("received in isolated chat"))
            await chats.close(id)
        } catch { await chats.close(meta.id); throw error }
    }

    @Test func fix29PeerSayReturnsReceiptUntilAnIndependentReadCheckPasses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fix29-peer-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("provider")
        let script = #"""
        #!/usr/bin/python3
        import sys,json
        for raw in sys.stdin:
            v=json.loads(raw)
            if v.get('type')=='control_request':
                print(json.dumps({'type':'control_response','response':{'subtype':'success','request_id':v['request_id'],'response':{}}}),flush=True)
            elif v.get('type')=='user':
                print(json.dumps({'type':'assistant','message':{'id':'private','content':[{'type':'text','text':'recipient private answer'}]}}),flush=True)
                print(json.dumps({'type':'result','subtype':'success','is_error':False,'session_id':'isolated-peer','stop_reason':'end_turn'}),flush=True)
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let manager = BackendPTYManager(inheritedEnvironment: ["HOME": root.path, "PATH": "/usr/bin:/bin"], onEvent: { _ in })
        let chats = BackendSessionChats(manager: manager, directory: root.appendingPathComponent("chats"), publish: { _, _ in })
        var input = BackendCreateSessionInput(cwd: root.path, provider: "claude"); input.chat = true
        let meta = try await chats.launch(input, spawn: .init(provider: "claude", command: executable.path, args: [], path: "/usr/bin:/bin", tabKey: "peer-alias"))
        do {
            let rows = [BackendSessionDirectory.row(meta, owner: .init(kind: .lead, id: "peer", name: "Peer", project: "peer"))]
            _ = try await chats.say(meta.id, text: "recipient private history", clientMessageID: "private")
            _ = try await chats.waitForTurn(meta.id, timeout: .seconds(5))
            let receipt = try await BackendSessionDirectory.say("peer-alias", text: "permitted peer message", chats: chats, rows: rows,
                clientMessageID: "peer-delivery", readTarget: { throw NativeRPCError(code: "access-denied", message: "Private project") })
            #expect(receipt["accepted"].bool == true)
            #expect(receipt["sessionId"].string == meta.id)
            #expect(receipt["clientMessageId"].string == "peer-delivery")
            #expect(!receipt.compact.contains("recipient private"))
            for field in ["events", "pending", "thoughts", "children", "conversationId", "draft"] { #expect(receipt[field].isNullish) }
            _ = try await chats.waitForTurn(meta.id, timeout: .seconds(5))
            let readable = try await BackendSessionDirectory.say(meta.id, text: "ordinary access", chats: chats, rows: rows,
                clientMessageID: "readable-delivery", readTarget: {})
            #expect(readable["events"].elements?.isEmpty == false)
            await chats.close(meta.id)
        } catch { await chats.close(meta.id); throw error }
    }

    @Test func chatSendDoesNotReportSuccessWhenTheOwnerRefuses() async throws {
        let surface = try surface(manager: .init(inheritedEnvironment: [:], onEvent: { _ in }), rows: [row("chat", cwd: "/chat")],
            send: { _, _ in throw NativeRPCError(code: "busy", message: "Not accepted") })
        await #expect(throws: NativeRPCError.self) {
            try await BackendDeckCoreCatalogueBuiltins.run(id: "sessions.send", arguments: .object([.init("sessionId", .string("chat")), .init("text", .string("message"))]), context: context(), surface: surface)
        }
    }
}
