import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Leftovers20: chat deletion, drafts, agent definitions and Gemini", .serialized)
struct Leftovers20Tests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("td-leftovers20-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func fixture(_ root: URL) throws -> (BackendPTYManager, BackendSessionChats, BackendSpawnSpec) {
        let cli = root.appendingPathComponent("fake-claude")
        let script = #"""
        #!/bin/sh
        read init
        id=$(printf '%s' "$init" | /usr/bin/sed -E 's/.*"request_id":"([^"]*)".*/\1/')
        printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{}}}\n' "$id"
        while read line; do
          printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}\n'
          printf '{"type":"result","subtype":"success","is_error":false,"result":"done"}\n'
        done
        """#
        try Data(script.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let manager = BackendPTYManager(inheritedEnvironment: ["PATH": "/usr/bin:/bin"]) { _ in }
        return (manager, BackendSessionChats(manager: manager, directory: root.appendingPathComponent("chats"), publish: { _, _ in }),
                BackendSpawnSpec(provider: "claude", command: cli.path, args: [], path: "/usr/bin:/bin", tabKey: "ordinary-tab"))
    }

    @Test func typingWaitsInTheComposerUntilEnterAndPreservesSpaces() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (manager, chats, spawn) = try fixture(root)
        let meta = try await chats.launch(.init(cwd: root.path, provider: "claude"), spawn: spawn)
        try await BackendDeckToolsSessionsTyping.typeLine(write: { try await chats.type(meta.id, data: $0) }, text: "  hello  ", submit: false, sleep: { _ in })
        var read = try await chats.read(meta.id, cursor: nil, limit: 500)
        #expect(read["draft"].string == "  hello  ")
        #expect(read["events"].elements?.contains { $0["kind"].string == "user" } == false)
        let keys = try BackendDeckToolsSessionsTyping.resolveKeys(.array([.string("x"), .string("backspace"), .string("enter")]))
        try await BackendDeckToolsSessionsTyping.pressKeys(write: { try await chats.type(meta.id, data: $0) }, keys: keys, sleep: { _ in })
        #expect(try await chats.waitForTurn(meta.id, timeout: .seconds(5)).state == .done(answer: "done"))
        read = try await chats.read(meta.id, cursor: nil, limit: 500)
        #expect(read["draft"].string == "")
        #expect(read["events"].elements?.filter { $0["kind"].string == "user" }.count == 1)
        #expect(read["events"].elements?.first { $0["kind"].string == "user" }?["value"]["text"].string == "  hello  ")
        try await chats.type(meta.id, data: "clear me")
        try await chats.type(meta.id, data: "\u{15}")
        #expect(try await chats.read(meta.id, cursor: nil, limit: 500)["draft"].string == "")
        await chats.close(meta.id); manager.killAll()
    }

    @Test func deletingAnOrdinarySessionRemovesAllProviderHistoriesButClosingForReopenKeepsThem() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (manager, chats, spawn) = try fixture(root)
        let meta = try await chats.launch(.init(cwd: root.path, provider: "claude"), spawn: spawn)
        _ = try await chats.say(meta.id, text: "save me")
        _ = try await chats.waitForTurn(meta.id, timeout: .seconds(5))
        let folder = root.appendingPathComponent("chats/ordinary-tab")
        await chats.close(meta.id)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("chat.json").path))
        try Data("other provider history".utf8).write(to: folder.appendingPathComponent("chat-gemini.json"))
        // The same tab may now be Terminal. Deletion still uses its tab key.
        var terminal = meta; terminal.chat = false
        try await chats.removeSession(terminal)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        manager.killAll()
    }

    @Test func teamHistorySurvivesTabRemovalAndIsDeletedOnlyByItsEntry() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (manager, chats, spawn) = try fixture(root)
        var input = BackendCreateSessionInput(cwd: root.path, provider: "claude")
        input.teamJob = .init(fromID: "hoot", fromName: "Hoot", agentID: "builder", agentName: "Builder", title: "Job")
        let meta = try await chats.launch(input, spawn: spawn)
        await #expect(throws: (any Error).self) { try await chats.deleteJobHistory(meta.id) }
        try await chats.finishJob(meta.id, result: "Kept", failed: false)
        try await chats.removeSession(meta)
        let folder = root.appendingPathComponent("chats/" + meta.id)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("job.json").path))
        #expect(await chats.conversation(meta.id) != nil)
        let restored = BackendSessionChats(manager: manager, directory: root.appendingPathComponent("chats"), publish: { _, _ in })
        try await restored.restoreJobHistory()
        #expect(await restored.conversation(meta.id) != nil)
        try await restored.deleteJobHistory(meta.id)
        #expect(await restored.conversation(meta.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(!manager.list().contains { $0.id == meta.id })
        manager.killAll()
    }

    /// 18 Oct (#433): Ctrl-C in a team job's chat interrupts the answer, as in a terminal; the job stays open.
    @Test func ctrlCInATeamJobInterruptsWithoutFinishingTheJob() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (manager, chats, spawn) = try fixture(root)
        var input = BackendCreateSessionInput(cwd: root.path, provider: "claude")
        input.teamJob = .init(fromID: "hoot", fromName: "Hoot", agentID: "builder", agentName: "Builder", title: "Job")
        let meta = try await chats.launch(input, spawn: spawn)
        try await chats.type(meta.id, data: "\u{3}")
        let read = try await chats.read(meta.id, cursor: nil, limit: 500)
        #expect(read["readOnly"].bool == false)
        #expect(await chats.conversation(meta.id)?.isFinished == false)
        _ = try await chats.say(meta.id, text: "carry on")
        #expect(try await chats.waitForTurn(meta.id, timeout: .seconds(5)).state == .done(answer: "done"))
        await chats.close(meta.id); manager.killAll()
    }

    /// 18 Oct (#424, #444): a finished job's history is read through the cache and that cache goes with the job.
    @Test func finishedJobHistoryIsCachedAndForgottenWhenDeleted() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (manager, chats, spawn) = try fixture(root)
        var input = BackendCreateSessionInput(cwd: root.path, provider: "claude")
        input.teamJob = .init(fromID: "hoot", fromName: "Hoot", agentID: "builder", agentName: "Builder", title: "Job")
        let meta = try await chats.launch(input, spawn: spawn)
        _ = try await chats.say(meta.id, text: "remember me")
        _ = try await chats.waitForTurn(meta.id, timeout: .seconds(5))
        try await chats.finishJob(meta.id, result: "Kept", failed: false)
        try await chats.removeSession(meta)
        for _ in 0..<2 {
            let read = try await chats.read(meta.id, cursor: nil, limit: 500)
            #expect(read["events"].elements?.first { $0["kind"].string == "user" }?["value"]["text"].string == "remember me")
        }
        let sequence = try #require(try await chats.read(meta.id, cursor: nil, limit: 500)["events"].elements?
            .first { $0["kind"].string == "user" }?["sequence"].number)
        _ = try await chats.handoffPrompt(meta.id, sequence: Int(sequence))
        try await chats.deleteJobHistory(meta.id)
        await #expect(throws: (any Error).self) { _ = try await chats.read(meta.id, cursor: nil, limit: 500) }
        manager.killAll()
    }

    @Test func dialogAgentInputUsesTheTaskEnginesOwnedDefinitionPreparation() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("project/.claude/agents/lead.md")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("---\nname: lead\ndescription: Lead with helpers\n---\nUse the helper in .claude/agents/helper.md.\n".utf8).write(to: source)
        try Data("---\nname: helper\ndescription: Helper\n---\nHelp the lead.\n".utf8).write(to: source.deletingLastPathComponent().appendingPathComponent("helper.md"))
        let specs = try BackendTaskPersistence(directory: root.appendingPathComponent("remote/task-briefs"), ownership: .exclusive)
        let agent = NativeRPCValue.object([.init("id", .string("lead-profile")), .init("claudeAgent", .string("lead")), .init("sourceFile", .string(source.path))])
        for chat in [true, false] {
            let input = try BackendAgentSessionInput.make(agent: agent, folder: root.path, projectID: "p", chat: chat, specs: specs)
            let file = try #require(input.agentDefinitionsFile)
            let args = try BackendTAGAgentDefinitionLaunch.arguments(file: file, storageRoot: root.appendingPathComponent("remote"), name: "lead")
            let definition = try NativeRPCValue.parseJSON(Data(args[1].utf8))
            #expect(input.provider == "claude" && input.claudeAgent == "lead")
            #expect(definition["lead"]["prompt"].string?.contains(source.path) == true)
            #expect(definition["lead"]["prompt"].string?.contains(".claude/agents/helper.md") == true)
        }
    }

    @Test func codexStatusKeepsAnEmailWhenTheCLIReportsOne() {
        let report = BackendAppAccountSignInParsing.codex("Logged in using ChatGPT\nEmail: person@example.test")
        #expect(report?.account == "person@example.test" && report?.plan == "ChatGPT")
        #expect(BackendAppAccountSignInParsing.codex("Logged in using ChatGPT")?.account == nil)
        #expect(BackendAppAccountSignInParsing.codex("Not logged in\nEmail: stale@example.test")?.loggedIn == false)
    }

    @Test func geminiHistoryWithoutAResumableIdUsesTheExistingWordForWordHandover() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try BackendHootChatStore(file: root.appendingPathComponent("chat-gemini.json"), provider: .gemini)
        let texts = ["Remember: blue lantern.\nKeep this line too.", "Blue lantern remembered."]
        try await store.seedTerminalHistory([
            .init(role: .user, text: texts[0], at: nil, key: "u"),
            .init(role: .assistant, text: texts[1], at: nil, key: "a")], conversation: nil)
        #expect(await store.cliSessionID == nil)
        #expect(await store.handoverPending)
        let messages = await store.recentMessages()
        let handover = try #require(BackendHootHandover.text(from: "gemini", messages: messages))
        #expect(texts.allSatisfy { handover.contains($0) })
        let reopened = try BackendHootChatStore(file: root.appendingPathComponent("chat-gemini.json"), provider: .gemini)
        #expect(await reopened.handoverPending)
        #expect(await reopened.recentMessages().map(\.text) == texts)
    }

    @Test func geminiUsesACPResumeOrCarriesTheHistoryWhenACPHasNoLoadSupport() throws {
        func hello(load: Bool) -> NativeRPCValue {
            .object([.init("id", .string("h")), .init("result", .object([.init("protocolVersion", .number(1)),
                .init("agentCapabilities", .object([.init("loadSession", .bool(load))]))]))])
        }
        for load in [true, false] {
            var rpc = BackendHootChatRPC(provider: .gemini, setup: .init(cwd: "/work"))
            _ = try rpc.begin(id: "h", resume: "existing")
            let update = try rpc.receive(hello(load: load))
            #expect(update.send.first?["method"].string == (load ? "session/load" : "session/new"))
            #expect(update.carryHistory == !load)
            if load { #expect(update.send.first?["params"]["sessionId"].string == "existing") }
        }
    }
}
