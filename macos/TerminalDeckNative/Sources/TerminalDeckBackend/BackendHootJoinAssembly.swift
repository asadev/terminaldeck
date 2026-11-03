import Foundation
import TerminalDeckNativeCore

/// index.ts `registerCopilotFolderIpc` dependencies over the one settings store
/// (`copilot.home`), the one desk runtime and the shared Home action writer.
/// The picker is the app's free-standing AppKit Open panel (no parent sheet).
public struct BackendHootJoinFolderSupply: BackendCopilotFolderDependencies {
    public static let homeSetting = RNMHootSettingsMigration.homeKey
    private let dataRoot: String
    private let settings: BackendAppSettingsStore
    private let running: @Sendable () async -> String?
    private let picker: @Sendable (String) async throws -> String?
    public init(dataRoot: URL, settings: BackendAppSettingsStore,
                runningIn: @escaping @Sendable () async -> String?,
                pick: @escaping @Sendable (String) async throws -> String?) {
        self.dataRoot = dataRoot.standardizedFileURL.path; self.settings = settings; running = runningIn; picker = pick
    }
    public func userData() async throws -> String { dataRoot }
    public func read() async throws -> NativeRPCValue {
        let value = await settings.value(Self.homeSetting)
        return value == .missing ? .null : value
    }
    public func write(_ value: String?) async throws {
        _ = try await settings.patch(.object([.init(Self.homeSetting, value.map(NativeRPCValue.string) ?? .null)]))
    }
    public func runningIn() async -> String? { await running() }
    public func pick(defaultPath: String) async throws -> String? { try await picker(defaultPath) }
    public func homeDir() async -> String { FileManager.default.homeDirectoryForCurrentUser.path }
    public func log(_ entry: BackendCopilotAction) async {
        BackendCopilotHome.appendAction(BackendCopilotPaths(userData: dataRoot), entry)
    }
}

/// Request 8 in one call: build the single desk Hoot graph from the retained
/// session/deck-core/settings owners and install it as one inert area. The app
/// supplies only AppKit (panels, picker, navigation) and the evidence closures
/// named in hoot-HANDOFF.md. Nothing starts until `installed.registration.start()`.
public enum BackendHootJoinAssembly {
    public struct Inputs: Sendable {
        public let storageRoot: URL
        public let sessions: BackendCompositionSessions
        /// deck-core's one runtime: its security server, action log, consent
        /// broker and catalogue titles are the joins (no second door/writer).
        public let deckCore: BackendDeckCoreRuntime
        /// The Mac confinement owner; nil keeps the visible "not held" result.
        public let confinement: BackendMacConfinement?
        public let machineID: String
        /// AppKit Open panel for `copilot:folder:pick`; returns nil on cancel.
        public let pickFolder: @Sendable (String) async throws -> String?
        /// The app's installed transcript scope for the desk Hoot's account.
        public private(set) var transcriptScope: @Sendable () async throws -> NativeTranscriptScope
        public let reveal: (any BackendCopilotInspectRevealing)?
        /// Live-window check, normally `BackendCompositionAuthority.requireLocalUI`.
        public let window: @Sendable (NativeRPCContext) throws -> Void
        /// Home scopes installed on the app's other transcript readers; default:
        /// the desk scope's own list (it must carry Hoot's home scope).
        public private(set) var transcriptHomeScopes: (@Sendable () async -> [NativeTranscriptHomeScope])?
        /// Stops paired-device Hoot (`{ await frames.stop(); await runs.stopAll() }`)
        /// once the native remote host serves it; nil = no native phone runs exist.
        public let stopPhoneRuns: (@Sendable () async -> Void)?
        public let headlessPolicy: (@Sendable (BackendCreateSessionInput, BackendProviderSpec, BackendLaunchContext) async throws -> [String])?
        public let readAcknowledged: (@Sendable (RNMHootPaths.Folder) async throws -> Void)?
        public let headlessProvider: HootChatProvider
        public let readyDefaults: BackendHootReadyDefaults?
        /// HOOTFIX: the app's own startup/owner context for Hoot's internal
        /// profile reads when no request scope exists (phone frames, task
        /// briefs, idle liveness). A request's own context always wins.
        public let ownerContext: (@Sendable () throws -> NativeRPCContext)?
        public init(storageRoot: URL, sessions: BackendCompositionSessions, deckCore: BackendDeckCoreRuntime,
                    confinement: BackendMacConfinement?, machineID: String,
                    pickFolder: @escaping @Sendable (String) async throws -> String?,
                    transcriptScope: @escaping @Sendable () async throws -> NativeTranscriptScope,
                    reveal: (any BackendCopilotInspectRevealing)?,
                    window: @escaping @Sendable (NativeRPCContext) throws -> Void = BackendCompositionRoot.requireLocalUI,
                    transcriptHomeScopes: (@Sendable () async -> [NativeTranscriptHomeScope])? = nil,
                    stopPhoneRuns: (@Sendable () async -> Void)? = nil,
                    headlessPolicy: (@Sendable (BackendCreateSessionInput, BackendProviderSpec, BackendLaunchContext) async throws -> [String])? = nil,
                    headlessProvider: HootChatProvider = .claude,
                    readAcknowledged: (@Sendable (RNMHootPaths.Folder) async throws -> Void)? = nil,
                    readyDefaults: BackendHootReadyDefaults? = nil,
                    ownerContext: (@Sendable () throws -> NativeRPCContext)? = nil) {
            self.storageRoot = storageRoot; self.sessions = sessions; self.deckCore = deckCore; self.confinement = confinement
            self.machineID = machineID; self.pickFolder = pickFolder; self.transcriptScope = transcriptScope
            self.reveal = reveal; self.window = window; self.transcriptHomeScopes = transcriptHomeScopes; self.stopPhoneRuns = stopPhoneRuns
            self.headlessPolicy = headlessPolicy
            self.readAcknowledged = readAcknowledged
            self.headlessProvider = headlessProvider
            self.readyDefaults = readyDefaults
            self.ownerContext = ownerContext
        }
        /// HOOTFIX: the ONE copy used by the app root when it swaps in the
        /// assembled transcript readers. Every other input (ready defaults,
        /// owner context, provider, policy) is carried; a hand-written field
        /// copy dropped readyDefaults and left Hoot "awaiting integration".
        public func replacingTranscripts(scope: @escaping @Sendable () async throws -> NativeTranscriptScope,
                                         homeScopes: @escaping @Sendable () async -> [NativeTranscriptHomeScope]) -> Inputs {
            // A value copy: every field not named here is carried by construction.
            var copy = self
            copy.transcriptScope = scope; copy.transcriptHomeScopes = homeScopes
            return copy
        }
    }
    /// Everything the app and the other areas need afterwards.
    public struct Assembled: Sendable {
        public let registration: BackendHootRegistration.Installed
        /// Island/catcher owner IDs and their contexts for the panel bindings.
        public let authority: BackendHootJoinSourceAuthority
        /// The one desk runtime (remote fanout's `isCopilotSession`, deck-tools).
        public let runtime: BackendCopilotSessionRuntime
        public let boundary: BackendHootJoinSpawnBoundary
        public let joins: BackendHootJoinGraph
        public let menu: BackendHootMenuBar
        public let screenMonitor: BackendHootScreenMonitor
        /// Hoot's tool-call fence (only its own settings are refused), enforced on Hoot's own tool calls.
        public let policy: BackendHootPolicy
        /// HOOT-TASKS-SPLIT: one Hoot conversation and process per task, never the chat's.
        public let taskConversations: BackendHootTaskConversations
        /// Item 74: Hoot's own context window and plan limits for the phones' session ring (`hoot`, `hoot:task:<id>`).
        public let usage: BackendHootUsage
    }

    /// `ui` receives the authority so the island binding is created with
    /// `authority.islandOwnerID` and the catcher with `authority.catcherOwnerID`.
    @MainActor
    public static func install(in root: BackendCompositionRoot, inputs: Inputs,
                               screenMonitor: BackendHootScreenMonitor = BackendHootScreenMonitor(),
                               ui: (BackendHootJoinSourceAuthority) -> BackendHootJoinMenuSupply.UI) async throws -> Assembled {
        try await root.requireAssemblyOpen()
        let dataRoot = root.dataRoot.standardizedFileURL
        let storageRoot = inputs.storageRoot.standardizedFileURL
        let sessions = inputs.sessions
        let boundary = BackendHootJoinSpawnBoundary(hidden: .shared)
        let history = inputs.headlessProvider == .claude ? "hoot/chat.json" : "hoot/chat-\(inputs.headlessProvider.rawValue).json"
        let chat = try BackendHootChatStore(file: dataRoot.appendingPathComponent(history), provider: inputs.headlessProvider, consent: inputs.deckCore.consent)
        // Hoot's read-only deck tools never ask: the security server knows every tool's tier.
        let tierServer = inputs.deckCore.server
        await chat.setToolTier { name in await tierServer.control.policy(named: name)?.tool.tier }
        let defaults = inputs.readyDefaults
        let launchBinding = defaults.map { defaults in
            BackendAGSLaunchBinding(facts: BackendAGSSelectedAccountFacts(providers: root.providers,
                profiles: sessions.profiles, configuration: sessions.profiles.configuration,
                projectRoot: { folder in folder }),
                reserve: { try await sessions.sessionTools.reserveAgentSettingsFiles() },
                authorize: { input, settings in
                    try Task.checkCancellation()
                    let selected = try await defaults.read(projectPath: input.cwd, forConversation: true)
                    guard selected.provider.rawValue == settings.provider,
                          selected.profile?.id == input.profileId, selected.launchSettings == settings else {
                        throw NativeRPCError(code: "conflict", message: "Hoot's selected account or AI settings changed during launch. Keep the draft and try again.")
                    }
                })
        }
        let driver = BackendHootChatDriver(providers: root.providers, sessions: sessions,
            confinement: inputs.confinement, chat: chat, exposure: boundary.exposureHook, policy: inputs.headlessPolicy,
            readyDefaults: defaults, launchBinding: launchBinding, defaultProjectPath: RNMHootPaths(dataRoot: dataRoot).home.path,
            ownerContext: inputs.ownerContext)
        let deckCore = inputs.deckCore, providers = root.providers
        let records: any BackendCopilotSessionRecordsProviding
        if let confinement = inputs.confinement {
            records = try BackendHootJoinRecords(dataRoot: dataRoot, prove: {
                try await confinement.measureRecordsFence(path: try await providers.loginPath())
            })
        } else { records = BackendCopilotSessionUnavailableRecords() }
        let policy = BackendHootPolicy(settings: root.settings)
        // The retired "What Hoot may do" switches leave the settings file once (an older install may hold them).
        Task { await policy.removeRetiredSettings() }
        // SETTINGS-TRUTH lines 70 and 74: the saved permission mode is loaded now (phone and task turns follow it before
        // any chat view opens), and the old per-Hoot account key is removed (Hoot's account is its Who-uses-what row).
        if let defaults {
            let home = RNMHootPaths(dataRoot: dataRoot).home.path, owner = inputs.ownerContext
            Task {
                await defaults.removeLegacyAccounts()
                #if TD_HOST_ACCOUNT_BRIDGE
                if let context = try? owner?() {
                    await BackendHOSTProfileScope.withContext(context) { await defaults.loadSavedMode(projectPath: home) }
                    return
                }
                #endif
                _ = owner
                await defaults.loadSavedMode(projectPath: home)
            }
        }
        let door = try BackendCopilotSessionMCPDoor(endpoint: BackendCopilotSessionSecurityEndpoint(server: deckCore.server, plansOnly: {
                if let defaults { return await defaults.plansOnly }
                return false
            }, bypass: {
                if let defaults { return await defaults.bypassOn }
                return false
            }, beforeTool: { tool, arguments in try await policy.check(tool: tool, arguments: arguments) }),
            userData: dataRoot, machineID: inputs.machineID, titles: { deckCore.hootLayerTitles() })
        let settings = root.settings
        let runtime = BackendCopilotSessionRuntime(dependencies: .init(userData: dataRoot.path, storageDir: storageRoot.path,
            chosenFolder: {
                let value = await settings.value(BackendHootJoinFolderSupply.homeSetting)
                return value == .missing ? .null : value
            },
            driver: driver, records: records, tools: door, chat: chat,
            picksUpAfterRestart: { [appState = root.state] in BackendCopilotSessionDependencies.picksUpAfterRestart(await appState.getPreferences()) }))
        // Item 74: Hoot's context and plan reader. The account is the one its AI runs as, else the one Hoot will start with.
        let usage = BackendHootUsage(), usageHome = RNMHootPaths(dataRoot: dataRoot).home.path, usageOwner = inputs.ownerContext
        let usageAccount: @Sendable (BackendHootChatDriver) async -> BackendUsageAccount? = { [sessions] driver in
            @Sendable func lookup() async -> BackendUsageAccount? {
                var profile: BackendAccountProfile?
                if let id = await driver.liveAccountID { profile = try? await sessions.profiles.find(id) }
                if profile == nil, let defaults { profile = (try? await defaults.read(projectPath: usageHome))?.profile }
                return profile.map { BackendUsageAccount(provider: $0.provider, id: $0.id, name: $0.name, configDirectory: $0.configDir) }
            }
            #if TD_HOST_ACCOUNT_BRIDGE
            if let context = try? usageOwner?() { return await BackendHOSTProfileScope.withContext(context) { await lookup() } }
            #endif
            _ = usageOwner
            return await lookup()
        }
        await usage.track(BackendHootUsage.chatID, chat: chat) { await usageAccount(driver) }
        // HOOT-TASKS-SPLIT (Asad, 12 Oct): each task Hoot works on gets its own Hoot: its own conversation file and its
        // own process, the same AI, account, card, rules, playbook (its desk) and tools as the chat Hoot, the same fence
        // on Hoot's records. Never the chat's conversation; its CLI session is hidden like the chat Hoot's.
        let taskHome = dataRoot.appendingPathComponent("hoot-tasks", isDirectory: true)
        let taskProvider = inputs.headlessProvider, taskConsent = inputs.deckCore.consent, taskConfinement = inputs.confinement
        let taskPolicy = inputs.headlessPolicy, taskOwner = inputs.ownerContext, taskProviders = root.providers
        let mainHome = RNMHootPaths(dataRoot: dataRoot).home.path
        let taskConversations = BackendHootTaskConversations { taskID in
            let folder = taskHome.appendingPathComponent(BackendHootTaskConversations.folderName(taskID) + "-" + UUID().uuidString.lowercased(), isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let taskChat = try BackendHootChatStore(file: folder.appendingPathComponent("chat-\(taskProvider.rawValue).json"),
                                                    provider: taskProvider, consent: taskConsent, retainAllHistory: true)
            await taskChat.setToolTier { name in await tierServer.control.policy(named: name)?.tool.tier }
            let taskDriver = BackendHootChatDriver(providers: taskProviders, sessions: sessions, confinement: taskConfinement, chat: taskChat,
                exposure: boundary.exposureHook, policy: taskPolicy, readyDefaults: defaults, launchBinding: launchBinding,
                defaultProjectPath: mainHome, ownerContext: taskOwner, taskID: taskID)
            await usage.track(BackendHootUsage.taskPrefix + taskID, chat: taskChat) { await usageAccount(taskDriver) }
            let taskDoor: any BackendCopilotSessionToolProviding
            if let host = await sessions.chatHost, host.hello.chatService == 1 {
                taskDoor = try await BackendHOSTTaskChatDoor(source: door, client: host, taskID: taskID)
            } else { taskDoor = door }
            return BackendCopilotSessionRuntime(dependencies: .init(userData: folder.path, storageDir: storageRoot.path,
                chosenFolder: {
                    let value = await settings.value(BackendHootJoinFolderSupply.homeSetting)
                    return value == .missing ? .null : value
                },
                // The task engine carries a task on after a restart itself ("Pick up where you left off").
                driver: taskDriver, records: records, tools: taskDoor, chat: taskChat, picksUpAfterRestart: { false }))
        }
        let folder = BackendCopilotFolderService(dependencies: BackendHootJoinFolderSupply(dataRoot: dataRoot, settings: settings,
            runningIn: { try? await runtime.state().folder.runningIn }, pick: inputs.pickFolder))
        let authority = BackendHootJoinSourceAuthority(window: inputs.window)
        let transcriptScope = inputs.transcriptScope
        let joins = try BackendHootJoinGraph(dataRoot: dataRoot, storageRoot: storageRoot, runtime: runtime, manager: sessions.manager,
            mcpDoor: door, actionLog: deckCore.log, boundary: boundary, authority: authority,
            evidence: .init(toolSink: { deckCore.log.rawSink }, hidesAtSpawn: { driver.hidesAtSpawn },
                managedRecordsAccount: { BackendAccountLaunchAdapter.recordsFenceKeepsManagedLogin },
                transcriptHomeScopes: inputs.transcriptHomeScopes ?? { @Sendable () async -> [NativeTranscriptHomeScope] in (try? await transcriptScope())?.homeScopes ?? [] },
                stopPhoneRuns: inputs.stopPhoneRuns ?? { @Sendable () async -> Void in },
                // deck-control index.ts: the gone approver window denies what only it could answer.
                windowGone: { _ in await deckCore.consent.approverGone() }))
        let snapshot = BackendHootJoinMenuSnapshot(dataRoot: dataRoot)
        let supply = BackendHootJoinMenuSupply(runtime: runtime, manager: sessions.manager, lifecycle: sessions.lifecycle,
            snapshot: snapshot, settings: settings, transcriptScope: inputs.transcriptScope)
        let menu = BackendHootMenuBar(supply.dependencies(ui(authority)))
        let monitor = screenMonitor
        let registration = try await root.installHoot(dependencies: .init(dataRoot: dataRoot, storageRoot: storageRoot,
            runtime: runtime, manager: sessions.manager, lifecycle: sessions.lifecycle, folder: folder, mcpDoor: door,
            actionLog: deckCore.log, rawSink: joins.sink, boundary: boundary, menu: menu, menuSnapshot: snapshot,
            screenMonitor: monitor, authority: authority, joins: joins, reveal: inputs.reveal, menuSupply: supply,
            readAcknowledged: inputs.readAcknowledged, providerChoice: BackendHootProviderChoice(settings: root.settings),
            readyDefaults: inputs.readyDefaults, usage: usage))
        return .init(registration: registration, authority: authority, runtime: runtime, boundary: boundary,
            joins: joins, menu: menu, screenMonitor: monitor, policy: policy, taskConversations: taskConversations, usage: usage)
    }
}
