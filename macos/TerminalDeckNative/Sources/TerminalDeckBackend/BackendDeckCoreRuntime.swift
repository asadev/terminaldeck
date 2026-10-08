import Foundation
import TerminalDeckNativeCore

private final class BackendDeckCoreRuntimeClaims: @unchecked Sendable {
    static let shared = BackendDeckCoreRuntimeClaims()
    private let lock = NSLock()
    private var entries = Set<ObjectIdentifier>()
    func take(_ registry: NativeChannelRegistry) -> Bool { lock.withLock { entries.insert(ObjectIdentifier(registry)).inserted } }
    func release(_ registry: NativeChannelRegistry) { _ = lock.withLock { entries.remove(ObjectIdentifier(registry)) } }
}
private final class BackendDeckCoreRuntimeReferences: @unchecked Sendable {
    private let lock = NSLock()
    private weak var control: BackendDeckCoreSecurityControl?
    private weak var detector: BackendDeckCoreEventsDetector?
    private weak var hub: BackendDeckCoreEventsHub?
    func setControl(_ control: BackendDeckCoreSecurityControl) { lock.withLock { self.control = control } }
    func setNotifications(_ value: BackendDeckCoreEventsComposition) { lock.withLock { detector = value.detector; hub = value.hub } }
    func notificationHub() -> BackendDeckCoreEventsHub? { lock.withLock { hub } }
    func starter(_ session: String) async -> String? { let value = lock.withLock { control }; return await value?.starterOf(sessionID: session) }
    func note(_ row: NativeRPCValue) async { let value = lock.withLock { detector }; await value?.noteRow(row) }
}
private final class BackendDeckCoreRuntimeMetadata: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [BackendDeckCoreCatalogueMetadata] = []
    private let live: @Sendable () throws -> [BackendDeckCoreCatalogueMetadata]
    init(live: @escaping @Sendable () throws -> [BackendDeckCoreCatalogueMetadata]) { self.live = live }
    func set(_ value: [BackendDeckCoreCatalogueMetadata]) { lock.withLock { self.value = value } }
    func read() -> [BackendDeckCoreCatalogueMetadata] {
        let fixed = lock.withLock { value }, offered = (try? live()) ?? []
        var taken = Set(fixed.flatMap { [$0.tool.id, $0.tool.wireName] + $0.aliases })
        return fixed + offered.filter { entry in
            guard !taken.contains(entry.tool.id), !taken.contains(entry.tool.wireName) else { return false }
            taken.insert(entry.tool.id); taken.insert(entry.tool.wireName); return true
        }
    }
}

/// Native index.ts assembly. This factory is an explicit startup operation;
/// merely importing these files never reads records, binds a port or connects.
public actor BackendDeckCoreRuntime {
    public static let channels = ["deck-control:status", "deck-control:activity", "deck-control:consent-attach", "deck-control:consent-respond", "deck-control:tour-report", "deck-control:tours"]
    public static let pushChannels = ["deck-control:consent-request", "deck-control:consent-settled", "deck-control:action", "deck-control:tour"]
    public nonisolated let endpoint: BackendDeckCoreSecurityEndpoint
    public nonisolated let control: BackendDeckCoreSecurityControl
    public nonisolated let consent: BackendDeckCoreSecurityConsentBroker
    public nonisolated let log: BackendDeckCoreSecurityActionLog
    public nonisolated let keys: BackendDeckCoreSecurityAccessKeys
    public nonisolated let door: BackendDeckCoreSecurityAccessKeyDoor
    public nonisolated let notifications: BackendDeckCoreEventsComposition
    public nonisolated let sessionEndpoint: BackendDeckCoreSessionEndpoint
    public nonisolated let configPath: URL
    public nonisolated let unattendedConfigPath: URL
    private let registry: NativeChannelRegistry
    /// The one authoritative security server (Hoot wraps it, never a second door).
    public nonisolated let server: BackendDeckCoreSecurityServer
    /// Live catalogue titles for Hoot's composed layer (the same metadata the
    /// describe tool reads); Hoot's MCP door matches them by wire name + tier.
    public nonisolated func hootLayerTitles() -> [BackendCopilotLayerTool] {
        BackendUIGMemoryDiscovery.metadata(metadata.read()).map { BackendCopilotLayerTool($0.tool, title: $0.title) }
    }
    private let window: BackendDeckCoreWindowConsent
    private let metadata: BackendDeckCoreRuntimeMetadata
    private let features: any BackendDeckCoreFeatureLifecycle
    private let tours: (any BackendDeckCoreTours)?
    private let relay: (any BackendDeckCoreRelayInstallation)?
    private let files: BackendTaskPersistence
    private let ownerID: String
    private let report: @Sendable (String) -> Void
    private var keyObserver: UUID?
    private var aiAppsObserver: NativeRPCSubscription?
    private var stopped = false

    private init(endpoint: BackendDeckCoreSecurityEndpoint, control: BackendDeckCoreSecurityControl,
                 consent: BackendDeckCoreSecurityConsentBroker, log: BackendDeckCoreSecurityActionLog,
                 keys: BackendDeckCoreSecurityAccessKeys, door: BackendDeckCoreSecurityAccessKeyDoor,
                 notifications: BackendDeckCoreEventsComposition, configs: (attended: URL, unattended: URL),
                 registry: NativeChannelRegistry, server: BackendDeckCoreSecurityServer, window: BackendDeckCoreWindowConsent,
                 metadata: BackendDeckCoreRuntimeMetadata, features: any BackendDeckCoreFeatureLifecycle,
                 tours: (any BackendDeckCoreTours)?, relay: (any BackendDeckCoreRelayInstallation)?,
                 files: BackendTaskPersistence, ownerID: String, report: @escaping @Sendable (String) -> Void) {
        self.endpoint = endpoint; self.control = control; self.consent = consent; self.log = log; self.keys = keys; self.door = door
        self.notifications = notifications; sessionEndpoint = BackendDeckCoreSessionEndpoint(server: server, control: control)
        configPath = configs.attended; unattendedConfigPath = configs.unattended
        self.registry = registry; self.server = server; self.window = window; self.metadata = metadata; self.features = features
        self.tours = tours; self.relay = relay; self.files = files; self.ownerID = ownerID; self.report = report
    }
    public static func start(registry: NativeChannelRegistry, ownPorts: BackendDevOwnPorts, dataDirectory: URL,
                             surface: any BackendDeckCoreCatalogueSurface & BackendDeckCoreEventsDetectionSurface,
                             window: BackendDeckCoreWindowConsent, whereDependencies: BackendDeckCoreCatalogueWhereDependencies,
                             mcpProvider: any BackendDeckCoreEventsMCPProvider,
                             features: any BackendDeckCoreFeatureLifecycle,
                             contributions: [BackendDeckCoreCatalogueBundle] = [], tours: (any BackendDeckCoreTours)? = nil,
                             relay: (any BackendDeckCoreRelayInstallation)? = nil,
                             taskHTTP: (any BackendDeckCoreSecurityTaskHTTP)? = nil,
                             livePolicies: @escaping @Sendable () throws -> [BackendDeckCoreSecurityToolPolicy] = { [] },
                             liveMetadata: @escaping @Sendable () throws -> [BackendDeckCoreCatalogueMetadata] = { [] },
                             channelBridge: @escaping @Sendable () async throws -> String?,
                             ownership: NativeStateStore.Ownership, port: Int? = nil,
                             consentTimeoutMilliseconds: Int = 120_000, budgets: BackendDeckCoreSecurityBudgets = .init(),
                             ownerID: String = "native-deck-control", report: @escaping @Sendable (String) -> Void = { _ in },
                             listenerFactory: BackendDeckCoreSecurityListenerFactory? = nil,
                             consentClock: (any BackendDeckCoreEventsClock)? = nil,
                             notificationClock: (any BackendDeckCoreEventsClock)? = nil,
                             suppliedMCPPolicies: [BackendDeckCoreSecurityToolPolicy]? = nil,
                             typingClock: BackendDeckCoreBriefClock = .real,
                             authenticatedExchange: BackendDeckCoreSecurityServer.AuthenticatedExchange? = nil,
                             beforeListing: BackendDeckCoreSecurityServer.BeforeListing? = nil) async throws -> BackendDeckCoreRuntime {
        guard BackendDeckCoreRuntimeClaims.shared.take(registry) else {
            throw NativeRPCError(code: "duplicate-handler", message: "deck-control: registerDeckControlIpc was called twice")
        }
        var handedOff = false
        defer { if !handedOff { BackendDeckCoreRuntimeClaims.shared.release(registry) } }
        guard ownership == .exclusive else {
            throw NativeRPCError(code: "read-only", message: "The original engine must give up deck-control record ownership before native startup.")
        }
        guard dataDirectory.isFileURL, dataDirectory.path.hasPrefix("/"), !dataDirectory.path.contains("\0") else { throw NativeRPCError.invalidArguments("deck-control needs the app's absolute data directory") }
        if await registry.has("deck-control:status") { throw NativeRPCError(code: "duplicate-handler", message: "deck-control: registerDeckControlIpc was called twice") }
        guard surface.copilotRoot().hasPrefix("/"), !surface.copilotRoot().contains("\0") else {
            throw NativeRPCError.invalidArguments("Deck control needs Hoot’s full folder path.")
        }
        let root = URL(fileURLWithPath: surface.copilotRoot(), isDirectory: true)
        let files = try BackendTaskPersistence(directory: root, ownership: ownership)
        // copilotPaths keeps audit records beside the editable home, even when
        // the owner chooses a different home. They stay inside the records fence.
        let log = BackendDeckCoreSecurityActionLog(directory: RNMHootPaths(dataRoot: dataDirectory).log)
        let consent = BackendDeckCoreSecurityConsentBroker(timeoutMilliseconds: consentTimeoutMilliseconds, clock: consentClock,
            ask: { await window.ask($0) }, settled: { await window.settled(id: $0, outcome: $1) })
        let keys = BackendDeckCoreSecurityAccessKeys(directory: dataDirectory.appendingPathComponent("remote", isDirectory: true))
        await keys.load()
        let references = BackendDeckCoreRuntimeReferences()
        let metadata = BackendDeckCoreRuntimeMetadata(live: liveMetadata)
        let notificationTools = try BackendDeckCoreEventsTools.notificationPolicies(hub: { references.notificationHub() })
        let mcpTools = try BackendDeckCoreMCPPolicies.resolve(provider: mcpProvider, supplied: suppliedMCPPolicies)
        let bundles = try [BackendDeckCoreCatalogueBuiltins.tools(surface: surface, typingClock: typingClock), BackendDeckCoreCatalogueWhere.tools(dependencies: whereDependencies),
            BackendDeckCoreCatalogueCoverage.tools(), BackendDeckCoreAreaIntegration.eventsBundle(policies: notificationTools + mcpTools)] + contributions
        let describe = try BackendDeckCoreCatalogueDescribe.tools(catalogue: { metadata.read() })
        let allMetadata = bundles.flatMap(\.metadata) + describe.metadata
        _ = try BackendDeckCoreCatalogueRegistry(metadata: allMetadata)
        metadata.set(allMetadata)
        let control = try BackendDeckCoreSecurityControl(log: log, consent: consent, policies: bundles.flatMap(\.policies) + describe.policies,
            budgets: budgets, driving: { await tours?.driving() ?? false }, liveTools: livePolicies,
            onRow: { row in await references.note(row); try await registry.publish("deck-control:action", arguments: [row]) })
        references.setControl(control)
        let notifications = await BackendDeckCoreEventsComposition.make(directory: dataDirectory.appendingPathComponent("remote", isDirectory: true), keys: keys,
            surface: surface, starterOf: { await references.starter($0) }, clock: notificationClock ?? BackendDeckCoreEventsRealClock(),
            onChange: { Task { try? await registry.publish("ai-apps:changed", arguments: []) } }, report: report)
        references.setNotifications(notifications)
        let door = BackendDeckCoreSecurityAccessKeyDoor(keys: keys, consent: consent, events: { notifications.events })
        await door.activate()
        let server = BackendDeckCoreSecurityServer(control: control, keys: door, ownPorts: ownPorts, tasks: taskHTTP,
            listenerFactory: listenerFactory ?? { BackendDeckCoreSecurityNativeListening(handler: $0) },
            listing: { policies, caller, grant in
                let ids = Set(policies.map { $0.tool.id }), rows = metadata.read().filter { ids.contains($0.tool.id) }
                guard Set(rows.map { $0.tool.id }) == ids else { throw BackendSessionFailure.missingCapability("the source metadata for the contributed tool areas") }
                return try BackendDeckCoreCatalogueDescribe.wireListing(metadata: rows, caller: caller, granted: grant)
            }, authenticated: authenticatedExchange, beforeListing: beforeListing)
        let observer = await keys.onChange { Task { await notifications.reconcile() } }
        var configured = false
        do {
            try await features.recover(control: control)
            let remembered = await keys.port()
            let endpoint = try await server.start(port: port, preferredPort: port == nil ? (remembered ?? 0) : nil)
            let movedFrom = remembered != nil && remembered != endpoint.port ? remembered : nil
            do { try await keys.setPort(endpoint.port) } catch { report("[deck-control] could not remember the tools port: \(error.localizedDescription)") }
            let configs = try BackendDeckCoreConfiguration.write(endpoint: endpoint, copilotRoot: root, ownership: ownership)
            configured = true
            try await relay?.install(server)
            let bridge: String?
            do { bridge = try await channelBridge() } catch { bridge = nil; report("[deck-control] could not prepare the native Claude Code channel bridge: \(error.localizedDescription)") }
            let runtime = BackendDeckCoreRuntime(endpoint: endpoint, control: control, consent: consent, log: log, keys: keys, door: door,
                notifications: notifications, configs: configs, registry: registry, server: server, window: window, metadata: metadata,
                features: features, tours: tours, relay: relay, files: files, ownerID: ownerID, report: report)
            await runtime.setKeyObserver(observer)
            try await runtime.registerChannels()
            let apps = BackendDeckCoreEventsAIApps(keys: keys, hub: notifications.hub, events: notifications.events,
                port: { endpoint.port }, movedFrom: { movedFrom }, relay: { await relay?.facts() },
                folders: { surface.listProjects().compactMap { $0["path"].string } }, channelBridge: { bridge })
            let trust = await window.isApprover
            await runtime.setAiAppsObserver(try await apps.register(in: registry, ownerID: ownerID, isApprover: trust))
            handedOff = true
            return runtime
        } catch {
            try? await relay?.install(nil); await door.stop(); await notifications.stop(); await keys.removeObserver(observer)
            await features.stopTasks(); await consent.stop(); await tours?.stop(); await features.stopPlugins(); await server.stop()
            await registry.removeOwner(ownerID)
            if configured { try? files.remove(BackendDeckCoreConfiguration.attendedFile); try? files.remove(BackendDeckCoreConfiguration.unattendedFile) }
            throw error
        }
    }
    private func setKeyObserver(_ id: UUID) { keyObserver = id }
    private func setAiAppsObserver(_ observer: NativeRPCSubscription) { aiAppsObserver = observer }
    private func registerChannels() async throws {
        for channel in Self.channels {
            try await registry.register(channel, ownerID: ownerID) { context, args in try await self.invoke(channel, context: context, arguments: args) }
        }
    }
    public func status() async throws -> NativeRPCValue {
        guard !stopped else { throw BackendSessionFailure.closed }
        return try await BackendDeckCoreStatus.value(endpoint: endpoint, control: control, metadata: metadata.read(), consent: consent, log: log)
    }
    private func invoke(_ channel: String, context: NativeRPCContext, arguments: [NativeRPCValue]) async throws -> NativeRPCValue {
        func arg(_ index: Int) -> NativeRPCValue { arguments.indices.contains(index) ? arguments[index] : .missing }
        switch channel {
        case "deck-control:status": return try await status()
        case "deck-control:activity": return .array(await log.tail(min(max((arg(0).number ?? 200).rounded(.towardZero), 1), 2000)))
        case "deck-control:consent-attach": return try await window.attach(context: context, broker: consent)
        case "deck-control:consent-respond": return try await window.respond(context: context, broker: consent, id: arg(0), approved: arg(1))
        case "deck-control:tours":
            guard let tours else { throw BackendSessionFailure.missingCapability("the native tour stage") }
            return .array(try await tours.list(count: Int(min(max((arg(0).number ?? 10).rounded(.towardZero), 1), 50))))
        case "deck-control:tour-report":
            guard await window.accepts(context) else { throw NativeRPCError(code: "access-denied", message: "deck-control: this window may not report on a tour") }
            guard arg(0).fields != nil else { throw NativeRPCError.invalidArguments("deck-control: a tour report is required") }
            guard let tours else { throw BackendSessionFailure.missingCapability("the native tour stage") }
            let raw = arg(0), id = raw["tourId"].string ?? "", record = raw["record"].fields == nil ? .object([]) : raw["record"]
            let accepted: Bool
            switch raw["kind"].string {
            case "started": accepted = try await tours.acknowledge(id: id)
            case "progress": accepted = try await tours.progress(id: id, record: record)
            case "ended": accepted = try await tours.end(id: id, record: record)
            default: throw NativeRPCError.invalidArguments("deck-control: unknown tour report \(BackendDeckCoreCatalogueRules.jsString(raw["kind"]))")
            }
            return .object([.init("accepted", .bool(accepted))])
        default: throw NativeRPCError(code: "missing-handler", message: "No native deck-control handler is registered for \(channel)")
        }
    }
    public func windowGone(ownerID: String) async {
        if await window.gone(ownerID: ownerID, broker: consent) { await tours?.windowGone() }
    }
    public func noteStatus(sessionID: String, status: String) async { await notifications.detector.noteStatus(sessionId: sessionID, status: status); await features.noteStatus(sessionID: sessionID, status: status) }
    public func noteExit(sessionID: String, exitCode: Int) async { await notifications.detector.noteExit(sessionId: sessionID, exitCode: Double(exitCode)); await features.noteExit(sessionID: sessionID, exitCode: exitCode) }
    public func tasksWake() async { await features.tasksWake() }
    public func stop() async {
        guard !stopped else { return }; stopped = true
        do { try await relay?.install(nil) } catch { report("[deck-control] could not detach the relay: \(error.localizedDescription)") }
        await door.stop(); await sessionEndpoint.revokeAll(); await notifications.detector.stop()
        if let keyObserver { await keys.removeObserver(keyObserver); self.keyObserver = nil }
        await notifications.events.stop(); await notifications.hub.stop(); await features.stopTasks()
        await aiAppsObserver?.cancelAndWait(); aiAppsObserver = nil
        do { try await keys.flush() } catch { report("[deck-control] could not save access-key last use: \(error.localizedDescription)") }
        await consent.stop(); await tours?.stop(); await features.stopPlugins(); await server.stop()
        try? files.remove(BackendDeckCoreConfiguration.attendedFile); try? files.remove(BackendDeckCoreConfiguration.unattendedFile)
        await registry.removeOwner(ownerID); BackendDeckCoreRuntimeClaims.shared.release(registry)
    }
}
