import Foundation
import TerminalDeckNativeCore

/// The shared descriptor/caller owner installs these held tools into its real
/// tools.describe catalogue and updates grants using authenticated caller kinds.
/// A missing supplier leaves the held tools unregistered.
public protocol BackendCompositionClientsLazyCatalogue: Sendable {
    func install(ownerID: String, tools: [BackendMCPTool], index: [String: String], areas: [String: String]) async throws
    func remove(ownerID: String) async
}

public struct BackendCompositionClientsDependencies: Sendable {
    public struct StoreConfiguration: Sendable {
        public let packaged: Bool
        public let commandRunner: BackendCommandRunner
        public let configuredBase: @Sendable () async -> String?
        public init(packaged: Bool, commandRunner: BackendCommandRunner,
                    configuredBase: @escaping @Sendable () async -> String?) {
            self.packaged = packaged; self.commandRunner = commandRunner; self.configuredBase = configuredBase
        }
    }
    public var outputValidator: (any BackendMcpClientOutputValidating)?
    public var saveChooser: BackendMcpClientService.SaveChooser?
    public var openChooser: BackendMcpClientService.OpenChooser?
    public var communityStore: (any BackendCommunityStoreProviding)?
    public var storeConfiguration: StoreConfiguration?
    public var memoryEnvironment: (any BackendMemoryEnvironment)?
    public var knowledgeAuthority: (any BackendKnowledgeToolAuthority)?
    public var lazyCatalogue: (any BackendCompositionClientsLazyCatalogue)?
    public var knowledgeConsent: (@Sendable (BackendKnowledgeShareRequest) async throws -> Bool)?
    public var pluginsConsent: (any BackendPluginsConsent)?
    public var pluginsDesktop: BackendPluginsDesktop?
    public var pluginsAuthority: (any BackendPluginsCallerAuthority)?
    /// Updates the real Hoot-only grants when the live plugin names change.
    /// The shared catalogue owner must also call refreshPluginTools before list.
    public var pluginToolsChanged: (@Sendable (Set<String>) async throws -> Void)?
    /// The concrete core authority publishes source policy/title metadata over
    /// the same live registrations; no raw handler bypasses its central gate.
    public var pluginRegistrationsChanged: (@Sendable (BackendPluginsHost, [BackendPluginsChannels.ToolRegistration]) async throws -> Void)?
    public var pluginTasks: (@Sendable () async throws -> [NativeRPCValue])?
    public var pluginGoals: (@Sendable (String?) async throws -> [NativeRPCValue])?
    public var pluginKnowledge: (@Sendable (String, String, Int) async throws -> NativeRPCValue)?
    public var pluginNotify: (@Sendable (String, String, String) async throws -> Bool)?
    public var plainNodeExecutable: String?
    public var pluginRuntimeExecutable: String?
    public var staysFixedProvisioning: (any BackendStaysFixedProvisioning)?
    public var staysFixedLocate: (@Sendable () throws -> BackendStaysFixedEngineHome)?
    public var report: @Sendable (String) -> Void
    /// The production graph's deck-tools memory-tools own memory.search/read (TS memoryTools is one of
    /// deck-control's extra tools); the clients then register knowledge only, never a second memory owner.
    public var memoryToolsOwnedElsewhere = false
    public init(report: @escaping @Sendable (String) -> Void = { NSLog("[native clients] %@", $0) }) { self.report = report }
}

/// Profile discovery uses the existing profile owner. It never constructs a
/// second profiles store or guesses a session's account from its current cwd.
public struct BackendCompositionClientsMemoryEnvironment: BackendMemoryEnvironment {
    public let profiles: BackendAccountProfileStore
    public let userData: URL
    private let hootMemory: @Sendable () async -> String?
    private let trashFile: @Sendable (String) async throws -> Void
    private let actionLogger: @Sendable () async -> BackendMemoryActionLogger?
    public init(profiles: BackendAccountProfileStore, userData: URL,
                hootMemory: @escaping @Sendable () async -> String?,
                trash: @escaping @Sendable (String) async throws -> Void,
                hootActionLogger: @escaping @Sendable () async -> BackendMemoryActionLogger? = { nil }) {
        self.profiles = profiles; self.userData = userData; self.hootMemory = hootMemory
        trashFile = trash; actionLogger = hootActionLogger
    }
    public func sources() async throws -> BackendMemorySources {
        let claude = try await profiles.list(provider: "claude")
        let codex = try await profiles.list(provider: "codex")
        return BackendMemorySources(stores: (claude + codex).map {
            BackendMemoryAccountStore(provider: $0.provider, configDir: $0.configDir, name: $0.name)
        }, hootMemory: await hootMemory(), userData: userData.path)
    }
    public func trash(_ path: String) async throws { try await trashFile(path) }
    public func hootActionLogger() async -> BackendMemoryActionLogger? { await actionLogger() }
    public func store(for session: BackendSessionMeta) async throws -> String? {
        guard ["claude", "codex"].contains(session.provider) else { return nil }
        let id = session.profileId ?? BackendAccountProfile.systemID(session.provider)
        guard let profile = try await profiles.find(id), profile.provider == session.provider else { return nil }
        return profile.configDir
    }
}

/// One retained client graph. The root passes only domains the Mac Node engine
/// has relinquished before launch. Installation performs no ownership transfer.
public actor BackendCompositionClients {
    public static let allDomains: Set<String> = ["mcp-clients", "github", "custom-agents", "community", "memory", "knowledge", "plugins", "staysfixed"]
    public static let communityChannels = ["community:list", "community:install", "community:remove"]
    public static let customAgentChannels = ["agents:list", "agents:add", "agents:remove"]
    public static func availableDomains(dependencies: BackendCompositionClientsDependencies) -> Set<String> {
        var domains: Set<String> = ["mcp-clients", "github", "custom-agents"]
        if dependencies.staysFixedProvisioning != nil || (dependencies.plainNodeExecutable != nil && dependencies.staysFixedLocate != nil) { domains.insert("staysfixed") }
        if dependencies.communityStore != nil || dependencies.storeConfiguration != nil { domains.insert("community") }
        if dependencies.memoryEnvironment != nil { domains.insert("memory") }
        if dependencies.knowledgeAuthority != nil && dependencies.lazyCatalogue != nil { domains.insert("knowledge") }
        if dependencies.pluginsConsent != nil && dependencies.pluginsAuthority != nil && dependencies.pluginToolsChanged != nil && dependencies.pluginRuntimeExecutable != nil {
            domains.insert("plugins")
        }
        return domains
    }
    public static func channels(for domains: Set<String>) -> [String] {
        var channels: [String] = []
        if domains.contains("mcp-clients") { channels += BackendMcpClientChannels.names }
        if domains.contains("github") { channels += BackendGitHubChannels.channels }
        if domains.contains("custom-agents") { channels += customAgentChannels }
        if domains.contains("community") { channels += communityChannels }
        if domains.contains("memory") { channels += BackendMemoryChannels.names }
        if domains.contains("plugins") { channels += BackendPluginsChannels.channels }
        if domains.contains("staysfixed") { channels += BackendStaysFixedChannels.channels + BackendSFXSetupChannels.channels }
        return channels
    }
    /// `authenticatedKind == .local` is the trusted local Hoot identity from
    /// the caller table, never merely an attended/native-window caller.
    public static func grantToolNames(domains: Set<String>, authenticatedKind: BackendKnowledgeToolCaller.Kind,
                                     machineID: String) -> Set<String> {
        var names = Set<String>()
        if domains.contains("memory") { names.formUnion(BackendMemoryMCP.grantToolNames(for: authenticatedKind, machineID: machineID)) }
        if domains.contains("knowledge") { names.formUnion(BackendKnowledgeMCP.grantToolNames(for: authenticatedKind, machineID: machineID)) }
        if !names.isEmpty { names.formUnion(["tools.describe", "tools_describe"]) }
        return names
    }
    public static func pendingSuppliers(dependencies: BackendCompositionClientsDependencies) -> [String] {
        var pending: [String] = []
        if dependencies.outputValidator == nil { pending.append("MCP clients: arbitrary output JSON Schema validation — validation owner; structured output with an outputSchema refuses until supplied.") }
        if dependencies.saveChooser == nil || dependencies.openChooser == nil { pending.append("MCP import/export: native owner file panels — app UI owner.") }
        if dependencies.communityStore == nil && dependencies.storeConfiguration == nil { pending.append("Community: signed installer/configured Store API setting — native Store owner.") }
        if dependencies.memoryEnvironment == nil { pending.append("Memory: authoritative profile sources, Hoot path/logger and native Trash — accounts/Hoot/app owners.") }
        if dependencies.knowledgeAuthority == nil { pending.append("Memory/knowledge: authenticated caller, known folders, task scope and action dispatcher — deck-core/task owners.") }
        if dependencies.lazyCatalogue == nil { pending.append("Memory/knowledge: held tools.describe catalogue and role-specific grants — deck-core catalogue owner.") }
        if dependencies.knowledgeConsent == nil { pending.append("Knowledge shares: owner consent — app UI owner; absent consent refuses sharing.") }
        if dependencies.pluginsConsent == nil || dependencies.pluginsAuthority == nil || dependencies.pluginToolsChanged == nil {
            pending.append("Plugins: native consent, real Hoot action dispatcher and dynamic Hoot-only grants — app/deck-core owners; no host startup before supplied.")
        }
        if dependencies.pluginTasks == nil { pending.append("Plugins tasks.list: source five-field task projection — task owner.") }
        if dependencies.pluginGoals == nil { pending.append("Plugins goals.list: actual goal store — task/goal owner.") }
        if dependencies.pluginKnowledge == nil && (dependencies.knowledgeAuthority == nil || dependencies.lazyCatalogue == nil) {
            pending.append("Plugins knowledge.search: current knowledge owner's project brief reader — knowledge/task owner.")
        }
        if dependencies.pluginNotify == nil { pending.append("Plugins notify: real notification service — deck-core notification owner.") }
        if dependencies.staysFixedProvisioning == nil && (dependencies.plainNodeExecutable == nil || dependencies.staysFixedLocate == nil) { pending.append("Stays Fixed: optional add-on provisioning or transitional runtime/locator is not connected.") }
        if dependencies.pluginRuntimeExecutable == nil { pending.append("Plugins: the bundled JavaScriptCore helper is not connected.") }
        return pending
    }

    public nonisolated let domains: Set<String>
    public nonisolated let invokeChannels: [String]
    public nonisolated let sendChannels: [String]
    public nonisolated let eventChannels: [String]
    public nonisolated let mcpClients: BackendMcpClientService?
    public nonisolated let github: BackendGitHubService?
    public nonisolated let githubAuth: BackendGitHubAuthenticator?
    /// Rung after the GitHub login changes (TS github-auth.ts onChanged); remote serve re-reads and fans out.
    public nonisolated let githubChanges: BackendCompositionChangeHub
    public nonisolated let customAgents: BackendCustomAgentsStore?
    public nonisolated let community: (any BackendCommunityStoreProviding)?
    public nonisolated let memory: BackendMemoryService?
    public nonisolated let knowledge: BackendKnowledgeService?
    public nonisolated let plugins: BackendPluginsHost?
    public nonisolated let staysFixed: BackendStaysFixedService?
    public nonisolated let sfxSetup: BackendSFXSetupService?
    private let registry: NativeChannelRegistry, mcpServer: BackendNativeMCPServer
    private let ownerID: String, toolsOwnerID: String
    private let dependencies: BackendCompositionClientsDependencies
    private let pluginCatalogue: BackendCompositionClientsPluginCatalogue?
    private var githubClear: NativeRPCSubscription?
    private var closed = false

    private init(domains: Set<String>, registry: NativeChannelRegistry, mcpServer: BackendNativeMCPServer,
                 ownerID: String, dependencies: BackendCompositionClientsDependencies,
                 mcpClients: BackendMcpClientService?, github: BackendGitHubService?, githubAuth: BackendGitHubAuthenticator?,
                 customAgents: BackendCustomAgentsStore?, community: (any BackendCommunityStoreProviding)?,
                 memory: BackendMemoryService?, knowledge: BackendKnowledgeService?, plugins: BackendPluginsHost?,
                 staysFixed: BackendStaysFixedService?, sfxSetup: BackendSFXSetupService?, pluginCatalogue: BackendCompositionClientsPluginCatalogue?,
                 githubChanges: BackendCompositionChangeHub) {
        self.domains = domains; invokeChannels = Self.channels(for: domains)
        sendChannels = domains.contains("github") ? ["github:clear-cache"] : []
        var events: [String] = []
        if domains.contains("mcp-clients") { events.append("mcp:state") }
        if domains.contains("memory") { events.append("memory:changed") }
        if domains.contains("plugins") { events.append("plugins:changed") }
        if domains.contains("staysfixed") { events.append("staysfixed:changed") }
        eventChannels = events
        self.registry = registry; self.mcpServer = mcpServer; self.ownerID = ownerID
        toolsOwnerID = ownerID + ".clients.lazy"; self.dependencies = dependencies
        self.mcpClients = mcpClients; self.github = github; self.githubAuth = githubAuth; self.githubChanges = githubChanges
        self.customAgents = customAgents; self.community = community; self.memory = memory
        self.knowledge = knowledge; self.plugins = plugins; self.staysFixed = staysFixed
        self.sfxSetup = sfxSetup
        self.pluginCatalogue = pluginCatalogue
    }

    public static func install(registry: NativeChannelRegistry, mcpServer: BackendNativeMCPServer,
                               stateStore: NativeStateStore, providers: BackendNativeProviders,
                               dataRoot: URL, home: String, inheritedEnvironment: [String: String],
                               ownerID: String, transferredDomains: Set<String>,
                               dependencies: BackendCompositionClientsDependencies) async throws -> BackendCompositionClients {
        guard dataRoot.isFileURL, dataRoot.path.hasPrefix("/"), home.hasPrefix("/"), !ownerID.isEmpty else {
            throw NativeRPCError.invalidArguments("The clients graph needs the authoritative data root, home and native owner.")
        }
        if let executable = dependencies.plainNodeExecutable {
            guard executable.hasPrefix("/"), !executable.contains("\0"), URL(fileURLWithPath: executable).lastPathComponent == "node",
                  !URL(fileURLWithPath: executable).standardizedFileURL.path.contains(".app/Contents/MacOS/") else {
                throw NativeRPCError.invalidArguments("Stays Fixed needs its own Node executable, never the native app executable.")
            }
        }
        if let executable = dependencies.pluginRuntimeExecutable {
            guard executable.hasPrefix("/"), !executable.contains("\0"), URL(fileURLWithPath: executable).lastPathComponent == "TerminalDeckJSCorePluginHelper" else {
                throw NativeRPCError.invalidArguments("Plugins need the bundled JavaScriptCore helper executable.")
            }
        }
        guard transferredDomains.isSubset(of: availableDomains(dependencies: dependencies)) else {
            let missing = transferredDomains.subtracting(availableDomains(dependencies: dependencies)).sorted().joined(separator: ", ")
            throw NativeRPCError(code: "unavailable", message: "Client domains have no concrete suppliers: " + missing)
        }
        if transferredDomains.contains("community"), !transferredDomains.contains("mcp-clients") {
            throw NativeRPCError(code: "ownership-required", message: "The community installer and MCP configuration writer must transfer together.")
        }
        for channel in channels(for: transferredDomains) {
            if await registry.has(channel) { throw NativeRPCError(code: "duplicate-handler", message: "Client channel is already registered: " + channel) }
        }
        if transferredDomains.contains("github"), await registry.hasSend("github:clear-cache") {
            throw NativeRPCError(code: "duplicate-handler", message: "Client send channel is already registered: github:clear-cache")
        }
        let loginPath: @Sendable () async throws -> String = { try await providers.loginPath() }
        let client: BackendMcpClientService?
        if transferredDomains.contains("mcp-clients") {
            let config = BackendMcpClientConfiguration(home: home, environment: inheritedEnvironment)
            let writer = BackendMcpClientWriter(configuration: config, providers: providers)
            client = BackendMcpClientService(writer: writer,
                pool: BackendMcpClientPool(configuration: config, loginPath: loginPath, outputValidator: dependencies.outputValidator),
                saveChooser: dependencies.saveChooser, openChooser: dependencies.openChooser)
        } else { client = nil }
        let github: BackendGitHubService?, auth: BackendGitHubAuthenticator?
        let githubChanges = BackendCompositionChangeHub()
        if transferredDomains.contains("github") {
            let tools = BackendGitHubNativeTools(home: home, loginPath: loginPath), cache = BackendGitHubCache()
            let service = BackendGitHubService(environment: inheritedEnvironment, tools: tools, cache: cache)
            github = service
            auth = try BackendGitHubAuthenticator(dataDirectory: dataRoot, environment: inheritedEnvironment, tools: tools,
                resolveRepo: { await service.resolveRepo($0) }, resolveBranch: { await service.readBranch($0) }, onAuthChanged: { await cache.clear(); await githubChanges.fire() })
        } else { github = nil; auth = nil }
        let agents: BackendCustomAgentsStore?
        if transferredDomains.contains("custom-agents") {
            agents = try BackendCustomAgentsStore(dataDirectory: dataRoot, lookup: BackendCustomAgentsStore.nativeLookup(loginPath: loginPath))
        } else { agents = nil }
        let community: (any BackendCommunityStoreProviding)?
        if transferredDomains.contains("community") {
            if let supplied = dependencies.communityStore { community = supplied }
            else if let configuration = dependencies.storeConfiguration, let client {
                community = try BackendOSStoreChannels.make(userData: dataRoot, environment: inheritedEnvironment, home: home,
                    packaged: configuration.packaged, writable: true, configuredBase: configuration.configuredBase,
                    providers: providers, commandRunner: configuration.commandRunner, claudeMCP: client.writer)
            } else { throw NativeRPCError(code: "unavailable", message: BackendCommunityChannels.unavailable) }
        } else { community = nil }
        let memory: BackendMemoryService?
        if transferredDomains.contains("memory"), let environment = dependencies.memoryEnvironment {
            memory = BackendMemoryService(environment: environment, onChanged: { id in
                try? await registry.publish("memory:changed", arguments: [.string(id)])
            }, onError: dependencies.report)
        } else { memory = nil }
        // This owner exists only after the whole knowledge domain transfers.
        // Plugins otherwise need the current owner's read-only supplier.
        let knowledge: BackendKnowledgeService? = transferredDomains.contains("knowledge")
            ? BackendKnowledgeService(userData: dataRoot.path, consent: dependencies.knowledgeConsent,
                onError: { error, operation in dependencies.report("Knowledge " + operation + ": " + error) }) : nil
        let pluginCatalogue: BackendCompositionClientsPluginCatalogue?, plugins: BackendPluginsHost?
        if transferredDomains.contains("plugins"), let consent = dependencies.pluginsConsent,
           let authority = dependencies.pluginsAuthority, let changed = dependencies.pluginToolsChanged {
            let catalogue = BackendCompositionClientsPluginCatalogue(server: mcpServer, authority: authority,
                ownerID: ownerID + ".clients.plugins", namesChanged: changed,
                registrationsChanged: dependencies.pluginRegistrationsChanged, report: dependencies.report)
            pluginCatalogue = catalogue
            let pluginKnowledge: (@Sendable (String, String, Int) async throws -> NativeRPCValue)?
            if let knowledge {
                pluginKnowledge = { project, query, limit in
                    let brief = await knowledge.forBrief(project: project, query: query, limit: limit)
                    return .object([.init("text", .string(brief.text)), .init("records", .array(brief.records.map { $0.shown(project: project) }))])
                }
            } else { pluginKnowledge = dependencies.pluginKnowledge }
            let services = BackendPluginsServices(projects: { await stateStore.getProjects().compactMap { $0["path"].string } },
                tasks: dependencies.pluginTasks, goals: dependencies.pluginGoals, knowledge: pluginKnowledge, notify: dependencies.pluginNotify)
            let host = BackendPluginsHost(userData: dataRoot, runtime: dependencies.pluginRuntimeExecutable,
                environment: inheritedEnvironment, consent: consent, services: services, desktop: dependencies.pluginsDesktop,
                changed: { await catalogue.changed(); try? await registry.publish("plugins:changed", arguments: []) })
            await catalogue.bind(host)
            plugins = host
        } else { pluginCatalogue = nil; plugins = nil }
        let fixed: BackendStaysFixedService?
        if transferredDomains.contains("staysfixed") {
            fixed = BackendStaysFixedService(userData: dataRoot, home: home, executable: dependencies.plainNodeExecutable,
                inheritedEnvironment: inheritedEnvironment, locate: {
                    guard let locate = dependencies.staysFixedLocate else { throw NativeRPCError(code: "unavailable", message: "Stays Fixed is not part of this build.") }
                    return try locate()
                }, loginPath: loginPath, changed: { project in try? await registry.publish("staysfixed:changed", arguments: [.string(project)]) },
                provisioning: dependencies.staysFixedProvisioning)
        } else { fixed = nil }
        let sfxSetup: BackendSFXSetupService?
        if let fixed {
            let planner = BackendSFXSetupPlanner(userData: dataRoot, executable: dependencies.plainNodeExecutable,
                inheritedEnvironment: inheritedEnvironment, locate: {
                    guard let locate = dependencies.staysFixedLocate else {
                        throw NativeRPCError(code: "unavailable", message: "Stays Fixed is not part of this build.")
                    }
                    return try locate()
                }, loginPath: loginPath, provisioning: dependencies.staysFixedProvisioning)
            sfxSetup = BackendSFXSetupService(plan: { try await planner.plan($0, prepareRuntime: $1) },
                setup: { try await fixed.setup($0) })
        } else { sfxSetup = nil }
        let graph = BackendCompositionClients(domains: transferredDomains, registry: registry, mcpServer: mcpServer, ownerID: ownerID,
            dependencies: dependencies, mcpClients: client, github: github, githubAuth: auth, customAgents: agents,
            community: community, memory: memory, knowledge: knowledge, plugins: plugins, staysFixed: fixed, sfxSetup: sfxSetup, pluginCatalogue: pluginCatalogue,
            githubChanges: githubChanges)
        do { try await graph.registerChannels(providers: providers, dataRoot: dataRoot, home: home, environment: inheritedEnvironment); return graph }
        catch { await graph.shutdown(); throw error }
    }

    private func registerChannels(providers: BackendNativeProviders, dataRoot: URL, home: String, environment: [String: String]) async throws {
        if let mcpClients { try await BackendMcpClientChannels.register(registry: registry, ownerID: ownerID, service: mcpClients) }
        if let github, let githubAuth { githubClear = try await BackendGitHubChannels.register(registry: registry, ownerID: ownerID, service: github, auth: githubAuth) }
        if let customAgents { try await BackendCustomAgentsChannels.register(registry: registry, ownerID: ownerID, store: customAgents) }
        if let community { try await BackendCommunityChannels.register(registry: registry, ownerID: ownerID, store: community,
            userData: dataRoot.path, probe: BackendCommunityNativeProbe(providers: providers), emptyHomes: BackendOSStoreInstaller.agentHomes(environment: environment, home: home)) }
        if let memory { try await BackendMemoryChannels.register(registry: registry, ownerID: ownerID, service: memory) }
        if let staysFixed { try await BackendStaysFixedChannels.register(registry: registry, ownerID: ownerID, service: staysFixed) }
        if let sfxSetup { try await BackendSFXSetupChannels.register(registry: registry, ownerID: ownerID, service: sfxSetup) }
        try await registerLazyTools()
        if let plugins {
            try await BackendPluginsChannels.register(registry: registry, ownerID: ownerID, host: plugins)
            await pluginCatalogue?.installRefresh()
            await plugins.startAll()
            try await pluginCatalogue?.refresh(revalidate: true)
        }
    }

    private func registerLazyTools() async throws {
        guard let authority = dependencies.knowledgeAuthority, let catalogue = dependencies.lazyCatalogue else { return }
        var registrations: [(BackendMCPTool, BackendNativeMCPServer.Handler)] = [], index: [String: String] = [:], areas: [String: String] = [:]
        if let memory, !dependencies.memoryToolsOwnedElsewhere {
            for spec in try BackendMemoryMCP.specifications() {
                registrations.append((spec, { context, arguments in
                    do { return try await BackendKnowledgeMCP.cancellable(context.cancellation) {
                        .value(try await BackendMemoryMCP.call(tool: spec.id, args: arguments, context: context, service: memory, authority: authority))
                    } } catch { return .failure(error.localizedDescription) }
                }))
                index[spec.id] = BackendMemoryMCP.index[spec.id]; areas[spec.id] = "memory"
            }
        }
        if domains.contains("knowledge"), let knowledge {
            for spec in try BackendKnowledgeMCP.specifications() {
                registrations.append((spec, { context, arguments in
                    do { return try await BackendKnowledgeMCP.cancellable(context.cancellation) {
                        .value(try await BackendKnowledgeMCP.call(tool: spec.id, args: arguments, context: context, service: knowledge, authority: authority))
                    } } catch { return .failure(error.localizedDescription) }
                }))
                index[spec.id] = BackendKnowledgeMCP.index[spec.id]; areas[spec.id] = "knowledge"
            }
        }
        guard !registrations.isEmpty else { return }
        try await catalogue.install(ownerID: toolsOwnerID, tools: registrations.map { $0.0 }, index: index, areas: areas)
        try await mcpServer.replaceTools(ownerID: toolsOwnerID, tools: registrations)
    }

    /// Called by the shared authenticated catalogue owner before listing tools.
    public func refreshPluginTools() async throws { guard !closed else { return }; try await pluginCatalogue?.refresh(revalidate: true) }
    public func pluginToolNames() async throws -> Set<String> { try await refreshPluginTools(); return await pluginCatalogue?.toolNames() ?? [] }
    /// Disable new bridge calls and drain pending requests before calling this.
    /// Unrelated owners' registry and MCP registrations remain intact.
    public func shutdown() async {
        guard !closed else { return }; closed = true
        await pluginCatalogue?.close()
        await plugins?.stopAll(); await mcpClients?.stopAll(); await githubAuth?.shutdown()
        await memory?.close(); await staysFixed?.dispose(); await githubClear?.cancelAndWait(); githubClear = nil
        await dependencies.lazyCatalogue?.remove(ownerID: toolsOwnerID)
        await mcpServer.removeTools(ownerID: toolsOwnerID)
        for channel in invokeChannels { await registry.removeHandler(channel, ownerID: ownerID) }
    }
}

private actor BackendCompositionClientsPluginCatalogue {
    private let server: BackendNativeMCPServer, authority: any BackendPluginsCallerAuthority
    private let ownerID: String
    private let namesChanged: @Sendable (Set<String>) async throws -> Void
    private let registrationsChanged: (@Sendable (BackendPluginsHost, [BackendPluginsChannels.ToolRegistration]) async throws -> Void)?
    private let report: @Sendable (String) -> Void
    private var host: BackendPluginsHost?, names = Set<String>(), generation: UInt64 = 0, closed = false
    init(server: BackendNativeMCPServer, authority: any BackendPluginsCallerAuthority, ownerID: String,
         namesChanged: @escaping @Sendable (Set<String>) async throws -> Void,
         registrationsChanged: (@Sendable (BackendPluginsHost, [BackendPluginsChannels.ToolRegistration]) async throws -> Void)?,
         report: @escaping @Sendable (String) -> Void) {
        self.server = server; self.authority = authority; self.ownerID = ownerID; self.namesChanged = namesChanged
        self.registrationsChanged = registrationsChanged; self.report = report
    }
    func bind(_ host: BackendPluginsHost) { self.host = host }
    func installRefresh() async {
        await server.setCatalogueRefresh(ownerID: ownerID, refresh: { [self] in try await refresh(revalidate: true) })
    }
    func toolNames() -> Set<String> { names }
    func changed() async {
        do { try await refresh(revalidate: false) }
        catch {
            names = []
            if let host { do { try await registrationsChanged?(host, []) } catch { report("Plugin policy withdrawal: " + error.localizedDescription) } }
            do { try await namesChanged([]) } catch { report("Plugin grant withdrawal: " + error.localizedDescription) }
            await server.removeTools(ownerID: ownerID); report("Plugin catalogue: " + error.localizedDescription)
        }
    }
    func refresh(revalidate: Bool) async throws {
        guard !closed, let host else { return }
        generation &+= 1; let current = generation
        if revalidate { await host.scan() }
        let registrations = try await BackendPluginsChannels.tools(host: host, authority: authority)
        guard !closed, generation == current else { return }
        try await registrationsChanged?(host, registrations)
        guard !closed, generation == current else { return }
        let names = Set(registrations.flatMap { [$0.spec.id, $0.spec.wireName] })
        try await namesChanged(names)
        guard !closed, generation == current else { return }
        try await server.replaceTools(ownerID: ownerID, tools: registrations.map { ($0.spec, $0.handler) })
        if closed { await server.removeTools(ownerID: ownerID); return }
        if generation == current { self.names = names }
        else { try await refresh(revalidate: false) }
    }
    func close() async {
        guard !closed else { return }; closed = true; generation &+= 1
        let previousHost = host; host = nil; names = []
        await server.setCatalogueRefresh(ownerID: ownerID, refresh: nil)
        if let previousHost {
            do { try await registrationsChanged?(previousHost, []) } catch { report("Plugin policy teardown: " + error.localizedDescription) }
        }
        do { try await namesChanged([]) } catch { report("Plugin grant teardown: " + error.localizedDescription) }
        await server.removeTools(ownerID: ownerID)
    }
}
