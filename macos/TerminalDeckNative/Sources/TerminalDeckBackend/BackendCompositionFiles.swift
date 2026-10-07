import Foundation
import TerminalDeckNativeCore

/// A retained files/Git/dev graph. The app supplies current grants and session
/// facts; this graph never creates a Store, PTY manager or account authority.
public actor BackendCompositionFiles {
    public typealias ArtifactScopes = @Sendable (String, BackendArtifactScope, NativeRPCContext) async throws -> [NativeTranscriptScope]

    public struct DevDependencies: Sendable {
        public let sessions: any BackendDevSessionAccess
        public let broadcastState: @Sendable (NativeRPCValue) async -> Void
        public let broadcastLog: (@Sendable (String, String) async -> Void)?
        public init(sessions: any BackendDevSessionAccess,
                    broadcastState: @escaping @Sendable (NativeRPCValue) async -> Void,
                    broadcastLog: (@Sendable (String, String) async -> Void)? = nil) {
            self.sessions = sessions; self.broadcastState = broadcastState; self.broadcastLog = broadcastLog
        }
    }

    public struct WorkspaceDependencies: Sendable {
        public let liveFolders: @Sendable () async -> [String]
        public let openFolder: @Sendable (String) async throws -> String
        public init(liveFolders: @escaping @Sendable () async -> [String],
                    openFolder: @escaping @Sendable (String) async throws -> String) {
            self.liveFolders = liveFolders; self.openFolder = openFolder
        }
    }

    /// Every optional supplier controls whether the corresponding channels are
    /// registered. An absent supplier leaves those channels on the Node route.
    public struct Dependencies: Sendable {
        public let authority: BackendFilesystemAuthority
        public let home: String
        public let inheritedEnvironment: [String: String]
        public let commandRunner: BackendCommandRunner
        public let liveSessions: @Sendable () async -> [BackendSessionMeta]
        public let sessionViews: @Sendable () async -> [NativeRPCValue]
        public let uploadsDirectory: @Sendable () async throws -> URL
        public let guestGitPlan: BackendGitRunner.DevicePlanner?
        public let artifactScopes: ArtifactScopes?
        public let dev: DevDependencies?
        public let workspace: WorkspaceDependencies?
        public let boundary: (@Sendable (String, NativeRPCContext) async throws -> BackendDeviceBoundary?)?
        public let pickFolder: (@Sendable () async throws -> String?)?
        public let showProject: (@Sendable (String) async throws -> Bool)?
        public let announcePreviewPort: (@Sendable (Int) async throws -> Void)?

        public init(authority: BackendFilesystemAuthority, home: String, inheritedEnvironment: [String: String],
                    commandRunner: BackendCommandRunner,
                    liveSessions: @escaping @Sendable () async -> [BackendSessionMeta],
                    sessionViews: @escaping @Sendable () async -> [NativeRPCValue],
                    uploadsDirectory: @escaping @Sendable () async throws -> URL,
                    guestGitPlan: BackendGitRunner.DevicePlanner? = nil, artifactScopes: ArtifactScopes? = nil,
                    dev: DevDependencies? = nil, workspace: WorkspaceDependencies? = nil,
                    boundary: (@Sendable (String, NativeRPCContext) async throws -> BackendDeviceBoundary?)? = nil,
                    pickFolder: (@Sendable () async throws -> String?)? = nil,
                    showProject: (@Sendable (String) async throws -> Bool)? = nil,
                    announcePreviewPort: (@Sendable (Int) async throws -> Void)? = nil) {
            self.authority = authority; self.home = home; self.inheritedEnvironment = inheritedEnvironment
            self.commandRunner = commandRunner; self.liveSessions = liveSessions; self.sessionViews = sessionViews
            self.uploadsDirectory = uploadsDirectory; self.guestGitPlan = guestGitPlan; self.artifactScopes = artifactScopes
            self.dev = dev; self.workspace = workspace; self.boundary = boundary; self.pickFolder = pickFolder
            self.showProject = showProject; self.announcePreviewPort = announcePreviewPort
        }
    }

    public struct Registration: Sendable {
        public let invokeChannels: [String]
        public let sendChannels: [String]
        public let tools: [String]
        public let unresolved: [String]
    }

    public nonisolated let authority: BackendFilesystemAuthority
    public nonisolated let files: BackendFilesystemService
    public nonisolated let git: BackendGitService
    public nonisolated let review: BackendGitReview
    public nonisolated let projects: BackendProjectService
    public nonisolated let watches: BackendFileWatchService
    public nonisolated let transfers: BackendFilesystemTransfers
    public nonisolated let ports: BackendDevPortDiscovery
    public nonisolated let dashboards: BackendDashboardStore
    public nonisolated let dev: BackendDevServers?
    public nonisolated let artifacts: BackendArtifactsIndex?
    public nonisolated let previews: BackendArtifactsPreview?
    public nonisolated let workspaces: BackendWorkspaceService?
    public nonisolated let processExecutor: BackendDevProcessExecutor
    public nonisolated let home: String
    public nonisolated let inheritedEnvironment: [String: String]
    public nonisolated let guestGitPlan: BackendGitRunner.DevicePlanner?
    private let registry: NativeChannelRegistry
    private let dependencies: Dependencies
    private var registrationOwner: String?
    private var subscriptions: [NativeRPCSubscription] = []
    private var devHandle: BackendDevServiceChannels.Handle?
    private var toolServer: BackendNativeMCPServer?
    private var lifecycle: BackendSessionLifecycleCoordinator?
    private var lifecycleObserver: UUID?
    private var installing = false
    private var stopped = false

    /// Construction is inert: no directory read, lock, process, watcher or port
    /// is opened. Persistent siblings inherit the supplied Store's ownership.
    public init(registry: NativeChannelRegistry, state: NativeStateStore, dataRoot: URL,
                providers: BackendNativeProviders, ownPorts: BackendDevOwnPorts,
                dependencies: Dependencies) throws {
        guard dataRoot.isFileURL, dataRoot.path.hasPrefix("/"), dataRoot.path != "/" else {
            throw NativeRPCError.invalidArguments("The native file graph needs the app's actual data folder")
        }
        self.registry = registry; self.dependencies = dependencies
        authority = dependencies.authority; home = dependencies.home
        inheritedEnvironment = dependencies.inheritedEnvironment; guestGitPlan = dependencies.guestGitPlan
        let runner = BackendGitRunner(inheritedEnvironment: dependencies.inheritedEnvironment,
            loginPath: { try await providers.loginPath() }, devicePlanner: dependencies.guestGitPlan)
        let git = BackendGitService(authority: dependencies.authority, runner: runner)
        self.git = git
        let files = BackendFilesystemService(authority: dependencies.authority,
            gitFiles: { root, context in try await git.listFiles(cwd: root, context: context) })
        self.files = files
        projects = try BackendProjectService(store: state, files: files, home: dependencies.home,
            appDataRoot: dataRoot, liveSessions: dependencies.liveSessions, showInWindow: dependencies.showProject)
        review = BackendGitReview(git: git, sessionViews: dependencies.sessionViews)
        watches = BackendFileWatchService(files: files, git: git, registry: registry)
        transfers = BackendFilesystemTransfers(authority: dependencies.authority, uploadsDirectory: dependencies.uploadsDirectory)
        let ports = try BackendDevPortDiscovery(runner: dependencies.commandRunner,
            inheritedEnvironment: dependencies.inheritedEnvironment, cwd: dependencies.home, ownPorts: ownPorts)
        self.ports = ports
        dashboards = try BackendDashboardStore(userData: dataRoot, ownership: state.ownership)
        dev = dependencies.dev.map { BackendDevServers(files: files, sessions: $0.sessions, ports: ports) }
        artifacts = dependencies.artifactScopes.map {
            BackendArtifactsIndex(source: BackendCompositionAuthorityArtifacts(scopes: $0), authority: dependencies.authority)
        }
        previews = dependencies.announcePreviewPort.map {
            BackendArtifactsPreview(authority: dependencies.authority, ownPorts: ownPorts, announce: $0)
        }
        if dependencies.workspace != nil { workspaces = try BackendWorkspaceService(userData: dataRoot, git: git, ownership: state.ownership) }
        else { workspaces = nil }
        processExecutor = BackendDevProcessExecutor()
    }

    /// The root calls this once, after Node has relinquished these channel
    /// owners. Tool access is supplied only when actual deck consent/logging is
    /// connected; otherwise the graph remains usable by its native channels.
    public func install(mcp: BackendNativeMCPServer, ownerID: String,
                        toolAccess: BackendProjectFilesToolAccess? = nil,
                        excludingToolIDs: Set<String> = []) async throws -> Registration {
        guard !stopped, !installing, registrationOwner == nil, !ownerID.isEmpty else {
            throw NativeRPCError(code: "composition-state", message: "The file graph is stopped or already installed")
        }
        installing = true; defer { installing = false }
        let expected = plannedInvokeChannels
        for channel in expected {
            if await registry.has(channel) { throw NativeRPCError(code: "duplicate-handler", message: "The file graph cannot replace another owner of '\(channel)'") }
        }
        if toolAccess != nil { try await preflightTools(mcp, ids: plannedToolIDs.subtracting(excludingToolIDs)) }
        registrationOwner = ownerID
        do {
            let handle = try await BackendProjectFilesChannels.register(registry: registry, ownerID: ownerID,
                files: files, git: git, projects: projects, watches: watches, transfers: transfers, pickFolder: dependencies.pickFolder)
            subscriptions = handle.subscriptions
            var invoke = handle.channels.filter { $0 != "git:unwatch" }
            invoke += try await BackendDashboardChannels.register(registry: registry, ownerID: ownerID, dashboards: dashboards, projects: projects)
            if let artifacts { invoke += try await BackendArtifactsChannels.register(registry: registry, ownerID: ownerID, artifacts: artifacts, projects: projects) }
            if let boundary = dependencies.boundary {
                invoke += try await BackendFilesystemAttachmentChannels.register(registry: registry, ownerID: ownerID, transfers: transfers, boundaryOf: boundary)
            }
            if let dev, let supplied = dependencies.dev {
                let handle = try await BackendDevServiceChannels.register(registry: registry, ownerID: ownerID, projects: projects,
                    ports: ports, servers: dev, broadcastState: supplied.broadcastState, broadcastLog: supplied.broadcastLog)
                devHandle = handle; invoke += handle.channels
            } else {
                try await registry.register("dev:ports", ownerID: ownerID) { [ports] context, args in
                    try context.require("dev.read")
                    return .array(try await ports.scan(force: context.argument(0, in: args).bool == true).map(\.wireValue))
                }
                invoke.append("dev:ports")
            }
            if let workspaces, let supplied = dependencies.workspace {
                invoke += try await BackendWorkspaceChannels.register(registry: registry, ownerID: ownerID,
                    workspaces: workspaces, liveFolders: supplied.liveFolders, openFolder: supplied.openFolder)
            }
            var tools: [String] = []
            if let toolAccess {
                // This collector has no listener/callers. Source factories keep
                // their real handlers, and the shared door installs them once.
                let collector = BackendNativeMCPServer()
                _ = try await BackendProjectFilesMCP.register(server: collector, files: files, git: git, review: review,
                    projects: projects, transfers: transfers, access: toolAccess)
                if let dev, let artifacts {
                    _ = try await BackendDevProjectMCP.register(server: collector, projects: projects, dev: dev,
                        ports: ports, dashboards: dashboards, artifacts: artifacts, access: toolAccess)
                }
                let contribution = await collector.registrations().filter { !excludingToolIDs.contains($0.0.id) }
                try await mcp.replaceTools(ownerID: ownerID, tools: contribution)
                toolServer = mcp; tools = contribution.map { $0.0.id }
            }
            return Registration(invokeChannels: invoke.sorted(), sendChannels: ["git:unwatch"],
                tools: tools.sorted(), unresolved: unresolved)
        } catch {
            if let dev, let devHandle { await BackendDevServiceChannels.unregister(devHandle, servers: dev) }
            devHandle = nil
            for subscription in subscriptions { await subscription.cancelAndWait() }; subscriptions = []
            await toolServer?.removeTools(ownerID: ownerID); toolServer = nil
            await registry.removeOwner(ownerID); registrationOwner = nil
            throw error
        }
    }

    /// Uses the existing ordered lifecycle observer, never another PTY reader.
    /// Root provides a newly authorized context for each development shell exit.
    public func startLifecycle(lifecycle: BackendSessionLifecycleCoordinator,
        contextForSession: @escaping @Sendable (String) async throws -> NativeRPCContext) async throws {
        guard !stopped, registrationOwner != nil else { throw NativeRPCError(code: "composition-state", message: "Install the file graph before observing lifecycle events") }
        guard self.lifecycle == nil else { return }
        guard let dev else { return }
        self.lifecycle = lifecycle
        lifecycleObserver = await lifecycle.observe { event in
            switch event {
            case .data(let id, let text): await dev.received(sessionID: id, text: text)
            case .exit(let id, _): if let context = try? await contextForSession(id) { await dev.noteExit(sessionID: id, context: context) }
            default: break
            }
        }
    }

    public func disconnect(ownerID: String) async {
        await watches.removeOwner(ownerID); await artifacts?.cancel(ownerID: ownerID)
    }

    public func shutdown() async {
        guard !stopped else { return }; stopped = true
        if let lifecycle, let lifecycleObserver { await lifecycle.removeObserver(lifecycleObserver) }
        lifecycle = nil; lifecycleObserver = nil
        if let dev, let devHandle { await BackendDevServiceChannels.unregister(devHandle, servers: dev) }
        devHandle = nil
        for subscription in subscriptions { await subscription.cancelAndWait() }; subscriptions = []
        await watches.stop(); await dev?.stop(); await ports.stop(); await artifacts?.stop(); await previews?.stopAll()
        if let registrationOwner { await toolServer?.removeTools(ownerID: registrationOwner); await registry.removeOwner(registrationOwner) }
        toolServer = nil
        registrationOwner = nil
    }

    public var unresolved: [String] {
        var gaps: [String] = []
        if guestGitPlan == nil { gaps.append("remote-serve: enforced guest Git/readiness environment planner") }
        if artifacts == nil { gaps.append("session/account owner: approved artifact transcript scopes") }
        if dev == nil { gaps.append("session/UI owner: authorized visible shell access and scoped dev state/log broadcasts") }
        if previews == nil { gaps.append("browser/remote owner: preview port announcement") }
        if workspaces == nil { gaps.append("tasks/UI owner: actual live workspace folders and native folder opener") }
        if dependencies.boundary == nil { gaps.append("session/device owner: authorized attachment boundary") }
        if dependencies.pickFolder == nil { gaps.append("native UI owner: project folder picker") }
        return gaps
    }

    private var plannedInvokeChannels: [String] {
        var names = ["fs:list", "fs:read", "search:files", "search:cancel", "search:invalidate", "deckignore:overview", "deckignore:explain", "deckignore:filter", "deckignore:invalidate", "git:status", "git:init", "git:diff", "git:watch", "project:home", "transfer:stage", "dashboard:load", "dashboard:save", "dashboard:clear", "dev:ports"]
        if dependencies.pickFolder != nil { names.append("project:pick") }
        if artifacts != nil { names += ["artifacts:list", "artifacts:changes", "artifacts:cancel"] }
        if dependencies.boundary != nil { names += ["attach:boundary", "attach:bring-in"] }
        if dev != nil { names += ["dev:server:list", "dev:server:start"] }
        if workspaces != nil { names += ["tasks:workspace", "tasks:workspace-open", "tasks:workspace-remove"] }
        return names
    }

    private var plannedToolIDs: Set<String> {
        var ids: Set<String> = ["projects.list", "projects.browse", "projects.add", "projects.remove", "files.list", "files.read", "files.find", "files.ignored", "files.upload", "sessions.attach", "git.status", "git.init", "git.diff"]
        if dev != nil, artifacts != nil { ids.formUnion(["dev.servers", "dashboard.layout", "artifacts.list"]) }
        return ids
    }
    private func preflightTools(_ server: BackendNativeMCPServer, ids: Set<String>) async throws {
        let existing = Set(try await server.catalogue().map(\.id)), overlap = ids.intersection(existing)
        guard overlap.isEmpty else { throw NativeRPCError(code: "duplicate-tool", message: "The file tools already have owners: \(overlap.sorted().joined(separator: ", "))") }
    }
}
