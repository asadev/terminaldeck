import Foundation
import TerminalDeckNativeCore

/// Restores explicit owner session choices by the existing ledger's stable tab
/// identity. Raw env/hooks are encrypted here, never put in the session ledger.
public actor BackendAGSSessionChoices {
    private struct Record: Codable { let version: Int; var entries: [String: AGSAgentSettings] }
    private let persistence: BackendTaskPersistence, cipher: any BackendAccountVaultCipher
    private var entries: [String: AGSAgentSettings] = [:], started = false
    public init(persistence: BackendTaskPersistence, cipher: any BackendAccountVaultCipher) { self.persistence = persistence; self.cipher = cipher }
    public func start() throws {
        guard !started else { return }
        if let raw = try persistence.read("ags-session-choices.json", maximumBytes: 4 * 1024 * 1024) {
            guard raw["version"].number == 1, let bytes = raw["encrypted"].string.flatMap({ Data(base64Encoded: $0) }), cipher.available() else { throw unavailable() }
            let record: Record
            do { record = try JSONDecoder().decode(Record.self, from: Data(cipher.decrypt(bytes).utf8)) } catch { throw unavailable() }
            guard record.version == 1, record.entries.count <= 512 else { throw unavailable() }
            for (key, value) in record.entries { try validKey(key); try BackendAGSValidation.check(value) }
            entries = record.entries
        }; started = true
    }
    /// Probe the existing cipher BEFORE tokens or CLI hooks can run. No file is written.
    public func prepareForLaunch() throws {
        try ready(); try persistence.writable(); guard cipher.available() else { throw unavailable() }
        do { _ = try cipher.encrypt("{}", existingVault: try persistence.read("ags-session-choices.json") != nil) } catch { throw unavailable() }
    }
    /// Only the authorized saved-ledger restore path calls this; never a page/MCP read tool.
    public func choice(tabKey: String) throws -> AGSAgentSettings? { try ready(); try validKey(tabKey); return entries[tabKey] }
    /// `keeping`: the tabs sessions still hold. 22 Oct (Asad, "remove this 128 limit"): a session that ended while
    /// the app was closed never removed its choice, so after 512 every agent launch was refused. When full, the
    /// choices of tabs no session holds are dropped first; only 512 tabs actually in use can still refuse.
    public func save(tabKey: String, settings: AGSAgentSettings, keeping live: Set<String>? = nil) throws {
        try ready(); try validKey(tabKey); try BackendAGSValidation.check(settings)
        var next = entries
        if next[tabKey] == nil, next.count >= 512, let live { next = next.filter { live.contains($0.key) } }
        guard next[tabKey] != nil || next.count < 512 else { throw NativeRPCError(code: "settings-full", message: "Too many saved session settings. Close an old session before keeping another choice.") }
        next[tabKey] = settings; try commit(next)
    }
    public func remove(tabKey: String) throws { try ready(); try validKey(tabKey); var next = entries; next[tabKey] = nil; try commit(next) }
    private func commit(_ next: [String: AGSAgentSettings]) throws {
        try persistence.writable(); guard cipher.available() else { throw unavailable() }
        let bytes = try JSONEncoder().encode(Record(version: 1, entries: next)); guard bytes.count <= 2 * 1024 * 1024 else { throw unavailable() }
        let existing = try persistence.read("ags-session-choices.json") != nil
        let encrypted: Data
        do { encrypted = try cipher.encrypt(String(decoding: bytes, as: UTF8.self), existingVault: existing) } catch { throw unavailable() }
        try persistence.write("ags-session-choices.json", value: .object([.init("version", .number(1)), .init("encrypted", .string(encrypted.base64EncodedString()))]))
        entries = next
    }
    private func validKey(_ key: String) throws { guard !key.isEmpty, key.utf8.count <= 200, !key.contains("\0"), !key.contains("/") else { throw NativeRPCError.invalidArguments("The saved tab identity is invalid.") } }
    private func ready() throws { guard started else { throw unavailable() } }
    private func unavailable() -> NativeRPCError { .init(code: "secure-store-unavailable", message: "Private session settings could not be read or saved. Their encrypted record was kept unchanged.") }
}

/// Existing configuration owns profile identity and scalar values; this helper
/// resolves only the AGS extension. All caller authorization stays with TAG/INT2.
public enum BackendAGSSettingsResolution {
    public static func resolve(input: BackendCreateSessionInput, store: BackendAGSStore, configuration: BackendTaskConfiguration,
                               defaultProvider: String, taskProfile: String?, requested: AGSAgentSettings? = nil,
                               playbook: BackendPlaybookLayer? = nil, sessionProviderChoice: Bool = false) async throws -> AGSAgentSettings? {
        let provider = input.provider ?? defaultProvider
        guard AGSCapabilities.providers.contains(provider) else {
            guard requested == nil else { throw BackendAGSSelectedAccountFacts.unavailable("Private settings belong to an unsupported selected CLI.") }; return nil
        }
        let defaults = try await store.defaults().providers[provider]
        let id = taskProfile ?? input.agentProfileID ?? input.agentInstructions
        var profile: AGSAgentSettings
        var extensionExists = false
        if let id {
            guard let raw = try await configuration.agent(id), raw["status"].string == "active" else { throw BackendAGSSelectedAccountFacts.unavailable("The task agent is no longer active.") }
            let saved = try await store.profile(raw["id"].string ?? id)
            extensionExists = saved != nil
            profile = try saved ?? BackendAGSProfileProjection.settings(raw, defaultProvider: defaultProvider)
        } else { profile = AGSAgentSettings(provider: provider, model: input.model, effort: input.effort, permissionMode: input.permissionMode, allowedTools: input.allowedTools, deniedTools: input.deniedTools ?? []) }
        // PLAYBOOK-SEATS: the playbook's AI replaced the agent's own: its profile is carried to that AI.
        if profile.provider == provider || playbook?.provider == provider || sessionProviderChoice { profile = BackendPlaybookLayer.carried(profile, to: provider) }
        guard profile.provider == provider else { throw BackendAGSSelectedAccountFacts.unavailable("This agent is set to use a different AI. Choose that AI or change the agent's settings first.") }
        // Deck Memory: a playbook choice the plain launch cannot carry (a thinking level; a model or
        // permission for Codex or Gemini) goes through the same private settings path as a saved default.
        let playbookChoice = id == nil && (input.effort != nil || provider != "claude" && (input.model != nil || input.permissionMode != nil))
        let layered = playbook.map { !$0.isEmpty } ?? false
        guard defaults != nil || extensionExists || requested != nil || playbookChoice || layered else { return nil }
        func over(_ settings: AGSAgentSettings) -> AGSAgentSettings { playbook?.apply(to: settings) ?? settings }
        // A key may only narrow its owner. A restore relaunching the tab from its own saved settings is not a key
        // request (FIXRESTART: those carry the fresh-start bypass, so every agent tab was refused after a restart).
        if taskProfile != nil, let requested, !BackendAGSLaunchScope.ownSavedChoice { try BackendAGSPolicy.requireNarrowing(requested, owner: over(BackendAGSPolicy.resolve(defaults: defaults, profile: profile))) }
        return over(try BackendAGSPolicy.resolve(defaults: defaults, profile: profile, session: requested))
    }
}
