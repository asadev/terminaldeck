import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

final class CodexAIFixesTests: XCTestCase {
    func testEveryCLIReadyPromptAndTypedBrief() async throws {
        for (mark, hint) in [("›", "Ask Codex to do anything"), (">", "Type your message or @path/to/file"), ("*", "Type your message or @path/to/file"), ("❯", "Try \"fix lint errors\"")] {
            let empty = "╭────────────────────╮\n│ \(mark) \(hint) │\n╰────────────────────╯\n? for shortcuts"
            guard case .ready = BackendTaskBriefDelivery.composer(empty) else { return XCTFail(empty) }
            XCTAssertNil(BackendDeckCoreBrief.refusal(BackendTaskBriefDelivery.composer(empty)))
            let line = "Read /tmp/whole-brief.md and do exactly what it says."
            let typed = empty.replacingOccurrences(of: hint, with: line)
            XCTAssertEqual(BackendTaskBriefDelivery.promptText(typed), line)
            guard case .typing(let text) = BackendTaskBriefDelivery.composer(typed) else { return XCTFail(typed) }
            XCTAssertTrue(BackendTaskBriefDelivery.echoes(text, line: line))
            XCTAssertTrue(BackendTaskBriefDelivery.taken(line + "\n" + empty, line: line))
        }
        XCTAssertEqual(BackendSessionClassifier.classify(viewport: "› Ask Codex to do anything"), .waiting)
        XCTAssertEqual(BackendSessionClassifier.classify(viewport: "* Type your message or @path/to/file"), .waiting)
        guard case .choosing = BackendTaskBriefDelivery.composer("› 1. Yes\n2. No") else { return XCTFail("choice confused with composer") }
        guard case .working = BackendTaskBriefDelivery.composer("› Ask Codex to do anything\nesc to interrupt") else { return XCTFail("working confused with ready") }
    }
    func testSavedModesCheckpointAcrossCodexSwitch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-ai-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = BackendAppSettingsStore(userData: root, writable: true)
        _ = try await settings.patch(.object([.init("hoot.provider", .string("codex")),
            .init("hoot.model.codex", .string("gpt-fixture"))]))
        let defaults = BackendHootReadyDefaults(settings: settings, profiles: { ai, _ in
            [.init(id: "system:" + ai.rawValue, name: ai.rawValue, provider: ai.rawValue, configDir: root.path, system: true, color: "", createdAt: 0)]
        }, available: { _ in true }, signedIn: { _, _ in true })
        await defaults.setModelHome(root)
        for mode in ["ask", "plan", "changes", "bypass"] {
            _ = try await defaults.setChatOptions(.object([.init("model", .string("codex:gpt-fixture")), .init("permissionMode", .string(mode))]), projectPath: root.path)
            let checkpoint = await defaults.checkpointChatOptions()
            try await defaults.restoreChatOptions(checkpoint)
            let before = try await defaults.read(projectPath: root.path, forConversation: true)
            let after = try await defaults.read(projectPath: root.path, forConversation: true)
            XCTAssertEqual(before.launchSettings, after.launchSettings)
            XCTAssertEqual(after.provider, .codex)
        }
    }
    func testGateHonoursRecordedPlaybookAndRejectsUnrelatedAI() async throws {
        let memory = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/tmp/codex-ai-gate"), ownership: .memory)
        let store = BackendTaskStore(persistence: memory), config = try BackendTaskConfiguration(persistence: memory)
        try await store.start(); try await config.start()
        _ = try await config.saveAgent(.object([.init("id", .string("probe")), .init("name", .string("Probe")), .init("provider", .string("claude"))]))
        let layer = BackendPlaybookLayer(jobKind: "probe", provider: "codex")
        _ = try await store.put(.object([.init("id", .string("local:probe")), .init("keyId", .string("local")), .init("externalTaskId", .string("probe")), .init("local", .bool(true)), .init("project", .string("/scratch")), .init("assignee", BackendTaskLocalService.assignment("probe", kind: "agent")), .init("playbook", layer.wireValue), .init("agoptProfileID", .string("system:codex"))]))
        let storedTask = try await store.byID("local:probe"), storedAgent = try await config.agent("probe")
        let recorded = try XCTUnwrap(storedTask), own = try XCTUnwrap(storedAgent)
        let launchOwner = try BackendAGSProfileProjection.settings(BackendTaskEngine.playbookAgent(recorded, own), defaultProvider: "codex")
        XCTAssertEqual(launchOwner.provider, "codex", "the AGS launch authority checks the same recorded playbook choice")
        let gate = BackendTaskSessionGate(store: store, config: config, connectionKeyExists: { _ in false }, openProjects: { ["/scratch"] })
        try await gate.authorize("sessions.start", .object([.init("task", .string("local:probe")), .init("provider", .string("codex")), .init("account", .string("system:codex"))]))
        do { try await gate.authorize("sessions.start", .object([.init("task", .string("local:probe")), .init("provider", .string("gemini")), .init("account", .string("system:codex"))])); XCTFail("unrelated AI accepted") } catch {}
    }
    func testEffectiveProfileShowsDefaultsAndPlaybookSources() {
        let settings = NativeRPCValue.object([.init("provider", .string("codex"))])
        let cli = NativeRPCValue.object([.init("model", .string("gpt-6.1-sol")), .init("effort", .string("xhigh"))])
        let plain = BackendAGOPTProfileService.displayChoices(settings, latest: nil, cli: cli)
        XCTAssertEqual(plain["model"].string, "gpt-6.1-sol")
        XCTAssertEqual(plain["effort"].string, "xhigh")
        XCTAssertTrue(AGTChoiceLine.text(run: plain)?.contains("from the app defaults") == true)
        let own = BackendAGOPTProfileService.displayChoices(settings.setting("model", .string("own-model")), latest: nil, cli: cli, own: .object([.init("model", .string("own-model"))]))
        XCTAssertEqual(own["sources"]["model"].string, "agent")
        XCTAssertEqual(own["sources"]["effort"].string, "default")
        let run = NativeRPCValue.object([.init("provider", .string("codex")), .init("requested_model", .string("gpt-6.1-sol")), .init("requested_effort", .string("low")), .init("sources", .object([.init("ai", .string("playbook")), .init("model", .string("playbook")), .init("effort", .string("playbook"))])), .init("playbook_job", .string("probe"))])
        let played = BackendAGOPTProfileService.displayChoices(settings, latest: run, cli: cli)
        XCTAssertEqual(played["effort"].string, "low")
        XCTAssertTrue(AGTChoiceLine.text(run: played)?.contains("from the playbook: probe") == true)
    }
    func testEnabledPageMCPReachesCodex() {
        let page = NativeRPCValue.object([.init("name", .string("idea")), .init("transport", .string("http")), .init("url", .string("http://127.0.0.1:64342/stream")), .init("enabled", .bool(true))])
        let launch = BackendMcpPolicy.codex(.init(), pageServers: [page], codexOwn: [], agentID: nil)
        XCTAssertTrue(launch.arguments.contains("mcp_servers.idea.url=\"http://127.0.0.1:64342/stream\""))
    }
    func testScopedCleanupKeepsOtherRecords() async throws {
        let memory = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/tmp/codex-ai-trash"), ownership: .memory)
        let store = BackendTaskStore(persistence: memory); try await store.start()
        for id in ["probe", "other"] { _ = try await store.put(.object([.init("id", .string("local:" + id)), .init("keyId", .string("local")), .init("externalTaskId", .string(id)), .init("local", .bool(true))])); try await store.moveToTrash("local:" + id) }
        try await store.purgeTrash("local:probe")
        _ = try await store.put(.object([.init("id", .string("local:kept")), .init("keyId", .string("local")), .init("externalTaskId", .string("kept")), .init("local", .bool(true)), .init("sessionId", .string("owned-session")), .init("process", .string("idle"))]))
        try await store.moveToTrash("local:kept")
        do { try await store.purgeTrash("local:kept"); XCTFail("kept worker lost its task") } catch {}

        let remaining = try await store.inTrash(); XCTAssertEqual(Set(remaining.map(\.id)), Set(["local:other", "local:kept"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-registry-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); PROJProjects.publishRegistered([PROJProjects.independent]) }
        let registry = BackendPROJRegistry(fileURL: root.appendingPathComponent("projects.json"))
        _ = try await registry.save(PROJProject(id: "probe", name: "Probe", folders: []))
        _ = try await registry.save(PROJProject(id: "other", name: "Other", folders: ["/scratch/other"]))
        _ = try await registry.removeEmpty("probe")
        do { _ = try await registry.removeEmpty("other"); XCTFail("populated project removed") } catch {}
        let projects = try await registry.projects(); XCTAssertTrue(projects.contains { $0.id == "other" }); XCTAssertFalse(projects.contains { $0.id == "probe" })
    }
}
