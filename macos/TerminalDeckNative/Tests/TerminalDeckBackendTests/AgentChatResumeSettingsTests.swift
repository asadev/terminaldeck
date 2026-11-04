import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private struct AgentResumeFixtureCipher: BackendAccountVaultCipher {
    func available() -> Bool { true }
    func prepareForWrites(existingVault: Bool) throws {}
    func encrypt(_ text: String, existingVault: Bool) throws -> Data { Data(("fixture:" + text).utf8) }
    func decrypt(_ blob: Data) throws -> String { String(decoding: blob.dropFirst(8), as: UTF8.self) }
}

@Suite("Agent chat Resume resolves current saved settings")
struct AgentChatResumeSettingsTests {
    @Test func currentPrivateSettingsAreLoadedAndBothCurrentAndSavedRestrictionsHold() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resume-settings-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try BackendTaskPersistence(directory: root, ownership: .memory)
        let configuration = try BackendTaskConfiguration(persistence: persistence)
        let store = BackendAGSStore(persistence: persistence, cipher: AgentResumeFixtureCipher())
        try await configuration.start(); try await store.start(); try await configuration.bindAGS(store)
        let agent = try await configuration.saveAgent(.object([.init("id", .string("saved-builder")),
            .init("name", .string("Saved builder")), .init("provider", .string("claude"))]))
        let id = try agent["id"].requireString("agent")
        let owner = AGSAgentSettings(provider: "claude", model: "sonnet", permissionMode: "bypassPermissions",
            allowedTools: ["Read", "Write", "Bash"], deniedTools: ["Bash"], mcpServers: ["docs": true, "current-off": false],
            hooks: [.init(command: "/usr/bin/true")], environment: ["FIXTURE_VALUE": "current-scratch-setting"],
            efficiency: .init(taskTokenBudget: 100))
        let revision = try await store.currentRevision()
        _ = try await configuration.saveSettingsForProfile(id, settings: owner, expectedRevision: revision)
        let saved = AGSAgentSettings(provider: "claude", model: "sonnet", permissionMode: "bypassPermissions",
            allowedTools: ["Read", "Bash"], deniedTools: ["Write"], mcpServers: ["docs": false, "current-off": true],
            efficiency: .init(addonsOff: true, taskTokenBudget: 10))
        var input = BackendCreateSessionInput(cwd: root.path, provider: "claude")
        input.agentProfileID = id; input.agentSettings = saved
        input.teamJob = .init(fromID: "starter", fromName: "Starter", agentID: id, agentName: "Saved builder", title: "Resume")
        input.teamJob?.resumedFromSessionID = "restarted-job"
        let resolver = BackendINT2AGSLaunch(store: store, configuration: configuration, defaultProvider: { "claude" }, taskProfile: { _ in nil })
        let result = try #require(try await resolver.resolve(input, context: .init(rememberTab: false, fromAI: true)).agentSettings)
        #expect(result.environment == owner.environment)
        #expect(result.hooks == owner.hooks)
        #expect(result.allowedTools == ["Read"])
        #expect(Set(result.deniedTools) == Set(["Bash", "Write"]))
        #expect(result.mcpServers["docs"] == false && result.mcpServers["current-off"] == false)
        #expect(result.efficiency?.addonsOff == true && result.efficiency?.taskTokenBudget == 10)
        #expect(throws: (any Error).self) { try BackendAGSPolicy.requireNarrowing(saved, owner: owner) }
        try await configuration.stop()
    }
}
