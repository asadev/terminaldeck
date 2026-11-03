import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

private struct AGSProofProvider: BackendProviderLaunchResolver {
    let readiness: BackendLaunchReadiness = .ready
    let binary: String
    func loginPath() async throws -> String { "/usr/bin:/bin" }
    func resolve(_ input: BackendCreateSessionInput, loginPath: String) async throws -> BackendProviderSpec {
        .init(id: "claude", command: binary, args: [], resumeArgs: [])
    }
}
private struct AGSProofAccounts: BackendAccountLaunchResolver {
    let readiness: BackendLaunchReadiness = .ready
    func resolve(_ input: BackendCreateSessionInput, provider: BackendProviderSpec, loginPath: String, context: BackendLaunchContext) async throws -> BackendAccountLaunch { .init(profile: nil, environment: [:], path: loginPath) }
    func continuingConversationID(_ input: BackendCreateSessionInput, account: BackendAccountLaunch, live: [BackendSessionMeta]) async throws -> String? { nil }
    func bind(_ account: BackendAccountLaunch, session: BackendSessionMeta) async throws {}
    func abandon(_ account: BackendAccountLaunch) async {}
    func exited(sessionID: String) async {}
}
private struct AGSProofConfinement: BackendConfinementLaunchResolver {
    let readiness: BackendLaunchReadiness = .ready
    func resolve(command: String, args: [String], input: BackendCreateSessionInput, account: BackendAccountLaunch, context: BackendLaunchContext) async throws -> BackendConfinedLaunch {
        .init(command: command, args: args, environment: context.environmentOverrides)
    }
}
private struct AGSProofLedger: BackendSessionLedger {
    let readiness: BackendLaunchReadiness = .ready
    func tabKey(_ input: BackendCreateSessionInput, context: BackendLaunchContext, live: [BackendSessionMeta]) async throws -> String? { nil }
    func started(_ session: BackendSessionMeta, input: BackendCreateSessionInput, context: BackendLaunchContext) async throws {}
    func removed(sessionID: String, reason: BackendRemovalReason) async {}
}
private struct AGSProofProject: BackendProjectMCPSource {
    let readiness: BackendLaunchReadiness = .ready
    func resolve(cwd: String, provider: String, loginPath: String) async throws -> BackendProjectMCPDefinition? { nil }
}
private struct AGSProofEndpoint: BackendMCPToolEndpoint {
    let readiness: BackendLaunchReadiness = .ready
    func description() async throws -> BackendMCPEndpointDescription? { nil }
    func catalogue() async throws -> [BackendMCPTool] { [] }
    func register(token: String, grant: BackendMCPCallerGrant) async throws -> BackendMCPRegistration { XCTFail("Disabled server issued a token"); return .init(id: UUID()) }
    func bind(_ registration: BackendMCPRegistration, sessionID: String, machineID: String) async throws {}
    func revoke(_ registration: BackendMCPRegistration) async {}
}
private struct AGSProofCipher: BackendAccountVaultCipher {
    func available() -> Bool { true }
    func prepareForWrites(existingVault: Bool) throws {}
    func encrypt(_ text: String, existingVault: Bool) throws -> Data { Data(text.utf8.map { $0 ^ 0xa5 }) }
    func decrypt(_ blob: Data) throws -> String { String(decoding: blob.map { $0 ^ 0xa5 }, as: UTF8.self) }
}
final class AGSActualLaunchProofTests: XCTestCase, @unchecked Sendable {
    func testSavedAgentEffortAndPrivateHookReachActualStubProcess() async throws {
        guard let binary = ProcessInfo.processInfo.environment["AGS_STUB_CLI"] else { throw XCTSkip("Run with the AGS scratch stub binary") }
        try await BackendFoundationTestsAccountsWithFixture { fixture in
            let directory = fixture.configuration.dataDirectory
            let capture = directory.appendingPathComponent("capture.json")
            let marker = directory.appendingPathComponent("hook-ran")
            let persistence = try BackendTaskPersistence(directory: directory, ownership: .exclusive)
            let settingsStore = BackendAGSStore(persistence: persistence, cipher: AGSProofCipher())
            try await settingsStore.start()
            let config = try BackendTaskConfiguration(persistence: persistence)
            try await config.start(); try await config.bindAGS(settingsStore)
            let settings = AGSAgentSettings(provider: "claude", effort: "high", mcpServers: ["deck-control": false],
                hooks: [.init(event: "SessionStart", command: "/usr/bin/touch " + "'" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'")],
                environment: ["AGS_CAPTURE_PATH": capture.path])
            let row: NativeRPCValue = .object([.init("id", .string("proof-agent")), .init("name", .string("Proof agent")), .init("provider", .string("claude"))])
            _ = try await config.saveAgentWithAGS(row, settings: settings, expectedRevision: 0)
            let provider = AGSProofProvider(binary: binary)
            let tools = try BackendSessionToolLeases(endpoint: AGSProofEndpoint(), userData: directory)
            let project = try BackendProjectToolComposition(source: AGSProofProject(), userData: directory, inheritedEnvironment: [:])
            let manager = BackendPTYManager(inheritedEnvironment: ["HOME": fixture.configuration.homeDirectory.path]) { _ in }
            let deps = try BackendSessionLaunchDependencies(providers: provider, accounts: AGSProofAccounts(), confinement: AGSProofConfinement(),
                instructions: BackendNativeInstructions(storageRoot: directory), ledger: AGSProofLedger())
            let launcher = BackendSessionLauncher(manager: manager, dependencies: deps)
            let coordinated = try BackendCoordinatedSessionLaunch(launcher: launcher, providers: provider, sessionTools: tools, projectTools: project,
                reach: BackendBrowserToolReachAdapter(readiness: .ready, reachesDeviceWindows: { _ in false }, hostHoldsWindows: { false }))
            let facts = BackendAGSSelectedAccountFacts(providers: provider, profiles: fixture.profiles, configuration: fixture.configuration, projectRoot: { $0 })
            let binding = BackendAGSLaunchBinding(facts: facts, reserve: { try await tools.reserveAgentSettingsFiles() }, authorize: { _, _ in })
            let choices = BackendAGSSessionChoices(persistence: persistence, cipher: AGSProofCipher()); try await choices.start()
            try await coordinated.setAgentSettingsBinding(binding, choices: choices)
            let resolver = BackendINT2AGSLaunch(store: settingsStore, configuration: config, defaultProvider: { "claude" }, taskProfile: { _ in "proof-agent" })
            try await coordinated.setAgentSettingsResolver { try await resolver.resolve($0, context: $1) }
            var input = BackendCreateSessionInput(cwd: fixture.configuration.homeDirectory.path, provider: "claude")
            input.taskID = "proof-task"
            let session = try await coordinated.create(input, context: BackendLaunchContext(rememberTab: false))
            do {
                let deadline = Date().addingTimeInterval(10)
                while !FileManager.default.fileExists(atPath: capture.path), Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
                let value = try NativeRPCValue.parseJSON(Data(contentsOf: capture))
                let args = value["arguments"].elements?.compactMap(\.string) ?? []
                let index = try XCTUnwrap(args.firstIndex(of: "--effort"))
                XCTAssertEqual(args[index + 1], "high")
                XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
                XCTAssertTrue(args.contains("--settings"))
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.configuration.homeDirectory.appendingPathComponent(".claude/settings.json").path))
                print("AGS scratch launch: saved proof-agent effort=high; private SessionStart hook created marker; global settings unchanged")
            } catch { manager.kill(session.session.id); _ = await coordinated.stop(); throw error }
            manager.kill(session.session.id); _ = await coordinated.stop()
            XCTAssertEqual(manager.list().filter { $0.exitCode == nil }.count, 0)
        }
    }
}
