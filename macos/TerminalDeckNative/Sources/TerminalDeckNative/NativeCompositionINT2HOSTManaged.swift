#if TD_HOST_ACCOUNT_BRIDGE && TD_HOST_INTEGRATED
import AppKit
import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Inert until prepare() is explicitly selected INSTEAD OF local account
/// activation. Core and agents helpers retain distinct process ownership.
@MainActor
final class NativeCompositionINT2HOSTManaged {
    private unowned let owner: NativeCompositionProduction
    /// The same owner, read only to ask whether it still exists. A start that failed after this object was made
    /// frees the production graph (NativeCompositionRoot: `production = nil`), and the quit that follows must not
    /// reach it through `owner`: 2 Nov 06:37, the dev copy aborted in swift_abortRetainUnowned inside
    /// stopAppAccountSignIns after "session host unavailable".
    private weak var liveOwner: NativeCompositionProduction?
    private(set) var coreClient: BackendHOSTClient!
    private(set) var coreBridge: BackendHOSTManagerBridge!
    private(set) var managedClient: BackendHOSTClient!
    private(set) var managedBridge: BackendHOSTManagerBridge!
    private(set) var relay: BackendHOSTAppRelayClient! { didSet { relayBox.set(relay) } }
    /// L8 (11 Oct): what the account door asks for the CURRENT relay attachment (a replaced helper has a new one).
    private let relayBox = NativeHOSTRelayBox()
    // Kept from prepare() so a crashed helper can be replaced without restarting the app (helper crash recovery).
    private var agentsPlan: BackendHOSTLaunchAgent?
    private var helperURL: URL?
    private var agentsPaths: BackendHOSTPaths?
    private var restartSpent = false
    private var explicitRestart = false
    private var restartLaunches: [NativeRPCValue] = []
    func restartState() throws -> NativeRPCValue {
        guard let managedClient else { throw BackendHOSTFailure.unavailable }
        var statuses: [NativeRPCValue] = []
        for row in try managedClient.list() where row.exitCode == nil {
            let state = try managedClient.snapshot(row.id)?.status.rawValue ?? "missing"
            statuses.append(.object([.init("id", .string(row.id)), .init("title", .string(row.title)), .init("status", .string(state))]))
        }
        return .object([.init("restartSpent", .bool(restartSpent)), .init("pid", .number(Double(managedClient.hello.hostPID))), .init("version", .string(managedClient.hello.hostVersion)), .init("sessions", .array(statuses))])
    }
    func restartOnce() async throws -> NativeRPCValue {
        guard !restartSpent, !reconnecting, !detached, let agentsPlan, let helperURL, let managedClient, let managedBridge else { throw BackendHOSTFailure.invalid("The one session-helper restart is unavailable or already spent.") }
        guard let sessions = owner.sessions, let surface = owner.coreSurface else { throw BackendHOSTFailure.unavailable }
        let rows = sessions.manager.list()
        for row in rows where row.exitCode == nil {
            // The accepted hook/screen record is the same source used by sessions_list and the rail.
            let visible = surface.sessionStatus(row.id)["status"].string ?? "idle"
            guard ["idle", "waiting", "completed"].contains(visible) else {
                // 3 Nov: name the session, so a refusal says which one holds it (it was guessed for an hour).
                throw BackendHOSTFailure.invalid("Wait until every session is idle before the one helper restart (\(row.title): \(visible)).")
            }
            if sessions.manager.isHostedSession(row.id), let raw = try managedClient.snapshot(row.id), raw.status == .working {
                throw BackendHOSTFailure.invalid("A terminal is still streaming; the helper was left running.")
            }
            if row.chat == true, let chats = owner.sessionChats {
                let state = try await chats.read(row.id, cursor: nil, limit: 1)
                guard state["busy"].bool != true, (state["pending"].elements ?? []).isEmpty else { throw BackendHOSTFailure.invalid("A Chat is still answering or waiting for permission; the helper was left running.") }
            }
        }
        let old = managedClient.hello
        guard old.hostVersion != agentsPlan.version else { throw BackendHOSTFailure.invalid("The helper already runs this payload; no restart was made.") }
        // 28 Oct (bug A): each session is put back in the conversation it is in NOW, not the one it started with
        // (after a /clear the CLI moved on; the saved launch still named the first one and came back "not found").
        await DeckMemorySessionCenter.shared?.reconcileConversations()
        let ids = managedBridge.liveIDs()
        // 4b (Asad 15 Oct): a live session the ledger never remembered (an AI-started chat, an idle empty Codex chat)
        // is put back from the helper's own launch record instead of blocking the restart. Task and app-composed
        // sessions stay with their owners (the task engine, Hoot), and a device-confined one keeps the old refusal.
        var recorded: [String: NativeRPCValue] = [:]
        for id in ids {
            guard let snapshot = try? managedClient.snapshot(id), let input = snapshot.input, let scope = snapshot.scope,
                  !scope.isAppComposed, scope.hostedTask != true, input.taskID == nil, scope.deviceBoundary == nil else { continue }
            var launch = BackendNativeLedger.savedLaunch(snapshot.session, input: input, deviceKey: nil)
            let title = snapshot.session.title // its tab name ("Hoot → codex · Deck Dev"), not the bare folder name
            if !title.isEmpty, title != URL(fileURLWithPath: input.cwd).lastPathComponent { launch = launch.setting("title", .string(title)) }
            recorded[id] = launch
        }
        restartLaunches = try await sessions.restore.snapshotForHostRestart(ids, live: recorded)
        guard Set(ids) == Set(managedBridge.liveIDs()) else {
            restartLaunches = []
            throw BackendHOSTFailure.invalid("The session list changed; the helper was left running. Wait for idle and retry.")
        }
        restartSpent = true; explicitRestart = true
        do { try await agentsPlan.restartUsingSavedConversations(sourceHelper: helperURL) }
        catch {
            if managedClient.sameHostAnswers() { restartLaunches = [] }
            throw error
        }
        await reconnect()
        guard managedClient.isConnected, managedClient.hello.hostVersion == agentsPlan.version,
              managedClient.hello.instance != old.instance else {
            throw BackendHOSTFailure.invalid("The replacement session helper did not become ready.")
        }
        return .object([.init("oldPID", .number(Double(old.hostPID))), .init("oldVersion", .string(old.hostVersion)),
            .init("candidateVersion", .string(agentsPlan.version)), .init("newPID", .number(Double(managedClient.hello.hostPID))),
            .init("newVersion", .string(managedClient.hello.hostVersion)), .init("restartRequested", .bool(true))])
    }
    private var hooksArguments: NativeRPCValue?
    private var relayHandler: BackendHOSTAppRelayClient.Handler?
    private var appControls: BackendHOSTResourceFactory.AppControls?
    /// The one reconnect under way. Its own task: never part of whoever asked for it (bug A, 28 Oct).
    private var reconnectTask: Task<Void, Never>?
    private var reconnecting = false
    private(set) var reconnects = 0
    private(set) var appAccounts: BackendHOSTAccountControlApp!
    private var appSignIn: BackendHOSTAppAccountSignIn?
    private(set) var controls: BackendHOSTAccountSessionControls!
    private var installedShim: BackendMacAppHandoffShimInstalled?
    /// Weak: it lives only as long as the production graph that holds it (`hostManaged`), so a failed start
    /// or a finished stop leaves no object behind for the quit path to find.
    static weak var current: NativeCompositionINT2HOSTManaged?
    private(set) var detached = false
    private var resourcesConfigureAttempted = false
    private var resourcesConfigured = false
    private var constructionStarted = false
    // Exact existing ordinary-session identity (the original bind default).
    private let machineID = ""
    init(owner: NativeCompositionProduction) { self.owner = owner; liveOwner = owner; Self.current = self }

    func prepare(dependencies: BackendCompositionSessions.Dependencies,
                 projectSource: any BackendProjectMCPSource) async throws -> BackendCompositionSessions {
        let accountRecovery = BackendAccountVaultRecovery(configuration: dependencies.accounts)
        _ = try? accountRecovery.prepareIfFreshOrMigratable()
        _ = try? BackendAccountProfileStore.cleanEmptyAccountFolders(configuration: dependencies.accounts)
        guard owner.root.preparedSessions.manager.localSessionCount() == 0 else {
            throw BackendHOSTFailure.remote("Existing in-app sessions still require their original account owner.")
        }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/TerminalDeckSessionHostHelper")
        let marketing = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.20.2") + "-host3"
        // One folder per helper build (QUIT); the 77 MB hash runs off the main thread.
        let version = try await Task.detached(priority: .userInitiated) { try BackendHOSTLaunchAgent.buildVersion(marketing: marketing, helper: helper) }.value
        let directory = owner.configuration.homeDirectory.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let corePlan = try BackendHOSTLaunchAgent(paths: BackendHOSTPaths(dataDirectory: owner.root.dataRoot),
            version: version, launchAgentsDirectory: directory)
        let paths = try BackendHOSTPaths(dataDirectory: owner.root.dataRoot, namespace: "agents")
        let agentsPlan = try BackendHOSTLaunchAgent(paths: paths, version: version, launchAgentsDirectory: directory)
        self.agentsPlan = agentsPlan; helperURL = helper; agentsPaths = paths
        coreClient = client(try await corePlan.connectAfterCoreExit(sourceHelper: helper, agents: paths))
        coreBridge = makeBridge(coreClient)
        coreBridge.onHostLost(NativeHOSTLost.announce) // core and agents (its peer) alike
        let initial = BackendHOSTReadyBarrier()
        try owner.root.preparedSessions.manager.installHOSTFrontend(coreBridge, ready: { initial.finish(nil) },
            disconnected: { initial.finish(BackendHOSTFailure.unavailable) })
        try await initial.wait(timeout: 60)

        managedClient = client(try await agentsPlan.connectOrStart(sourceHelper: helper))
        // Original configuration/catalogue, no local account adapter was started.
        let specs = try await owner.wired(owner.core, "core").sessionEndpoint.catalogue()
        guard !specs.isEmpty else { throw BackendHOSTFailure.unavailable }
        resourcesConfigureAttempted = true
        try await BackendHOSTBootstrap.configure(client: managedClient,
            configuration: BackendHOSTConfiguration(configuration: owner.configuration, tools: specs))
        resourcesConfigured = true
        let active = managedClient!, manager = owner.root.preparedSessions.manager, core = try owner.wired(owner.core, "core").control
        let tools = BackendHOSTSessionToolRelay(core: core, currentAdoption: { call in
            // 30 Oct (Decker: every tools_run answered "The attached app could not authorize or complete this tool"):
            // the same checks as before, each now naming itself, so a refusal says which one failed.
            func refuse(_ check: String) -> Error {
                NSLog("[native graph] relayed tool %@ for session %@ refused: %@", call.toolID, call.context.sessionID, check)
                return BackendHOSTSessionToolRelay.Refusal(check: check)
            }
            let actual = try await Task.detached { try active.snapshot(call.context.sessionID) }.value
            let grant = try await active.resource("mcp.caller.current", arguments: .object([.init("callID", .string(call.id.uuidString))]))
            guard let actual else { throw refuse("the session helper does not know this session") }
            guard manager.isHostedSession(actual.session.id) else { throw refuse("this session is not one the session helper holds") }
            guard BackendHOSTSessionToolRelay.matchesCurrentSession(actual,
                    current: manager.list().first(where: { $0.id == actual.session.id }), pid: manager.pidOf(actual.session.id)) else {
                throw refuse("the session changed since it started (process, account or conversation)")
            }
            guard actual.session.exitCode == nil, let input = actual.input, let scope = actual.scope else { throw refuse("the session has ended or carries no launch record") }
            guard input.chat == true || (input.taskID == nil && input.taskProject == nil) else { throw refuse("a task terminal session cannot use relayed tools") }
            guard scope.deviceBoundary == nil, scope.appFenceID == nil, !scope.isAppComposed else { throw refuse("the session runs inside a fence or a device boundary") }
            guard !call.context.cancellation.isCancelled else { throw CancellationError() }
            guard grant["callID"].string == call.id.uuidString, grant["toolID"].string == call.toolID,
                  grant["wireName"].string == call.wireName, grant["tier"].string == call.tier.rawValue else { throw refuse("the helper's record of this call names another tool") }
            guard grant["argumentsDigest"].string == (try BackendHOSTSessionToolRelay.argumentsDigest(call.arguments)) else { throw refuse("the call's arguments differ from the helper's record") }
            guard grant["sessionID"].string == call.context.sessionID, grant["machineID"].string == call.context.machineID,
                  grant["projectRoot"].string == call.context.projectRoot, grant["taskProject"].string == call.taskProject else { throw refuse("the helper's record of this call names another session or project") }
            guard let currentTools = grant["tools"].elements?.compactMap(\.string),
                  let currentTiers = grant["tiers"].elements?.compactMap({ $0.string.flatMap(BackendMCPTier.init(rawValue:)) }),
                  currentTools.count == grant["tools"].elements?.count, currentTiers.count == grant["tiers"].elements?.count else { throw refuse("the helper's grant for this session could not be read") }
            let original = BackendTAGToolPolicy.filter(BackendTAGToolPolicy.sessionNames(taskID: input.taskID), server: "deck-control",
                allowed: input.allowedTools, denied: input.deniedTools ?? [])
            // These are the ORIGINAL ordinary lease tiers, further intersected
            // with the authenticated persisted grant by the real relay/core gate.
            return .init(snapshot: actual, currentTools: original.intersection(currentTools), currentTiers: Set(currentTiers), originalSessionLimits: .missing)
        })
        let handler: BackendHOSTAppRelayClient.Handler = { try await tools.invoke($0) }
        relayHandler = handler
        relay = try BackendHOSTAppRelayClient(paths: paths, host: active.hello, handler: handler)
        let authority = try owner.wired(owner.authority, "authority"), providers = owner.root.providers, relays = relayBox
        appAccounts = BackendHOSTAccountControlApp(client: active, currentAttachment: { relays.attachmentID() },
            authorizeRPC: { try await authority.authorizeSessionRPC($0, channel: $1, arguments: $2) },
            authorizeMetadata: { try authority.authorizeMetadata($0) }, authorizeMutation: { try authority.authorizeMutation($0) },
            originalProviders: providers)
        let app = appAccounts!
        let appSignIn = BackendHOSTAppAccountSignIn(configuration: dependencies.accounts, frontend: app.facade, providers: providers,
            executor: dependencies.authCommands, sessionsUsing: { id in manager.list().filter { $0.exitCode == nil && $0.profileId == id }.map(\.title) },
            authorizeMetadata: { try authority.authorizeMetadata($0) }, authorizeMutation: { try authority.authorizeMutation($0) })
        self.appSignIn = appSignIn
        NativeAPIAccounts.shared.configure { id, key in
            try await appSignIn.apiAccounts.storeNativeKey(id: id, key: key, context: authority.localContext())
        }
        await app.facade.installLocalAccountHandler { channel, args, context, olderHost in
            if channel == "profiles:vault-status" { return try accountRecovery.status() }
            if channel == "profiles:vault-recover" {
                guard context.caller == .nativeApp else { throw BackendAccountFailure("Click Allow login store in Settings › Coding AIs on this Mac.") }
                return try accountRecovery.recover()
            }
            return try await appSignIn.invoke(channel, args: args, context: context, olderHost: olderHost)
        }
        BackendHOSTFrontendResources.bindAuthorization(app: app) { context, channel, arguments, mutation in
            try await app.authority.recheckExternal(channel: channel, args: arguments, context: context, mutation: mutation)
        }
        let controlsValue = BackendHOSTResourceFactory.AppControls(
            verifyClaims: { [weak self, weak owner = self.owner] rows, cancellation in
                guard !cancellation.isCancelled, let self, let owner else { throw BackendHOSTFailure.unavailable }
                return try await self.verifyOrdinaryAdoption(rows, owner: owner)
            }, hookContext: { [weak owner = self.owner] event, cancellation in
                guard !cancellation.isCancelled, let owner else { throw BackendHOSTFailure.unavailable }
                return try await BackendHOSTFrontendResources.hookContext(event: event, joins: owner.joins)
            }, openLink: { [weak owner = self.owner] url, session, cancellation in
                guard !cancellation.isCancelled, let owner else { throw BackendHOSTFailure.unavailable }
                return await owner.openForSession(url: url.absoluteString, sessionID: session)
            }, authorizeAccount: { arguments, cancellation in
                try await app.authority.control(arguments: arguments, cancellation: cancellation)
            })
        appControls = controlsValue
        BackendHOSTResourceFactory.installAppControls(client: relay, controls: controlsValue)
        let peer = makeBridge(active), hydrated = BackendHOSTReadyBarrier()
        try coreBridge.addPeer(peer, ready: { hydrated.finish(nil) }); managedBridge = peer
        try await hydrated.wait(timeout: 60)
        let context = try authority.localContext() // actual app startup owner, never a key fallback
        let settings = NativeRPCValue.object(dependencies.hookSettingsFiles.map { .init($0.key, .string($0.value.path)) })
        let hooks = NativeRPCValue.object([.init("settings", settings), .init("offer", .string(dependencies.hookOfferFile.path))])
        hooksArguments = hooks
        _ = try await active.resource("hooks.configure", arguments: hooks)
        // Helper crash recovery: when this helper is gone for good, a new one is started and every owner follows.
        peer.onHostGone { [weak self] in Task { @MainActor in await self?.reconnect() } }
        controls = try await BackendHOSTProfileScope.withContext(context) {
            try await BackendHOSTFrontendResources.makeControls(client: active, app: app, manager: manager)
        }
        // 4 Nov: the launch tidy of account names, through this session host's own list and rename (an older host
        // knows both), so an account that only carried another login's name stops hiding from the list.
        Task.detached(priority: .utility) {
            _ = await BackendHOSTProfileScope.withContext(context) {
                await appSignIn.tidy(context: context) { line in Task { @MainActor in AppModel.shared.engine.log.note(line) } }
            }
        }
        let parts = try await BackendHOSTAccountSessionParts(managedClient: active, configuration: owner.configuration,
            app: app, externalPID: { manager.pidOf($0) }, profileContext: { try BackendHOSTProfileScope.requireCurrent() })
        let ordinary = try await BackendHOSTToolLeaseProxy(client: active)
        let project = try await BackendHOSTProjectToolProxy(client: active, source: projectSource, machineID: machineID,
            inheritedEnvironment: owner.configuration.inheritedEnvironment)
        // Deferred sessions retain the ORIGINAL app endpoint and project owner.
        // Account/profile/vault/broker writers remain solely in the helper.
        let localOrdinary = try BackendSessionToolLeases(endpoint: owner.wired(owner.core, "core").sessionEndpoint, userData: owner.root.dataRoot)
        let localProject = try BackendProjectToolComposition(source: dependencies.projectMCPSource,
            userData: owner.root.dataRoot, inheritedEnvironment: owner.configuration.inheritedEnvironment)
        let mixed = try BackendHOSTMixedToolLeases(localOrdinary: localOrdinary, localProject: localProject,
            hostOrdinary: ordinary, hostProject: project)
        let configuration = owner.configuration, machine = machineID
        constructionStarted = true
        return try await owner.root.installHostedSessions(parts: parts, ordinaryTools: mixed, projectTools: mixed,
            machineID: machine, createResolved: { [weak self] input, spawn, account, context in
                guard !(input.chat == true && active.hello.chatService == 1 && context.deviceBoundary == nil && context.appFenceID == nil && !context.isAppComposed) && !BackendHOSTMixedLeaseRoute.eligible(input, context) else {
                    guard let self else { throw BackendHOSTFailure.unavailable }
                    let shim = await MainActor.run { self.installedShim.map { ($0.directory, $0.browser) } }
                    return try await peer.createManagedAsync(input: input, spawn: spawn, inheritedEnvironment: configuration.inheritedEnvironment,
                        openShim: shim, context: context, accountHandle: account.reservationID,
                        leaseIDs: context.hostLeaseIDs, machineID: context.hostMachineID)
                }
                return nil
            }, controls: controls, dependencies: dependencies)
    }
    /// A failed helper start may return to the original account graph only
    /// before its prepared owner is claimed and after any empty helper writer
    /// has actually released. Occupied helpers are preserved.
    func abandonForLocalFallback() async throws -> Bool {
        var localSelected = false
        defer {
            // A refused early fallback must not retain a startup-only watch or
            // make the failed app appear to have a prepared session owner.
            if !localSelected, managedClient == nil {
                owner.root.preparedSessions.manager.detachHOSTFrontend()
                coreClient?.detach()
                if Self.current === self { Self.current = nil }
            }
        }
        guard !constructionStarted else { return false }
        if managedClient == nil {
            let agents = try BackendHOSTPaths(dataDirectory: owner.root.dataRoot, namespace: "agents")
            guard try !BackendHOSTLaunchAgent.agentsOwnerMayBeHeld(agents) else { return false }
        }
        // A lost configure reply can leave a live account writer. Never infer
        // an unconfigured helper from an empty PTY list or a failed reply.
        guard !resourcesConfigureAttempted || resourcesConfigured else { return false }
        if let managedClient {
            let live = try await Task.detached { try managedClient.list() }.value
            guard !live.contains(where: { $0.exitCode == nil }) else { return false }
            if resourcesConfigured {
                try await Task.detached { try managedClient.stopAll() }.value
                _ = try await managedClient.resource("resources.shutdown", arguments: .object([]))
                let closed = try await managedClient.resource("resources.closed", arguments: .object([]))
                guard closed["closed"].bool == true else { return false }
            }
        }
        owner.root.preparedSessions.manager.detachHOSTFrontend()
        relay?.detach(); await appAccounts?.facade.close(); coreClient?.detach(); managedClient?.detach()
        localSelected = true
        return true
    }
    func keepForExit() async throws {
        guard !detached else { return }
        // A failed start already gave back what it held; there is nothing of this attempt to detach.
        guard let owner = liveOwner else { return }
        guard let sessions = owner.sessions else {
            throw BackendHOSTFailure.remote("Session ownership is still starting; quitting was held without stopping hosted processes.")
        }
        let result = await sessions.applyQuit(keep: true)
        switch result {
        case .detached: detached = true; owner.hostCore?.noteManagedDetachment()
        case .blocked(let error): throw BackendHOSTFailure.remote(error)
        default: throw BackendHOSTFailure.unavailable
        }
    }
    func stopAppAccountSignIns() async throws {
        guard let appSignIn else { return }
        // The production graph is gone (a failed start): its sign-in owners went with it.
        guard let owner = liveOwner else { return }
        guard let authority = owner.authority else { throw BackendAccountFailure("The sign-in is still closing. Try Quit again in a moment.") }
        try await appSignIn.shutdown(context: authority.localContext())
    }
    func acceptOpenShim(_ value: BackendMacAppHandoffShimInstalled?) { installedShim = value }
    func bindAndAdopt() async throws {
        let sessions = try owner.wired(owner.sessions, "sessions")
        await sessions.restore.setHostedClaims { [manager = sessions.manager] in manager.list().filter { manager.isHostedSession($0.id) } }
        for client in [coreClient!, managedClient!] {
            for meta in client.cachedSessions() {
                if meta.chat == true && meta.exitCode != nil { continue }
                guard let snapshot = try client.snapshot(meta.id), let input = snapshot.input, let scope = snapshot.scope else { throw BackendHOSTFailure.unavailable }
                try await sessions.ledger.started(snapshot.session, input: input,
                    context: .init(deviceBoundary: scope.deviceBoundary, appFenceID: scope.appFenceID,
                        rememberTab: scope.rememberTab, isAppComposed: scope.isAppComposed, requiresInAppOwner: true))
            }
        }
        // 28 Oct (bug A): a kept session that moved to another conversation (/clear) before this app started is
        // written down with the conversation it is in now, so a later restore resumes the right one.
        await DeckMemorySessionCenter.shared?.reconcileConversations()
    }
    func refreshActualCatalogue() async throws {
        let tools = try await owner.wired(owner.core, "core").sessionEndpoint.catalogue().map(BackendHOSTConfiguration.Tool.init)
        _ = try await managedClient.resource("mcp.catalogue.replace", arguments: .object([.init("tools", try NativeRPCValue.parseJSON(JSONEncoder().encode(tools)))]))
    }
    func usage(_ account: BackendUsageAccount, cancellation: BackendMCPCancellation?) async -> BackendUsageProbe.Outcome {
        await BackendHOSTFrontendResources.usageProbe(client: managedClient, account: account, cancellation: cancellation)
    }
    private func verifyOrdinaryAdoption(_ rows: [BackendSessionMeta], owner: NativeCompositionProduction) async throws -> Bool {
        guard let sessions = owner.sessions else { throw BackendHOSTFailure.unavailable }
        let current = sessions.manager.list()
        for row in rows where row.exitCode == nil {
            guard let copy = try managedClient.snapshot(row.id), copy.session == row,
                  copy.pid == sessions.manager.pidOf(row.id), current.contains(where: { $0 == row }),
                  let input = copy.input, let scope = copy.scope, (input.chat == true || (input.taskID == nil && input.taskProject == nil)),
                  scope.deviceBoundary == nil, (scope.hostedTask == true && input.chat == true || (scope.appFenceID == nil && !scope.isAppComposed)) else { return false }
            if scope.rememberTab {
                let saved = try await owner.root.state.ledgerGet(row.id)
                guard saved["cwd"].string == row.cwd, saved["tabKey"].string == row.tabKey,
                      saved["profileId"].string == row.profileId else { return false }
            }
        }
        return true
    }
    /// L8 (11 Oct, Asad: "about helper I don't care what we need to touch, I need it fixed"). The session helper
    /// died (killed, crashed) or was restarted on purpose. Without a restart: start a new helper with this build (the
    /// same launch-agent path as the app's start, under the same owner lock and secret), move the ONE client every
    /// owner holds onto it (accounts, tool leases, project tools, usage, the launcher's bridge all follow), set it up
    /// as at start (configuration and tool catalogue, hooks, a new app relay with the same controls), re-attach the
    /// session stream, then give back what the dead helper took: the person's own sessions are started again in the
    /// new helper, each in its saved conversation (the restore path), and Hoot is woken. Sessions the app runs itself
    /// (agents, tasks) were never in the helper and go on. Nothing runs after a quit/detach or while one runs.
    ///
    /// 28 Oct (bug A, Asad: the app was dead for 9 minutes after a keeper restart): the reconnect ran INSIDE the
    /// restart tool call. The caller lived in the old keeper, so ending the keeper ended the caller, its request was
    /// closed, the call was cancelled, and the reconnect with it (CancellationError on its first wait); an explicit
    /// restart allowed one attempt, and the host-gone trigger only waited for that one. Now the reconnect is its own
    /// task that no caller can cancel; every caller (the tool, host gone) waits for the same one; it retries five
    /// times quickly and then every 30 s until a helper answers, and it picks up where a failed attempt stopped.
    func reconnect() async {
        if let running = reconnectTask { await running.value; return }
        guard !detached, !AppModel.shared.isTerminating, !NativeSVResident.shared.explicitStop,
              agentsPlan != nil, helperURL != nil, agentsPaths != nil, managedClient != nil, managedBridge != nil,
              relayHandler != nil, appControls != nil else { return }
        let task = Task { @MainActor [weak self] in guard let self else { return }; await self.runReconnect() }
        reconnectTask = task
        reconnecting = true
        await task.value
        reconnecting = false
        reconnectTask = nil
    }
    private func runReconnect() async {
        guard let agentsPlan, let helperURL, let agentsPaths, let managedClient, let managedBridge,
              let relayHandler, let appControls else { return }
        let note: (String) -> Void = { NativeCompositionRoot.note("helper reconnect: " + $0) }
        note("the session helper is gone; starting a new one (no app restart)")
        var plan = NativeHOSTReconnectPlan()
        var adopted = false          // this reconnect already moved the client onto a new helper
        var held: [String] = []      // the person's sessions put on hold, kept across attempts
        var attempt = 0
        while true {
            attempt += 1
            guard !detached, !AppModel.shared.isTerminating, !NativeSVResident.shared.explicitStop else { return }
            do {
                // Freeze launches before adopt/useHost can deliver old exit/removal events.
                if !adopted, restartLaunches.isEmpty, let sessions = owner.sessions {
                    await DeckMemorySessionCenter.shared?.reconcileConversations()
                    restartLaunches = try await sessions.restore.snapshotForHostRestart(managedBridge.liveIDs(), strict: false)
                }
                let started = try await agentsPlan.connectOrStart(sourceHelper: helperURL, pruneStaleHelpers: !explicitRestart)
                let fresh = client(started)
                if fresh.hello.instance == managedClient.hello.instance {
                    fresh.detach()
                    // The same helper answers again and nothing was moved yet: a passing drop, nothing was lost.
                    guard adopted else { return }
                } else {
                    try managedClient.adopt(fresh); fresh.detach(); adopted = true
                }
                let specs = try await owner.wired(owner.core, "core").sessionEndpoint.catalogue()
                try await BackendHOSTBootstrap.configure(client: managedClient,
                    configuration: BackendHOSTConfiguration(configuration: owner.configuration, tools: specs))
                if let hooksArguments { _ = try await managedClient.resource("hooks.configure", arguments: hooksArguments) }
                if managedClient.hello.chatService == 1, let sessions = owner.sessions, let chats = owner.sessionChats {
                    try await chats.useHost(managedClient)
                    await sessions.setChatHost(managedClient)
                    await sessions.launch.setChatSurvival(true)
                    await sessions.launcher.setHostedChatAttachment { meta in try await chats.adoptHostedSession(meta) }
                }
                let newRelay = try BackendHOSTAppRelayClient(paths: agentsPaths, host: managedClient.hello, handler: relayHandler)
                BackendHOSTResourceFactory.installAppControls(client: newRelay, controls: appControls)
                let old = relay; relay = newRelay; old?.detach()
                // The person's sessions the dead helper took: their saved launch (folder, AI, conversation) is put on
                // hold BEFORE they are marked ended, then each is started again from it below.
                if !restartLaunches.isEmpty {
                    held += try await owner.sessions?.restore.holdAfterHostRestart(restartLaunches) ?? []
                    restartLaunches = []
                }
                let ready = BackendHOSTReadyBarrier()
                let gone = try managedBridge.reattach(ready: { ready.finish(nil) })
                try await ready.wait(timeout: 60)
                reconnects += 1
                owner.hostCore?.refreshStatus()
                await owner.sessionChats?.retireFinishedJobs() // finished jobs the new helper still lists leave the list
                note("new session helper pid \(managedClient.hello.hostPID), \(managedClient.hello.hostVersion), attempt \(attempt); \(gone.count) session(s) of the old one to start again")
                if !held.isEmpty, let sessions = owner.sessions {
                    var again = 0
                    for key in held {
                        do {
                            // The same owner context the start-up restore runs in (profile reads go through the new helper).
                            let remaining = try await BackendHOSTProfileScope.withContext(try owner.wired(owner.authority, "authority").localContext()) {
                                try await sessions.restore.retryHeld(key)
                            }
                            if let still = remaining.first(where: { $0.key == key }) { note("a session was not started again: " + still.reason) } else { again += 1 }
                        } catch { note("a session could not be started again: " + error.localizedDescription) }
                    }
                    note("\(again) of \(held.count) session(s) started again in their saved conversation")
                }
                await NativeHootChatModel.restoreOutboxes()
                if let runtime = owner.hoot?.runtime {
                    do { let state = try await runtime.ensure(); note(state.status == .running ? "Hoot is awake again" : "Hoot did not wake: " + (state.problem ?? "stopped")) }
                    catch { note("Hoot did not wake: " + error.localizedDescription) }
                }
                DeckReconnect.shared.back("the session helper is running again")
                return
            } catch {
                if let line = plan.failed(attempt: attempt, error.localizedDescription) { note(line) }
                try? await Task.sleep(for: .seconds(NativeHOSTReconnectPlan.pause(after: attempt)))
            }
        }
    }
    private func makeBridge(_ value: BackendHOSTClient) -> BackendHOSTManagerBridge {
        .init(client: value, write: { try value.write($0, bytes: $1, expectedCreatedAt: $2) },
            drain: { try await value.drain(timeoutMilliseconds: $0) }, setWatched: { try value.setWatched($0) },
            stampIndependent: { $0.ownerIndependent = true })
    }
    private func client(_ value: BackendHOSTLaunchAgent.Result) -> BackendHOSTClient {
        switch value { case .attached(let client, _), .started(let client): return client }
    }
}
/// The app relay the account door uses NOW (replaced together with a crashed helper).
final class NativeHOSTRelayBox: @unchecked Sendable {
    private let lock = NSLock()
    private var relay: BackendHOSTAppRelayClient?
    func set(_ value: BackendHOSTAppRelayClient?) { lock.withLock { relay = value } }
    func attachmentID() -> UUID? { lock.withLock { relay }?.attachmentID() }
}
#endif
