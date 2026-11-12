import Foundation
import TerminalDeckNativeCore

/// The one native session/account graph. `activate` is deliberately separate
/// from the app root's inert construction: it acquires account writer leases,
/// starts authenticated local sockets, and activates the existing Store ledger.
/// The root calls it once, as this domain's only owner.
public actor BackendCompositionSessions {
    public private(set) var chatHost: BackendHOSTClient?
    public func setChatHost(_ client: BackendHOSTClient) { chatHost = client }

    /// One inert real manager for core's early synchronous session projection.
    /// Activation binds this exact manager; it never substitutes an empty list.
    public final class Prepared: @unchecked Sendable {
        public let manager: BackendPTYManager
        public let environment: [String: String]
        fileprivate let events: BackendCompositionSessionsEventPump
        private let lock = NSLock()
        private var claimed = false
        public init(environment: [String: String]) {
            self.environment = environment
            let events = BackendCompositionSessionsEventPump(); self.events = events
            manager = BackendPTYManager(inheritedEnvironment: environment) { events.submit($0) }
        }
        fileprivate func claim(environment: [String: String]) throws {
            try lock.withLock {
                guard !claimed, self.environment == environment else { throw BackendSessionFailure.invalidInput("The prepared PTY owner is already bound or has a different launch environment.") }
                claimed = true
            }
        }
    }
    public typealias Authorization = @Sendable (NativeRPCContext, String, [NativeRPCValue]) async throws -> Void
    public struct Dependencies: Sendable {
        public let accounts: BackendAccountConfiguration
        public let cipher: BackendAccountKeychainCipher
        public let confinement: any BackendConfinementLaunchResolver
        public let instructions: any BackendInstructionLaunchResolver
        public let projectMCPSource: any BackendProjectMCPSource
        public let browserReach: any BackendBrowserToolReach
        public let cleanup: BackendSessionLifecycleCleanup
        public let restoreContext: BackendSessionRestoreContext
        public let excludedAppWorkingDirectories: [String]
        public let authorizeRPC: Authorization
        public let authorizeAccountMetadata: @Sendable (NativeRPCContext) throws -> Void
        public let authorizeMutation: @Sendable (NativeRPCContext) throws -> Void
        /// Caller/device/app launch context is derived from current authority,
        /// never accepted from arbitrary renderer environment/argv fields.
        public let createContext: @Sendable (BackendCreateSessionInput, NativeRPCContext) async throws -> BackendLaunchContext
        public let emit: @Sendable (BackendSessionLifecycleEvent) -> Void
        public let renamed: @Sendable (String, String) async -> Void
        public let hookSettingsFiles: [String: URL]
        public let hookOfferFile: URL
        public let hookAdditionalContext: @Sendable (BackendSessionHookEvent) async throws -> String?
        public let hookOpenLink: (@Sendable (URL, String?) async throws -> BackendSessionHookOpenAnswer)?
        public let authCommands: any BackendAppSessionCommandExecuting

        public init(accounts: BackendAccountConfiguration, cipher: BackendAccountKeychainCipher,
                    confinement: any BackendConfinementLaunchResolver, instructions: any BackendInstructionLaunchResolver,
                    projectMCPSource: any BackendProjectMCPSource, browserReach: any BackendBrowserToolReach,
                    cleanup: BackendSessionLifecycleCleanup, restoreContext: BackendSessionRestoreContext,
                    excludedAppWorkingDirectories: [String], authorizeRPC: @escaping Authorization,
                    authorizeAccountMetadata: @escaping @Sendable (NativeRPCContext) throws -> Void,
                    authorizeMutation: @escaping @Sendable (NativeRPCContext) throws -> Void,
                    createContext: @escaping @Sendable (BackendCreateSessionInput, NativeRPCContext) async throws -> BackendLaunchContext,
                    emit: @escaping @Sendable (BackendSessionLifecycleEvent) -> Void,
                    renamed: @escaping @Sendable (String, String) async -> Void,
                    hookSettingsFiles: [String: URL], hookOfferFile: URL,
                    hookAdditionalContext: @escaping @Sendable (BackendSessionHookEvent) async throws -> String?,
                    hookOpenLink: (@Sendable (URL, String?) async throws -> BackendSessionHookOpenAnswer)? = nil,
                    authCommands: any BackendAppSessionCommandExecuting = BackendAppSessionCommandExecutor()) {
            self.accounts = accounts; self.cipher = cipher; self.confinement = confinement; self.instructions = instructions
            self.projectMCPSource = projectMCPSource; self.browserReach = browserReach; self.cleanup = cleanup
            self.restoreContext = restoreContext; self.excludedAppWorkingDirectories = excludedAppWorkingDirectories
            self.authorizeRPC = authorizeRPC; self.authorizeAccountMetadata = authorizeAccountMetadata
            self.authorizeMutation = authorizeMutation; self.createContext = createContext; self.emit = emit; self.renamed = renamed
            self.hookSettingsFiles = hookSettingsFiles; self.hookOfferFile = hookOfferFile
            self.hookAdditionalContext = hookAdditionalContext; self.hookOpenLink = hookOpenLink; self.authCommands = authCommands
        }
    }

    public struct Registration: Sendable {
        public let invokeChannels: [String]
        public let sendChannels: [String]
        public let events: [String]
    }
    public nonisolated let manager: BackendPTYManager
    public func agentSettingsCipher() -> BackendAccountKeychainCipher { dependencies.cipher }
    public func agentSettingsAccountConfiguration() -> BackendAccountConfiguration { dependencies.accounts }
    public nonisolated let ledger: BackendNativeLedger
    #if TD_HOST_ACCOUNT_BRIDGE
    public nonisolated let accounts: any BackendAccountLaunchResolver
    public nonisolated let profiles: any BackendHOSTProfileViewReading
    public nonisolated let vault: BackendAccountVault?
    public nonisolated let broker: BackendAccountBroker?
    public nonisolated let attribution: any BackendHOSTSessionAccountAttributing
    private let legacyAccountOwner: BackendAccountLaunchAdapter?
    private let hostedControls: BackendHOSTAccountSessionControls?
    public nonisolated var isHostedAccountGraph: Bool { hostedControls != nil }
    public nonisolated var hookEndpoint: BackendSessionHookEndpoint { hostedControls?.hookEndpoint ?? hookServer!.endpoint }
    #else
    public nonisolated let accounts: BackendAccountLaunchAdapter
    public nonisolated let profiles: BackendAccountProfileStore
    public nonisolated let vault: BackendAccountVault
    public nonisolated let broker: BackendAccountBroker
    public nonisolated let attribution: BackendAccountAttribution
    public nonisolated var hookEndpoint: BackendSessionHookEndpoint { hookServer.endpoint }
    #endif
    public nonisolated let launcher: BackendSessionLauncher
    public nonisolated let launch: BackendCoordinatedSessionLaunch
    public nonisolated let lifecycle: BackendSessionLifecycleCoordinator
    #if TD_HOST_ACCOUNT_BRIDGE
    public nonisolated let sessionTools: any BackendHOSTOrdinaryToolLeaseOwner
    #else
    public nonisolated let sessionTools: BackendSessionToolLeases
    #endif
    #if TD_HOST_ACCOUNT_BRIDGE
    public nonisolated let projectTools: any BackendHOSTProjectToolLeaseOwner
    #else
    public nonisolated let projectTools: BackendProjectToolComposition
    #endif
    public nonisolated let planner: BackendSessionRestorePlanner
    /// The switch and any account-history routes share this single writer.
    public nonisolated let sharedHistory: BackendAppSharedProjects
    public nonisolated let restore: BackendSessionRestoreCoordinator
    #if TD_HOST_ACCOUNT_BRIDGE
    public nonisolated let switches: any BackendHOSTSessionSwitching
    #else
    public nonisolated let switches: BackendSessionSwitchCoordinator
    #endif
    #if TD_HOST_ACCOUNT_BRIDGE
    public nonisolated let deferred: any BackendHOSTSessionDeferring
    #else
    public nonisolated let deferred: BackendSessionSwitchDeferred
    #endif
    #if TD_HOST_ACCOUNT_BRIDGE
    public nonisolated let hookCoordinator: any BackendHOSTSessionHookObserving
    #else
    public nonisolated let hookCoordinator: BackendSessionHookCoordinator
    #endif
    #if TD_HOST_ACCOUNT_BRIDGE
    public nonisolated let hookServer: BackendSessionHookServer?
    #else
    public nonisolated let hookServer: BackendSessionHookServer
    #endif
    #if TD_HOST_ACCOUNT_BRIDGE
    public nonisolated let hookInstallation: BackendSessionHookInstallation?
    #else
    public nonisolated let hookInstallation: BackendSessionHookInstallation
    #endif
    public nonisolated let sessionRPC: BackendSessionLifecycleRPC
    #if TD_HOST_ACCOUNT_BRIDGE
    public nonisolated let accountRPC: any BackendHOSTAccountChannelInvoking
    #else
    public nonisolated let accountRPC: BackendAccountRPC
    #endif
    #if TD_HOST_ACCOUNT_BRIDGE
    public nonisolated let hookRPC: any BackendHOSTAccountChannelInvoking
    #else
    public nonisolated let hookRPC: BackendSessionHookRPC
    #endif
    #if TD_HOST_ACCOUNT_BRIDGE
    public nonisolated let signIn: any BackendHOSTAccountChannelInvoking
    #else
    public nonisolated let signIn: BackendAppAccountSignInService
    #endif
    #if TD_HOST_ACCOUNT_BRIDGE
    public nonisolated let quit: any BackendHOSTSessionQuitting
    #else
    public nonisolated let quit: BackendSessionLifecycleQuit
    #endif
    private let dependencies: Dependencies
    public var macConfinement: BackendMacConfinement? { dependencies.confinement as? BackendMacConfinement }
    private let events: BackendCompositionSessionsEventPump
    private let eventTask: Task<Void, Never>
    private var registry: NativeChannelRegistry?
    private var ownerID: String?
    private var subscriptions: [NativeRPCSubscription] = []
    private var installing = false
    private var stopping = false
    private var stopped = false
    private var completedLeases: [String: BackendAccountCodexLease.Release] = [:]

    /// No app startup invokes this automatically. It uses the already supplied
    /// Store, providers and MCP owner and starts no CLI session or restoration.
    public static func activate(state: NativeStateStore, providers: BackendNativeProviders,
                                endpoint: any BackendMCPToolEndpoint, dependencies: Dependencies, prepared: Prepared? = nil,
                                fanout: (@Sendable (BackendSessionLifecycleEvent) -> Void)? = nil) async throws -> BackendCompositionSessions {
        guard state.ownership == .exclusive, let stateFile = state.file,
              stateFile.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path == dependencies.accounts.dataDirectory.resolvingSymlinksInPath().path else {
            throw BackendSessionFailure.missingCapability("exclusive native Store/account/session ownership in the same data folder")
        }
        guard dependencies.cipher.appName == dependencies.accounts.appName else {
            throw BackendAccountFailure("The account cipher must use this app's existing safe-storage identity.")
        }
        for (name, readiness) in [("session MCP endpoint", endpoint.readiness), ("confinement", dependencies.confinement.readiness), ("instructions", dependencies.instructions.readiness),
                                  ("project MCP source", dependencies.projectMCPSource.readiness), ("browser reach", dependencies.browserReach.readiness),
                                  ("session cleanup", dependencies.cleanup.readiness)] {
            guard readiness == .ready else { throw BackendSessionFailure.missingCapability(name) }
        }
        guard Set(dependencies.hookSettingsFiles.keys) == Set(BackendSessionHookInstallation.events.keys),
              dependencies.hookSettingsFiles.values.allSatisfy({ $0.isFileURL && $0.path.hasPrefix("/") }),
              dependencies.hookOfferFile.isFileURL, dependencies.hookOfferFile.path.hasPrefix("/"),
              dependencies.excludedAppWorkingDirectories.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else {
            throw BackendSessionFailure.invalidInput("Session hooks and excluded app folders require trusted absolute paths.")
        }
        try Task.checkCancellation()
        let prepared = prepared ?? Prepared(environment: dependencies.accounts.inheritedEnvironment)
        try prepared.claim(environment: dependencies.accounts.inheritedEnvironment)
        let accounts = try await BackendAccountLaunchAdapter.start(configuration: dependencies.accounts,
            stateStore: state, cipher: dependencies.cipher)
        let events = prepared.events, manager = prepared.manager
        let emit: @Sendable (BackendSessionLifecycleEvent) -> Void = { event in dependencies.emit(event); fanout?(event) }
        var hookServer: BackendSessionHookServer?
        var switches: BackendSessionSwitchCoordinator?
        var deferred: BackendSessionSwitchDeferred?
        var sessionTools: BackendSessionToolLeases?
        var projectTools: BackendProjectToolComposition?
        do {
            try Task.checkCancellation()
            let ledger = try await BackendNativeLedger.activate(store: state)
            let profiles = await accounts.profiles, vault = await accounts.vault, broker = await accounts.broker
            // D11: the launch adapter says "account vault off: …" once when it runs without the vault.
            // F4-attrib / TS configureSessionAccounts: the PTY manager owns each session's record and pid.
            let attribution = BackendAccountAttribution(configuration: dependencies.accounts, profiles: profiles,
                sessions: .init(manager: manager))
            let launchDependencies = try BackendSessionLaunchDependencies(providers: providers, accounts: accounts,
                confinement: dependencies.confinement, instructions: dependencies.instructions, ledger: ledger)
            let launcher = BackendSessionLauncher(manager: manager, dependencies: launchDependencies)
            let ordinaryTools = try BackendSessionToolLeases(endpoint: endpoint, userData: dependencies.accounts.dataDirectory)
            sessionTools = ordinaryTools
            let configuredTools = try BackendProjectToolComposition(source: dependencies.projectMCPSource,
                userData: dependencies.accounts.dataDirectory, inheritedEnvironment: dependencies.accounts.inheritedEnvironment)
            projectTools = configuredTools
            let launch = try BackendCoordinatedSessionLaunch(launcher: launcher, providers: providers,
                sessionTools: ordinaryTools, projectTools: configuredTools, reach: dependencies.browserReach)
            let lifecycle = try BackendSessionLifecycleCoordinator(manager: manager, launch: launch, accounts: accounts,
                attribution: attribution, ledger: ledger, store: state, cleanup: dependencies.cleanup, emit: emit)
            let hookCoordinator = BackendSessionHookCoordinator(lifecycle: lifecycle, attribution: attribution, ledger: ledger)
            let hooks = try BackendSessionHookServer(configuration: dependencies.accounts,
                sessionEnvironment: BackendSessionEnvironment.sessionVariable, coordinator: hookCoordinator,
                additionalContext: dependencies.hookAdditionalContext, openLink: dependencies.hookOpenLink)
            hookServer = hooks
            let hookInstallation = try BackendSessionHookInstallation(configuration: dependencies.accounts, endpoint: hooks.endpoint,
                providerSettingsFiles: dependencies.hookSettingsFiles, offerFile: dependencies.hookOfferFile,
                authorizeMutation: dependencies.authorizeMutation)
            let planner = BackendSessionRestorePlanner(accounts: accounts, providers: providers, context: dependencies.restoreContext)
            let restore = BackendSessionRestoreCoordinator(lifecycle: lifecycle, planner: planner, store: state,
                context: dependencies.restoreContext, excludedAppWorkingDirectories: dependencies.excludedAppWorkingDirectories, emit: emit)
            let sharedHistory = BackendAppSharedProjects(
                systemConfig: URL(fileURLWithPath: dependencies.accounts.systemDirectory("claude")),
                managedRoot: dependencies.accounts.profilesRoot, writable: true, changed: {})
            let switching = try await BackendSessionSwitchCoordinator.start(lifecycle: lifecycle, accounts: accounts,
                attribution: attribution, planner: planner, store: state, sharedHistory: .projects(sharedHistory), emit: emit)
            switches = switching
            let later = await BackendSessionSwitchDeferred.start(lifecycle: lifecycle, switches: switching, emit: emit)
            deferred = later
            let sessionRPC = BackendSessionLifecycleRPC(lifecycle: lifecycle, switches: switching, restore: restore,
                deferred: later, store: state, authorizeMutation: dependencies.authorizeMutation)
            let accountRPC = BackendAccountRPC(accounts: accounts, configuration: dependencies.accounts,
                authorizeMutation: dependencies.authorizeMutation, sessionTitle: { id in manager.list().first { $0.id == id }?.title })
            // 4 Nov: once at start, where the account list is kept: every email-named account carries the address it
            // is signed in as (BackendAccountTidy; copies the list first, logs each rename, changes nothing else).
            let tidyConfiguration = dependencies.accounts
            Task.detached(priority: .utility) {
                let store = await accounts.profiles
                guard store.readiness == .ready else { return }
                _ = await BackendAccountTidy.run(configuration: tidyConfiguration, list: { try await store.list() },
                    rename: { id, next in _ = try await store.rename(id: id, name: next) })
            }
            let hookRPC = BackendSessionHookRPC(installation: hookInstallation, server: hooks)
            let signIn = BackendAppAccountSignInService(accounts: accounts, providers: providers, configuration: dependencies.accounts,
                executor: dependencies.authCommands, authorizeMetadata: dependencies.authorizeAccountMetadata,
                authorizeMutation: dependencies.authorizeMutation)
            // A Claude session never starts on a login that is signed out (BackendAccountLaunchAdapter.signedOutRefusal).
            await accounts.setSignInCheck(identity: { [signIn] profile in await signIn.read(profile, refresh: false).account }) {
                [signIn] profile, fresh in await signIn.read(profile, refresh: fresh).state
            }
            let quit = BackendSessionLifecycleQuit(lifecycle: lifecycle, switches: switching, deferred: later,
                accounts: accounts, store: state, ledger: ledger, hooks: hooks)
            try Task.checkCancellation()
            let task = events.start(lifecycle: lifecycle)
            return BackendCompositionSessions(manager: manager, ledger: ledger, accounts: accounts, profiles: profiles,
                vault: vault, broker: broker, attribution: attribution, launcher: launcher, launch: launch, lifecycle: lifecycle,
                sessionTools: ordinaryTools, projectTools: configuredTools, planner: planner, sharedHistory: sharedHistory, restore: restore,
                switches: switching, deferred: later, hookCoordinator: hookCoordinator, hookServer: hooks,
                hookInstallation: hookInstallation, sessionRPC: sessionRPC, accountRPC: accountRPC, hookRPC: hookRPC,
                signIn: signIn, quit: quit, dependencies: dependencies, events: events, eventTask: task)
        } catch {
            await deferred?.stop(); await switches?.stop(); await sessionTools?.stop(); await projectTools?.stop()
            hookServer?.stop(); events.finish(); manager.beginShutdown()
            _ = await accounts.shutdown()
            throw error
        }
    }

    private init(manager: BackendPTYManager, ledger: BackendNativeLedger, accounts: BackendAccountLaunchAdapter,
                 profiles: BackendAccountProfileStore, vault: BackendAccountVault, broker: BackendAccountBroker,
                 attribution: BackendAccountAttribution, launcher: BackendSessionLauncher, launch: BackendCoordinatedSessionLaunch,
                 lifecycle: BackendSessionLifecycleCoordinator, sessionTools: BackendSessionToolLeases,
                 projectTools: BackendProjectToolComposition, planner: BackendSessionRestorePlanner, sharedHistory: BackendAppSharedProjects,
                 restore: BackendSessionRestoreCoordinator, switches: BackendSessionSwitchCoordinator,
                 deferred: BackendSessionSwitchDeferred, hookCoordinator: BackendSessionHookCoordinator,
                 hookServer: BackendSessionHookServer, hookInstallation: BackendSessionHookInstallation,
                 sessionRPC: BackendSessionLifecycleRPC, accountRPC: BackendAccountRPC, hookRPC: BackendSessionHookRPC,
                 signIn: BackendAppAccountSignInService, quit: BackendSessionLifecycleQuit, dependencies: Dependencies,
                 events: BackendCompositionSessionsEventPump, eventTask: Task<Void, Never>) {
        #if TD_HOST_ACCOUNT_BRIDGE
        legacyAccountOwner = accounts; hostedControls = nil
        #endif
        self.manager = manager; self.ledger = ledger; self.accounts = accounts; self.profiles = profiles; self.vault = vault
        self.broker = broker; self.attribution = attribution; self.launcher = launcher; self.launch = launch; self.lifecycle = lifecycle
        self.sessionTools = sessionTools; self.projectTools = projectTools; self.planner = planner; self.sharedHistory = sharedHistory; self.restore = restore
        self.switches = switches; self.deferred = deferred; self.hookCoordinator = hookCoordinator; self.hookServer = hookServer
        self.hookInstallation = hookInstallation; self.sessionRPC = sessionRPC; self.accountRPC = accountRPC; self.hookRPC = hookRPC
        self.signIn = signIn; self.quit = quit; self.dependencies = dependencies; self.events = events; self.eventTask = eventTask
    }

    #if TD_HOST_ACCOUNT_BRIDGE && TD_HOST_INTEGRATED
    /// Called INSTEAD OF activate's local account start. Caller configured the
    /// managed namespace and transferred the one actual profile/vault writer.
    public static func activateHosted(state: NativeStateStore, providers: BackendNativeProviders,
        dependencies: Dependencies, prepared: Prepared, parts: BackendHOSTAccountSessionParts,
        ordinaryTools: any BackendHOSTOrdinaryToolLeaseOwner, projectTools: any BackendHOSTProjectToolLeaseOwner,
        machineID: String, createResolved: @escaping BackendSessionLauncher.HostedDispatch,
        controls: BackendHOSTAccountSessionControls,
        fanout: (@Sendable (BackendSessionLifecycleEvent) -> Void)? = nil) async throws -> BackendCompositionSessions {
        guard prepared.manager.localSessionCount() == 0 else {
            throw BackendSessionFailure.missingCapability("the previous in-app sessions must retain their existing writer until they drain")
        }
        try prepared.claim(environment: dependencies.accounts.inheritedEnvironment)
        let emit: @Sendable (BackendSessionLifecycleEvent) -> Void = { event in dependencies.emit(event); fanout?(event) }
        let components = try await BackendHOSTAccountSessionConstruction.make(manager: prepared.manager,
            state: state, providers: providers, parts: parts, dependencies: dependencies,
            ordinaryTools: ordinaryTools, projectTools: projectTools, machineID: machineID,
            createResolved: createResolved, emit: emit)
        // 12 Oct (accounts): a session the host cannot switch in place (it started before switching was ready)
        // is offered, in plain words, a restart that resumes its conversation (BackendSessionSwitchRestartFallback).
        let restartParts = BackendSessionSwitchRestartFallback.restartParts(manager: components.manager, lifecycle: components.lifecycle,
            store: state, planner: components.planner, sharedHistory: .projects(components.sharedHistory),
            find: { [profiles = components.profiles] id in try await profiles.find(id) }, configuration: components.profiles.configuration, emit: emit)
        let inner = controls.switches, manager = components.manager
        let switching = BackendSessionSwitchRestartFallback(inPlacePlan: { try await inner.subject(sessionID: $0, accountID: $1) },
            inPlacePerform: { try await inner.perform(sessionID: $0, accountID: $1, note: $2) },
            restartPlan: restartParts.plan, restart: restartParts.restart,
            cancel: { try await inner.cancel(sessionID: $0) }, stop: { await inner.stop() },
            pending: { await inner.pendingAccount(sessionID: $0) },
            handoverPlan: restartParts.handoverPlan, handover: restartParts.handover,
            fingerprint: { id in BackendSessionSwitchPlanMemo.fingerprint(manager.list().first { $0.id == id }, pid: manager.pidOf(id)) })
        let hostedControls = BackendHOSTAccountSessionControls(switches: switching, deferred: controls.deferred, hooks: controls.hooks,
            hookObservation: controls.hookObservation, hookEndpoint: controls.hookEndpoint,
            detachForKeep: controls.detachForKeep, closeAfterDrain: controls.closeAfterDrain)
        let rpc = BackendSessionLifecycleRPC(lifecycle: components.lifecycle, switches: hostedControls.switches,
            restore: components.restore, deferred: hostedControls.deferred, store: state, authorizeMutation: dependencies.authorizeMutation)
        let quit = BackendHOSTHostedSessionQuit(lifecycle: components.lifecycle, ledger: components.ledger,
            store: state, controls: hostedControls)
        // 2 Nov (lane/working-turn): behind the session host every session's hooks reach the app only as accepted
        // events (the app runs no hook server of its own); a session's turn, and so its status, follows them.
        let turns = BackendSessionTurnFeed(components.lifecycle)
        _ = await controls.hookObservation.observeAccepted { event in turns.post(event) }
        let events = prepared.events, task = events.start(lifecycle: components.lifecycle)
        return BackendCompositionSessions(hosted: components, resolver: parts.resolver, controls: hostedControls,
            sessionRPC: rpc, quit: quit, dependencies: dependencies, events: events, eventTask: task)
    }
    private init(hosted: BackendHOSTAccountSessionConstruction, resolver: BackendHOSTAccountResolver,
        controls: BackendHOSTAccountSessionControls, sessionRPC: BackendSessionLifecycleRPC,
        quit: BackendHOSTHostedSessionQuit, dependencies: Dependencies,
        events: BackendCompositionSessionsEventPump, eventTask: Task<Void, Never>) {
        manager = hosted.manager; ledger = hosted.ledger; accounts = resolver; profiles = hosted.profiles
        vault = nil; broker = nil; legacyAccountOwner = nil; hostedControls = controls
        attribution = hosted.accounts; launcher = hosted.launcher; launch = hosted.launch; lifecycle = hosted.lifecycle
        sessionTools = hosted.sessionTools; projectTools = hosted.projectTools; planner = hosted.planner
        sharedHistory = hosted.sharedHistory; restore = hosted.restore; switches = controls.switches; deferred = controls.deferred
        hookCoordinator = controls.hookObservation; hookServer = nil; hookInstallation = nil
        self.sessionRPC = sessionRPC; accountRPC = hosted.accountRPC; hookRPC = controls.hooks; signIn = hosted.signIn
        self.quit = quit; self.dependencies = dependencies; self.events = events; self.eventTask = eventTask
    }
    #endif

    /// Native app high-level channels and the exact five basic invoke / two
    /// send channels from index.ts. Remote dispatch reuses `lifecycle` directly.
    public func install(registry: NativeChannelRegistry, ownerID: String) async throws -> Registration {
        guard !stopped, !stopping, !installing, self.ownerID == nil, !ownerID.isEmpty else {
            throw NativeRPCError(code: "composition-state", message: "The native session graph is stopped or already installed")
        }
        installing = true; defer { installing = false }
        for channel in Self.invokeChannels {
            if await registry.has(channel) { throw NativeRPCError(code: "duplicate-handler", message: "A different owner already handles '\(channel)'") }
        }
        self.ownerID = ownerID; self.registry = registry
        do {
            for channel in Self.invokeChannels.sorted() {
                try await registry.register(channel, ownerID: ownerID) { [self] context, args in
                    try await self.invoke(channel, context: context, args: args)
                }
            }
            for channel in Self.sendChannels.sorted() {
                subscriptions.append(try await registry.onSend(channel, ownerID: ownerID) { [self] context, args in
                    try await self.send(channel, context: context, args: args)
                })
            }
            // 28 Oct: this Mac's terminals hear at once when another device takes a session (or this Mac takes it back).
            subscriptions.append(manager.observeSizes { [weak self] id in Task { await self?.ownerMayHaveMoved(id) } })
            return Registration(invokeChannels: Self.invokeChannels.sorted(), sendChannels: Self.sendChannels.sorted(), events: Self.eventChannels.sorted())
        } catch {
            for subscription in subscriptions { await subscription.cancelAndWait() }; subscriptions = []
            await registry.removeOwner(ownerID); self.ownerID = nil; self.registry = nil
            throw error
        }
    }

    private func invoke(_ channel: String, context: NativeRPCContext, args: [NativeRPCValue]) async throws -> NativeRPCValue {
        #if TD_HOST_ACCOUNT_BRIDGE
        return try await BackendHOSTProfileScope.withContext(context) { try await self.invokeScoped(channel, context: context, args: args) }
        #else
        return try await invokeScoped(channel, context: context, args: args)
        #endif
    }
    private func invokeScoped(_ channel: String, context: NativeRPCContext, args: [NativeRPCValue]) async throws -> NativeRPCValue {
        guard !stopped, !stopping else { throw BackendSessionFailure.closed }
        try await dependencies.authorizeRPC(context, channel, args); try Task.checkCancellation()
        if BackendSessionLifecycleRPC.channels.contains(channel) { return try await sessionRPC.invoke(channel, args: args, context: context) }
        if BackendAccountRPC.channels.contains(channel) { return try await accountRPC.invoke(channel, args: args, context: context) }
        if BackendSessionHookRPC.channels.contains(channel) { return try await hookRPC.invoke(channel, args: args, context: context) }
        if BackendAppAccountSignInService.channels.contains(channel) { return try await signIn.invoke(channel, args: args, context: context) }
        switch channel {
        case "session:create":
            let raw = context.argument(0, in: args)
            _ = try raw.requireObject("session creation")
            let bytes = try raw.encodedJSON()
            guard bytes.count <= 128 * 1024 else { throw NativeRPCError.invalidArguments("The session creation request is too large") }
            let input = try JSONDecoder().decode(BackendCreateSessionInput.self, from: bytes)
            let launchContext = try await dependencies.createContext(input, context)
            let session = try await lifecycle.create(input, context: launchContext)
            return try Self.wire(session)
        case "session:list": return .array(try manager.list().map(Self.wire))
        // 27 Oct: this Mac's terminal joining a session gets it drawn as it is now, not its raw tail (`remount`).
        case "session:scrollback": return .string(manager.remount(try context.argument(0, in: args).requireString("session id", nonempty: true)))
        // 28 Oct (Asad: the session follows the device where it was chosen last): [id, cols, rows] the session was
        // chosen on this Mac at its terminal's size. Answers once the program has redrawn for it: who has it now
        // ({here, name, kind, turn}) and whether it was resized.
        case "session:use":
            let id = try context.argument(0, in: args).requireString("session id", nonempty: true)
            let cols = try Self.dimension(context.argument(1, in: args)), rows = try Self.dimension(context.argument(2, in: args))
            let resized = try await lifecycle.use(sessionID: id, cols: cols, rows: rows)
            return Self.ownerValue(manager.owner(id)).setting("resized", .bool(resized))
        // 28 Oct: who has the session's size: {here, name, kind, turn} (`TerminalOwner`; also the `session:owner` event).
        case "session:owner": return Self.ownerValue(manager.owner(try context.argument(0, in: args).requireString("session id", nonempty: true)))
        case "session:kill":
            let id = try context.argument(0, in: args).requireString("session id", nonempty: true)
            // Ending the session ends its waiting switch too, so a refused cancel never keeps it running.
            try? await deferred.cancel(sessionID: id); try await lifecycle.close(sessionID: id); return .missing
        case "session:rename":
            let id = try context.argument(0, in: args).requireString("session id", nonempty: true)
            let title = try context.argument(1, in: args).requireString("session title")
            let renamed = try await lifecycle.rename(sessionID: id, title: title)
            if renamed { await dependencies.renamed(id, title) }; return .bool(renamed)
        default: throw BackendSessionFailure.unsupported("This native session channel is not registered.")
        }
    }
    /// The `session:owner` event, only when who has the session changed (its size changing alone is not told).
    private var toldOwners: [String: TerminalOwner] = [:]
    private func ownerMayHaveMoved(_ id: String) async {
        guard let registry, !stopped else { return }
        let owner = manager.owner(id)
        guard toldOwners[id] != owner else { return }
        toldOwners[id] = owner
        do { try await registry.publish("session:owner", arguments: [.string(id), Self.ownerValue(owner)]) }
        catch { NSLog("[native lifecycle] %@", error.localizedDescription) }
    }
    private func send(_ channel: String, context: NativeRPCContext, args: [NativeRPCValue]) async throws {
        guard !stopped, !stopping else { throw BackendSessionFailure.closed }
        try await dependencies.authorizeRPC(context, channel, args)
        let id = try context.argument(0, in: args).requireString("session id", nonempty: true)
        switch channel {
        case "session:write": try await lifecycle.write(sessionID: id, data: context.argument(1, in: args).requireString("terminal input"))
        case "session:resize":
            let cols = try Self.dimension(context.argument(1, in: args))
            let rows = try Self.dimension(context.argument(2, in: args))
            try await lifecycle.resize(sessionID: id, cols: cols, rows: rows)
        default: throw BackendSessionFailure.unsupported("This native session send channel is not registered.")
        }
    }

    /// Root calls restore explicitly after native routes and event consumers
    /// are installed. Activation itself never launches saved CLI processes.
    public func restoreSavedSessions() async throws -> BackendSessionRestoreCoordinator.Result {
        guard !stopped, !stopping, ownerID != nil else { throw BackendSessionFailure.closed }
        // 10 Nov (Asad: "/resume can't see past chats when I switch account"): before the tabs come back, every
        // account folder the app made that no running session uses joins the one chat history of its AI.
        let notes = await joinSharedHistory()
        // 10 Nov (Asad's Decker tab): the last resort for a tab whose own conversations are gone from disk.
        await restore.setConversationHint(BackendRestoreConversationHint.make(dataRoot: dependencies.accounts.dataDirectory))
        var result = try await restore.restore()
        result.notes = notes + result.notes
        return result
    }
    private func joinSharedHistory() async -> [String] {
        let live = manager.list().filter { $0.exitCode == nil }
        let inUse = Set(live.flatMap { [$0.profileId, $0.homeProfileId].compactMap { $0 } })
        guard let accounts = try? await profiles.list(provider: nil) else { return ["shared history: the account list could not be read; nothing was joined"] }
        let profiles = self.profiles
        let outcome = await BackendSharedHistoryJoin.joinAll(accounts, configuration: dependencies.accounts,
            managed: { (try? await profiles.managed($0)) ?? false }, inUse: inUse)
        var notes: [String] = []
        if !outcome.joined.isEmpty { notes.append("shared history: \(outcome.joined.count) account folder(s) joined (\(outcome.joined.joined(separator: ", "))); \(outcome.keptBeside) clashing file(s) kept beside") }
        for line in outcome.skipped where line.contains("in use") { notes.append("shared history: waits for a later start: " + line) }
        for line in outcome.failed { notes.append("shared history: not joined: " + line) }
        return notes
    }

    /// The existing quit owner retains native processes for the user's Keep
    /// choice. Actual teardown flushes the event queue before closing accounts.
    public func applyQuit(keep: Bool) async -> BackendSessionLifecycleQuit.Result {
        #if TD_HOST_ACCOUNT_BRIDGE
        if hostedControls != nil, keep {
            let result = await quit.apply(keep: true)
            if case .detached = result {
                events.finish(); await eventTask.value
                for subscription in subscriptions { await subscription.cancelAndWait() }; subscriptions = []
                if let registry, let ownerID { await registry.removeOwner(ownerID) }
                registry = nil; ownerID = nil; stopped = true
            }
            return result
        }
        #endif
        if keep, manager.list().contains(where: { $0.exitCode == nil }) { return await quit.apply(keep: true) }
        return await shutdown()
    }
    #if TD_HOST_INTEGRATED
    /// QUIT (9 Oct): only the explicit Stop Everything sets this. Every other shutdown — quit,
    /// signal, logout, update, a failed startup — leaves the session host's processes running.
    private var hostedStopAuthorized = false
    public func authorizeHostedStop() { hostedStopAuthorized = true }
    #endif
    public func shutdown() async -> BackendSessionLifecycleQuit.Result {
        guard !stopped else { return .stopped(codexLeases: completedLeases) }
        guard !stopping else { return .blocked("Native session shutdown is already in progress.") }
        stopping = true; defer { stopping = false }
        #if TD_HOST_INTEGRATED
        let stopHosted = hostedStopAuthorized
        #else
        let stopHosted = true
        #endif
        #if TD_HOST_ACCOUNT_BRIDGE
        // Pending account switches of kept sessions belong to their helper; a detach leaves them there.
        let helperKeepsSwitches = hostedControls != nil && !stopHosted
        #else
        let helperKeepsSwitches = false
        #endif
        await lifecycle.stopAccepting()
        if !helperKeepsSwitches { await deferred.stop(); await switches.stop() }
        do { try await ledger.prepareForQuit() }
        catch { return .blocked("The recovery ledger could not be saved before shutdown: " + error.localizedDescription) }
        #if TD_HOST_INTEGRATED
        // Detach BEFORE stopping processes, so stopping reaches in-app processes only.
        manager.prepareShutdown(stopHosted: stopHosted)
        #endif
        guard await lifecycle.stopProcesses() else { return .blocked("Owned session processes have not all exited. Their credential leases and stores remain open.") }
        events.finish(); await eventTask.value
        #if TD_HOST_ACCOUNT_BRIDGE
        hookServer?.stop(); await hookCoordinator.stop()
        let leases: [String: BackendAccountCodexLease.Release]
        if let hostedControls {
            if stopHosted {
                do { leases = try await hostedControls.closeAfterDrain() }
                catch { return .blocked("Actual helper account cleanup is unconfirmed: " + error.localizedDescription) }
            } else { leases = [:] } // the helper keeps its account owner for the kept sessions
        } else if let legacyAccountOwner { leases = await legacyAccountOwner.shutdown() }
        else { return .blocked("No actual account owner can confirm cleanup.") }
        #else
        hookServer.stop(); await hookCoordinator.stop()
        let leases = await accounts.shutdown()
        #endif
        for subscription in subscriptions { await subscription.cancelAndWait() }; subscriptions = []
        if let registry, let ownerID { await registry.removeOwner(ownerID) }
        self.registry = nil; ownerID = nil; stopped = true; completedLeases = leases
        return .stopped(codexLeases: leases)
    }

    public static let baseInvokeChannels: Set<String> = ["session:create", "session:list", "session:scrollback", "session:use", "session:owner", "session:kill", "session:rename"]
    public static let invokeChannels = baseInvokeChannels.union(BackendSessionLifecycleRPC.channels).union(BackendAccountRPC.channels).union(BackendSessionHookRPC.channels).union(BackendAppAccountSignInService.channels)
    public static let sendChannels: Set<String> = ["session:write", "session:resize"]
    /// Root emits these using the source payloads and actual audience authority.
    public static let eventChannels: Set<String> = ["session:data", "session:exit", "session:status", "session:removed", "session:renamed", "session:created", "session:switched", "session:switch-failed", "sessions:held", "session:owner"]
    static func ownerValue(_ owner: TerminalOwner) -> NativeRPCValue {
        .object([.init("here", .bool(owner.here)), .init("name", owner.name.map(NativeRPCValue.string) ?? .null),
                 .init("kind", .string(owner.kind)), .init("turn", .number(Double(owner.turn)))])
    }
    private static func wire(_ session: BackendSessionMeta) throws -> NativeRPCValue { try NativeRPCValue.parseJSON(JSONEncoder().encode(session)) }
    private static func dimension(_ value: NativeRPCValue) throws -> Int {
        guard let number = value.number, number.isFinite, number.rounded(.towardZero) == number,
              number >= Double(Int.min), number < Double(Int.max) else {
            throw NativeRPCError.invalidArguments("Terminal dimensions must be whole numbers")
        }
        // The sole PTY manager applies its existing clamp and maximum.
        return Int(number)
    }
}

/// PTY callbacks arrive on one serial queue. A single stream consumer awaits
/// the sole lifecycle owner in that same order; per-event detached tasks would
/// let a fast exit overtake a session's preceding output/account cleanup.
fileprivate final class BackendCompositionSessionsEventPump: Sendable {
    private let stream: AsyncStream<BackendSessionEvent>
    private let continuation: AsyncStream<BackendSessionEvent>.Continuation
    init() {
        let pair = AsyncStream<BackendSessionEvent>.makeStream(bufferingPolicy: .unbounded)
        stream = pair.stream; continuation = pair.continuation
    }
    func submit(_ event: BackendSessionEvent) { continuation.yield(event) }
    func start(lifecycle: BackendSessionLifecycleCoordinator) -> Task<Void, Never> {
        Task { [stream] in for await event in stream { await lifecycle.noteSessionEvent(event) } }
    }
    func finish() { continuation.finish() }
}
