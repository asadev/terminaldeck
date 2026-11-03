import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Composer20: chat Fast mode and the options tool")
struct Composer20BackendTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("td-composer20-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func fastModeUsesOnlyTheSelectedAccountsEntitlementAndSettings() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let catalogue = NativeRPCValue.object([.init("fastMode", .object([.init("available", .bool(true)), .init("on", .bool(true))]))])
        #expect(BackendSessionChatComposer.fastMode(provider: .claude, configDir: root.path, catalogue: catalogue, arguments: [], choice: nil) == nil)
        try Data(#"{"penguinModeOrgEnabled":true}"#.utf8).write(to: root.appendingPathComponent(".claude.json"))
        try Data(#"{"fastMode":false}"#.utf8).write(to: root.appendingPathComponent("settings.json"))
        #expect(BackendSessionChatComposer.fastMode(provider: .claude, configDir: root.path, catalogue: catalogue, arguments: [], choice: nil) == false)
        #expect(BackendSessionChatComposer.fastMode(provider: .claude, configDir: root.path, catalogue: catalogue,
            arguments: ["--settings", #"{"fastMode":true}"#], choice: nil) == true)
        #expect(BackendSessionChatComposer.fastMode(provider: .claude, configDir: root.path, catalogue: catalogue,
            arguments: ["--settings", #"{"fastMode":true}"#], choice: "false") == false)
        #expect(BackendSessionChatComposer.fastMode(provider: .codex, configDir: root.path, catalogue: catalogue, arguments: [], choice: "true") == nil)
        #expect(BackendSessionChatComposer.fastMode(provider: .gemini, configDir: root.path, catalogue: catalogue, arguments: [], choice: "true") == nil)
    }

    @Test func launchOverrideKeepsHooksAndOtherSettingsWithoutChangingTheirFile() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.json")
        let bytes = Data(#"{"hooks":{"Stop":[]},"fastMode":false}"#.utf8)
        try bytes.write(to: original)
        let args = try BackendSessionChatComposer.applyingFastMode(["--model", "opus", "--settings", original.path,
            "--settings", #"{"ultracode":true}"#], on: true, directory: root.appendingPathComponent("chat"))
        #expect(Array(args.prefix(2)) == ["--model", "opus"])
        #expect(args.filter { $0 == "--settings" }.count == 1)
        let output = try #require(args.last)
        let settings = try NativeRPCValue.parseJSON(Data(contentsOf: URL(fileURLWithPath: output)))
        #expect(settings["fastMode"].bool == true && settings["ultracode"].bool == true)
        #expect(settings["hooks"]["Stop"].elements == [])
        #expect(try Data(contentsOf: original) == bytes)
        #expect(try FileManager.default.attributesOfItem(atPath: output)[.posixPermissions] as? Int == 0o600)
        let off = try BackendSessionChatComposer.applyingFastMode(args, on: false, directory: root.appendingPathComponent("chat"))
        #expect(try NativeRPCValue.parseJSON(Data(contentsOf: URL(fileURLWithPath: off.last!)))["fastMode"].bool == false)
        #expect(throws: (any Error).self) {
            try BackendSessionChatComposer.applyingFastMode(["--settings", root.appendingPathComponent("missing.json").path], on: true, directory: root)
        }
    }

    @Test func optionsToolReadsUsageSetsFastModeAndTheNextMessageResumesTheConversation() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"penguinModeOrgEnabled":true}"#.utf8).write(to: root.appendingPathComponent(".claude.json"))
        let script = root.appendingPathComponent("claude")
        try Data(#"""
        #!/bin/sh
        printf '%s\n' "$@" >> launches.txt
        read init
        id=$(printf '%s' "$init" | /usr/bin/sed -E 's/.*"request_id":"([^"]*)".*/\1/')
        printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{}}}\n' "$id"
        while read line; do
          printf '{"type":"system","subtype":"init","session_id":"composer-conversation"}\n'
          printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"pong"}]}}\n'
          printf '{"type":"result","subtype":"success","is_error":false,"session_id":"composer-conversation","result":"pong"}\n'
        done
        """#.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let manager = BackendPTYManager(inheritedEnvironment: ["PATH": "/usr/bin:/bin"]) { _ in }
        let account = NativeRPCValue.object([.init("provider", .string("claude")), .init("id", .string("fixture-account")), .init("name", .string("Work account"))])
        let now = Date().timeIntervalSince1970 * 1000
        let report = NativeRPCValue.object([.init("account", account), .init("readings", .array([
            .object([.init("id", .string("five")), .init("account", account), .init("window", .string("five-hour")),
                .init("used", .object([.init("state", .string("reported")), .init("fraction", .number(0.25))])),
                .init("resets", .object([.init("state", .string("at")), .init("at", .number(now + 3_600_000))])),
                .init("source", .string("claude-usage-api")), .init("reportedAt", .number(now))])
        ]))])
        let chats = BackendSessionChats(manager: manager, directory: root.appendingPathComponent("chats"), publish: { _, _ in },
            usageReport: { id in report.setting("sessionId", .string(id)) }, modelCatalogue: { .object([]) })
        var input = BackendCreateSessionInput(cwd: root.path, provider: "claude"); input.chat = true
        let meta = try await chats.launch(input, spawn: .init(provider: "claude", command: script.path,
            args: ["--session-id", "initial-conversation"], path: "/usr/bin:/bin", env: ["CLAUDE_CONFIG_DIR": root.path], tabKey: "test-tab"))
        _ = try await chats.say(meta.id, text: "first")
        try await finished(chats, id: meta.id)
        let before = try String(contentsOf: root.appendingPathComponent("launches.txt"), encoding: .utf8)
        let read = try await BackendSessionChatOptionsTool.invoke(chats, id: meta.id)
        #expect(read["fastMode"].bool == false)
        #expect(read["usage"]["account"]["id"].string == "fixture-account")
        #expect(read["usage"]["sessionId"].string == meta.id)
        #expect(read["usageSummary"].elements?.first?["percentUsed"].number == 25)
        let set = try await BackendSessionChatOptionsTool.invoke(chats, id: meta.id, patch: .object([.init("fastMode", .bool(true))]))
        #expect(set["fastMode"].bool == true)
        #expect(set["catalog"]["claude"]["fastMode"]["on"].bool == true)
        #expect(try String(contentsOf: root.appendingPathComponent("launches.txt"), encoding: .utf8) == before, "picking Fast mode does not interrupt or restart immediately")
        _ = try await chats.say(meta.id, text: "second")
        try await finished(chats, id: meta.id)
        let after = try String(contentsOf: root.appendingPathComponent("launches.txt"), encoding: .utf8)
        #expect(after.contains("--resume\ncomposer-conversation"))
        let settingsFile = root.appendingPathComponent("chats/test-tab/composer-settings.json")
        #expect(try NativeRPCValue.parseJSON(Data(contentsOf: settingsFile))["fastMode"].bool == true)
        #expect(try await chats.read(meta.id, cursor: nil, limit: 500)["events"].elements?.filter { $0["kind"].string == "user" }.count == 2)
        let off = try await BackendSessionChatOptionsTool.invoke(chats, id: meta.id, patch: .object([.init("fastMode", .bool(false))]))
        #expect(off["fastMode"].bool == false)
        await #expect(throws: (any Error).self) {
            try await BackendSessionChatOptionsTool.invoke(chats, id: meta.id, patch: .object([.init("fastMode", .string("yes"))]))
        }
        try FileManager.default.removeItem(at: root.appendingPathComponent(".claude.json"))
        await #expect(throws: (any Error).self) {
            try await BackendSessionChatOptionsTool.invoke(chats, id: meta.id, patch: .object([.init("fastMode", .bool(true))]))
        }
        #expect(BackendSessionChatOptionsTool.schema["properties"]["fastMode"]["type"].string == "boolean")
        await chats.close(meta.id)
    }

    private func finished(_ chats: BackendSessionChats, id: String) async throws {
        let end = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < end {
            if case .done = try await chats.turn(id).state { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        Issue.record("The fixture did not finish its reply.")
    }
}
