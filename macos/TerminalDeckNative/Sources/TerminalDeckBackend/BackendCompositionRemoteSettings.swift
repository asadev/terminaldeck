import Foundation
import TerminalDeckNativeCore

/// The two settings this machine owns, served to its own phones exactly as the
/// TS host did: host-core.ts createServerSettingsAccess (rows, apply sentences),
/// server.ts settingsServe (`settings.read` → `settings.state`, `settings.apply`
/// → `settings.applied`) and the `settings.changed` push to every own device
/// that named `settings`, fired on every preference write whichever surface
/// made it (prefs:set, Hoot, the deck tools, a phone's own apply).
public final class BackendCompositionRemoteSettings: @unchecked Sendable {
    public static let capability = "settings"
    public static let messageTypes: Set<String> = ["settings.read", "settings.apply"]
    /// protocol.ts SERVER_SETTINGS, in wire order.
    public static let keys = ["agents.defaultProvider", "general.restoreSessions"]
    /// providers.ts providersFor on a Mac: the table's keys in order, with their labels.
    public static let providers: [(id: String, label: String)] = [
        ("claude", "Claude Code"), ("codex", "Codex CLI"), ("gemini", "Gemini CLI"), ("shell", "Shell"),
    ]

    private let state: BackendCompositionState
    public init(state: BackendCompositionState) { self.state = state }

    /// rowFor(key): `{key, value, options}` for the default tool, `{key, value}` for restore.
    public func row(_ key: String, preferences: NativeRPCValue) -> NativeRPCValue {
        if key == "agents.defaultProvider" {
            return .object([.init("key", .string(key)), .init("value", .string(preferences["defaultProvider"].string ?? "")),
                .init("options", .array(Self.providers.map { .string($0.id) }))])
        }
        return .object([.init("key", .string(key)), .init("value", .string(preferences["restoreSessions"].bool == true ? "true" : "false"))])
    }
    /// read(): both rows from the current preferences.
    public func rows() async -> NativeRPCValue {
        let preferences = await state.store.getPreferences()
        return .array(Self.keys.map { row($0, preferences: preferences) })
    }

    /// apply(key, value): the store write and the machine's own sentence.
    public func apply(key: String, value: String) async throws -> (ok: Bool, message: String, setting: NativeRPCValue) {
        guard Self.keys.contains(key) else {
            return (false, "That is not a setting this machine owns.", .object([.init("key", .string(key)), .init("value", .string(""))]))
        }
        if key == "agents.defaultProvider" {
            guard let spec = Self.providers.first(where: { $0.id == value }) else {
                return (false, "That is not a coding tool this machine can start.", row(key, preferences: await state.store.getPreferences()))
            }
            let saved = try await state.writePreferencesAsync(.object([.init("defaultProvider", .string(spec.id))]))
            return (true, "Default coding tool set to \(spec.label).", row(key, preferences: saved))
        }
        guard value == "true" || value == "false" else {
            return (false, "That setting is on or off.", row(key, preferences: await state.store.getPreferences()))
        }
        let saved = try await state.writePreferencesAsync(.object([.init("restoreSessions", .bool(value == "true"))]))
        return (true, value == "true" ? "The last layout will be restored at launch." : "A fresh start each launch.", row(key, preferences: saved))
    }

    /// settingsServe for an own device (the host's `ownerOnly` policy refuses the
    /// rest with server.ts's own sentence before this runs).
    public func feature() -> BackendRemoteHostFeature {
        .init(capability: Self.capability, messageTypes: Self.messageTypes, policy: .ownerOnly) { [self] message, _ in
            let rid = try message["rid"].requireString("rid", nonempty: true)
            if message.type == "settings.read" {
                return [try .init(.settingsState, fields: [.init("rid", .string(rid)), .init("settings", await rows())])]
            }
            let key = try message["key"].requireString("key", nonempty: true)
            let value = try message["value"].requireString("value", nonempty: true)
            let result = try await apply(key: key, value: value)
            return [try .init(.settingsApplied, fields: [.init("rid", .string(rid)), .init("ok", .bool(result.ok)),
                .init("message", .string(result.message)), .init("setting", result.setting)])]
        }
    }
    /// `{ t: 'settings.changed', settings: read() }`, read at send time.
    public func changed() async throws -> BackendRemoteServerMessage {
        try .init(.settingsChanged, fields: [.init("settings", await rows())])
    }
}
