import Foundation
import TerminalDeckNativeCore

public enum BackendAGSCodec {
    public static func value<T: Encodable>(_ value: T) throws -> NativeRPCValue { try .parseJSON(JSONEncoder().encode(value)) }
    public static func decode<T: Decodable>(_ type: T.Type, _ value: NativeRPCValue) throws -> T {
        do { return try JSONDecoder().decode(type, from: value.encodedJSON()) }
        catch { throw NativeRPCError.invalidArguments("The settings record is incomplete or has an invalid field.") }
    }
    public static func preserveMaskedEnvironment(_ submitted: [String: String], previous: [String: String]) throws -> [String: String] {
        var result = submitted
        for (name, value) in submitted where value == "••••••••" {
            guard let old = previous[name] else { throw NativeRPCError.invalidArguments("A masked environment value has no saved value. Enter it again.") }
            result[name] = old
        }
        return result
    }
    public static func maskedDefaults(_ defaults: AGSDefaults) throws -> NativeRPCValue {
        let secrets = Array(defaults.providers.values.flatMap { $0.environment.values })
        var value = try self.value(defaults)
        value = value.setting("providers", .object(try defaults.providers.keys.sorted().map { .init($0, try masked(defaults.providers[$0]!)) }))
        value = value.setting("hooks", .array(try defaults.hooks.map { hook in
            var safe = try self.value(hook)
            if let address = hook.webhook {
                safe = safe.setting("webhook", .string("••••••••"))
                    .setting("webhookHost", URL(string: address)?.host.map(NativeRPCValue.string) ?? .null)
            }
            for name in ["command"] where !safe[name].isNullish { safe = safe.setting(name, masking(safe[name], secrets: secrets)) }
            return safe
        }))
        return value
    }
    public static func masked(_ settings: AGSAgentSettings) throws -> NativeRPCValue {
        var value = try self.value(settings)
        value = value.setting("environment", .object(settings.environment.keys.sorted().map { .init($0, .string("••••••••")) }))
        value = value.setting("hooks", .array(try settings.hooks.map { hook in
            var safe = try self.value(hook)
            for name in ["command", "matcher"] where !safe[name].isNullish { safe = safe.setting(name, masking(safe[name], secrets: Array(settings.environment.values))) }
            return safe
        }))
        return value
    }
    public static func restoreMaskedHooks(_ submitted: [AGSCLIHook], previous: AGSAgentSettings) throws -> [AGSCLIHook] {
        try submitted.map { hook in
            var hook = hook
            if let old = previous.hooks.first(where: { $0.id == hook.id }) {
                if hook.command == masking(.string(old.command), secrets: Array(previous.environment.values)).string { hook.command = old.command }
                if let matcher = old.matcher, hook.matcher == masking(.string(matcher), secrets: Array(previous.environment.values)).string { hook.matcher = matcher }
            }
            guard !hook.command.contains("••••••••"), hook.matcher?.contains("••••••••") != true else { throw NativeRPCError.invalidArguments("A hook contains a masked value. Keep its saved command or enter a complete replacement.") }
            return hook
        }
    }
    public static func restoreMaskedAppHooks(_ submitted: [AGSAppHook], previous: AGSDefaults) throws -> [AGSAppHook] {
        let secrets = Array(previous.providers.values.flatMap { $0.environment.values })
        return try submitted.map { hook in
            var hook = hook
            if let old = previous.hooks.first(where: { $0.id == hook.id }) {
                if hook.webhook == "••••••••" { hook.webhook = old.webhook }
                if let command = old.command, hook.command == masking(.string(command), secrets: secrets).string { hook.command = command }
            }
            guard hook.command?.contains("••••••••") != true, hook.webhook?.contains("••••••••") != true else { throw NativeRPCError.invalidArguments("A hook contains a masked value. Keep its saved action or enter a complete replacement.") }
            return hook
        }
    }
    /// A setting value shorter than this is left readable (#528): a "1" or "true" is not a
    /// secret, and hiding it dots out every "1" in a command or a hook reply. The same
    /// length the shared rule takes from an environment (BackendSharedRedact.secretsFromEnv).
    public static let minimumMaskedLength = 8
    public static func masking(_ value: NativeRPCValue, secrets: [String]) -> NativeRPCValue {
        if let text = value.string {
            return .string(secrets.filter { $0.utf16.count >= minimumMaskedLength }.sorted { $0.count > $1.count }.reduce(text) { $0.replacingOccurrences(of: $1, with: "••••••••") })
        }
        if let fields = value.fields { return .object(fields.map { .init($0.key, masking($0.value, secrets: secrets)) }) }
        if let entries = value.elements { return .array(entries.map { masking($0, secrets: secrets) }) }; return value
    }
}
private struct BackendAGSState: Codable, Sendable {
    var version = 1
    var defaults = AGSDefaults()
    var profiles: [String: AGSAgentSettings] = [:]
}
/// Private, typed proposal for TAG's combined transaction; never a wire value.
public struct BackendAGSProfileTransaction: Sendable {
    fileprivate let token: UUID
    fileprivate let persistence: BackendTaskPersistence
    fileprivate let before: Data?
    fileprivate let after: Data
    public func publish() throws { try persistence.writeBytes("ags-settings.json", data: after) }
    public func restore() throws {
        if let before { try persistence.writeBytes("ags-settings.json", data: before) }
        else { try persistence.remove("ags-settings.json") }
    }
}
/// Reuses the app's safe-storage cipher and its exclusive private record writer.
/// Full records are encrypted; never a plaintext env sidecar or a new Keychain identity.
public actor BackendAGSStore {
    private let persistence: BackendTaskPersistence, cipher: any BackendAccountVaultCipher
    private let changed: @Sendable () async -> Void
    private let supportedAppEvents: Set<String>
    private var state = BackendAGSState(), started = false, revision: UInt64 = 0
    private var transaction: (token: UUID, next: BackendAGSState)?
    public init(persistence: BackendTaskPersistence, cipher: any BackendAccountVaultCipher,
                supportedAppEvents: Set<String> = Set(AGSCapabilities.appEvents), changed: @escaping @Sendable () async -> Void = {}) {
        self.persistence = persistence; self.cipher = cipher; self.changed = changed
        self.supportedAppEvents = supportedAppEvents
    }
    public func start() throws {
        guard !started else { return }
        if let record = try persistence.read("ags-settings.json", maximumBytes: 4 * 1024 * 1024) {
            guard record["version"].number == 1, let blob = record["encrypted"].string.flatMap({ Data(base64Encoded: $0) }) else { throw NativeRPCError.malformed("The private agent settings cannot be read.") }
            guard cipher.available() else { throw unavailable() }
            let plain: String
            do { plain = try cipher.decrypt(blob) } catch { throw unavailable() }
            guard plain.utf8.count <= 2 * 1024 * 1024 else { throw NativeRPCError.malformed("The private agent settings are too large.") }
            let next = try JSONDecoder().decode(BackendAGSState.self, from: Data(plain.utf8))
            // No cap on how many agents have settings (Asad, 11 Oct); the record's size is still checked above.
            guard next.version == 1 else { throw NativeRPCError.malformed("The private agent settings version is unsupported.") }
            try BackendAGSValidation.check(next.defaults)
            try requirePublishedEvents(next.defaults)
            for (id, settings) in next.profiles { try profileID(id); try BackendAGSValidation.check(settings) }
            state = next
        }
        started = true
    }
    public func currentRevision() throws -> UInt64 { try requireStarted(); return revision }
    public func profile(_ id: String) throws -> AGSAgentSettings? { try requireStarted(); try profileID(id); return state.profiles[id] }
    public func defaults() throws -> AGSDefaults { try requireStarted(); return state.defaults }
    public func view(profile id: String?) throws -> NativeRPCValue {
        try requireStarted()
        if let id {
            try profileID(id)
            return .object([.init("revision", .number(Double(revision))), .init("profile", .string(id)),
                            .init("settings", try state.profiles[id].map(BackendAGSCodec.masked) ?? .null)])
        }
        return .object([.init("revision", .number(Double(revision))), .init("defaults", try BackendAGSCodec.maskedDefaults(state.defaults))])
    }
    /// Same authorized profile, with inherited public controls for planning.
    /// The editable masked record and its revision remain unchanged.
    public func controlsView(profile id: String, base: AGSAgentSettings) throws -> NativeRPCValue {
        try requireStarted(); try profileID(id)
        let profile = state.profiles[id] ?? base
        let resolved = try BackendAGSPolicy.resolve(defaults: state.defaults.providers[profile.provider], profile: profile)
        var result = try view(profile: id)
        if result["settings"].isNullish { result = result.setting("settings", try BackendAGSCodec.masked(base)) }
        let effective = NativeRPCValue.object([.init("provider", .string(resolved.provider)), .init("model", resolved.model.map(NativeRPCValue.string) ?? .null),
            .init("effort", resolved.effort.map(NativeRPCValue.string) ?? .null), .init("permissionMode", resolved.permissionMode.map(NativeRPCValue.string) ?? .null),
            .init("efficiency", try resolved.efficiency.map(BackendAGSCodec.value) ?? .null)])
        return result.setting("effective", effective)
    }
    public func saveProfile(_ id: String, settings: AGSAgentSettings, expectedRevision: UInt64) async throws {
        try requireNoTransaction()
        try requireStarted(); try profileID(id); try BackendAGSValidation.check(settings); try checkRevision(expectedRevision)
        var next = state
        next.profiles[id] = settings; try commit(next); await changed()
    }
    public func saveDefaults(_ defaults: AGSDefaults, expectedRevision: UInt64) async throws {
        try requireNoTransaction()
        try requirePublishedEvents(defaults)
        try requireStarted(); try BackendAGSValidation.check(defaults); try checkRevision(expectedRevision)
        var next = state; next.defaults = defaults; try commit(next); await changed()
    }
    /// Used by TAG import/owner delete while holding the existing profile transaction.
    public func removeProfile(_ id: String, expectedRevision: UInt64) async throws {
        try requireNoTransaction()
        try requireStarted(); try profileID(id); try checkRevision(expectedRevision)
        var next = state; next.profiles[id] = nil; try commit(next); await changed()
    }
    public func prepareProfileTransaction(_ id: String, settings: AGSAgentSettings, expectedRevision: UInt64) throws -> BackendAGSProfileTransaction {
        try prepareProfilesTransaction([id: settings], expectedRevision: expectedRevision)
    }
    /// One encrypted record transaction for an exact, prevalidated group.
    public func prepareProfilesTransaction(_ profiles: [String: AGSAgentSettings], expectedRevision: UInt64) throws -> BackendAGSProfileTransaction {
        try requireStarted(); try requireNoTransaction(); try checkRevision(expectedRevision); try persistence.writable()
        // One group publish carries at most one request's agents (save-many: 50 per request); not a cap on agents.
        guard !profiles.isEmpty, profiles.count <= BackendTAGAgentProfile.maximumPerCall else { throw BackendAGSValidation.bad("Save at most \(BackendTAGAgentProfile.maximumPerCall) agents' settings in one request.") }
        guard cipher.available() else { throw unavailable() }
        var next = state
        for (id, settings) in profiles {
            try profileID(id); try BackendAGSValidation.check(settings); next.profiles[id] = settings
        }
        let before = try persistence.readOwnedBytes("ags-settings.json")
        let plain = String(decoding: try JSONEncoder().encode(next), as: UTF8.self)
        guard plain.utf8.count <= 2 * 1024 * 1024 else { throw BackendAGSValidation.bad("Agent settings are too large.") }
        let encrypted: Data
        do { encrypted = try cipher.encrypt(plain, existingVault: before != nil) } catch { throw unavailable() }
        let record: NativeRPCValue = .object([.init("version", .number(1)), .init("encrypted", .string(encrypted.base64EncodedString()))])
        let token = UUID(); transaction = (token, next)
        return .init(token: token, persistence: persistence, before: before, after: try record.encodedJSON(pretty: true))
    }
    /// TAG calls this only after all owned files have been published. Changes
    /// remain unpublished until TAG's canonical cache is committed as well.
    public func finishProfileTransaction(_ prepared: BackendAGSProfileTransaction) throws {
        guard let pending = transaction, pending.token == prepared.token else { throw BackendAGSMCP.changed() }
        if persistence.ownership != .memory, try persistence.readOwnedBytes("ags-settings.json") != prepared.after {
            throw NativeRPCError(code: "settings-changed", message: "The prepared agent settings were not published intact.")
        }
        state = pending.next; revision += 1; transaction = nil
    }
    public func cancelProfileTransaction(_ prepared: BackendAGSProfileTransaction) throws {
        guard transaction?.token == prepared.token else { throw BackendAGSMCP.changed() }
        if persistence.ownership != .memory, try persistence.readOwnedBytes("ags-settings.json") != prepared.before {
            throw NativeRPCError(code: "settings-rollback-failed", message: "Agent settings rollback did not restore the original record.")
        }
        transaction = nil
    }
    public func announceProfileTransaction() async { await changed() }
    private func requireNoTransaction() throws {
        guard transaction == nil else { throw NativeRPCError(code: "settings-saving", message: "The combined agent profile save is still running. Try again after it finishes.") }
    }
    private func requirePublishedEvents(_ defaults: AGSDefaults) throws {
        guard defaults.hooks.allSatisfy({ !$0.enabled || supportedAppEvents.contains($0.event) }) else {
            throw NativeRPCError(code: "unavailable", message: "This host does not publish that hook event yet. Keep the hook disabled until its actual producer is installed.")
        }
    }
    private func commit(_ next: BackendAGSState) throws {
        try persistence.writable()
        guard cipher.available() else { throw unavailable() }
        let plain = String(decoding: try JSONEncoder().encode(next), as: UTF8.self)
        guard plain.utf8.count <= 2 * 1024 * 1024 else { throw BackendAGSValidation.bad("Agent settings are too large.") }
        let exists = try persistence.read("ags-settings.json") != nil
        let blob: Data
        do { blob = try cipher.encrypt(plain, existingVault: exists) } catch { throw unavailable() }
        try persistence.write("ags-settings.json", value: .object([.init("version", .number(1)), .init("encrypted", .string(blob.base64EncodedString()))]))
        state = next; revision += 1
    }
    private func checkRevision(_ expected: UInt64) throws { guard expected == revision else { throw NativeRPCError(code: "settings-changed", message: "Agent settings changed while approval was open. Read them again before saving.") } }
    private func profileID(_ id: String) throws { guard id.range(of: #"^[a-z0-9][a-z0-9-]{0,39}$"#, options: .regularExpression) != nil else { throw BackendAGSValidation.bad("Choose an existing task-agent identifier.") } }
    private func requireStarted() throws { guard started else { throw NativeRPCError(code: "unavailable", message: "Agent settings have not started.") } }
    private func unavailable() -> NativeRPCError { .init(code: "secure-store-unavailable", message: "The app's secure store is unavailable. Agent settings were kept unchanged.") }
}
