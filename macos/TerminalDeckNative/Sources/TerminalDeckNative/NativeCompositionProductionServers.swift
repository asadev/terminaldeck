import AppKit
import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    func installServers() async throws {
        let caller = NativeCompositionServerCaller(authority: authority, joins: joins)
        let cipher = BackendAccountKeychainCipher(appName: configuration.appName)
        let leases = deckToolLeases().elsewhere
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let inputs = BackendServersFeatureInputs(dataRoot: root.dataRoot.appendingPathComponent("servers", isDirectory: true),
            keyRoot: root.dataRoot.appendingPathComponent("servers/keys", isDirectory: true), scratchRoot: root.dataRoot.appendingPathComponent("servers/tmp", isDirectory: true),
            storagePolicy: .init(mayRead: true, mayWrite: root.state.ownership == .exclusive),
            sshPolicy: .init(mayConnect: root.state.ownership == .exclusive, helperExecutable: configuration.helperExecutable,
                helperDispatchInstalled: FileManager.default.isExecutableFile(atPath: configuration.helperExecutable.path)),
            cipher: .keychain(cipher, available: { cipher.available() }),
            registry: root.registry, ownPorts: root.ownPorts, authorize: { try await caller.authorize($0, $1) },
            ipc: .init(resolve: { try await caller.resolve($0) }, pickKey: { _ in try await NativeCompositionFolderPicker.file() },
                uploadFile: { [files] who, _, file in _ = try await files!.authority.authorize(file.path, context: who.context) },
                uploadDirectory: { _, _ in BackendSharedBrand.name },
                appVersion: { version }, linkStanding: { [machineCoordinator] id in
                    guard let coordinator = machineCoordinator, let link = try? await coordinator.link(id) else { return nil }
                    let state = await link.state(); return (id, state.phase == .online)
                }, redial: { [machineCoordinator] id in try? await machineCoordinator?.connect(id) },
                revokeWindows: { [machineCoordinator] id in _ = try? await machineCoordinator?.setDrivesWindows(id, allowed: false) },
                forgetReach: { [machineCoordinator] id in await machineCoordinator?.disconnect(id) }),
            resolveMCP: { try await caller.resolve($0) }, sessionLeases: leases,
            windowEndpoint: { [core, sessions] kind in
                switch kind { case .control: return .port(core!.endpoint.port); case .hooks: return .socketPath(sessions!.hookServer.endpoint.socketPath) }
            }, hookToken: { nil }, remoteContext: { _, _ in nil },
            openInBrowser: { url in
                let graph = try await NativeCompositionRoot.shared.browserForComposition()
                _ = try await graph.service.nativeCreate(graph.dependencies.uiContext, arguments: .object([.init("url", .string(url))]))
            }, hostPackage: { BackendServersHostPackages.find(version: version, resources: Bundle.main.resourceURL?.path, tree: nil) },
            machineLink: { [machineCoordinator, machineStore] code in
                guard let coordinator = machineCoordinator, let store = machineStore else { return .refused("The native machine pairing owner is not installed.") }
                do { return try await BackendCompositionMachinePairing.receipt(coordinator: coordinator, store: store, code: code) }
                catch { return .refused(error.localizedDescription) }
            }, machineReaching: { [machineCoordinator] id, port in
                guard let coordinator = machineCoordinator, let link = try? await coordinator.link(id) else { return false }
                let state = await link.state(); return state.phase == .online && state.ports.contains { $0["port"].number == Double(port) }
            }, controls: nil, report: { [report] in report($0.message) })
        serversOwner = try await root.installServers(inputs: inputs, oldServerOwnerDisabled: true)
    }
}

final class NativeCompositionServerCaller: @unchecked Sendable {
    private let authority: BackendCompositionAuthority
    private let joins: BackendCompositionProductionBindings
    private let lock = NSLock()
    private var native: [UUID: BackendMCPCallContext] = [:]
    init(authority: BackendCompositionAuthority, joins: BackendCompositionProductionBindings) { self.authority = authority; self.joins = joins }
    func resolve(_ context: NativeRPCContext) async throws -> BackendServersCaller {
        if context.caller == .nativeApp {
            try authority.requireLocalUI(context); return .init(kind: .nativeUI, attended: true, context: context)
        }
        let original = try await authority.nativeCaller(context)
        return try await resolve(original)
    }
    func resolve(_ context: BackendMCPCallContext) async throws -> BackendServersCaller {
        let core = try await authority.resolve(context), rpc = try await authority.rpc(context)
        lock.withLock { native = native.filter { !$0.value.cancellation.isCancelled }; native[rpc.requestID] = context }
        guard let kind = BackendServersCaller.Kind(rawValue: core.caller.kind.rawValue) else { throw NativeRPCError(code: "access-denied", message: "The server caller's provenance is not supported.") }
        return .init(kind: kind, attended: core.attended, context: rpc)
    }
    func authorize(_ who: BackendServersCaller, _ operation: BackendServersAuthorization) async throws {
        if who.kind == .nativeUI { try authority.requireLocalUI(who.context); return }
        guard let native = lock.withLock({ native[who.context.requestID] }) else { throw NativeRPCError(code: "access-denied", message: "This server operation has no current core caller.") }
        _ = try await authority.resolve(native)
        if operation.tier == .read { try authority.authorizeMetadata(who.context); return }
        try await joins.prepareNative(native, tier: operation.tier, sentence: "Use server " + operation.operation)
    }
}
