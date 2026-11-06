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
    private(set) var core: BackendDeckCoreRuntime?
    var tagConsentOwnerActivity: NativeCompositionINT2TAGOwnerActivity?
    var hostCore: NativeCompositionINT2HOSTCore?
    #if TD_HOST_ACCOUNT_BRIDGE && TD_HOST_INTEGRATED
    var hostManaged: NativeCompositionINT2HOSTManaged?
    #endif
    private(set) var authority: BackendCompositionAuthority?
    private(set) var sessions: BackendCompositionSessions?
    private(set) var files: BackendCompositionFiles?
    var chatDiffActions: BackendChatDiffActions?
    var chatDiffOwners: [String: Set<String>] = [:]
    var chatDiffOwnerOrder: [String] = []
    var chatChildOpenings: [String: Task<NativeRPCValue, Error>] = [:]
    private(set) var usage: BackendCompositionUsage?
    private(set) var clients: BackendCompositionClients?
    private(set) var clientAuthority: BackendCompositionClientsSecurityAuthority?
    private(set) var suppliers: BackendCompositionSuppliers?
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
    /// One saved-server store shared by access.request_scope and Docker approval (DKA2).
    let serverStoreReference = BackendDockerMCPServerStoreReference()
    var leaseFacade: BackendDeckToolsSessionsLeaseFacade?
    var hoot: BackendHootJoinAssembly.Assembled?
    var osServices: NativeCompositionOS.Services?
    var browserAccess: NativeCompositionBrowserAuthority?
    var coreSurface: BackendDeckCoreLiveSurface?
    var restoreContext: BackendSessionRestoreContext?
    /// Chat sessions' AIs (NativeCompositionSessionChats).
    var sessionChats: BackendSessionChats?
    let tourWindow = NativeCompositionLateTourWindow()
    var tourStage: BackendDeckToolsTourStage?
    var machineDefinitions: [BackendDeckToolsDefinition] = []
    var machinePending: NativeCompositionMachinesPending?
    var staysFixedProvisioning: (any BackendStaysFixedProvisioning)?
    var sessionSimulator: NativeCompositionINT2SessionSimulator?
    var devices: BackendCompositionDevices.Installed?
    var restoreStarted = false
    var finishedJobsSwept = false
    var machineWindowAsks: BackendRemoteServeWindowAsks?
    let relay = BackendCompositionRelaySwitchboard()
    let linkRequests = BackendCompositionLinkRequests()
    let linkTabWindow = NativeCompositionLinkTabWindow()
    var notifications: BackendOSNativeNotifier?
    var phoneHoot: BackendINT2HootPhone?
    /// Agent chats on a paired phone (`chats`, NativeCompositionINT2PhoneChats).
    var phoneChats: BackendPhoneChats?
    var chatMCPApps: BackendChatMCPApps?
    /// 31 Oct: alerts for phones whose app is closed (NativeCompositionPhonePush).
    var phonePush: BackendPhonePush?
    var phonePushWatcher: NativePhonePushWatcher?
    /// 31 Oct: the Mac's load for the phone's Activity page and the system.activity tool (NativeCompositionPhoneActivity).
    var systemActivity: BackendSystemActivity?
    var phoneActivity: BackendPhoneActivity?
    var widgets: BackendWidgets?
    var widgetWatcher: NativeWidgetWatcher?
    /// Post-24 (phone-terminal item 1): what every widget snapshot of one refresh shares, read once, not per phone.
    var widgetInputs: NativeWidgetInputs?
    /// Item 74: the phones' context push (sessions and Hoot), made with the remote serve.
    var contextPush: BackendRemoteServeUsagePush?
    /// CPU and memory for widgets, sampled at most every 15 s (the shared sampler measures since its last call).
    var widgetActivity: (at: Date, value: NativeRPCValue)?
    /// The phone's pictures (28 Oct): held here, or the endpoint's weakly held adapter is freed at once.
    var phonePictures: BackendPhonePictures.Installation?
    /// The phone's Devices page (31 Oct): held here for the same reason as the pictures.
    var phoneDevices: BackendPhoneDevices.Installation?
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
    let showProject: @Sendable (String) async throws -> Bool
    let whereWindow: @Sendable () async throws -> NativeRPCValue
    init(root: BackendCompositionRoot, state: BackendCompositionState, engineConfiguration: EngineConfiguration,
         window: @escaping @MainActor @Sendable () -> NSWindow?,
         showProject: @escaping @Sendable (String) async throws -> Bool,
         whereWindow: @escaping @Sendable () async throws -> NativeRPCValue, report: @escaping @Sendable (String) -> Void) throws {
        self.root = root; self.state = state; self.engineConfiguration = engineConfiguration
        self.window = window; self.report = report
        self.showProject = showProject; self.whereWindow = whereWindow
        // The person's own projects are the live project list from the first moment, before sessions,
        // memory or tasks file anything (read only; the registry loads the same file again later).
        BackendPROJRegistry.publishSaved(fileURL: root.dataRoot.appendingPathComponent("projects.registry.json"))
        configuration = try BackendCompositionSuppliers.configuration(dataRoot: root.dataRoot,
            home: URL(fileURLWithPath: NSHomeDirectory()), environment: ProcessInfo.processInfo.environment,
            helper: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/TerminalDeckNativeHelper"))
        joins = BackendCompositionProductionBindings(root: root, state: state, configuration: configuration)
    }
    /// 18 Oct (#151): the session tools find a Codex or Gemini session's own conversation record with the task
    /// engine's strict locator (Claude keeps its own transcript matcher). Nil until sessions are installed.
    func agentRecordLocator() -> BackendDeckCoreAgentRecords.Locate? {
        guard let sessions, let authority else { return nil }
        let locate = BackendTaskAgentTranscripts.locator(claude: { _, _ in nil }, metadata: { await sessions.lifecycle.metadata(transcripts: false) },
            systemDirectory: { sessions.profiles.configuration.systemDirectory($0) }, ownerContext: { try authority.localContext() },
            transcriptConfiguration: { await sessions.lifecycle.transcriptConfiguration(sessionID: $0) })
        return { id in
            guard let meta = sessions.manager.list().first(where: { $0.id == id }) else { return nil }
            return try await locate(meta)
        }
    }
    func assemble() async throws {
        try await installMemoryEvents()
        let surface = try BackendDeckCoreLiveSurface(manager: root.preparedSessions.manager, state: state,
            evidence: BackendDeckCoreNativeEvidence(scopeForProject: { [joins] in try await joins.transcriptScope(project: $0) },
                scopeForPath: { [joins] _ in try await joins.transcriptScope() }), projectEvidence: joins,
            ownership: root.state.ownership,
            // sessions.start (Hoot, sessions and AI apps): the new session opens as a quiet tab (#160).
            startSession: { [joins] input in
                let started = try await joins.startSession(input)
                await NativeButtonActions.openQuietly(started)
                return started
            },
            writeToSession: { [joins] in try await joins.writeSession($0, $1) },
            closeSession: { [joins] in try await joins.closeSession($0) },
            // The accepted status record (hook/screen), as TS liveStatus.get(id); not the session row.
            sessionStatus: { [joins] id in (try? joins.authority())?.statusRecord(id) ?? .null }, windows: { [joins] in joins.browserWindows(sessionID: $0) },
            accountsForSessionStart: { [weak self] in
                guard let sessions = await self?.sessions else { throw BackendSessionFailure.closed }
                // Read through the account owner with this request's original scope.
                let profiles = try await sessions.profiles.list(provider: nil)
                return try profiles.map { try NativeRPCValue.parseJSON(JSONEncoder().encode($0)) }
            },
            sessionStartContext: { [joins] context, operation in try await joins.withSessionStartContext(context, operation: operation) },
            // Sessions are installed after this surface; the locator is built when a tool first asks.
            agentRecords: { [weak self] id in
                guard let locate = await self?.agentRecordLocator() else { return nil }
                return try await locate(id)
            }, sendChat: { [weak self] id, text in
                guard let chats = await self?.sessionChats else { throw BackendSessionFailure.closed }
                _ = try await chats.say(id, text: text, clientMessageID: UUID().uuidString.lowercased())
            })
        coreSurface = surface
        // One tour stage for the tour tool and the core's tour channels (deck-tools handoff "Tours").
        let stage = BackendDeckToolsTourStage(logDirectory: RNMHootPaths(dataRoot: root.dataRoot).log,
            window: tourWindow, writeFailure: { [report] in report("tour record: " + $0) })
        tourStage = stage
        let ownerActivity = NativeCompositionINT2TAGOwnerActivity()
        tagConsentOwnerActivity = ownerActivity
        let consent = BackendDeckCoreWindowConsent(isApprover: { context in
            context.caller == .nativeApp && context.ownerID == BackendCompositionRoot.appOwnerID
        }, send: { [root] owner, channel, value in
            try await root.registry.publish(channel, arguments: [value], ownerID: owner); return true
        }, broadcast: { [root] channel, value in
            try await root.registry.publish(channel, arguments: [value], ownerID: BackendCompositionRoot.appOwnerID)
        }, relay: NativeCompositionINT2PhoneConsent(self), ownerIsActive: {
            await MainActor.run { ownerActivity.isPresent }
        })
        core = try await root.installDeckCore(providers: .init(surface: surface, window: consent,
            whereDependencies: .init(window: NativeCompositionWhere(readWindow: whereWindow), page: { nil }),
            mcp: joins, features: joins, tours: BackendDeckToolsTourCoreAdapter(stage: stage), relay: relay, taskHTTP: joins, livePolicies: { [joins] in joins.livePolicies() },
            liveMetadata: { [joins] in joins.liveMetadata() }, mcpPolicies: joins.mcpPolicies(),
            channelBridge: { [configuration] in configuration.helperExecutable.path + " --notify-channel" },
            authenticatedExchange: { [joins] grant, scope, operation in
                try await joins.authenticated(grant: grant, cancellation: scope, operation: operation)
            }, beforeListing: { [joins] in try await joins.beforeListing() }),
            options: .init(ownership: root.state.ownership, report: report))
        guard let core else { throw unwired("core") }
        await core.log.onFailureChanged { failed in
            _ = await NativeCompositionBanners.shared.post(title: "AI activity record", body: failed
                ? "The AI activity record could not be saved. Logging will retry on the next action. Check free disk space and folder access."
                : "The AI activity record is saving again.")
        }
        await core.control.holdSessionToolsUntilRestrictionsReady()
        joins.bind(core: core)
        ownerActivity.start(window: consent, broker: core.consent)
        authority = try BackendCompositionAuthority(prepared: root.preparedSessions, state: state,
            configuration: configuration, coreContexts: joins.contexts, gate: core.control.compositionGate(), hidden: joins.hidden,
            remote: joins.remoteAuthority())
        guard let authority else { throw unwired("authority") }
        try joins.bind(authority: authority)
        let remaining: @MainActor @Sendable () async throws -> Void = { [self] in
        let ui = BackendCompositionSuppliersUI(state: state, home: configuration.homeDirectory.path,
            showProject: showProject,
            // index.ts onOpen: the shim's link goes where the session's other links go
            // (openForSession); a `system` answer makes the shim open it itself.
            hookOpenLink: { [weak self] url, session in
                guard let self else { throw NativeRPCError(code: "unavailable", message: "The app is shutting down.") }
                return await self.openForSession(url: url.absoluteString, sessionID: session)
            })
        suppliers = try BackendCompositionSuppliers(authority: authority, providers: root.providers, registry: root.registry,
            downloads: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0], ui: ui)
        guard let suppliers else { throw unwired("suppliers") }
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
        let sessionDependencies = try suppliers.sessionDependencies(projectMCPSource: projectSource, browserReach: reach,
                cleanup: .init(readiness: .ready, release: { [joins] in try await joins.releaseSession($0) }),
                restoreContext: restore, excludedAppWorkingDirectories: [Bundle.main.bundleURL.path],
                emit: { [weak self, joins] event in
                    Task {
                        await joins.sessionStartedHere(event) // 28 Oct (bug C): the phones' lists, at once
                        await self?.sessionSimulator?.noteLifecycle(event)
                        if SourceNamespace.agentSettingsEnabled { await self?.agentSettings?.events.session(event) }
                    }
                }, renamed: { [root, joins] id, title in
                    // Every listener, the island's own owner too (not only the app's), and the paired phones' lists (Asad, 12 Oct).
                    try? await root.registry.publish("session:renamed", arguments: [.string(id), .string(title)])
                    await joins.sessionsRenamed()
                }, hookAdditionalContext: { [joins] in try await joins.hookContext($0) })
        #if TD_HOST_ACCOUNT_BRIDGE && TD_HOST_INTEGRATED
        let managed = NativeCompositionINT2HOSTManaged(owner: self)
        hostManaged = managed
        do { sessions = try await managed.prepare(dependencies: sessionDependencies, projectSource: projectSource) }
        catch {
            guard try await managed.abandonForLocalFallback() else { throw error }
            hostManaged = nil
            NativeCompositionINT2HOSTManaged.current = nil
            report("Sessions will run in-app because the persistent helper could not start: " + error.localizedDescription)
            sessions = try await root.installSessions(endpoint: core.sessionEndpoint,
                dependencies: sessionDependencies)
        }
        #else
        sessions = try await root.installSessions(endpoint: core.sessionEndpoint,
            dependencies: sessionDependencies)
        #endif
        guard let sessions else { throw unwired("sessions") }
        try authority.bind(sessions); try joins.bind(sessions: sessions)
        try await installSessionChats()     // before any restore: a chat session comes back as a chat
        await installDeckMemoryStore()      // M1 CORE · Deck Memory: the store itself, before anything asks for it
        await installDeckMemorySessions()   // L8 HOST · Deck Memory: before any session (restored ones too) is started
#if TD_HOST_INTEGRATED
        let hostOwner = NativeCompositionINT2HOSTCore(sessions: sessions, dataRoot: root.dataRoot, home: configuration.homeDirectory)
        hostCore = hostOwner
        #if TD_HOST_ACCOUNT_BRIDGE
        if let hostManaged {
            try await hostManaged.bindAndAdopt()
            await hostOwner.usePreconnected(client: hostManaged.coreClient, bridge: hostManaged.coreBridge)
        } else { await hostOwner.start() }
        #else
        await hostOwner.start()
        #endif
#endif
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
        guard let files else { throw unwired("files") }
        #if TD_HOST_ACCOUNT_BRIDGE && TD_HOST_INTEGRATED
        usage = try await installHOSTUsage(excludingToolIDs: deckToolIDs)
        #else
        usage = try await root.installUsage(accounts: sessions.accounts, lifecycle: sessions.lifecycle,
            dependencies: suppliers.usageDependencies(), excludingToolIDs: deckToolIDs)
        #endif
        guard let usage else { throw unwired("usage") }
        joins.bind(files: files, usage: usage)
        try await installAIRReadiness()
        var deps = NativeCompositionClients.runtimeDependencies(dataRoot: root.dataRoot, configuration: engineConfiguration,
            window: window, report: report)
        deps.pluginsConsent = BackendPluginsBrokerConsent(broker: core.consent)
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
                await core.log.append(.object([.init("at", .string(ISO8601DateFormatter().string(from: Date()))),
                    .init("action", .string(action)), .init("detail", .string(detail))]))
            } })
        clientAuthority = BackendCompositionClientsSecurityAuthority(contexts: joins.contexts,
            manager: sessions.manager, profiles: sessions.profiles, surface: surface, pluginControl: core.control)
        guard let clientAuthority else { throw unwired("clientAuthority") }
        let catalogue = BackendCompositionClientsDeckCatalogue(baseMetadata: { [joins] in joins.liveMetadata() },
            updateCallerGrants: { [clientAuthority] in try clientAuthority.replaceLazyMetadata($0) }, report: report)
        deps.pluginOwnerDispatch = { [clientAuthority, core] context, tool, args in
            try await clientAuthority.dispatchNativePlugin(context: context, control: core.control, tool: tool, arguments: args)
        }
        deps = clientAuthority.configure(deps, catalogue: catalogue)
        clients = try await root.installClients(transferredDomains: BackendCompositionClients.allDomains, dependencies: deps)
        guard let clients else { throw unwired("clients") }
        let mcp = try clients.mcpProvider(surface: surface, filesystem: clientAuthority.filesystemAuthority(), authority: clientAuthority)
        try joins.bind(clients: clients, authority: clientAuthority, mcp: mcp)
        try joins.replaceContributions(owner: "clients", clientAuthority.bundles(graph: clients, includeMemory: false))
        try await installStateAndDesktopChannels()
        try await installNotifications()
        try await installBrowser()
        linkTabWindow.start()
        try await installTasksAndRoutines()
        try await installRemoteMachinesAndServers()
        let readyHoot = BackendHootReadyDefaults(settings: root.settings, sessions: sessions, providers: root.providers)
        #if TD_HOST_ACCOUNT_BRIDGE
        // This call is explicit APP STARTUP, not a keyed handler fallback.
        let readySelection = try await BackendHOSTProfileScope.withContext(authority.localContext()) {
            try await readyHoot.read(projectPath: RNMHootPaths(dataRoot: root.dataRoot).home.path)
        }
        #else
        let readySelection = try await readyHoot.read(projectPath: RNMHootPaths(dataRoot: root.dataRoot).home.path)
        #endif
        hoot = try await NativeCompositionRoot.shared.installHoot(in: root, inputs: .init(
            storageRoot: root.dataRoot.appendingPathComponent("remote"), sessions: sessions, deckCore: core,
            confinement: await sessions.macConfinement, machineID: "", pickFolder: { try await NativeCompositionFolderPicker.pick($0) },
            transcriptScope: { [joins] in try await joins.accountTranscriptScope() }, reveal: NativeCompositionReveal(),
            window: { [authority] in try authority.requireLocalUI($0) }, stopPhoneRuns: { [weak self] in
                await (await MainActor.run { self?.phoneHoot })?.stop()
            },
            headlessPolicy: { [sessions] input, provider, context in
                try await sessions.launcher.headlessPolicy(input, provider: provider, context: context)
            }, headlessProvider: readySelection.provider,
            readAcknowledged: { folder in
                try await NativeCompositionRoot.shared.confirmHootRead([folder])
            }, readyDefaults: readyHoot,
            // HOOTFIX: Hoot's own launch reads (phone/task/idle paths without a
            // request scope) use the actual app owner, as startup does above.
            ownerContext: { [authority] in try authority.localContext() }))
        // Item 74: Hoot's plan limits come from the same account pool as every session's (and Hoot's Limits tab).
        await hoot?.usage.bindPlans { [usage] in try await usage.usage.read(sessionID: nil) }
        await hoot?.usage.bindCheck { [usage] account in try await usage.usage.refreshAccount(account).detail }
        // Item 74 relay half: Hoot's figure moving pushes it to the phones following `hoot` / `hoot:task:<id>`.
        if let contextPush { await hoot?.usage.setChangeHandler { id in await contextPush.transcriptChanged(id) } }
        try await installChatMCPApps()
        try await installINT2PhoneHoot()
        try await installINT2PhoneChats()
        await installPhonePictures()   // the Mac's project logos and agent pictures on the phone (28 Oct); never fatal
        await installPhonePush()   // alerts for phones whose app is closed (31 Oct); never fatal
        await installWidgets()
        await installPhoneActivity()   // the phone's Activity page: CPU, memory and what uses them (31 Oct); never fatal
        await installDeckMemoryFlow()   // M2 FLOW · Deck Memory: diary, board, note helper, tidy-up (needs sessions, tasks and Hoot)
        // deck-tools needs Hoot's administrative service (copilot-admin tools) and every owner above.
        try await installDeckToolsAndOS()
        try await installServerControl()
        await installOpenShim()
        await installPhoneDevices()   // the Mac's simulators and emulators on the phone (31 Oct; needs the device engine); never fatal
        #if TD_HOST_ACCOUNT_BRIDGE && TD_HOST_INTEGRATED
        try await hostManaged?.refreshActualCatalogue()
        #endif
        try await startAreas()
        }
        #if TD_HOST_ACCOUNT_BRIDGE
        try await BackendHOSTProfileScope.withContext(authority.localContext(), operation: remaining)
        #else
        try await remaining()
        #endif
    }
}

extension NativeCompositionProduction {
    /// A wiring member read before assemble() set it (a wiring-order mistake): one report line names
    /// the member and its caller, and only that one operation fails, instead of the app trapping at launch.
    func wired<Member>(_ value: Member?, _ member: String, caller: String = #function, file: String = #fileID, line: Int = #line) throws -> Member {
        try Self.wired(value, member, report: report, caller: caller, file: file, line: line)
    }
    /// The same report for a caller that returns early: `guard let x else { unwired("x"); return }`.
    @discardableResult
    func unwired(_ member: String, caller: String = #function, file: String = #fileID, line: Int = #line) -> NativeRPCError {
        Self.unwired(member, report: report, caller: caller, file: file, line: line)
    }
    nonisolated static func wired<Member>(_ value: Member?, _ member: String, report: (String) -> Void,
                                          caller: String = #function, file: String = #fileID, line: Int = #line) throws -> Member {
        guard let value else { throw unwired(member, report: report, caller: caller, file: file, line: line) }
        return value
    }
    nonisolated static func unwired(_ member: String, report: (String) -> Void, caller: String, file: String, line: Int) -> NativeRPCError {
        report("composition: \(member) is not wired yet; \(caller) (\(file):\(line)) stopped instead of crashing the app")
        return NativeRPCError(code: "composition-incomplete", message: "The app's \(member) is not ready yet.")
    }
}

struct NativeCompositionWhere: BackendDeckCoreCatalogueWhereWindow {
    let readWindow: @Sendable () async throws -> NativeRPCValue
    func read() async throws -> NativeRPCValue { try await readWindow() }
}
