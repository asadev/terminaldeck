import Foundation
import TerminalDeckNativeCore

/// Startup joins over real retained owners. Missing bindings refuse; these
/// adapters never allocate another Store, PTY, caller table or policy gate.
public final class BackendCompositionProductionBindings: BackendDeckCoreEventsMCPProvider,
    BackendDeckCoreFeatureLifecycle, BackendDeckCoreProjectEvidence, BackendDeckCoreSecurityTaskHTTP, @unchecked Sendable {
    public let root: BackendCompositionRoot
    public let state: BackendCompositionState
    public let configuration: BackendAccountConfiguration
    public let contexts = BackendDeckCoreToolContextAuthority()
    public let hidden = BackendRemoteServeSessionHidden()
    private let lock = NSLock()
    private var sessionOwner: BackendCompositionSessions?
    private var authorityOwner: BackendCompositionAuthority?
    private var fileOwner: BackendCompositionFiles?
    private var usageOwner: BackendCompositionUsage?
    private var clientOwner: BackendCompositionClients?
    private var clientAuthorityOwner: BackendCompositionClientsSecurityAuthority?
    private var clientMCPOwner: BackendCompositionClientsMCPProvider?
    private var clientPolicies: [String: BackendDeckCoreSecurityToolPolicy] = [:]
    /// Contributions by owner (clients, deck-tools, …); replacing one never drops another.
    private var contributionOrder: [String] = []
    private var extraMetadataByOwner: [String: [BackendDeckCoreCatalogueMetadata]] = [:]
    private var extraPoliciesByOwner: [String: [BackendDeckCoreSecurityToolPolicy]] = [:]
    private var coreControl: BackendDeckCoreSecurityControl?
    private var agentControl: (@Sendable (String, String, String) async throws -> Void)?
    private var taskWake: (@Sendable () async -> Void)?
    private var taskHTTP: (any BackendDeckCoreSecurityTaskHTTP)?
    private var taskStop: (@Sendable () async -> Void)?
    private var recoveredControl: BackendDeckCoreSecurityControl?
    private var coreEndpoint: BackendDeckCoreSecurityEndpoint?
    private var remoteTrust: BackendRemoteTrustStore?
    private var remoteHost: BackendRemoteHost?
    private var remoteWindows: BackendRemoteServeWindowGrants?
    private var machineCoordinator: BackendMachineCoordinator?
    private var releaseBrowser: (@Sendable (String) async throws -> Void)?
    private var windowRows: [String: [NativeRPCValue]] = [:]
    private var phoneStop: (@Sendable () async -> Void)?
    private var hookAdditional: (@Sendable (BackendSessionHookEvent) async throws -> String?)?
    private var taskMonitor: BackendTaskTurnMonitor?
    private var reportTask: (@Sendable (String) -> Void)?
    private var closed = false
    private struct GrantScope: Sendable {
        let grant: BackendDeckCoreSecurityGrant
        let cancellation: BackendMCPCancellation
        let requestID: UUID
    }
    private enum Exchange { @TaskLocal static var scope: GrantScope? }
    private final class Invocation: @unchecked Sendable {
        let tool: String, arguments: NativeRPCValue, callID: String
        private let lock = NSLock()
        private var receipt: (tier: BackendMCPTier, owner: Bool)?
        private var noted: NativeRPCValue?
        func note(_ summary: NativeRPCValue) { lock.withLock { noted = summary } }
        var summary: NativeRPCValue? { lock.withLock { noted } }
        init(tool: String, arguments: NativeRPCValue, callID: String) { self.tool = tool; self.arguments = arguments; self.callID = callID }
        func covers(_ tier: BackendMCPTier, owner: Bool) -> Bool {
            lock.withLock {
                guard let receipt else { return false }
                let rank: (BackendMCPTier) -> Int = { $0 == .alter ? 2 : $0 == .act ? 1 : 0 }
                return rank(receipt.tier) >= rank(tier) && (!owner || receipt.owner)
            }
        }
        var entered: Bool { lock.withLock { receipt != nil } }
        func accept(_ tier: BackendMCPTier, owner: Bool) { lock.withLock { receipt = (tier, owner) } }
    }
    private enum NativeCall { @TaskLocal static var invocation: Invocation? }
    public func invokeNative(tool: String, handler: BackendNativeMCPServer.Handler, arguments: NativeRPCValue,
                             context: BackendDeckCoreSecurityCallContext) async throws -> BackendMCPToolReply {
        try await NativeCall.$invocation.withValue(Invocation(tool: tool, arguments: arguments, callID: context.callID)) {
            try await contexts.invoke(handler: handler, arguments: arguments, context: context)
        }
    }
    public func prepareNative(_ native: BackendMCPCallContext, tier: BackendMCPTier, sentence: String, ownerMustAnswer: Bool = false) async throws {
        let context = try await authority().resolve(native)
        guard let call = NativeCall.invocation, call.callID == context.callID else { throw missing("the running native policy arguments") }
        if call.entered {
            guard call.covers(tier, owner: ownerMustAnswer) else { throw NativeRPCError(code: "consent-required", message: "This operation exceeds its already accepted effect.") }
            return
        }
        try await authority().authorize(native, tool: call.tool, arguments: call.arguments,
            tier: tier, sentence: sentence, ownerMustAnswer: ownerMustAnswer)
        call.accept(ownerMustAnswer ? .alter : tier, owner: ownerMustAnswer)
    }
    public func nativeTool(_ native: BackendMCPCallContext) async throws -> (String, NativeRPCValue) {
        let context = try await authority().resolve(native)
        guard let call = NativeCall.invocation, call.callID == context.callID else { throw missing("the running native tool") }
        return (call.tool, call.arguments)
    }
    public init(root: BackendCompositionRoot, state: BackendCompositionState, configuration: BackendAccountConfiguration) {
        self.root = root; self.state = state; self.configuration = configuration
    }
    private func missing(_ name: String) -> NativeRPCError {
        .init(code: "composition-incomplete", message: "The production graph has not bound its actual " + name + ".")
    }
    public func bind(core: BackendDeckCoreRuntime) { lock.withLock { coreEndpoint = core.endpoint; coreControl = core.control } }
    /// The source result summary of the running native tool call, for its one action-log row.
    public func noteNative(_ native: BackendMCPCallContext, summary: NativeRPCValue) async {
        guard let call = NativeCall.invocation, let context = try? await authority().resolve(native), call.callID == context.callID else { return }
        call.note(summary)
    }
    /// The one gate every deck-tools production adapter uses (prepareEffect once per call; summary to the same row).
    public func deckToolsGate() throws -> BackendCompositionDeckToolsGate {
        BackendCompositionDeckToolsGate(authority: try authority(), authorize: { [self] native, tier, sentence, owner in
            try await prepareNative(native, tier: tier, sentence: sentence, ownerMustAnswer: owner)
        }, noteResult: { [self] native, summary in await noteNative(native, summary: summary) })
    }
    /// A deck-tools definition entered through the ONE core door: deck-core checks grant, base tier,
    /// budget and consent; the handler may raise its effective tier once through prepareNative.
    public func nativePolicy(_ definition: BackendDeckToolsDefinition) -> BackendDeckCoreSecurityToolPolicy {
        mcpPolicy(definition.catalogueMetadata, handler: definition.handler)
    }
    /// Any native MCP handler (deck-tools, Safari, tasks, servers) behind the ONE core door,
    /// with its source catalogue row; the same invocation/redaction/summary rules for all.
    public func mcpPolicy(_ metadata: BackendDeckCoreCatalogueMetadata, handler: @escaping BackendNativeMCPServer.Handler) -> BackendDeckCoreSecurityToolPolicy {
        let tool = metadata.tool
        return wrapped(BackendDeckCoreSecurityToolPolicy(tool: tool, aliases: metadata.aliases, audience: metadata.audience,
            summary: { _, _ in metadata.title.isEmpty ? "Run " + tool.id : metadata.title },
            redactArgs: { args in Self.redacted(tool.id, args) },
            run: { [self] args, context in
                let call = Invocation(tool: tool.id, arguments: args, callID: context.callID)
                let reply = try await NativeCall.$invocation.withValue(call) {
                    try await contexts.invoke(handler: handler, arguments: args, context: context)
                }
                let text = reply.content.compactMap { $0["text"].string }.joined(separator: "\n")
                if reply.isError {
                    throw NativeRPCError(code: reply.structuredContent?["refusal"].string ?? "tool-error", message: text.isEmpty ? "that could not be done." : text)
                }
                let value = reply.structuredContent ?? (try? NativeRPCValue.parseJSON(Data(text.utf8))) ?? .string(text)
                return BackendDeckCoreSecurityToolOutput(value: value, summary: call.summary)
            }))
    }
    /// What the one action-log row keeps of a deck-tools call's arguments (TS: asset-tools scrubUrlArgs,
    /// files.upload's content replaced by its size, app-tools' own redaction list).
    public static func redacted(_ id: String, _ args: NativeRPCValue) -> NativeRPCValue {
        if id.hasPrefix("assets.") { return BackendDeckToolsAssets.redact(args) }
        if id == "devices.type" || id == "servers.manage" { return BackendDeckToolsMachinesFactory.loggedArguments(toolID: id, arguments: args) }
        if id == "files.upload", let content = args["contentBase64"].string {
            return args.setting("contentBase64", .string("[\(content.count) base64 characters]"))
        }
        return BackendDeckToolsAppKit.redacted(id, args)
    }
    /// TS window-serve.ts serveWindowCall: a paired machine's session acts on a window here through
    /// the same control door, as a session caller keyed <machineID, sessionID>, attended as asked.
    public func machineWindowCall(_ tool: String, arguments: NativeRPCValue, caller: BackendMachineWindowCaller) async throws -> NativeRPCValue {
        guard let control = lock.withLock({ coreControl }) else {
            throw NativeRPCError(code: "unavailable", message: "this computer’s control endpoint is not running yet. Try again in a moment; it comes up shortly after the app window does.")
        }
        let result = await control.call(name: tool, arguments: arguments, options: .init(
            caller: .init(kind: .session, tiers: caller.tiers, sessionID: caller.sessionID, machineID: caller.machineID), attended: caller.attended))
        guard result.ok else { throw NativeRPCError(code: "refused", message: result.error ?? "that could not be done.") }
        return result.value
    }
    /// The live agent-controls owner (TS agent-controls.ts applyControl), bound once it exists.
    public func bindAgentControls(_ apply: @escaping @Sendable (String, String, String) async throws -> Void) { lock.withLock { agentControl = apply } }
    public func setAgentControl(sessionID: String, control: String, value: String) async throws {
        guard let apply = lock.withLock({ agentControl }) else { throw missing("agent controls owner") }
        try await apply(sessionID, control, value)
    }
    public func withPolicyContext<T: Sendable>(_ context: BackendDeckCoreSecurityCallContext,
        operation: @Sendable () async throws -> T) async throws -> T {
        if Exchange.scope != nil { return try await operation() }
        guard context.caller.kind == .local, !context.attended,
              let endpoint = lock.withLock({ coreEndpoint }),
              let grant = await endpoint.callers.match(authorization: "Bearer " + endpoint.unattendedToken),
              !grant.attended else { throw missing("the actual in-process unattended credential") }
        let observer = grant.cancellation.observe { context.cancellation.cancel() }
        defer { grant.cancellation.removeObserver(observer) }
        let clientAuthority = lock.withLock { clientAuthorityOwner }
        return try await Exchange.$scope.withValue(.init(grant: grant, cancellation: context.cancellation, requestID: UUID())) {
            guard let clientAuthority else { return try await operation() }
            return try await clientAuthority.withAuthenticatedGrant(grant: grant, cancellation: context.cancellation, operation: operation)
        }
    }
    public func wrapped(_ original: BackendDeckCoreSecurityToolPolicy) -> BackendDeckCoreSecurityToolPolicy {
        .init(tool: original.tool, aliases: original.aliases, audience: original.audience,
            keyRequiresTasks: original.keyRequiresTasks, spendsDeviceInput: original.spendsDeviceInput,
            summary: original.summary, precheck: original.precheck,
            precheckAsync: { [self] args, context in try await withPolicyContext(context) { try await original.precheckAsync?(args, context) } },
            escalate: original.escalate, ownerMustAnswer: original.ownerMustAnswer, redactArgs: original.redactArgs,
            run: { [self] args, context in try await withPolicyContext(context) { try await original.run(args, context) } })
    }
    public func bind(authority: BackendCompositionAuthority) throws {
        try lock.withLock { guard !closed, authorityOwner == nil else { throw missing("authority") }; authorityOwner = authority }
    }
    public func bind(sessions: BackendCompositionSessions) throws {
        try lock.withLock { guard !closed, sessionOwner == nil else { throw missing("sessions") }; sessionOwner = sessions }
    }
    public func bind(files: BackendCompositionFiles, usage: BackendCompositionUsage) {
        lock.withLock { fileOwner = files; usageOwner = usage }
    }
    public func bind(clients: BackendCompositionClients, authority: BackendCompositionClientsSecurityAuthority,
                     mcp: BackendCompositionClientsMCPProvider) throws {
        let policies = try mcp.policies()
        try lock.withLock {
            guard !closed, clientOwner == nil else { throw missing("clients") }
            clientOwner = clients; clientAuthorityOwner = authority; clientMCPOwner = mcp
            clientPolicies = Dictionary(uniqueKeysWithValues: policies.map { ($0.tool.id, $0) })
        }
    }
    public func sessions() throws -> BackendCompositionSessions {
        try lock.withLock { guard !closed, let sessionOwner else { throw missing("sessions") }; return sessionOwner }
    }
    public func authority() throws -> BackendCompositionAuthority {
        try lock.withLock { guard !closed, let authorityOwner else { throw missing("authority") }; return authorityOwner }
    }
    public func clients() throws -> BackendCompositionClients {
        try lock.withLock { guard !closed, let clientOwner else { throw missing("clients") }; return clientOwner }
    }
    private func clientMCP() throws -> BackendCompositionClientsMCPProvider {
        try lock.withLock { guard !closed, let clientMCPOwner else { throw missing("MCP clients") }; return clientMCPOwner }
    }
    public func authenticated(grant: BackendDeckCoreSecurityGrant, cancellation: BackendMCPCancellation,
                              operation: @escaping @Sendable () async -> Void) async throws {
        let observer = grant.cancellation.observe { cancellation.cancel() }
        defer { grant.cancellation.removeObserver(observer) }
        let clientAuthority = lock.withLock { clientAuthorityOwner }
        try await Exchange.$scope.withValue(.init(grant: grant, cancellation: cancellation, requestID: UUID())) {
            guard !cancellation.isCancelled, !grant.cancellation.isCancelled else { throw CancellationError() }
            if let clientAuthority {
                await clientAuthority.withAuthenticatedGrant(grant: grant, cancellation: cancellation, operation: operation)
            } else { await operation() }
        }
    }
    private func grant() async throws -> BackendDeckCoreSecurityCaller {
        let caller: BackendDeckCoreSecurityCaller
        if let scope = Exchange.scope, !scope.cancellation.isCancelled, !scope.grant.cancellation.isCancelled {
            caller = await scope.grant.caller()
        } else {
            guard let endpoint = lock.withLock({ coreEndpoint }),
                  let actual = await endpoint.callers.match(authorization: "Bearer " + endpoint.unattendedToken), !actual.cancellation.isCancelled else {
                throw missing("authenticated core exchange")
            }
            caller = await actual.caller()
        }
        guard !caller.tiers.isEmpty else { throw NativeRPCError(code: "access-denied", message: "The core caller's grant has expired.") }
        return caller
    }
    public func startSession(_ raw: NativeRPCValue) async throws -> NativeRPCValue {
        let caller = try await grant()
        guard caller.kind != .remote else { throw missing("device-aware session starter") }
        let input = try JSONDecoder().decode(BackendCreateSessionInput.self, from: raw.encodedJSON())
        let session = try await sessions().lifecycle.create(input, context: .init(rememberTab: true))
        return try NativeRPCValue.parseJSON(JSONEncoder().encode(session))
    }
    public func writeSession(_ id: String, _ data: String) async throws {
        _ = try await grant(); try await sessions().lifecycle.write(sessionID: id, data: data)
    }
    public func closeSession(_ id: String) async throws {
        _ = try await grant(); try await sessions().lifecycle.close(sessionID: id)
    }
    public func accountTranscriptScope() async throws -> NativeTranscriptScope {
        let graph = try sessions()
        let profiles = try await graph.profiles.list(provider: "claude")
        var scope = NativeTranscriptScope(configDirectory: configuration.systemDirectory("claude"),
            deviceHomesRoot: root.dataRoot.appendingPathComponent("remote/device-home").path,
            homeScopes: configuration.homeScopes, additionalConfigDirectories: profiles.map(\.configDir))
        scope.homeScopes.append(BackendCopilotSessionRuntime.homeScope(userData: root.dataRoot.path))
        return scope
    }
    public func transcriptScope(project: String? = nil) async throws -> NativeTranscriptScope {
        let caller = try await grant()
        var scope = try await accountTranscriptScope()
        switch caller.kind {
        case .local: break
        case .key: scope.projectFolders = caller.folders
        case .session:
            guard let id = caller.sessionID,
                  let record = await (try sessions()).lifecycle.metadata().first(where: { $0.session.id == id }),
                  record.session.provider == "claude", let configuration = record.transcriptConfiguration else { throw missing("session transcript attribution") }
            scope.configDirectory = configuration; scope.additionalConfigDirectories = []; scope.deviceHomesRoot = nil
            scope.projectFolders = caller.projectRoot.map { [$0] } ?? []
        case .remote:
            guard let id = caller.deviceID else { throw missing("remote transcript caller") }
            scope = try await remoteTranscriptScope(deviceID: id)
        }
        if let project {
            let known = state.listProjects().compactMap { $0["path"].string } + [state.copilotRoot()]
            guard known.contains(project), scope.projectFolders == nil || scope.projectFolders!.contains(where: { BackendCompositionAuthority.within(project, $0) }) else {
                throw NativeRPCError(code: "access-denied", message: "The transcript folder is outside this core caller's grant.")
            }
            scope.projectFolders = [project]
        }
        return scope
    }
    public func evidenceContext() throws -> NativeRPCContext {
        guard let scope = Exchange.scope, !scope.cancellation.isCancelled, !scope.grant.cancellation.isCancelled else { throw missing("evidence caller") }
        return .init(caller: .page, ownerID: "core-evidence:" + scope.requestID.uuidString,
            requestID: scope.requestID, capabilities: ["files.read", "git.read", "projects.read"])
    }
    public func filesystemScope(_ context: NativeRPCContext) async throws -> BackendFilesystemScope {
        if context.caller == .nativeApp { return try await authority().filesystemScope(context) }
        if let exchange = Exchange.scope, context.requestID == exchange.requestID,
           context.ownerID == "core-evidence:" + exchange.requestID.uuidString {
            let caller = try await grant()
            let known = state.listProjects().compactMap { $0["path"].string } + [state.copilotRoot()]
            let paths: [String]
            switch caller.kind {
            case .local: paths = known
            case .key: paths = caller.folders ?? known
            case .session: paths = caller.projectRoot.map { [$0] } ?? []
            case .remote: throw missing("remote filesystem authority")
            }
            return .init(readRoots: caller.tiers.contains(.read) ? paths.map { URL(fileURLWithPath: $0) } : [], writeRoots: [])
        }
        return try await authority().filesystemScope(context)
    }
    /// Policies passed here are ALREADY wrapped by their owner (nativePolicy/wrapped).
    public func replaceContributions(owner: String, _ bundles: [BackendDeckCoreCatalogueBundle], policiesWrapped: Bool = false) throws {
        let metadata = bundles.flatMap(\.metadata), policies = bundles.flatMap(\.policies)
        let others = lock.withLock { extraMetadataByOwner.filter { $0.key != owner }.values.flatMap { $0 } }
        _ = try BackendDeckCoreCatalogueRegistry(metadata: others + metadata)
        lock.withLock {
            if extraMetadataByOwner[owner] == nil { contributionOrder.append(owner) }
            extraMetadataByOwner[owner] = metadata
            extraPoliciesByOwner[owner] = policiesWrapped ? policies : policies.map(wrapped)
        }
    }
    public func liveMetadata() -> [BackendDeckCoreCatalogueMetadata] {
        let values = lock.withLock { (contributionOrder.flatMap { extraMetadataByOwner[$0] ?? [] }, clientAuthorityOwner) }
        return values.0 + (values.1?.liveMetadata() ?? [])
    }
    public func livePolicies() -> [BackendDeckCoreSecurityToolPolicy] {
        let values = lock.withLock { (contributionOrder.flatMap { extraPoliciesByOwner[$0] ?? [] }, clientAuthorityOwner) }
        return values.0 + (values.1?.livePolicies() ?? []).map(wrapped)
    }
    public func beforeListing() async throws { try await clients().refreshPluginTools() }
    private func policy(_ id: String) throws -> BackendDeckCoreSecurityToolPolicy {
        try lock.withLock { guard !closed, let policy = clientPolicies[id] else { throw missing("MCP policy " + id) }; return policy }
    }
    public func mcpPolicies() throws -> [BackendDeckCoreSecurityToolPolicy] {
        try BackendDeckCoreEventsTools.mcpPolicies(provider: self).map { seed in
            let id = seed.tool.id
            return wrapped(BackendDeckCoreSecurityToolPolicy(tool: seed.tool, aliases: seed.aliases, audience: seed.audience,
                keyRequiresTasks: seed.keyRequiresTasks, spendsDeviceInput: seed.spendsDeviceInput,
                summary: { [self] args, context in try policy(id).summary(args, context) },
                precheck: { [self] args, context in try policy(id).precheck?(args, context) },
                precheckAsync: { [self] args, context in try await policy(id).precheckAsync?(args, context) },
                escalate: { [self] args, context in try policy(id).escalate?(args, context) },
                ownerMustAnswer: { [self] args in try policy(id).ownerMustAnswer?(args) ?? false },
                redactArgs: { [self] args in try policy(id).redactArgs?(args) ?? args },
                run: { [self] args, context in try await policy(id).run(args, context) }))
        }
    }
    public func bindRemote(trust: BackendRemoteTrustStore, host: BackendRemoteHost, windows: BackendRemoteServeWindowGrants) {
        lock.withLock { remoteTrust = trust; remoteHost = host; remoteWindows = windows }
    }
    public func bindMachines(_ coordinator: BackendMachineCoordinator) { lock.withLock { machineCoordinator = coordinator } }
    public func bindBrowser(release: @escaping @Sendable (String) async throws -> Void) { lock.withLock { releaseBrowser = release } }
    /// Lane BR: the hook endpoint's extra context (attached browser windows, TS index.ts contextFor).
    public func bindHookContext(_ hook: @escaping @Sendable (BackendSessionHookEvent) async throws -> String?) { lock.withLock { hookAdditional = hook } }
    public func updateBrowserWindows(_ rows: [String: [NativeRPCValue]]) { lock.withLock { windowRows = rows } }
    public func browserWindows(sessionID: String) -> [NativeRPCValue] { lock.withLock { windowRows[sessionID] ?? [] } }
    public func reachesDeviceWindows(_ id: String) async -> Bool {
        guard let windows = lock.withLock({ remoteWindows }) else { return false }
        return (try? await windows.drives(id)) == true
    }
    public func remoteBrowserPrincipal(_ context: NativeRPCContext) async throws -> BackendBrowserPrincipal {
        guard context.caller == .pairedDevice, let trust = lock.withLock({ remoteTrust }),
              await trust.isApproved(context.ownerID), await trust.kindOf(context.ownerID) == .mine,
              await reachesDeviceWindows(context.ownerID) else { throw missing("the live My-device window grant") }
        return .init(ownerID: context.ownerID, managesWindows: true)
    }
    public func hostHoldsWindows() async -> Bool { lock.withLock { !windowRows.isEmpty } }
    public func releaseSession(_ id: String) async throws {
        if let release = lock.withLock({ releaseBrowser }) { try await release(id) }
        if let host = lock.withLock({ remoteHost }) { await host.sessionsChanged() }
    }
    public func hookContext(_ event: BackendSessionHookEvent) async throws -> String? {
        if let hook = lock.withLock({ hookAdditional }) { return try await hook(event) }
        // The native hook server still supplies its provider context; extra
        // context is optional until a task/routine is actually attached.
        return nil
    }
    public func remoteAuthority() -> BackendCompositionRemoteAuthority {
        .init(filesystem: { [self] context in
            guard let id = context.caller.deviceID else { throw missing("remote identity") }
            return try await remoteFilesystem(deviceID: id, tiers: context.caller.tiers)
        }, transcripts: { [self] project, context in
            guard let id = context.caller.deviceID else { throw missing("remote identity") }
            var scope = try await remoteTranscriptScope(deviceID: id)
            if let project {
                guard scope.projectFolders?.contains(where: { BackendCompositionAuthority.within(project, $0) }) == true else { throw missing("remote project grant") }
                scope.projectFolders = [project]
            }
            return scope
        }, requireSession: { [self] id, context in
            guard let trust = lock.withLock({ remoteTrust }), let device = context.caller.deviceID,
                  await trust.isApproved(device), await trust.sessionShared(device, session: id) else { throw missing("remote session grant") }
        }, launch: { [self] input, context in
            guard let id = context.caller.deviceID else { throw missing("remote identity") }
            return .init(deviceBoundary: try await deviceBoundary(deviceID: id, folder: input.cwd), rememberTab: true)
        })
    }
    public func deviceBoundary(deviceID: String, folder: String) async throws -> BackendDeviceBoundary {
        guard let trust = lock.withLock({ remoteTrust }), await trust.isApproved(deviceID), await trust.canReachFolder(deviceID, folder: folder) else {
            throw NativeRPCError(code: "access-denied", message: "The device no longer has this folder grant.")
        }
        return .init(deviceKey: deviceID, folder: folder)
    }
    private func remoteFilesystem(deviceID: String, tiers: Set<BackendMCPTier>) async throws -> BackendFilesystemScope {
        guard let trust = lock.withLock({ remoteTrust }), await trust.isApproved(deviceID) else { throw missing("approved device") }
        let offered = state.listProjects().compactMap { $0["path"].string }
        let reach = await trust.reach(deviceID, offered: offered, home: configuration.homeDirectory.path)
        let paths = reach.folders.map { URL(fileURLWithPath: $0) }
        return .init(readRoots: tiers.contains(.read) ? paths : [], writeRoots: tiers.contains(.act) || tiers.contains(.alter) ? paths : [])
    }
    private func remoteTranscriptScope(deviceID: String) async throws -> NativeTranscriptScope {
        guard let trust = lock.withLock({ remoteTrust }), await trust.isApproved(deviceID) else { throw missing("approved device") }
        let offered = state.listProjects().compactMap { $0["path"].string }
        let reach = await trust.reach(deviceID, offered: offered, home: configuration.homeDirectory.path)
        var scope = try await accountTranscriptScope()
        scope.projectFolders = reach.folders
        // Guest callers never inherit the desktop's account transcript roots.
        if await trust.kindOf(deviceID) == .guest {
            scope.configDirectory = root.dataRoot.appendingPathComponent("remote/device-home").appendingPathComponent(deviceID).appendingPathComponent(".claude").path
            scope.additionalConfigDirectories = []; scope.deviceHomesRoot = nil
        }
        return scope
    }
    public func guestGitPlanner() -> BackendGitRunner.DevicePlanner {
        { [self] context, plan in
            let device: String?
            if context.caller == .pairedDevice { device = context.ownerID }
            else if let exchange = Exchange.scope, context.requestID == exchange.requestID {
                device = try await grant().deviceID
            } else { device = try await authority().rpcCaller(context).deviceID }
            guard let device else { return plan }
            let boundary = try await deviceBoundary(deviceID: device, folder: plan.cwd)
            guard let confinement = await (try sessions()).macConfinement else { throw missing("the session owner's Mac confinement") }
            // Guest Git keeps no owner's token, SSH agent or account-home env.
            let path = plan.environment["PATH"] ?? configuration.inheritedEnvironment["PATH"] ?? ""
            let account = BackendAccountLaunch(profile: nil, environment: [:], path: path)
            let confined = try await confinement.resolve(command: plan.command, args: plan.arguments,
                input: .init(cwd: plan.cwd, provider: "shell"), account: account, context: .init(deviceBoundary: boundary))
            var environment = ["PATH": path, "LC_ALL": "C", "GIT_TERMINAL_PROMPT": "0", "GIT_PAGER": "cat", "PAGER": "cat"]
            environment.merge(confined.environment) { _, value in value }
            for key in confined.removeEnvironment { environment[key] = nil }
            return .init(command: confined.command, arguments: confined.args, environment: environment,
                cwd: confined.hostCwd ?? plan.cwd)
        }
    }
    public func stopPhoneRuns() -> (@Sendable () async -> Void)? { lock.withLock { phoneStop } }
    public func recover(control: BackendDeckCoreSecurityControl) async throws { lock.withLock { recoveredControl = control } }
    // The shared lifecycle fanout already delivers these to usage. Tasks'
    // monitor follows that same lifecycle directly, so no duplicate PTY parse.
    public func noteStatus(sessionID: String, status: String) async {
        let fields = lock.withLock { (taskMonitor, reportTask) }
        guard let monitor = fields.0, let status = BackendSessionStatus(rawValue: status) else { return }
        do { try await monitor.noteStatus(sessionID: sessionID, status: status) } catch { fields.1?(error.localizedDescription) }
    }
    public func noteExit(sessionID: String, exitCode: Int) async {
        let fields = lock.withLock { (taskMonitor, reportTask) }
        do { try await fields.0?.noteExit(sessionID: sessionID, exitCode: exitCode) } catch { fields.1?(error.localizedDescription) }
    }
    public func bindTaskMonitor(_ monitor: BackendTaskTurnMonitor, report: @escaping @Sendable (String) -> Void) {
        lock.withLock { taskMonitor = monitor; reportTask = report }
    }
    public func noteTaskSend(_ id: String) async { if let monitor = lock.withLock({ taskMonitor }) { await monitor.noteSend(sessionID: id) } }
    public func bindTasks(wake: @escaping @Sendable () async -> Void, stop: @escaping @Sendable () async -> Void,
                          http: any BackendDeckCoreSecurityTaskHTTP) { lock.withLock { taskWake = wake; taskStop = stop; taskHTTP = http } }
    public func answer(method: String, path: String, authorization: String?, body: String) async throws -> BackendDeckCoreSecurityHTTPResponse {
        guard let actual = lock.withLock({ taskHTTP }) else { throw missing("the task HTTP owner") }
        return try await actual.answer(method: method, path: path, authorization: authorization, body: body)
    }
    public func tasksWake() async { if let wake = lock.withLock({ taskWake }) { await wake() } }
    public func stopTasks() async { if let stop = lock.withLock({ taskStop }) { await stop() } }
    public func stopPlugins() async { if let clients = lock.withLock({ clientOwner }) { await clients.plugins?.stopAll() } }
    public func gitStatus(cwd: String) async throws -> NativeRPCValue {
        guard let files = lock.withLock({ fileOwner }) else { throw missing("Git") }
        return try await files.git.status(cwd: cwd, context: evidenceContext())
    }
    public func alerts(projectPath: String) async throws -> NativeRPCValue {
        guard let usage = lock.withLock({ usageOwner }) else { throw missing("alerts") }
        return try await usage.alerts.project(projectPath, context: evidenceContext())
    }
    public func collectFolderDiff(sessions: [NativeRPCValue], cwd: String, path: String?, maxFiles: Int) async throws -> NativeRPCValue {
        guard let files = lock.withLock({ fileOwner }) else { throw missing("Git review") }
        return try await BackendDeckToolsFleetDiff.collect(review: files.review, cwd: cwd, path: path, maxFiles: maxFiles, context: evidenceContext())
    }

    public func knownFolder(_ path: String, context: BackendDeckCoreSecurityCallContext) throws -> String { try clientMCP().knownFolder(path, context: context) }
    public func resolveAdd(_ request: NativeRPCValue) throws -> NativeRPCValue { try clientMCP().resolveAdd(request) }
    public func resolveEdit(_ request: NativeRPCValue) throws -> NativeRPCValue { try clientMCP().resolveEdit(request) }
    public func resolveRemove(_ request: NativeRPCValue) throws -> NativeRPCValue { try clientMCP().resolveRemove(request) }
    public func resolveInstall(_ request: NativeRPCValue) throws -> NativeRPCValue { try clientMCP().resolveInstall(request) }
    public func list(projectPath: String?) async throws -> [NativeRPCValue] { try await clientMCP().list(projectPath: projectPath) }
    public func add(_ request: NativeRPCValue) async throws -> NativeRPCValue { try await clientMCP().add(request) }
    public func edit(_ request: NativeRPCValue) async throws -> NativeRPCValue { try await clientMCP().edit(request) }
    public func remove(_ request: NativeRPCValue) async throws -> NativeRPCValue { try await clientMCP().remove(request) }
    public func inventory(id: String, projectPath: String?) async throws -> NativeRPCValue { try await clientMCP().inventory(id: id, projectPath: projectPath) }
    public func disconnect(id: String) async throws -> NativeRPCValue? { try await clientMCP().disconnect(id: id) }
    public func call(id: String, tool: String, arguments: NativeRPCValue, projectPath: String?) async throws -> NativeRPCValue { try await clientMCP().call(id: id, tool: tool, arguments: arguments, projectPath: projectPath) }
    public func store(projectPath: String?) async throws -> NativeRPCValue { try await clientMCP().store(projectPath: projectPath) }
    public func install(_ request: NativeRPCValue) async throws -> NativeRPCValue { try await clientMCP().install(request) }
    public func toolFile(name: String, scope: String, projectPath: String?) async throws -> NativeRPCValue? { try await clientMCP().toolFile(name: name, scope: scope, projectPath: projectPath) }
}
