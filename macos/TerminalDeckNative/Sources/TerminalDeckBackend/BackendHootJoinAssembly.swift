import Foundation
import TerminalDeckNativeCore

/// index.ts `registerCopilotFolderIpc` dependencies over the one settings store
/// (`copilot.home`), the one desk runtime and the shared Home action writer.
/// The picker is the app's free-standing AppKit Open panel (no parent sheet).
public struct BackendHootJoinFolderSupply: BackendCopilotFolderDependencies {
    public static let homeSetting = "copilot.home"
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
        public let transcriptScope: @Sendable () async throws -> NativeTranscriptScope
        public let reveal: (any BackendCopilotInspectRevealing)?
        /// Live-window check, normally `BackendCompositionAuthority.requireLocalUI`.
        public let window: @Sendable (NativeRPCContext) throws -> Void
        /// Home scopes installed on the app's other transcript readers; default:
        /// the desk scope's own list (it must carry Hoot's home scope).
        public let transcriptHomeScopes: (@Sendable () async -> [NativeTranscriptHomeScope])?
        /// Stops paired-device Hoot (`{ await frames.stop(); await runs.stopAll() }`)
        /// once the native remote host serves it; nil = no native phone runs exist.
        public let stopPhoneRuns: (@Sendable () async -> Void)?
        public init(storageRoot: URL, sessions: BackendCompositionSessions, deckCore: BackendDeckCoreRuntime,
                    confinement: BackendMacConfinement?, machineID: String,
                    pickFolder: @escaping @Sendable (String) async throws -> String?,
                    transcriptScope: @escaping @Sendable () async throws -> NativeTranscriptScope,
                    reveal: (any BackendCopilotInspectRevealing)?,
                    window: @escaping @Sendable (NativeRPCContext) throws -> Void = BackendCompositionRoot.requireLocalUI,
                    transcriptHomeScopes: (@Sendable () async -> [NativeTranscriptHomeScope])? = nil,
                    stopPhoneRuns: (@Sendable () async -> Void)? = nil) {
            self.storageRoot = storageRoot; self.sessions = sessions; self.deckCore = deckCore; self.confinement = confinement
            self.machineID = machineID; self.pickFolder = pickFolder; self.transcriptScope = transcriptScope
            self.reveal = reveal; self.window = window; self.transcriptHomeScopes = transcriptHomeScopes; self.stopPhoneRuns = stopPhoneRuns
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
    }

    /// `ui` receives the authority so the island binding is created with
    /// `authority.islandOwnerID` and the catcher with `authority.catcherOwnerID`.
    @MainActor
    public static func install(in root: BackendCompositionRoot, inputs: Inputs, oldHootOwnerDisabled: Bool,
                               ui: (BackendHootJoinSourceAuthority) -> BackendHootJoinMenuSupply.UI) async throws -> Assembled {
        try await root.requireAssemblyOpen()
        let dataRoot = root.dataRoot.standardizedFileURL
        let storageRoot = inputs.storageRoot.standardizedFileURL
        let sessions = inputs.sessions
        let boundary = BackendHootJoinSpawnBoundary(hidden: .shared)
        let driver = BackendCopilotSessionNativeDriver(providers: root.providers, profiles: sessions.profiles,
            signIns: sessions.signIn, launcher: sessions.launcher, ptys: sessions.manager, exposure: boundary.exposureHook)
        let deckCore = inputs.deckCore, providers = root.providers
        let records: any BackendCopilotSessionRecordsProviding
        if let confinement = inputs.confinement {
            records = try BackendHootJoinRecords(dataRoot: dataRoot, prove: {
                try await confinement.measureRecordsFence(path: try await providers.loginPath())
            })
        } else { records = BackendCopilotSessionUnavailableRecords() }
        let door = try BackendCopilotSessionMCPDoor(endpoint: BackendCopilotSessionSecurityEndpoint(server: deckCore.server),
            userData: dataRoot, machineID: inputs.machineID, titles: { deckCore.hootLayerTitles() })
        let settings = root.settings
        let runtime = BackendCopilotSessionRuntime(dependencies: .init(userData: dataRoot.path, storageDir: storageRoot.path,
            chosenFolder: {
                let value = await settings.value(BackendHootJoinFolderSupply.homeSetting)
                return value == .missing ? .null : value
            },
            driver: driver, records: records, tools: door))
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
        let monitor = BackendHootScreenMonitor()
        let registration = try await root.installHoot(dependencies: .init(dataRoot: dataRoot, storageRoot: storageRoot,
            runtime: runtime, manager: sessions.manager, lifecycle: sessions.lifecycle, folder: folder, mcpDoor: door,
            actionLog: deckCore.log, rawSink: joins.sink, boundary: boundary, menu: menu, menuSnapshot: snapshot,
            screenMonitor: monitor, authority: authority, joins: joins, reveal: inputs.reveal, menuSupply: supply),
            oldHootOwnerDisabled: oldHootOwnerDisabled)
        return .init(registration: registration, authority: authority, runtime: runtime, boundary: boundary,
            joins: joins, menu: menu, screenMonitor: monitor)
    }
}
