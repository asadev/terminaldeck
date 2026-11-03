import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// 28 Oct (Asad, a ClaudeCRM chat: "no other models in the list"): a chat kept by the session host offered only its
/// launch model ("opus"), because the host keeps no account store and so never has the Claude list. The app fills in
/// its own live list; every place (the Mac's box, a phone's Select model) offers the account's whole list.
@Suite("Chat model list: every model the account can use, also for a chat the session host keeps")
struct ChatModelListTests {
    private static func row(_ id: String, _ name: String, window: Double = 200_000) -> NativeRPCValue {
        .object([.init("id", .string(id)), .init("name", .string(name)), .init("efforts", .array([.string("high"), .string("xhigh")])),
                 .init("contextWindow", .number(window)), .init("maxContextWindow", .null), .init("oneMillion", .bool(window >= 1_000_000))])
    }
    /// The app's live catalogue (what Anthropic's list gives through a login the app keeps, and the Codex CLI's cache).
    static let appCatalogue: NativeRPCValue = .object([
        .init("claude", .object([
            .init("models", .array([row("claude-opus-5-5", "Opus 5.5"), row("claude-sonnet-5", "Sonnet 5"), row("claude-haiku-4-5", "Haiku 4.5"),
                                    row("claude-fable-5-1", "Fable 5.1"), row("claude-opus-4-1", "Opus 4.1")])),
            .init("featured", .array(["claude-opus-5-5", "claude-sonnet-5", "claude-haiku-4-5", "claude-fable-5-1"].map(NativeRPCValue.string))),
            .init("more", .array([.string("claude-opus-4-1")])), .init("defaultModel", .null), .init("current", .null), .init("fastMode", .null)])),
        .init("codex", .object([.init("models", .array([row("gpt-6.1-sol", "GPT-6.1 Sol")])), .init("featured", .array([.string("gpt-6.1-sol")])),
                                .init("more", .array([])), .init("fastMode", .null)])),
        .init("gemini", .object([.init("models", .array([])), .init("featured", .array([])), .init("more", .array([]))]))])

    /// What a session host answers today for a chat started with `--model opus[1m]`: no list, only that model.
    static let hostAnswer: NativeRPCValue = .object([
        .init("permissionMode", .string("bypass")),
        .init("catalog", .object([.init("claude", .object([.init("models", .array([])), .init("featured", .array([])), .init("more", .array([])),
            .init("fastMode", .object([.init("available", .bool(true)), .init("on", .bool(false))]))]))])),
        .init("fastMode", .bool(false)), .init("model", .string("claude:opus[1m]")),
        .init("models", .array([.object([.init("id", .string("claude:opus[1m]")), .init("provider", .string("Claude Code")), .init("name", .string("opus"))])])),
        .init("ready", .bool(true)), .init("effort", .string("xhigh")), .init("efforts", .array(["low", "medium", "high", "xhigh", "max"].map(NativeRPCValue.string)))])

    @Test func aHostedChatOffersTheAccountsWholeListAndKeepsItsOwnReading() {
        let merged = BackendSessionChats.withLiveModels(Self.hostAnswer, catalogue: Self.appCatalogue)
        let section = merged["catalog"]["claude"]
        #expect((section["featured"].elements ?? []).compactMap(\.string) == ["claude-opus-5-5", "claude-opus-5-5[1m]", "claude-sonnet-5", "claude-sonnet-5[1m]",
                                                                        "claude-haiku-4-5", "claude-fable-5-1", "claude-fable-5-1[1m]"])
        #expect((section["more"].elements ?? []).compactMap(\.string) == ["claude-opus-4-1"], "older models stay under More models")
        let names = (merged["models"].elements ?? []).compactMap { $0["name"].string }
        #expect(names == ["Opus 5.5", "Opus 5.5 1M", "Sonnet 5", "Sonnet 5 1M", "Haiku 4.5", "Fable 5.1", "Fable 5.1 1M", "Opus 4.1", "Opus 1M"],
                "every model the account can use, named as Claude Code names them; the alias in use reads as a name, not \"opus\"")
        // The host's own reading of this session stays exactly as it said.
        #expect(merged["model"].string == "claude:opus[1m]" && merged["effort"].string == "xhigh" && merged["permissionMode"].string == "bypass")
        #expect(section["fastMode"]["available"].bool == true && section["fastMode"]["on"].bool == false, "Fast mode is the session's, from the host")
        #expect(merged["efforts"] == Self.hostAnswer["efforts"], "effort stays its own choice")
        // The alias in use ticks the 1M choice of its line; a bare alias the newest of its line.
        #expect(BackendSessionChats.liveModel(forAlias: "opus[1m]", in: section) == "claude-opus-5-5[1m]")
        #expect(BackendSessionChats.liveModel(forAlias: "opus", in: section) == "claude-opus-5-5")
        #expect(BackendSessionChats.liveModel(forAlias: "opusplan", in: section) == "claude-opus-5-5")
        #expect(BackendSessionChats.liveModel(forAlias: "haiku[1m]", in: section) == "claude-haiku-4-5", "no 1M choice: the line's model")
        #expect(BackendSessionChats.liveModel(forAlias: "claude-opus-5-5", in: section) == nil, "a full id is not an alias")
        #expect(BackendSessionChats.liveModel(forAlias: "default", in: section) == nil)
    }

    @Test func aListTheHostAlreadyHasStaysAndNothingIsInventedWhereNoListExists() {
        // A Codex chat: the host reads the CLI's own cache, so its list stays.
        let codex = NativeRPCValue.object([.init("model", .string("codex:gpt-6-luna")),
            .init("catalog", .object([.init("codex", .object([.init("models", .array([Self.row("gpt-6-luna", "GPT-6 Luna")])),
                                                              .init("featured", .array([.string("gpt-6-luna")]))]))])),
            .init("models", .array([.object([.init("id", .string("codex:gpt-6-luna")), .init("name", .string("GPT-6 Luna"))])]))])
        let kept = BackendSessionChats.withLiveModels(codex, catalogue: Self.appCatalogue)
        #expect((kept["catalog"]["codex"]["featured"].elements ?? []).compactMap(\.string) == ["gpt-6-luna"])
        #expect((kept["models"].elements ?? []).compactMap { $0["id"].string } == ["codex:gpt-6-luna"])
        // Gemini's CLI gives no list: its current model only, unchanged.
        let gemini = NativeRPCValue.object([.init("model", .string("gemini:gemini-3-pro")),
            .init("catalog", .object([.init("gemini", .object([.init("models", .array([]))]))])),
            .init("models", .array([.object([.init("id", .string("gemini:gemini-3-pro")), .init("name", .string("gemini-3-pro"))])]))])
        #expect(BackendSessionChats.withLiveModels(gemini, catalogue: Self.appCatalogue) == gemini)
        // No list in the app either (the account store has not answered yet): the host's answer, unchanged.
        #expect(BackendSessionChats.withLiveModels(Self.hostAnswer, catalogue: .object([])) == Self.hostAnswer)
    }

    @Test func aPhoneGetsTheSameWholeListWithTheModelInUseTicked() throws {
        let merged = BackendSessionChats.withLiveModels(Self.hostAnswer, catalogue: Self.appCatalogue)
        let frame = try BackendPhoneChats.optionsFrame("chat-1", merged)
        let ids = (frame.value["options"]["models"].elements ?? []).compactMap { $0["id"].string }
        #expect(ids == ["claude:claude-opus-5-5", "claude:claude-opus-5-5[1m]", "claude:claude-sonnet-5", "claude:claude-sonnet-5[1m]",
                        "claude:claude-haiku-4-5", "claude:claude-fable-5-1", "claude:claude-fable-5-1[1m]", "claude:claude-opus-4-1"],
                "the alias in use is not listed twice")
        #expect(frame.value["options"]["model"].string == "claude:claude-opus-5-5[1m]", "the sheet ticks Opus 5.5 1M")
        let million = frame.value["options"]["models"].elements?[1]
        #expect(million?["name"].string == "Opus 5.5 1M" && million?["detail"].string == "Newest of its line · 1M context")
        #expect(frame.value["options"]["models"].elements?.last?["more"].bool == true, "Opus 4.1 under More models")
        // A model in use that the list does not have still shows, as in use.
        let other = merged.setting("model", .string("claude:claude-opus-4")).setting("models", .array([
            .object([.init("id", .string("claude:claude-opus-4")), .init("name", .string("Opus 4"))])]))
        let otherFrame = try BackendPhoneChats.optionsFrame("chat-1", other)
        #expect(otherFrame.value["options"]["model"].string == "claude:claude-opus-4")
        #expect(otherFrame.value["options"]["models"].elements?.last?["detail"].string == "In use now")
    }

    @Test func namesAreTheOnesClaudeCodeUses() {
        #expect(BackendHootReadyDefaults.shortModelName("opus[1m]", provider: .claude) == "Opus 1M")
        #expect(BackendHootReadyDefaults.shortModelName("opus", provider: .claude) == "Opus")
        #expect(BackendHootReadyDefaults.shortModelName("claude-opus-5-5", provider: .claude) == "Opus 5.5")
        #expect(BackendHootReadyDefaults.shortModelName("claude-opus-5-5[1m]", provider: .claude) == "Opus 5.5 1M")
        #expect(BackendHootReadyDefaults.shortModelName("gpt-6-luna", provider: .codex) == "gpt-6-luna")
    }

    /// Claude Code's handshake `models`, in the shape the installed CLI (2.1.310) sends.
    static let handshake = NativeRPCValue.array([
        .object([.init("value", .string("default")), .init("resolvedModel", .string("claude-opus-5-5")), .init("displayName", .string("Default (recommended)")),
                 .init("description", .string("Opus 5.5 · Best for everyday, complex tasks"))]),
        .object([.init("value", .string("opus")), .init("resolvedModel", .string("claude-opus-5-5")), .init("displayName", .string("Opus")),
                 .init("description", .string("Opus 5.5 · Best for everyday, complex tasks")), .init("supportedEffortLevels", .array([.string("high")]))]),
        .object([.init("value", .string("fable")), .init("resolvedModel", .string("claude-fable-5-1")), .init("displayName", .string("Fable")),
                 .init("description", .string("Fable 5.1 · Most capable for your hardest and longest-running tasks"))]),
        .object([.init("value", .string("haiku")), .init("resolvedModel", .string("claude-haiku-5-5")), .init("displayName", .string("Haiku")),
                 .init("description", .string("Haiku 5.5 · Fastest for quick answers"))]),
        .object([.init("value", .string("rm -rf /")), .init("displayName", .string("Bad"))]),
        .object([.init("value", .string("opus")), .init("displayName", .string("Opus again"))])])

    @Test func withThisMacsOwnSignInTheListIsClaudeCodesOwn() throws {
        let models = BackendHootChatStore.offeredCLIModels(Self.handshake)
        #expect(models.compactMap { $0["id"].string } == ["opus", "fable", "haiku"], "no Default, nothing unsafe, no repeats")
        #expect(models.first?["name"].string == "Opus" && models.first?["resolvedModel"].string == "claude-opus-5-5")
        let section = BackendSessionChats.withMillionChoices(BackendSessionChats.cliSection(.array(models), base: .object([])), provider: .claude)
        #expect(section["source"].string == "cli")
        #expect((section["featured"].elements ?? []).compactMap(\.string) == ["opus", "opus[1m]", "fable", "fable[1m]", "haiku"])
        #expect(BackendSessionChats.offeredModels(section, provider: .claude).compactMap { $0["name"].string } == ["Opus", "Opus 1M", "Fable", "Fable 1M", "Haiku"])
        // The model the CLI reports in use is the choice that means it.
        #expect(BackendSessionChats.liveModel(forAlias: "claude-opus-5-5", in: section) == "opus")
        #expect(BackendSessionChats.liveModel(forAlias: "claude-opus-5-5[1m]", in: section) == "opus[1m]")
        // A phone gets the same list, each with Claude Code's own line.
        let answer = NativeRPCValue.object([.init("model", .string("claude:opus[1m]")), .init("catalog", .object([.init("claude", section)])),
            .init("models", .array(BackendSessionChats.offeredModels(section, provider: .claude)))])
        let frame = try BackendPhoneChats.optionsFrame("chat-1", answer)
        let rows = frame.value["options"]["models"].elements ?? []
        #expect(rows.compactMap { $0["id"].string } == ["claude:opus", "claude:opus[1m]", "claude:fable", "claude:fable[1m]", "claude:haiku"])
        #expect(rows[1]["detail"].string == "Opus 5.5 · Best for everyday, complex tasks · 1M context")
        #expect(frame.value["options"]["model"].string == "claude:opus[1m]")
        // A newer host answers with this short list; the account's list through a login the app keeps wins.
        let hosted = BackendSessionChats.withLiveModels(answer, catalogue: Self.appCatalogue)
        #expect((hosted["catalog"]["claude"]["featured"].elements ?? []).first?.string == "claude-opus-5-5")
        #expect(!(hosted["models"].elements ?? []).contains { $0["id"].string == "claude:fable" }, "the CLI's aliases are not listed twice")
        #expect(BackendSessionChats.withLiveModels(answer, catalogue: .object([]))["catalog"]["claude"]["source"].string == "cli", "else the CLI's own")
    }

    @Test func aChatOnThisMacsOwnSignInOffersWhatItsCLIOffers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-model-list-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("claude")
        try Data(#"""
        #!/bin/sh
        read init
        id=$(printf '%s' "$init" | /usr/bin/sed -E 's/.*"request_id":"([^"]*)".*/\1/')
        printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{"commands":[],"models":[{"value":"default","resolvedModel":"claude-opus-5-5","displayName":"Default (recommended)"},{"value":"opus","resolvedModel":"claude-opus-5-5","displayName":"Opus","description":"Opus 5.5"},{"value":"haiku","resolvedModel":"claude-haiku-5-5","displayName":"Haiku","description":"Haiku 5.5"}]}}}\n' "$id"
        while read line; do
          printf '{"type":"system","subtype":"init","session_id":"model-list-conversation"}\n'
          printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"pong"}]}}\n'
          printf '{"type":"result","subtype":"success","is_error":false,"session_id":"model-list-conversation","result":"pong"}\n'
        done
        """#.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let manager = BackendPTYManager(inheritedEnvironment: ["PATH": "/usr/bin:/bin"]) { _ in }
        // No list through a login the app keeps (this Mac's own Claude Code sign-in): the catalogue has none.
        let chats = BackendSessionChats(manager: manager, directory: root.appendingPathComponent("chats"), publish: { _, _ in },
            usageReport: { _ in .object([]) }, modelCatalogue: { .object([]) })
        var input = BackendCreateSessionInput(cwd: root.path, provider: "claude"); input.chat = true
        let meta = try await chats.launch(input, spawn: .init(provider: "claude", command: script.path,
            args: ["--session-id", "initial-conversation"], path: "/usr/bin:/bin", env: ["CLAUDE_CONFIG_DIR": root.path], tabKey: "model-list-tab"))
        _ = try await chats.say(meta.id, text: "hello")
        let end = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < end {
            if case .done = try await chats.turn(meta.id).state { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let options = try await chats.options(meta.id)
        #expect((options["catalog"]["claude"]["featured"].elements ?? []).compactMap(\.string) == ["opus", "opus[1m]", "haiku"])
        #expect((options["models"].elements ?? []).compactMap { $0["name"].string } == ["Opus", "Opus 1M", "Haiku"])
        #expect(options["model"].string == "claude:opus", "the CLI's default is its first real choice")
        let switched = try await chats.setOptions(meta.id, .object([.init("model", .string("claude:haiku"))]))
        #expect(switched["model"].string == "claude:haiku", "a pick switches the chat (from its next message)")
        await chats.close(meta.id)
    }

    /// A chat whose fake CLI refuses "[1m]" launches with `reason` (from reason.txt) and answers otherwise.
    private struct MillionChat {
        let root: URL, chats: BackendSessionChats, id: String
        static func start(reason: String) async throws -> MillionChat {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-model-million-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(reason.utf8).write(to: root.appendingPathComponent("reason.txt"))
            let script = root.appendingPathComponent("claude")
            try Data(#"""
            #!/bin/sh
            printf '%s\n' "$@" >> launches.txt
            million=0
            case "$*" in *"[1m]"*) million=1 ;; esac
            reason=$(/bin/cat reason.txt)
            read init
            id=$(printf '%s' "$init" | /usr/bin/sed -E 's/.*"request_id":"([^"]*)".*/\1/')
            printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{}}}\n' "$id"
            while read line; do
              printf '{"type":"system","subtype":"init","session_id":"million-conversation"}\n'
              if [ "$million" = 1 ]; then
                printf '{"type":"result","subtype":"success","is_error":true,"session_id":"million-conversation","result":"%s"}\n' "$reason"
              else
                printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"pong"}]}}\n'
                printf '{"type":"result","subtype":"success","is_error":false,"session_id":"million-conversation","result":"pong"}\n'
              fi
            done
            """#.utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            let manager = BackendPTYManager(inheritedEnvironment: ["PATH": "/usr/bin:/bin"]) { _ in }
            let chats = BackendSessionChats(manager: manager, directory: root.appendingPathComponent("chats"), publish: { _, _ in },
                usageReport: { _ in .object([]) }, modelCatalogue: { .object([]) })
            var input = BackendCreateSessionInput(cwd: root.path, provider: "claude"); input.chat = true
            let meta = try await chats.launch(input, spawn: .init(provider: "claude", command: script.path,
                args: ["--session-id", "initial-conversation", "--model", "opus"], path: "/usr/bin:/bin", env: ["CLAUDE_CONFIG_DIR": root.path], tabKey: "million-tab"))
            return .init(root: root, chats: chats, id: meta.id)
        }
        func settled() async throws -> BackendSessionChats.TurnState {
            let end = ContinuousClock.now + .seconds(8)
            while ContinuousClock.now < end {
                let state = try await chats.turn(id).state
                switch state { case .done, .failed: return state; default: try await Task.sleep(for: .milliseconds(30)) }
            }
            Issue.record("The fixture did not finish its reply."); return .idle
        }
        /// Pick Opus 1M, send "first", wait for its failed answer and for the change handler's turn.
        func pickMillionAndFail() async throws {
            _ = try await chats.setOptions(id, .object([.init("model", .string("claude:opus[1m]"))]))
            _ = try await chats.say(id, text: "first")
            guard case .failed = try await settled() else { Issue.record("the 1M answer should fail in this fixture"); return }
            try await Task.sleep(for: .milliseconds(300))
        }
        func close() async { await chats.close(id); try? FileManager.default.removeItem(at: root) }
    }

    /// Reviewer 28 Oct (SHOULD 3, MUST): whether an account has the 1M window cannot be read beforehand, so the 1M
    /// choice stays; a first answer that refuses the model or its 1M window puts the chat back on the same model
    /// without it, in plain words, with his message back in the box.
    @Test func aRefusedOneMillionPickFallsBackAndTheChatKeepsWorking() async throws {
        let chat = try await MillionChat.start(reason: "API Error: 400 the 1M context window is not available for this account")
        try await chat.pickMillionAndFail()
        var options = try await chat.chats.options(chat.id)
        for _ in 0..<100 where options["model"].string != "claude:opus" { try await Task.sleep(for: .milliseconds(20)); options = try await chat.chats.options(chat.id) }
        #expect(options["model"].string == "claude:opus", "back on the same model without the 1M window")
        let read = try await chat.chats.read(chat.id, cursor: nil, limit: 500)
        let problem = read["problem"].string ?? ""
        #expect(problem.hasPrefix("The 1M choice did not work for this account, so this chat is back on Opus without it. Send your message again."))
        #expect(problem.contains("not available for this account"), "the AI's own reason, in brackets")
        #expect(read["draft"].string == "first", "his message is back in the box: one tap to send again")
        // The next message runs, on the plain model; the notice goes with it.
        _ = try await chat.chats.say(chat.id, text: "second")
        guard case .done = try await chat.settled() else { Issue.record("the next message should be answered"); await chat.close(); return }
        let launches = try String(contentsOf: chat.root.appendingPathComponent("launches.txt"), encoding: .utf8)
        #expect(launches.components(separatedBy: "--model\n").last?.hasPrefix("opus\n") == true, "relaunched without [1m]")
        #expect(try await chat.chats.read(chat.id, cursor: nil, limit: 500)["problem"].string?.hasPrefix("The 1M choice") != true)
        await chat.close()
    }

    /// A usage limit, an overload, the network, a sign-in problem or any other failure is not a refusal of the 1M
    /// window: his pick stays, nothing is said about 1M and the box is left alone (Reviewer 28 Oct, MUST).
    @Test(arguments: ["Claude AI usage limit reached. Your limit resets at 5pm.", "API Error: 429 rate_limit_error",
                      "API Error: 529 Overloaded", "API Error: Connection error.", "OAuth token has expired. Please run /login.",
                      "Tool failed: the file could not be written", "The model returned an invalid tool call",
                      #"\u001b[1mError\u001b[0m: the answer stopped"#, "Request failed, retrying in 1m"])
    func anotherFailureKeepsTheOneMillionPick(reason: String) async throws {
        let chat = try await MillionChat.start(reason: reason)
        try await chat.pickMillionAndFail()
        let options = try await chat.chats.options(chat.id)
        #expect(options["model"].string == "claude:opus[1m]", "the 1M pick stays")
        let read = try await chat.chats.read(chat.id, cursor: nil, limit: 500)
        #expect(read["problem"].string?.hasPrefix("The 1M choice") != true)
        #expect((read["draft"].string ?? "").isEmpty)
        await chat.close()
    }

    @Test func onlyAModelOrLongContextRefusalCounts() {
        for refusal in ["The long context beta is not yet available for this subscription.", "API Error: 400 context-1m is not enabled",
                        "Your plan does not include the 1M context window", "model: claude-opus-5-5[1m] is not available for this account",
                        "invalid model name", "This model is not supported on your plan"] {
            #expect(BackendSessionChats.isMillionRefusal(refusal), "\(refusal)")
        }
        // Reviewer 28 Oct (MUST): ordinary errors in raw crash output are not refusals either.
        for other in ["Claude AI usage limit reached", "API Error: 429 rate limited", "Overloaded", "Connection error.", "Please sign in again",
                      "OAuth token has expired", "Network unreachable", "The turn was stopped before it finished.", "Tool failed",
                      "The model returned an invalid tool call", "\u{1B}[1mError\u{1B}[0m: the answer stopped", "Request failed, retrying in 1m",
                      "Tool output:\n\u{1B}[1mbold\u{1B}[0m and the model kept going"] {
            #expect(!BackendSessionChats.isMillionRefusal(other), "\(other)")
        }
    }

    /// Guard: every answer for a hosted chat goes through the app's live list (reading and changing).
    @Test func everyHostedOptionsAnswerGetsTheLiveList() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let source = try String(contentsOf: root.appendingPathComponent("Sources/TerminalDeckBackend/BackendSessionChats.swift"), encoding: .utf8)
        let calls = source.components(separatedBy: #"hosted!.call("options""#).count - 1
        let merged = source.components(separatedBy: #"withLiveModels(try await hosted!.call("options""#).count - 1
        #expect(calls == 2 && merged == calls, "a hosted chat's choices never reach the Mac or a phone without the app's live list")
    }
}
