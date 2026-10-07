import Foundation
import TerminalDeckNativeCore

/// High-level source channels. Native remote/PT Y dispatch supplies baseline
/// read/write/create operations through the same lifecycle instance.
public actor BackendSessionLifecycleRPC {
    public static let channels: Set<String> = ["session:switch-plan", "session:switch-account", "session:switch-later", "session:switch-cancel", "session:switch-armed",
        "sessions:held", "session:held-retry", "session:held-forget", "session:account"]
    private let lifecycle: BackendSessionLifecycleCoordinator
    private let switches: BackendSessionSwitchCoordinator
    private let restore: BackendSessionRestoreCoordinator
    private let deferred: BackendSessionSwitchDeferred
    private let store: NativeStateStore
    private let authorize: @Sendable (NativeRPCContext) throws -> Void
    public init(lifecycle: BackendSessionLifecycleCoordinator, switches: BackendSessionSwitchCoordinator,
                restore: BackendSessionRestoreCoordinator, deferred: BackendSessionSwitchDeferred, store: NativeStateStore,
                authorizeMutation: @escaping @Sendable (NativeRPCContext) throws -> Void) {
        self.lifecycle = lifecycle; self.switches = switches; self.restore = restore; self.deferred = deferred; self.store = store; authorize = authorizeMutation
    }
    public func invoke(_ channel: String, args: [NativeRPCValue], context: NativeRPCContext) async throws -> NativeRPCValue {
        guard Self.channels.contains(channel) else { throw BackendSessionFailure.unsupported("This native session orchestration channel is not registered.") }
        func value(_ index: Int) -> NativeRPCValue { args.indices.contains(index) ? args[index] : .missing }
        func id(_ index: Int) throws -> String { try value(index).requireString("session/account id", nonempty: true) }
        if ["session:switch-account", "session:switch-later", "session:switch-cancel", "session:held-retry", "session:held-forget"].contains(channel) { try authorize(context) }
        switch channel {
        case "session:switch-plan": return try await switches.subject(sessionID: id(0), accountID: id(1)).wireValue
        case "session:switch-account":
            let result = try await switches.perform(sessionID: id(0), accountID: id(1))
            let session = try NativeRPCValue.parseJSON(JSONEncoder().encode(result.session))
            return session.setting("accountSwitchPhase", .string(result.phase.rawValue)).setting("requestedProfileId", .string(result.requestedAccount.id))
        case "session:switch-later": return try await deferred.arm(sessionID: id(0), accountID: id(1))
        case "session:switch-cancel": await deferred.cancel(sessionID: try id(0)); return .null
        case "session:switch-armed": return .array(await deferred.list().map(\.wireValue))
        case "sessions:held": return .array(try await store.heldSessions().map(\.wireValue))
        case "session:held-retry": return .array(try await restore.retryHeld(id(0)).map(\.wireValue))
        case "session:held-forget": return .array(try await restore.forgetHeld(id(0)).map(\.wireValue))
        case "session:account": return await lifecycle.sessionAccount(sessionID: try id(0)).wireValue
        default: throw BackendSessionFailure.unsupported("The native session operation is unsupported.")
        }
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
