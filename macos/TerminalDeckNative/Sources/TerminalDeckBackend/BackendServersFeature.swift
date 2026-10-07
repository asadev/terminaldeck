import Foundation
import TerminalDeckNativeCore

/// Inputs belonging to existing owners stay explicit. None is reconstructed
/// from a server draft or granted because a dependency was omitted.
public struct BackendServersFeatureInputs: Sendable {
    public let dataRoot: URL, keyRoot: URL, scratchRoot: URL
    public let storagePolicy: BackendServersStoragePolicy, sshPolicy: BackendServersSSHPolicy
    public let cipher: BackendBrowserPasswordsCipher
    public let registry: NativeChannelRegistry, ownPorts: BackendDevOwnPorts
    public let authorize: BackendServersCoordinator.Authorize
    public let ipc: BackendServersIPCHooks
    public let resolveMCP: BackendServersTools.Resolve
    public let sessionLeases: BackendDeckToolsSessionsElsewhereLeases
    public let windowEndpoint: @Sendable (BackendServersWindowReachKind) async -> BackendServersWindowLocalEnd?
    public let hookToken: @Sendable () -> String?
    public let remoteContext: @Sendable (String, Bool) -> BackendServersWindowRemoteContext?
    public let openInBrowser: (@Sendable (String) async throws -> Void)?
    public let hostPackage: @Sendable () -> BackendServersHostPackage?
    public let machineLink: (@Sendable (String) async -> BackendServersHostLinkOutcome)?
    public let machineReaching: (@Sendable (String, Int) async -> Bool)?
    public let controls: (any BackendServersAgentControls)?
    public let report: @Sendable (NativeRPCError) -> Void
    public init(dataRoot: URL, keyRoot: URL, scratchRoot: URL, storagePolicy: BackendServersStoragePolicy,
                sshPolicy: BackendServersSSHPolicy, cipher: BackendBrowserPasswordsCipher,
                registry: NativeChannelRegistry, ownPorts: BackendDevOwnPorts,
                authorize: @escaping BackendServersCoordinator.Authorize, ipc: BackendServersIPCHooks,
                resolveMCP: @escaping BackendServersTools.Resolve, sessionLeases: BackendDeckToolsSessionsElsewhereLeases,
                windowEndpoint: @escaping @Sendable (BackendServersWindowReachKind) async -> BackendServersWindowLocalEnd?,
                hookToken: @escaping @Sendable () -> String?,
                remoteContext: @escaping @Sendable (String, Bool) -> BackendServersWindowRemoteContext?,
                openInBrowser: (@Sendable (String) async throws -> Void)?, hostPackage: @escaping @Sendable () -> BackendServersHostPackage?,
                machineLink: (@Sendable (String) async -> BackendServersHostLinkOutcome)?,
                machineReaching: (@Sendable (String, Int) async -> Bool)?, controls: (any BackendServersAgentControls)?,
                report: @escaping @Sendable (NativeRPCError) -> Void) {
        self.dataRoot = dataRoot; self.keyRoot = keyRoot; self.scratchRoot = scratchRoot
        self.storagePolicy = storagePolicy; self.sshPolicy = sshPolicy; self.cipher = cipher
        self.registry = registry; self.ownPorts = ownPorts; self.authorize = authorize; self.ipc = ipc; self.resolveMCP = resolveMCP
        self.sessionLeases = sessionLeases; self.windowEndpoint = windowEndpoint; self.hookToken = hookToken; self.remoteContext = remoteContext
        self.openInBrowser = openInBrowser; self.hostPackage = hostPackage; self.machineLink = machineLink; self.machineReaching = machineReaching
        self.controls = controls; self.report = report
    }
}

/// Inert assembly, followed by an explicit registry/tool installation. The
/// exclusive app owner supplies real adapters and keeps this object alive.
/// This file does not choose a live data root or start SSH during construction.
public actor BackendServersFeature {
    public nonisolated let room: BackendServersCoordinator, connections: BackendServersConnections
    public nonisolated let ipc: BackendServersIPC, shells: BackendServersShells, reach: BackendServersReach
    public nonisolated let windowDrives: BackendServersWindowDrives, windowReach: BackendServersWindowReachPool
    private let credentials: BackendServersCredentials
    private let registry: NativeChannelRegistry, reachChannels: BackendServersReachChannels
    private let resolveMCP: BackendServersTools.Resolve
    private let stateEvents: BackendServersStateEvents
    private let delivery: Task<Void, Never>
    private var tokens: [NativeRPCSubscription] = [], registrationOwner: String?
    private var toolInstallation: (server: BackendNativeMCPServer, owner: String)?
    private var stopped = false
    public init(_ input: BackendServersFeatureInputs) {
        let ssh = BackendServersSSH(scratchRoot: input.scratchRoot, policy: input.sshPolicy)
        let store = BackendServersStore(dataRoot: input.dataRoot, policy: input.storagePolicy)
        let credentials = BackendServersCredentials(dataRoot: input.dataRoot, cipher: input.cipher, policy: input.storagePolicy, keyValidator: ssh.keyValidator())
        let connections = BackendServersConnections(store: store, credentials: credentials, dialer: ssh)
        let grants = BackendServersGrants(assistantName: BackendSharedBrand.assistant, knows: { (try? store.get($0)) != nil })
        let journal = BackendServersFileJournal(storageDirectory: input.dataRoot, policy: input.storagePolicy)
        let room = BackendServersCoordinator(store: store, connections: connections, grants: grants, journal: journal,
            storageDirectory: input.dataRoot, authorize: input.authorize,
            download: { server, remote, local in try await connections.download(server, remotePath: remote, localPath: local) })
        let stateEvents = BackendServersStateEvents(), registry = input.registry, report = input.report
        let setups = BackendServersSetups(.init(runScript: { try await connections.runScript($0, script: $1) },
            openTunnel: { await BackendServersSetupTunnel.open(serverId: $0, port: $1, connections: connections) }, openInBrowser: input.openInBrowser,
            broadcast: { state in
                if state.step == .done || state.step == .idle { room.invalidateFromEvent(state.serverId) }
                stateEvents.append("servers:setup:changed", state.wireValue)
            }))
        let hosts = BackendServersHosts(.init(runScript: { try await connections.runScript($0, script: $1) },
            linkThisComputer: input.machineReaching == nil ? nil : input.machineLink, whenReaching: input.machineReaching,
            putFile: { server, local, name in
                try await connections.putFile(server, localPath: local, name: name, folder: BackendSharedBrand.name)
            }, hostPackage: input.hostPackage,
            broadcast: { state in stateEvents.append("servers:host:changed", state.wireValue) }))
        let windowReach = BackendServersWindowReachPool(connections: connections, endpoint: input.windowEndpoint)
        let windowDrives = BackendServersWindowDrives(.init(allowed: { (try? store.drivesWindows($0)) == true },
            claudeOn: { BackendServersSetupRules.agentOn(try await room.measured($0), id: .claude) },
            run: { try await connections.run($0, argv: $1) }, runScript: { try await connections.runScript($0, script: $1) },
            reach: { await windowReach.reach($0, kind: $1) }, letGo: { await windowReach.letGo($0, kind: $1) },
            mint: { try await input.sessionLeases.prepare(allowed: $0) }, hookEndpoint: input.hookToken, remoteContext: input.remoteContext))
        let shells = BackendServersShells(room: room, connections: connections, store: store,
            hooks: .init(arm: { await windowDrives.arm($0, shellId: $1).wireValue },
                disarm: { await windowDrives.disarm($0) }, cancelSetup: { await setups.cancel($0) },
                whyNot: { await windowDrives.whyNot($0) }, belonging: { await windowDrives.belonging($0)?.wireValue },
                publish: { context, channel, value in try await registry.publish(channel, arguments: [value], ownerID: context.ownerID) },
                report: report, controls: input.controls))
        let reach = BackendServersReach(connections: connections, ownPorts: input.ownPorts, servers: { try store.list() },
            facts: { try await room.measured($0) }, tunnelsDropped: { await room.invalidate($0) })
        let hooks = input.ipc
        let ipcHooks = BackendServersIPCHooks(resolve: hooks.resolve, pickKey: hooks.pickKey, uploadFile: hooks.uploadFile,
            uploadDirectory: hooks.uploadDirectory, appVersion: hooks.appVersion, linkStanding: hooks.linkStanding, redial: hooks.redial,
            revokeWindows: { await windowDrives.revoke($0); await hooks.revokeWindows($0) },
            forgetReach: { await reach.closeServer($0); await hooks.forgetReach($0) })
        self.room = room; self.connections = connections; self.shells = shells; self.reach = reach; self.windowDrives = windowDrives; self.windowReach = windowReach
        self.credentials = credentials; self.registry = registry; self.resolveMCP = input.resolveMCP; self.stateEvents = stateEvents
        self.ipc = BackendServersIPC(room: room, shells: shells, store: store, credentials: credentials,
            keys: BackendServersKeyFileOffers(keyRoot: input.keyRoot), setups: setups, hosts: hosts, hooks: ipcHooks)
        reachChannels = BackendServersReachChannels(room: room, reach: reach, resolve: input.ipc.resolve)
        delivery = Task {
            for await event in stateEvents.stream {
                guard !Task.isCancelled else { break }
                do { try await registry.publish(event.channel, arguments: [event.value]) }
                catch { report(NativeRPCError(code: "servers-state-event", message: "A server setup or host state subscriber disconnected.")) }
            }
        }
    }
    public func registerChannels(ownerID: String) async throws {
        guard !stopped, registrationOwner == nil else { throw NativeRPCError(code: "already-installed", message: "This server facade is stopped or already installed.") }
        registrationOwner = ownerID
        do {
            tokens = try await ipc.register(on: registry, ownerID: ownerID)
            guard !stopped else { throw CancellationError() }
            try await reachChannels.register(on: registry, ownerID: ownerID)
            guard !stopped else { throw CancellationError() }
        } catch { await removeChannels(installationOwner: ownerID); throw error }
    }
    public func registerTools(on server: BackendNativeMCPServer, ownerID: String = "native-servers-tools") async throws {
        guard !stopped, toolInstallation == nil else { throw CancellationError() }
        toolInstallation = (server, ownerID)
        do {
            try await BackendServersTools.register(on: server, ownerID: ownerID, room: room, resolve: resolveMCP)
            guard !stopped else { await server.removeTools(ownerID: ownerID); throw CancellationError() }
        } catch { toolInstallation = nil; throw error }
    }
    public func disconnectOwner(_ owner: String) async { await shells.disconnectOwner(owner); await room.disconnectOwner(owner) }
    public func stop() async {
        guard !stopped else { return }; stopped = true
        if let tools = toolInstallation { toolInstallation = nil; await tools.server.removeTools(ownerID: tools.owner) }
        await ipc.beginStopping(); await room.beginStopping(); await removeChannels()
        await shells.beginStopping(); await ipc.stopFlows(); await windowDrives.stop(); await shells.stop()
        await windowReach.stop(); await reach.stop(); await ipc.stop()
        credentials.close(); stateEvents.finish(); delivery.cancel()
    }
    private func removeChannels(installationOwner: String? = nil) async {
        guard let owner = installationOwner ?? registrationOwner else { return }
        if registrationOwner == owner { registrationOwner = nil }
        for token in tokens { await token.cancelAndWait() }; tokens = []
        for channel in BackendServersIPC.channels.union(Set(BackendServersReachChannels.channels)) { await registry.removeHandler(channel, ownerID: owner) }
    }
}

/// One ordered state delivery task, rather than racing per-change tasks.
final class BackendServersStateEvents: @unchecked Sendable {
    struct Event: Sendable { let channel: String, value: NativeRPCValue }
    let stream: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    init() { let pair = AsyncStream<Event>.makeStream(); stream = pair.stream; continuation = pair.continuation }
    func append(_ channel: String, _ value: NativeRPCValue) { continuation.yield(.init(channel: channel, value: value)) }
    func finish() { continuation.finish() }
}
