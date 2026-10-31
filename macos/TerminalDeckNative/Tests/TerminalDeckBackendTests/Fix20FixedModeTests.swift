import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class Fix20FixedModeTests: XCTestCase {
    func testRestartRejectsAModeChangeAndKeepsAnUnspecifiedMode() throws {
        for original in [nil, false, true] as [Bool?] {
            let expected = original == true
            XCTAssertThrowsError(try BackendSessionLifecycleCoordinator.replacementMode(requested: !expected, original: original))
            XCTAssertEqual(try BackendSessionLifecycleCoordinator.replacementMode(requested: nil, original: original), expected)
            XCTAssertEqual(try BackendSessionLifecycleCoordinator.replacementMode(requested: expected, original: original), expected)
        }
    }
    func testMCPRegistrationRejectsTheRetiredReopenToolWithoutChangingTheServer() async throws {
        let server = BackendNativeMCPServer()
        let definitions = try BackendDeckCoreTestPortS1CatalogueCostSources.deckToolDefinitions()
        _ = try await BackendDeckToolsRegistration.register(on: server, definitions: definitions)
        let before = Set(await server.registrations().map { $0.0.id })
        let spec = try BackendMCPTool(id: "sessions.reopen", wireName: "sessions_reopen", description: "Retired mode change",
            inputSchema: .object([.init("type", .string("object"))]), tier: .act)
        let retired = BackendDeckToolsDefinition(spec: spec, title: spec.description) { _, _ in .value(.string("must never be installed")) }
        do {
            _ = try await BackendDeckToolsRegistration.register(on: server, definitions: definitions + [retired])
            XCTFail("The retired mode-changing tool was installed")
        } catch { }
        let after = Set(await server.registrations().map { $0.0.id })
        XCTAssertEqual(before, after)
        XCTAssertFalse(after.contains("sessions.reopen"))
        for task in [nil, "task"] as [String?] {
            let grant = BackendTAGToolPolicy.sessionNames(taskID: task)
            XCTAssertFalse(grant.contains("sessions.reopen"))
            XCTAssertFalse(grant.contains("sessions_reopen"))
        }
    }
    func testAccountAndAIChangesKeepTheSavedMode() throws {
        for chat in [false, true] {
            var original = BackendCreateSessionInput(cwd: "/scratch", provider: "claude")
            original.chat = chat
            let saved = try BackendSessionSaved(BackendSessionSaved.from(original))
            for provider in ["claude", "codex", "gemini"] {
                let target = BackendAccountProfile(id: "new-account", name: "New account", provider: provider,
                    configDir: "/scratch/account", system: false, color: "--accent", createdAt: 0)
                let (input, remembered) = BackendSessionChatSwitch.relaunch(saved: saved, target: target, from: "claude", replacing: "running")
                XCTAssertEqual(input.chat == true, chat)
                XCTAssertEqual(remembered["chat"].bool == true, chat)
                XCTAssertEqual(input.profileId, target.id)
                XCTAssertEqual(input.provider, provider)
            }
        }
    }
    func testOnlyNewSessionsUseTheRememberedChoiceAndAIDefault() {
        let person = BackendLaunchContext(rememberTab: true, fromWindow: true)
        let ai = BackendLaunchContext(fromAI: true)
        XCTAssertFalse(BackendSessionLifecycleCoordinator.startsAsChat(context: person, remembered: "terminal"))
        XCTAssertTrue(BackendSessionLifecycleCoordinator.startsAsChat(context: person, remembered: "chat"))
        XCTAssertTrue(BackendSessionLifecycleCoordinator.startsAsChat(context: ai, remembered: "terminal"))
        var existing = BackendCreateSessionInput(cwd: "/scratch", provider: "claude")
        existing.replaces = "running"
        XCTAssertFalse(BackendSessionLifecycleCoordinator.choosesMode(existing, context: person, restoring: false))
    }
}
