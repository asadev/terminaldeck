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
    public static func generatedSystemName(_ provider: String) -> String { CodingAIAccountLabels.generatedName(provider) }
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
    /// Every level's stored choice, per AI (ACCOUNTS-SPEC). The two fields above are the older, Claude-first view of it.
    public var levels = BackendAccountLevelsSnapshot()
}

public actor BackendAccountProfileStore {
    public nonisolated let configuration: BackendAccountConfiguration
    public nonisolated let readiness: BackendLaunchReadiness
    private let file: URL
    private var lease: BackendAccountWriterLease?
    private var raw: NativeRPCValue = .object([])
    private var profiles: [BackendAccountProfile] = []
    /// The levels (BackendAccountLevels.swift): provider → account id, for the whole app, per project folder, per seat.
    private var levels = BackendAccountLevelsSnapshot()
    /// An AI's own login named as the default in the older file ("system"): the same as naming nothing,
    /// kept only so the older field reads back as it was written.
    private var namedSystemDefault: String?
    /// The older single default: Claude's whole-app account (kept so older readers still work).
    private var defaultID: String? { levels.app["claude"] ?? namedSystemDefault }
    /// The older per-project default: one id per folder (Claude's if set, else any).
    private var projectDefaults: [String: String] {
        levels.projects.compactMapValues { $0["claude"] ?? $0.sorted { $0.key < $1.key }.first?.value }
    }
    private var systemNames: [String: String] = [:]
    /// 30 Oct (Decker: an assigned seat account only took effect after a restart): the file as last read or written.
    /// Every read first compares the file on disk with this; a change made outside this store (an edit, another
    /// copy of the store) is read in again, so a seat's new account applies to the very next job.
    private var loadedStamp: BackendAccountFileStamp?
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
        let parsed = Self.load(file: file, configuration: configuration)
        raw = parsed.raw; profiles = parsed.profiles; levels = parsed.levels; namedSystemDefault = parsed.namedSystemDefault
        systemNames = parsed.systemNames; backupBeforeWrite = parsed.backupBeforeWrite; loadedStamp = parsed.stamp
        if exclusive { _ = try? Self.cleanEmptyAccountFolders(configuration: configuration) }
    }

    /// What one read of profiles.json gives (getState()): absent is first run and the only case where empty is the
    /// truth. Unreadable or corrupt boots empty — a launch failure is worse than a lost list — but the next write must
    /// not make the loss permanent.
    struct Loaded {
        var raw: NativeRPCValue = .object([])
        var profiles: [BackendAccountProfile] = []
        var levels = BackendAccountLevelsSnapshot()
        var namedSystemDefault: String?
        var systemNames: [String: String] = [:]
        var backupBeforeWrite = false
        var stamp: BackendAccountFileStamp?
    }
    static func load(file: URL, configuration: BackendAccountConfiguration) -> Loaded {
        var out = Loaded()
        out.stamp = BackendAccountFileStamp(file)
        var parsed: NativeRPCValue?
        do {
            if let data = try BackendAccountFiles.boundedRead(file, maximum: 4 * 1024 * 1024) {
                if let value = try? NativeRPCValue.parseJSON(data), value.fields != nil { parsed = value } else { out.backupBeforeWrite = true }
            }
        } catch { out.backupBeforeWrite = true }
        let raw = parsed ?? .object([])
        out.raw = raw
        // A newer version keeps its unknown keys, but what it meant by the keys
        // parsed here is unknowable, so the original stays recoverable.
        if let version = raw["version"].number, version > 1 { out.backupBeforeWrite = true }
        let now = Date().timeIntervalSince1970 * 1000
        var seen = Set<String>()
        for value in raw["profiles"].elements ?? [] {
            // sanitizeProvider: absent means Claude; anything but a supported
            // agent's id drops the row rather than downgrading it.
            let providerValue = value["provider"]
            guard let provider = providerValue.isNullish ? "claude" : providerValue.string,
                  let id = value["id"].string, !id.isEmpty, id != "system", !seen.contains(id),
                  let name = value["name"].string, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let directory = value["configDir"].string, directory.hasPrefix("/"), !directory.contains("\0") else { continue }
            let candidate = BackendAccountProfile(id: id, name: name, provider: provider, configDir: directory, system: false, color: "", createdAt: 0)
            guard BackendAccountStrategies.supportsAccounts(provider) || BackendAPIAccountRecord.isOwnedAPIProfile(candidate, configuration: configuration) else { continue }
            seen.insert(id)
            var slots: [String] = []
            for slot in (value["keptSlots"].elements ?? []).compactMap(\.string) where BackendAccountProfile.validSlot(slot) && !slots.contains(slot) { slots.append(slot) }
            out.profiles.append(BackendAccountProfile(id: id, name: name, provider: provider, configDir: directory, system: false,
                color: value["color"].string ?? BackendAccountProfile.colors[0], createdAt: value["createdAt"].number ?? now,
                lastUsedAt: value["lastUsedAt"].number, loginStore: value["loginStore"].string == "app" ? "app" : nil,
                keptSlots: slots.isEmpty ? nil : slots))
        }
        // provider of a known account id (a system id is "that AI's own login", never stored as a choice).
        let owners = Dictionary(out.profiles.map { ($0.id, $0.provider) }, uniquingKeysWith: { first, _ in first })
        func provider(of id: String) -> String? { owners[id] }
        func choices(_ value: NativeRPCValue) -> [String: String] {
            var found: [String: String] = [:]
            for field in value.fields ?? [] { if let id = field.value.string, provider(of: id) == field.key { found[field.key] = id } }
            return found
        }
        out.levels.app = choices(raw["providerDefaults"])
        for field in raw["projectAccounts"].fields ?? [] where field.key.hasPrefix("/") {
            let found = choices(field.value); if !found.isEmpty { out.levels.projects[projectKey(field.key)] = found }
        }
        for field in raw["seatAccounts"].fields ?? [] where BackendAccountLevel.validSeatKey(field.key) {
            let found = choices(field.value); if !found.isEmpty { out.levels.seats[field.key] = found }
        }
        // The older keys, read once into the levels when the newer ones say nothing for that AI.
        if let id = raw["defaultProfileId"].string {
            if let owner = provider(of: id) { if out.levels.app[owner] == nil { out.levels.app[owner] = id } }
            else if BackendAccountProfile.systemProvider(id) != nil { out.namedSystemDefault = id }
        }
        for field in raw["projectDefaults"].fields ?? [] {
            if let id = field.value.string, let owner = provider(of: id) {
                let key = projectKey(field.key)
                if out.levels.projects[key]?[owner] == nil { out.levels.projects[key, default: [:]][owner] = id }
            }
        }
        for field in raw["systemNames"].fields ?? [] {
            if BackendAccountProfile.systemProvider(field.key) != nil, let name = try? normalizedName(field.value) { out.systemNames[field.key] = name }
        }
        return out
    }
    /// Reads the file in again when it changed on disk since it was last read or written here. A file that vanished
    /// or cannot be read keeps what is in memory (never a silent loss of every choice).
    private func refreshIfChanged() {
        let seen = BackendAccountFileStamp(file)
        guard let current = seen, current != loadedStamp else { return }
        let parsed = Self.load(file: file, configuration: configuration)
        // Unreadable or not an object: keep what is in memory, and back the file up before the next write.
        guard !parsed.backupBeforeWrite || parsed.raw.fields?.isEmpty == false else { loadedStamp = current; backupBeforeWrite = true; return }
        raw = parsed.raw; profiles = parsed.profiles; levels = parsed.levels; namedSystemDefault = parsed.namedSystemDefault
        systemNames = parsed.systemNames; backupBeforeWrite = backupBeforeWrite || parsed.backupBeforeWrite; loadedStamp = parsed.stamp ?? current
    }

    /// `canonicalProjectKey`: `/w/app` and `/w/app/` are one project.
    private static func projectKey(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

    public func snapshot() throws -> BackendAccountProfilesSnapshot {
        refreshIfChanged()
        return BackendAccountProfilesSnapshot(profiles: profiles, defaultProfileID: defaultID, projectDefaults: projectDefaults, systemNames: systemNames, levels: levels)
    }
    private func system(_ provider: String) -> BackendAccountProfile {
        let id = BackendAccountProfile.systemID(provider)
        return BackendAccountProfile(id: id, name: systemNames[id] ?? BackendAccountProfile.generatedSystemName(provider), provider: provider,
            configDir: configuration.systemDirectory(provider), system: true,
            color: BackendAccountProfile.colors[BackendAccountProfile.signInProviders.firstIndex(of: provider) ?? 0], createdAt: 0)
    }
    public func find(_ id: String) throws -> BackendAccountProfile? {
        refreshIfChanged()
        if let provider = BackendAccountProfile.systemProvider(id) { return system(provider) }
        return profiles.first { $0.id == id }
    }
    public func list(provider: String? = nil) throws -> [BackendAccountProfile] {
        refreshIfChanged()
        return (BackendAccountProfile.signInProviders.map(system) + profiles).filter { provider == nil || $0.provider == provider }
    }
    /// The account a session uses (a session that fills no seat). Kept with exactly this shape: other
    /// code reaches the store through it (`BackendHOSTProfileViewReading`).
    public typealias DefaultLoginResolver = @Sendable (BackendAccountProfile, [BackendAccountProfile], [String]) async throws -> BackendAccountProfile
    private var defaultLoginResolver: DefaultLoginResolver?
    public func setDefaultLoginResolver(_ resolver: DefaultLoginResolver?) { defaultLoginResolver = resolver }
    public func resolve(sessionProfileID: String?, projectPath: String?, provider: String?) async throws -> BackendAccountProfile {
        try await resolve(sessionProfileID: sessionProfileID, projectPath: projectPath, provider: provider, seat: nil)
    }
    /// The same for a session that fills a seat (`AGTSeat.key`): the seat's account comes before the project's.
    public func resolve(sessionProfileID: String?, projectPath: String?, provider: String?, seat: String?) async throws -> BackendAccountProfile {
        let login = try effective(sessionProfileID: sessionProfileID, projectPath: projectPath, provider: provider, seat: seat).profile
        guard login.system, login.provider == "claude", let resolver = defaultLoginResolver else { return login }
        let preferred = [sessionProfileID, seat.flatMap { levels.seats[$0]?["claude"] },
                         levels.project(containing: projectPath, provider: "claude")?.id, levels.app["claude"],
                         projectPath.flatMap { raw["lastClaudeAccounts"][Self.projectKey($0)].string }].compactMap { $0 }
        return try await resolver(login, profiles, preferred)
    }
    /// The same answer with where it comes from: this session, its seat, its project, the whole app, or the AI's own login.
    public func effective(sessionProfileID: String?, projectPath: String?, provider: String?, seat: String? = nil) throws -> BackendAccountEffective {
        refreshIfChanged()
        let wanted = provider.flatMap { BackendAccountStrategies.hasSignIn($0) ? $0 : nil } ?? "claude"
        func usable(_ id: String?) throws -> BackendAccountProfile? {
            guard let id else { return nil }
            let found = try find(id)
            if BackendAPIAccountRecord.isAPIAccountID(id) {
                guard let found, provider == nil || found.provider == provider,
                      BackendAPIAccountRecord.isOwnedAPIProfile(found, configuration: configuration) else {
                    throw BackendAccountFailure("The selected API account is unavailable. No other account was used.")
                }
                return found
            }
            guard let found, provider == nil || found.provider == provider else { return nil }
            return found
        }
        if let found = try usable(sessionProfileID) { return .init(profile: found, source: .session, sourceKey: nil) }
        if let seat, let found = try usable(levels.seats[seat]?[wanted]) { return .init(profile: found, source: .seat, sourceKey: seat) }
        if let project = levels.project(containing: projectPath, provider: wanted), let found = try usable(project.id) {
            return .init(profile: found, source: .project, sourceKey: project.path)
        }
        if let found = try usable(levels.app[wanted]) { return .init(profile: found, source: .app, sourceKey: nil) }
        return .init(profile: system(wanted), source: .system, sourceKey: nil)
    }
    /// What is stored at one level for one AI: an account id, or nil for "Same as above".
    public func assigned(_ level: BackendAccountLevel, provider: String) -> String? {
        refreshIfChanged()
        return switch level {
        case .app: levels.app[provider]
        case .project(let path): levels.projects[Self.projectKey(path)]?[provider]
        case .seat(let key): levels.seats[key]?[provider]
        }
    }
    /// Sets one level for one AI. `id` nil (or that AI's own "system" id) means "Same as above".
    public func setLevel(_ level: BackendAccountLevel, provider: String, id: String?) throws {
        refreshIfChanged() // a write starts from what is on disk now, never putting back a choice changed elsewhere
        try writable()
        let selected = try id.flatMap { try find($0) }
        let geminiAPI = provider == "gemini" && (id == nil || id?.isEmpty == true || selected?.system == true
            || selected.map { BackendAPIAccountRecord.isOwnedAPIProfile($0, configuration: configuration) } == true)
        guard BackendAccountStrategies.supportsAccounts(provider) || geminiAPI else { throw BackendAccountFailure(BackendAccountStrategies.unsupportedReason(provider)) }
        var chosen: String?
        if let id, !id.isEmpty, BackendAccountProfile.systemProvider(id) == nil {
            guard let found = try find(id) else { throw BackendAccountFailure("no profile with id \(id)") }
            guard found.provider == provider else { throw BackendAccountFailure("This account belongs to a different agent.") }
            chosen = id
        }
        let before = levels
        switch level {
        case .app: levels.app[provider] = chosen
        case .project(let path):
            let key = Self.projectKey(path)
            levels.projects[key, default: [:]][provider] = chosen
            if levels.projects[key]?.isEmpty == true { levels.projects[key] = nil }
        case .seat(let key):
            guard BackendAccountLevel.validSeatKey(key) else { throw BackendAccountFailure("That role cannot hold an account.") }
            levels.seats[key, default: [:]][provider] = chosen
            if levels.seats[key]?.isEmpty == true { levels.seats[key] = nil }
        }
        do { try persist() } catch { levels = before; throw error }
    }
    public func managed(_ profile: BackendAccountProfile) -> Bool {
        !profile.system && (BackendAccountFiles.descendant(profile.configDir, root: configuration.profilesRoot.path)
            || BackendAccountSignInStorage.ownsFolder(profile, configuration: configuration))
    }
    /// File-only startup repair. It takes no profile writer lease, so a newer app can also call it
    /// before attaching to an older helper. Unknown profile metadata and recent drafts are preserved.
    public nonisolated static func cleanEmptyAccountFolders(configuration: BackendAccountConfiguration,
                                                          now: Date = Date(), minimumAge: TimeInterval = 300) throws -> [String] {
        try BackendAccountEmptyFolders.clean(configuration: configuration, now: now, minimumAge: minimumAge)
    }
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
        // 10 Nov (Asad: "deleted accounts disappear everywhere"): a remembered last account that is no longer an
        // account is not written back (the levels below already keep only existing accounts).
        let existing = Set(profiles.map(\.id))
        var remembered = raw["lastClaudeAccounts"]
        if let fields = remembered.fields { remembered = .object(fields.filter { $0.value.string.map(existing.contains) == true }) }
        var next = raw.setting("version", .number(1)).setting("profiles", .array(encodedProfiles))
        if remembered.fields != nil { next = next.setting("lastClaudeAccounts", remembered) }
        next = next
            .setting("defaultProfileId", defaultID.map(NativeRPCValue.string) ?? .null)
            .setting("projectDefaults", .object(projectDefaults.sorted { $0.key < $1.key }.map { .init($0.key, .string($0.value)) }))
            .setting("providerDefaults", levels.wire["app"]).setting("projectAccounts", levels.wire["projects"]).setting("seatAccounts", levels.wire["seats"])
            .setting("systemNames", .object(systemNames.sorted { $0.key < $1.key }.map { .init($0.key, .string($0.value)) }))
        try BackendAccountFiles.writeAtomic(try next.encodedJSON(pretty: true), to: file)
        raw = next
        loadedStamp = BackendAccountFileStamp(file)
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
    /// 4 Nov (Asad: "it says this account already exists, but if I scroll all the accounts it's not there"): the
    /// sentence names the AI and where the account is. The launch tidy (BackendAccountTidy) makes every email name
    /// match its login, so the account named here is one the list shows.
    private static func nameClash(_ provider: String, _ name: String, adding: Bool = false) -> BackendAccountFailure {
        let label = BackendAccountProfile.providerLabel(provider)
        return BackendAccountFailure("A \(label) account called “\(name)” already exists in Settings › Coding AIs. "
            + (adding ? "Press Sign in again on its row, or choose another name." : "Choose another name."))
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
        refreshIfChanged()
        try writable()
        let name = try Self.normalizedName(name)
        let nameKey = provider + "\0" + name.lowercased()
        guard !creatingNames.contains(nameKey), !(try list(provider: provider)).contains(where: { $0.name.lowercased() == name.lowercased() }) else { throw Self.nameClash(provider, name, adding: true) }
        let id = try BackendAccountProfile.uniqueProfileID(BackendAccountProfile.slugifyProfileID(name), taken: Set(try list().map(\.id)).union(creatingIDs))
        let directory = try configDir.map { try adoptable($0, provider: provider) } ?? configuration.profilesRoot.appendingPathComponent(id).path
        let candidate = BackendAccountProfile(id: id, name: name, provider: provider, configDir: directory, system: false, color: "", createdAt: 0)
        guard BackendAccountStrategies.supportsAccounts(provider) || BackendAPIAccountRecord.isOwnedAPIProfile(candidate, configuration: configuration) else { throw BackendAccountFailure(BackendAccountStrategies.unsupportedReason(provider)) }
        if let owner = creatingDirectories[directory] { throw BackendAccountFailure("\"\(owner)\" already uses that config directory") }
        // A managed directory cannot be protected, but an adopted account may
        // already point inside the profiles root; never share one directory.
        if let clash = profiles.first(where: { URL(fileURLWithPath: $0.configDir).standardizedFileURL.path == directory }) { throw BackendAccountFailure("\"\(clash.name)\" already uses that config directory") }
        guard !isProtected(directory) else { throw BackendAccountFailure("that is your own \(BackendAccountProfile.providerLabel(provider)) install — the default account already uses it, and pointing a second account at it would break the login") }
        creatingIDs.insert(id); creatingNames.insert(nameKey); creatingDirectories[directory] = name
        defer { creatingIDs.remove(id); creatingNames.remove(nameKey); creatingDirectories[directory] = nil }
        let wasPresent = BackendAccountEmptyFolders.existsWithoutFollowing(directory)
        do {
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
        } catch {
            if !wasPresent, !profiles.contains(where: { $0.configDir == directory }) {
                // Never delete an adopted folder or anything the failed attempt wrote into it.
                // The repair only unlinks an app-owned projects link and removes an empty directory.
                _ = try? BackendAccountEmptyFolders.removeDraft(directory, configuration: configuration)
            }
            throw error
        }
    }
    public func rename(id: String, name: String) throws -> BackendAccountProfile {
        refreshIfChanged() // a write starts from what is on disk now, never putting back a choice changed elsewhere
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
        refreshIfChanged() // a write starts from what is on disk now, never putting back a choice changed elsewhere
        guard BackendAccountProfile.validSlot(slot), let index = profiles.firstIndex(where: { $0.id == id }), !(profiles[index].keptSlots ?? []).contains(slot) else { return }
        try writable(); profiles[index].keptSlots = (profiles[index].keptSlots ?? []) + [slot]; try persist()
    }
    public func markUsed(id: String, projectPath: String? = nil) throws {
        refreshIfChanged() // a write starts from what is on disk now, never putting back a choice changed elsewhere
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        try writable()
        let previous = raw
        if profiles[index].provider == "claude", let projectPath, projectPath.hasPrefix("/") {
            let remembered = raw["lastClaudeAccounts"].fields == nil ? NativeRPCValue.object([]) : raw["lastClaudeAccounts"]
            raw = raw.setting("lastClaudeAccounts", remembered.setting(Self.projectKey(projectPath), .string(id)))
        }
        profiles[index].lastUsedAt = Date().timeIntervalSince1970 * 1000
        do { try persist() } catch { raw = previous; throw error }
    }
    /// `setGlobalDefault(id)` when `projectPath` is nil, else `setProjectDefault(projectPath, id)`.
    public func setDefault(_ id: String?, projectPath: String? = nil) throws {
        refreshIfChanged() // a write starts from what is on disk now, never putting back a choice changed elsewhere
        try writable()
        if let projectPath, projectPath.isEmpty { throw BackendAccountFailure("a project path is required") }
        let found = try id.flatMap { try find($0) }
        if id != nil, found == nil { throw BackendAccountFailure("no profile with id \(id ?? "")") }
        let before = levels
        // The older calls name only an account: it is stored for that account's own AI. Clearing clears Claude's
        // choice for the whole app, and every AI's choice for a project (what "no default" meant before).
        let owner = found?.provider ?? "claude"
        let chosen = found.flatMap { $0.system ? nil : $0.id }
        if let projectPath {
            let key = Self.projectKey(projectPath)
            if found == nil { levels.projects[key] = nil }
            else { levels.projects[key, default: [:]][owner] = chosen; if levels.projects[key]?.isEmpty == true { levels.projects[key] = nil } }
        } else {
            levels.app[owner] = chosen
            // "system" has always meant "no default"; another AI's own login is remembered as named.
            namedSystemDefault = found.flatMap { $0.system && $0.id != "system" ? $0.id : nil }
        }
        do { try persist() } catch { levels = before; throw error }
    }
    public func removeMetadata(id: String) throws -> BackendAccountProfile {
        refreshIfChanged() // a write starts from what is on disk now, never putting back a choice changed elsewhere
        try writable()
        if let provider = BackendAccountProfile.systemProvider(id) {
            throw BackendAccountFailure("the default account is your own \(BackendAccountProfile.providerLabel(provider)) install and cannot be deleted")
        }
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw BackendAccountFailure("no profile with id \(id)") }
        let previousProfiles = profiles, previousLevels = levels
        let profile = profiles.remove(at: index)
        // A removed account is no longer anyone's choice: those levels go back to "Same as above".
        levels.app = levels.app.filter { $0.value != id }
        levels.projects = levels.projects.compactMapValues { let kept = $0.filter { $0.value != id }; return kept.isEmpty ? nil : kept }
        levels.seats = levels.seats.compactMapValues { let kept = $0.filter { $0.value != id }; return kept.isEmpty ? nil : kept }
        do { try persist() }
        catch { profiles = previousProfiles; levels = previousLevels; throw error }
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

/// Which version of a file was read: its change time, size and file number. A rename-over write (writeAtomic) or an
/// edit changes at least one of them.
struct BackendAccountFileStamp: Equatable, Sendable {
    let modified: Double, size: Int64, inode: UInt64
    init?(_ file: URL) {
        guard let info = try? FileManager.default.attributesOfItem(atPath: file.path) else { return nil }
        modified = (info[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        size = (info[.size] as? NSNumber)?.int64Value ?? -1
        inode = (info[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }
}
