import Foundation
import TerminalDeckNativeCore

// TRUTH-B (12 Oct, SETTINGS-TRUTH.md): the MCP page's On switch, per-tool, per-AI and per-agent switches called four
// channels nobody answered (mcp:policy, mcp:enabled, mcp:tools:set, mcp:access:set), so every one failed or stayed
// grey, and so did Hoot's mcp_switch. They are answered now, and what they say is applied to every session Terminal
// Deck starts, never by editing an AI's own config file:
//  - Claude Code: a server that is off (for this AI or this agent) and every tool that is off are refused with
//    --disallowedTools (or, under agent settings, left out of its one --strict-mcp-config file).
//  - Codex and Gemini: the servers on the MCP page (Claude Code's list) now reach them too, as per-launch overrides
//    (Codex `-c mcp_servers.<name>.*`, secrets in a private launch file only that server reads; Gemini a private
//    settings file of the launch), minus the ones that are off, with the tools that are off left out.
// One small file in the app's data folder holds the choices: mcp-policy.json.

public struct BackendMcpPolicyEntry: Codable, Equatable, Sendable {
    public var off: Bool = false
    public var toolsOff: [String] = []
    public var clientsOff: [String] = []
    public var agentsOff: [String] = []
    public init() {}
    var isEmpty: Bool { !off && toolsOff.isEmpty && clientsOff.isEmpty && agentsOff.isEmpty }
    /// Is the server on for this AI (and this agent, when the session is an agent's)?
    public func on(client: String, agentID: String?) -> Bool {
        !off && !clientsOff.contains(client) && !(agentID.map(agentsOff.contains) ?? false)
    }
}

public struct BackendMcpPolicyDocument: Codable, Equatable, Sendable {
    public var revision: Int = 0
    public var servers: [String: BackendMcpPolicyEntry] = [:]
    public init() {}
}

public enum BackendMcpPolicy {
    public static let fileName = "mcp-policy.json"
    public static let clients = ["claude", "codex", "gemini"]
    private static let lock = NSLock()
    nonisolated(unsafe) private static var configured: URL?

    /// The app and the session helper both call this with the one data folder they share.
    public static func configure(dataDirectory: URL) {
        lock.withLock { configured = dataDirectory.appendingPathComponent(fileName) }
    }
    public static var file: URL? { lock.withLock { configured } }

    /// Owner-only folder for a launch's private Gemini file when no other private folder is at hand.
    public static func launchDirectory() -> URL? {
        guard let folder = file?.deletingLastPathComponent().appendingPathComponent("mcp-launch", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Old launch files go once a day: each is read only when its session starts.
        let old = Date().addingTimeInterval(-86_400)
        for item in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where ((try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()) < old {
            try? FileManager.default.removeItem(at: item)
        }
        return folder
    }

    /// Agent settings (Claude Code): the page's choices folded into the agent's own server switches and blocked tools.
    public static func applyToAgentSettings(_ settings: inout AGSAgentSettings, accountServers: Set<String>, agentID: String?,
                                            document: BackendMcpPolicyDocument = load()) {
        guard settings.provider == "claude" else { return }
        for name in accountServers.sorted() where valid(name) {
            guard let entry = document.servers[name] else { continue }
            if !entry.on(client: "claude", agentID: agentID) { settings.mcpServers[name] = false; continue }
            for tool in entry.toolsOff where valid(tool) && !settings.deniedTools.contains("mcp__" + name + "__" + tool) {
                settings.deniedTools.append("mcp__" + name + "__" + tool)
            }
        }
    }

    /// The server's name from a page id ("user:github", "project:github") or a bare name (Hoot's tool).
    public static func name(_ serverID: String) -> String {
        guard let colon = serverID.firstIndex(of: ":"), ["user", "project", "local"].contains(String(serverID[..<colon])) else { return serverID }
        return String(serverID[serverID.index(after: colon)...])
    }

    public static func load(_ file: URL? = BackendMcpPolicy.file) -> BackendMcpPolicyDocument {
        guard let file, let data = try? Data(contentsOf: file), data.count <= 1_048_576,
              let document = try? JSONDecoder().decode(BackendMcpPolicyDocument.self, from: data) else { return .init() }
        return document
    }

    public enum Failure: Error, Equatable { case stale(Int), unconfigured, unwritable(String) }

    /// One change, refused when the screen read an older revision (somebody else changed it in between).
    @discardableResult
    public static func change(_ server: String, expected revision: Int?, file: URL? = BackendMcpPolicy.file,
                              _ edit: (inout BackendMcpPolicyEntry) -> Void) throws -> Int {
        guard let file else { throw Failure.unconfigured }
        return try lock.withLock {
            var document = load(file)
            if let revision, revision != document.revision { throw Failure.stale(document.revision) }
            var entry = document.servers[server] ?? .init()
            edit(&entry)
            entry.toolsOff = Array(Set(entry.toolsOff)).sorted(); entry.clientsOff = Array(Set(entry.clientsOff)).sorted()
            entry.agentsOff = Array(Set(entry.agentsOff)).sorted()
            document.servers[server] = entry.isEmpty ? nil : entry
            document.revision += 1
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(document).write(to: file, options: .atomic)
            } catch { throw Failure.unwritable(error.localizedDescription) }
            return document.revision
        }
    }

    static func toggled(_ list: inout [String], _ item: String, off: Bool) {
        if off { if !list.contains(item) { list.append(item) } } else { list.removeAll { $0 == item } }
    }

    // MARK: Launch

    /// Claude Code: the server groups and single tools to refuse for this session.
    public static func claudeDenied(_ document: BackendMcpPolicyDocument, agentID: String?) -> [String] {
        var denied: [String] = []
        for (name, entry) in document.servers.sorted(by: { $0.key < $1.key }) where valid(name) {
            if !entry.on(client: "claude", agentID: agentID) { denied.append("mcp__" + name); continue }
            denied += entry.toolsOff.filter(valid).map { "mcp__" + name + "__" + $0 }
        }
        return denied
    }

    /// Bare names only: Codex takes quotes as part of a name, and these become rule and flag names.
    public static func valid(_ name: String) -> Bool { name.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil }

    /// What starts a server whose secrets sit in a private file: `/bin/sh` reads the file (`$0`), then runs the server
    /// (`$@`) in its place. The values reach that server alone, never Codex's own environment.
    static let secretsLoader = #". "$0" && exec "$@""#

    /// One stdio server's variables as an owner-only file the loader reads. Nil when there is no private folder, a
    /// name could not be exported, or the file could not be written: the server is then left out, never handed its
    /// secrets some other way.
    static func secretsFile(_ server: String, _ env: [(String, String)], in directory: URL?) -> URL? {
        guard let directory, env.allSatisfy({ $0.0.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil }) else { return nil }
        let text = env.map { "export " + $0.0 + "='" + $0.1.replacingOccurrences(of: "'", with: "'\\''") + "'\n" }.joined()
        let file = directory.appendingPathComponent("codex-mcp-" + server + "-" + UUID().uuidString.prefix(8) + ".env")
        return (try? BackendPrivateLaunchFiles.write(Data(text.utf8), to: file)) == nil ? nil : file
    }

    /// Codex: the MCP page's servers this session should have (on for Codex and this agent), plus `enabled=false`
    /// for servers of Codex's own config.toml that are off. Servers Codex already has itself are left alone.
    /// A server's secrets go in a private file under `privateDirectory`, read only as that server starts: never on
    /// Codex's command line, and never in the session's environment, where the AI's commands and every process
    /// they start could read them.
    public static func codex(_ document: BackendMcpPolicyDocument, pageServers: [NativeRPCValue], codexOwn: Set<String>,
                             agentID: String?, privateDirectory: URL? = nil) -> Launch {
        var result = Launch()
        func add(_ key: String, _ value: String) { result.arguments += ["-c", key + "=" + value] }
        for name in codexOwn.sorted() where valid(name) {
            guard let entry = document.servers[name] else { continue }
            let prefix = "mcp_servers." + name
            if !entry.on(client: "codex", agentID: agentID) { add(prefix + ".enabled", "false") }
            else if !entry.toolsOff.isEmpty { add(prefix + ".disabled_tools", toml(entry.toolsOff)) }
        }
        for server in pageServers {
            guard let name = server["name"].string, valid(name), !codexOwn.contains(name), server["enabled"].bool != false else { continue }
            let entry = document.servers[name] ?? .init()
            guard entry.on(client: "codex", agentID: agentID) else { continue }
            let prefix = "mcp_servers." + name
            if server["transport"].string == "stdio", var command = server["command"].string {
                var args = (server["args"].elements ?? []).compactMap(\.string)
                let env = (server["env"].fields ?? []).compactMap { field in field.value.string.map { (field.key, $0) } }
                if !env.isEmpty {
                    guard let file = secretsFile(name, env, in: privateDirectory) else { continue }
                    args = ["-c", secretsLoader, file.path, command] + args; command = "/bin/sh"
                    result.readableFiles.append(file.path)
                }
                add(prefix + ".command", BackendNativeInstructions.tomlString(command))
                if !args.isEmpty { add(prefix + ".args", toml(args)) }
                if let cwd = server["cwd"].string { add(prefix + ".cwd", BackendNativeInstructions.tomlString(cwd)) }
            } else if server["transport"].string == "http", let url = server["url"].string {
                add(prefix + ".url", BackendNativeInstructions.tomlString(url))
            } else { continue }
            if !entry.toolsOff.isEmpty { add(prefix + ".disabled_tools", toml(entry.toolsOff)) }
        }
        return result
    }

    /// Gemini: the MCP page's servers in Gemini's own form (private launch file), with the tools that are off excluded.
    public static func gemini(_ document: BackendMcpPolicyDocument, pageServers: [NativeRPCValue], agentID: String?) -> [NativeRPCValue.Field] {
        pageServers.compactMap { server in
            guard let name = server["name"].string, valid(name), server["enabled"].bool != false else { return nil }
            let entry = document.servers[name] ?? .init()
            guard entry.on(client: "gemini", agentID: agentID) else { return nil }
            var fields: [NativeRPCValue.Field] = []
            if server["transport"].string == "stdio", let command = server["command"].string {
                fields.append(.init("command", .string(command)))
                fields.append(.init("args", server["args"].isNullish ? .array([]) : server["args"]))
                if let cwd = server["cwd"].string { fields.append(.init("cwd", .string(cwd))) }
                if !(server["env"].fields ?? []).isEmpty { fields.append(.init("env", server["env"])) }
            } else if server["transport"].string == "http", let url = server["url"].string {
                fields.append(.init("httpUrl", .string(url)))
            } else if server["transport"].string == "sse", let url = server["url"].string {
                fields.append(.init("url", .string(url)))
            } else { return nil }
            if !entry.toolsOff.isEmpty { fields.append(.init("excludeTools", .array(entry.toolsOff.map(NativeRPCValue.string)))) }
            return .init(name, .object(fields))
        }
    }

    /// Gemini servers that are off: named in `mcp.excluded` of the launch's private settings.
    public static func geminiExcluded(_ document: BackendMcpPolicyDocument, agentID: String?) -> [String] {
        document.servers.filter { valid($0.key) && !$0.value.on(client: "gemini", agentID: agentID) }.map(\.key).sorted()
    }

    static func toml(_ values: [String]) -> String { "[" + values.map(BackendNativeInstructions.tomlString).joined(separator: ",") + "]" }

    /// What one launch adds for its AI. `geminiDefaults`: the private defaults file this launch already names, if any.
    /// Hoot's own name on the MCP page's per-agent switches.
    public static let hootAgentID = "hoot"
    /// FINAL-HOOT: the MCP page's servers Hoot gets on this AI, the same choice every other session gets: on, on for this
    /// AI and on for Hoot. Never one that has the name of Hoot's own lease.
    public static func hootServers(provider: String, cwd: String, home: String = NSHomeDirectory(),
                                   environment: [String: String] = ProcessInfo.processInfo.environment,
                                   document: BackendMcpPolicyDocument = load(), reserved: Set<String> = ["deck-control"]) -> [HootServer] {
        let page = BackendMcpClientConfiguration(home: home, environment: environment).load(project: cwd.hasPrefix("/") ? cwd : nil)
        return page.compactMap { server in
            guard let name = server["name"].string, valid(name), !reserved.contains(name), server["enabled"].bool != false else { return nil }
            let entry = document.servers[name] ?? .init()
            guard entry.on(client: provider, agentID: hootAgentID) else { return nil }
            return .init(name: name, server: server, toolsOff: entry.toolsOff)
        }
    }
    public struct HootServer: Sendable, Equatable { public var name: String; public var server: NativeRPCValue; public var toolsOff: [String]
        public init(name: String, server: NativeRPCValue, toolsOff: [String]) { self.name = name; self.server = server; self.toolsOff = toolsOff } }

    public struct Launch: Equatable, Sendable {
        public var arguments: [String] = [], environment: [String: String] = [:], readableFiles: [String] = []
    }
    public static func launch(provider: String, cwd: String, agentID: String?, agentSettings: Bool, home: String,
                              inherited: [String: String], environment current: [String: String], privateDirectory: URL?,
                              document: BackendMcpPolicyDocument = load()) -> Launch {
        var result = Launch()
        switch provider {
        case "claude":
            // Under agent settings the server list is written whole (--strict-mcp-config) and filtered there.
            guard !agentSettings else { return result }
            let denied = claudeDenied(document, agentID: agentID)
            if !denied.isEmpty { result.arguments = ["--disallowedTools", denied.joined(separator: ",")] }
        case "codex":
            let page = BackendMcpClientConfiguration(home: home, environment: inherited).load(project: cwd.hasPrefix("/") ? cwd : nil)
            let codexHome = inherited["CODEX_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? home + "/.codex"
            let own = Set(BackendAppAgentInventory.codexServers(file: codexHome + "/config.toml"))
            result = codex(document, pageServers: page, codexOwn: own, agentID: agentID, privateDirectory: privateDirectory)
        case "gemini":
            let page = BackendMcpClientConfiguration(home: home, environment: inherited).load(project: cwd.hasPrefix("/") ? cwd : nil)
            let servers = gemini(document, pageServers: page, agentID: agentID), excluded = geminiExcluded(document, agentID: agentID)
            guard !servers.isEmpty || !excluded.isEmpty, let directory = privateDirectory else { return result }
            // On top of the defaults file this launch already names (Terminal Deck's own tools), else the machine's own.
            let key = "GEMINI_CLI_SYSTEM_DEFAULTS_PATH"
            let base = current[key].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath:
                (inherited["GEMINI_CLI_SYSTEM_SETTINGS_PATH"] ?? "/Library/Application Support/GeminiCli/settings.json")).deletingLastPathComponent().appendingPathComponent("system-defaults.json")
            var object = NativeRPCValue.object([])
            if FileManager.default.fileExists(atPath: base.path) {
                guard let bytes = try? BackendAccountFiles.boundedRead(base, maximum: 2 * 1024 * 1024),
                      let parsed = try? NativeRPCValue.parseJSON(bytes), parsed.fields != nil else { return result }
                object = parsed
            }
            var mcpServers = object["mcpServers"].fields == nil ? NativeRPCValue.object([]) : object["mcpServers"]
            for field in servers where mcpServers[field.key].isNullish { mcpServers = mcpServers.setting(field.key, field.value) }
            object = object.setting("mcpServers", mcpServers)
            if !excluded.isEmpty {
                let mcp = object["mcp"].fields == nil ? NativeRPCValue.object([]) : object["mcp"]
                let already = (mcp["excluded"].elements ?? []).compactMap(\.string)
                object = object.setting("mcp", mcp.setting("excluded", .array(Array(Set(already + excluded)).sorted().map(NativeRPCValue.string))))
            }
            let file = directory.appendingPathComponent("gemini-mcp-page-" + UUID().uuidString.prefix(8) + ".json")
            guard (try? BackendPrivateLaunchFiles.write(try object.encodedJSON(pretty: true), to: file)) != nil else { return result }
            result.environment = [key: file.path]; result.readableFiles = [file.path]
        default: break
        }
        return result
    }
}
