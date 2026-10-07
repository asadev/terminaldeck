import Foundation
import TerminalDeckNativeCore

public typealias BackendDeckToolsSessionsRPCContext = @Sendable (BackendMCPCallContext) async throws -> NativeRPCContext

/// Operations not exposed by the current account facade. The lifecycle/account
/// lane supplies its existing sign-in and shared-history services here.
public protocol BackendDeckToolsSessionsAccountExtras: Sendable {
    func signInStatus(accountID: String, refresh: Bool, context: NativeRPCContext) async throws -> NativeRPCValue
    func history(accountID: String, context: NativeRPCContext) async throws -> NativeRPCValue
    func signOut(accountID: String, context: NativeRPCContext) async throws -> NativeRPCValue
    func shareHistory(accountID: String, share: Bool, context: NativeRPCContext) async throws -> NativeRPCValue
}

/// agents-area-live: every supported operation goes to the same account facade
/// as the native app. Context comes from the authenticated caller, never a fixed
/// .nativeApp context or a tool argument.
public struct BackendDeckToolsSessionsNativeAccounts: BackendDeckToolsSessionsAccounts {
    private let rpc: BackendAccountRPC
    private let profiles: BackendAccountProfileStore
    private let context: BackendDeckToolsSessionsRPCContext
    private let extras: (any BackendDeckToolsSessionsAccountExtras)?
    public init(rpc: BackendAccountRPC, profiles: BackendAccountProfileStore, context: @escaping BackendDeckToolsSessionsRPCContext,
                extras: (any BackendDeckToolsSessionsAccountExtras)? = nil) { self.rpc = rpc; self.profiles = profiles; self.context = context; self.extras = extras }
    private func invoke(_ channel: String, _ arguments: [NativeRPCValue], _ caller: BackendMCPCallContext) async throws -> NativeRPCValue {
        try await rpc.invoke(channel, args: arguments, context: context(caller))
    }
    public func list(agent: String?, context: BackendMCPCallContext) async throws -> NativeRPCValue { try await invoke("profiles:list", [agent.map(NativeRPCValue.string) ?? .null], context) }
    public func agents(context: BackendMCPCallContext) async throws -> NativeRPCValue { try await invoke("profiles:account-providers", [], context) }
    public func resolve(projectPath: String?, provider: String?, context: BackendMCPCallContext) async throws -> NativeRPCValue {
        try await invoke("profiles:resolve", [BackendDeckToolsSupport.object([("projectPath", projectPath.map(NativeRPCValue.string) ?? .null), ("provider", provider.map(NativeRPCValue.string) ?? .null)])], context)
    }
    public func find(accountID: String, context: BackendMCPCallContext) async throws -> NativeRPCValue? {
        guard let account = try await profiles.find(accountID) else { return nil }
        return BackendDeckToolsSupport.object([("id", .string(account.id)), ("name", .string(account.name)), ("provider", .string(account.provider))])
    }
    public func status(accountID: String, context: BackendMCPCallContext) async throws -> NativeRPCValue { try await invoke("profiles:status", [.string(accountID)], context) }
    public func signInStatus(accountID: String, refresh: Bool, context caller: BackendMCPCallContext) async throws -> NativeRPCValue {
        guard let extras else { throw BackendDeckToolsSupport.unavailable("profiles:signin") }
        return try await extras.signInStatus(accountID: accountID, refresh: refresh, context: context(caller))
    }
    public func history(accountID: String, context caller: BackendMCPCallContext) async throws -> NativeRPCValue {
        guard let extras else { throw BackendDeckToolsSupport.unavailable("accounts:history-state") }
        return try await extras.history(accountID: accountID, context: context(caller))
    }
    public func create(name: String, provider: String?, context: BackendMCPCallContext) async throws -> NativeRPCValue {
        try await invoke("profiles:create", [.string(name), provider.map { .object([.init("provider", .string($0))]) } ?? .object([])], context)
    }
    public func rename(accountID: String, name: String, context: BackendMCPCallContext) async throws -> NativeRPCValue { try await invoke("profiles:rename", [.string(accountID), .string(name)], context) }
    public func delete(accountID: String, deleteFiles: Bool, context: BackendMCPCallContext) async throws -> NativeRPCValue {
        try await invoke("profiles:delete", [.string(accountID), .object([.init("deleteFiles", .bool(deleteFiles))])], context)
    }
    public func setDefault(accountID: String?, projectPath: String?, context: BackendMCPCallContext) async throws -> NativeRPCValue {
        let id = accountID.map(NativeRPCValue.string) ?? .null
        return try await invoke(projectPath == nil ? "profiles:set-default" : "profiles:set-project-default", projectPath.map { [.string($0), id] } ?? [id], context)
    }
    public func signOut(accountID: String, context caller: BackendMCPCallContext) async throws -> NativeRPCValue {
        guard let extras else { throw BackendDeckToolsSupport.unavailable("profiles:signout") }
        return try await extras.signOut(accountID: accountID, context: context(caller))
    }
    public func shareHistory(accountID: String, share: Bool, context caller: BackendMCPCallContext) async throws -> NativeRPCValue {
        guard let extras else { throw BackendDeckToolsSupport.unavailable(share ? "accounts:history-share" : "accounts:history-unshare") }
        return try await extras.shareHistory(accountID: accountID, share: share, context: context(caller))
    }
}

/// Sessions-lane bindings reuse the real lifecycle, ledger facade, account
/// store, conversation reader, search and inspector. Signal timestamps, title
/// broadcasts, plan-limit snapshots and authenticated launch contexts belong to
/// app assembly and are explicit closures rather than guessed values.
public struct BackendDeckToolsSessionsNativeSurface: BackendDeckToolsSessionsSurface {
    private let lifecycle: BackendSessionLifecycleCoordinator
    private let rpc: BackendSessionLifecycleRPC
    private let profiles: BackendAccountProfileStore
    private let cost: BackendCostService
    private let searchService: BackendSessionSearchService
    private let insightsService: BackendInsightsService
    private let context: BackendDeckToolsSessionsRPCContext
    private let signal: @Sendable (String, BackendMCPCallContext) async throws -> NativeRPCValue?
    private let planLimits: @Sendable (String, BackendMCPCallContext) async throws -> NativeRPCValue
    private let renamed: @Sendable (String, String) async throws -> Void
    private let switched: @Sendable (String, NativeRPCValue, String) async throws -> Void
    private let view: @Sendable (String, BackendMCPCallContext) async throws -> NativeRPCValue
    private let cancelArmed: @Sendable (String, BackendMCPCallContext) async throws -> Bool
    private let launchContext: @Sendable (String?, String, BackendMCPCallContext) async throws -> BackendLaunchContext
    public init(lifecycle: BackendSessionLifecycleCoordinator, rpc: BackendSessionLifecycleRPC, profiles: BackendAccountProfileStore,
                cost: BackendCostService, search: BackendSessionSearchService, insights: BackendInsightsService,
                context: @escaping BackendDeckToolsSessionsRPCContext,
                statusRecord: @escaping @Sendable (String, BackendMCPCallContext) async throws -> NativeRPCValue?,
                planLimits: @escaping @Sendable (String, BackendMCPCallContext) async throws -> NativeRPCValue,
                announceRenamed: @escaping @Sendable (String, String) async throws -> Void,
                tellSwitched: @escaping @Sendable (String, NativeRPCValue, String) async throws -> Void,
                sessionView: @escaping @Sendable (String, BackendMCPCallContext) async throws -> NativeRPCValue,
                cancelArmed: @escaping @Sendable (String, BackendMCPCallContext) async throws -> Bool,
                launchContext: @escaping @Sendable (String?, String, BackendMCPCallContext) async throws -> BackendLaunchContext) {
        self.lifecycle = lifecycle; self.rpc = rpc; self.profiles = profiles; self.cost = cost; searchService = search; insightsService = insights
        self.context = context; signal = statusRecord; self.planLimits = planLimits; renamed = announceRenamed; switched = tellSwitched
        view = sessionView; self.cancelArmed = cancelArmed; self.launchContext = launchContext
    }
    private func invoke(_ channel: String, _ arguments: [NativeRPCValue], _ caller: BackendMCPCallContext) async throws -> NativeRPCValue {
        try await rpc.invoke(channel, args: arguments, context: context(caller))
    }
    public func status(sessionID: String, context: BackendMCPCallContext) async throws -> NativeRPCValue? { try await signal(sessionID, context) }
    public func screen(sessionID: String, context: BackendMCPCallContext) async throws -> String? { lifecycle.manager.screen(sessionID) }
    public func write(sessionID: String, data: String, context: BackendMCPCallContext) async throws { try await lifecycle.write(sessionID: sessionID, data: data) }
    public func rename(sessionID: String, title: String, context: BackendMCPCallContext) async throws -> String? {
        guard try await lifecycle.rename(sessionID: sessionID, title: title) else { return nil }
        let resolved = lifecycle.manager.list().first { $0.id == sessionID }?.title ?? title
        try await renamed(sessionID, resolved); return resolved
    }
    private func heldView(_ rows: NativeRPCValue) -> [NativeRPCValue] {
        (rows.elements ?? []).map { row in BackendDeckToolsSupport.object(["key", "cwd", "provider", "profileId", "reason", "at", "lastSeenAt"].map { ($0, row[$0]) }) }
    }
    public func held(context: BackendMCPCallContext) async throws -> [NativeRPCValue] { heldView(try await invoke("sessions:held", [], context)) }
    public func retryHeld(key: String, context: BackendMCPCallContext) async throws -> [NativeRPCValue] { heldView(try await invoke("session:held-retry", [.string(key)], context)) }
    public func forgetHeld(key: String, context: BackendMCPCallContext) async throws -> [NativeRPCValue] { heldView(try await invoke("session:held-forget", [.string(key)], context)) }
    public func account(sessionID: String, context: BackendMCPCallContext) async throws -> NativeRPCValue { try await invoke("session:account", [.string(sessionID)], context) }
    public func limits(sessionID: String, context: BackendMCPCallContext) async throws -> NativeRPCValue { try await planLimits(sessionID, context) }
    public func accountPlan(sessionID: String, profileID: String, context: BackendMCPCallContext) async throws -> NativeRPCValue { try await invoke("session:switch-plan", [.string(sessionID), .string(profileID)], context) }
    public func switchAccount(sessionID: String, profileID: String, context: BackendMCPCallContext) async throws -> NativeRPCValue {
        let meta = try await invoke("session:switch-account", [.string(sessionID), .string(profileID)], context)
        let profile = try await profiles.find(profileID)
        try await switched(sessionID, meta, profile?.name ?? profileID)
        return try await view(meta["id"].string ?? "", context)
    }
    public func switchLater(sessionID: String, profileID: String, context: BackendMCPCallContext) async throws -> NativeRPCValue { try await invoke("session:switch-later", [.string(sessionID), .string(profileID)], context) }
    public func cancelSwitch(sessionID: String, context: BackendMCPCallContext) async throws -> Bool { try await cancelArmed(sessionID, context) }
    public func armedSwitches(context: BackendMCPCallContext) async throws -> [NativeRPCValue] { try await invoke("session:switch-armed", [], context).elements ?? [] }
    public func accounts(context: BackendMCPCallContext) async throws -> [NativeRPCValue] {
        try await profiles.list().map { BackendDeckToolsSupport.object([("id", .string($0.id)), ("name", .string($0.name)), ("provider", .string($0.provider))]) }
    }
    public func search(request: NativeRPCValue, context caller: BackendMCPCallContext) async throws -> NativeRPCValue {
        var parsed = try BackendSessionSearchRequest.parse(request)
        // session-more-tools only overrides roles if it received a nonempty list.
        parsed.maxHits = try BackendDeckToolsArgs.optInt(request, "maxHits", 20, 1, 100)
        return try await searchService.search(parsed, context: context(caller), cancellation: caller.cancellation, restrictedToProject: caller.projectRoot)
    }
    public func insights(transcriptPath: String, context caller: BackendMCPCallContext) async throws -> NativeRPCValue { try await insightsService.session(path: transcriptPath, context: context(caller), cancellation: caller.cancellation) }
    public func transcripts(cwd: String, context caller: BackendMCPCallContext) async throws -> [NativeRPCValue] {
        try await cost.files(project: cwd, context: context(caller)).map { file in BackendDeckToolsSupport.object([("path", .string(file.path)), ("sessionId", .string(file.sessionID)), ("createdAt", .number(file.createdAt)), ("modifiedAt", .number(file.modifiedAt)), ("bytes", .number(Double(file.bytes)))]) }
    }
    public func transcriptBytes(path: String, context caller: BackendMCPCallContext) async throws -> Int {
        let scope = try await cost.scope(project: nil, context: context(caller))
        _ = try NativeTranscriptPaths.assertTranscript(path, scope: scope)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let size = attributes[.size] as? NSNumber else { throw BackendDeckToolsSupport.unavailable("The transcript byte count") }
        return size.intValue
    }
    public func transcriptMessages(path: String, fromByte: Int, context caller: BackendMCPCallContext) async throws -> [NativeRPCValue] {
        let scope = try await cost.scope(project: nil, context: context(caller))
        _ = try NativeTranscriptPaths.assertTranscript(path, scope: scope)
        let reader = NativeChatTranscriptReader(path: path, startAt: Int64(max(0, fromByte)), allowedRoots: try NativeTranscriptPaths.approvedRoots(scope))
        let result = try await reader.readAll(wholeConversation: true)
        return result.messages.map { BackendDeckToolsSupport.object([("id", .string($0.id)), ("role", .string($0.role.rawValue)), ("at", .number($0.at)), ("text", .string($0.text)), ("truncated", .bool(false))]) }
    }
    public func start(input: BackendCreateSessionInput, deviceID: String?, context caller: BackendMCPCallContext) async throws -> NativeRPCValue {
        let launch = try await launchContext(deviceID, input.cwd, caller)
        let meta = try await lifecycle.create(input, context: launch)
        return try NativeRPCValue.parseJSON(JSONEncoder().encode(meta))
    }
}

/// Source assembly order. Other tool lanes supply definitions from their own
/// files; this area creates no duplicate MCP server, ledger, provider or inbox.
public enum BackendDeckToolsSessionsAssembly {
    public static func agents(agents: [BackendDeckToolsDefinition], accounts: [BackendDeckToolsDefinition], mcp: [BackendDeckToolsDefinition],
                              hooks: [BackendDeckToolsDefinition], routines: [BackendDeckToolsDefinition], app: [BackendDeckToolsDefinition],
                              setup: [BackendDeckToolsDefinition], usage: [BackendDeckToolsDefinition], voice: [BackendDeckToolsDefinition]) throws -> BackendDeckCoreToolArea {
        try BackendDeckToolsSupport.area(id: "agents", definitions: agents + accounts + mcp + hooks + routines + app + setup + usage + voice)
    }
    public static func sessions(more: [BackendDeckToolsDefinition], projects: [BackendDeckToolsDefinition], files: [BackendDeckToolsDefinition],
                                copilotAdmin: [BackendDeckToolsDefinition], ui: [BackendDeckToolsDefinition], coverage: [BackendDeckToolsDefinition]) throws -> BackendDeckCoreToolArea {
        try BackendDeckToolsSupport.area(id: "sessions", definitions: more + projects + files + copilotAdmin + ui + coverage)
    }
}
