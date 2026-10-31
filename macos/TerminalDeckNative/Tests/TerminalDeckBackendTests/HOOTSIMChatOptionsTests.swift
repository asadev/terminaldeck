// Draft only: outside test targets. Root runs through one-build.sh HOOTSIM after integration.
import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

final class HOOTSIMChatOptionsTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HOOTSIM-chat-options-" + UUID().uuidString + ".noindex")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func defaults(_ settings: BackendAppSettingsStore, installed: Set<String> = ["claude", "codex"],
                          signed: Set<String> = ["claude", "codex"]) -> BackendHootReadyDefaults {
        let profiles = HootReadyDefaults.providerOrder.map { provider in
            BackendAccountProfile(id: "system:" + provider.rawValue, name: provider.rawValue, provider: provider.rawValue,
                                  configDir: "/HOOTSIM-fixture/" + provider.rawValue, system: true, color: "#000000", createdAt: 0)
        }
        return .init(settings: settings, enabled: true,
                     profiles: { provider, _ in profiles.filter { $0.provider == provider.rawValue } },
                     available: { installed.contains($0.rawValue) }, signedIn: { profile, _ in signed.contains(profile.provider) })
    }
    private func seeded(_ root: URL) async throws -> BackendAppSettingsStore {
        let settings = BackendAppSettingsStore(userData: root, writable: true)
        _ = try await settings.patch(.object([
            .init("hoot.provider", .string("claude")), .init("hoot.model.claude", .string("sonnet")),
            .init("hoot.model.codex", .string("gpt-fixture")), .init("hoot.effort.claude", .string("high")),
            .init("unrelated.fixture", .string("keep"))]))
        return settings
    }
    /// One saved choice (10 Oct): what is picked in the chat IS Hoot's saved choice, for every window and owner.
    func testAChoiceInTheChatIsTheSavedChoiceForEveryOwner() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let settings = try await seeded(root), owner = defaults(settings)
        let changed = try await owner.setChatOptions(.object([.init("model", .string("codex:gpt-fixture")), .init("permissionMode", .string("plan"))]), projectPath: "/HOOTSIM-fixture/project")
        XCTAssertEqual(changed["model"].string, "codex:gpt-fixture")
        XCTAssertEqual(changed["permissionMode"].string, "plan")
        let separate = try await defaults(settings).read(projectPath: "/HOOTSIM-fixture/project")
        XCTAssertEqual(separate.provider, .codex, "another owner sees the same saved AI")
        XCTAssertEqual(separate.preferences.model, "gpt-fixture")
        let savedAI = await settings.value("hoot.provider").string, untouched = await settings.value("unrelated.fixture").string
        XCTAssertEqual(savedAI, "codex"); XCTAssertEqual(untouched, "keep", "nothing but Hoot's own choices is written")
        let plans = await owner.plansOnly
        XCTAssertTrue(plans)
        // "Reset" has no private copy to drop any more: the chat shows the saved choice again.
        await owner.resetChatOptions()
        let reset = try await owner.chatOptions(projectPath: "/HOOTSIM-fixture/project")
        XCTAssertEqual(reset["model"].string, "codex:gpt-fixture"); XCTAssertEqual(reset["permissionMode"].string, "plan")
    }
    /// H20b (11 Oct): switching Hoot's AI and back keeps what was chosen for each AI (Claude Code's Bypass survived nothing before).
    func testSwitchingAIKeepsEachAIsOwnPermission() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let settings = try await seeded(root), owner = defaults(settings)
        _ = try await settings.patch(.object([.init("hoot.permission.claude", .string("bypassPermissions"))]))
        _ = try await owner.save(.object([.init("provider", .string("codex"))]), projectPath: "/HOOTSIM-fixture/project")
        _ = try await owner.save(.object([.init("provider", .string("claude"))]), projectPath: "/HOOTSIM-fixture/project")
        let kept = await settings.value("hoot.permission.claude").string, model = await settings.value("hoot.model.claude").string
        XCTAssertEqual(kept, "bypassPermissions"); XCTAssertEqual(model, "sonnet")
        // U91: Settings → Hoot sends an empty permission on a switch (no local copy of its own); each AI gets its own back.
        _ = try await settings.patch(.object([.init("hoot.permission.codex", .string("read-only"))]))
        let codex = try await owner.save(.object([.init("provider", .string("codex")), .init("permissionMode", .string(""))]), projectPath: "/HOOTSIM-fixture/project")
        XCTAssertEqual(codex.preferences.permissionMode, "read-only")
        let back = try await owner.save(.object([.init("provider", .string("claude")), .init("permissionMode", .string(""))]), projectPath: "/HOOTSIM-fixture/project")
        XCTAssertEqual(back.preferences.permissionMode, "bypassPermissions")
    }
    /// U91: Fast mode changed in the chat box goes through the one shared writer and is Hoot's saved choice.
    func testFastModeInTheChatIsTheSavedChoice() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let settings = try await seeded(root), owner = defaults(settings)
        let on = try await owner.setChatOptions(.object([.init("fastMode", .bool(true))]), projectPath: "/HOOTSIM-fixture/project")
        XCTAssertEqual(on["fastMode"].bool, true)
        let saved = await settings.value("hoot.fast.claude").bool, model = await settings.value("hoot.model.claude").string
        XCTAssertEqual(saved, true); XCTAssertEqual(model, "sonnet", "only Fast mode changes")
        do {
            _ = try await owner.setChatOptions(.object([.init("fastMode", .string("true"))]), projectPath: "/HOOTSIM-fixture/project")
            XCTFail("Fast mode must be on or off")
        } catch {}
        let off = try await owner.setChatOptions(.object([.init("fastMode", .bool(false))]), projectPath: "/HOOTSIM-fixture/project")
        XCTAssertEqual(off["fastMode"].bool, false)
    }
    func testInvalidModeAndMixedInvalidPatchDoNotPartlyApplyAModel() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = defaults(try await seeded(root))
        let before = try await owner.chatOptions(projectPath: "/HOOTSIM-fixture/project")
        for mode in [NativeRPCValue.string("bypassPermissions"), .string("never-ask"), .bool(true), .number(1)] {
            do {
                _ = try await owner.setChatOptions(.object([.init("permissionMode", mode), .init("model", .string("codex:gpt-fixture"))]), projectPath: "/HOOTSIM-fixture/project")
                XCTFail("Invalid permission mode was accepted")
            } catch {}
            let after = try await owner.chatOptions(projectPath: "/HOOTSIM-fixture/project")
            XCTAssertEqual(after, before, "Invalid mode cannot partly switch this chat's provider/model")
        }
    }
    func testModelChoiceRequiresOfferedModelAndInstalledProvider() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = defaults(try await seeded(root), installed: ["claude"])
        let before = try await owner.chatOptions(projectPath: "/HOOTSIM-fixture/project")
        // The list is read live for the signed-in account (it differs per Mac), plus the saved model. No "Default"
        // entry anywhere, and nothing from an AI that is not installed.
        let offered = (before["models"].elements ?? []).compactMap { $0["id"].string }
        XCTAssertTrue(offered.contains("claude:sonnet"), "the saved model is always offered")
        XCTAssertFalse(offered.contains { $0.hasSuffix(":default") })
        XCTAssertTrue(offered.allSatisfy { $0.hasPrefix("claude:") })
        for model in ["codex:gpt-fixture", "gemini:default", "unknown:default", "claude:", "claude:not-in-the-offered-inventory"] {
            do {
                _ = try await owner.setChatOptions(.object([.init("model", .string(model))]), projectPath: "/HOOTSIM-fixture/project")
                XCTFail("Unsupported or unoffered model was accepted: " + model)
            } catch {}
            let after = try await owner.chatOptions(projectPath: "/HOOTSIM-fixture/project")
            XCTAssertEqual(after, before)
        }
    }
    func testInstalledUnsignedProviderCanBeSelectedButIsNotFalselyReady() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = defaults(try await seeded(root), signed: ["claude"])
        // "codex:default" is gone with the Default entries; the saved Codex model is what is offered.
        let changed = try await owner.setChatOptions(.object([.init("model", .string("codex:gpt-fixture"))]), projectPath: "/HOOTSIM-fixture/project")
        XCTAssertEqual(changed["model"].string, "codex:gpt-fixture")
        XCTAssertEqual(changed["ready"].bool, false, "Choosing an installed AI cannot invent sign-in")
    }
    func testPermissionChoiceFlowsIntoTheSelectedProvidersPrivateLaunchSettings() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = defaults(try await seeded(root))
        _ = try await owner.setChatOptions(.object([.init("model", .string("codex:gpt-fixture")), .init("permissionMode", .string("plan"))]), projectPath: "/HOOTSIM-fixture/project")
        let selected = try await owner.read(projectPath: "/HOOTSIM-fixture/project", forConversation: true)
        XCTAssertEqual(selected.launchSettings.provider, "codex")
        XCTAssertEqual(selected.launchSettings.permissionMode, "read-only")
        XCTAssertEqual(selected.launchSettings.effort, "xhigh", "R6: the selected AI gets its own Extra effort default")
        let claude = try await defaults(try await seeded(root)).read(projectPath: "/HOOTSIM-fixture/project")
        XCTAssertNil(claude.launchSettings.permissionMode, "The permission was saved for Codex only: Claude Code's own stays as it was")
    }
    func testMentionContextSurvivesSavedHistoryResetIncrementalAndReopen() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let context = try BackendHOOTSIMChatContext(wire: .object([
            .init("mentions", .array([.object([.init("id", .string("session-fixture")), .init("kind", .string("session")),
                .init("name", .string("CRM portal")), .init("project", .string("CRM"))])])),
            .init("source", .object([.init("kind", .string("browser")), .init("projectId", .string("crm")),
                .init("url", .string("https://portal.example.test/sign-in")), .init("noteCount", .number(1))]))]))
        let event = HootChatEvent(conversationID: "fixture-conversation", turnID: "fixture-turn", sequence: 1,
            provider: .claude, record: .init(.user, id: "fixture-user", value: .object([
                .init("text", .string("Check the sign-in screen")), .init("context", context.value), .init("attachmentCount", .number(1))])), at: 10)
        let file = root.appendingPathComponent("chat.json")
        try NativeRPCValue.object([.init("version", .number(1)), .init("provider", .string("claude")),
            .init("conversationId", .string("fixture-conversation")), .init("events", .array([event.wireValue]))]).encodedJSON().write(to: file)
        let store = try BackendHootChatStore(file: file)
        for cursor: Int? in [nil, 0] {
            let snapshot = await store.snapshot(after: cursor)
            let wire = try XCTUnwrap(snapshot["events"].elements?.first)
            XCTAssertEqual(wire["value"]["context"], context.value)
            XCTAssertEqual(wire["value"]["text"].string, "Check the sign-in screen")
        }
        let reopened = try BackendHootChatStore(file: file)
        let snapshot = await reopened.snapshot()
        XCTAssertEqual(snapshot["events"].elements?.first?["value"]["context"], context.value)
        let alive = await store.alive
        XCTAssertFalse(alive, "Reading saved metadata must not launch an AI")
    }
    func testNewConversationArchivesTheOldHistoryAndMetadataWithoutLaunchingAI() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let event = HootChatEvent(conversationID: "previous-conversation", turnID: "previous-turn", sequence: 1,
            provider: .claude, record: .init(.user, id: "old-user", value: .object([
                .init("text", .string("Keep this old message")), .init("context", .object([.init("source", .object([
                    .init("kind", .string("browser")), .init("projectId", .string("crm"))]))]))])), at: 10)
        let file = root.appendingPathComponent("chat.json")
        let saved = NativeRPCValue.object([.init("version", .number(1)), .init("provider", .string("claude")),
            .init("conversationId", .string("previous-conversation")), .init("sessionId", .string("previous-cli")),
            .init("events", .array([event.wireValue]))])
        let original = try saved.encodedJSON()
        try original.write(to: file)
        let store = try BackendHootChatStore(file: file)
        let next = try await store.newConversation()
        XCTAssertNotEqual(next["conversationId"].string, "previous-conversation")
        let newEvents = try (next["events"].elements ?? []).map(HootChatEvent.init(wire:))
        XCTAssertTrue(newEvents.allSatisfy { $0.record.kind == .session })
        XCTAssertTrue(HootChatProjection.rows(newEvents).isEmpty)
        let cliID = await store.cliSessionID, alive = await store.alive
        XCTAssertNil(cliID); XCTAssertFalse(alive)
        // Top level only: Foundation's atomic write can leave its own temporary
        // "(A Document Being Saved By …)" folder beside the file for a moment.
        let archiveFiles = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("chat-archive-") && $0.pathExtension == "json" }
        XCTAssertEqual(archiveFiles.count, 1, "One new chat makes one archive, never a second conversation store")
        let archive = try XCTUnwrap(archiveFiles.first)
        XCTAssertEqual(try Data(contentsOf: archive), original)
        let previous = try BackendHootChatStore(file: archive)
        let old = await previous.snapshot()
        XCTAssertEqual(old["conversationId"].string, "previous-conversation")
        XCTAssertEqual(old["events"].elements?.first?["value"], event.record.value)
    }
    func testPlansOnlyNarrowTheExistingTokenAtRuntimeWithoutRevokingOrBroadeningIt() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let mode = HOOTSIMPlanState(), effects = HOOTSIMPlanEffects()
        let schema = NativeRPCValue.object([.init("type", .string("object"))])
        let log = BackendDeckCoreSecurityActionLog(directory: root.appendingPathComponent("log"))
        let policies = try [("sessions.list", BackendMCPTier.read), ("sessions.send", .act)].map { id, tier in
            BackendDeckCoreSecurityToolPolicy(tool: try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"),
                description: id, inputSchema: schema, tier: tier), summary: { _, _ in id }, run: { _, _ in
                    await effects.enter(id)
                    return .init(value: .object([.init("fixture", .bool(true))]))
                })
        }
        let control = try BackendDeckCoreSecurityControl(log: log, consent: BackendDeckCoreSecurityConsentBroker(ask: { _ in false }), policies: policies)
        let server = BackendDeckCoreSecurityServer(control: control, ownPorts: BackendDevOwnPorts(), listenerFactory: { _ in HOOTSIMOptionsListener() })
        let endpoint = try await server.start(port: 0)
        let hoot = BackendCopilotSessionSecurityEndpoint(server: server, plansOnly: { await mode.read() })
        let titles: [BackendCopilotLayerTool] = [.init(wire: "sessions_list", tier: "read", title: "List sessions"),
                                               .init(wire: "sessions_send", tier: "act", title: "Send a message")]
        let door = try BackendCopilotSessionMCPDoor(endpoint: hoot, userData: root, titles: { titles })
        do {
            let maybePrepared = try await door.prepare(), prepared = try XCTUnwrap(maybePrepared)
            try await door.bind(prepared, sessionID: "HOOTSIM-plan-fixture")
            let config = try NativeRPCValue.parseJSON(Data(contentsOf: URL(fileURLWithPath: prepared.configPath)))
            let authorization = try XCTUnwrap(config["mcpServers"]["deck-control"]["headers"]["Authorization"].string)
            let maybeGrant = await endpoint.callers.match(authorization: authorization), grant = try XCTUnwrap(maybeGrant)
            await mode.set(true)
            let restricted = await grant.caller()
            XCTAssertEqual(restricted.tiers, [.read])
            for tool in ["sessions_list", "sessions_send"] {
                let body = try NativeRPCValue.object([.init("jsonrpc", .string("2.0")), .init("id", .number(1)),
                    .init("method", .string("tools/call")), .init("params", .object([
                        .init("name", .string(tool)), .init("arguments", .object([]))]))]).encodedJSON()
                _ = await server.respond(.init(method: "POST", path: "/mcp", headers: ["host": "127.0.0.1:\(endpoint.port)",
                    "authorization": authorization, "content-type": "application/json", "accept": "application/json, text/event-stream"], body: body))
            }
            let calls = await effects.read()
            XCTAssertEqual(calls, ["sessions.list"], "Plan mode must refuse messages at the real tool door, not only CLI permission")
            XCTAssertFalse(grant.cancellation.isCancelled, "Plan mode narrows the same lease")
            await mode.set(false)
            let restored = await grant.caller()
            XCTAssertTrue(restored.tiers.contains(.act))
            let narrowRegistration = try await hoot.register(token: "hootsim-render-read-only-token", grant: .init(
                attended: true, allowedTools: ["sessions.list"], allowedTiers: [.read]))
            let maybeNarrow = await endpoint.callers.match(authorization: "Bearer hootsim-render-read-only-token")
            let narrow = try XCTUnwrap(maybeNarrow)
            await mode.set(true)
            let narrowPlanned = await narrow.caller()
            XCTAssertEqual(narrowPlanned.tiers, [.read])
            await mode.set(false)
            let narrowRestored = await narrow.caller()
            XCTAssertEqual(narrowRestored.tiers, [.read], "Leaving plan mode must not widen the underlying grant")
            await hoot.revoke(narrowRegistration)
            await door.release(sessionID: "HOOTSIM-plan-fixture"); await door.stop(); await server.stop()
        } catch { await door.stop(); await server.stop(); throw error }
    }
}

private actor HOOTSIMPlanState {
    private var value = false
    func set(_ next: Bool) { value = next }
    func read() -> Bool { value }
}
private actor HOOTSIMPlanEffects {
    private var calls: [String] = []
    func enter(_ id: String) { calls.append(id) }
    func read() -> [String] { calls }
}

private struct HOOTSIMOptionsListener: BackendDeckCoreSecurityListening {
    func start(port: Int) async throws -> Int { port == 0 ? 43211 : port }
    func stop() async {}
}
