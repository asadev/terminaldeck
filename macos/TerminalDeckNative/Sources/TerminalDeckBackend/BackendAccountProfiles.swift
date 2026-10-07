import Foundation
import TerminalDeckNativeCore

public struct BackendAccountProfile: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var provider: String
    public var configDir: String
    public var system: Bool
    public var color: String
    public var createdAt: Double
    public var lastUsedAt: Double?
    public var loginStore: String?
    public var keptSlots: [String]?
    public var identity: BackendAccountIdentity { BackendAccountIdentity(id: id, name: name) }
    public var promised: Bool { loginStore == "app" || !(keptSlots ?? []).isEmpty }
    /// `SIGN_IN_PROVIDERS`: every agent with a login, derived from the catalogue.
    public static let signInProviders = BackendAccountStrategies.signInProviders
    public static let colors = ["--accent", "--status-completed", "--status-waiting", "--status-input", "--color-warning", "--color-critical"]
    public static let maximumNameLength = 60
    /// `ACCOUNT_STRATEGIES[provider].label`, which is the catalogue's label.
    public static func providerLabel(_ provider: String) -> String { CodingAICatalog.label(provider) }
    public static func configEnvironment(_ provider: String) -> String? { BackendAccountStrategies.strategy(provider)?.configEnv }
    public static func systemID(_ provider: String) -> String { provider == "claude" ? "system" : "system:" + provider }
    public static func systemProvider(_ id: String) -> String? { signInProviders.first { systemID($0) == id } }
    /// `generatedSystemName`: the name an agent's own install has until renamed.
    public static func generatedSystemName(_ provider: String) -> String { provider == "claude" ? "Default" : "Default (\(providerLabel(provider)))" }
    public static func validSlot(_ value: String) -> Bool { value.range(of: "^(keychain|file|env):[A-Za-z0-9 ._-]{1,80}$", options: .regularExpression) != nil }
    public static func loginSlot(_ value: String) -> Bool { value.range(of: "^keychain:Claude Code(?:-[a-z]+)*-credentials$", options: .regularExpression) != nil }

    /// `slugifyProfileId` (profiles.ts): NFKD, lower-case, runs of anything
    /// but [a-z0-9] become one dash, trimmed, at most 32; never empty and never
    /// a Windows device name.
    public static func slugifyProfileID(_ name: String) -> String {
        let slug = String(name.decomposedStringWithCompatibilityMapping.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "^-+|-+$", with: "", options: .regularExpression).prefix(32))
        if slug.isEmpty { return "profile" }
        return slug.range(of: "^(con|prn|aux|nul|com[1-9]|lpt[1-9])$", options: .regularExpression) != nil ? slug + "-profile" : slug
    }
    /// `uniqueProfileId`: append -2, -3 … until free; never the system id.
    public static func uniqueProfileID(_ base: String, taken: Set<String>) throws -> String {
        if !taken.contains(base), base != "system" { return base }
        for suffix in 2..<1000 where !taken.contains("\(base)-\(suffix)") { return "\(base)-\(suffix)" }
        throw BackendAccountFailure("could not allocate a profile id")
    }
    /// `profileTranscriptDir`: Claude Code files a profiled session's
    /// transcripts under `<configDir>/projects/<encoded cwd>`, not ~/.claude.
    public static func profileTranscriptDir(_ profile: BackendAccountProfile, cwd: String) -> String {
        URL(fileURLWithPath: profile.configDir).appendingPathComponent("projects")
            .appendingPathComponent(NativeTranscriptPaths.encodeProjectPath(cwd)).path
    }
    /// `inheritedSystemInstalls(env)`: every agent whose own install this app
    /// inherited, redirected, from the environment it was launched in. A
    /// variable set to only whitespace is how a shell spells "unset".
    public static func inheritedSystemInstalls(environment: [String: String]) -> [BackendAccountInheritedInstall] {
        signInProviders.compactMap { provider in
            guard let key = configEnvironment(provider), let named = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !named.isEmpty else { return nil }
            return BackendAccountInheritedInstall(provider: provider, env: key, dir: named)
        }
    }
}

/// `InheritedInstall`: the agent, the variable that named the directory, and
/// the directory, so a screen can say all three.
public struct BackendAccountInheritedInstall: Equatable, Sendable {
    public let provider: String
    public let env: String
    public let dir: String
    public var wireValue: NativeRPCValue { .object([.init("provider", .string(provider)), .init("env", .string(env)), .init("dir", .string(dir))]) }
}

public struct BackendAccountProfilesSnapshot: Sendable {
    public let profiles: [BackendAccountProfile]
    public let defaultProfileID: String?
    public let projectDefaults: [String: String]
    public let systemNames: [String: String]
}

public actor BackendAccountProfileStore {
    public nonisolated let configuration: BackendAccountConfiguration
    public nonisolated let readiness: BackendLaunchReadiness
    private let file: URL
    private var lease: BackendAccountWriterLease?
    private var raw: NativeRPCValue = .object([])
    private var profiles: [BackendAccountProfile] = []
    private var defaultID: String?
    private var projectDefaults: [String: String] = [:]
    private var systemNames: [String: String] = [:]
    /// profiles.ts `backupBeforeWrite`: the file on disk could not be read,
    /// was not a JSON object, or came from a newer version. It boots as what
    /// could be read (possibly empty) and is moved aside before the first write.
    private var backupBeforeWrite = false
    private var creatingIDs = Set<String>()
    private var creatingNames = Set<String>()
    private var creatingDirectories: [String: String] = [:]

    public init(configuration: BackendAccountConfiguration, stateStore: NativeStateStore) throws {
        self.configuration = configuration
        file = configuration.dataDirectory.appendingPathComponent("profiles.json")
        let exclusive = stateStore.ownership == .exclusive && stateStore.file?.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path == configuration.dataDirectory.resolvingSymlinksInPath().path
        readiness = exclusive ? .ready : .unavailable("The whole native state facade has not taken ownership from Node.")
        if exclusive { lease = try BackendAccountWriterLease(file: file) }
        // getState(): absent is first run and the only case where empty is the
        // truth. Unreadable or corrupt boots empty — a launch failure is worse
        // than a lost list — but the next write must not make the loss permanent.
        var parsed: NativeRPCValue?
        do {
            if let data = try BackendAccountFiles.boundedRead(file, maximum: 4 * 1024 * 1024) {
                if let value = try? NativeRPCValue.parseJSON(data), value.fields != nil { parsed = value } else { backupBeforeWrite = true }
            }
        } catch { backupBeforeWrite = true }
        raw = parsed ?? .object([])
        // A newer version keeps its unknown keys, but what it meant by the keys
        // parsed here is unknowable, so the original stays recoverable.
        if let version = raw["version"].number, version > 1 { backupBeforeWrite = true }
        let now = Date().timeIntervalSince1970 * 1000
        var seen = Set<String>()
        for value in raw["profiles"].elements ?? [] {
            // sanitizeProvider: absent means Claude; anything but a supported
            // agent's id drops the row rather than downgrading it.
            let providerValue = value["provider"]
            guard let provider = providerValue.isNullish ? "claude" : providerValue.string.flatMap({ BackendAccountStrategies.supportsAccounts($0) ? $0 : nil }),
                  let id = value["id"].string, !id.isEmpty, id != "system", !seen.contains(id),
                  let name = value["name"].string, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let directory = value["configDir"].string, directory.hasPrefix("/"), !directory.contains("\0") else { continue }
            seen.insert(id)
            var slots: [String] = []
            for slot in (value["keptSlots"].elements ?? []).compactMap(\.string) where BackendAccountProfile.validSlot(slot) && !slots.contains(slot) { slots.append(slot) }
            profiles.append(BackendAccountProfile(id: id, name: name, provider: provider, configDir: directory, system: false,
                color: value["color"].string ?? BackendAccountProfile.colors[0], createdAt: value["createdAt"].number ?? now,
                lastUsedAt: value["lastUsedAt"].number, loginStore: value["loginStore"].string == "app" ? "app" : nil,
                keptSlots: slots.isEmpty ? nil : slots))
        }
        let known = Set(profiles.map(\.id) + BackendAccountProfile.signInProviders.map(BackendAccountProfile.systemID))
        if let id = raw["defaultProfileId"].string, known.contains(id) { defaultID = id }
        for field in raw["projectDefaults"].fields ?? [] { if let id = field.value.string, known.contains(id) { projectDefaults[Self.projectKey(field.key)] = id } }
        for field in raw["systemNames"].fields ?? [] {
            if BackendAccountProfile.systemProvider(field.key) != nil, let name = try? Self.normalizedName(field.value) { systemNames[field.key] = name }
        }
    }

    /// `canonicalProjectKey`: `/w/app` and `/w/app/` are one project.
    private static func projectKey(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

    public func snapshot() throws -> BackendAccountProfilesSnapshot {
        BackendAccountProfilesSnapshot(profiles: profiles, defaultProfileID: defaultID, projectDefaults: projectDefaults, systemNames: systemNames)
    }
    private func system(_ provider: String) -> BackendAccountProfile {
        let id = BackendAccountProfile.systemID(provider)
        return BackendAccountProfile(id: id, name: systemNames[id] ?? BackendAccountProfile.generatedSystemName(provider), provider: provider,
            configDir: configuration.systemDirectory(provider), system: true,
            color: BackendAccountProfile.colors[BackendAccountProfile.signInProviders.firstIndex(of: provider) ?? 0], createdAt: 0)
    }
    public func find(_ id: String) throws -> BackendAccountProfile? {
        if let provider = BackendAccountProfile.systemProvider(id) { return system(provider) }
        return profiles.first { $0.id == id }
    }
    public func list(provider: String? = nil) throws -> [BackendAccountProfile] {
        (BackendAccountProfile.signInProviders.map(system) + profiles).filter { provider == nil || $0.provider == provider }
    }
    public func resolve(sessionProfileID: String?, projectPath: String?, provider: String?) throws -> BackendAccountProfile {
        let projectID = projectPath.flatMap { $0.isEmpty ? nil : projectDefaults[Self.projectKey($0)] }
        for candidate in [sessionProfileID, projectID, defaultID].compactMap({ $0 }) {
            if let found = try find(candidate), provider == nil || found.provider == provider { return found }
        }
        return system(provider.flatMap { BackendAccountStrategies.hasSignIn($0) ? $0 : nil } ?? "claude")
    }
    public func managed(_ profile: BackendAccountProfile) -> Bool { !profile.system && BackendAccountFiles.descendant(profile.configDir, root: configuration.profilesRoot.path) }
    private func writable() throws {
        guard readiness == .ready, lease != nil else { throw BackendAccountFailure("Native accounts cannot write while Node owns the store.") }
    }
    private func persist() throws {
        try writable()
        // Overwriting a file that could not be read is the one irreversible
        // thing this store does to a user's config: move it aside first.
        if backupBeforeWrite {
            if Darwin.rename(file.path, file.path + ".bak-\(Int64(Date().timeIntervalSince1970 * 1000))") != 0, errno != ENOENT {
                throw BackendAccountFailure("The existing profile list could not be backed up, so it was not overwritten.")
            }
            backupBeforeWrite = false
        }
        let encodedProfiles = try profiles.map { try NativeRPCValue.parseJSON(JSONEncoder().encode($0)) }
        let next = raw.setting("version", .number(1)).setting("profiles", .array(encodedProfiles))
            .setting("defaultProfileId", defaultID.map(NativeRPCValue.string) ?? .null)
            .setting("projectDefaults", .object(projectDefaults.sorted { $0.key < $1.key }.map { .init($0.key, .string($0.value)) }))
            .setting("systemNames", .object(systemNames.sorted { $0.key < $1.key }.map { .init($0.key, .string($0.value)) }))
        try BackendAccountFiles.writeAtomic(try next.encodedJSON(pretty: true), to: file)
        raw = next
    }
    /// `normalizeProfileName(raw: unknown)`: anything but a string has no name.
    public static func normalizedName(_ raw: NativeRPCValue) throws -> String {
        guard let text = raw.string else { throw BackendAccountFailure("a profile needs a name") }
        return try normalizedName(text)
    }
    public static func normalizedName(_ text: String) throws -> String {
        let cleaned = text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format ? " " : String($0) }.joined()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !cleaned.isEmpty else { throw BackendAccountFailure("a profile needs a name") }
        guard cleaned.utf16.count <= BackendAccountProfile.maximumNameLength else { throw BackendAccountFailure("profile names are limited to \(BackendAccountProfile.maximumNameLength) characters") }
        return cleaned
    }
    private static func nameClash(_ provider: String, _ name: String) -> BackendAccountFailure {
        BackendAccountFailure("a \(provider) account called \"\(name)\" already exists")
    }
    /// `adoptableConfigDir`: absolute, not an agent's own install, not another account's.
    private func adoptable(_ raw: String, provider: String) throws -> String {
        guard raw.hasPrefix("/"), !raw.contains("\0") else { throw BackendAccountFailure("a config directory must be an absolute path") }
        let resolved = URL(fileURLWithPath: raw).standardizedFileURL.path
        if isProtected(resolved) {
            throw BackendAccountFailure("that is your own \(BackendAccountProfile.providerLabel(provider)) install — the default account already uses it, and pointing a second account at it would break the login")
        }
        if let clash = profiles.first(where: { URL(fileURLWithPath: $0.configDir).standardizedFileURL.path == resolved }) {
            throw BackendAccountFailure("\"\(clash.name)\" already uses that config directory")
        }
        return resolved
    }
    public func create(name: String, provider: String = "claude", configDir: String? = nil, vaultManaged: Bool,
                       beforeCommit: (@Sendable (BackendAccountProfile) async throws -> Void)? = nil) async throws -> BackendAccountProfile {
        try writable()
        guard BackendAccountStrategies.supportsAccounts(provider) else { throw BackendAccountFailure(BackendAccountStrategies.unsupportedReason(provider)) }
        let name = try Self.normalizedName(name)
        let nameKey = provider + "\0" + name.lowercased()
        guard !creatingNames.contains(nameKey), !(try list(provider: provider)).contains(where: { $0.name.lowercased() == name.lowercased() }) else { throw Self.nameClash(provider, name) }
        let id = try BackendAccountProfile.uniqueProfileID(BackendAccountProfile.slugifyProfileID(name), taken: Set(try list().map(\.id)).union(creatingIDs))
        let directory = try configDir.map { try adoptable($0, provider: provider) } ?? configuration.profilesRoot.appendingPathComponent(id).path
        if let owner = creatingDirectories[directory] { throw BackendAccountFailure("\"\(owner)\" already uses that config directory") }
        // A managed directory cannot be protected, but an adopted account may
        // already point inside the profiles root; never share one directory.
        if let clash = profiles.first(where: { URL(fileURLWithPath: $0.configDir).standardizedFileURL.path == directory }) { throw BackendAccountFailure("\"\(clash.name)\" already uses that config directory") }
        guard !isProtected(directory) else { throw BackendAccountFailure("that is your own \(BackendAccountProfile.providerLabel(provider)) install — the default account already uses it, and pointing a second account at it would break the login") }
        creatingIDs.insert(id); creatingNames.insert(nameKey); creatingDirectories[directory] = name
        defer { creatingIDs.remove(id); creatingNames.remove(nameKey); creatingDirectories[directory] = nil }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let profile = BackendAccountProfile(id: id, name: name, provider: provider, configDir: directory, system: false,
            color: BackendAccountProfile.colors[(profiles.count + 1) % BackendAccountProfile.colors.count], createdAt: Date().timeIntervalSince1970 * 1000,
            loginStore: vaultManaged && BackendAccountFiles.descendant(directory, root: configuration.profilesRoot.path) ? "app" : nil)
        if profile.loginStore == "app", beforeCommit == nil { throw BackendAccountFailure("An app-kept new account requires the facade's stale-vault clearing transaction.") }
        try await beforeCommit?(profile)
        // Other mutations can run while the vault transaction awaits.
        guard !profiles.contains(where: { $0.id == id || $0.configDir == directory }) else { throw BackendAccountFailure("This profile was created concurrently. Its name or directory must be chosen again.") }
        profiles.append(profile)
        do { try persist() } catch { profiles.removeLast(); throw error }
        return profile
    }
    public func rename(id: String, name: String) throws -> BackendAccountProfile {
        try writable()
        guard let profile = try find(id) else { throw BackendAccountFailure("no profile with id \(id)") }
        let name = try Self.normalizedName(name)
        guard !(try list(provider: profile.provider)).contains(where: { $0.id != id && $0.name.lowercased() == name.lowercased() }) else { throw Self.nameClash(profile.provider, name) }
        if profile.system {
            // Typing the generated name back in is a reset, not an override.
            systemNames[id] = name == BackendAccountProfile.generatedSystemName(profile.provider) ? nil : name
        } else if let index = profiles.firstIndex(where: { $0.id == id }) { profiles[index].name = name }
        try persist()
        return try find(id)!
    }
    public func markSlotKept(id: String, slot: String) throws {
        guard BackendAccountProfile.validSlot(slot), let index = profiles.firstIndex(where: { $0.id == id }), !(profiles[index].keptSlots ?? []).contains(slot) else { return }
        try writable(); profiles[index].keptSlots = (profiles[index].keptSlots ?? []) + [slot]; try persist()
    }
    public func markUsed(id: String) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        try writable(); profiles[index].lastUsedAt = Date().timeIntervalSince1970 * 1000; try persist()
    }
    /// `setGlobalDefault(id)` when `projectPath` is nil, else `setProjectDefault(projectPath, id)`.
    public func setDefault(_ id: String?, projectPath: String? = nil) throws {
        try writable()
        if let projectPath, projectPath.isEmpty { throw BackendAccountFailure("a project path is required") }
        if let id, try find(id) == nil { throw BackendAccountFailure("no profile with id \(id)") }
        if let projectPath { projectDefaults[Self.projectKey(projectPath)] = id }
        else { defaultID = id == "system" ? nil : id }
        try persist()
    }
    public func removeMetadata(id: String) throws -> BackendAccountProfile {
        try writable()
        if let provider = BackendAccountProfile.systemProvider(id) {
            throw BackendAccountFailure("the default account is your own \(BackendAccountProfile.providerLabel(provider)) install and cannot be deleted")
        }
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw BackendAccountFailure("no profile with id \(id)") }
        let profile = profiles.remove(at: index)
        if defaultID == id { defaultID = nil }
        projectDefaults = projectDefaults.filter { $0.value != id }
        try persist()
        return profile
    }
    public func deleteManagedDirectory(_ profile: BackendAccountProfile) throws -> Bool {
        try writable()
        guard managed(profile), !isProtected(profile.configDir) else { return false }
        if FileManager.default.fileExists(atPath: profile.configDir) { try FileManager.default.removeItem(atPath: profile.configDir) }
        return true
    }
    /// `isProtectedDir`: home, the filesystem root, ~/.claude and every agent's
    /// own install are never adopted and never deleted.
    public nonisolated func isProtectedDir(_ directory: String) -> Bool { isProtected(directory) }
    private nonisolated func isProtected(_ directory: String) -> Bool {
        let value = URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath().path
        let protected = ["/", configuration.homeDirectory.path, configuration.homeDirectory.appendingPathComponent(".claude").path] + BackendAccountProfile.signInProviders.map { configuration.systemDirectory($0) }
        return protected.contains { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path == value }
    }
    public func close() { lease = nil }
}
