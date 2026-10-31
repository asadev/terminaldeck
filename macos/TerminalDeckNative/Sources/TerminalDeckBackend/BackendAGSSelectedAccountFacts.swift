import Foundation
import CryptoKit
import TerminalDeckNativeCore

#if TD_HOST_ACCOUNT_BRIDGE
public typealias BackendHOSTAGSSelectedAccountFactsProfiles = any BackendHOSTProfileViewReading
#else
public typealias BackendHOSTAGSSelectedAccountFactsProfiles = BackendAccountProfileStore
#endif

/// Private, selected-account launch facts. This never has a wire representation.
/// The production constructor probes the resolved binary with the account's
/// real environment and keeps all CLI inventory output private. No credential is exported.
public struct BackendAGSSelectedAccountFacts: Sendable {
    public struct Snapshot: Sendable {
        public let provider: BackendProviderSpec, account: BackendAccountProfile
        public let loginID: String
        public let environment: [String: String], installedHelp: String
        public let servers: NativeRPCValue, geminiSystemSettings: NativeRPCValue?
        public let fingerprints: [String: String]
        /// Codex only: the servers its config FILES define (`[mcp_servers.<name>]` in ~/.codex/config.toml and the
        /// project layers). A server in `codex mcp list` that is not here comes from a Codex plugin; an
        /// `mcp_servers.<name>.…` override for it makes Codex refuse to start ("invalid transport", real-app T11).
        public var binaryFingerprint: String = ""
        public var codexConfigured: Set<String>? = nil
        public var serverNames: Set<String> { Set(servers.fields?.map(\.key) ?? []) }
    }
    /// The server names a Codex config.toml defines, read from its section headers only (`[mcp_servers.name]`,
    /// `[mcp_servers."name"]`, `[mcp_servers.name.env]`); values are never parsed here.
    public static func codexConfiguredServers(_ toml: String) -> Set<String> {
        var names = Set<String>()
        for line in toml.components(separatedBy: .newlines) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("["), !text.hasPrefix("[["), let range = text.range(of: #"^\[\s*mcp_servers\.(?:"([^"]+)"|([A-Za-z0-9_-]+))"#, options: .regularExpression) else { continue }
            let head = String(text[range]).replacingOccurrences(of: #"^\[\s*mcp_servers\."#, with: "", options: .regularExpression)
            names.insert(head.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        }
        return names
    }
    private let helpCache = BackendAGSHelpCache()
    private let providers: any BackendProviderLaunchResolver
    private let profiles: BackendHOSTAGSSelectedAccountFactsProfiles
    private let configuration: BackendAccountConfiguration
    private let projectRoot: @Sendable (String) async throws -> String
    private let command: any BackendAppSessionCommandExecuting
    private let profileContext: (@Sendable () async throws -> NativeRPCContext)?
    public init(providers: any BackendProviderLaunchResolver, profiles: BackendHOSTAGSSelectedAccountFactsProfiles,
                configuration: BackendAccountConfiguration, projectRoot: @escaping @Sendable (String) async throws -> String, command: (any BackendAppSessionCommandExecuting)? = nil, profileContext: (@Sendable () async throws -> NativeRPCContext)? = nil) {
        self.providers = providers; self.profiles = profiles; self.configuration = configuration; self.projectRoot = projectRoot; self.command = command ?? BackendAppSessionCommandExecutor(); self.profileContext = profileContext
    }
    public func capture(_ input: BackendCreateSessionInput, context: BackendLaunchContext) async throws -> Snapshot {
        try await capture(input, context: context, previous: nil)
    }
    private func capture(_ input: BackendCreateSessionInput, context: BackendLaunchContext, previous: Snapshot?) async throws -> Snapshot {
        #if TD_HOST_ACCOUNT_BRIDGE
        if let profileContext {
            let rpc = try await profileContext()
            return try await BackendHOSTProfileScope.withContext(rpc) { try await captureScoped(input, context: context, previous: previous) }
        }
        #endif
        return try await captureScoped(input, context: context, previous: previous)
    }
    private func captureScoped(_ input: BackendCreateSessionInput, context: BackendLaunchContext, previous: Snapshot?) async throws -> Snapshot {
        guard context.deviceBoundary == nil, context.appFenceID == nil else { throw Self.unavailable("Private agent settings require this Mac's selected-account launch path.") }
        let path = try await providers.loginPath(), provider = try await providers.resolve(input, loginPath: path)
        let login = try await BackendDefaultClaudeLogin.$environmentOverrides.withValue(context.environmentOverrides) {
            try await profiles.resolve(sessionProfileID: input.profileId, projectPath: input.cwd, provider: provider.id)
        }
        guard login.provider == provider.id else { throw Self.unavailable("The selected account belongs to a different coding agent.") }
        var home = login
        if provider.id == "claude", let id = input.homeProfileId, id != login.id {
            guard let candidate = try await profiles.find(id), candidate.provider == provider.id else { throw Self.unavailable("The selected account home is unavailable.") }
            home = candidate
        }
        let apiHome = BackendAPIAccountRecord.isOwnedAPIProfile(home, configuration: configuration)
        if apiHome, try BackendAPIAccountRecord.read(home) == nil { throw Self.unavailable("This API account's settings are incomplete. No other account was used.") }
        var environment = BackendSessionEnvironment.stripInherited(configuration.inheritedEnvironment)
        environment["PATH"] = path; environment["HOME"] = configuration.homeDirectory.path
        if !home.system { environment.merge(BackendAccountStrategies.accountEnv(provider: provider.id, account: (home.provider, home.configDir))) { _, next in next } }
        // Explicit selected-account config routes are pinned even for a system install.
        if !home.system, let key = BackendAccountProfile.configEnvironment(provider.id), (["claude", "codex"].contains(provider.id) || apiHome) { environment[key] = home.configDir }
        if let key = BackendAccountProfile.configEnvironment(provider.id), let override = context.environmentOverrides[key], URL(fileURLWithPath: override).standardizedFileURL.path != URL(fileURLWithPath: home.configDir).standardizedFileURL.path {
            throw Self.unavailable("Launch composition redirects the selected account. Agent settings were not applied to another account home.")
        }
        guard home.system || BackendAccountStrategies.supportsAccounts(provider.id) || apiHome else { throw Self.unavailable("This CLI has no measured route for that selected account home.") }
        let binary = try Self.binaryFingerprint(provider.command)
        if let previous, previous.binaryFingerprint != binary {
            throw Self.unavailable("The selected CLI changed during launch. Start again.")
        }
        let command = self.command, launchEnvironment = environment
        let help: String
        if let previous { help = previous.installedHelp }
        else {
            help = try await helpCache.read(key: binary + "\nhelp") {
                await command.run(provider.command, arguments: ["--help"], environment: launchEnvironment, cwd: input.cwd, timeoutMilliseconds: 8_000, maximumBytes: 256 * 1024)
            }
        }
        let root = try await projectRoot(input.cwd)
        guard root.hasPrefix("/"), (NativeTranscriptPaths.canonical(input.cwd) == NativeTranscriptPaths.canonical(root) || NativeTranscriptPaths.isDescendant(NativeTranscriptPaths.canonical(input.cwd), of: NativeTranscriptPaths.canonical(root))) else { throw Self.unavailable("The trusted project root does not contain this launch folder.") }
        var fingerprints: [String: String] = [:], servers: NativeRPCValue = .object([]), system: NativeRPCValue?, configured = Set<String>()
        switch provider.id {
        case "claude":
            let locations = BackendMcpClientConfiguration(home: configuration.homeDirectory.path, environment: environment)
            let settings = try Self.readJSON(locations.claudeSettingsDirectory + "/settings.json", fingerprints: &fingerprints)
            let global = try Self.readJSON(locations.claudeJSONPath, fingerprints: &fingerprints)
            // 29 Oct (keeper restart 00:52: a chat was refused "changed during launch" and stayed down): Claude Code
            // rewrites its .claude.json at every start (counters, tips, last session, usage), so a sibling session
            // starting beside this one changed the whole-file digest. Only what this launch uses is compared: the
            // MCP servers it can load for this project and their on/off lists.
            if fingerprints[locations.claudeJSONPath] != "missing" {
                fingerprints[locations.claudeJSONPath] = Self.claudeLaunchDigest(global, projectRoot: root)
            }
            let projectFile = root + "/.mcp.json"
            let project = try Self.readJSON(projectFile, fingerprints: &fingerprints)
            var mergedSettings = settings
            var directories: [String] = [], cursor = URL(fileURLWithPath: NativeTranscriptPaths.canonical(input.cwd))
            let canonicalRoot = NativeTranscriptPaths.canonical(root)
            while true {
                directories.append(cursor.path); guard directories.count <= 64 else { throw Self.unavailable("There are too many inherited project settings layers.") }; if cursor.path == canonicalRoot { break }
                let parent = cursor.deletingLastPathComponent(); guard parent.path != cursor.path else { throw Self.unavailable("The project settings path escaped its trusted root.") }; cursor = parent
            }
            for directory in directories.reversed() {
                mergedSettings = Self.merge(mergedSettings, try Self.readJSON(directory + "/.claude/settings.json", fingerprints: &fingerprints))
                mergedSettings = Self.merge(mergedSettings, try Self.readJSON(directory + "/.claude/settings.local.json", fingerprints: &fingerprints))
            }
            // The existing collector preserves account/project/local precedence and project approvals.
                        let rows = BackendMcpClientConfiguration.collect(claude: global, settings: mergedSettings, projectJSON: project,
                projectPath: root, claudePath: locations.claudeJSONPath, projectFile: projectFile, environment: environment)
            let rawMaps: [String: NativeRPCValue] = ["user": global["mcpServers"], "project": project["mcpServers"], "local": global["projects"][URL(fileURLWithPath: root).standardizedFileURL.path]["mcpServers"]]
            for map in rawMaps.values where !map.isNullish {
                guard let fields = map.fields, fields.allSatisfy({ $0.value.fields != nil && ($0.value["command"].string != nil || $0.value["url"].string != nil) }) else { throw Self.unavailable("A selected-account MCP record is malformed; the inventory is incomplete.") }
            }
            servers = .object(try rows.map { row in
                guard let name = row["name"].string, let scope = row["scope"].string,
                      let map = rawMaps[scope], map[name].fields != nil, Self.validName(name) else { throw Self.unavailable("The selected-account MCP inventory lost its original configuration.") }
                return .init(name, map[name].setting("enabled", .bool(row["enabled"].bool == true)))
            })
        case "codex":
            // Codex's own config loader aggregates configured/plugin servers. No hand-written TOML parser.
            if let previous { servers = previous.servers }
            else {
                let listHelp = try await helpCache.read(key: binary + "\nmcp-list-help") {
                    await command.run(provider.command, arguments: ["mcp", "list", "--help"], environment: launchEnvironment, cwd: input.cwd, timeoutMilliseconds: 8_000, maximumBytes: 64 * 1024)
                }
                guard listHelp.contains("--json") else { throw Self.unavailable("The installed Codex cannot export its complete MCP configuration.") }
                let exported = await command.run(provider.command, arguments: ["mcp", "list", "--json"], environment: environment, cwd: input.cwd, timeoutMilliseconds: 15_000, maximumBytes: 2 * 1024 * 1024)
                guard exported.ok else { throw Self.unavailable("The selected Codex account's MCP configuration could not be exported.") }
                servers = try Self.codexServers(try NativeRPCValue.parseJSON(Data(exported.stdout.utf8), maximumBytes: 2 * 1024 * 1024))
            }
            fingerprints["codex:export"] = Self.digest(try servers.encodedJSON())
            let configFile = URL(fileURLWithPath: home.configDir).appendingPathComponent("config.toml").path
            if let bytes = try BackendAccountFiles.boundedRead(URL(fileURLWithPath: configFile), maximum: 4 * 1024 * 1024) {
                fingerprints[configFile] = Self.digest(bytes); configured.formUnion(Self.codexConfiguredServers(String(decoding: bytes, as: UTF8.self)))
            } else { fingerprints[configFile] = "missing" }
            var cursor = URL(fileURLWithPath: NativeTranscriptPaths.canonical(input.cwd)), count = 0
            while true {
                let file = cursor.appendingPathComponent(".codex/config.toml").path
                if let bytes = try BackendAccountFiles.boundedRead(URL(fileURLWithPath: file), maximum: 4 * 1024 * 1024) {
                    fingerprints[file] = Self.digest(bytes); configured.formUnion(Self.codexConfiguredServers(String(decoding: bytes, as: UTF8.self)))
                } else { fingerprints[file] = "missing" }
                count += 1; guard count <= 64 else { throw Self.unavailable("There are too many inherited Codex config layers.") }
                if cursor.path == NativeTranscriptPaths.canonical(root) { break }; cursor.deleteLastPathComponent()
            }
        case "gemini":
            let settingsRoot = environment["GEMINI_CLI_HOME"] ?? configuration.inheritedEnvironment["GEMINI_CLI_HOME"] ?? configuration.homeDirectory.path
            let systemPath = configuration.inheritedEnvironment["GEMINI_CLI_SYSTEM_SETTINGS_PATH"] ?? "/Library/Application Support/GeminiCli/settings.json"
            let defaultsPath = configuration.inheritedEnvironment["GEMINI_CLI_SYSTEM_DEFAULTS_PATH"] ?? "/Library/Application Support/GeminiCli/system-defaults.json"
            let systemSettings = try Self.readJSON(systemPath, fingerprints: &fingerprints)
            system = systemSettings
            var merged = try Self.readJSON(defaultsPath, fingerprints: &fingerprints)
            merged = Self.merge(merged, try Self.readJSON(settingsRoot + "/.gemini/settings.json", fingerprints: &fingerprints))
            let project = try Self.readJSON(root + "/.gemini/settings.json", fingerprints: &fingerprints)
            guard project["mcpServers"].isNullish || project["mcpServers"].fields?.isEmpty == true else { throw Self.unavailable("Gemini project MCP servers require measured workspace trust before copying them into a private system layer.") }
            merged = Self.merge(merged, project)
            merged = Self.merge(merged, systemSettings)
            // Unknown extension activation cannot be treated as an empty inventory.
            // Preserve the launch's original policy; a future extension supplier can provide a measured aggregate.
            let extensions = URL(fileURLWithPath: settingsRoot).appendingPathComponent(".gemini/extensions")
            let directories = (try? FileManager.default.contentsOfDirectory(at: extensions, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            guard directories.isEmpty else { throw Self.unavailable("Gemini extensions need a verified active MCP inventory before private agent settings can be applied.") }
            servers = merged["mcpServers"].isNullish ? .object([]) : merged["mcpServers"]
            guard servers.fields != nil else { throw Self.unavailable("The selected Gemini MCP configuration is invalid.") }
        default: throw Self.unavailable("That coding agent has no verified private-settings adapter.")
        }
        guard let fields = servers.fields, fields.count <= 200,
              fields.allSatisfy({ Self.validName($0.key) && $0.value.fields != nil }) else { throw Self.unavailable("The complete MCP inventory contains an unsupported server record.") }
        return Snapshot(provider: provider, account: home, loginID: login.id, environment: environment, installedHelp: help,
                        servers: servers, geminiSystemSettings: system, fingerprints: fingerprints,
                        binaryFingerprint: binary, codexConfigured: provider.id == "codex" ? configured : nil)
    }
    public func recheck(_ snapshot: Snapshot, input: BackendCreateSessionInput, context: BackendLaunchContext) async throws {
        let current = try await capture(input, context: context, previous: snapshot)
        guard current.provider.command == snapshot.provider.command, current.account.id == snapshot.account.id,
              current.account.configDir == snapshot.account.configDir, current.loginID == snapshot.loginID, current.installedHelp == snapshot.installedHelp,
              current.servers == snapshot.servers, current.fingerprints == snapshot.fingerprints else {
            throw Self.unavailable("The selected account or its CLI/MCP configuration changed during launch. Start again.")
        }
    }
    static func binaryFingerprint(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let modified = attributes[.modificationDate] as? Date else { throw unavailable("The installed CLI could not be identified.") }
        return "\(url.path)\n\(modified.timeIntervalSince1970)\n\(attributes[.size] ?? 0)\n\(attributes[.systemFileNumber] ?? 0)"
    }
    static func codexServers(_ raw: NativeRPCValue) throws -> NativeRPCValue {
        guard let rows = raw.elements, rows.count <= 200 else { throw unavailable("Codex did not return a complete structured MCP inventory.") }
        var fields: [NativeRPCValue.Field] = [], names = Set<String>()
        for row in rows {
            guard let name = row["name"].string, validName(name), names.insert(name).inserted,
                  row["enabled"].bool != nil, row["transport"].fields != nil else { throw unavailable("A Codex MCP inventory record is incomplete.") }
            fields.append(.init(name, canonical(row["disabled_reason"].string == nil ? row.removing("auth_status") : row.setting("enabled", .bool(false)).removing("auth_status"))))
        }
        return .object(fields.sorted { $0.key < $1.key })
    }
    /// L8 (11 Oct, real-app T11: a Codex agent never started, "changed during launch", twice): `codex mcp list
    /// --json` prints a server's `env` map in a different key order on every run (seen on his config: the same
    /// nine variables, reordered), so the launch's second look never matched its first. Objects are compared
    /// with their keys in one fixed order; array order (arguments) still counts.
    static func canonical(_ value: NativeRPCValue) -> NativeRPCValue {
        if let fields = value.fields { return .object(fields.map { .init($0.key, canonical($0.value)) }.sorted { $0.key < $1.key }) }
        if let elements = value.elements { return .array(elements.map(canonical)) }
        return value
    }
    static func claudeServers(_ rows: [NativeRPCValue]) throws -> NativeRPCValue {
        var fields: [NativeRPCValue.Field] = []
        for row in rows {
            guard let name = row["name"].string, validName(name) else { throw unavailable("A selected-account Claude MCP server name is invalid.") }
            guard row["enabled"].bool == true else { continue }
            var raw = row.removing("id").removing("name").removing("scope").removing("source").removing("enabled").removing("disabledReason").removing("unsupported")
            raw = raw.setting("type", row["transport"]).removing("transport")
            fields.append(.init(name, raw))
        }
        return .object(fields)
    }
    /// The part of Claude Code's .claude.json a launch depends on (BackendMcpClientConfiguration.collect reads only
    /// these): the account's MCP servers and this project's servers and approvals. Everything else it rewrites freely.
    static func claudeLaunchDigest(_ global: NativeRPCValue, projectRoot: String) -> String {
        let local = global["projects"][URL(fileURLWithPath: projectRoot).standardizedFileURL.path]
        let used = NativeRPCValue.object([.init("mcpServers", global["mcpServers"]),
            .init("project", .object(["mcpServers", "enabledMcpjsonServers", "disabledMcpjsonServers", "enableAllProjectMcpServers"].map { .init($0, local[$0]) }))])
        return "launch:" + digest((try? used.encodedJSON()) ?? Data())
    }
    static func readJSON(_ path: String, fingerprints: inout [String: String]) throws -> NativeRPCValue {
        do {
            guard let bytes = try BackendAccountFiles.boundedRead(URL(fileURLWithPath: path), maximum: 4 * 1024 * 1024) else { fingerprints[path] = "missing"; return .object([]) }
            fingerprints[path] = digest(bytes)
            let parsed = try NativeRPCValue.parseJSON(bytes, maximumBytes: 4 * 1024 * 1024)
            guard parsed.fields != nil else { throw unavailable("An account's MCP/settings file is not an object.") }; return parsed
        } catch { throw unavailable("A selected-account MCP/settings file is unreadable or malformed. No configuration was treated as empty.") }
    }
    static func merge(_ a: NativeRPCValue, _ b: NativeRPCValue) -> NativeRPCValue {
        guard let fields = b.fields else { return b }
        var result = a.fields == nil ? NativeRPCValue.object([]) : a
        for field in fields {
            result = result.setting(field.key, result[field.key].fields != nil && field.value.fields != nil ? merge(result[field.key], field.value) : field.value)
        }; return result
    }
    static func validName(_ text: String) -> Bool { text.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func unavailable(_ message: String) -> NativeRPCError { .init(code: "unavailable", message: message) }
}

/// Share help across launches and coalesce simultaneous probes. A changed binary gets a new key.
private actor BackendAGSHelpCache {
    private var entries: [String: Task<String, Error>] = [:]
    func read(key: String, probe: @escaping @Sendable () async -> BackendAppSessionCommandResult) async throws -> String {
        if let entry = entries[key] { return try await entry.value }
        let entry = Task {
            let result = await probe()
            guard result.ok, !result.stdout.isEmpty else {
                throw BackendAGSSelectedAccountFacts.unavailable("The installed CLI help could not be read.")
            }
            return result.stdout
        }
        if entries.count > 32 { entries.removeAll() }
        entries[key] = entry
        do { return try await entry.value }
        catch { entries[key] = nil; throw error }
    }
}
