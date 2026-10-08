import Foundation
import TerminalDeckNativeCore

/// Integration-owned values, never request payload fields. A captured kernel
/// scope must match every value, including the private Caddy persistence path.
public struct BackendAppsMCPRecoveryNamespace: Sendable, Equatable {
    public let stateRoot: String
    public let resourcePrefix: String
    public let privateNetwork: String
    public let caddyServerKey: String?
    public let caddyAutosavePath: String?

    public init(stateRoot: String, resourcePrefix: String, privateNetwork: String,
                caddyServerKey: String? = nil, caddyAutosavePath: String? = nil) throws {
        guard Self.slug(resourcePrefix), Self.identifier(privateNetwork),
              stateRoot == (resourcePrefix == "terminaldeck" ? "/var/lib/terminaldeck/apps" : "/var/lib/" + resourcePrefix + "-apps"),
              caddyServerKey.map(Self.identifier) ?? true,
              caddyAutosavePath.map(Self.absoluteFile) ?? true else {
            throw NativeRPCError.invalidArguments("The trusted app recovery namespace is invalid.")
        }
        self.stateRoot = stateRoot; self.resourcePrefix = resourcePrefix; self.privateNetwork = privateNetwork
        self.caddyServerKey = caddyServerKey; self.caddyAutosavePath = caddyAutosavePath
    }

    fileprivate func matches(_ scope: BackendAppsRecoveryScope) -> Bool {
        stateRoot == scope.stateRoot && resourcePrefix == scope.resourcePrefix && privateNetwork == scope.privateNetwork
            && caddyServerKey == scope.caddyServerKey && caddyAutosavePath == scope.caddyAutosavePath
    }
    fileprivate static func slug(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (1...48).contains(bytes.count) && bytes.first.map { (97...122).contains($0) } == true
            && bytes.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }
    private static func identifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        func alphanumeric(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) }
        return (1...96).contains(bytes.count) && bytes.first.map(alphanumeric) == true
            && bytes.allSatisfy { alphanumeric($0) || $0 == 45 || $0 == 46 || $0 == 95 }
    }
    private static func absoluteFile(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.hasSuffix("/") && !value.contains("..") && value.utf8.count <= 4096
            && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 47, 95].contains($0) }
    }
}

/// Records the SAME real approval used by Apps dispatch. This map is only the
/// issuer's original-action binding; it never substitutes for live authority
/// or gives ordinary transport a way around cancellation.
public actor BackendAppsMCPRecoveryAuthority {
    public typealias RegistrationAuthorize = @Sendable (NativeRPCContext?) async throws -> Void
    public typealias Factory = @Sendable (BackendAppsRecoveryScope, NativeRPCContext, @escaping RegistrationAuthorize) async throws -> BackendAppsRecoveryTransport
    /// Root resolves the original accepted core invocation through its actual
    /// bindings. A missing resolver denies core issuance; native clicks still
    /// ask the person about their exact received action.
    public typealias OriginalAction = @Sendable (NativeRPCContext) async throws -> (String, NativeRPCValue)
    private struct Key: Hashable, Sendable { let requestID: UUID; let ownerID: String }
    private struct Approval: Sendable {
        let nonce: UUID
        let context: NativeRPCContext
        let channel: String
        let serverID: String
        let primaryAppID: String
        let bindTargetAppID: String?
        let confirmation: String?
        let bindKey: String?
        let appIDs: Set<String>
        let issuedAt: Double
        let deadline: Double
    }
    private let authority: BackendCompositionAuthority
    private let approval: BackendDockerMCPServerApproval
    private let namespace: BackendAppsMCPRecoveryNamespace
    private let factory: Factory
    private let originalAction: OriginalAction?
    private let audit: BackendAppsRecovery.Audit
    private let monotonic: @Sendable () -> Double
    private var approvals: [Key: Approval] = [:]
    private var recovery: BackendAppsRecovery?
    private var closed = false
    private var shutdownTask: Task<Void, Never>?

    public init(authority: BackendCompositionAuthority, approval: BackendDockerMCPServerApproval,
                namespace: BackendAppsMCPRecoveryNamespace, factory: @escaping Factory,
                audit: @escaping BackendAppsRecovery.Audit,
                originalAction: OriginalAction? = nil,
                monotonic: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.authority = authority; self.approval = approval; self.namespace = namespace
        self.factory = factory; self.audit = audit; self.monotonic = monotonic
        self.originalAction = originalAction
    }

    /// Use as the engine's injected authorizer, replacing no existing approval.
    /// Read calls and server-only writes can run but mint no app recovery scope.
    public func authorizeAndRecord(action: BackendAppsAction, context: NativeRPCContext) async throws {
        try requireOpen()
        try Task.checkCancellation()
        let writes = BackendAppsChannels.writeChannels.union(BackendAppsDataChannels.writeChannels)
        let reads = BackendAppsChannels.readChannels.union(BackendAppsDataChannels.readChannels)
        guard writes.contains(action.channel) || reads.contains(action.channel), action.serverID != "local" else {
            throw denial("This app action has no recovery approval path.")
        }
        let changing = writes.contains(action.channel)
        let permittedApps = try apps(for: action)
        let expectedDestructive = ["apps:remove", "apps:backups:restore"].contains(action.channel)
        guard action.destructive == expectedDestructive else { throw denial("The app action does not match its destructive confirmation policy.") }
        let key = Key(requestID: context.requestID, ownerID: context.ownerID)
        if let old = approvals[key] {
            guard Self.sameContext(old.context, context) else { throw denial("Another caller cannot replace this app approval.") }
            approvals[key] = nil
        }
        if changing {
            try await checkOriginal(context, channel: action.channel, server: action.serverID, app: action.appID,
                                    target: action.channel == "apps:databases:bind" ? action.preview["targetAppId"].string : nil,
                                    confirmation: action.confirmation, bindKey: action.preview["key"].string)
            try requireOpen()
        }
        let sentence = summary(action)
        try await approval.authorize(context: context, channel: action.channel,
            target: action.serverID.isEmpty ? nil : action.serverID, changing: changing,
            summary: sentence, arguments: action.preview)
        try requireOpen()
        try Task.checkCancellation()
        guard changing, !permittedApps.isEmpty else { return }
        guard !action.serverID.isEmpty else { throw denial("App recovery requires a saved server.") }
        // Check the original receipt and caller again after pending consent.
        try authority.authorizeMutation(context)
        try await approval.authorize(context: context, channel: action.channel, target: action.serverID,
                                     changing: false, summary: sentence, arguments: action.preview)
        try requireOpen()
        try await checkOriginal(context, channel: action.channel, server: action.serverID, app: action.appID,
                                target: action.channel == "apps:databases:bind" ? action.preview["targetAppId"].string : nil,
                                confirmation: action.confirmation, bindKey: action.preview["key"].string)
        try requireOpen()
        try Task.checkCancellation()
        let now = try clock()
        prune(now)
        guard approvals[key] != nil || approvals.count < 128 else { throw denial("Too many app recovery approvals are active.") }
        approvals[key] = Approval(nonce: UUID(), context: context, channel: action.channel,
                                  serverID: action.serverID, primaryAppID: action.appID!,
                                  bindTargetAppID: action.channel == "apps:databases:bind" ? action.preview["targetAppId"].string : nil,
                                  confirmation: action.confirmation, bindKey: action.preview["key"].string,
                                  appIDs: permittedApps, issuedAt: now, deadline: now + 3900)
    }

    /// Kernel capture is called while the original mutation ticket is alive.
    /// The returned transport exposes no public arbitrary I/O; only sealed
    /// kernel operations may use it after the ordinary caller is cancelled.
    public func capture(scope: BackendAppsRecoveryScope, context: NativeRPCContext?) async throws -> BackendAppsRecoveryTransport {
        try requireOpen()
        guard let context else { throw denial("App recovery requires the original authenticated caller.") }
        let approved = try matching(scope, context)
        try await recheck(scope, context: context, nonce: approved.nonce)
        let register: RegistrationAuthorize = { [weak self] supplied in
            guard let self, let supplied, Self.sameContext(supplied, context) else {
                throw NativeRPCError(code: "access-denied", message: "Only the original live caller can seal recovery steps.")
            }
            try await self.recheck(scope, context: supplied, nonce: approved.nonce)
        }
        let transport = try await factory(scope, context, register)
        do {
            try await recheck(scope, context: context, nonce: approved.nonce)
            return transport
        } catch {
            await transport.closePinned()
            throw error
        }
    }

    public func kernel() -> BackendAppsRecovery {
        if let recovery { return recovery }
        let result = BackendAppsRecovery(capture: { [weak self] scope, context in
            guard let self else { throw NativeRPCError(code: "unavailable", message: "The app recovery issuer was released.") }
            return try await self.capture(scope: scope, context: context)
        }, audit: audit, monotonic: monotonic)
        recovery = result
        return result
    }
    /// Root calls this at ordinary-call teardown. Existing sealed handles keep
    /// their kernel-owned lease; no further capture/registration can be minted.
    public func finish(requestID: UUID, ownerID: String) { approvals[Key(requestID: requestID, ownerID: ownerID)] = nil }
    /// First shutdown phase: refuse pending/new approvals and captures while
    /// already sealed recovery remains available to cancelled in-flight work.
    /// Root must drain those owners before calling full shutdown().
    public func stopAccepting() {
        closed = true
        approvals.removeAll()
    }
    public func shutdown() async {
        // Close admissions before the first await. Pending consent/factory
        // work must never recreate a receipt after owner teardown starts.
        stopAccepting()
        if let shutdownTask { await shutdownTask.value; return }
        let kernel = recovery
        let task = Task { if let kernel { await kernel.shutdown() } }
        shutdownTask = task
        await task.value
    }

    private func recheck(_ scope: BackendAppsRecoveryScope, context: NativeRPCContext, nonce: UUID) async throws {
        try requireOpen()
        try Task.checkCancellation()
        let accepted = try matching(scope, context)
        guard accepted.nonce == nonce else { throw denial("The original app approval was replaced or released.") }
        try await checkOriginal(context, channel: accepted.channel, server: accepted.serverID, app: accepted.primaryAppID,
                                target: accepted.bindTargetAppID, confirmation: accepted.confirmation, bindKey: accepted.bindKey)
        try requireOpen()
        try await approval.authorize(context: context, channel: accepted.channel, target: accepted.serverID,
                                     changing: false, summary: "Register approved app recovery", arguments: .object([]))
        try requireOpen()
        try authority.authorizeMutation(context)
        try Task.checkCancellation()
        guard try matching(scope, context).nonce == nonce else { throw denial("The original app approval was replaced or released.") }
    }
    private func matching(_ scope: BackendAppsRecoveryScope, _ context: NativeRPCContext) throws -> Approval {
        try requireOpen()
        let now = try clock()
        prune(now)
        guard namespace.matches(scope), scope.requestID == context.requestID, scope.ownerID == context.ownerID,
              scope.lifetimeSeconds.isFinite, (1...3900).contains(scope.lifetimeSeconds),
              let accepted = approvals[Key(requestID: context.requestID, ownerID: context.ownerID)],
              Self.sameContext(accepted.context, context), accepted.serverID == scope.serverID,
              accepted.appIDs.contains(scope.appID), now >= accepted.issuedAt, now < accepted.deadline else {
            throw denial("The recovery scope does not match a current approved app action.")
        }
        return accepted
    }
    private func apps(for action: BackendAppsAction) throws -> Set<String> {
        guard let app = action.appID else { return [] }
        guard BackendAppsMCPRecoveryNamespace.slug(app) else { throw denial("The approved app ID is invalid.") }
        for (key, expected) in [("channel", action.channel), ("serverId", action.serverID), ("appId", app)] {
            if action.preview.has(key), action.preview[key].string != expected { throw denial("The app approval preview does not match its action.") }
        }
        var apps: Set<String> = [app]
        if action.channel == "apps:databases:bind" {
            guard let target = action.preview["targetAppId"].string, BackendAppsMCPRecoveryNamespace.slug(target), target != app else {
                throw denial("The database binding approval must name its exact target app.")
            }
            apps.insert(target)
        }
        return apps
    }
    private func checkOriginal(_ context: NativeRPCContext, channel: String, server: String, app: String?,
                               target: String?, confirmation: String?, bindKey: String?) async throws {
        if context.caller == .nativeApp { try authority.requireLocalUI(context); return }
        guard context.caller == .page, let originalAction else {
            throw NativeRPCError(code: "unavailable", message: "App recovery needs the original accepted core action.")
        }
        let (tool, arguments) = try await originalAction(context)
        guard tool == channel.replacingOccurrences(of: ":", with: "."), arguments["serverId"].string == server,
              arguments["appId"].string == app else { throw denial("This app action does not match the original approved request.") }
        if channel == "apps:databases:bind" {
            guard target != nil, arguments["targetAppId"].string == target,
                  !arguments.has("key") || arguments["key"].string == bindKey else {
                throw denial("This database binding does not match the original approved target and setting.")
            }
        }
        if ["apps:remove", "apps:backups:restore"].contains(channel) {
            guard confirmation != nil, arguments["confirmation"].string == confirmation else {
                throw denial("The recovery approval does not match the original destructive confirmation.")
            }
        }
    }
    private func summary(_ action: BackendAppsAction) -> String {
        let app = action.confirmation ?? action.appID ?? "server"
        var sentence = action.channel.replacingOccurrences(of: ":", with: " ") + " \"" + app + "\" on server \"" + action.serverID + "\"."
        if action.channel == "apps:databases:bind", let target = action.preview["targetAppId"].string {
            sentence = "Connect database \"\(app)\" to app \"\(target)\" on server \"\(action.serverID)\". Replace its selected saved setting; deploy the target app to apply it."
        }
        return BackendDockerMCPMasker.text(sentence)
    }
    private func clock() throws -> Double {
        let now = monotonic()
        guard now.isFinite else { throw denial("The app recovery approval clock is unavailable.") }
        return now
    }
    private func prune(_ now: Double) { approvals = approvals.filter { now >= $0.value.issuedAt && now < $0.value.deadline } }
    private nonisolated static func sameContext(_ lhs: NativeRPCContext, _ rhs: NativeRPCContext) -> Bool {
        lhs.caller == rhs.caller && lhs.ownerID == rhs.ownerID && lhs.requestID == rhs.requestID
            && lhs.origin == rhs.origin && lhs.capabilities == rhs.capabilities
    }
    private func denial(_ message: String) -> NativeRPCError { .init(code: "access-denied", message: message) }
    private func requireOpen() throws {
        guard !closed else { throw NativeRPCError(code: "unavailable", message: "The app recovery issuer has stopped.") }
    }
}
