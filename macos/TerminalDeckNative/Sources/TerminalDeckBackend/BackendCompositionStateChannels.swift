import Foundation
import TerminalDeckNativeCore

/// Who may use a channel (Round 3, D14). `window`: only the current app window
/// (`requireLocalUI`). `read` / `change`: the app window, or a credential-resolved
/// core call's page ticket — any ticket for a read, an accepted act/alter
/// receipt for a change — because the TS lets an agent tool reach it
/// (src/main/deck-control/actions/*.ts). A paired device passes neither.
enum BackendCompositionChannelAccess: Sendable {
    case window, read, change
    func policy(_ authority: BackendCompositionAuthority) -> NativeChannelRegistry.Policy {
        switch self {
        case .window: return { try authority.requireLocalUI($0) }
        case .read: return { try authority.authorizeMetadata($0) }
        case .change: return { try authority.authorizeMutation($0) }
        }
    }
}

/// One area's invokes and sends, installed all or nothing on the one registry.
struct BackendCompositionChannelTable {
    var invokes: [(name: String, access: BackendCompositionChannelAccess, handler: NativeChannelRegistry.Handler)] = []
    var sends: [(name: String, access: BackendCompositionChannelAccess, handler: NativeChannelRegistry.SendHandler)] = []
    mutating func invoke(_ name: String, _ access: BackendCompositionChannelAccess, _ handler: @escaping NativeChannelRegistry.Handler) {
        invokes.append((name, access, handler))
    }
    mutating func send(_ name: String, _ access: BackendCompositionChannelAccess, _ handler: @escaping NativeChannelRegistry.SendHandler) {
        sends.append((name, access, handler))
    }
    func install(registry: NativeChannelRegistry, ownerID: String, authority: BackendCompositionAuthority,
                 events: [String]) async throws -> (invokes: [String], sends: [String], events: [String]) {
        for entry in invokes {
            if await registry.has(entry.name) { throw NativeRPCError(code: "duplicate-handler", message: "Channel is already registered: " + entry.name) }
        }
        for entry in sends {
            if await registry.hasSend(entry.name) { throw NativeRPCError(code: "duplicate-handler", message: "Send channel is already registered: " + entry.name) }
        }
        var registered: [String] = [], listening: [NativeRPCSubscription] = []
        do {
            for entry in invokes {
                try await registry.register(entry.name, ownerID: ownerID, policy: entry.access.policy(authority), handler: entry.handler)
                registered.append(entry.name)
            }
            for entry in sends {
                listening.append(try await registry.onSend(entry.name, ownerID: ownerID, policy: entry.access.policy(authority), handler: entry.handler))
            }
        } catch {
            for name in registered { await registry.removeHandler(name, ownerID: ownerID) }
            for subscription in listening { await subscription.cancelAndWait() }
            throw error
        }
        // A send listener lives as long as its subscription; keep them for the area's lifetime.
        await BackendCompositionSendLeases.shared.keep(ownerID, listening)
        return (registered, sends.map { $0.name }, events)
    }
}

/// Send-listener leases by owner: released when the area stops (`drop`), never by scope exit.
public actor BackendCompositionSendLeases {
    public static let shared = BackendCompositionSendLeases()
    private var leases: [String: [NativeRPCSubscription]] = [:]
    public func keep(_ ownerID: String, _ subscriptions: [NativeRPCSubscription]) { leases[ownerID, default: []] += subscriptions }
    public func drop(_ ownerID: String) async {
        let held = leases.removeValue(forKey: ownerID) ?? []
        for subscription in held { await subscription.cancelAndWait() }
    }
}

/// Projects, preferences, shared account history, the Windows-only confinement
/// grant and WSL, natively (D14). Every write goes through its one owner: the
/// one NativeStateStore (`authority.state.store`), the composition state's
/// awaited preference writer (which publishes `prefs:changed`, index.ts L2901),
/// and `sessions.sharedHistory` with the profile store.
public enum BackendCompositionStateChannels {
    public static let events = ["prefs:changed"]

    public static func register(registry: NativeChannelRegistry, ownerID: String, authority: BackendCompositionAuthority,
                                sharedHistory: BackendAppSharedProjects,
                                profiles: BackendAccountProfileStore) async throws -> (invokes: [String], sends: [String], events: [String]) {
        let state = authority.state, store = state.store
        var table = BackendCompositionChannelTable()

        // index.ts L2864-2903 (tools projects.list/add/remove, settings.read/write).
        table.invoke("projects:list", .read) { _, _ in .array(await store.getProjects()) }
        table.invoke("projects:add", .change) { context, args in try await store.addProject(context.argument(0, in: args).requireString("project path")) }
        table.invoke("projects:remove", .change) { context, args in
            try await store.removeProject(context.argument(0, in: args).requireString("project path")); return .missing
        }
        table.invoke("prefs:get", .read) { _, _ in await store.getPreferences() }
        // The awaited writer tells every window (prefs:changed), the saver included.
        // TS also nudges the phone's server-settings view (serverSettings.noteChanged):
        // every committed write reaches BackendCompositionRemoteSettings' settings.changed push.
        table.invoke("prefs:set", .change) { context, args in try await state.writePreferencesAsync(context.argument(0, in: args)) }

        // shared-projects.ts L631-662 (tools accounts.status / accounts.share_history).
        let subject: @Sendable (NativeRPCValue) async throws -> BackendAccountProfile = { raw in
            guard let id = raw.string, !id.isEmpty else { throw BackendAccountFailure("an account id is required") }
            guard let profile = try await profiles.find(id) else { throw BackendAccountFailure("no account with id \(id)") }
            return profile
        }
        table.invoke("accounts:history-state", .read) { context, args in
            let profile = try await subject(context.argument(0, in: args))
            let shown = await sharedHistory.state(profile)
            return .object([.init("state", shown.wire), .init("share", .string(BackendAppSharedProjects.describeShare(shown))),
                            .init("unshare", .string(BackendAppSharedProjects.describeUnshare(shown))),
                            .init("remove", .string(BackendAppSharedProjects.describeDelete(shown)))])
        }
        table.invoke("accounts:history-share", .change) { context, args in
            let profile = try await subject(context.argument(0, in: args))
            return try await sharedHistory.share(profile)
        }
        table.invoke("accounts:history-unshare", .change) { context, args in
            let profile = try await subject(context.argument(0, in: args))
            return try await sharedHistory.unshare(profile).wire
        }

        // confine/ipc.ts L193-206 on darwin: {result: null, state} / {ok: true, detail: '', state}.
        // No tool may move the confinement boundary, so these are the window's alone.
        for channel in ["confine:grant", "confine:withdraw"] {
            table.invoke(channel, .window) { context, args in try BackendAppConfinementChannels().invoke(channel, args: args, context: context) }
        }

        // wsl.ts L1049-1062 on a Mac: `supported` is false, a reading is `absent`
        // with no distributions, nothing is ever chosen, and no home is known.
        // Terminal Deck is Mac-only (Asad); WSL itself is not ported.
        table.invoke("wsl:status", .window) { _, _ in Self.wslOnMac }
        table.invoke("wsl:choose", .window) { _, _ in Self.wslOnMac }

        return try await table.install(registry: registry, ownerID: ownerID, authority: authority, events: Self.events)
    }

    /// WslSnapshot (wsl.ts L826-840) as a Mac answers it after its first reading.
    public static let wslOnMac = NativeRPCValue.object([.init("supported", .bool(false)), .init("state", .string("absent")),
        .init("distros", .array([])), .init("chosen", .null), .init("active", .null), .init("home", .null),
        .init("detail", .null), .init("read", .bool(true))])
}
