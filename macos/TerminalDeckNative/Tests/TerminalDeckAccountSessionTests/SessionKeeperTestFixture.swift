#if TD_HOST_ACCOUNT_BRIDGE && TD_HOST_INTEGRATED
import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class KeeperTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func add(_ value: String) { lock.withLock { entries.append(value) } }
    var values: [String] { lock.withLock { entries } }
}

/// Reversible fixture bytes, never a real Keychain operation or a production credential.
private final class KeeperCipher: BackendAccountVaultCipher, @unchecked Sendable {
    func available() -> Bool { true }
    func prepareForWrites(existingVault: Bool) throws {}
    func encrypt(_ text: String, existingVault: Bool) throws -> Data { Data("keeper-fixture:".utf8) + Data(text.utf8.reversed()) }
    func decrypt(_ data: Data) throws -> String {
        let prefix = Data("keeper-fixture:".utf8)
        guard data.starts(with: prefix) else { throw BackendAccountFailure("Not fixture ciphertext") }
        return String(decoding: data.dropFirst(prefix.count).reversed(), as: UTF8.self)
    }
}

private struct KeeperProviders: BackendProviderLaunchResolver {
    let readiness: BackendLaunchReadiness = .ready
    func loginPath() async throws -> String { "/usr/bin:/bin" }
    func resolve(_ input: BackendCreateSessionInput, loginPath: String) async throws -> BackendProviderSpec {
        .init(id: "shell", command: "/bin/sh", args: ["-c", "cat >/dev/null"], resumeArgs: [])
    }
}
private struct KeeperConfinement: BackendConfinementLaunchResolver {
    let readiness: BackendLaunchReadiness = .ready
    func resolve(command: String, args: [String], input: BackendCreateSessionInput, account: BackendAccountLaunch,
                 context: BackendLaunchContext) async throws -> BackendConfinedLaunch { .init(command: command, args: args) }
}
private struct KeeperInstructions: BackendInstructionLaunchResolver {
    let readiness: BackendLaunchReadiness = .ready
    func arguments(_ input: BackendCreateSessionInput, provider: BackendProviderSpec, context: BackendLaunchContext) async throws -> [String] { [] }
}
private struct KeeperProjectTools: BackendProjectMCPSource {
    let readiness: BackendLaunchReadiness = .ready
    func resolve(cwd: String, provider: String, loginPath: String) async throws -> BackendProjectMCPDefinition? { nil }
}
private struct KeeperHookChannels: BackendHOSTAccountChannelInvoking {
    func invoke(_ channel: String, args: [NativeRPCValue], context: NativeRPCContext) async throws -> NativeRPCValue { throw BackendHOSTFailure.unavailable }
}

/// No session tools are needed by the keeper checks; no listener is opened.
private struct KeeperEndpoint: BackendMCPToolEndpoint {
    let readiness: BackendLaunchReadiness = .ready
    func description() async throws -> BackendMCPEndpointDescription? { nil }
    func catalogue() async throws -> [BackendMCPTool] { [] }
    func register(token: String, grant: BackendMCPCallerGrant) async throws -> BackendMCPRegistration {
        throw BackendAccountFailure("No session tools in this fixture")
    }
    func bind(_ registration: BackendMCPRegistration, sessionID: String, machineID: String) async throws {}
    func revoke(_ registration: BackendMCPRegistration) async {}
}

/// A private host account owner and PTYs under a short scratch path. No installed service is contacted.
final class SessionKeeperTestFixture: @unchecked Sendable {
    let root: URL
    let service: BackendHOSTAccountService
    let manager: BackendPTYManager
    let ledger: BackendNativeLedger
    let lifecycle: BackendSessionLifecycleCoordinator
    private var hooks: BackendHOSTHookService?

    private init(root: URL, service: BackendHOSTAccountService, manager: BackendPTYManager,
                 ledger: BackendNativeLedger, lifecycle: BackendSessionLifecycleCoordinator) {
        self.root = root; self.service = service; self.manager = manager; self.ledger = ledger; self.lifecycle = lifecycle
    }
    static func make() async throws -> SessionKeeperTestFixture {
        let root = URL(fileURLWithPath: "/private/tmp/p59-" + String(UUID().uuidString.prefix(12)))
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: root) } }
        let data = root.appendingPathComponent("data"), home = root.appendingPathComponent("home")
        for path in [data, home] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        let configuration = try BackendAccountConfiguration(dataDirectory: data, homeDirectory: home, appName: "Keeper Boundary Fixture", appID: "terminaldeck",
            helperExecutable: root.appendingPathComponent("never-run-helper"), inheritedEnvironment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        let service = try await BackendHOSTAccountService.start(configuration: configuration, nativeAccountOwnerDisabled: true,
            vaultCipher: KeeperCipher(), apiCredentialAvailable: { _ in false }, brokerFactory: { configuration, profiles, vault in
                try await BackendAccountBroker.offline(configuration: configuration, profiles: profiles, vault: vault,
                    runner: { _, _ in .init(code: 46, stdout: "", stderr: "") })
            })
        do {
            let manager = BackendPTYManager(inheritedEnvironment: ["HOME": home.path, "PATH": "/usr/bin:/bin"], onEvent: { _ in })
            let ledger = try await BackendNativeLedger.activate(store: service.authority)
            let launcher = BackendSessionLauncher(manager: manager, dependencies: try .init(providers: KeeperProviders(), accounts: service.accounts,
                confinement: KeeperConfinement(), instructions: KeeperInstructions(), ledger: ledger))
            let endpoint = KeeperEndpoint()
            let launch = try BackendCoordinatedSessionLaunch(launcher: launcher, providers: KeeperProviders(),
                sessionTools: .init(endpoint: endpoint, userData: data), projectTools: .init(source: KeeperProjectTools(), userData: data, inheritedEnvironment: [:]),
                reach: BackendBrowserToolReachAdapter(readiness: .ready, reachesDeviceWindows: { _ in false }, hostHoldsWindows: { false }))
            let lifecycle = try BackendSessionLifecycleCoordinator(manager: manager, launch: launch, accounts: service.accounts,
                attribution: BackendAccountAttribution(configuration: configuration, profiles: await service.accounts.profiles), ledger: ledger,
                store: service.authority, cleanup: .init(readiness: .ready, release: { _ in }), emit: { _ in })
            retained = true
            return .init(root: root, service: service, manager: manager, ledger: ledger, lifecycle: lifecycle)
        } catch {
            try? await service.stop(afterProcessDrain: true); try? FileManager.default.removeItem(at: root); throw error
        }
    }
    func shell(provider: String = "shell") throws -> BackendSessionMeta {
        try manager.create(.init(cwd: root.path, provider: provider),
            spawn: .init(provider: provider, command: "/bin/sh", args: ["-c", "cat >/dev/null"], path: "/usr/bin:/bin"))
    }
    func quit(trace: KeeperTrace, detachFails: Bool = false, closeFails: Bool = false) -> BackendHOSTHostedSessionQuit {
        let manager = manager
        let controls = BackendHOSTAccountSessionControls(
            switches: BackendHOSTSuppliedSessionSwitching(subject: { _, _ in throw BackendHOSTFailure.unavailable }, perform: { _, _, _ in throw BackendHOSTFailure.unavailable },
                cancel: { _ in }, stop: { trace.add("switches") }),
            deferred: BackendHOSTSuppliedSessionDeferring(arm: { _, _ in throw BackendHOSTFailure.unavailable }, list: { [] }, cancel: { _ in }, recoveryDraft: { _ in nil },
                stop: { trace.add("deferred") }), hooks: KeeperHookChannels(),
            hookObservation: BackendHOSTSuppliedSessionHookObserving(observe: { _ in UUID() }, remove: { _ in }, stop: {}),
            hookEndpoint: .init(socketPath: root.appendingPathComponent("unused.sock").path, configPath: root.appendingPathComponent("unused.json").path,
                                sessionEnvironment: BackendSessionEnvironment.sessionVariable, appID: "terminaldeck"),
            detachForKeep: { trace.add("detach"); if detachFails { throw BackendAccountFailure("Fixture detach refused") } },
            closeAfterDrain: {
                XCTAssertFalse(manager.list().contains { $0.exitCode == nil }, "A live process must retain its account lease")
                trace.add("close")
                if closeFails { throw BackendAccountFailure("Fixture cleanup refused") }
                return ["fixture": .removed]
            })
        return .init(lifecycle: lifecycle, ledger: ledger, store: service.authority, controls: controls)
    }
    func startHooks() async throws -> BackendHOSTHookService {
        let started = try await BackendHOSTHookService.start(configuration: service.configuration, manager: manager, accounts: service,
            makeCoordinator: { BackendSessionHookCoordinator(hostedReceiver: $0) }, peerBelongs: { $0 == $1 }, additionalContext: { _ in nil })
        hooks = started; return started
    }
    func close() async {
        manager.killAll(); _ = await manager.drain()
        try? await hooks?.stop(afterProcessDrain: true)
        try? await service.stop(afterProcessDrain: true)
        try? FileManager.default.removeItem(at: root)
    }
}
#endif
