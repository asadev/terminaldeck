import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// PLAYBOOK-SEATS (12 Oct, Asad: "Agents placed in seats still use their own AI settings rather than the playbook
/// choice… let's fix that"). One order for every agent job: the playbook row, else the agent's own settings, else
/// the app defaults; what a layer leaves empty falls through to the next.
@Suite("PLAYBOOK-SEATS: playbook row, then the agent, then the app defaults", .serialized)
struct PlaybookSeatsTests {
    private struct Cipher: BackendAccountVaultCipher {
        func available() -> Bool { true }
        func prepareForWrites(existingVault: Bool) throws {}
        func encrypt(_ text: String, existingVault: Bool) throws -> Data { Data(text.utf8) }
        func decrypt(_ blob: Data) throws -> String { String(decoding: blob, as: UTF8.self) }
    }
    private let defaults = AGSAgentSettings(provider: "claude", model: "app-model", effort: "low", permissionMode: "default")

    @Test func eachLayerFallsThroughToTheNext() throws {
        let own = AGSAgentSettings(provider: "claude", model: "agent-model", effort: nil, permissionMode: nil)
        let merged = try BackendAGSPolicy.resolve(defaults: defaults, profile: own)
        // 1. The row decides what it names.
        let row = BackendPlaybookLayer(jobKind: "bug fix", model: "opus", permission: "plan")
        let played = row.apply(to: merged)
        #expect(played.model == "opus" && played.permissionMode == "plan")
        // 2. What the row leaves out comes from the agent; 3. what the agent leaves out from the app defaults.
        #expect(played.effort == "low")
        let empty = BackendPlaybookLayer(jobKind: "default").apply(to: merged)
        #expect(empty.model == "agent-model" && empty.effort == "low" && empty.permissionMode == "default")
        // An effort the AI does not have is not applied (falls through).
        #expect(BackendPlaybookLayer(jobKind: "x", effort: "minimal").apply(to: merged).effort == "low")
        #expect(BackendPlaybookLayer(jobKind: "x", effort: "Extra high").apply(to: merged).effort == "xhigh")
        // Permission in the CLI's own word for each AI.
        #expect(BackendPlaybookLayer(jobKind: "x", permission: "auto").apply(to: AGSAgentSettings(provider: "codex")).permissionMode == "workspace-write")
        #expect(BackendPlaybookLayer(jobKind: "x", permission: "bypass").apply(to: AGSAgentSettings(provider: "gemini")).permissionMode == "yolo")
    }

    @Test func thePlaybooksAIReplacesTheAgentsOwnAndItsAIChoicesFallThrough() throws {
        let agent = NativeRPCValue.object([.init("id", .string("alpha")), .init("provider", .string("claude")), .init("model", .string("sonnet")),
            .init("effort", .string("high")), .init("account", .string("claude-work")), .init("claudeAgent", .string("reviewer"))])
        let switched = BackendPlaybookLayer(jobKind: "bug fix", provider: "codex").agentRow(agent)
        #expect(switched["provider"].string == "codex")
        for field in ["model", "effort", "account", "claudeAgent"] { #expect(switched[field].isNullish, "\(field)") }
        #expect(BackendPlaybookLayer(jobKind: "bug fix", provider: "claude").agentRow(agent) == agent)
        #expect(BackendPlaybookLayer(jobKind: "bug fix").agentRow(agent) == agent)
        let profile = AGSAgentSettings(provider: "claude", model: "sonnet", effort: "high", permissionMode: "acceptEdits",
            hooks: [.init(event: "SessionStart", command: "/usr/bin/true"), .init(event: "Notification", command: "/usr/bin/true")])
        let carried = BackendPlaybookLayer.carried(profile, to: "codex")
        #expect(carried.provider == "codex" && carried.model == nil && carried.effort == nil && carried.permissionMode == nil)
        #expect(carried.hooks.map(\.event) == ["SessionStart"])
    }

    @Test func theLaunchResolutionUsesTheSameOrderOnEveryAI() async throws {
        let persistence = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/tmp/playbook-seats-memory"), ownership: .memory)
        let store = BackendAGSStore(persistence: persistence, cipher: Cipher()); try await store.start()
        try await store.saveDefaults(.init(providers: ["claude": defaults, "codex": AGSAgentSettings(provider: "codex", model: "codex-default", effort: "medium")]), expectedRevision: 0)
        let config = try BackendTaskConfiguration(persistence: persistence); try await config.start(); try await config.bindAGS(store)
        _ = try await config.saveAgent(.object([.init("id", .string("alpha")), .init("name", .string("Alpha")), .init("provider", .string("claude")), .init("model", .string("agent-model"))]))
        func resolve(_ provider: String, _ layer: BackendPlaybookLayer?) async throws -> AGSAgentSettings? {
            try await BackendAGSSettingsResolution.resolve(input: BackendCreateSessionInput(cwd: "/tmp", provider: provider), store: store,
                configuration: config, defaultProvider: "claude", taskProfile: "alpha", playbook: layer)
        }
        // No row: the agent's own model, the app default effort.
        let plain = try #require(try await resolve("claude", nil))
        #expect(plain.model == "agent-model" && plain.effort == "low")
        // A row with a model and an effort: both from the row.
        let row = try #require(try await resolve("claude", BackendPlaybookLayer(jobKind: "bug fix", model: "opus", effort: "max")))
        #expect(row.model == "opus" && row.effort == "max")
        // A row naming Codex: Codex, the agent's Claude model dropped, so Codex's app default model; the row's effort.
        let codex = try #require(try await resolve("codex", BackendPlaybookLayer(jobKind: "bug fix", provider: "codex", effort: "high")))
        #expect(codex.provider == "codex" && codex.model == "codex-default" && codex.effort == "high")
        // Without the row the agent's own AI must match the launch, as before.
        await #expect(throws: (any Error).self) { _ = try await resolve("codex", nil) }
    }

    @Test func aTaskCarriesItsDecidedRowToEveryLaunchCheck() throws {
        let decided = BackendPlaybookLayer(jobKind: "bug fix", provider: "gemini", model: "gemini-3-pro", effort: "high")
        let task = try BackendTaskRecord(.object([.init("id", .string("local:1")), .init("keyId", .string("local")), .init("externalTaskId", .string("1")),
            .init("playbook", decided.wireValue)]))
        let agent = NativeRPCValue.object([.init("id", .string("alpha")), .init("provider", .string("claude"))])
        #expect(BackendTaskEngine.playbookAgent(task, agent)["provider"].string == "gemini")
        let owner = BackendTaskEngine.playbookOwner(task, AGSAgentSettings(provider: "gemini", model: "gemini-default", effort: "low"))
        #expect(owner.model == "gemini-3-pro" && owner.effort == "high")
        #expect(BackendPlaybookLayer(wire: decided.wireValue) == decided)
        #expect(BackendPlaybookLayer(wire: .null) == nil)
        let none = try BackendTaskRecord(.object([.init("id", .string("local:2")), .init("keyId", .string("local")), .init("externalTaskId", .string("2"))]))
        #expect(BackendTaskEngine.playbookAgent(none, agent) == agent)
    }

    @Test func theProfileSaysWhereEachChoiceCameFrom() {
        let layer = BackendPlaybookLayer(jobKind: "bug fix", provider: "claude", model: "opus")
        let launched = AGSAgentSettings(provider: "claude", model: "opus", effort: "high", permissionMode: "default")
        let sources = BackendPlaybookLayer.sources(layer: layer, own: AGSAgentSettings(provider: "claude", effort: "high"), launched: launched, task: .object([]))
        #expect(sources["ai"].string == "playbook" && sources["model"].string == "playbook")
        #expect(sources["effort"].string == "agent" && sources["permission"].string == "default")
        let byTask = BackendPlaybookLayer.sources(layer: layer, own: nil, launched: launched, task: .object([.init("model", .string("haiku"))]))
        #expect(byTask["model"].string == "task" && byTask["effort"].string == "default")
        let run = NativeRPCValue.object([.init("provider", .string("claude")), .init("requested_model", .string("opus")), .init("requested_effort", .string("high")),
            .init("permission", .string("default")), .init("sources", sources), .init("playbook_job", .string("bug fix"))])
        #expect(AGTChoiceLine.text(run: run) == "Claude Code · opus · from the playbook: bug fix; effort high · from its own settings; Ask first · from the app defaults")
        #expect(AGTChoiceLine.text(run: .object([.init("provider", .string("claude"))])) == nil)
    }
}
