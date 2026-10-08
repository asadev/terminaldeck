import AppKit
import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// The scraping caller of the running assets.* call: the S4 asset transport takes
/// a synchronous caller, so the policy sets it for the duration of that one call.
enum NativeCompositionAssetCaller {
    @TaskLocal static var current: BackendBrowserScrapingCaller?
    /// No running call: a caller every grant check refuses (remote, unattended).
    static let none = BackendBrowserScrapingCaller(ownerID: "no-current-asset-call", attended: false, remote: true, rpc: nil)
}

/// TS native shell (mode.ts NATIVE_REFUSAL.popout, index.ts sessionWindowTools with
/// `popouts` null): sessions have no windows of their own in this app yet.
struct NativeCompositionSessionWindows: BackendDeckToolsSessionsWindows {
    func view(context: BackendMCPCallContext) async throws -> NativeRPCValue {
        .object([.init("windows", .array([])), .init("displays", .array([]))])
    }
    func open(sessionID: String, displayID: Double?, context: BackendMCPCallContext) async throws -> NativeRPCValue {
        .object([.init("ok", .bool(false)), .init("message", .string("This build cannot give a session its own window.")), .init("sessionId", .string(sessionID))])
    }
    func dock(sessionID: String, context: BackendMCPCallContext) async throws -> NativeRPCValue {
        .object([.init("ok", .bool(false)), .init("message", .string("That session is not in a window of its own.")), .init("sessionId", .string(sessionID))])
    }
}

extension NativeCompositionProduction {
    /// OS bodies (power, voice, notification evidence, app log), then the 128
    /// deck-tools definitions, the Safari and task/server rows, all entered
    /// through the one core door; machines register last over the shared ids.
    func installDeckToolsAndOS() async throws {
        let os = try NativeCompositionOS.make(backend: root, home: configuration.homeDirectory.path,
            executor: files.processExecutor, cipher: BackendAccountKeychainCipher(appName: configuration.appName),
            bundleIdentifier: Bundle.main.bundleIdentifier)
        try await NativeCompositionOS.install(backend: root, services: os, oldOwnersDisabled: true)
        osServices = os
        guard let access = browserAccess, let surface = coreSurface, let restore = restoreContext, let stage = tourStage,
              let hoot, let serversOwner, let routinesOwner, let dev = files.dev, let artifacts = files.artifacts,
              let customAgents = clients.customAgents else {
            throw NativeRPCError(code: "composition-incomplete", message: "deck-tools need every owner installed before them.")
        }
        let browser = try NativeCompositionRoot.shared.browserForComposition()
        let gate = try joins.deckToolsGate()
        // Declared before deviceFolders' closure uses it (Swift 6.3 refuses a capture before declaration).
        let authority = self.authority!, sessions = self.sessions!, usage = self.usage!, registry = root.registry
        let deviceFolders = remoteTrust.map { BackendCompositionDeckToolsDeviceFolders(trust: $0, authority: authority).scopeFolders }
        let scope = BackendCompositionDeckToolsScope(gate: gate, deviceFolders: deviceFolders, workspaces: files.workspaces,
            browserSlots: { session, machine in
                await MainActor.run {
                    browser.bindings.bindings(for: .init(ownerID: BackendCompositionRoot.appOwnerID, managesWindows: true))
                        .of(.init(sessionId: session, machineId: machine)).map(\.name)
                }
            })
        let appAccess = BackendCompositionDeckToolsAccess.appAccess(scope: scope)
        let runtime = BackendCompositionDeckToolsSessionsRuntime(scope: scope)
        var definitions: [BackendDeckToolsDefinition] = []

        // Root: files, projects, assets, tour.
        let filesRuntime = BackendCompositionDeckToolsFilesRuntime(scope: scope, restoreContext: restore)
        definitions += try BackendDeckToolsFiles.definitions(service: .init(files: files.files, transfers: files.transfers), runtime: filesRuntime)
        definitions += try BackendDeckToolsProjects.definitions(services: .init(projects: files.projects, git: files.git, dev: dev,
            ports: files.ports, dashboards: files.dashboards, artifacts: artifacts), runtime: filesRuntime)
        let assetDomain = BackendS4AssetsDomain(userData: root.dataRoot, store: browser.scrapingStore,
            transport: BackendS4AssetsHooksTransport(hooks: browser.assetHooks, caller: { NativeCompositionAssetCaller.current ?? NativeCompositionAssetCaller.none }),
            profileExists: { id in
                if id == BackendBrowserAssetHooks.publicProfileID { return true }
                return (try? await browser.profiles.requireProfile(id)) != nil
            })
        definitions += try BackendDeckToolsAssets.definitions(domain: assetDomain, runtime: BackendCompositionDeckToolsAssetRuntime(gate: gate)).map { definition in
            Self.replacing(definition) { native, args in
                let caller = try await access.scrapingCaller(native)
                return try await NativeCompositionAssetCaller.$current.withValue(caller) { try await definition.handler(native, args) }
            }
        }
        let evidence = BackendDeckToolsTourNativeEvidence(surface: surface, sessionViews: { authority.sessionViews() },
            scrollback: { id in sessions.manager.scrollback(id) ?? "" })
        definitions += try BackendDeckToolsTourTool.definitions(stage: stage, runtime: BackendCompositionDeckToolsTourRuntime(gate: gate, evidence: evidence))

        // Sessions / agents / accounts / windows; the one lift definition goes to the workers below.
        let sessionsSurface = BackendDeckToolsSessionsNativeSurface(lifecycle: sessions.lifecycle, rpc: sessions.sessionRPC,
            profiles: sessions.profiles, cost: usage.cost, search: usage.search, insights: usage.insights,
            context: { try await authority.rpc($0) },
            statusRecord: { id, native in _ = try await authority.requireSession(id, native: native); return authority.statusRecord(id) },
            planLimits: { id, _ in await usage.usage.plan(sessionID: id) },
            announceRenamed: { id, title in try await registry.publish("session:renamed", arguments: [.string(id), .string(title)]) },
            tellSwitched: { old, meta, note in try await registry.publish("session:switched", arguments: [.string(old), meta, .string(note)]) },
            sessionView: { id, native in
                _ = try await authority.requireSession(id, native: native)
                guard let row = authority.sessionViews().first(where: { $0["id"].string == id }) else { throw BackendSessionFailure.missingSession }
                return row
            },
            cancelArmed: { id, native in
                let armed = try await sessions.sessionRPC.invoke("session:switch-armed", args: [], context: try await authority.rpc(native))
                let had = armed.elements?.contains { $0["sessionId"].string == id } ?? false
                await sessions.deferred.cancel(sessionID: id); return had
            },
            launchContext: { [joins] device, cwd, _ in
                guard let device else { return .init(rememberTab: true) }
                return .init(deviceBoundary: try await joins.deviceBoundary(deviceID: device, folder: cwd), rememberTab: true)
            })
        let controls = BackendCompositionDeckToolsAgentControls(access: .local(manager: sessions.manager, attribution: sessions.attribution, store: root.state),
            transcripts: BackendCompositionDeckToolsAgentControls.transcriptScope(configuration: configuration, dataRoot: root.dataRoot),
            environment: configuration.inheritedEnvironment)
        joins.bindAgentControls { id, control, value in _ = try await controls.setAgentControl(sessionID: id, control: control, value: value) }
        try await installAppChannels(controls: controls)
        definitions += try BackendDeckToolsSessionsArea.sessionDefinitions(runtime: runtime, surface: sessionsSurface)
        definitions += try BackendDeckToolsSessionsArea.agentDefinitions(runtime: runtime, agents: BackendCompositionDeckToolsAgents(gate: gate,
            providers: root.providers, customAgents: customAgents, controls: controls))
        let accounts = BackendDeckToolsSessionsNativeAccounts(rpc: sessions.accountRPC, profiles: sessions.profiles,
            context: { try await authority.rpc($0) },
            extras: BackendCompositionDeckToolsAccountExtras(signIn: sessions.signIn, shared: sessions.sharedHistory, profiles: sessions.profiles, authority: authority))
        definitions += try BackendDeckToolsSessionsArea.accountDefinitions(runtime: runtime, accounts: accounts, sessions: sessionsSurface)
        definitions += try BackendDeckToolsSessionsArea.windowDefinitions(runtime: runtime, windows: NativeCompositionSessionWindows())
        let lift = try BackendDeckToolsSessionsArea.liftDefinitions(runtime: runtime, requests: BackendCompositionDeckToolsLiftRequests(gate: gate,
            inbox: { ask, native in try await access.fileLift(ask, native: native) }))

        // App tools.
        let diagnostics = NativeCompositionDiagnostics.make(backend: root, sessions: sessions, log: os.log, executor: files.processExecutor,
            configuration: engineConfiguration, environment: configuration.inheritedEnvironment, home: configuration.homeDirectory.path)
        try await NativeCompositionDiagnostics.install(backend: root, services: diagnostics)
        await root.observeCalls(diagnostics.metrics)
        let setup = try await installSetup(detection: diagnostics.detection)
        definitions += try appDefinitions(access: appAccess, gate: gate, os: os, browser: browser, sessions: sessions, usage: usage,
            setup: setup, diagnostics: diagnostics)

        guard let github = clients.github, let githubAuth = clients.githubAuth else {
            throw NativeRPCError(code: "unavailable", message: "The existing GitHub account service is unavailable.")
        }
        let githubTools = BackendGitHubNativeTools(home: configuration.homeDirectory.path,
            loginPath: { [root] in try await root.providers.loginPath() })
        let githubWorkspace = BackendGHComposition(authenticator: githubAuth,
            repositoryService: github, tools: githubTools,
            environment: configuration.inheritedEnvironment, registry: root.registry,
            addProject: { [root] path in try await root.state.addProject(path) })
        _ = try await BackendGHRegistration.install(root: root, composition: githubWorkspace,
            bindings: joins, access: appAccess, repositoryService: github)
        try await installINT2HootChatTools(access: appAccess)
        await root.installReceiverTools(access: appAccess, joins: joins, github: githubWorkspace.service) // RCV
        try await installINT2PhoneAccess(access: appAccess)
        if SourceNamespace.agentSettingsEnabled { try await installINT2AGSTools(access: appAccess) }

        // Machines, servers, remote, devices, workers (+ the shared lift definition).
        definitions += try await BackendCompositionDeckToolsMachines.definitions(scope: scope, rpc: { try await access.rpc($0) },
            registry: registry, dataRoot: root.dataRoot, home: configuration.homeDirectory,
            machines: machineDefinitions, serverShells: serversOwner.shells, devices: try await installDevices().tools,
            workers: browser.workers, workerMetadata: BackendCompositionDeckToolsWorkerMetadata(browser: {
                try await MainActor.run { try NativeCompositionRoot.shared.browserForComposition().service }
            }, signIns: browser.signIns), liftRequest: lift)

        // One core door: deck-tools bundles by area; the six machine tools run through the machine
        // registration's own guard once it is installed (shared mode below).
        let machineIDs = BackendMachineRegistration.toolIDs
        let policies = definitions.map { definition -> BackendDeckCoreSecurityToolPolicy in
            guard machineIDs.contains(definition.spec.id) else { return joins.nativePolicy(definition) }
            return joins.nativePolicy(Self.replacing(definition) { [weak self] native, args in
                guard let guarded = await self?.machineOwner?.definitions.first(where: { $0.spec.id == definition.spec.id }) else {
                    throw NativeRPCError(code: "unavailable", message: "The native machines area has not been started.")
                }
                return try await guarded.handler(native, args)
            })
        }
        let bundles = try await root.installDeckTools(definitions: definitions, policies: policies)
        try joins.replaceContributions(owner: "deck-tools", bundles, policiesWrapped: true)
        try joins.replaceContributions(owner: "safari", [try await BackendCompositionCoreContributions.safari(server: root.mcp, joins: joins)], policiesWrapped: true)
        try joins.replaceContributions(owner: "tasks-servers", [try await BackendCompositionCoreContributions.supplement(server: root.mcp, joins: joins,
            knowledgeFromClients: clients.domains.contains("knowledge") && clients.knowledge != nil)], policiesWrapped: true)
        try await installINT2WatchCatalogue()
        guard let panels = machinePending?.panels else { throw NativeRPCError(code: "composition-incomplete", message: "Phone panels need the existing machine registry.") }
        try await installINT2PhonePanels(panels: panels)
        try await registerMachines()
        try await installBrowserChannels()
        _ = sessions; _ = hoot; _ = routinesOwner
    }

    static func replacing(_ definition: BackendDeckToolsDefinition, handler: @escaping BackendNativeMCPServer.Handler) -> BackendDeckToolsDefinition {
        .init(spec: definition.spec, title: definition.title, index: definition.index, aliases: definition.aliases,
              audience: definition.audience, keyIndex: definition.keyIndex, keyGrant: definition.keyGrant, handler: handler)
    }
}
