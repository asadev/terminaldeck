import Foundation
import TerminalDeckNativeCore

/// Retained services only. This installer never opens a store, starts a remote
/// listener, creates a session, or constructs another registry/MCP owner.
public enum BackendMachineRegistration {
    public static let name = "machines"
    public static let nodeDomains: Set<String> = ["machines"]
    public static let invokeChannels = BackendMachineChannels.invokeChannels.union(["remote:tunnel:stop"])
    public static let sendChannels: Set<String> = []
    public static let requiredTransferredDomains: Set<String> = ["machines", "remote-serve"]
    public static let eventChannels: Set<String> = ["machines:state", "machines:output", "machines:upload:progress", "machines:copilot:state", "machines:copilot:chat", "machines:github:changed"]
    public static let toolIDs: Set<String> = ["machines.look", "machines.session", "machines.copilot", "machines.ports", "machines.upload", "machines.manage"]
    public static let hostTags: Set<String> = ["panel.read", "panel.act", "upload.begin", "upload.data", "upload.end", "upload.cancel", "ports", "tunnel.open", "tunnel.close", "net.open", "net.data", "net.ack", "net.close"]

    /// The same authoritative host used by remote-serve supplies an additive,
    /// atomic lease. It must neither overwrite other hooks nor start a listener.
    public struct Host: Sendable {
        public typealias Install = @Sendable (String, [BackendRemoteHostFeature], @escaping @Sendable (UUID) async -> Void) async throws -> NativeRPCSubscription
        public let endpoint: BackendRemoteHost
        public let install: Install
        public let currentContext: @Sendable (BackendRemoteHostContext) async throws -> BackendRemoteHostContext
        public let authorize: @Sendable (BackendRemoteClientMessage, BackendRemoteHostContext) async throws -> NativeRPCContext
        public let connectionRows: @Sendable () async throws -> NativeRPCValue
        public init(endpoint: BackendRemoteHost, install: @escaping Install,
                    currentContext: @escaping @Sendable (BackendRemoteHostContext) async throws -> BackendRemoteHostContext,
                    authorize: @escaping @Sendable (BackendRemoteClientMessage, BackendRemoteHostContext) async throws -> NativeRPCContext,
                    connectionRows: @escaping @Sendable () async throws -> NativeRPCValue) {
            self.endpoint = endpoint; self.install = install; self.currentContext = currentContext; self.authorize = authorize; self.connectionRows = connectionRows
        }
    }

    /// Use shared mode when deck-tools already installed the six source IDs.
    /// Its real handler, policy and descriptor contribution remains untouched.
    public struct MCP: Sendable {
        public enum Mode: Sendable { case owned; case shared(ownerID: String) }
        public let mode: Mode
        public let definitions: [BackendDeckToolsDefinition]
        public let policies: [BackendDeckCoreSecurityToolPolicy]
        public let authenticate: @Sendable (BackendMCPCallContext, BackendMCPTool, NativeRPCValue) async throws -> NativeRPCContext
        public let requireSharedOwner: (@Sendable (String, Set<String>) async throws -> Void)?
        public let disconnect: @Sendable (NativeRPCContext) async -> Void
        public init(mode: Mode, definitions: [BackendDeckToolsDefinition], policies: [BackendDeckCoreSecurityToolPolicy],
                    authenticate: @escaping @Sendable (BackendMCPCallContext, BackendMCPTool, NativeRPCValue) async throws -> NativeRPCContext,
                    requireSharedOwner: (@Sendable (String, Set<String>) async throws -> Void)? = nil,
                    disconnect: @escaping @Sendable (NativeRPCContext) async -> Void) {
            self.mode = mode; self.definitions = definitions; self.policies = policies; self.authenticate = authenticate
            self.requireSharedOwner = requireSharedOwner; self.disconnect = disconnect
        }
    }

    public struct Dependencies: Sendable {
        public let coordinator: BackendMachineCoordinator
        public let localHost: BackendRemoteHostService
        public let browser: BackendMachineWindowServices
        public let panels: BackendRemotePanelRegistry
        public let uploads: BackendUploadReceive
        public let tunnels: BackendRemoteGuestTunnelHost
        public let host: Host
        public let mcp: MCP
        public let transferredDomains: Set<String>
        /// Memory/authority checks against the retained graph, not new probes.
        public let requireSuppliers: @Sendable () async throws -> Void
        public let authorizeInvoke: @Sendable (String, NativeRPCContext, [NativeRPCValue]) async throws -> Void
        /// Root explicitly starts its existing store/link/watch consumers later.
        /// Return all consumer leases so cancellation/quit can await teardown.
        public let activate: @Sendable (String) async throws -> [NativeRPCSubscription]
        public let deactivate: @Sendable () async -> Void
        public init(coordinator: BackendMachineCoordinator, localHost: BackendRemoteHostService, browser: BackendMachineWindowServices,
                    panels: BackendRemotePanelRegistry, uploads: BackendUploadReceive, tunnels: BackendRemoteGuestTunnelHost,
                    host: Host, mcp: MCP, transferredDomains: Set<String>,
                    requireSuppliers: @escaping @Sendable () async throws -> Void,
                    authorizeInvoke: @escaping @Sendable (String, NativeRPCContext, [NativeRPCValue]) async throws -> Void,
                    activate: @escaping @Sendable (String) async throws -> [NativeRPCSubscription],
                    deactivate: @escaping @Sendable () async -> Void) {
            self.coordinator = coordinator; self.localHost = localHost; self.browser = browser; self.panels = panels; self.uploads = uploads
            self.tunnels = tunnels; self.host = host; self.mcp = mcp; self.transferredDomains = transferredDomains
            self.requireSuppliers = requireSuppliers; self.authorizeInvoke = authorizeInvoke; self.activate = activate; self.deactivate = deactivate
        }
    }

    public struct Installed: Sendable {
        public let area: BackendCompositionRoot.Area
        public let invokeChannels: Set<String>
        public let sendChannels: Set<String>
        public let eventChannels: Set<String>
        public let sendSubscriptions: [NativeRPCSubscription]
        public let toolIDs: Set<String>
        public let definitions: [BackendDeckToolsDefinition]
        public let policies: [BackendDeckCoreSecurityToolPolicy]
        public var metadata: [BackendDeckCoreCatalogueMetadata] { definitions.map(\.catalogueMetadata) }
        private let runtime: Runtime
        fileprivate init(area: BackendCompositionRoot.Area, definitions: [BackendDeckToolsDefinition], policies: [BackendDeckCoreSecurityToolPolicy], runtime: Runtime) {
            self.area = area; invokeChannels = area.invokes; sendChannels = []; eventChannels = area.events; sendSubscriptions = []
            toolIDs = BackendMachineRegistration.toolIDs; self.definitions = definitions; self.policies = policies; self.runtime = runtime
        }
        public func start() async throws { try await runtime.start() }
        public func stop() async { await runtime.stop() }
        public func disconnect(connectionID: UUID) async { await runtime.connectionClosed(connectionID) }
        public func disconnect(machineID: String) async { await runtime.machineDisconnected(machineID) }
        public func disconnect(caller: NativeRPCContext) async { await runtime.callerDisconnected(caller) }
    }

    /// The panels Machines cannot transfer without (the original four); others are optional.
    public static let requiredPanelDomains: Set<String> = Set(([.artifacts, .store, .readiness, .mcp] as [BackendRemotePanelRegistry.Domain]).map(\.rawValue))
    public static func hasRequiredPanels(_ supplied: [String]) -> Bool { requiredPanelDomains.isSubset(of: Set(supplied)) }
    /// nil means no area was installed or advertised; the Node route stays.
    /// Other missing/conflicting suppliers throw unavailable before retention.
    public static func register(in composition: BackendCompositionRoot, dependencies: Dependencies?) async throws -> Installed? {
        guard let d = dependencies else { return nil }
        try await composition.requireAssemblyOpen()
        let registry = composition.registry, server = composition.mcp
        let existingDomains = Set(await composition.domains())
        guard !existingDomains.contains(name), existingDomains.contains("remote-serve"), requiredTransferredDomains.isSubset(of: d.transferredDomains) else {
            throw unavailable("Machines require the exclusive machines/remote-serve cutover and the retained native remote host.")
        }
        for channel in invokeChannels where await registry.has(channel) { throw unavailable("The machine registration cannot replace another owner's \(channel) handler.") }
        guard await d.coordinator.uses(registry: registry, ownPorts: composition.ownPorts), await d.localHost.endpoint === d.host.endpoint else {
            throw unavailable("Machines must share the composition registry, own-port owner and remote endpoint.")
        }
        guard d.browser.held != nil, d.browser.ownSessions != nil, d.browser.receivedHolds != nil, d.browser.receivedResult != nil, !d.browser.allowedTools.isEmpty else {
            throw unavailable("The authenticated bidirectional native browser binding/dispatcher is incomplete.")
        }
        // O2 (8 Oct, release blocker): the four original panels must be supplied; the phone panels
        // widened Domain to cases that are deliberately never supplied (memory, plugins, github,
        // ai-apps), so equality with allCases made every launch fail.
        guard Self.hasRequiredPanels(await d.panels.suppliedDomains()) else {
            throw unavailable("The four required native panel providers (artifacts, store, readiness, mcp) must be registered before transferring this area.")
        }
        try await d.requireSuppliers()
        try Task.checkCancellation()
        try validateMCP(d.mcp)
        if case .owned = d.mcp.mode {
            let registered = await server.registrations()
            guard Set(registered.map { $0.0.id }).isDisjoint(with: toolIDs) else { throw unavailable("Machine MCP tools already have an owner; supply the shared contribution proof instead.") }
        }
        if case .shared(let sharedOwner) = d.mcp.mode {
            guard !sharedOwner.isEmpty, let require = d.mcp.requireSharedOwner else { throw unavailable("The shared machine MCP owner proof is missing.") }
            try await require(sharedOwner, toolIDs)
            let entries = await server.registrations()
            for definition in d.mcp.definitions {
                guard let actual = entries.first(where: { $0.0.id == definition.spec.id })?.0, same(actual, definition.spec) else {
                    throw unavailable("The actual shared \(definition.spec.id) handler/descriptor is not installed.")
                }
            }
        }
        let owner = "native-composition:machines:" + UUID().uuidString.lowercased()
        let runtime = Runtime(dependencies: d, registry: registry, server: server, ownerID: owner)
        do {
            try await d.coordinator.installWindowServices(d.browser)
            let channels = try await BackendMachineChannels.register(registry: registry, coordinator: d.coordinator, localHost: d.localHost, ownerID: owner,
                authorize: { _, context in
                    guard context.caller == .nativeApp || context.caller == .page else { throw NativeRPCError(code: "access-denied", message: "Machine channels require the actual app or authenticated local caller.") }
                }, authorizeCall: { channel, context, arguments in
                    guard let current = NativeCompositionCallContext.rpc, current.requestID == context.requestID, current.ownerID == context.ownerID, current.caller == context.caller else {
                        throw unavailable("The machine operation has no matching authenticated dispatcher context.")
                    }
                    try await d.authorizeInvoke(channel, context, arguments)
                    try await runtime.requireStarted()
                }, requireReady: { try await runtime.requireStarted() })
            try await registry.register("remote:tunnel:stop", ownerID: owner) { context, args in
                try await runtime.requireStarted(); try await d.authorizeInvoke("remote:tunnel:stop", context, args)
                if let connection = args.first?.string.flatMap(UUID.init(uuidString:)), let tunnel = args.dropFirst().first?.string {
                    _ = try await d.tunnels.stop(connectionID: connection, tunnelID: tunnel)
                }
                return try await d.host.connectionRows()
            }
            let features = [
                BackendRemoteHostFeature(capability: "panels", messageTypes: ["panel.read", "panel.act"], policy: .grantedDevice) { message, context in
                    try await runtime.hostCall(message, context: context) { fresh, rpc in [try await d.panels.handle(message, context: fresh, rpcContext: rpc)] }
                },
                try await runtime.guarded(await d.uploads.feature()),
                try await runtime.guarded(d.tunnels.feature()),
            ]
            guard Set(features.flatMap(\.messageTypes)) == hostTags else { throw unavailable("The native machine host packet groups are incomplete.") }
            let hostLease = try await d.host.install(owner, features) { await runtime.connectionClosed($0) }
            await runtime.retain(hostLease)
            let definitions = d.mcp.definitions.map { definition in wrap(definition, runtime: runtime, authenticate: d.mcp.authenticate) }
            if case .owned = d.mcp.mode {
                try await server.replaceTools(ownerID: owner, tools: definitions.map { ($0.spec, $0.handler) })
                await runtime.markToolsOwned()
            }
            let area = BackendCompositionRoot.Area(name: name, domains: nodeDomains, ownerID: owner,
                invokes: Set(channels.channels).union(["remote:tunnel:stop"]), sends: [], events: eventChannels, stop: { await runtime.stop() })
            guard area.invokes == invokeChannels else { throw unavailable("The complete machine route contribution was not installed.") }
            try Task.checkCancellation()
            try await composition.retain(area)
            return Installed(area: area, definitions: definitions, policies: d.mcp.policies, runtime: runtime)
        } catch { await runtime.rollback(); throw error }
    }

    private static func validateMCP(_ binding: MCP) throws {
        guard Set(binding.definitions.map { $0.spec.id }) == toolIDs, binding.definitions.count == toolIDs.count,
              Set(binding.policies.map { $0.tool.id }) == toolIDs, binding.policies.count == toolIDs.count else {
            throw unavailable("The six real machine MCP definitions and their source policies are required exactly once.")
        }
        for definition in binding.definitions {
            guard definition.spec.implementation == .native, let policy = binding.policies.first(where: { $0.tool.id == definition.spec.id }), same(policy.tool, definition.spec),
                  Set(policy.aliases) == Set(definition.aliases), policy.audience == definition.audience else {
                throw unavailable("The machine MCP descriptor/policy does not match its genuine native handler.")
            }
        }
    }
    private static func same(_ a: BackendMCPTool, _ b: BackendMCPTool) -> Bool { a.id == b.id && a.wireName == b.wireName && a.description == b.description && a.inputSchema == b.inputSchema && a.tier == b.tier && a.advertised == b.advertised && a.implementation == b.implementation }
    private static func wrap(_ definition: BackendDeckToolsDefinition, runtime: Runtime,
                             authenticate: @escaping @Sendable (BackendMCPCallContext, BackendMCPTool, NativeRPCValue) async throws -> NativeRPCContext) -> BackendDeckToolsDefinition {
        .init(spec: definition.spec, title: definition.title, index: definition.index, aliases: definition.aliases, audience: definition.audience, keyIndex: definition.keyIndex, keyGrant: definition.keyGrant) { caller, args in
            try await runtime.requireStarted()
            let rpc = try await authenticate(caller, definition.spec, args)
            guard rpc.caller == .page else { throw NativeRPCError(code: "access-denied", message: "Machine MCP requires its authenticated caller identity, never an app-window substitute.") }
            return try await NativeCompositionCallContext.$rpc.withValue(rpc) { try await definition.handler(caller, args) }
        }
    }
    private static func unavailable(_ message: String) -> NativeRPCError { .init(code: "unavailable", message: message) }

    fileprivate actor Runtime {
        let d: Dependencies, registry: NativeChannelRegistry, server: BackendNativeMCPServer, ownerID: String
        var active = false, starting = false, stopped = false, toolsOwned = false, ownsServices = false
        var leases: [NativeRPCSubscription] = []
        var activation: Task<[NativeRPCSubscription], Error>?
        init(dependencies: Dependencies, registry: NativeChannelRegistry, server: BackendNativeMCPServer, ownerID: String) { d = dependencies; self.registry = registry; self.server = server; self.ownerID = ownerID }
        func requireStarted() throws { guard active, !stopped else { throw BackendMachineRegistration.unavailable("The native machines area has not been started.") } }
        func retain(_ lease: NativeRPCSubscription) { leases.append(lease) }
        func markToolsOwned() { toolsOwned = true }
        func guarded(_ feature: BackendRemoteHostFeature) throws -> BackendRemoteHostFeature {
            .init(capability: feature.capability, messageTypes: feature.messageTypes, policy: feature.policy, sessionField: feature.sessionField) { [self] message, context in
                try await hostCall(message, context: context) { fresh, _ in try await feature.handle(message, fresh) }
            }
        }
        func hostCall(_ message: BackendRemoteClientMessage, context: BackendRemoteHostContext,
                      operation: @escaping @Sendable (BackendRemoteHostContext, NativeRPCContext) async throws -> [BackendRemoteServerMessage]) async throws -> [BackendRemoteServerMessage] {
            try requireStarted()
            let current = try await d.host.currentContext(context)
            guard current.connectionID == context.connectionID, current.deviceID == context.deviceID, current.peerPublicKey == context.peerPublicKey else { throw BackendMachineRegistration.unavailable("The authenticated remote connection changed.") }
            let rpc = try await d.host.authorize(message, current)
            guard rpc.caller == .pairedDevice, rpc.ownerID == current.deviceID else { throw NativeRPCError(code: "access-denied", message: "The remote packet has no matching authenticated device context.") }
            try requireStarted()
            return try await NativeCompositionCallContext.$rpc.withValue(rpc) { try await operation(current, rpc) }
        }
        func start() async throws {
            guard !stopped else { throw BackendMachineRegistration.unavailable("The machine registration stopped.") }; if active { return }
            guard !starting else { throw BackendMachineRegistration.unavailable("The machine registration is already starting.") }; starting = true; defer { starting = false }
            try await d.requireSuppliers()
            guard !stopped else { throw CancellationError() }
            try Task.checkCancellation()
            ownsServices = true
            let task = Task { try await d.activate(ownerID) }; activation = task
            do {
                let consumers = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                // Cleanup owns any late activation result and awaits its leases.
                // Two cancelAndWait calls would not join the same action twice.
                guard !stopped else { throw CancellationError() }
                leases += consumers; activation = nil
                try Task.checkCancellation()
                active = true
            } catch { activation = nil; await stop(); throw error }
        }
        func connectionClosed(_ id: UUID) async { await d.uploads.close(connectionID: id); await d.tunnels.close(connectionID: id) }
        func machineDisconnected(_ id: String) async { await d.coordinator.disconnect(id) }
        func callerDisconnected(_ caller: NativeRPCContext) async { await d.mcp.disconnect(caller) }
        func rollback() async { await cleanup(stopServices: ownsServices) }
        func stop() async { await cleanup(stopServices: ownsServices) }
        private func cleanup(stopServices: Bool) async {
            guard !stopped else { return }; stopped = true; active = false
            let pendingActivation = activation; activation = nil
            pendingActivation?.cancel()
            if let pendingActivation, let consumers = try? await pendingActivation.value {
                for lease in consumers { await lease.cancelAndWait() }
            }
            let old = leases; leases = []; for lease in old { await lease.cancelAndWait() }
            if toolsOwned { await server.removeTools(ownerID: ownerID); toolsOwned = false }
            if stopServices { await d.coordinator.stop(); await d.uploads.stop(); await d.tunnels.stop(); await d.deactivate() }
            await registry.removeOwner(ownerID)
        }
    }
}
