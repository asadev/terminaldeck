import Foundation
import TerminalDeckNativeCore

/// Per-exchange proof from the actual core credential door. No field here is
/// read from tool arguments, attended flags or the Node local-UI transport.
public final class BackendCompositionClientsSecurityAuthority: BackendKnowledgeToolAuthority, BackendPluginsCallerAuthority,
    BackendCompositionClientsMCPContextAuthority, @unchecked Sendable {
    private struct GrantScope: Sendable {
        let authorityID: UUID, requestID: UUID
        let cancellation: BackendMCPCancellation
        let grant: BackendDeckCoreSecurityGrant
        let current: @Sendable () async -> BackendDeckCoreSecurityGrant?
    }
    private struct Dispatch: Sendable {
        let authorityID: UUID, tool: String, tier: BackendMCPTier
        let arguments: NativeRPCValue, context: BackendDeckCoreSecurityCallContext
    }
    private enum Scope {
        @TaskLocal static var grant: GrantScope?
        @TaskLocal static var dispatch: Dispatch?
    }
    private let id = UUID()
    private let contexts: BackendDeckCoreToolContextAuthority
    private let manager: BackendPTYManager
    private let profiles: BackendAccountProfileStore
    private let surface: any BackendDeckCoreCatalogueSurface
    private let tasks: BackendTaskStore?
    private let lock = NSLock()
    private var lazyMetadata: [BackendDeckCoreCatalogueMetadata] = []
    private var pluginMetadata: [BackendDeckCoreCatalogueMetadata] = []
    private var pluginPolicies: [BackendDeckCoreSecurityToolPolicy] = []
    public init(contexts: BackendDeckCoreToolContextAuthority, manager: BackendPTYManager,
                profiles: BackendAccountProfileStore, surface: any BackendDeckCoreCatalogueSurface,
                tasks: BackendTaskStore? = nil) {
        self.contexts = contexts; self.manager = manager; self.profiles = profiles; self.surface = surface; self.tasks = tasks
    }

    /// SecurityServer.exchange calls this with its matched grant and its real
    /// request scope around control.call. The caller table/door owns the grant.
    /// A direct in-process routine uses the credential-table overload below.
    public func withAuthenticatedGrant<T: Sendable>(grant: BackendDeckCoreSecurityGrant, cancellation: BackendMCPCancellation,
        current: (@Sendable () async -> BackendDeckCoreSecurityGrant?)? = nil,
        operation: @Sendable () async throws -> T) async rethrows -> T {
        let observer = grant.cancellation.observe { cancellation.cancel() }
        defer { grant.cancellation.removeObserver(observer) }
        let scope = GrantScope(authorityID: id, requestID: UUID(), cancellation: cancellation, grant: grant,
            current: current ?? { grant })
        return try await Scope.$grant.withValue(scope) { try await operation() }
    }
    /// Rechecks the same actual credential in the same table on every operation.
    /// The credential is retained only in this private closure, never returned.
    public func withAuthenticatedCredential<T: Sendable>(authorization: String, table: BackendDeckCoreSecurityCallerTable,
        cancellation: BackendMCPCancellation, operation: @Sendable () async throws -> T) async throws -> T {
        guard let grant = await table.match(authorization: authorization) else { throw refused("The native client credential is no longer registered.") }
        return try await withAuthenticatedGrant(grant: grant, cancellation: cancellation,
            current: { await table.match(authorization: authorization) }, operation: operation)
    }
    private func grantScope() throws -> GrantScope {
        guard let scope = Scope.grant, scope.authorityID == id, !scope.cancellation.isCancelled,
              !scope.grant.cancellation.isCancelled else { throw BackendSessionFailure.missingCapability("the matched native core caller grant for this exchange") }
        return scope
    }
    private func freshCaller(_ context: BackendDeckCoreSecurityCallContext? = nil) async throws -> (GrantScope, BackendDeckCoreSecurityGrant, BackendDeckCoreSecurityCaller) {
        let scope = try grantScope()
        guard let grant = await scope.current(), grant.identity == scope.grant.identity, !grant.cancellation.isCancelled else { throw refused("This native client caller was revoked or replaced.") }
        let caller = await grant.caller()
        guard !scope.cancellation.isCancelled, !grant.cancellation.isCancelled, !caller.tiers.isEmpty else { throw refused("This native client caller no longer has access.") }
        if let context {
            guard !context.cancellation.isCancelled, sameIdentity(caller, context.caller),
                  context.attended == grant.attended, context.native.sessionID == (caller.sessionID ?? ""),
                  context.native.machineID == (caller.machineID ?? "") else { throw refused("The native client call no longer matches its authenticated caller.") }
        }
        return (scope, grant, caller)
    }
    private func sameIdentity(_ a: BackendDeckCoreSecurityCaller, _ b: BackendDeckCoreSecurityCaller) -> Bool {
        a.kind == b.kind && a.deviceID == b.deviceID && a.keyID == b.keyID && a.sessionID == b.sessionID &&
        a.machineID == b.machineID && a.projectRoot == b.projectRoot && a.folders == b.folders
    }
    private func refused(_ message: String) -> BackendDeckCoreSecurityRefusal { .init(.callerGone, message) }
    private func securityContext(_ native: BackendMCPCallContext) async throws -> BackendDeckCoreSecurityCallContext {
        let context = try await contexts.context(for: native)
        _ = try await freshCaller(context)
        return context
    }
    private func clientKind(_ caller: BackendDeckCoreSecurityCaller) -> BackendKnowledgeToolCaller.Kind {
        switch caller.kind { case .local: .local; case .session: .session; case .key: .key; case .remote: .remote }
    }
    private func roleAllows(_ tool: String, caller: BackendDeckCoreSecurityCaller) -> Bool {
        if tool.hasPrefix("plugin.") { return caller.kind == .local }
        if tool.hasPrefix("memory.") { return BackendMemoryMCP.grantToolNames(for: clientKind(caller), machineID: caller.machineID ?? "").contains(tool) }
        if tool.hasPrefix("knowledge.") { return BackendKnowledgeMCP.grantToolNames(for: clientKind(caller), machineID: caller.machineID ?? "").contains(tool) }
        // These source configuration tools use their explicit grant/tier/consent.
        return ["mcp.list", "mcp.add", "mcp.edit", "mcp.remove", "mcp.connect", "mcp.disconnect", "mcp.call", "mcp.store", "mcp.install", "mcp.export", "mcp.import"].contains(tool)
    }
    private func requireRole(_ tool: String, caller: BackendDeckCoreSecurityCaller) throws {
        guard !roleAllows(tool, caller: caller) else { return }
        if tool.hasPrefix("plugin.") { throw BackendDeckCoreSecurityRefusal(.notGranted, tool + " is a plugin tool, and plugin tools are Hoot’s own.") }
        if tool == "knowledge.note" {
            if caller.kind == .local { throw BackendDeckCoreSecurityRefusal(.notGranted, "knowledge.note is a worker session’s; you record with knowledge_record.") }
            if caller.kind == .session { throw BackendDeckCoreSecurityRefusal(.notGranted, "knowledge.note keeps notes for projects on this computer; this session runs on another one.") }
            throw BackendDeckCoreSecurityRefusal(.notGranted, "knowledge.note is for a session in this app, about the project it is working in.")
        }
        if tool.hasPrefix("knowledge.") { throw BackendDeckCoreSecurityRefusal(.notGranted, tool + " is Hoot’s own tool.") }
        if caller.kind == .session { throw BackendDeckCoreSecurityRefusal(.notPermitted, "This session runs on another computer, and its memory is there, not on this one.") }
        throw BackendDeckCoreSecurityRefusal(.notPermitted, "The memory of the agents on this computer is read on this computer only.")
    }
    private func specification(_ tool: String) throws -> BackendMCPTool {
        if let found = lock.withLock({ (lazyMetadata + pluginMetadata).first { $0.tool.id == tool || $0.tool.wireName == tool }?.tool }) { return found }
        if let row = try BackendDeckCoreEventsToolDefinitions.all().first(where: { $0["id"].string == tool }) {
            return try BackendMCPTool(id: tool, wireName: row["wire"].requireString("wire"), description: row["description"].requireString("description"),
                inputSchema: row["inputSchema"], tier: BackendMCPTier(rawValue: row["tier"].string ?? "") ?? .alter, advertised: false)
        }
        throw BackendSessionFailure.missingCapability("the registered native client policy for " + tool)
    }
    public func revalidate(_ context: BackendDeckCoreSecurityCallContext, tool: String) async throws {
        let (_, grant, caller) = try await freshCaller(context), spec = try specification(tool)
        try requireRole(spec.id, caller: caller)
        let aliases: Set<String> = [spec.id, spec.wireName]
        guard caller.tiers.contains(spec.tier), context.native.allowedTiers.contains(spec.tier),
              !context.native.allowedTools.isDisjoint(with: aliases),
              context.granted == nil || !context.granted!.isDisjoint(with: aliases),
              grant.tools == nil || !grant.tools!.isDisjoint(with: aliases) else {
            throw BackendDeckCoreSecurityRefusal(.notGranted, "This authenticated caller is not granted " + spec.id + ".")
        }
    }

    /// Every projection is scoped. Even local Hoot is never .nativeApp; the
    /// scope below is derived from the matched credential and current roots.
    public func filesystemContext(_ context: BackendDeckCoreSecurityCallContext) async throws -> NativeRPCContext {
        let (scope, _, _) = try await freshCaller(context)
        return NativeRPCContext(caller: .pairedDevice, ownerID: "native-clients:" + scope.requestID.uuidString,
            requestID: scope.requestID, capabilities: [])
    }
    public func filesystemAuthority() -> BackendFilesystemAuthority {
        BackendFilesystemAuthority(scope: { [self] native in try await filesystemScope(native) })
    }
    public func filesystemScope(_ native: NativeRPCContext) async throws -> BackendFilesystemScope {
        let (scope, _, caller) = try await freshCaller()
        guard native.caller == .pairedDevice, native.requestID == scope.requestID,
              native.ownerID == "native-clients:" + scope.requestID.uuidString else { throw refused("The filesystem projection has no matching native client credential.") }
        let known = Array(BackendDeckCoreCatalogueBuiltins.knownFolders(surface))
        let roots: [String]
        switch caller.kind {
        case .local: roots = known
        case .key: roots = caller.folders ?? known
        case .remote:
            guard let device = caller.deviceID, !device.isEmpty, let allowed = surface.deviceFolders(device) else { throw refused("The device has no current native folder grant.") }
            roots = allowed
        case .session:
            guard (caller.machineID ?? "").isEmpty, let project = caller.projectRoot, !project.isEmpty,
                  let sessionID = caller.sessionID, manager.list().contains(where: { $0.id == sessionID }) else { throw refused("The session has no current local native project grant.") }
            roots = [project]
        }
        let urls = roots.filter { $0.hasPrefix("/") && !$0.contains("\0") }.map { URL(fileURLWithPath: $0) }
        return BackendFilesystemScope(readRoots: caller.tiers.contains(.read) ? urls : [],
            writeRoots: caller.tiers.contains(.act) || caller.tiers.contains(.alter) ? urls : [])
    }
    public func caller(_ native: BackendMCPCallContext) async throws -> BackendKnowledgeToolCaller {
        let context = try await securityContext(native), (_, _, caller) = try await freshCaller(context)
        guard caller.kind == .session else { return .init(kind: clientKind(caller)) }
        guard let sessionID = caller.sessionID, let session = manager.list().first(where: { $0.id == sessionID }), sessionID == native.sessionID else {
            throw refused("This session is no longer one the native app is holding.")
        }
        var store: String?
        if ["claude", "codex"].contains(session.provider) {
            let profileID = session.profileId ?? BackendAccountProfile.systemID(session.provider)
            if let profile = try await profiles.find(profileID), profile.provider == session.provider { store = profile.configDir }
        }
        let record = try await tasks?.bySession(sessionID)
        let task = record.map { BackendKnowledgeTaskScope(taskId: $0.id, project: $0.project,
            agentId: $0.assigneeKind == "agent" ? $0.value["assignee"]["agentId"].string : nil,
            goalId: $0.value["goalId"].string, conversationId: $0.value["conversationId"].string) }
        _ = try await freshCaller(context)
        return .init(kind: .session, session: session, store: store, task: task)
    }
    public func requireKnownFolder(_ project: String) async throws -> String {
        guard let dispatch = Scope.dispatch, dispatch.authorityID == id else { throw BackendSessionFailure.missingCapability("the gated native client project call") }
        _ = try await freshCaller(dispatch.context)
        let known = try BackendDeckCoreCatalogueBuiltins.requireKnownFolder(surface, path: project)
        let native = try await filesystemContext(dispatch.context)
        _ = try await filesystemAuthority().authorize(known, context: native)
        return known
    }
    public func isLocalHoot(_ native: BackendMCPCallContext) async -> Bool {
        do { let context = try await securityContext(native); return try await freshCaller(context).2.kind == .local }
        catch { return false }
    }
    /// Called by the original memory/knowledge/plugin handlers after their own
    /// refusal checks. This proves they reached the actual central policy.run;
    /// it never recursively executes the tool or substitutes a no-op gate.
    public func authorize(_ native: BackendMCPCallContext, tool: String, arguments: NativeRPCValue, tier: BackendMCPTier) async throws {
        let context = try await securityContext(native)
        guard let dispatch = Scope.dispatch, dispatch.authorityID == id, dispatch.tool == tool, dispatch.tier == tier,
              dispatch.arguments == arguments, dispatch.context.callID == context.callID else {
            throw BackendSessionFailure.missingCapability("the completed native consent/budget/action-dispatch gate for " + tool)
        }
        try await revalidate(context, tool: tool)
    }

    /// The concrete catalogue grant callback retains a current policy snapshot;
    /// role filters below only add names admitted for the matched actual caller.
    public func replaceLazyMetadata(_ metadata: [BackendDeckCoreCatalogueMetadata]) throws {
        _ = try BackendDeckCoreCatalogueRegistry(metadata: metadata)
        lock.withLock { lazyMetadata = metadata }
    }
    public func liveMetadata() -> [BackendDeckCoreCatalogueMetadata] { lock.withLock { pluginMetadata } }
    public func livePolicies() -> [BackendDeckCoreSecurityToolPolicy] { lock.withLock { pluginPolicies } }
    public func clearPluginTools() { lock.withLock { pluginMetadata = []; pluginPolicies = [] } }
    public func retainPluginNames(_ names: Set<String>) {
        lock.withLock {
            pluginMetadata.removeAll { !names.contains($0.tool.id) && !names.contains($0.tool.wireName) }
            pluginPolicies.removeAll { !names.contains($0.tool.id) && !names.contains($0.tool.wireName) }
        }
    }
    /// Attach these callbacks before installing the graph. The core startup
    /// receives bundles(graph:) plus the live metadata/policy readers below.
    public func configure(_ supplied: BackendCompositionClientsDependencies,
        catalogue: BackendCompositionClientsDeckCatalogue) -> BackendCompositionClientsDependencies {
        var result = supplied
        result.knowledgeAuthority = self; result.pluginsAuthority = self; result.lazyCatalogue = catalogue
        result.pluginToolsChanged = { [self] names in retainPluginNames(names) }
        result.pluginRegistrationsChanged = { [self] host, registrations in try await replacePluginTools(host: host, registrations: registrations) }
        return result
    }
    public func enrichedGrant(_ base: BackendMCPCallerGrant, context native: BackendMCPCallContext) async throws -> BackendMCPCallerGrant {
        let context = try await securityContext(native), (scope, grant, caller) = try await freshCaller(context)
        let specs = lock.withLock { (lazyMetadata + pluginMetadata).map(\.tool) }
        var names = base.allowedTools
        let admitted = specs.filter { roleAllows($0.id, caller: caller) && base.allowedTiers.contains($0.tier) }
        names.formUnion(admitted.flatMap { [$0.id, $0.wireName] })
        if admitted.contains(where: { !$0.advertised }) { names.formUnion(["tools.describe", "tools_describe"]) }
        return BackendMCPCallerGrant(attended: base.attended, allowedTools: names, allowedTiers: base.allowedTiers, projectRoot: base.projectRoot,
            permitted: { [self] in
                guard await base.permitted(), !grant.cancellation.isCancelled, let current = await scope.current(),
                      current.identity == grant.identity, !current.cancellation.isCancelled else { return false }
                let now = await current.caller()
                return sameIdentity(now, caller) && !now.tiers.isEmpty
            })
    }

    /// `includeMemory: false` when deck-tools' memory-tools own memory.search/read in the core catalogue
    /// (TS: memoryTools is one of deck-control's extra tools; one owner per id).
    public func bundles(graph: BackendCompositionClients, includeMemory: Bool = true) throws -> [BackendDeckCoreCatalogueBundle] {
        var metadata: [BackendDeckCoreCatalogueMetadata] = [], policies: [BackendDeckCoreSecurityToolPolicy] = []
        if includeMemory, let memory = graph.memory {
            for tool in try BackendMemoryMCP.specifications() {
                let row = try BackendCompositionClientsDeckCatalogue.clientMetadata(tool: tool, index: BackendMemoryMCP.index[tool.id]!)
                metadata.append(row)
                policies.append(policy(metadata: row, handler: { [self] native, args in
                    .value(try await BackendMemoryMCP.call(tool: tool.id, args: args, context: native, service: memory, authority: self))
                }))
            }
        }
        if graph.domains.contains("knowledge"), let knowledge = graph.knowledge {
            for tool in try BackendKnowledgeMCP.specifications() {
                let row = try BackendCompositionClientsDeckCatalogue.clientMetadata(tool: tool, index: BackendKnowledgeMCP.index[tool.id]!)
                metadata.append(row)
                policies.append(policy(metadata: row, handler: { [self] native, args in
                    .value(try await BackendKnowledgeMCP.call(tool: tool.id, args: args, context: native, service: knowledge, authority: self))
                }))
            }
        }
        try replaceLazyMetadata(metadata)
        return metadata.isEmpty ? [] : [try BackendDeckCoreCatalogueBundle(metadata: metadata, policies: policies)]
    }
    public func replacePluginTools(host: BackendPluginsHost, registrations: [BackendPluginsChannels.ToolRegistration]) async throws {
        let sources = await host.contributors()
        var metadata: [BackendDeckCoreCatalogueMetadata] = [], policies: [BackendDeckCoreSecurityToolPolicy] = []
        for registration in registrations {
            guard let source = sources.first(where: { id, manifest in manifest.tools.contains { $0.actionID(id) == registration.spec.id } }),
                  let definition = source.1.tools.first(where: { $0.actionID(source.0) == registration.spec.id }) else {
                throw BackendSessionFailure.missingCapability("the current approved plugin manifest for " + registration.spec.id)
            }
            let row = BackendDeckCoreCatalogueMetadata(tool: registration.spec, title: definition.title + " (" + source.1.name + ")", audience: "copilot")
            metadata.append(row)
            policies.append(policy(metadata: row, handler: registration.handler,
                summary: { _, _ in "Run “" + definition.title + "” from the plugin “" + source.1.name + "”" },
                resultSummary: { _ in .object([.init("plugin", .string(source.0)), .init("tool", .string(definition.name))]) }))
        }
        _ = try BackendDeckCoreCatalogueRegistry(metadata: metadata)
        lock.withLock { pluginMetadata = metadata; pluginPolicies = policies }
    }
    private func policy(metadata: BackendDeckCoreCatalogueMetadata, handler: @escaping BackendNativeMCPServer.Handler,
        summary: (@Sendable (NativeRPCValue, BackendDeckCoreSecurityCallContext) throws -> String)? = nil,
        resultSummary: (@Sendable (NativeRPCValue) -> NativeRPCValue)? = nil) -> BackendDeckCoreSecurityToolPolicy {
        let tool = metadata.tool
        return BackendDeckCoreSecurityToolPolicy(tool: tool, audience: metadata.audience,
            summary: summary ?? { args, _ in Self.summary(tool.id, args) },
            precheck: { [self] _, context in
                try requireRole(tool.id, caller: context.caller)
            }, precheckAsync: { [self] _, context in try await revalidate(context, tool: tool.id) },
            run: { [self] args, context in
                try await revalidate(context, tool: tool.id)
                let dispatch = Dispatch(authorityID: id, tool: tool.id, tier: tool.tier, arguments: args, context: context)
                return try await Scope.$dispatch.withValue(dispatch) {
                    let reply = try await contexts.invoke(handler: handler, arguments: args, context: context)
                    if reply.isError { throw BackendDeckCoreSecurityRefusal(.notPermitted, reply.content.compactMap { $0["text"].string }.joined(separator: "\n")) }
                    guard let value = reply.structuredContent else { throw NativeRPCError.malformed("The native client tool did not return its source object result.") }
                    return BackendDeckCoreSecurityToolOutput(value: value, summary: resultSummary?(value) ?? Self.resultSummary(tool.id, value))
                }
            })
    }
    private static func summary(_ id: String, _ args: NativeRPCValue) -> String {
        let short = { (key: String) in String(decoding: Array((args[key].string ?? "?").utf16.prefix(80)), as: UTF16.self) }
        switch id {
        case "memory.search": return "Search memory for “" + (args["query"].string ?? "") + "”"
        case "memory.read": return args["path"].string.flatMap { $0.isEmpty ? nil : $0 }.map { "Read memory note " + $0 } ?? "List memory notes"
        case "knowledge.search":
            let query = args["query"].string.map { " for “" + String(decoding: Array($0.utf16.prefix(60)), as: UTF16.self) + "”" } ?? ""
            return "Search the knowledge of " + URL(fileURLWithPath: args["project"].string ?? "?").lastPathComponent + query
        case "knowledge.get": return "Read knowledge record " + (args["id"].string ?? "?")
        case "knowledge.record": return "Record a " + (args["kind"].string ?? "?") + " for " + URL(fileURLWithPath: args["project"].string ?? "?").lastPathComponent + ": " + short("subject")
        case "knowledge.supersede": return "Supersede knowledge record " + (args["id"].string ?? "?") + ": " + short("reason")
        default: return "Note a " + (args["kind"].string ?? "?") + ": " + short("subject")
        }
    }
    private static func resultSummary(_ id: String, _ value: NativeRPCValue) -> NativeRPCValue {
        switch id {
        case "memory.search": return .object([.init("spaces", .number(Double(value["spaces"].elements?.count ?? 0))), .init("results", .number(Double(value["results"].elements?.count ?? 0)))])
        case "memory.read":
            if let memories = value["memories"].elements { return .object([.init("spaces", .number(Double(memories.count))), .init("notes", .number(Double(memories.reduce(0) { $0 + ($1["notes"].elements?.count ?? 0) })))]) }
            return .object([.init("path", value["path"]), .init("chars", .number(Double(value["text"].string?.utf16.count ?? 0)))])
        case "knowledge.search": return .object([.init("found", .number(Double(value["records"].elements?.count ?? 0))), .init("of", value["of"])])
        case "knowledge.supersede": return .object([.init("id", value["superseded"]["id"]), .init("replacement", value["replacement"]["id"].isNullish ? .null : value["replacement"]["id"])])
        case "knowledge.note": return .object([.init("id", value["noted"]["id"])])
        default: return .object([.init("id", value["record"]["id"]), .init("status", value["record"]["status"])])
        }
    }
}
