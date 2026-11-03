import Foundation
import TerminalDeckNativeCore

/// The actual host-owned native server and existing private lease owner.
/// App detach never invokes stop(), revoke(), or private-file cleanup here.
public actor BackendHOSTMCPPersistence {
    public nonisolated let server: BackendNativeMCPServer
    public nonisolated let endpoint: BackendHOSTMCPPreservedEndpoint
    public nonisolated let sessionTools: BackendSessionToolLeases
    private let relay: BackendHOSTAppRelayServer
    private let sessionsDrained: @Sendable () async -> Bool
    private let userData: URL
    private enum LeaseOwner: Sendable {
        case session
        case project(BackendProjectToolComposition, machineID: String)
    }
    private struct Binding: Sendable {
        let sessionID: String, machineID: String
        let operation: Task<Void, Error>
    }
    private struct BindingReceipt: Equatable, Sendable { let sessionID: String, machineID: String }
    private var owners: [UUID: LeaseOwner] = [:]
    private var settingsFiles: [UUID: BackendAGSLaunchFileLease] = [:]
    private var bindings: [UUID: Binding] = [:]
    private var retirement: [UUID: Task<Void, Never>] = [:]
    private var pendingExpiry: [UUID: Task<Void, Never>] = [:]
    private var completedBindings: [UUID: BindingReceipt] = [:]
    private var completedAgentSettings: Set<UUID> = []
    private var receiptOrder: [UUID] = []
    private var abandonedClaims: Set<UUID> = []
    private var abandonedOrder: [UUID] = []
    private var projectSource: (any BackendProjectMCPSource)?
    private var projectEnvironment: [String: String] = [:]
    private var stopped = false
    public struct Projection: Codable, Sendable {
        public var url: String?
        public var callerCount: Int
        public var leaseCount: Int
        public var appAttached: Bool
    }

    public init(server: BackendNativeMCPServer, relay: BackendHOSTAppRelayServer, userData: URL,
                sessionsDrained: @escaping @Sendable () async -> Bool) throws {
        self.server = server; self.relay = relay; self.sessionsDrained = sessionsDrained; self.userData = userData
        let endpoint = BackendHOSTMCPPreservedEndpoint(server: server); self.endpoint = endpoint
        sessionTools = try BackendSessionToolLeases(endpoint: endpoint, userData: userData)
    }
    /// Supply the real catalogue from app factories, preserving schemas, names,
    /// tier and implementation; no invented replacement tool descriptions.
    public func installTools(_ tools: [BackendMCPTool]) async throws {
        guard !stopped else { throw BackendHOSTFailure.unavailable }
        let relay = relay, endpoint = endpoint
        let handlers: [(BackendMCPTool, BackendNativeMCPServer.Handler)] = tools.map { spec in
            (spec, { context, arguments in
                let project: String?
                do { project = try await endpoint.taskProject(for: context) }
                catch { return .failure("The original session tool grant could not be verified. Nothing was executed.") }
                return await relay.invoke(tool: spec, context: context, taskProject: project, arguments: arguments)
            })
        }
        try await server.replaceTools(ownerID: "native.host.persistent-app-tools", tools: handlers)
    }
    public func start() async throws -> BackendMCPEndpointDescription {
        guard !stopped else { throw BackendHOSTFailure.unavailable }; return try await server.start()
    }
    public func projection() async -> Projection {
        let projects = owners.values.filter { if case .project = $0 { return true }; return false }.count
        return .init(url: await server.description()?.url.absoluteString, callerCount: await endpoint.count,
              leaseCount: await sessionTools.count + projects, appAttached: relay.projection().attached)
    }
    public func prepareOrdinary(restricting allowedTools: [String]?, deniedTools: [String], taskID: String? = nil,
                                taskProject: String? = nil) async throws -> BackendPreparedToolLease? {
        guard !stopped else { throw BackendSessionFailure.closed }
        let value = try await sessionTools.prepareOrdinary(restricting: allowedTools, deniedTools: deniedTools,
                                                          taskID: taskID, taskProject: taskProject)
        guard let value else { return nil }
        guard !stopped, !Task.isCancelled else { await sessionTools.abandon(value.id); throw BackendSessionFailure.closed }
        remember(value.id, owner: .session)
        return value
    }
    public func reserveAgentSettingsFiles() async throws -> BackendAGSLaunchFileLease {
        guard !stopped else { throw BackendSessionFailure.closed }
        let actual = try await sessionTools.reserveAgentSettingsFiles()
        guard !stopped, !Task.isCancelled else { await actual.abandon(); throw BackendSessionFailure.closed }
        remember(actual.id, owner: .session); settingsFiles[actual.id] = actual
        // These are the actual owner's file operations, behind the same bind
        // transaction as ordinary/project leases. No app-owned files are made.
        return BackendAGSLaunchFileLease(id: actual.id, directory: actual.directory, write: { [weak self] files in
            guard let self else { throw BackendSessionFailure.closed }
            try await self.writeAgentSettingsFiles(actual.id, files: files)
        }, bind: { [weak self] session in
            guard let self else { throw BackendSessionFailure.closed }
            try await self.bindAgentSettingsFiles(actual.id, sessionID: session)
        }, abandon: { [weak self] in await self?.abandonPrepared(actual.id) })
    }
    public func writeAgentSettingsFiles(_ id: UUID, files: [String: Data]) async throws {
        guard !stopped, retirement[id] == nil, bindings[id] == nil, let actual = settingsFiles[id] else {
            throw BackendSessionFailure.invalidInput("The pending host agent settings lease is unavailable or already claimed.")
        }
        try await actual.write(files)
        guard !stopped, retirement[id] == nil else { throw BackendSessionFailure.closed }
    }
    public func bindAgentSettingsFiles(_ id: UUID, sessionID: String) async throws {
        guard settingsFiles[id] != nil || completedAgentSettings.contains(id) else { throw BackendSessionFailure.closed }
        // The existing AGS closure has only a session parameter. When pre-exec
        // has already supplied the real machine, preserve that exact identity.
        let machine = bindings[id]?.machineID ?? completedBindings[id]?.machineID ?? ""
        try await bindPrepared(id, sessionID: sessionID, machineID: machine)
    }
    public func agentSettingsConfiguration(_ id: UUID) async throws -> NativeRPCValue {
        guard !stopped, retirement[id] == nil, let owner = owners[id] else { throw BackendSessionFailure.closed }
        switch owner {
        case .session: return try await sessionTools.agentSettingsConfiguration(id)
        case .project(let project, _): return try await project.agentSettingsConfiguration(id)
        }
    }
    /// Pre-exec and post-create claims share exactly one original bind. A
    /// different machine/session cannot silently replace the original grant.
    public func bindPrepared(_ id: UUID, sessionID: String, machineID: String) async throws {
        guard !stopped, !abandonedClaims.contains(id), !sessionID.isEmpty,
              !sessionID.contains("\0"), !machineID.contains("\0") else { throw BackendSessionFailure.closed }
        let receipt = BindingReceipt(sessionID: sessionID, machineID: machineID)
        if let completed = completedBindings[id] {
            guard completed == receipt else { throw BackendSessionFailure.invalidInput("The retired host tool lease belongs to a different session or machine.") }
            if let pending = retirement[id] { await pending.value }
            guard !stopped, !abandonedClaims.contains(id) else { throw BackendSessionFailure.closed }
            try Task.checkCancellation(); return
        }
        guard retirement[id] == nil, let owner = owners[id] else { throw BackendSessionFailure.closed }
        if let existing = bindings[id] {
            guard existing.sessionID == sessionID, existing.machineID == machineID else {
                throw BackendSessionFailure.invalidInput("The host tool lease is already claimed by a different session or machine.")
            }
            try await existing.operation.value
            rememberBinding(id, receipt: receipt)
            if let pending = retirement[id] { await pending.value }
            guard !stopped, !abandonedClaims.contains(id) else { throw BackendSessionFailure.closed }
            if Task.isCancelled { await abandonPrepared(id); throw CancellationError() }
            return
        }
        if case .project(_, let expectedMachine) = owner, expectedMachine != machineID {
            throw BackendSessionFailure.invalidInput("The project lease was prepared for a different machine.")
        }
        let tools = sessionTools
        let operation = Task<Void, Error> {
            switch owner {
            case .session: try await tools.bind(id, sessionID: sessionID, machineID: machineID)
            case .project(let project, _): try await project.bind(id, sessionID: sessionID)
            }
        }
        bindings[id] = Binding(sessionID: sessionID, machineID: machineID, operation: operation)
        pendingExpiry.removeValue(forKey: id)?.cancel()
        do { try await operation.value }
        catch { await abandonPrepared(id); throw error }
        rememberBinding(id, receipt: receipt)
        if let pending = retirement[id] { await pending.value }
        guard !stopped, !abandonedClaims.contains(id) else { throw BackendSessionFailure.closed }
        // A cancelled launch still waits for the real bind to finish, then
        // retires the exact lease. It cannot return while a bind can resurrect it.
        if Task.isCancelled { await abandonPrepared(id); throw CancellationError() }
    }
    public func abandonPrepared(_ id: UUID) async {
        if owners[id] != nil || completedBindings[id] != nil {
            if abandonedClaims.insert(id).inserted { abandonedOrder.append(id) }
            completedBindings[id] = nil; completedAgentSettings.remove(id)
            if abandonedOrder.count > 4096 { abandonedClaims.remove(abandonedOrder.removeFirst()) }
        }
        await retirePrepared(id)
    }
    private func retirePrepared(_ id: UUID) async {
        if let pending = retirement[id] { await pending.value; forgetOwner(id); return }
        guard let owner = owners[id] else { return }
        pendingExpiry.removeValue(forKey: id)?.cancel()
        let binding = bindings[id], tools = sessionTools
        let pending = Task<Void, Never> {
            if let binding {
                do {
                    try await binding.operation.value
                    self.rememberBinding(id, receipt: .init(sessionID: binding.sessionID, machineID: binding.machineID))
                } catch {}
            }
            switch owner {
            case .session: await tools.abandon(id)
            case .project(let project, _): await project.abandon(id); await project.stop()
            }
        }
        retirement[id] = pending
        await pending.value
        forgetOwner(id)
    }
    private func forgetOwner(_ id: UUID) {
        owners[id] = nil; settingsFiles[id] = nil; bindings[id] = nil; retirement[id] = nil
    }
    /// Process/descendant drain is enforced by the Resources caller. App
    /// detach must never call this method.
    public func releasePrepared(sessionID: String) async {
        let ids = bindings.compactMap { $0.value.sessionID == sessionID ? $0.key : nil }
        for id in ids { await retirePrepared(id) }
        // Include any older direct registrations made before wrapper adoption.
        await sessionTools.release(sessionID: sessionID)
    }
    public func configureProjectTools(source: any BackendProjectMCPSource, inheritedEnvironment: [String: String]) throws {
        guard !stopped, projectSource == nil else { throw BackendSessionFailure.invalidInput("The actual host project source is already configured or stopped.") }
        projectSource = source; projectEnvironment = inheritedEnvironment
    }
    public func projectReadiness() -> BackendLaunchReadiness {
        if stopped { return .unavailable("The host project lease owner stopped.") }
        return projectSource?.readiness ?? .unavailable("No actual helper-owned project source is configured. Supply the original resolved stdio definition for each launch.")
    }
    public func prepareProject(definition: BackendHOSTProjectDefinition? = nil, provider: String, cwd: String, loginPath: String,
                               allowedTools: [String]? = nil, deniedTools: [String] = [], taskID: String? = nil,
                               taskProject: String? = nil, machineID: String, inheritedEnvironment: [String: String]? = nil) async throws -> BackendPreparedProjectTools? {
        guard !stopped, !machineID.contains("\0") else { throw BackendSessionFailure.closed }
        let source = try resolvedProjectSource(definition: definition, cwd: cwd)
        let project = try BackendProjectToolComposition(source: BackendHOSTMachineProjectSource(source: source, machineID: machineID),
            userData: userData, inheritedEnvironment: inheritedEnvironment ?? projectEnvironment)
        do {
            guard let value = try await project.prepare(provider: provider, cwd: cwd, loginPath: loginPath,
                allowedTools: allowedTools, deniedTools: deniedTools, taskID: taskID, taskProject: taskProject) else {
                await project.stop(); return nil
            }
            guard !stopped, !Task.isCancelled else { await project.stop(); throw BackendSessionFailure.closed }
            remember(value.id, owner: .project(project, machineID: machineID))
            return value
        } catch { await project.stop(); throw error }
    }
    public func projectAgentSettingsServerName(definition: BackendHOSTProjectDefinition? = nil, provider: String,
                                               cwd: String, loginPath: String) async throws -> String? {
        guard !stopped else { throw BackendSessionFailure.closed }
        let source = try resolvedProjectSource(definition: definition, cwd: cwd)
        guard let actual = try await source.resolve(cwd: cwd, provider: provider, loginPath: loginPath) else { return nil }
        switch actual { case .stdio(_, let spec): return spec.name; case .registeredEndpoint(_, let name, _, _, _): return name }
    }
    public func projectAgentSettingsConfiguration(_ id: UUID) async throws -> NativeRPCValue {
        guard case .project? = owners[id] else { throw BackendSessionFailure.invalidInput("No actual host project lease owns this configuration.") }
        return try await agentSettingsConfiguration(id)
    }
    private func resolvedProjectSource(definition: BackendHOSTProjectDefinition?, cwd: String) throws -> any BackendProjectMCPSource {
        if let definition { return try BackendHOSTResolvedProjectSource(definition: definition, cwd: cwd) }
        guard let projectSource else { throw BackendSessionFailure.missingCapability("the actual host project source or original resolved stdio definition") }
        return projectSource
    }
    private func remember(_ id: UUID, owner: LeaseOwner) {
        owners[id] = owner
        // The original actors expire unclaimed files after 60 seconds. Retire
        // this provenance/actor holder too, so abandoned app transactions cannot
        // retain expired project composers forever.
        pendingExpiry[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            await self?.expirePending(id)
        }
    }
    private func rememberBinding(_ id: UUID, receipt: BindingReceipt) {
        guard !abandonedClaims.contains(id) else { return }
        if completedBindings[id] == nil { receiptOrder.append(id) }
        completedBindings[id] = receipt
        if settingsFiles[id] != nil { completedAgentSettings.insert(id) }
        if receiptOrder.count > 4096 {
            let old = receiptOrder.removeFirst(); completedBindings[old] = nil; completedAgentSettings.remove(old)
        }
    }
    private func expirePending(_ id: UUID) async {
        guard bindings[id] == nil else { return }
        await abandonPrepared(id)
    }
    public nonisolated func appAttachmentID() -> UUID? { relay.appAttachmentID() }
    public nonisolated func currentAppPID() -> Int32? { relay.projection().appPID }
    /// Token-free provenance lookup on the authenticated app/helper socket. This is not
    /// an MCP grant and cannot create or widen a retained session registration.
    public func currentSessionCaller(_ context: BackendMCPCallContext) async throws -> NativeRPCValue {
        try await endpoint.currentSessionCaller(context)
    }
    public func currentRelayedSessionCaller(_ callID: UUID) async throws -> NativeRPCValue {
        let original = try relay.currentSessionCall(callID)
        let result = try await endpoint.currentSessionCaller(original.context)
        let current = try relay.currentSessionCall(callID)
        guard current.context.cancellation === original.context.cancellation, !current.context.cancellation.isCancelled else { throw BackendHOSTFailure.authentication }
        return result.setting("callID", .string(callID.uuidString)).setting("toolID", .string(original.toolID))
            .setting("wireName", .string(original.wireName)).setting("tier", .string(original.tier.rawValue))
            .setting("argumentsDigest", .string(try BackendHOSTSessionToolRelay.argumentsDigest(original.arguments)))
    }
    public func sessionCallerResource(_ arguments: NativeRPCValue) async throws -> NativeRPCValue {
        guard Set(arguments.fields?.map(\.key) ?? []) == ["callID"],
              let id = arguments["callID"].string.flatMap(UUID.init(uuidString:)) else { throw BackendHOSTFailure.authentication }
        return try await currentRelayedSessionCaller(id)
    }
    public func invokeControl(operation: BackendHOSTAppRelayControl.Operation, arguments: NativeRPCValue) async throws -> NativeRPCValue {
        try await relay.invokeControl(operation: operation, arguments: arguments)
    }
    public func stopAfterSessionsDrained() async throws {
        guard await sessionsDrained() else { throw BackendHOSTFailure.remote("Running sessions still own these MCP grants and private files. Stop was refused.") }
        guard !stopped else { return }; stopped = true
        for id in Array(owners.keys) { await abandonPrepared(id) }
        await sessionTools.stop(); await server.stop(); await endpoint.clearAfterServerStopped(); relay.stop()
        completedBindings.removeAll(); completedAgentSettings.removeAll(); receiptOrder.removeAll()
        abandonedClaims.removeAll(); abandonedOrder.removeAll()
    }
}

/// This is a provenance projection over the REAL serving caller table, not a
/// token authentication table. No token value or digest is retained here.
public actor BackendHOSTMCPPreservedEndpoint: BackendMCPToolEndpoint {
    public nonisolated let readiness: BackendLaunchReadiness = .ready
    private struct Binding: Sendable { var grant: BackendMCPCallerGrant; var sessionID: String?; var machineID = "" }
    private let server: BackendNativeMCPServer
    private var bindings: [UUID: Binding] = [:]
    private var closed = false
    public init(server: BackendNativeMCPServer) { self.server = server }
    public var count: Int { bindings.count }
    public func description() async throws -> BackendMCPEndpointDescription? { await server.description() }
    public func catalogue() async throws -> [BackendMCPTool] { try await server.catalogue() }
    public func register(token: String, grant: BackendMCPCallerGrant) async throws -> BackendMCPRegistration {
        // Preserve permitted(), attended, project/task roots, names and tiers
        // exactly. The existing native server retains/rechecks the real grant.
        guard !closed else { throw BackendHOSTFailure.unavailable }
        let registered = try await server.register(token: token, grant: grant)
        guard !closed else { await server.revoke(registered); throw BackendHOSTFailure.unavailable }
        bindings[registered.id] = Binding(grant: grant); return registered
    }
    public func bind(_ registration: BackendMCPRegistration, sessionID: String, machineID: String) async throws {
        guard !closed, bindings[registration.id] != nil else { throw BackendHOSTFailure.authentication }
        try await server.bind(registration, sessionID: sessionID, machineID: machineID)
        guard !closed, var value = bindings[registration.id] else { throw BackendHOSTFailure.authentication }
        value.sessionID = sessionID; value.machineID = machineID; bindings[registration.id] = value
    }
    public func revoke(_ registration: BackendMCPRegistration) async {
        bindings[registration.id] = nil; await server.revoke(registration)
    }
    func clearAfterServerStopped() { closed = true; bindings.removeAll() }
    func currentSessionCaller(_ context: BackendMCPCallContext) async throws -> NativeRPCValue {
        guard !closed, !context.cancellation.isCancelled else { throw BackendHOSTFailure.authentication }
        func matches(_ binding: Binding) -> Bool {
            binding.sessionID == context.sessionID && binding.machineID == context.machineID &&
                binding.grant.projectRoot == context.projectRoot && binding.grant.attended == context.attended &&
                binding.grant.allowedTools == context.allowedTools && binding.grant.allowedTiers == context.allowedTiers
        }
        let ids = Set(bindings.filter { matches($0.value) }.map(\.key))
        guard !ids.isEmpty else { throw BackendHOSTFailure.authentication }
        var project: String? = nil, haveProject = false
        for id in ids {
            guard let original = bindings[id], await original.grant.permitted(), !closed,
                  !context.cancellation.isCancelled, let current = bindings[id], matches(current) else { throw BackendHOSTFailure.authentication }
            if haveProject, project != current.grant.taskProject { throw BackendHOSTFailure.authentication }
            project = current.grant.taskProject; haveProject = true
        }
        guard Set(bindings.filter { matches($0.value) }.map(\.key)) == ids, !closed else { throw BackendHOSTFailure.authentication }
        return .object([.init("sessionID", .string(context.sessionID)), .init("machineID", .string(context.machineID)),
            .init("projectRoot", context.projectRoot.map(NativeRPCValue.string) ?? .null),
            .init("taskProject", project.map(NativeRPCValue.string) ?? .null),
            .init("tools", .array(context.allowedTools.sorted().map(NativeRPCValue.string))),
            .init("tiers", .array(context.allowedTiers.map(\.rawValue).sorted().map(NativeRPCValue.string)))])
    }
    func taskProject(for context: BackendMCPCallContext) throws -> String? {
        let matching = bindings.values.filter {
            $0.sessionID == context.sessionID && $0.machineID == context.machineID && $0.grant.projectRoot == context.projectRoot
                && $0.grant.attended == context.attended && $0.grant.allowedTools == context.allowedTools && $0.grant.allowedTiers == context.allowedTiers
        }
        guard !matching.isEmpty else { throw BackendHOSTFailure.authentication }
        let scopes = Set(matching.map { $0.grant.taskProject })
        guard scopes.count == 1 else { throw BackendHOSTFailure.invalid("Ambiguous original task scope.") }
        return matching[0].grant.taskProject
    }
}

/// Private authenticated launch payload made from the original resolved
/// project source. It carries no invented executable, server, or grant.
public struct BackendHOSTProjectDefinition: Codable, Sendable {
    public let root: String, name: String, command: String
    public let arguments: [String], environment: [String: String]
    public let implementation: String
    public init(_ definition: BackendProjectMCPDefinition) throws {
        guard case .stdio(let root, let spec) = definition else {
            throw BackendSessionFailure.unsupported("An app-owned registered project endpoint needs its actual helper-owned source; it cannot be transferred as a stdio definition.")
        }
        self.root = root; name = spec.name; command = spec.command; arguments = spec.arguments
        environment = spec.environment; implementation = spec.implementation.rawValue
    }
    fileprivate func spec() throws -> BackendProjectMCPServerSpec {
        guard let implementation = BackendMCPImplementation(rawValue: implementation) else { throw BackendHOSTFailure.invalid("Unsupported actual project server implementation.") }
        return try .init(name: name, command: command, arguments: arguments, environment: environment, implementation: implementation)
    }
}

private struct BackendHOSTResolvedProjectSource: BackendProjectMCPSource {
    let readiness: BackendLaunchReadiness = .ready
    let definition: BackendProjectMCPDefinition
    let launchDirectory: String
    init(definition: BackendHOSTProjectDefinition, cwd: String) throws {
        guard definition.root.hasPrefix("/"), cwd.hasPrefix("/"), !definition.root.contains("\0"), !cwd.contains("\0") else {
            throw BackendHOSTFailure.invalid("The actual project definition needs absolute project and launch directories.")
        }
        let root = URL(fileURLWithPath: definition.root).standardizedFileURL.path
        launchDirectory = URL(fileURLWithPath: cwd).standardizedFileURL.path
        guard launchDirectory == root || launchDirectory.hasPrefix(root == "/" ? "/" : root + "/") else {
            throw BackendHOSTFailure.invalid("The actual project definition does not own this launch directory.")
        }
        self.definition = .stdio(root: root, server: try definition.spec())
    }
    func resolve(cwd: String, provider: String, loginPath: String) async throws -> BackendProjectMCPDefinition? {
        guard URL(fileURLWithPath: cwd).standardizedFileURL.path == launchDirectory else { throw BackendHOSTFailure.invalid("The resolved project definition belongs to a different launch directory.") }
        return definition
    }
}

/// The canonical project composer binds with its default empty machine. This
/// adapter forwards that one operation with the immutable real launch identity;
/// all catalogue, token registration and scope checks stay in the actual owner.
/// The same endpoint, with every session bound to this launch's machine.
private struct BackendHOSTMachineBoundEndpoint: BackendMCPToolEndpoint {
    let endpoint: any BackendMCPToolEndpoint, machineID: String
    var readiness: BackendLaunchReadiness { endpoint.readiness }
    func description() async throws -> BackendMCPEndpointDescription? { try await endpoint.description() }
    func catalogue() async throws -> [BackendMCPTool] { try await endpoint.catalogue() }
    func register(token: String, grant: BackendMCPCallerGrant) async throws -> BackendMCPRegistration { try await endpoint.register(token: token, grant: grant) }
    func bind(_ registration: BackendMCPRegistration, sessionID: String, machineID supplied: String) async throws {
        guard supplied.isEmpty || supplied == machineID else { throw BackendHOSTFailure.authentication }
        try await endpoint.bind(registration, sessionID: sessionID, machineID: machineID)
    }
    func revoke(_ registration: BackendMCPRegistration) async { await endpoint.revoke(registration) }
}
private struct BackendHOSTMachineProjectSource: BackendProjectMCPSource {
    let source: any BackendProjectMCPSource, machineID: String
    var readiness: BackendLaunchReadiness { source.readiness }
    func resolve(cwd: String, provider: String, loginPath: String) async throws -> BackendProjectMCPDefinition? {
        guard let value = try await source.resolve(cwd: cwd, provider: provider, loginPath: loginPath) else { return nil }
        switch value {
        case .stdio: return value
        case .registeredEndpoint(let root, let name, let endpoint, let names, let launcher):
            return .registeredEndpoint(root: root, serverName: name, endpoint: BackendHOSTMachineBoundEndpoint(endpoint: endpoint, machineID: machineID),
                                       toolNames: names, stdioLauncher: launcher)
        }
    }
}
