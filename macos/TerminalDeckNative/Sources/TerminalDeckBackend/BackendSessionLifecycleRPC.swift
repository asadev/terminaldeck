import Foundation
import TerminalDeckNativeCore

#if TD_HOST_ACCOUNT_BRIDGE
public typealias BackendHOSTRPCSwitches = any BackendHOSTSessionSwitching
public typealias BackendHOSTRPCDeferred = any BackendHOSTSessionDeferring
#else
public typealias BackendHOSTRPCSwitches = BackendSessionSwitchCoordinator
public typealias BackendHOSTRPCDeferred = BackendSessionSwitchDeferred
#endif

/// High-level source channels. Native remote/PT Y dispatch supplies baseline
/// read/write/create operations through the same lifecycle instance.
public actor BackendSessionLifecycleRPC {
    public static let channels: Set<String> = ["session:switch-plan", "session:switch-account", "session:switch-later", "session:switch-cancel", "session:switch-armed",
        "sessions:held", "session:held-retry", "session:held-forget", "session:account"]
    private let lifecycle: BackendSessionLifecycleCoordinator
    private let switches: BackendHOSTRPCSwitches
    private let restore: BackendSessionRestoreCoordinator
    private let deferred: BackendHOSTRPCDeferred
    private let store: NativeStateStore
    private let authorize: @Sendable (NativeRPCContext) throws -> Void
    public init(lifecycle: BackendSessionLifecycleCoordinator, switches: BackendHOSTRPCSwitches,
                restore: BackendSessionRestoreCoordinator, deferred: BackendHOSTRPCDeferred, store: NativeStateStore,
                authorizeMutation: @escaping @Sendable (NativeRPCContext) throws -> Void) {
        self.lifecycle = lifecycle; self.switches = switches; self.restore = restore; self.deferred = deferred; self.store = store; authorize = authorizeMutation
    }
    public func invoke(_ channel: String, args: [NativeRPCValue], context: NativeRPCContext) async throws -> NativeRPCValue {
        guard Self.channels.contains(channel) else { throw BackendSessionFailure.unsupported("This native session orchestration channel is not registered.") }
        func value(_ index: Int) -> NativeRPCValue { args.indices.contains(index) ? args[index] : .missing }
        func id(_ index: Int) throws -> String { try value(index).requireString("session/account id", nonempty: true) }
        if ["session:switch-account", "session:switch-later", "session:switch-cancel", "session:held-retry", "session:held-forget"].contains(channel) { try authorize(context) }
        // 13 Oct (Asad's recording): the account a session is on now is the one an in-place switch handed it, from
        // the moment the switch is made, even before the agent's next request proves it; else its record's. Picking
        // that account again does nothing and says so; it never reaches the host, whose older refusal for it is
        // the same sentence as "cannot switch in place" and must not become the Switch offer.
        func already(_ sessionID: String, _ accountID: String) async -> BackendSessionSwitchPlan? {
            let meta = lifecycle.manager.list().first(where: { $0.id == sessionID && $0.exitCode == nil })
            return Self.already(meta: meta, pending: meta == nil ? nil : await switches.pendingAccount(sessionID: sessionID), accountID: accountID)
        }
        switch channel {
        case "session:switch-plan":
            // 12 Oct: the app's own window draws the dialog this plan opens; the offer for a session that cannot
            // switch in place (plain words, a Switch button) is kept for it there. Tools and devices ask with their own callers.
            let mine = context.caller == .nativeApp
            if mine { SwitchAccountRestartOffer.record(nil) }
            let sessionID = try id(0), accountID = try id(1)
            if let same = await already(sessionID, accountID) { return same.wireValue }
            let plan = try await switches.subject(sessionID: sessionID, accountID: accountID)
            if mine, plan.notice != nil, plan.refusal == nil, let to = plan.to {
                SwitchAccountRestartOffer.record(.init(sessionID: plan.sessionID, accountID: to.id, carriesOn: plan.carriesConversation))
            }
            return plan.wireValue
        case "session:switch-account":
            let sessionID = try id(0), accountID = try id(1)
            if await already(sessionID, accountID) != nil, let meta = lifecycle.manager.list().first(where: { $0.id == sessionID }) {
                return try NativeRPCValue.parseJSON(JSONEncoder().encode(meta)).setting("accountSwitchPhase", .string("already")).setting("requestedProfileId", .string(accountID))
            }
            let result = try await switches.perform(sessionID: sessionID, accountID: accountID)
            let session = try NativeRPCValue.parseJSON(JSONEncoder().encode(result.session))
            return session.setting("accountSwitchPhase", .string(result.phase.rawValue)).setting("requestedProfileId", .string(result.requestedAccount.id))
        case "session:switch-later":
            let sessionID = try id(0), accountID = try id(1)
            if let same = await already(sessionID, accountID) { return .object([.init("already", .bool(true)), .init("message", same.refusal.map(NativeRPCValue.string) ?? .null)]) }
            return try await deferred.arm(sessionID: sessionID, accountID: accountID)
        case "session:switch-cancel": try await deferred.cancel(sessionID: try id(0)); return .null
        case "session:switch-armed": return .array(try await deferred.list().map(\.wireValue))
        case "sessions:held": return .array(try await store.heldSessions().map(\.wireValue))
        case "session:held-retry": return .array(try await restore.retryHeld(id(0)).map(\.wireValue))
        case "session:held-forget": return .array(try await restore.forgetHeld(id(0)).map(\.wireValue))
        case "session:account":
            // An in-place switch shows the account it handed the session at once, marked pending until proven.
            let sessionID = try id(0), reading = await lifecycle.sessionAccount(sessionID: sessionID)
            let meta = lifecycle.manager.list().first(where: { $0.id == sessionID && $0.exitCode == nil })
            return Self.account(reading, meta: meta, pending: meta == nil ? nil : await switches.pendingAccount(sessionID: sessionID))
        default: throw BackendSessionFailure.unsupported("The native session operation is unsupported.")
        }
    }
}

extension BackendSessionLifecycleRPC {
    /// The account a running session is on now: the one an in-place switch handed it (until its record catches
    /// up), else its record's.
    static func current(meta: BackendSessionMeta?, pending: BackendAccountIdentity?) -> BackendAccountIdentity? {
        guard let meta, meta.exitCode == nil else { return nil }
        if let pending { return pending }
        return meta.profileId.map { BackendAccountIdentity(id: $0, name: meta.profileName ?? $0) }
    }
    /// Picking that account again: nothing to do, said plainly (never the host's refusal, never the offer).
    static func already(meta: BackendSessionMeta?, pending: BackendAccountIdentity?, accountID: String) -> BackendSessionSwitchPlan? {
        guard let meta, let now = current(meta: meta, pending: pending), now.id == accountID else { return nil }
        return .alreadyOn(sessionID: meta.id, account: now, provider: meta.provider)
    }
    /// What the chip shows: the switched-to account at once, marked pending until the agent's next request proves it.
    static func account(_ reading: BackendAccountSessionReading, meta: BackendSessionMeta?, pending: BackendAccountIdentity?) -> NativeRPCValue {
        guard let meta, let pending, reading.profileId != pending.id else { return reading.wireValue }
        return .object([.init("kind", .string("known")), .init("provider", .string(reading.provider ?? meta.provider)),
            .init("configDir", .string(reading.configDir ?? meta.cwd)), .init("profileId", .string(pending.id)),
            .init("profileName", .string(pending.name)), .init("source", .string("switch")), .init("email", .null), .init("pending", .bool(true))])
    }
}

public actor BackendSessionHookRPC {
    public static let channels: Set<String> = ["hooks:status", "hooks:sync", "hooks:offer", "hooks:offer-accept", "hooks:offer-decline", "hooks:install", "hooks:remove", "hooks:server"]
    private let installation: BackendSessionHookInstallation
    private let server: BackendSessionHookServer
    public init(installation: BackendSessionHookInstallation, server: BackendSessionHookServer) { self.installation = installation; self.server = server }
    public func invoke(_ channel: String, args: [NativeRPCValue], context: NativeRPCContext) async throws -> NativeRPCValue {
        switch channel {
        case "hooks:status": return .array(await installation.allStatus().map(\.wireValue))
        case "hooks:sync": return .array(try await installation.sync(context: context).map(\.wireValue))
        case "hooks:offer": return await installation.offer()
        case "hooks:offer-accept": return try await installation.answerOffer(accept: true, context: context)
        case "hooks:offer-decline": return try await installation.answerOffer(accept: false, context: context)
        case "hooks:server": return server.status()
        case "hooks:install", "hooks:remove":
            let provider = try (args.first ?? .missing).requireString("hook provider", nonempty: true)
            let row = channel == "hooks:install" ? try await installation.install(provider, context: context) : try await installation.remove(provider, context: context)
            return .object([.init("ok", .bool(row.state != "error")), .init("message", .string(row.message)), .init("status", row.wireValue)])
        default: throw BackendSessionFailure.unsupported("The native hook operation is unsupported.")
        }
    }
}
