import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// TS vault-profiles.test.ts `wire()`: the whole native account runtime over a short temporary
/// folder (a unix socket path must fit 104 bytes) — profile store, vault with the fake cipher,
/// broker with a fake `security` that answers "not found" (exit 44) and records every call,
/// Codex lease without a watcher, launch adapter, RPC and sign-in service. Nothing reaches a
/// Keychain, the helper binary or a real agent.
final class BackendF4Runtime: @unchecked Sendable {
    let root: URL
    let configuration: BackendAccountConfiguration
    let state: NativeStateStore
    let adapter: BackendAccountLaunchAdapter
    let rpc: BackendAccountRPC
    /// Every argv the broker handed the real `security`.
    let securityCalls: BackendF4Box<[[String]]>
    private(set) var disposed = false
    var profiles: BackendAccountProfileStore { get async { await adapter.profiles } }
    var vault: BackendAccountVault { get async { await adapter.vault } }
    var broker: BackendAccountBroker { get async { await adapter.broker } }
    var codex: BackendAccountCodexLease { get async { await adapter.codex } }

    /// A fresh short root (TS `mkdtempSync('/tmp/tdvp-')`).
    static func makeRoot() throws -> URL {
        var template = Array("/tmp/tdvp-XXXXXX".utf8CString)
        guard let made = mkdtemp(&template) else { throw BackendAccountFailure("no temporary folder") }
        let root = URL(fileURLWithPath: String(cString: made), isDirectory: true)
        for name in ["data", "home"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
        return root
    }
    static func configuration(_ root: URL, environment: [String: String] = ["USER": "me"], helper: URL? = nil) throws -> BackendAccountConfiguration {
        try BackendAccountConfiguration(dataDirectory: root.appendingPathComponent("data"), homeDirectory: root.appendingPathComponent("home"),
            appName: "Terminal Deck Fixture", appID: "terminaldeck", helperExecutable: helper ?? root.appendingPathComponent("never-run-helper"), inheritedEnvironment: environment)
    }

    private init(root: URL, configuration: BackendAccountConfiguration, state: NativeStateStore, adapter: BackendAccountLaunchAdapter, calls: BackendF4Box<[[String]]>) {
        self.root = root; self.configuration = configuration; self.state = state; self.adapter = adapter; securityCalls = calls
        rpc = BackendAccountRPC(accounts: adapter, configuration: configuration, authorizeMutation: { _ in })
    }

    /// TS `wire(cipher)`; throws where TS `wireRaw` answers null (the vault did not start).
    static func wire(root existing: URL? = nil, cipher: any BackendAccountVaultCipher = BackendF4FakeCipher(),
                     environment: [String: String] = ["USER": "me"], helper: URL? = nil,
                     runner: BackendAccountSecurityRunner? = nil) async throws -> BackendF4Runtime {
        let root = try existing ?? makeRoot()
        let configuration = try Self.configuration(root, environment: environment, helper: helper)
        let state = try NativeStateStore(file: configuration.dataDirectory.appendingPathComponent("state.json"), ownership: .exclusive, clock: { 1_000 })
        let calls = BackendF4Box<[[String]]>([])
        do {
            let profiles = try BackendAccountProfileStore(configuration: configuration, stateStore: state)
            let vault = try BackendAccountVault(configuration: configuration, stateStore: state, vaultCipher: cipher)
            let broker: BackendAccountBroker
            do {
                broker = try await BackendAccountBroker.offline(configuration: configuration, profiles: profiles, vault: vault,
                    runner: runner ?? { argv, _ in calls.update { $0.append(argv) }; return .init(code: 44, stdout: "", stderr: "") })
            } catch { await vault.close(); await profiles.close(); throw error }
            // As the app wires it (TS wire.ts); watchers are driven by the Codex lease's own tests.
            let codex = BackendAccountCodexLease.wired(vault: vault, profiles: profiles, inUse: { _ in false }, watch: { _, _ in { } })
            let adapter = try BackendAccountLaunchAdapter(configuration: configuration, profiles: profiles, vault: vault, broker: broker, codex: codex)
            do { try await adapter.prepareExistingAccounts() } catch { _ = await adapter.shutdown(); throw error }
            return BackendF4Runtime(root: root, configuration: configuration, state: state, adapter: adapter, calls: calls)
        } catch {
            await state.close()
            if existing == nil { try? FileManager.default.removeItem(at: root) }
            throw error
        }
    }
    /// TS `handle.dispose()`: quit — Codex files released, broker closed, vault and store closed.
    @discardableResult
    func dispose(removeRoot: Bool = false) async -> [String: BackendAccountCodexLease.Release] {
        guard !disposed else { return [:] }
        disposed = true
        let releases = await adapter.shutdown()
        await state.close()
        if removeRoot { try? FileManager.default.removeItem(at: root) }
        return releases
    }

    /// TS `createProfile(name, options)` with the vault running.
    func create(_ name: String, provider: String = "claude", configDir: String? = nil) async throws -> BackendAccountProfile {
        try await adapter.createProfile(name: name, provider: provider, configDir: configDir)
    }
    /// TS `vault.put(id, provider, slot, value, 'sign-in')`.
    @discardableResult
    func put(_ id: String, _ value: String, provider: String = "claude", slot: String = "keychain:Claude Code-credentials") async -> BackendAccountVaultWrite {
        await vault.write(accountID: id, provider: provider, slot: slot, value: value, source: "sign-in")
    }
    /// The profiles list (`profiles:list`) and its `vault` view of one account (TS profileKeptBy / vaultSignedIn).
    func listed(_ provider: String? = nil) async throws -> NativeRPCValue {
        try await rpc.invoke("profiles:list", args: provider.map { [.string($0)] } ?? [], context: BackendF4Runtime.context)
    }
    func keptBy(_ id: String) async throws -> String? { try await listed()["vault"][id]["keptBy"].string }
    func signedIn(_ id: String) async throws -> NativeRPCValue { try await listed()["vault"][id]["signedIn"] }

    /// TS `sessionEnv(profile, provider)`: the account environment a launch gets, without a session seat
    /// (an app-composed launch takes no seat; the per-account ticket is what sessionEnv carries).
    func sessionEnv(_ profile: BackendAccountProfile, _ provider: String = "claude") async throws -> (environment: [String: String], path: String) {
        var input = BackendCreateSessionInput(cwd: root.path, cols: 80, rows: 24, provider: provider)
        input.profileId = profile.id
        let spec = BackendProviderSpec(id: provider, command: "/bin/sh", args: ["-c", "true"], resumeArgs: [])
        let launch = try await adapter.resolve(input, provider: spec, loginPath: "/usr/bin:/bin", context: BackendLaunchContext(isAppComposed: true))
        await adapter.abandon(launch)
        return (launch.environment, launch.path)
    }
    /// TS `answerShim(find(ticket, configDir), deps)`.
    func find(_ ticket: String, configDir: String) async -> BackendAccountVaultServer.WireAnswer {
        let suffix = String(BackendAccountSwitchInPlace.sha256Hex(configDir).prefix(8))
        let request = BackendAccountVaultServer.Request(ticket: ticket, argv: ["find-generic-password", "-a", "me", "-w", "-s", "Claude Code-credentials-\(suffix)"], stdin: "")
        return await BackendAccountVaultServer.answerShim(request, deps: await broker.deps)
    }
    var ticketKey: String { configuration.ticketEnvironment }
    var socketKey: String { configuration.socketEnvironment }

    /// The sign-in service over this runtime, with a fake executor that records every run.
    func signIn(executor: BackendF4Executor) throws -> BackendAppAccountSignInService {
        let providers = try BackendNativeProviders(store: state, dataRoot: configuration.dataDirectory, inheritedEnvironment: [:],
                                                   home: configuration.homeDirectory.path, runner: BackendCommandRunner())
        let native = BackendAppAccountSignInNativeDependencies(accounts: adapter, providers: providers, configuration: configuration)
        return BackendAppAccountSignInService(dependencies: BackendF4SignInDependencies(native: native),
            executor: executor, clock: BackendAppSessionSystemClock(), authorizeMetadata: { _ in }, authorizeMutation: { _ in })
    }
    static let context = NativeRPCContext(caller: .nativeApp, ownerID: "f4")
}

/// The real native sign-in dependencies with the binary lookup pinned (no PATH probing).
struct BackendF4SignInDependencies: BackendAppAccountSignInDependencies {
    let native: BackendAppAccountSignInNativeDependencies
    var configuration: BackendAccountConfiguration { native.configuration }
    func find(_ id: String) async throws -> BackendAccountProfile? { try await native.find(id) }
    func managed(_ profile: BackendAccountProfile) async -> Bool { await native.managed(profile) }
    func summaries() async throws -> [BackendAccountVaultSummary] { try await native.summaries() }
    func vaultUsable() async -> Bool { await native.vaultUsable() }
    func loginPath() async throws -> String { "/usr/bin:/bin" }
    func binary(_ provider: String, path: String, refresh: Bool) async -> BackendNativeProviders.Binary {
        .init(id: provider, onPath: "/fixture/bin/" + provider, runnable: "/fixture/bin/" + provider, version: "fixture", broken: false, said: nil, usedAlternate: false, checkedAt: Date())
    }
    func probeEnvironment(_ profile: BackendAccountProfile, provider: String, path: String) async throws -> [String: String] {
        try await native.probeEnvironment(profile, provider: provider, path: path)
    }
    func recheck(_ profile: BackendAccountProfile) async throws { try await native.recheck(profile) }
    func readJSON(_ file: URL) -> NativeRPCValue { native.readJSON(file) }
    func nonEmptyFile(_ file: URL) -> Bool { native.nonEmptyFile(file) }
}

/// A command executor that runs nothing: it records the call and answers as told.
final class BackendF4Executor: BackendAppSessionCommandExecuting, @unchecked Sendable {
    let runs = BackendF4Box<[(command: String, arguments: [String], environment: [String: String])]>([])
    let answer: BackendAppSessionCommandResult
    init(answer: BackendAppSessionCommandResult = .init(stdout: "{\"loggedIn\":false}", exitCode: 0)) { self.answer = answer }
    func run(_ command: String, arguments: [String], environment: [String: String], cwd: String, timeoutMilliseconds: Int, maximumBytes: Int) async -> BackendAppSessionCommandResult {
        runs.update { $0.append((command, arguments, environment)) }
        return answer
    }
    func detach(_ command: String, arguments: [String], environment: [String: String], cwd: String) async throws {
        runs.update { $0.append((command, arguments, environment)) }
    }
}
