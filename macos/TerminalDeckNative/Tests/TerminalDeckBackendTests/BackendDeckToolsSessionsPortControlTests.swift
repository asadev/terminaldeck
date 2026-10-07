import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor final class BackendDeckToolsSessionsPortControlTests: XCTestCase {
    private typealias V = BackendDeckToolsSessionsPortValues
    private typealias F = BackendDeckCoreTestPortToolsFixture
    private func using(_ id: String, approval: BackendDeckCoreTestPortSecurityRig.Approval,
                       _ operation: @MainActor (BackendDeckCoreTestPortSecurityRig, BackendDeckCoreTestPortToolsApplicationFake) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendDeckToolsSessionsPortControl-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = BackendDeckCoreTestPortToolsApplicationFake(), audit = BackendDeckCoreTestPortToolsAudit()
        let definitions = id == "voice.save_key" ? try BackendDeckToolsAppVoice.definitions(service: fake, access: F.access(audit)) : try BackendDeckToolsAppApplication.definitions(service: fake, settings: fake, access: F.access(audit))
        let definition = try XCTUnwrap(definitions.first { $0.spec.id == id })
        let policy = BackendDeckCoreSecurityToolPolicy(tool: definition.spec, aliases: definition.aliases, summary: { _, _ in definition.title },
            redactArgs: { BackendDeckToolsAppKit.redacted(id, $0) }, run: { args, context in
                let reply = try await definition.handler(context.native, args)
                if reply.isError { throw NativeRPCError(code: "area-error", message: V.error(reply)) }
                return .init(value: reply.structuredContent ?? .null)
            })
        let gate = try BackendDeckCoreTestPortSecurityRig(directory: root, approval: approval, extras: [policy])
        try await operation(gate, fake)
    }
    func testAgentsAreaControlL68VoiceCredentialNeverReachesRealActionLogOrConsent() async throws {
        try await using("voice.save_key", approval: .allow) { gate, _ in
            let result = await gate.call("voice_save_key", V.object([("provider", .string("groq")), ("key", .string("gsk_live_do_not_log_me"))]))
            XCTAssertTrue(result.ok); XCTAssertEqual(gate.questions.get().count, 1)
            XCTAssertFalse(gate.questions.get()[0].wireValue.compact.contains("gsk_live"))
            let logFile = await gate.log.file; let text = try String(contentsOf: logFile, encoding: .utf8); XCTAssertFalse(text.contains("gsk_live"))
        }
    }
    func testAgentsAreaControlL77NestedMCPEnvironmentCredential_SeamNeeded() throws {
        throw XCTSkip("Actual mcp-server-tools factory/metadata is absent. Exact intent: mcp_add with GITHUB_PERSONAL_ACCESS_TOKEN must complete through real central consent/log gate; log retains field name but never ghp_do_not_log_me. Do not manufacture a fake mcp.add policy.")
    }
    func testAgentsAreaControlL93DeclinePreventsSettingsReset() async throws {
        try await using("settings.reset", approval: .decline) { gate, fake in
            let result = await gate.call("settings_reset")
            XCTAssertFalse(result.ok); XCTAssertEqual(result.refusal, .declined)
            let settings = await fake.currentSettings(); XCTAssertTrue(settings.has("appearance.density"))
        }
    }
    func testAgentsAreaControlL101UnattendedResetNeverAsksOrMutates() async throws {
        try await using("settings.reset", approval: .allow) { gate, fake in
            let result = await gate.call("settings_reset", .object([]), .init(attended: false))
            XCTAssertEqual(result.refusal, .unattended); XCTAssertEqual(gate.questions.get().count, 0)
            let settings = await fake.currentSettings(); XCTAssertTrue(settings.has("appearance.density"))
        }
    }
    func testAgentsAreaControlL109AllowedResetOnlyChangesUnprotectedSettings() async throws {
        try await using("settings.reset", approval: .allow) { gate, fake in
            let result = await gate.call("settings_reset")
            XCTAssertTrue(result.ok); XCTAssertEqual(gate.questions.get().count, 1)
            let settings = await fake.currentSettings(); XCTAssertEqual(settings, V.object([("remote.enabled", .bool(true)), ("advanced.debugMode", .bool(false))]))
        }
    }
}
