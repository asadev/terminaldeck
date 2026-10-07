import Foundation
import TerminalDeckNativeCore

/// One retained owner graph. Construction is inert: the app starts this only
/// after taking the Store lease and before launching the transitional engine.
public actor BackendCompositionRoot {
    public static let appOwnerID = "native-app"
    public nonisolated let dataRoot: URL
    public nonisolated let state: NativeStateStore
    public nonisolated let settings: BackendAppSettingsStore
    public nonisolated let registry: NativeChannelRegistry
    public nonisolated let mcp: BackendNativeMCPServer
    public nonisolated let providers: BackendNativeProviders
    public nonisolated let tailnet: BackendRemoteServeTailnet
    public nonisolated let ownPorts = BackendDevOwnPorts()
    public nonisolated let preparedSessions: BackendCompositionSessions.Prepared
    public nonisolated let events: BackendCompositionEvents
    private nonisolated let coreControl = BackendCompositionCoreControl()
    private var areas: [String: Area] = [:]
    private let environment: [String: String]
    private let home: String
    private var clients: BackendCompositionClients?
    private var files: BackendCompositionFiles?
    private var usage: BackendCompositionUsage?
    private var routines: BackendRoutinesRegistrationHandle?
    private var remoteServe: BackendRemoteServeRegistration.Installed?
    private var sessions: BackendCompositionSessions?
    private var core: BackendDeckCoreRuntime?
    private var coreClientsAuthority: BackendCompositionClientsSecurityAuthority?
    private var coreHasClientsExchange = false
    private var stateProjection: BackendCompositionState?
    private var callMetrics: BackendMacAppSetupIPCMetrics?
    private var machines: BackendMachineRegistration.Installed?
    private var servers: BackendServersFeature?
    private var tasks: BackendTaskRegistration?
    private var stopped = false
    private var sealed = false

    public struct Area: Sendable {
        public let name: String
        public let domains: Set<String>
        public let ownerID: String
        public let invokes: Set<String>
        public let sends: Set<String>
        public let events: Set<String>
        public let stop: @Sendable () async throws -> Void
        public init(name: String, domains: Set<String>, ownerID: String,
                    invokes: Set<String>, sends: Set<String> = [], events: Set<String> = [],
                    stop: @escaping @Sendable () async throws -> Void) {
            self.name = name; self.domains = domains; self.ownerID = ownerID
            self.invokes = invokes; self.sends = sends; self.events = events; self.stop = stop
        }
    }

    public init(dataRoot: URL, state: NativeStateStore, environment: [String: String], home: String) throws {
        self.dataRoot = dataRoot.standardizedFileURL; self.state = state
        settings = BackendAppSettingsStore(userData: dataRoot, writable: state.ownership == .exclusive || state.ownership == .memory)
        self.environment = environment; self.home = home
        preparedSessions = BackendCompositionSessions.Prepared(environment: environment)
        registry = NativeChannelRegistry(report: { failure in NSLog("[native backend] %@: %@", failure.code, failure.message) })
        events = BackendCompositionEvents(registry: registry)
        mcp = BackendNativeMCPServer()
        let providers = try BackendNativeProviders(store: state, dataRoot: dataRoot,
            inheritedEnvironment: environment, home: home, runner: BackendCommandRunner())
        self.providers = providers
        tailnet = BackendRemoteServeTailnet(environment: environment, loginPath: {
            // A failed login-PATH lookup retains the actual inherited PATH.
            (try? await providers.loginPath()) ?? environment["PATH"] ?? ""
        })
    }

    public static func requireLocalUI(_ context: NativeRPCContext) throws {
        guard context.caller == .nativeApp, context.ownerID == appOwnerID else {
            throw NativeRPCError(code: "access-denied", message: "This operation belongs to the native app window.")
        }
    }

    /// Commit only a complete area's actual registered routes. A missing
    /// dependency leaves the area absent and its channels on the Node path.
    public func retain(_ area: Area) async throws {
        guard !stopped, !sealed, areas[area.name] == nil,
              areas.values.allSatisfy({ $0.domains.isDisjoint(with: area.domains) }) else {
            throw NativeRPCError(code: "composition-conflict", message: "The native area already has an owner.")
        }
        let registeredInvokes = Set(await registry.channels())
        let registeredSends = Set(await registry.sends())
        guard area.invokes.isSubset(of: registeredInvokes), area.sends.isSubset(of: registeredSends) else {
            let missing = area.invokes.subtracting(registeredInvokes).union(area.sends.subtracting(registeredSends)).sorted()
            throw NativeRPCError(code: "composition-incomplete", message: "The native area \(area.name) has unregistered routes: " + missing.joined(separator: ", "))
        }
        for channel in area.invokes where await registry.registrationOwner(of: channel) != area.ownerID {
            throw NativeRPCError(code: "composition-owner", message: "The native area cannot claim another owner's '\(channel)' handler.")
        }
        for channel in area.sends where await registry.sendOwners(of: channel) != [area.ownerID] {
            throw NativeRPCError(code: "composition-owner", message: "The native area cannot claim another owner's '\(channel)' send listener.")
        }
        areas[area.name] = area
    }

    public func installFoundations() async throws {
        guard areas["tailnet"] == nil, !stopped else { return }
        let owner = "native-composition:tailnet"
        do {
            try await tailnet.registerChannels(registry, ownerID: owner,
                certificateDirectory: dataRoot.appendingPathComponent("tailnet-certs", isDirectory: true),
                authorize: Self.requireLocalUI)
            try await retain(.init(name: "tailnet", domains: ["tailnet"], ownerID: owner,
                invokes: ["tailnet:status", "tailnet:cert"], stop: {}))
        } catch { await registry.removeOwner(owner); throw error }
    }

    /// The manifest is fixed for one Node launch. Late handoffs are wired in
    /// source for the next launch; they cannot silently open a second writer.
    public func seal() { sealed = true }
    public func requireAssemblyOpen() throws {
        guard !sealed, !stopped else {
            throw NativeRPCError(code: "composition-sealed", message: "Native areas must be installed before the transitional engine launches.")
        }
    }

    @discardableResult
    public func installSettings(environment: BackendAppSettingsEnvironment,
                                oldSettingsOwnerDisabled: Bool) async throws -> BackendCompositionState {
        try requireAssemblyOpen()
        guard oldSettingsOwnerDisabled, stateProjection == nil,
              environment.userData.standardizedFileURL == dataRoot else {
            throw NativeRPCError(code: "ownership-required", message: "Settings must share the selected data folder and the one native writer.")
        }
        let owner = "native-composition:settings"
        let projection = await BackendCompositionState.make(store: state, settings: settings,
            dataRoot: dataRoot, registry: registry, copilotRoot: { [dataRoot] values in
                let selected = values[BackendCopilotFolder.homeSetting].string
                return selected.flatMap { $0.hasPrefix("/") && !$0.contains("\0") ? $0 : nil }
                    ?? BackendCopilotHome.defaultHome(dataRoot.path)
            })
        do {
            let channels = try await BackendAppSettingsChannels.register(registry: registry,
                ownerID: owner, store: settings, environment: environment)
            try await retain(.init(name: "settings", domains: ["settings"], ownerID: owner,
                invokes: Set(channels), events: ["settings:changed", "prefs:changed"], stop: { await projection.stop() }))
            stateProjection = projection; return projection
        } catch { await projection.stop(); await registry.removeOwner(owner); throw error }
    }

    @discardableResult
    public func installSessions(endpoint: any BackendMCPToolEndpoint,
                                dependencies: BackendCompositionSessions.Dependencies,
                                oldSessionOwnerDisabled: Bool) async throws -> BackendCompositionSessions {
        try requireAssemblyOpen()
        guard sessions == nil else { throw NativeRPCError(code: "composition-conflict", message: "Sessions already have a native owner.") }
        let owner = "native-composition:sessions"
        let graph = try await BackendCompositionSessions.activate(state: state, providers: providers,
            endpoint: endpoint, dependencies: dependencies, oldSessionOwnerDisabled: oldSessionOwnerDisabled,
            prepared: preparedSessions, fanout: { [events] event in events.submit(event) })
        do {
            let registered = try await graph.install(registry: registry, ownerID: owner)
            try await retain(.init(name: "sessions", domains: ["sessions-accounts"], ownerID: owner,
                invokes: Set(registered.invokeChannels), sends: Set(registered.sendChannels), events: Set(registered.events), stop: {
                    switch await graph.shutdown() {
                    case .stopped: return
                    case .blocked(let reason): throw NativeRPCError(code: "shutdown-blocked", message: reason)
                    case .background: throw NativeRPCError(code: "shutdown-blocked", message: "Native sessions still own the background process.")
                    }
                }))
            sessions = graph; return graph
        } catch { _ = await graph.shutdown(); throw error }
    }

    @discardableResult
    public func installClients(transferredDomains: Set<String>, dependencies: BackendCompositionClientsDependencies) async throws -> BackendCompositionClients {
        try requireAssemblyOpen()
        guard clients == nil, !stopped else { throw NativeRPCError(code: "composition-conflict", message: "The clients graph already has an owner.") }
        guard core == nil || coreHasClientsExchange else {
            throw NativeRPCError(code: "composition-incomplete", message: "Install the native clients' authenticated exchange hook before transferring their domains.")
        }
        let owner = "native-composition:clients"
        let graph = try await BackendCompositionClients.install(registry: registry, mcpServer: mcp,
            stateStore: state, providers: providers, dataRoot: dataRoot, home: home,
            inheritedEnvironment: environment, ownerID: owner,
            transferredDomains: transferredDomains, dependencies: dependencies)
        do {
            try await retain(.init(name: "clients", domains: graph.domains, ownerID: owner,
                invokes: Set(graph.invokeChannels), sends: Set(graph.sendChannels), events: Set(graph.eventChannels),
                stop: { await graph.shutdown() }))
            clients = graph; return graph
        } catch { await graph.shutdown(); throw error }
    }

    @discardableResult
    public func installFiles(dependencies: BackendCompositionFiles.Dependencies, excludingToolIDs: Set<String> = []) async throws -> BackendCompositionFiles {
        try requireAssemblyOpen()
        guard files == nil, !stopped else { throw NativeRPCError(code: "composition-conflict", message: "The files graph already has an owner.") }
        let owner = "native-composition:files"
        let graph = try BackendCompositionFiles(registry: registry, state: state, dataRoot: dataRoot,
            providers: providers, ownPorts: ownPorts, dependencies: dependencies)
        do {
            let registered = try await graph.install(mcp: mcp, ownerID: owner, excludingToolIDs: excludingToolIDs)
            try await retain(.init(name: "files", domains: ["files-git"], ownerID: owner,
                invokes: Set(registered.invokeChannels), sends: Set(registered.sendChannels),
                events: ["git:status-changed", "fs:changed", "dev:server:state"], stop: { await graph.shutdown() }))
            files = graph; return graph
        } catch { await graph.shutdown(); throw error }
    }

    @discardableResult
    public func installUsage(accounts: BackendAccountLaunchAdapter, lifecycle: BackendSessionLifecycleCoordinator,
                             dependencies: BackendCompositionUsage.Dependencies, excludingToolIDs: Set<String> = []) async throws -> BackendCompositionUsage {
        try requireAssemblyOpen()
        guard usage == nil, let files, !stopped else { throw NativeRPCError(code: "composition-incomplete", message: "Usage requires the retained file and session owners.") }
        let owner = "native-composition:usage"
        let graph = try BackendCompositionUsage(state: state, files: files, accounts: accounts,
            lifecycle: lifecycle, providers: providers, dependencies: dependencies)
        do {
            let registered = try await graph.install(registry: registry, mcp: mcp, ownerID: owner, excludingToolIDs: excludingToolIDs)
            try await retain(.init(name: "usage", domains: ["usage"], ownerID: owner,
                invokes: Set(registered.invokeChannels), sends: Set(registered.sendChannels),
                events: ["usage:update", "plan:update", "cost:update"],
                stop: { await graph.shutdown() }))
            usage = graph; events.bind(usage: graph); return graph
        } catch { await graph.shutdown(); throw error }
    }

    @discardableResult
    public func installRoutines(service: BackendRoutinesService,
                                events: BackendRoutinesEventBindings) async throws -> BackendRoutinesRegistrationHandle {
        try requireAssemblyOpen()
        guard routines == nil, !stopped else { throw NativeRPCError(code: "composition-conflict", message: "Routines already have an owner.") }
        let owner = "native-composition:routines"
        // The seven tool definitions enter the shared deck-tools/core door.
        // Starting the unattended runner waits for that live door's config.
        let registered = try await BackendRoutinesRegistration.register(registry: registry,
            service: service, ownerID: owner, events: events, startEngine: false)
        do {
            try await retain(.init(name: "routines", domains: ["routines"], ownerID: owner,
                invokes: registered.channels, events: ["routines:changed"], stop: {
                    await service.stop(); await registered.cleanup.cancelAndWait()
                }))
            routines = registered; return registered
        } catch { await registered.cleanup.cancelAndWait(); throw error }
    }

    @discardableResult
    public func installRemoteServe(dependencies: BackendRemoteServeRegistration.Dependencies) async throws -> BackendRemoteServeRegistration.Installed {
        try requireAssemblyOpen()
        guard remoteServe == nil, !stopped else { throw NativeRPCError(code: "composition-conflict", message: "Remote serving already has an owner.") }
        let installed = try await BackendRemoteServeRegistration.register(in: self, dependencies: dependencies)
        remoteServe = installed; return installed
    }

    @discardableResult
    public func installMachines(dependencies: BackendMachineRegistration.Dependencies) async throws -> BackendMachineRegistration.Installed {
        try requireAssemblyOpen()
        guard machines == nil else { throw NativeRPCError(code: "composition-conflict", message: "Machines already have a retained owner.") }
        guard let installed = try await BackendMachineRegistration.register(in: self, dependencies: dependencies) else {
            throw NativeRPCError(code: "unavailable", message: "The complete machine supplier graph is missing.")
        }
        machines = installed; return installed
    }

    @discardableResult
    public func installServers(inputs: BackendServersFeatureInputs, oldServerOwnerDisabled: Bool) async throws -> BackendServersFeature {
        try requireAssemblyOpen()
        guard servers == nil else { throw NativeRPCError(code: "composition-conflict", message: "SSH Servers already have a retained owner.") }
        let installed = try await BackendServersComposition.install(in: self, inputs: inputs, oldServerOwnerDisabled: oldServerOwnerDisabled)
        servers = installed; return installed
    }

    /// Definitions carry their actual effective-tier handlers. Bundle them with
    /// the exact source policies/metadata before the one core caller door starts.
    @discardableResult
    public func installDeckTools(definitions: [BackendDeckToolsDefinition],
                                 policies: [BackendDeckCoreSecurityToolPolicy]) async throws -> [BackendDeckCoreCatalogueBundle] {
        try requireAssemblyOpen()
        guard !stopped else { throw NativeRPCError(code: "composition-state", message: "The native composition is stopped.") }
        // Validate every bundle before the atomic MCP contribution mutates.
        let grouped = Dictionary(grouping: definitions) { BackendDeckCoreCatalogueDescribe.areaOf($0.spec.id) }
        let bundles = try grouped.keys.sorted().map { name in
            let rows = grouped[name]!
            let area = try BackendDeckToolsSupport.area(id: name, definitions: rows)
            let ids = Set(rows.map { $0.spec.id })
            return try BackendDeckCoreAreaIntegration.bundle(area: area, metadata: rows.map(\.catalogueMetadata),
                policies: policies.filter { ids.contains($0.tool.id) })
        }
        _ = try await BackendDeckToolsRegistration.register(on: mcp, definitions: definitions)
        do {
            try await retain(.init(name: "deck-tools", domains: ["deck-tools"], ownerID: BackendDeckToolsRegistration.ownerID,
                invokes: [], stop: { [mcp] in await mcp.removeTools(ownerID: BackendDeckToolsRegistration.ownerID) }))
        } catch { await mcp.removeTools(ownerID: BackendDeckToolsRegistration.ownerID); throw error }
        return bundles
    }

    @discardableResult
    public func installDeckCore(providers: BackendDeckCoreRegistration.Providers,
                                options: BackendDeckCoreRegistration.Options,
                                clientsAuthority: BackendCompositionClientsSecurityAuthority? = nil,
                                oldCoreOwnerDisabled: Bool) async throws -> BackendDeckCoreRuntime {
        try requireAssemblyOpen()
        guard core == nil, oldCoreOwnerDisabled, options.ownership == state.ownership else {
            throw NativeRPCError(code: "ownership-required", message: "The native core must share the Store lease after Node relinquishes the core door and records.")
        }
        guard clients == nil || clientsAuthority != nil else {
            throw NativeRPCError(code: "composition-incomplete", message: "Native clients require the actual matched-grant exchange authority on the core door.")
        }
        let supplied: BackendDeckCoreRegistration.Providers
        if let clientsAuthority {
            guard providers.authenticatedExchange == nil else {
                throw NativeRPCError(code: "composition-conflict", message: "The native core already has an authenticated-exchange owner.")
            }
            supplied = .init(surface: providers.surface, window: providers.window,
                whereDependencies: providers.whereDependencies, mcp: providers.mcp,
                features: providers.features, contributions: providers.contributions,
                tours: providers.tours, relay: providers.relay, taskHTTP: providers.taskHTTP,
                livePolicies: providers.livePolicies, liveMetadata: providers.liveMetadata,
                mcpPolicies: providers.mcpPolicies, channelBridge: providers.channelBridge,
                authenticatedExchange: { grant, cancellation, operation in
                    await clientsAuthority.withAuthenticatedGrant(grant: grant, cancellation: cancellation, operation: operation)
                }, beforeListing: { [weak self] in
                    guard let self else { throw NativeRPCError(code: "closed", message: "The native client composition has stopped.") }
                    try await self.refreshClientPluginTools()
                    try await providers.beforeListing?()
                })
        } else { supplied = providers }
        let graph = try await BackendDeckCoreRegistration.register(registry: registry, ownPorts: ownPorts,
            dataDirectory: dataRoot, providers: supplied, options: options)
        do {
            try coreControl.bind(graph.control)
            try await retain(.init(name: "deck-core", domains: ["deck-core"], ownerID: options.ownerID,
                invokes: Set(BackendDeckCoreRuntime.channels + BackendDeckCoreEventsAIApps.channels),
                events: Set(BackendDeckCoreRuntime.pushChannels + ["ai-apps:changed"]), stop: { await graph.stop() }))
            core = graph; coreClientsAuthority = clientsAuthority
            coreHasClientsExchange = clientsAuthority != nil || supplied.authenticatedExchange != nil
            events.bind(core: graph); return graph
        } catch { coreControl.unbind(graph.control); await graph.stop(); throw error }
    }

    /// Policies may retain this before installDeckCore. It forwards only to the
    /// real control after binding and refuses calls while assembly is incomplete.
    public nonisolated func compositionCoreGate() -> BackendCompositionCoreGate { coreControl.gate }
    public func requireHootServices(sessions: BackendCompositionSessions, deckCore: BackendDeckCoreRuntime) throws {
        try requireAssemblyOpen()
        guard self.sessions === sessions, core === deckCore else {
            throw NativeRPCError(code: "composition-incomplete", message: "Hoot must use this composition's installed session and deck-core owners.")
        }
    }
    private func refreshClientPluginTools() async throws {
        guard !stopped else { throw NativeRPCError(code: "closed", message: "The native client composition has stopped.") }
        try await clients?.refreshPluginTools()
    }

    @discardableResult
    public func installTasks(view: BackendTaskStateView, local: BackendTaskLocalService,
                             engine: BackendTaskEngine, detail: BackendTaskDetailService,
                             monitor: BackendTaskTurnMonitor, planning: BackendGoalPlanning,
                             api: BackendTaskAPI?, delegation: BackendTaskDelegation?,
                             dependencies: BackendTaskChannelDependencies, authority: BackendTaskToolAuthority,
                             knowledge: BackendTaskKnowledgeAdapter?, indexed: Bool,
                             readAttachment: (@Sendable (BackendMCPCallContext, String) async throws -> (name: String, mime: String?, bytes: Data))?,
                             oldTaskOwnerDisabled: Bool) async throws -> BackendTaskRegistration {
        try requireAssemblyOpen()
        guard tasks == nil, oldTaskOwnerDisabled, dependencies.inventory != nil else {
            throw NativeRPCError(code: "composition-incomplete", message: "Tasks require sole native ownership and the real account inventory supplier.")
        }
        let owner = "native-composition:tasks"
        let installed = try await BackendTaskRegistration.install(registry: registry, server: mcp, ownerID: owner,
            view: view, local: local, engine: engine, detail: detail, monitor: monitor, planning: planning,
            api: api, delegation: delegation, dependencies: dependencies, authority: authority, knowledge: knowledge,
            indexed: indexed, readAttachment: readAttachment)
        do {
            try await retain(.init(name: "tasks", domains: ["tasks"], ownerID: owner,
                invokes: Set(installed.invokes), sends: Set(installed.sends), events: Set(installed.events),
                stop: { try await installed.stop() }))
            tasks = installed
            // The caller starts this retained registration only after all
            // task runners, change recipients and shared services are bound.
            return installed
        } catch { try? await installed.stop(); throw error }
    }

    /// The host receives one direct-access provider using this root's tailnet
    /// and port owner. Construction does no IO; HostService.start owns launch.
    public func remoteHostService(endpoint: BackendRemoteHost, relayURL: String?, webRoot: URL?,
                                  hostName: String, preview: Bool,
                                  mcp: BackendRemoteRelayClient.MCPHandler? = nil, directPort: UInt16 = 8443,
                                  afterEndpointStart: (@Sendable () async throws -> Void)? = nil) throws -> BackendRemoteHostService {
        try requireAssemblyOpen()
        let direct = BackendCompositionPreviewDirect(preview: preview, relayAvailable: relayURL != nil,
            actual: BackendRemoteServeHostServiceDirect(tailnet: tailnet))
        return BackendRemoteHostService(endpoint: endpoint, ownPorts: ownPorts, relayURL: relayURL,
            webRoot: webRoot, tailnet: direct, hostName: hostName, mcp: mcp, directPort: directPort,
            afterEndpointStart: afterEndpointStart)
    }

    @discardableResult
    public func installCRM(configuration: BackendTaskConfiguration,
                           detailOwnership: BackendCrmRegistration.DetailOwnership,
                           taskState: @escaping @Sendable () async throws -> NativeRPCValue,
                           subscribeChanges: @escaping BackendCrmRegistration.ChangeSubscriber,
                           installSuppliers: @escaping BackendCrmRegistration.SupplierInstaller,
                           problem: @escaping @Sendable (NativeRPCError) async -> Void) async throws -> BackendCrmRegistration.Contribution {
        try requireAssemblyOpen()
        let owner = "native-composition:crm"
        let contribution = try await BackendCrmRegistration.register(registry: registry, ownerID: owner,
            configuration: configuration, detailOwnership: detailOwnership, state: taskState,
            subscribeChanges: subscribeChanges, installSuppliers: installSuppliers, problem: problem)
        do {
            try await retain(.init(name: "crm", domains: ["crm"], ownerID: owner,
                invokes: Set(contribution.ownedChannels), events: Set(contribution.eventChannels),
                stop: { await contribution.lease.cancelAndWait() }))
            return contribution
        } catch { await contribution.lease.cancelAndWait(); throw error }
    }

    public func manifest() -> NativeRPCValue {
        .object([.init("domains", .array(domains().map(NativeRPCValue.string))),
            .init("invoke", .array(areas.values.flatMap { $0.invokes }.sorted().map(NativeRPCValue.string))),
            .init("send", .array(areas.values.flatMap { $0.sends }.sorted().map(NativeRPCValue.string))),
            .init("events", .array(areas.values.flatMap { $0.events }.sorted().map(NativeRPCValue.string)))])
    }
    public func domains() -> [String] { Set(areas.values.flatMap { $0.domains }).sorted() }
    public func hasInvoke(_ channel: String) -> Bool { !stopped && areas.values.contains { $0.invokes.contains(channel) } }
    public func hasSend(_ channel: String) -> Bool { !stopped && areas.values.contains { $0.sends.contains(channel) } }
    public func ownsEvent(_ channel: String) -> Bool { !stopped && areas.values.contains { $0.events.contains(channel) } }
    public func invoke(_ channel: String, context: NativeRPCContext, arguments: [NativeRPCValue]) async throws -> NativeRPCValue {
        guard hasInvoke(channel) else { throw NativeRPCError(code: "missing-handler", message: "No native handler registered for '\(channel)'") }
        // TS diagnostics.ts timed(): one record per page/app call on the shared dispatcher (app.log "calls").
        guard let metrics = callMetrics else { return try await registry.invoke(channel, context: context, arguments: arguments) }
        let started = await metrics.started(channel)
        do {
            let value = try await registry.invoke(channel, context: context, arguments: arguments)
            await metrics.finish(channel, kind: "invoke", started: started); return value
        } catch { await metrics.finish(channel, kind: "invoke", started: started, error: error); throw error }
    }
    /// The diagnostics' call observer; the one dispatcher above then times every call.
    public func observeCalls(_ metrics: BackendMacAppSetupIPCMetrics) async {
        callMetrics = metrics; await metrics.activate(sharedDispatcherUsesThisObserver: true)
    }
    public func send(_ channel: String, context: NativeRPCContext, arguments: [NativeRPCValue]) async throws {
        guard hasSend(channel) else { throw NativeRPCError(code: "missing-handler", message: "No native send handler registered for '\(channel)'") }
        _ = try await registry.send(channel, context: context, arguments: arguments)
    }
    /// `trace` names each shutdown step and any step still running after five
    /// seconds, so a quit that does not finish says where it is waiting.
    public func shutdown(trace: (@Sendable (String) -> Void)? = nil) async throws {
        guard !stopped else { return }; stopped = true
        // Consumers stop before their dispatch/caller owners. Store stays alive
        // until the transitional engine has saved its final session ledger.
        let consumers = areas.values.filter { $0.name != "sessions" }.sorted { $0.name > $1.name }
        let order = consumers + areas.values.filter { $0.name == "sessions" }
        for area in order {
            do { try await Self.traced("area " + area.name, trace) { try await area.stop() } }
            catch { stopped = false; throw error }
            await registry.removeOwner(area.ownerID); await mcp.removeTools(ownerID: area.ownerID)
            areas[area.name] = nil
        }
        areas.removeAll(); coreControl.close()
        await Self.traced("events", trace) { await events.stop() }
        await Self.traced("mcp", trace) { await mcp.stop() }
        await registry.shutdown()
        clients = nil; files = nil; usage = nil; routines = nil; remoteServe = nil; sessions = nil; core = nil; stateProjection = nil; tasks = nil
        machines = nil; servers = nil
        coreClientsAuthority = nil
        coreHasClientsExchange = false
    }

    /// One named shutdown step: logged when it starts, again if it is still
    /// running after five seconds, and with its duration when it ends.
    public static func traced<T>(_ name: String, _ trace: (@Sendable (String) -> Void)?,
                                 isolation: isolated (any Actor)? = #isolation,
                                 _ step: () async throws -> T) async rethrows -> T {
        guard let trace else { return try await step() }
        let started = Date()
        trace("stopping " + name)
        let watchdog = Task { try await Task.sleep(for: .seconds(5)); trace("still stopping " + name + " after 5 s") }
        defer { watchdog.cancel(); trace("stopped " + name + " in \(Int(Date().timeIntervalSince(started) * 1000)) ms") }
        return try await step()
    }
}
