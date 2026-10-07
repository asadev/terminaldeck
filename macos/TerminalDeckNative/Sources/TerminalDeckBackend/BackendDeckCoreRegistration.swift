import Foundation
import TerminalDeckNativeCore

/// The one startup call for the composition root. It assembles the existing
/// Runtime; it does not create another server, caller table, Store or catalogue.
public enum BackendDeckCoreRegistration {
    public struct Providers: Sendable {
        public let surface: any BackendDeckCoreCatalogueSurface & BackendDeckCoreEventsDetectionSurface
        public let window: BackendDeckCoreWindowConsent
        public let whereDependencies: BackendDeckCoreCatalogueWhereDependencies
        public let mcp: any BackendDeckCoreEventsMCPProvider
        public let mcpPolicies: [BackendDeckCoreSecurityToolPolicy]?
        public let features: any BackendDeckCoreFeatureLifecycle
        public let contributions: [BackendDeckCoreCatalogueBundle]
        public let tours: (any BackendDeckCoreTours)?
        public let relay: (any BackendDeckCoreRelayInstallation)?
        public let taskHTTP: (any BackendDeckCoreSecurityTaskHTTP)?
        public let livePolicies: @Sendable () throws -> [BackendDeckCoreSecurityToolPolicy]
        public let liveMetadata: @Sendable () throws -> [BackendDeckCoreCatalogueMetadata]
        public let channelBridge: @Sendable () async throws -> String?
        /// Root: `{ grant, scope, operation in try await clientsAuthority.withAuthenticatedGrant(grant: grant, cancellation: scope, operation: operation) }`.
        public let authenticatedExchange: BackendDeckCoreSecurityServer.AuthenticatedExchange?
        /// Root: `{ try await clients.refreshPluginTools() }`.
        public let beforeListing: BackendDeckCoreSecurityServer.BeforeListing?

        /// Required services have no fake defaults. Optional services retain
        /// source absence semantics, including a genuinely absent helper path.
        public init(surface: any BackendDeckCoreCatalogueSurface & BackendDeckCoreEventsDetectionSurface,
                    window: BackendDeckCoreWindowConsent,
                    whereDependencies: BackendDeckCoreCatalogueWhereDependencies,
                    mcp: any BackendDeckCoreEventsMCPProvider,
                    features: any BackendDeckCoreFeatureLifecycle,
                    contributions: [BackendDeckCoreCatalogueBundle] = [],
                    tours: (any BackendDeckCoreTours)? = nil,
                    relay: (any BackendDeckCoreRelayInstallation)? = nil,
                    taskHTTP: (any BackendDeckCoreSecurityTaskHTTP)? = nil,
                    livePolicies: @escaping @Sendable () throws -> [BackendDeckCoreSecurityToolPolicy] = { [] },
                    liveMetadata: @escaping @Sendable () throws -> [BackendDeckCoreCatalogueMetadata] = { [] },
                    mcpPolicies: [BackendDeckCoreSecurityToolPolicy]? = nil,
                    channelBridge: @escaping @Sendable () async throws -> String?,
                    authenticatedExchange: BackendDeckCoreSecurityServer.AuthenticatedExchange? = nil,
                    beforeListing: BackendDeckCoreSecurityServer.BeforeListing? = nil) {
            self.surface = surface; self.window = window; self.whereDependencies = whereDependencies
            self.mcp = mcp; self.mcpPolicies = mcpPolicies; self.features = features; self.contributions = contributions
            self.tours = tours; self.relay = relay; self.taskHTTP = taskHTTP
            self.livePolicies = livePolicies; self.liveMetadata = liveMetadata; self.channelBridge = channelBridge
            self.authenticatedExchange = authenticatedExchange; self.beforeListing = beforeListing
        }
    }

    public struct Options: Sendable {
        public let ownership: NativeStateStore.Ownership
        public let port: Int?
        public let consentTimeoutMilliseconds: Int
        public let budgets: BackendDeckCoreSecurityBudgets
        public let ownerID: String
        public let report: @Sendable (String) -> Void
        /// Test/embedding transports use the same authenticated request handler.
        /// Nil keeps the real source loopback listener and consent scheduler.
        public let listenerFactory: BackendDeckCoreSecurityListenerFactory?
        public let consentClock: (any BackendDeckCoreEventsClock)?
        public let notificationClock: (any BackendDeckCoreEventsClock)?
        public let typingClock: BackendDeckCoreBriefClock

        public init(ownership: NativeStateStore.Ownership,
                    port: Int? = nil, consentTimeoutMilliseconds: Int = 120_000,
                    budgets: BackendDeckCoreSecurityBudgets = .init(),
                    ownerID: String = "native-deck-control",
                    report: @escaping @Sendable (String) -> Void = { _ in },
                    listenerFactory: BackendDeckCoreSecurityListenerFactory? = nil,
                    consentClock: (any BackendDeckCoreEventsClock)? = nil,
                    notificationClock: (any BackendDeckCoreEventsClock)? = nil,
                    typingClock: BackendDeckCoreBriefClock = .real) {
            self.ownership = ownership; self.port = port; self.consentTimeoutMilliseconds = consentTimeoutMilliseconds
            self.budgets = budgets; self.ownerID = ownerID; self.report = report
            self.listenerFactory = listenerFactory; self.consentClock = consentClock; self.notificationClock = notificationClock
            self.typingClock = typingClock
        }
    }

    /// Call once after the original writer relinquishes ownership, before
    /// restoring sessions or launching Hoot. Retain the returned handle and
    /// await stop() during shutdown. Configs/caller leases belong to this handle.
    @discardableResult
    public static func register(registry: NativeChannelRegistry,
                                ownPorts: BackendDevOwnPorts,
                                dataDirectory: URL,
                                providers: Providers,
                                options: Options) async throws -> BackendDeckCoreRuntime {
        try await BackendDeckCoreRuntime.start(
            registry: registry, ownPorts: ownPorts, dataDirectory: dataDirectory,
            surface: providers.surface, window: providers.window,
            whereDependencies: providers.whereDependencies, mcpProvider: providers.mcp,
            features: providers.features, contributions: providers.contributions,
            tours: providers.tours, relay: providers.relay, taskHTTP: providers.taskHTTP,
            livePolicies: providers.livePolicies, liveMetadata: providers.liveMetadata,
            channelBridge: providers.channelBridge, ownership: options.ownership,
            port: options.port, consentTimeoutMilliseconds: options.consentTimeoutMilliseconds,
            budgets: options.budgets, ownerID: options.ownerID, report: options.report,
            listenerFactory: options.listenerFactory, consentClock: options.consentClock,
            notificationClock: options.notificationClock, suppliedMCPPolicies: providers.mcpPolicies, typingClock: options.typingClock,
            authenticatedExchange: providers.authenticatedExchange, beforeListing: providers.beforeListing)
    }
}
