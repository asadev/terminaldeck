import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

private struct AGSBindingProviders: BackendProviderLaunchResolver {
    let readiness: BackendLaunchReadiness = .ready
    func loginPath() async throws -> String { "/usr/bin:/bin" }
    func resolve(_ input: BackendCreateSessionInput, loginPath: String) async throws -> BackendProviderSpec {
        .init(id: input.provider ?? "claude", command: "/usr/bin/true", args: [], resumeArgs: [])
    }
}
private actor AGSBindingProbeLog {
    var environments: [[String: String]] = [], calls: [[String]] = []
    func note(_ args: [String], _ environment: [String: String]) { calls.append(args); environments.append(environment) }
}
private struct AGSBindingProbe: BackendAppSessionCommandExecuting {
    let log: AGSBindingProbeLog
    var export = "[]", help = "--model --effort --permission-mode --tools --allowedTools --disallowedTools --mcp-config --strict-mcp-config --settings --config --sandbox --ask-for-approval"
    func run(_ command: String, arguments: [String], environment: [String: String], cwd: String, timeoutMilliseconds: Int, maximumBytes: Int) async -> BackendAppSessionCommandResult {
        await log.note(arguments, environment)
        return .init(stdout: arguments == ["mcp", "list", "--json"] ? export : arguments == ["mcp", "list", "--help"] ? "--json" : help, exitCode: 0)
    }
    func detach(_ command: String, arguments: [String], environment: [String: String], cwd: String) async throws { XCTFail("Facts must never detach a process") }
}
private actor AGSBindingLeaseLog { var writes = 0, binds = 0, abandons = 0; func write() { writes += 1 }; func bind() { binds += 1 }; func abandon() { abandons += 1 } }
private struct AGSBindingCipher: BackendAccountVaultCipher {
    func available() -> Bool { true }
    func prepareForWrites(existingVault: Bool) throws {}
    func encrypt(_ text: String, existingVault: Bool) throws -> Data { Data(text.utf8.map { $0 ^ 0xa5 }) }
    func decrypt(_ blob: Data) throws -> String { String(decoding: blob.map { $0 ^ 0xa5 }, as: UTF8.self) }
}
final class AGSLaunchBindingTests: XCTestCase, @unchecked Sendable {
    func testSelectedAccountHelpUsesItsOwnEnvironmentAndPreservesRawMCPHeaders() async throws {
        try await BackendFoundationTestsAccountsWithFixture { fixture in
            let account = try await fixture.create("work")
            try FileManager.default.createDirectory(atPath: account.configDir, withIntermediateDirectories: true)
            let raw = #"{"mcpServers":{"private":{"type":"http","url":"https://example.com/mcp","headers":{"Authorization":"private-token"}}}}"#
            try Data(raw.utf8).write(to: URL(fileURLWithPath: account.configDir).appendingPathComponent(".claude.json"))
            let log = AGSBindingProbeLog()
            let source = BackendAGSSelectedAccountFacts(providers: AGSBindingProviders(), profiles: fixture.profiles, configuration: fixture.configuration, projectRoot: { $0 }, command: AGSBindingProbe(log: log))
            var input = BackendCreateSessionInput(cwd: fixture.configuration.homeDirectory.path, provider: "claude"); input.profileId = account.id
            let snapshot = try await source.capture(input, context: .init())
            XCTAssertEqual(snapshot.account.id, account.id)
            XCTAssertEqual(snapshot.servers["private"]["headers"]["Authorization"].string, "private-token")
            let environments = await log.environments; XCTAssertEqual(environments.first?["CLAUDE_CONFIG_DIR"], account.configDir)
            XCTAssertEqual(snapshot.provider.command, "/usr/bin/true")
        }
    }
    func testMalformedSelectedAccountConfigIsNotAnEmptySuccess() async throws {
        try await BackendFoundationTestsAccountsWithFixture { fixture in
            let account = try await fixture.create("work")
            try FileManager.default.createDirectory(atPath: account.configDir, withIntermediateDirectories: true)
            try Data("not json".utf8).write(to: URL(fileURLWithPath: account.configDir).appendingPathComponent(".claude.json"))
            let source = BackendAGSSelectedAccountFacts(providers: AGSBindingProviders(), profiles: fixture.profiles, configuration: fixture.configuration, projectRoot: { $0 }, command: AGSBindingProbe(log: AGSBindingProbeLog()))
            var input = BackendCreateSessionInput(cwd: fixture.configuration.homeDirectory.path, provider: "claude"); input.profileId = account.id
            do { _ = try await source.capture(input, context: .init()); XCTFail("Malformed config passed") } catch let error as NativeRPCError { XCTAssertEqual(error.code, "unavailable") }
        }
    }
    func testCodexStructuredExportUsesSelectedAccountAndIncludesDisabledServers() async throws {
        try await BackendFoundationTestsAccountsWithFixture { fixture in
            let account = try await fixture.create("work", provider: "codex")
            let log = AGSBindingProbeLog()
            let exported = #"[{"name":"private","enabled":false,"transport":{"type":"stdio","command":"/usr/bin/true"}}]"#
            let source = BackendAGSSelectedAccountFacts(providers: AGSBindingProviders(), profiles: fixture.profiles, configuration: fixture.configuration, projectRoot: { $0 }, command: AGSBindingProbe(log: log, export: exported))
            var input = BackendCreateSessionInput(cwd: fixture.configuration.homeDirectory.path, provider: "codex"); input.profileId = account.id
            let snapshot = try await source.capture(input, context: .init())
            XCTAssertEqual(snapshot.serverNames, ["private"]); XCTAssertEqual(snapshot.servers["private"]["enabled"].bool, false)
            let environments = await log.environments; XCTAssertTrue(environments.allSatisfy { $0["CODEX_HOME"] == account.configDir })
            let calls = await log.calls; XCTAssertEqual(calls.last, ["mcp", "list", "--json"])
        }
    }
    func testAccountFactsRecheckRefusesChangedConfigBeforeMaterialization() async throws {
        try await BackendFoundationTestsAccountsWithFixture { fixture in
            let account = try await fixture.create("work")
            try FileManager.default.createDirectory(atPath: account.configDir, withIntermediateDirectories: true)
            let source = BackendAGSSelectedAccountFacts(providers: AGSBindingProviders(), profiles: fixture.profiles, configuration: fixture.configuration, projectRoot: { $0 }, command: AGSBindingProbe(log: AGSBindingProbeLog()))
            var input = BackendCreateSessionInput(cwd: fixture.configuration.homeDirectory.path, provider: "claude"); input.profileId = account.id
            let snapshot = try await source.capture(input, context: .init())
            try Data(#"{"effortLevel":"high"}"#.utf8).write(to: URL(fileURLWithPath: account.configDir).appendingPathComponent("settings.json"))
            do { try await source.recheck(snapshot, input: input, context: .init()); XCTFail("Changed facts passed") } catch let error as NativeRPCError { XCTAssertEqual(error.code, "unavailable") }
        }
    }
    func testMissingHelpAndUnsupportedServerFailBeforeFileWrites() async throws {
        try await BackendFoundationTestsAccountsWithFixture { fixture in
            let source = BackendAGSSelectedAccountFacts(providers: AGSBindingProviders(), profiles: fixture.profiles, configuration: fixture.configuration, projectRoot: { $0 }, command: AGSBindingProbe(log: AGSBindingProbeLog(), help: ""))
            do { _ = try await source.capture(.init(cwd: fixture.configuration.homeDirectory.path, provider: "claude"), context: .init()); XCTFail("Empty help passed") } catch let error as NativeRPCError { XCTAssertEqual(error.code, "unavailable") }
        }
        let incomplete: NativeRPCValue = .array([.object([.init("name", .string("missing-transport")), .init("enabled", .bool(true))])])
        XCTAssertThrowsError(try BackendAGSSelectedAccountFacts.codexServers(incomplete))
    }
    func testGrantIsNarrowedBeforeTokenIssuerAndServerOffIssuesNone() {
        let settings = AGSAgentSettings(allowedTools: ["mcp__deck-control__browser_read"], deniedTools: ["mcp__deck-control__browser_step"], mcpServers: ["off": false])
        XCTAssertEqual(BackendAGSLaunchBinding.grant(["browser.read", "browser.step"], server: "deck-control", settings: settings), ["browser.read"])
        XCTAssertTrue(BackendAGSLaunchBinding.grant(["browser.read"], server: "off", settings: settings).isEmpty)
        XCTAssertTrue(BackendAGSLaunchBinding.grant(["browser.read"], server: "deck-control", settings: .init(allowedTools: [])).isEmpty)
    }
    func testLegacyScalarFlagsAreRemovedWithoutDroppingOwnedInstructionsOrMCP() {
        let args = ["--effort", "high", "--model=old", "--permission-mode", "bypassPermissions", "-c", "model_reasoning_effort=\"high\"", "--append-system-prompt-file", "/private/owned.md", "--mcp-config", "/private/owned-mcp.json"]
        XCTAssertEqual(BackendAGSLaunchBinding.removingScalarOverrides(args), ["--append-system-prompt-file", "/private/owned.md", "--mcp-config", "/private/owned-mcp.json"])
    }
    func testRemoteFactsAreRefusedWithoutAnyCLIProbe() async throws {
        try await BackendFoundationTestsAccountsWithFixture { fixture in
            let log = AGSBindingProbeLog()
            let source = BackendAGSSelectedAccountFacts(providers: AGSBindingProviders(), profiles: fixture.profiles, configuration: fixture.configuration, projectRoot: { $0 }, command: AGSBindingProbe(log: log))
            do { _ = try await source.capture(.init(cwd: fixture.configuration.homeDirectory.path), context: .init(deviceBoundary: .init(deviceKey: "phone", folder: fixture.configuration.homeDirectory.path))); XCTFail("Remote borrowed local facts") } catch let error as NativeRPCError { XCTAssertEqual(error.code, "unavailable") }
            let calls = await log.calls; XCTAssertTrue(calls.isEmpty)
        }
    }
    func testFailedPlanAbandonsExistingOwnerLeaseAndNeverWrites() async throws {
        try await BackendFoundationTestsAccountsWithFixture { fixture in
            let source = BackendAGSSelectedAccountFacts(providers: AGSBindingProviders(), profiles: fixture.profiles, configuration: fixture.configuration, projectRoot: { $0 }, command: AGSBindingProbe(log: AGSBindingProbeLog()))
            let log = AGSBindingLeaseLog()
            let binding = BackendAGSLaunchBinding(facts: source, reserve: {
                .init(id: UUID(), directory: fixture.configuration.dataDirectory.appendingPathComponent("existing-owned-lease"), write: { _ in await log.write() }, bind: { _ in await log.bind() }, abandon: { await log.abandon() })
            }, authorize: { _, _ in })
            do { _ = try await binding.prepare(.init(cwd: fixture.configuration.homeDirectory.path, provider: "claude"), settings: .init(mcpServers: ["unknown": true]), context: .init(), nativeServerNames: []); XCTFail("Unknown server passed") } catch {}
            let writes = await log.writes, abandoned = await log.abandons; XCTAssertEqual(writes, 0); XCTAssertEqual(abandoned, 1)
        }
    }
    func testRestoredSessionChoiceIsEncryptedAndSeparateFromTaskProfiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ags-choice-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = try BackendTaskPersistence(directory: directory, ownership: .exclusive)
        let store = BackendAGSSessionChoices(persistence: persistence, cipher: AGSBindingCipher()); try await store.start()
        let settings = AGSAgentSettings(effort: "high", hooks: [.init(command: "true")], environment: ["TOKEN": "private-secret"])
        try await store.save(tabKey: "stable-tab", settings: settings)
        let bytes = try Data(contentsOf: directory.appendingPathComponent("ags-session-choices.json")); XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("private-secret"))
        let restored = BackendAGSSessionChoices(persistence: persistence, cipher: AGSBindingCipher()); try await restored.start()
        let choice = try await restored.choice(tabKey: "stable-tab"); XCTAssertEqual(choice, settings)
        try await restored.remove(tabKey: "stable-tab"); let removed = try await restored.choice(tabKey: "stable-tab"); XCTAssertNil(removed)
    }
    func testDisabledNativeServerNeedsNoGeneratedTokenConfiguration() async throws {
        try await BackendFoundationTestsAccountsWithFixture { fixture in
            let source = BackendAGSSelectedAccountFacts(providers: AGSBindingProviders(), profiles: fixture.profiles, configuration: fixture.configuration, projectRoot: { $0 }, command: AGSBindingProbe(log: AGSBindingProbeLog()))
            let log = AGSBindingLeaseLog()
            let binding = BackendAGSLaunchBinding(facts: source, reserve: {
                .init(id: UUID(), directory: fixture.configuration.dataDirectory.appendingPathComponent("existing-owned-lease"), write: { files in
                    let bytes = try XCTUnwrap(files["ags-complete-mcp.json"])
                    let config = try NativeRPCValue.parseJSON(bytes)
                    XCTAssertTrue(config["mcpServers"].fields?.isEmpty == true)
                    await log.write()
                }, bind: { _ in await log.bind() }, abandon: { await log.abandon() })
            }, authorize: { _, _ in })
            let input = BackendCreateSessionInput(cwd: fixture.configuration.homeDirectory.path, provider: "claude")
            let prepared = try await binding.prepare(input, settings: .init(mcpServers: ["deck-control": false]), context: .init(), nativeServerNames: ["deck-control"])
            let context = try await binding.stage(prepared, generatedServers: .object([]), context: .init(), originalInput: input)
            XCTAssertTrue(context.extraArguments.contains("--strict-mcp-config"))
            let writes = await log.writes; XCTAssertEqual(writes, 1)
        }
    }
    func testFullSessionSnapshotRestoresHooksOnceAndSupportsRemoval() throws {
        let profile = AGSAgentSettings(hooks: [.init(command: "true")], environment: ["OLD": "secret"])
        let restored = try BackendAGSPolicy.resolve(defaults: nil, profile: profile, session: profile)
        XCTAssertEqual(restored.hooks, profile.hooks)
        let removed = try BackendAGSPolicy.resolve(defaults: nil, profile: profile, session: .init())
        XCTAssertTrue(removed.hooks.isEmpty); XCTAssertTrue(removed.environment.isEmpty)
    }
    func testServerGroupCanNarrowToOneToolAndBroaderDenyIsKept() throws {
        let parent = AGSAgentSettings(allowedTools: ["mcp__private"], deniedTools: ["mcp__other__write"])
        let child = AGSAgentSettings(allowedTools: ["mcp__private__read"], deniedTools: ["mcp__other"])
        let resolved = try BackendAGSPolicy.resolve(defaults: parent, profile: child)
        XCTAssertEqual(resolved.allowedTools, ["mcp__private__read"])
        XCTAssertNoThrow(try BackendAGSPolicy.requireNarrowing(child, owner: parent))
        XCTAssertThrowsError(try BackendAGSPolicy.requireNarrowing(parent, owner: child))
    }

}
