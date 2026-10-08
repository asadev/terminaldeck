import Foundation
import TerminalDeckNativeCore

/// Metrics share the actual account, session, project and filesystem owners.
/// This assembly installs routes but starts nothing before the whole native
/// Store/session ownership transfer has completed.
public actor BackendCompositionUsage {
    public struct Dependencies: Sendable {
        public let transcriptScope: BackendCostScopeProvider
        public let authorizeRPC: BackendUsageRPC.Authorization
        /// The supplier targets the actual owner and rechecks live grants before
        /// delivering private usage/cost updates. A global broadcast is invalid.
        public let push: @Sendable (String, String, NativeRPCValue) async -> Void
        public let modelLabel: @Sendable (String) -> String
        public let preferredProvider: @Sendable (String) async -> String?
        public let authorizeReadinessMutation: @Sendable (NativeRPCContext) throws -> Void
        public let appName: String
        public init(transcriptScope: @escaping BackendCostScopeProvider,
                    authorizeRPC: @escaping BackendUsageRPC.Authorization,
                    push: @escaping @Sendable (String, String, NativeRPCValue) async -> Void,
                    modelLabel: @escaping @Sendable (String) -> String,
                    preferredProvider: @escaping @Sendable (String) async -> String?,
                    authorizeReadinessMutation: @escaping @Sendable (NativeRPCContext) throws -> Void,
                    appName: String) {
            self.transcriptScope = transcriptScope; self.authorizeRPC = authorizeRPC; self.push = push
            self.modelLabel = modelLabel; self.preferredProvider = preferredProvider
            self.authorizeReadinessMutation = authorizeReadinessMutation; self.appName = appName
        }
    }
    public struct Registration: Sendable {
        public let invokeChannels: [String]
        public let sendChannels: [String]
        public let tools: [String]
    }

    public nonisolated let cost: BackendCostService
    public nonisolated let usage: BackendUsageService
    public nonisolated let insights: BackendInsightsService
    public nonisolated let search: BackendSessionSearchService
    public nonisolated let alerts: BackendAlertsService
    public nonisolated let readiness: BackendReadinessService
    public nonisolated let rpc: BackendUsageRPC
    private let state: NativeStateStore
    private let projects: BackendProjectService
    private var registry: NativeChannelRegistry?
    private var registrationOwner: String?
    private var subscriptions: [NativeRPCSubscription] = []
    private var toolServer: BackendNativeMCPServer?
    private var started = false
    private var installing = false
    private var stopped = false

    /// Suppliers are mandatory because absent accounts/session authority or an
    /// invented transcript scope would change which person's records are read.
    public init(state: NativeStateStore, files: BackendCompositionFiles,
                accounts: BackendAccountLaunchAdapter, lifecycle: BackendSessionLifecycleCoordinator,
                providers: BackendNativeProviders, dependencies: Dependencies) throws {
        guard !dependencies.appName.isEmpty else { throw NativeRPCError.invalidArguments("The metrics graph needs the actual app name") }
        self.state = state; projects = files.projects
        let cost = BackendCostService(projects: files.projects, scopeProvider: dependencies.transcriptScope, push: dependencies.push)
        self.cost = cost
        let usage = BackendUsageService(accounts: accounts, lifecycle: lifecycle, store: state,
            cost: cost, providers: providers, modelLabel: dependencies.modelLabel, push: dependencies.push)
        self.usage = usage
        let insights = BackendInsightsService(cost: cost)
        self.insights = insights
        let search = BackendSessionSearchService(cost: cost, projects: files.projects)
        self.search = search
        let alerts = BackendAlertsService(cost: cost, lifecycle: lifecycle, projects: files.projects,
            git: files.git, providers: providers, defaultProvider: dependencies.preferredProvider)
        self.alerts = alerts
        let tools = BackendReadinessTools(providers: providers, executor: files.processExecutor,
            authority: files.authority, inheritedEnvironment: files.inheritedEnvironment,
            home: files.home, guestPlan: files.guestGitPlan)
        let readiness = BackendReadinessService(projects: files.projects, git: files.git, tools: tools,
            appName: dependencies.appName, authorizeMutation: dependencies.authorizeReadinessMutation)
        self.readiness = readiness
        rpc = BackendUsageRPC(usage: usage, cost: cost, insights: insights, search: search,
            alerts: alerts, readiness: readiness, authorize: dependencies.authorizeRPC)
    }

    /// Omit toolAccess when deck-core/deck-tools own the same tool identities.
    /// There is no default consent or action-log bypass. The root can instead
    /// supply these retained services to its central area registration.
    public func install(registry: NativeChannelRegistry, mcp: BackendNativeMCPServer,
                        ownerID: String, toolAccess: BackendUsageToolAccess? = nil,
                        excludingToolIDs: Set<String> = []) async throws -> Registration {
        guard !stopped, !installing, registrationOwner == nil, !ownerID.isEmpty else {
            throw NativeRPCError(code: "composition-state", message: "The metrics graph is stopped or already installed")
        }
        installing = true; defer { installing = false }
        for channel in BackendUsageRPC.invokeChannels {
            if await registry.has(channel) { throw NativeRPCError(code: "duplicate-handler", message: "The metrics graph cannot replace another owner of '\(channel)'") }
        }
        if toolAccess != nil {
            let present = Set(try await mcp.catalogue().map(\.id)), overlap = Self.toolIDs.subtracting(excludingToolIDs).intersection(present)
            guard overlap.isEmpty else { throw NativeRPCError(code: "duplicate-tool", message: "Metrics tools already have owners: \(overlap.sorted().joined(separator: ", "))") }
        }
        registrationOwner = ownerID; self.registry = registry
        do {
            for channel in BackendUsageRPC.invokeChannels.sorted() {
                try await registry.register(channel, ownerID: ownerID) { [rpc] context, args in
                    try await rpc.invoke(channel, args: args, context: context)
                }
            }
            for channel in BackendUsageRPC.sendChannels.sorted() {
                let subscription = try await registry.onSend(channel, ownerID: ownerID) { [rpc] context, args in
                    try await rpc.send(channel, args: args, context: context)
                }
                subscriptions.append(subscription)
            }
            let tools: [String]
            if let toolAccess {
                let collector = BackendNativeMCPServer()
                _ = try await BackendUsageMCPTools.register(server: collector, usage: usage, cost: cost,
                    insights: insights, search: search, alerts: alerts, readiness: readiness,
                    projects: projects, access: toolAccess)
                let contribution = await collector.registrations().filter { !excludingToolIDs.contains($0.0.id) }
                try await mcp.replaceTools(ownerID: ownerID, tools: contribution)
                toolServer = mcp; tools = contribution.map { $0.0.id }
            } else { tools = [] }
            return Registration(invokeChannels: BackendUsageRPC.invokeChannels.sorted(),
                sendChannels: BackendUsageRPC.sendChannels.sorted(), tools: tools.sorted())
        } catch {
            for subscription in subscriptions { await subscription.cancelAndWait() }; subscriptions = []
            await toolServer?.removeTools(ownerID: ownerID); toolServer = nil
            await registry.removeOwner(ownerID); registrationOwner = nil; self.registry = nil
            throw error
        }
    }

    /// Only the root knows when the existing native session/account graph has
    /// replaced Node. No refresh or credential probe occurs merely by starting.
    public func startAfterOwnershipTransfer() async throws {
        guard !stopped, registrationOwner != nil else { throw NativeRPCError(code: "composition-state", message: "Install the metrics graph before starting it") }
        guard state.ownership == .exclusive || state.ownership == .memory else {
            throw NativeRPCError(code: "ownership", message: "Node still owns Store/session state; native metrics observers are not started")
        }
        guard !started else { return }; started = true
        await rpc.start()
    }

    /// Wire this into the sole coordinator's accepted lifecycle emit callback.
    /// Its raw PTY observation is already owned by that coordinator.
    public func noteLifecycleEvent(_ event: BackendSessionLifecycleEvent) async {
        guard started, !stopped else { return }; await rpc.noteLifecycleEvent(event)
    }
    public func disconnect(ownerID: String) async { await rpc.disconnect(ownerID: ownerID) }

    public func shutdown() async {
        guard !stopped else { return }; stopped = true; started = false
        await rpc.stop()
        for subscription in subscriptions { await subscription.cancelAndWait() }; subscriptions = []
        if let registry, let registrationOwner { await toolServer?.removeTools(ownerID: registrationOwner); await registry.removeOwner(registrationOwner) }
        toolServer = nil
        registry = nil; registrationOwner = nil
    }

    public static let toolIDs: Set<String> = ["usage.read", "usage.refresh", "usage.cost", "chats.insights", "sessions.search", "alerts.list"]
}
