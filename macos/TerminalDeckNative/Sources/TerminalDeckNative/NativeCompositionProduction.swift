import AppKit
import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// The packaged app's real graph, assembled before a transitional child starts.
/// Each retained area determines its own manifest; no catalogue name stands in
/// for an installed handler, and incomplete dependencies abort the transfer.
@MainActor
final class NativeCompositionProduction {
    let root: BackendCompositionRoot
    let state: BackendCompositionState
    let configuration: BackendAccountConfiguration
    let joins: BackendCompositionProductionBindings
    private(set) var core: BackendDeckCoreRuntime!
    private(set) var authority: BackendCompositionAuthority!
    private(set) var sessions: BackendCompositionSessions!
    private(set) var files: BackendCompositionFiles!
    private(set) var usage: BackendCompositionUsage!
    private(set) var clients: BackendCompositionClients!
    private(set) var clientAuthority: BackendCompositionClientsSecurityAuthority!
    private(set) var suppliers: BackendCompositionSuppliers!
    var taskRegistration: BackendTaskRegistration?
    var taskEngine: BackendTaskEngine?
    var taskView: BackendTaskStateView?
    var airReadiness: NativeCompositionINT2AIR?
    var agentSettings: NativeCompositionINT2AGS?
    var routinesOwner: BackendRoutinesService?
    var remoteRegistration: BackendRemoteServeRegistration.Installed?
    var remoteHost: BackendRemoteHostService?
    var remoteEndpoint: BackendRemoteHost?
    var remoteTrust: BackendRemoteTrustStore?
    var windowGrants: BackendRemoteServeWindowGrants?
    var machineOwner: BackendMachineRegistration.Installed?
    var machineStore: BackendMachineStore?
    var machineCoordinator: BackendMachineCoordinator?
    var serversOwner: BackendServersFeature?
    var serverControl: NativeServerControlRuntime?
    var leaseFacade: BackendDeckToolsSessionsLeaseFacade?
    var hoot: BackendHootJoinAssembly.Assembled?
    var osServices: NativeCompositionOS.Services?
    var browserAccess: NativeCompositionBrowserAuthority?
    var coreSurface: BackendDeckCoreLiveSurface?
    var restoreContext: BackendSessionRestoreContext?
    let tourWindow = NativeCompositionLateTourWindow()
    var tourStage: BackendDeckToolsTourStage?
    var machineDefinitions: [BackendDeckToolsDefinition] = []
    var machinePending: NativeCompositionMachinesPending?
    var staysFixedProvisioning: (any BackendStaysFixedProvisioning)?
    var devices: BackendCompositionDevices.Installed?
    var restoreStarted = false
    var machineWindowAsks: BackendRemoteServeWindowAsks?
    let relay = BackendCompositionRelaySwitchboard()
    let linkRequests = BackendCompositionLinkRequests()
    let linkTabWindow = NativeCompositionLinkTabWindow()
    var notifications: BackendOSNativeNotifier?
    var phoneHoot: BackendINT2HootPhone?
    /// open-shim.ts: written at start (installOpenShim), read by the hook context.
    let openShim = BackendMacAppHandoffOpenShim(files: BackendMacAppHandoffShimDisk())
    /// app-context.ts: the app map a session is told about at SessionStart/BeforeAgent.
    let appContext = BackendMacAppSetupContext(io: BackendMacAppSetupLocalContextIO(), noVerbsReasons: { BackendAppSessionVerbsRegistry.reasons })
    /// session-verbs.ts: why a session has no browser verbs ("cannot drive").
    let verbs = BackendAppSessionVerbsRegistry()
    var reachLedger: BackendCompositionBrowserReachLedger?
    let engineConfiguration: EngineConfiguration
    let window: @MainActor @Sendable () -> NSWindow?
    let report: @Sendable (String) -> Void
    init(root: BackendCompositionRoot, state: BackendCompositionState, engineConfiguration: EngineConfiguration,
         window: @escaping @MainActor @Sendable () -> NSWindow?, report: @escaping @Sendable (String) -> Void) throws {
        self.root = root; self.state = state; self.engineConfiguration = engineConfiguration
        self.window = window; self.report = report
        configuration = try BackendCompositionSuppliers.configuration(dataRoot: root.dataRoot,
            home: URL(fileURLWithPath: NSHomeDirectory()), environment: ProcessInfo.processInfo.environment,
            helper: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/TerminalDeckNativeHelper"))
        joins = BackendCompositionProductionBindings(root: root, state: state, configuration: configuration)
    }
    func assemble() async throws {
        let surface = try BackendDeckCoreLiveSurface(manager: root.preparedSessions.manager, state: state,
            evidence: BackendDeckCoreNativeEvidence(scopeForProject: { [joins] in try await joins.transcriptScope(project: $0) },
                scopeForPath: { [joins] _ in try await joins.transcriptScope() }), projectEvidence: joins,
            ownership: root.state.ownership,
            startSession: { [joins] in try await joins.startSession($0) },
            writeToSession: { [joins] in try await joins.writeSession($0, $1) },
            closeSession: { [joins] in try await joins.closeSession($0) },
            // The accepted status record (hook/screen), as TS liveStatus.get(id); not the session row.
            sessionStatus: { [joins] id in (try? joins.authority())?.statusRecord(id) ?? .null }, windows: { [joins] in joins.browserWindows(sessionID: $0) })
        coreSurface = surface
        // One tour stage for the tour tool and the core's tour channels (deck-tools handoff "Tours").
        let stage = BackendDeckToolsTourStage(logDirectory: RNMHootPaths(dataRoot: root.dataRoot).log,
            window: tourWindow, writeFailure: { [report] in report("tour record: " + $0) })
        tourStage = stage
        let consent = BackendDeckCoreWindowConsent(isApprover: { context in
            context.caller == .nativeApp && context.ownerID == BackendCompositionRoot.appOwnerID
        }, send: { [root] owner, channel, value in
            try await root.registry.publish(channel, arguments: [value], ownerID: owner); return true
        }, broadcast: { [root] channel, value in
            try await root.registry.publish(channel, arguments: [value], ownerID: BackendCompositionRoot.appOwnerID)
        }, relay: NativeCompositionINT2PhoneConsent(self))
        core = try await root.installDeckCore(providers: .init(surface: surface, window: consent,
            whereDependencies: .init(window: NativeCompositionWhere(root: root), page: { nil }),
            mcp: joins, features: joins, tours: BackendDeckToolsTourCoreAdapter(stage: stage), relay: relay, taskHTTP: joins, livePolicies: { [joins] in joins.livePolicies() },
            liveMetadata: { [joins] in joins.liveMetadata() }, mcpPolicies: joins.mcpPolicies(),
            channelBridge: { [configuration] in configuration.helperExecutable.path + " --notify-channel" },
            authenticatedExchange: { [joins] grant, scope, operation in
                try await joins.authenticated(grant: grant, cancellation: scope, operation: operation)
            }, beforeListing: { [joins] in try await joins.beforeListing() }),
            options: .init(ownership: root.state.ownership, report: report), oldCoreOwnerDisabled: true)
        joins.bind(core: core)
        authority = try BackendCompositionAuthority(prepared: root.preparedSessions, state: state,
            configuration: configuration, coreContexts: joins.contexts, gate: core.control.compositionGate(), hidden: joins.hidden,
            remote: joins.remoteAuthority())
        try joins.bind(authority: authority)
        let ui = BackendCompositionSuppliersUI(state: state, home: configuration.homeDirectory.path,
            showProject: { path in await MainActor.run { AppModel.shared.select(path); return true } },
            // index.ts onOpen: the shim's link goes where the session's other links go
            // (openForSession); a `system` answer makes the shim open it itself.
            hookOpenLink: { [weak self] url, session in
                guard let self else { throw NativeRPCError(code: "unavailable", message: "The app is shutting down.") }
                return await self.openForSession(url: url.absoluteString, sessionID: session)
            })
        suppliers = try BackendCompositionSuppliers(authority: authority, providers: root.providers, registry: root.registry,
            downloads: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0], ui: ui)
        let restore = BackendSessionRestoreContext(readiness: .ready) { [joins] device, folder in
            try await joins.deviceBoundary(deviceID: device, folder: folder)
        }
        let projectSource = try BackendStaysFixedProjectSource(userData: root.dataRoot,
            home: configuration.homeDirectory.path, readiness: .ready) { [joins] cwd, provider, path in
                let clients = try joins.clients()
                guard let fixed = clients.staysFixed, let definition = try await fixed.projectSource().resolve(cwd: cwd, provider: provider, loginPath: path) else {
                    throw BackendSessionFailure.missingCapability("the set-up project's Stays Fixed engine")
                }
                return definition
            }
        let reach = BackendBrowserToolReachAdapter(readiness: .ready,
            reachesDeviceWindows: { [joins] in await joins.reachesDeviceWindows($0) },
            hostHoldsWindows: { [joins] in await joins.hostHoldsWindows() })
        sessions = try await root.installSessions(endpoint: core.sessionEndpoint,
            dependencies: suppliers.sessionDependencies(projectMCPSource: projectSource, browserReach: reach,
                cleanup: .init(readiness: .ready, release: { [joins] in try await joins.releaseSession($0) }),
                restoreContext: restore, excludedAppWorkingDirectories: [Bundle.main.bundleURL.path],
                emit: { [weak self] event in
                    guard SourceNamespace.agentSettingsEnabled else { return }
                    Task { await self?.agentSettings?.events.session(event) }
                }, renamed: { [root] id, title in
                    try? await root.registry.publish("session:renamed", arguments: [.string(id), .string(title)], ownerID: BackendCompositionRoot.appOwnerID)
                }, hookAdditionalContext: { [joins] in try await joins.hookContext($0) }), oldSessionOwnerDisabled: true)
        try authority.bind(sessions); try joins.bind(sessions: sessions)
        restoreContext = restore
        tourWindow.bind(NativeCompositionDeckToolsTourWindow(registry: root.registry, authority: authority, window: window))
        // deck-tools own these tool ids in the one core catalogue; the domain owners keep their channels.
        let deckToolIDs = try BackendCompositionCoreContributions.deckToolsSourceIDs()
        // TS artifact-preview.ts announce default: force the port scan the tunnel gates a dial on.
        files = try await root.installFiles(dependencies: suppliers.filesDependencies(restoreContext: restore,
            guestGitPlan: joins.guestGitPlanner(), announcePreviewPort: { [weak self] _ in
                guard let ports = await MainActor.run(body: { self?.files?.ports }) else { return }
                _ = try? await ports.scan(force: true)
            }), excludingToolIDs: deckToolIDs)
        usage = try await root.installUsage(accounts: sessions.accounts, lifecycle: sessions.lifecycle,
            dependencies: suppliers.usageDependencies(), excludingToolIDs: deckToolIDs)
        joins.bind(files: files, usage: usage)
        try await installAIRReadiness()
        var deps = NativeCompositionClients.runtimeDependencies(dataRoot: root.dataRoot, configuration: engineConfiguration,
            window: window, report: report)
        deps.outputValidator = BackendMcpClientJSONSchemaValidator()
        deps.memoryToolsOwnedElsewhere = true
        // deck-control services.notify: "<plugin>: <title>" as a Mac banner.
        deps.pluginNotify = { plugin, title, body in
            await NativeCompositionBanners.shared.post(title: plugin + ": " + title, body: body).delivered
        }
        staysFixedProvisioning = deps.staysFixedProvisioning
        deps.storeConfiguration = .init(packaged: true, commandRunner: BackendCommandRunner(),
            configuredBase: { [root] in await root.settings.value("store.baseUrl").string })
        deps.memoryEnvironment = NativeCompositionClients.memoryEnvironment(profiles: sessions.profiles, userData: root.dataRoot,
            hootMemory: { [state] in URL(fileURLWithPath: state.copilotRoot()).appendingPathComponent("memory").path },
            hootActionLogger: { [core] in BackendMemoryActionLogger { action, detail in
                await core?.log.append(.object([.init("at", .string(ISO8601DateFormatter().string(from: Date()))),
                    .init("action", .string(action)), .init("detail", .string(detail))]))
            } })
        clientAuthority = BackendCompositionClientsSecurityAuthority(contexts: joins.contexts,
            manager: sessions.manager, profiles: sessions.profiles, surface: surface)
        let catalogue = BackendCompositionClientsDeckCatalogue(baseMetadata: { [joins] in joins.liveMetadata() },
            updateCallerGrants: { [clientAuthority] in try clientAuthority!.replaceLazyMetadata($0) }, report: report)
        deps = clientAuthority.configure(deps, catalogue: catalogue)
        clients = try await root.installClients(transferredDomains: BackendCompositionClients.allDomains, dependencies: deps)
        let mcp = try clients.mcpProvider(surface: surface, filesystem: clientAuthority.filesystemAuthority(), authority: clientAuthority)
        try joins.bind(clients: clients, authority: clientAuthority, mcp: mcp)
        try joins.replaceContributions(owner: "clients", clientAuthority.bundles(graph: clients, includeMemory: false))
        try await installStateAndDesktopChannels()
        try await installNotifications()
        try await installBrowser()
        linkTabWindow.start()
        try await installTasksAndRoutines()
        try await installRemoteMachinesAndServers()
        hoot = try await NativeCompositionRoot.shared.installHoot(in: root, inputs: .init(
            storageRoot: root.dataRoot.appendingPathComponent("remote"), sessions: sessions, deckCore: core,
            confinement: await sessions.macConfinement, machineID: "", pickFolder: { try await NativeCompositionFolderPicker.pick($0) },
            transcriptScope: { [joins] in try await joins.accountTranscriptScope() }, reveal: NativeCompositionReveal(),
            window: { [authority] in try authority!.requireLocalUI($0) }, stopPhoneRuns: { [weak self] in
                await (await MainActor.run { self?.phoneHoot })?.stop()
            },
            headlessPolicy: { [sessions] input, provider, context in
                try await sessions!.launcher.headlessPolicy(input, provider: provider, context: context)
            }, headlessProvider: try await BackendHootProviderChoice(settings: root.settings).selected(),
            readAcknowledged: { folder in
                try await NativeCompositionRoot.shared.confirmHootRead([folder])
            }), oldHootOwnerDisabled: true)
        try await installINT2PhoneHoot()
        // deck-tools needs Hoot's administrative service (copilot-admin tools) and every owner above.
        try await installDeckToolsAndOS()
        try await installServerControl()
        await installOpenShim()
        try await startAreas()
    }
}

private struct NativeCompositionWhere: BackendDeckCoreCatalogueWhereWindow {
    let root: BackendCompositionRoot
    func read() async throws -> NativeRPCValue { try await Self.readOnMain() }
    @MainActor private static func readOnMain() async throws -> NativeRPCValue {
        // Hoot driving the app is native (NativeScreens "drive"): the page mounts no DriveHost and
        // publishes no `__terminaldeckWhere`, so the native drive host answers what is on screen.
        if NativeScreens.registered.contains("drive") {
            guard AppModel.shared.sidebar != nil, NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return .null }
            return try NativeRPCValue.fromFoundation(DriveHost.shared.whereView())
        }
        let value = try await AppModel.shared.web.webView.callAsyncJavaScript(
            BackendDeckCoreCatalogueWhere.sourceWindowCall, arguments: [:], in: nil, contentWorld: .defaultClient)
        return try NativeRPCValue.fromFoundation(value)
    }
}
