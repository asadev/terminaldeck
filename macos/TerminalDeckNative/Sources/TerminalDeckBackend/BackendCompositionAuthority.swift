import Foundation
import TerminalDeckNativeCore

/// Actual credential-resolved deck-core gate, supplied by the one core owner.
/// These callbacks must prove the effective operation's consent/budget receipt
/// and record its result in that same action log. There are no permit defaults.
public struct BackendCompositionCoreGate: Sendable {
    public let authorize: @Sendable (BackendDeckCoreSecurityCallContext, String, NativeRPCValue, BackendMCPTier, String, Bool) async throws -> Void
    public let record: @Sendable (BackendDeckCoreSecurityCallContext, String, NativeRPCValue, NativeRPCValue) async throws -> Void
    public init(authorize: @escaping @Sendable (BackendDeckCoreSecurityCallContext, String, NativeRPCValue, BackendMCPTier, String, Bool) async throws -> Void,
                record: @escaping @Sendable (BackendDeckCoreSecurityCallContext, String, NativeRPCValue, NativeRPCValue) async throws -> Void) {
        self.authorize = authorize; self.record = record
    }
}

/// The remote owner supplies live grants/home boundaries. A missing remote
/// supplier refuses that caller; it never inherits the Mac owner's account.
public struct BackendCompositionRemoteAuthority: Sendable {
    public let filesystem: @Sendable (BackendDeckCoreSecurityCallContext) async throws -> BackendFilesystemScope
    public let transcripts: @Sendable (String?, BackendDeckCoreSecurityCallContext) async throws -> NativeTranscriptScope
    public let requireSession: @Sendable (String, BackendDeckCoreSecurityCallContext) async throws -> Void
    public let launch: @Sendable (BackendCreateSessionInput, BackendDeckCoreSecurityCallContext) async throws -> BackendLaunchContext
    public init(filesystem: @escaping @Sendable (BackendDeckCoreSecurityCallContext) async throws -> BackendFilesystemScope,
                transcripts: @escaping @Sendable (String?, BackendDeckCoreSecurityCallContext) async throws -> NativeTranscriptScope,
                requireSession: @escaping @Sendable (String, BackendDeckCoreSecurityCallContext) async throws -> Void,
                launch: @escaping @Sendable (BackendCreateSessionInput, BackendDeckCoreSecurityCallContext) async throws -> BackendLaunchContext) {
        self.filesystem = filesystem; self.transcripts = transcripts; self.requireSession = requireSession; self.launch = launch
    }
}

/// Current local UI identity plus exact per-call core capabilities. This is a
/// projection/adapter, not a second caller table, session ledger or Store.
public final class BackendCompositionAuthority: @unchecked Sendable {
    public let prepared: BackendCompositionSessions.Prepared
    public let state: BackendCompositionState
    public let configuration: BackendAccountConfiguration
    public let coreContexts: BackendDeckCoreToolContextAuthority
    public let gate: BackendCompositionCoreGate
    public let hidden: BackendRemoteServeSessionHidden
    private let hootHomeScope: NativeTranscriptHomeScope
    private let remote: BackendCompositionRemoteAuthority?
    private let lock = NSLock()
    private var graph: BackendCompositionSessions?
    private var open = true
    private var uiAlive = true
    private struct Ticket: Sendable {
        let native: BackendMCPCallContext
        let context: NativeRPCContext
        var effects: Set<BackendMCPTier> = []
    }
    private var tickets: [UUID: Ticket] = [:]
    private var statusReceipts: [String: (status: String, at: Double)] = [:]

    public init(prepared: BackendCompositionSessions.Prepared, state: BackendCompositionState,
                configuration: BackendAccountConfiguration, coreContexts: BackendDeckCoreToolContextAuthority,
                gate: BackendCompositionCoreGate, hidden: BackendRemoteServeSessionHidden,
                remote: BackendCompositionRemoteAuthority? = nil) throws {
        guard state.store.file?.deletingLastPathComponent().standardizedFileURL == configuration.dataDirectory.standardizedFileURL,
              prepared.environment == configuration.inheritedEnvironment else {
            throw NativeRPCError.invalidArguments("Composition authority must share the actual Store folder and prepared session environment")
        }
        self.prepared = prepared; self.state = state; self.configuration = configuration
        self.coreContexts = coreContexts; self.gate = gate; self.hidden = hidden; self.remote = remote
        hootHomeScope = BackendCopilotSessionRuntime.homeScope(userData: configuration.dataDirectory.path)
    }
    public func bind(_ sessions: BackendCompositionSessions) throws {
        try lock.withLock {
            guard open, graph == nil, sessions.manager === prepared.manager else { throw unavailable("the one prepared session graph") }
            graph = sessions
        }
    }
    public func sessions() throws -> BackendCompositionSessions {
        try lock.withLock { guard open, let graph else { throw unavailable("the activated native session/account owner") }; return graph }
    }
    public func requireLocalUI(_ context: NativeRPCContext) throws {
        guard lock.withLock({ open && uiAlive }), context.caller == .nativeApp, context.ownerID == BackendCompositionRoot.appOwnerID else {
            throw NativeRPCError(code: "access-denied", message: "This operation belongs to the current native app window")
        }
    }
    public func localContext(requestID: UUID = UUID()) throws -> NativeRPCContext {
        let context = NativeRPCContext(caller: .nativeApp, ownerID: BackendCompositionRoot.appOwnerID, requestID: requestID)
        try requireLocalUI(context); return context
    }
    public func revokeLocalUI() { lock.withLock { uiAlive = false } }
    public func localUIOpened() { lock.withLock { if open { uiAlive = true } } }
    public func close() {
        let cancelled = lock.withLock { open = false; uiAlive = false; let values = tickets.values.map { $0.native.cancellation }; tickets.removeAll(); return values }
        cancelled.forEach { $0.cancel() }
    }

    public func resolve(_ native: BackendMCPCallContext) async throws -> BackendDeckCoreSecurityCallContext {
        guard lock.withLock({ open }), !native.cancellation.isCancelled else { throw CancellationError() }
        let context = try await coreContexts.context(for: native)
        guard !context.cancellation.isCancelled else { throw CancellationError() }
        return context
    }
    public func rpc(_ native: BackendMCPCallContext) async throws -> NativeRPCContext {
        let core = try await resolve(native)
        return lock.withLock {
            tickets = tickets.filter { !$0.value.native.cancellation.isCancelled }
            if let existing = tickets.values.first(where: { $0.native.cancellation === native.cancellation }) { return existing.context }
            var capabilities: Set<String> = []
            if core.caller.tiers.contains(.read) { capabilities.formUnion(["files.read", "git.read", "projects.read", "dev.read"]) }
            if core.caller.tiers.contains(.act) || core.caller.tiers.contains(.alter) { capabilities.formUnion(["files.write", "git.write", "projects.write", "dev.start"]) }
            // Page keeps filesystem limits enforced; a keyed/session caller is
            // never translated into nativeApp/internalEngine owner authority.
            let rpc = NativeRPCContext(caller: .page, ownerID: "core-call:" + core.callID, capabilities: capabilities)
            tickets[rpc.requestID] = Ticket(native: native, context: rpc); return rpc
        }
    }
    private func ticket(_ context: NativeRPCContext) throws -> Ticket {
        try lock.withLock {
            guard open, let ticket = tickets[context.requestID], ticket.context.ownerID == context.ownerID,
                  context.caller == .page, !ticket.native.cancellation.isCancelled else { throw unavailable("a current credential-resolved core call") }
            return ticket
        }
    }
    public func authorizeMutation(_ context: NativeRPCContext) throws {
        if context.caller == .nativeApp { try requireLocalUI(context); return }
        let proof = try ticket(context)
        guard !proof.effects.isDisjoint(with: [.act, .alter]) else { throw NativeRPCError(code: "access-denied", message: "This core call has no accepted mutation receipt") }
    }
    public func authorizeMetadata(_ context: NativeRPCContext) throws {
        if context.caller == .nativeApp { try requireLocalUI(context); return }
        _ = try ticket(context)
    }
    public func authorize(_ native: BackendMCPCallContext, tool: String, arguments: NativeRPCValue, tier: BackendMCPTier,
                          sentence: String, ownerMustAnswer: Bool = false) async throws {
        let core = try await resolve(native)
        guard core.native.allowedTiers.contains(tier), core.native.allowedTools.contains(tool) || core.native.allowedTools.contains(tool.replacingOccurrences(of: ".", with: "_")) else {
            throw NativeRPCError(code: "access-denied", message: "The current core caller is not granted this operation")
        }
        try await gate.authorize(core, tool, arguments, tier, sentence, ownerMustAnswer)
        _ = try await resolve(native)
        let rpc = try await self.rpc(native)
        lock.withLock { tickets[rpc.requestID]?.effects.insert(tier) }
    }
    public func record(_ native: BackendMCPCallContext, tool: String, arguments: NativeRPCValue, summary: NativeRPCValue) async throws {
        let core = try await resolve(native)
        try await gate.record(core, tool, arguments, summary)
    }

    public func filesystemScope(_ context: NativeRPCContext) async throws -> BackendFilesystemScope {
        if context.caller == .nativeApp { try requireLocalUI(context); return .local }
        let ticket = try ticket(context), core = try await resolve(ticket.native)
        if core.caller.kind == .remote {
            guard let remote else { throw unavailable("the remote caller's live folder/home grants") }
            let scope = try await remote.filesystem(core)
            guard !scope.unrestricted else { throw NativeRPCError(code: "access-denied", message: "A remote caller cannot inherit the Mac owner's filesystem") }
            return BackendFilesystemScope(readRoots: scope.readRoots + scope.writeRoots,
                writeRoots: ticket.effects.isDisjoint(with: [.act, .alter]) ? [] : scope.writeRoots)
        }
        let folders = try await allowedFolders(core)
        var reads = folders.map { URL(fileURLWithPath: $0) }
        if core.caller.kind == .local || core.caller.kind == .key && core.caller.folders == nil {
            reads.append(configuration.homeDirectory)
        }
        let scope = try await transcriptScope(project: nil, context: context)
        if let projects = scope.projectFolders {
            for project in projects { reads += try NativeTranscriptPaths.projectDirectories(project, scope: scope).map { URL(fileURLWithPath: $0) } }
        } else { reads += try NativeTranscriptPaths.approvedRoots(scope).map { URL(fileURLWithPath: $0) } }
        return BackendFilesystemScope(readRoots: reads, writeRoots: ticket.effects.isDisjoint(with: [.act, .alter]) ? [] : folders.map { URL(fileURLWithPath: $0) })
    }
    /// Same credential-resolved context used by domain RPC projections.
    public func rpcCaller(_ context: NativeRPCContext) async throws -> BackendDeckCoreSecurityCaller {
        try await resolve(ticket(context).native).caller
    }
    public func nativeCaller(_ context: NativeRPCContext) async throws -> BackendMCPCallContext {
        let actual = try ticket(context).native
        _ = try await resolve(actual)
        return actual
    }
    public func knownFolder(_ folder: String, native: BackendMCPCallContext) async throws -> String {
        let core = try await resolve(native), allowed = try await allowedFolders(core)
        guard state.listProjects().contains(where: { $0["path"].string == folder }), allowed.contains(where: { Self.within(folder, $0) }) else {
            throw NativeRPCError(code: "access-denied", message: "That project is outside this caller's current project grant")
        }
        return folder
    }
    private func allowedFolders(_ core: BackendDeckCoreSecurityCallContext) async throws -> [String] {
        let projects = state.listProjects().compactMap { $0["path"].string }
        switch core.caller.kind {
        case .local: return projects
        case .key: return core.caller.folders.map { granted in projects.filter { folder in granted.contains { Self.within(folder, $0) } } } ?? projects
        case .session:
            guard let id = core.caller.sessionID, let session = prepared.manager.list().first(where: { $0.id == id && $0.exitCode == nil }) else { throw unavailable("the caller's live session") }
            let root = core.caller.projectRoot ?? session.cwd
            return projects.filter { Self.within($0, root) }
        case .remote:
            guard let remote else { throw unavailable("the remote caller's current folder grants") }
            let scope = try await remote.filesystem(core)
            guard !scope.unrestricted else { throw NativeRPCError(code: "access-denied", message: "A remote caller cannot inherit the Mac owner's filesystem") }
            return projects.filter { folder in (scope.readRoots + scope.writeRoots).contains { Self.within(folder, $0.path) } }
        }
    }
    public func requireSession(_ id: String, native: BackendMCPCallContext) async throws -> BackendSessionMeta {
        let core = try await resolve(native)
        guard let session = prepared.manager.list().first(where: { $0.id == id }) else { throw BackendSessionFailure.missingSession }
        switch core.caller.kind {
        case .local: break
        case .key:
            if let folders = core.caller.folders, !folders.contains(where: { Self.within(session.cwd, $0) }) { throw NativeRPCError(code: "access-denied", message: "This session is outside the key's granted folders") }
        case .session:
            guard id == core.caller.sessionID || core.caller.projectRoot.map({ Self.within(session.cwd, $0) }) == true else { throw NativeRPCError(code: "access-denied", message: "This session belongs to a different caller/project") }
        case .remote:
            guard let remote, !hidden.contains(id) else { throw BackendSessionFailure.missingSession }
            try await remote.requireSession(id, core)
        }
        return session
    }
    public func transcriptScope(project: String?, context: NativeRPCContext) async throws -> NativeTranscriptScope {
        let graph = try sessions()
        let core: BackendDeckCoreSecurityCallContext?
        if context.caller == .nativeApp { try requireLocalUI(context); core = nil }
        else { core = try await resolve(ticket(context).native) }
        if let core, core.caller.kind == .remote {
            guard let remote else { throw unavailable("the remote caller's account-owned transcript grant") }
            return try await remote.transcripts(project, core)
        }
        let profiles = try await graph.profiles.list(provider: "claude")
        let configuration: String
        var additional: [String] = []
        if let core, core.caller.kind == .session {
            guard let id = core.caller.sessionID, let row = await graph.lifecycle.metadata().first(where: { $0.session.id == id }),
                  row.session.provider == "claude", let established = row.transcriptConfiguration else {
                throw unavailable("this session's established Claude transcript store")
            }
            configuration = established
        } else {
            configuration = self.configuration.systemDirectory("claude")
            additional = profiles.map(\.configDir).filter { NativeTranscriptPaths.canonical($0) != NativeTranscriptPaths.canonical(configuration) }
        }
        var scope = NativeTranscriptScope(configDirectory: configuration)
        // The same boot restriction used by the app's chat/conversation
        // reader, including cost, alerts and artifact scans using this scope.
        scope.homeScopes = [hootHomeScope]
        scope.additionalConfigDirectories = Array(Set(additional)).sorted()
        if let core {
            switch core.caller.kind {
            case .session: scope.projectFolders = try await allowedFolders(core)
            case .key: scope.projectFolders = core.caller.folders
            case .local, .remote: break
            }
        }
        if let project {
            if let core { _ = try await knownFolder(project, native: core.native) }
            else { guard state.listProjects().contains(where: { $0["path"].string == project }) else { throw NativeRPCError(code: "access-denied", message: "That folder is not an open project") } }
            scope.projectFolders = [project]
        }
        return scope
    }
    public func authorizeSessionRPC(_ context: NativeRPCContext, channel: String, arguments: [NativeRPCValue]) async throws {
        if context.caller == .nativeApp { try requireLocalUI(context); return }
        let native = try ticket(context).native
        if let id = arguments.first?.string, channel.hasPrefix("session:") { _ = try await requireSession(id, native: native) }
        else { _ = try await resolve(native) }
    }
    public func requireSessionRPC(_ id: String, context: NativeRPCContext) async throws {
        if context.caller == .nativeApp {
            try requireLocalUI(context)
            guard prepared.manager.list().contains(where: { $0.id == id }) else { throw BackendSessionFailure.missingSession }
        } else { _ = try await requireSession(id, native: ticket(context).native) }
    }
    public func createContext(_ input: BackendCreateSessionInput, context: NativeRPCContext) async throws -> BackendLaunchContext {
        if context.caller == .nativeApp { try requireLocalUI(context); return BackendLaunchContext(rememberTab: true) }
        let core = try await resolve(ticket(context).native)
        try authorizeMutation(context)
        if core.caller.kind == .remote {
            guard let remote else { throw unavailable("the requested remote launch boundary") }
            return try await remote.launch(input, core)
        }
        _ = try await knownFolder(input.cwd, native: core.native)
        return BackendLaunchContext(rememberTab: true)
    }
    public func note(_ event: BackendSessionLifecycleEvent) {
        let now = Date().timeIntervalSince1970 * 1000
        lock.withLock {
            switch event {
            case .status(let id, let status, _): if statusReceipts[id]?.status != status.rawValue { statusReceipts[id] = (status.rawValue, now) }
            case .process(.exit(let id, _)): statusReceipts[id] = ("exited", now)
            case .process(.removed(let id, _)): statusReceipts[id] = nil
            default: break
            }
        }
    }
    public func statusRecord(_ id: String) -> NativeRPCValue? {
        lock.withLock { statusReceipts[id].map { .object([.init("status", .string($0.status)), .init("at", .number($0.at))]) } }
    }
    public func sessionViews() -> [NativeRPCValue] {
        prepared.manager.list().map { meta in
            let value = BackendCompositionSuppliers.sessionWire(meta)
            guard let record = statusRecord(meta.id) else { return value }
            return value.setting("attention", record["status"]).setting("statusSince", record["at"])
        }
    }
    public func publish(ownerID: String, channel: String, value: NativeRPCValue, registry: NativeChannelRegistry) async {
        guard ownerID == BackendCompositionRoot.appOwnerID, lock.withLock({ open && uiAlive }) else { return }
        try? await registry.publish(channel, arguments: [value], ownerID: ownerID)
    }
    public static func within(_ path: String, _ root: String) -> Bool {
        BackendRemoteServeSessionPolicy.withinFolder(NativeTranscriptPaths.canonical(root), NativeTranscriptPaths.canonical(path))
    }
    private func unavailable(_ operation: String) -> NativeRPCError { .init(code: "unavailable", message: "Composition needs \(operation)") }
}
