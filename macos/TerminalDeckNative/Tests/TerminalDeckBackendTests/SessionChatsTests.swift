import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

// Asad, 13 Oct: "give a switch on each new session if they want to use chat vs terminal; whatever they choose stays
// for next time", and "instead of building new screens give same as Hoot, just use same".

private final class SessionChatsEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [BackendSessionEvent] = []
    private var pushes: [String] = []
    func note(_ event: BackendSessionEvent) { lock.withLock { values.append(event) } }
    func pushed(_ id: String) { lock.withLock { pushes.append(id) } }
    var exits: [String] { lock.withLock { values.compactMap { if case .exit(let id, _) = $0 { return id }; return nil } } }
    var removed: [String] { lock.withLock { values.compactMap { if case .removed(let id, _) = $0 { return id }; return nil } } }
    var statuses: [BackendSessionStatus] { lock.withLock { values.compactMap { if case .status(_, let status) = $0 { return status }; return nil } } }
    var pushCount: Int { lock.withLock { pushes.count } }
}

@Suite("Chat sessions: the mode, the saved launch, the arguments")
struct SessionChatsRulesTests {
    /// U110 #442: a key the composer refuses is refused before a typed send is accepted (the phone is told why).
    @Test func refusedKeysAreRefusedBeforeTheSendIsAccepted() {
        for accepted in ["hello", "hello\r", "two\nlines", "\r", "\u{7f}", "\u{15}", "\u{3}", "\u{1b}", "tab\there"] {
            #expect(BackendSessionChats.keyRefusal(accepted) == nil, "\(accepted.debugDescription)")
        }
        for refused in ["\u{1b}[A", "fine\r\u{1b}[B", "\u{1}"] {
            #expect(BackendSessionChats.keyRefusal(refused)?.code == "invalid-arguments", "\(refused.debugDescription)")
        }
    }
    private func input(chat: Bool?) -> BackendCreateSessionInput {
        var input = BackendCreateSessionInput(cwd: "/work/api", provider: "claude"); input.chat = chat; return input
    }

    @Test func theSessionAndItsSavedLaunchSayChat() throws {
        let spawn = BackendSpawnSpec(provider: "claude", command: "/bin/sh", args: [], path: "/usr/bin:/bin", tabKey: "tab-1")
        let chat = BackendSessionMeta(id: "s1", input: input(chat: true), spawn: spawn)
        let terminal = BackendSessionMeta(id: "s2", input: input(chat: nil), spawn: spawn)
        #expect(chat.chat == true); #expect(terminal.chat == nil)
        let wire = try NativeRPCValue.parseJSON(JSONEncoder().encode(chat))
        #expect(wire["chat"].bool == true)
        #expect(try NativeRPCValue.parseJSON(JSONEncoder().encode(terminal))["chat"] == .missing)
        // A restart brings it back as a chat; a terminal stays a terminal.
        let saved = try BackendSessionSaved(BackendSessionSaved.from(input(chat: true)))
        #expect(saved.raw["chat"].bool == true)
        #expect(saved.input(resume: true).chat == true)
        #expect(try BackendSessionSaved(BackendSessionSaved.from(input(chat: nil))).input(resume: false).chat == nil)
        // The window's request carries it as JSON.
        let decoded = try JSONDecoder().decode(BackendCreateSessionInput.self, from: Data(#"{"cwd":"/w","cols":80,"rows":24,"provider":"codex","chat":true}"#.utf8))
        #expect(decoded.chat == true)
    }

    @Test func chatIsTheDefaultForThePersonAndForAIsNeverForARestoreAPhoneOrATaskWorker() {
        typealias Rule = BackendSessionLifecycleCoordinator
        let window = BackendLaunchContext(rememberTab: true, fromWindow: true), ai = BackendLaunchContext(rememberTab: true, fromAI: true)
        let other = BackendLaunchContext(rememberTab: true)
        // The person's window: chat until they last chose a terminal.
        #expect(Rule.choosesMode(input(chat: nil), context: window, restoring: false))
        #expect(Rule.startsAsChat(context: window, remembered: nil))
        #expect(Rule.startsAsChat(context: window, remembered: "chat"))
        #expect(!Rule.startsAsChat(context: window, remembered: "terminal"))
        // An AI's start (Hoot, a lead, sessions_start): chat, whatever the person last picked.
        #expect(Rule.choosesMode(input(chat: nil), context: ai, restoring: false))
        #expect(Rule.startsAsChat(context: ai, remembered: "terminal"))
        // Said explicitly, a restore, a replacement, a task's worker, a phone or any other start: left as it is.
        #expect(!Rule.choosesMode(input(chat: false), context: window, restoring: false))
        #expect(!Rule.choosesMode(input(chat: nil), context: window, restoring: true))
        #expect(!Rule.choosesMode(input(chat: nil), context: other, restoring: false))
        var replacing = input(chat: nil); replacing.replaces = "old"
        #expect(!Rule.choosesMode(replacing, context: window, restoring: false))
        var worker = input(chat: nil); worker.taskID = "t1"
        #expect(!Rule.choosesMode(worker, context: ai, restoring: false))
        let phone = BackendLaunchContext(deviceBoundary: .init(deviceKey: "phone", folder: "/w"), rememberTab: true, fromAI: true)
        #expect(!Rule.choosesMode(input(chat: nil), context: phone, restoring: false))
        // Who started it survives the tab being remembered or not.
        #expect(window.remembering(false).fromWindow && ai.remembering(false).fromAI)
    }

    @Test func aSessionCanRunAsASavedAgent() throws {
        let agent = NativeRPCValue.object([.init("id", .string("alex")), .init("provider", .string("codex")), .init("account", .string("work")),
            .init("model", .string("gpt-5")), .init("permissionMode", .string("workspace-write")), .init("instructionsFile", .string("alex.md")),
            .init("projectId", .string("crm"))])
        let made = try BackendAgentSessionInput.make(agent: agent, folder: "/work/crm", projectID: nil, chat: true)
        #expect(made.cwd == "/work/crm" && made.provider == "codex" && made.profileId == "work" && made.model == "gpt-5")
        #expect(made.agentProfileID == "alex")
        #expect(made.agentInstructions == "alex" && made.projectId == "crm" && made.chat == true && made.taskID == nil)
        let gemini = try BackendAgentSessionInput.make(agent: .object([.init("id", .string("g")), .init("provider", .string("gemini"))]),
                                                       folder: "/w", projectID: "p")
        #expect(gemini.agentProfileID == "g")
        #expect(gemini.agentInstructions == nil && gemini.chat == nil && gemini.projectId == "p")
        #expect(throws: (any Error).self) { try BackendAgentSessionInput.make(agent: .object([]), folder: "/w", projectID: nil) }
    }

    @Test func anAgentWithoutInstructionsKeepsItsOwnSeatAcrossRestart() async throws {
        let agent = NativeRPCValue.object([.init("id", .string("builder")), .init("provider", .string("codex")),
            .init("projectId", .string("td")), .init("name", .string("Builder")), .init("seat", .string("build"))])
        let made = try BackendAgentSessionInput.make(agent: agent, folder: "/scratch/td", projectID: "td", chat: true)
        #expect(made.agentInstructions == nil && made.agentProfileID == "builder")
        let saved = try BackendSessionSaved(BackendSessionSaved.from(made))
        #expect(saved.input(resume: true).agentProfileID == "builder")
        let owners = BackendAGTMemoryOwners(projects: { [] }, agents: { [agent] }, taskAgent: { _ in nil })
        let owner = await owners.owner(made, provider: "codex")
        #expect(owner.kind == .agent && owner.id == "build" && owner.project == "td")
        #expect(!BackendAGTMemoryOwners.openedByThePerson(made, provider: "codex", origin: nil, routine: nil))
    }

    @Test func aProgramReadsTheTurnAsWorkingNeedsPermissionDoneOrFailed() {
        func event(_ kind: HootChatKind, turn: String, text: String = "") -> NativeRPCValue {
            .object([.init("kind", .string(kind.rawValue)), .init("turnId", .string(turn)), .init("value", .object([.init("text", .string(text))]))])
        }
        func snapshot(_ events: [NativeRPCValue], busy: Bool = false, pending: [NativeRPCValue] = []) -> NativeRPCValue {
            .object([.init("events", .array(events)), .init("busy", .bool(busy)), .init("pending", .array(pending)), .init("sequence", .number(9))])
        }
        #expect(BackendSessionChats.turn(of: snapshot([])).state == .idle)
        #expect(BackendSessionChats.turn(of: snapshot([event(.user, turn: "t1", text: "go")], busy: true)).state == .working)
        let ask = NativeRPCValue.object([.init("requestId", .string("r1"))])
        #expect(BackendSessionChats.turn(of: snapshot([event(.user, turn: "t1")], busy: true, pending: [ask])).state == .needsPermission([ask]))
        let done = BackendSessionChats.turn(of: snapshot([event(.user, turn: "t0"), event(.message, turn: "t0", text: "old"),
            event(.user, turn: "t1"), event(.message, turn: "t1", text: "first"), event(.message, turn: "t1", text: "final"), event(.completed, turn: "t1")]))
        #expect(done.state == .done(answer: "final") && done.turnID == "t1" && done.cursor == 9)
        #expect(BackendSessionChats.turn(of: snapshot([event(.user, turn: "t1"), event(.error, turn: "t1", text: "no login")])).state == .failed(reason: "no login"))
        #expect(BackendSessionChats.wire(done)["state"].string == "done")
        #expect(BackendSessionChats.wire(done)["answer"].string == "final")
    }

    @Test func thePicksUnderTheBoxReplaceTheLaunchsOwn() {
        let claude = BackendSessionChats.withChoices(["--model", "opus", "--dangerously-skip-permissions", "--effort", "high"], provider: .claude,
                                                     choices: ["model": "sonnet", "effort": "max", "permission": "acceptEdits"])
        #expect(claude == ["--model", "sonnet", "--effort", "max", "--permission-mode", "acceptEdits"])
        let codex = BackendSessionChats.withChoices(["-m", "gpt-5", "-c", "model_reasoning_effort=\"low\"", "--sandbox", "read-only", "--ask-for-approval", "on-request"],
                                                    provider: .codex, choices: ["effort": "high", "permission": "danger-full-access"])
        #expect(codex == ["-m", "gpt-5", "-c", "model_reasoning_effort=\"high\"", "--sandbox", "danger-full-access", "--ask-for-approval", "never"])
        #expect(BackendSessionChats.effort(provider: .codex, arguments: codex) == "high")
        #expect(BackendSessionChats.withChoices(["--yolo"], provider: .gemini, choices: ["permission": "default"]).isEmpty)
    }

    @Test func theSlashMenuShowsWhatTheAIItselfOffers() {
        let offered = BackendHootChatStore.offeredCommands(.array([
            .object([.init("name", .string("/compact")), .init("description", .string("Compact the conversation")), .init("argumentHint", .string("<focus>"))]),
            .string("recover"), .string("recover"), .string("")]))
        #expect(offered.map { $0["name"].string } == ["compact", "recover"])
        #expect(offered.first?["description"].string == "Compact the conversation")
        #expect(offered.first?["argumentHint"].string == "<focus>")
    }

    @Test func claudeStartsInItsChatModeAndStartsAgainInTheSameConversation() throws {
        let recipe = BackendSessionChats.Recipe(provider: .claude, executable: "/bin/claude",
            arguments: ["--session-id", "conv-1", "--mcp-config", "/tmp/tools.json", "--permission-mode", "acceptEdits"],
            environment: [:], cwd: "/work/api", conversation: "conv-1")
        let first = try BackendSessionChats.plan(recipe, cliSession: nil, again: false).arguments
        #expect(first.starts(with: ["--print", "--output-format", "stream-json", "--input-format", "stream-json"]))
        #expect(first.contains("--session-id") && first.contains("conv-1") && !first.contains("--resume"))
        #expect(first.contains("--mcp-config"))
        let again = try BackendSessionChats.plan(recipe, cliSession: "cli-9", again: true).arguments
        #expect(Array(again.suffix(2)) == ["--resume", "cli-9"])
        #expect(!again.contains("--session-id"))
        let fallback = try BackendSessionChats.plan(recipe, cliSession: nil, again: true).arguments
        #expect(Array(fallback.suffix(2)) == ["--resume", "conv-1"])
        #expect(BackendSessionChats.claudeExtra(["--dangerously-skip-permissions", "--model", "opus"]) == ["--model", "opus", "--permission-mode", "bypassPermissions"])
        #expect(BackendSessionChats.withoutConversation(["--continue", "--model", "opus", "--resume", "x"]) == ["--model", "opus"])
    }

    @Test func restartBeforeFirstMessageStartsTheSameConversationAgain() throws {
        // 2 Nov (web v1 live): a new chat's model/account change before its first message restarted Claude with
        // --resume of a conversation Claude never saved ("No conversation found with session ID").
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("td-claude-saved-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: config) }
        let folder = config.appendingPathComponent("projects/-work-new-app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let recipe = BackendSessionChats.Recipe(provider: .claude, executable: "/bin/claude", arguments: ["--session-id", "conv-2"],
            environment: ["CLAUDE_CONFIG_DIR": config.path], cwd: "/work/new.app", conversation: "conv-2")
        let unsaved = try BackendSessionChats.plan(recipe, cliSession: "conv-2", again: true).arguments
        #expect(!unsaved.contains("--resume") && unsaved.firstIndex(of: "--session-id").map { unsaved[$0 + 1] } == "conv-2")
        try Data("{}\n".utf8).write(to: folder.appendingPathComponent("conv-2.jsonl"))
        let saved = try BackendSessionChats.plan(recipe, cliSession: "conv-2", again: true).arguments
        #expect(Array(saved.suffix(2)) == ["--resume", "conv-2"])
    }

    /// Review chat-backend #4: a fork Chat relaunched before it has its own conversation ID is still a fork of its parent.
    @Test func aClaudeForkRelaunchedBeforeItsFirstMessageStaysAForkOfItsParent() throws {
        let recipe = BackendSessionChats.Recipe(provider: .claude, executable: "/bin/claude",
            arguments: ["--resume", "parent-1", "--fork-session", "--permission-mode", "acceptEdits"],
            environment: [:], cwd: "/work/api", conversation: nil)
        let again = try BackendSessionChats.plan(recipe, cliSession: nil, again: true).arguments
        #expect(again.contains("--fork-session"))
        #expect(again.firstIndex(of: "--resume").map { again[$0 + 1] } == "parent-1")
        // Once the fork has its own conversation, a restart resumes that one and no longer forks.
        let later = try BackendSessionChats.plan(recipe, cliSession: "fork-7", again: true).arguments
        #expect(!later.contains("--fork-session"))
        #expect(Array(later.suffix(2)) == ["--resume", "fork-7"])
    }

    @Test func codexAndGeminiKeepOnlyWhatTheirAppModesTake() {
        let codex = BackendSessionChats.rpcExtra(["-m", "gpt-5", "--sandbox", "workspace-write", "-c", "mcp_servers.deck.url=x",
                                                  "-c", "model_reasoning_effort=high", "resume", "--last"], provider: .codex)
        #expect(codex == ["-m", "gpt-5", "--sandbox", "workspace-write", "-c", "model_reasoning_effort=high"])
        let gemini = BackendSessionChats.rpcExtra(["--yolo", "--model", "gemini-3", "--resume", "latest"], provider: .gemini)
        #expect(gemini == ["--yolo", "--model", "gemini-3"])
    }

    @Test func permissionsAreAnsweredAsTheSessionWasStarted() {
        #expect(BackendSessionChats.permissionPolicy(provider: .claude, arguments: ["--permission-mode", "acceptEdits"]) == "acceptEdits")
        #expect(BackendSessionChats.permissionPolicy(provider: .claude, arguments: ["--dangerously-skip-permissions"]) == "bypassPermissions")
        #expect(BackendSessionChats.permissionPolicy(provider: .claude, arguments: []) == nil)
        #expect(BackendSessionChats.permissionPolicy(provider: .codex, arguments: ["--sandbox", "danger-full-access"]) == "danger-full-access")
        #expect(BackendSessionChats.permissionPolicy(provider: .gemini, arguments: ["-y"]) == "yolo")
    }

    @Test func eachTabKeepsItsOwnConversationFolder() {
        let folder = URL(fileURLWithPath: "/data/session-chats")
        #expect(BackendSessionChats.tabFolder(folder, key: "df137fa0-2f58").lastPathComponent == "df137fa0-2f58")
        #expect(BackendSessionChats.tabFolder(folder, key: "../x/y").lastPathComponent == "___x_y")
        let tab = BackendSessionChats.tabFolder(folder, key: "t")
        #expect(BackendSessionChats.historyFile(tab, provider: .claude).lastPathComponent == "chat.json")
        #expect(BackendSessionChats.historyFile(tab, provider: .codex).lastPathComponent == "chat-codex.json")
    }
}

@Suite("Chat sessions: a real conversation through the session manager", .serialized)
struct SessionChatsLiveTests {
    /// A stand-in for Claude Code's print mode: the handshake, then one answer per message.
    private static let fakeClaude = #"""
    #!/bin/sh
    read init
    id=$(printf '%s' "$init" | /usr/bin/sed -E 's/.*"request_id":"([^"]*)".*/\1/')
    printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{}}}\n' "$id"
    while read line; do
      printf '{"type":"system","subtype":"init","session_id":"fake-conv"}\n'
      printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"pong"}]}}\n'
      printf '{"type":"result","subtype":"success","is_error":false,"session_id":"fake-conv","result":"pong"}\n'
    done
    """#

    private func until(_ check: @escaping () async -> Bool) async -> Bool {
        let limit = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < limit { if await check() { return true }; try? await Task.sleep(for: .milliseconds(50)) }
        return await check()
    }

    @Test func anExplicitAskModeOverridesInheritedBypassOnTheFirstLaunch() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("web-chat-mode-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("claude")
        let body = Self.fakeClaude.replacingOccurrences(of: "#!/bin/sh", with: "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$0.argv\"")
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let manager = BackendPTYManager(inheritedEnvironment: ["PATH": "/usr/bin:/bin"]) { _ in }
        let chats = BackendSessionChats(manager: manager, directory: root.appendingPathComponent("chats"), publish: { _, _ in })
        var input = BackendCreateSessionInput(cwd: root.path, provider: "claude")
        input.chat = true; input.permissionMode = "default"
        let spawn = BackendSpawnSpec(provider: "claude", command: script.path, args: ["--dangerously-skip-permissions"], path: "/usr/bin:/bin")
        let meta = try await chats.launch(input, spawn: spawn)
        defer { Task { await chats.close(meta.id) } }
        #expect(try await chats.options(meta.id)["permissionMode"].string == "ask")
        let arguments = try String(contentsOfFile: script.path + ".argv", encoding: .utf8)
        #expect(!arguments.contains("--dangerously-skip-permissions"))
    }

    @Test func aChatSessionIsListedNamedTypedIntoClosedAndComesBackWithItsConversation() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("td-chat-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("claude")
        try Data(Self.fakeClaude.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let events = SessionChatsEvents()
        let manager = BackendPTYManager(inheritedEnvironment: ["PATH": "/usr/bin:/bin"]) { events.note($0) }
        let folder = root.appendingPathComponent("chats")
        let chats = BackendSessionChats(manager: manager, directory: folder, publish: { id, _ in events.pushed(id) })
        var input = BackendCreateSessionInput(cwd: root.path, provider: "claude"); input.chat = true
        let spawn = BackendSpawnSpec(provider: "claude", command: script.path, args: ["--session-id", "conv-1"], path: "/usr/bin:/bin",
                                     agentSessionId: "conv-1", tabKey: "tab-1")
        let meta = try await chats.launch(input, spawn: spawn)
        #expect(meta.chat == true)
        #expect(manager.isChat(meta.id))
        #expect(manager.list().first { $0.id == meta.id }?.chat == true)

        // The window's message, answered; the status dot follows the turn; a tool reads it as the session's screen.
        _ = try await chats.say(meta.id, text: "ping")
        #expect(await until { manager.screen(meta.id)?.contains("pong") == true })
        #expect(manager.screen(meta.id)?.contains("You: ping") == true)
        #expect(events.statuses.contains(.working))
        #expect(events.pushCount > 0)
        // Named like any session; typed into from elsewhere (sessions_send): a message.
        #expect(manager.rename(meta.id, title: "API chat"))
        #expect(manager.list().first { $0.id == meta.id }?.title == "API chat")
        try manager.write(meta.id, data: "again\r")
        #expect(await until { manager.screen(meta.id)?.contains("You: again") == true })
        try manager.write(meta.id, data: "\r")   // a lone Return is nothing

        // Closed: its AI ends, the session leaves the list, the conversation stays on disk.
        manager.kill(meta.id)
        #expect(manager.list().isEmpty)
        #expect(events.exits.contains(meta.id) && events.removed.contains(meta.id))
        let tab = BackendSessionChats.tabFolder(folder, key: "tab-1")
        #expect(FileManager.default.fileExists(atPath: BackendSessionChats.historyFile(tab, provider: .claude).path))

        // The app opens again: the same tab starts as a chat with the conversation so far.
        let reopened = BackendSessionChats(manager: manager, directory: folder, publish: { _, _ in })
        let again = try await reopened.launch(input, spawn: spawn)
        let history = try await reopened.read(again.id, cursor: nil, limit: 500)
        let texts = (history["events"].elements ?? []).compactMap { $0["value"]["text"].string }
        #expect(texts.contains("ping") && texts.contains("pong"))

        // A program drives it: send, wait for the turn, read the answer.
        _ = try await reopened.say(again.id, text: "status?")
        let turn = try await reopened.waitForTurn(again.id, timeout: .seconds(8))
        #expect(turn.state == .done(answer: "pong"))

        // Another account takes the same tab over: the AI starts clean and its next message carries the conversation.
        var other = spawn; other.profile = BackendAccountIdentity(id: "work", name: "Work")
        let switched = try await reopened.launch(input, spawn: other)
        #expect(!manager.list().contains { $0.id == again.id })
        #expect(await reopened.isChat(again.id) == false)   // one conversation, one place: the old one ended first
        _ = try await reopened.say(switched.id, text: "hi")
        #expect(await until { manager.screen(switched.id)?.contains("You: hi") == true })
        manager.kill(again.id); manager.kill(switched.id)
    }
}
