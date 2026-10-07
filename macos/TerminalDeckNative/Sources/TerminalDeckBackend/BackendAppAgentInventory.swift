import Foundation
import Darwin
import TerminalDeckNativeCore

/// tasks/agent-inventory.ts. Discovery reads configuration and skill headers;
/// it never starts an agent, MCP server, plugin or external process.
public struct BackendAppAgentInventory: Sendable {
    public static let appServerName = "deck-control"
    public static let maximumListed = 300
    /// The source calls this HEAD_BYTES, but slices decoded UTF-16 units.
    public static let headUnits = 4096
    public struct Choice: Equatable, Sendable {
        public let value: String, label: String, `where`: String
        public init(value: String, label: String, where location: String) { self.value = value; self.label = label; self.where = location }
        public var wire: NativeRPCValue { .object([.init("value", .string(value)), .init("label", .string(label)), .init("where", .string(self.where))]) }
    }
    public struct Inventory: Equatable, Sendable {
        public let tools: [Choice], skills: [Choice]
        public init(tools: [Choice], skills: [Choice]) { self.tools = tools; self.skills = skills }
        public var wire: NativeRPCValue { .object([.init("tools", .array(tools.map(\.wire))), .init("skills", .array(skills.map(\.wire)))]) }
    }
    public struct Input: Sendable {
        public let provider: String?, configDirectory: String, system: Bool, projects: [String]
        public let environment: [String: String]
        public let home: String?
        public init(provider: String? = nil, configDirectory: String, system: Bool, projects: [String],
                    environment: [String: String] = ProcessInfo.processInfo.environment, home: String? = nil) {
            self.provider = provider; self.configDirectory = configDirectory; self.system = system
            self.projects = projects; self.environment = environment; self.home = home
        }
    }
    public typealias LoadServers = @Sendable (String?, [String: String]) throws -> [NativeRPCValue]
    private let systemHome: String
    private let loadServers: LoadServers
    public init(systemHome: String = NSHomeDirectory(), loadServers: LoadServers? = nil) {
        self.systemHome = systemHome
        self.loadServers = loadServers ?? { project, environment in
            let absolute = project.flatMap { $0.hasPrefix("/") && !$0.isEmpty ? URL(fileURLWithPath: $0).standardizedFileURL.path : nil }
            return BackendMcpClientConfiguration(home: systemHome, environment: environment).load(project: absolute)
        }
    }
    public func read(_ input: Input) -> Inventory {
        let family = BackendSharedAgentCapabilities.familyOf(input.provider)
        if family == .codex { return codex(input) }
        guard family == .claude else { return Inventory(tools: [], skills: []) }
        var environment = input.environment
        environment["CLAUDE_CONFIG_DIR"] = input.system ? nil : input.configDirectory
        var tools = BackendSharedAgentTools.claude.map { Choice(value: $0.name, label: $0.name + " — " + $0.label, where: "Claude Code") }
        var seen = Set(tools.map(\.value))
        func addTool(_ value: String, _ label: String, _ location: String) {
            guard tools.count < Self.maximumListed, seen.insert(value).inserted else { return }
            tools.append(Choice(value: value, label: label, where: location))
        }
        if let name = BackendSharedAgentTools.mcpServerTool(Self.appServerName) { addTool(name, Self.appServerName + " — Terminal Deck's own tools", "this app") }
        for project in [String?.none] + input.projects.map(Optional.some) {
            guard let servers = try? loadServers(project, environment) else { continue }
            for server in servers {
                guard let name = server["name"].string, let value = BackendSharedAgentTools.mcpServerTool(name) else { continue }
                addTool(value, name + " — every tool of this MCP server", "MCP, " + (server["scope"].string ?? ""))
            }
        }
        var skills: [Choice] = [], named = Set<String>()
        func addSkills(_ path: String, _ location: String, _ prefix: String = "") {
            for found in Self.skills(in: path) {
                let value = prefix + found.name
                guard skills.count < Self.maximumListed, named.insert(value).inserted else { continue }
                skills.append(Choice(value: value, label: found.description.map { value + " — " + $0 } ?? value, where: location))
            }
        }
        addSkills(Self.join(input.configDirectory, "skills"), "account")
        for project in input.projects { addSkills(Self.join(project, ".claude/skills"), "project") }
        for plugin in Self.plugins(in: input.configDirectory) { addSkills(Self.join(plugin.path, "skills"), "plugin " + plugin.name, plugin.name + ":") }
        return Inventory(tools: tools, skills: skills)
    }
    private func codex(_ input: Input) -> Inventory {
        var tools: [Choice] = [], seen = Set<String>()
        for name in Self.codexServers(file: Self.join(input.configDirectory, "config.toml")) {
            guard let value = BackendSharedAgentTools.mcpServerTool(name), tools.count < Self.maximumListed, seen.insert(value).inserted else { continue }
            tools.append(Choice(value: value, label: name + " — every tool of this MCP server", where: "Codex config"))
        }
        var skills: [Choice] = [], named = Set<String>()
        func add(_ path: String, _ location: String) {
            for found in Self.skills(in: path) {
                guard skills.count < Self.maximumListed, named.insert(found.name).inserted else { continue }
                skills.append(Choice(value: found.name, label: found.description.map { found.name + " — " + $0 } ?? found.name, where: location))
            }
        }
        add(Self.join(input.configDirectory, "skills"), "account")
        add(Self.join(input.home ?? systemHome, ".agents/skills"), "home")
        for project in input.projects { add(Self.join(project, ".agents/skills"), "project") }
        add(Self.join(input.configDirectory, "skills/.system"), "built in")
        return Inventory(tools: tools, skills: skills)
    }
    public static func frontMatter(_ head: String, key: String) throws -> String? {
        let block = try NSRegularExpression(pattern: #"^---\r?\n([\s\S]*?)\r?\n---"#)
        guard let match = block.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)), let bodyRange = Range(match.range(at: 1), in: head) else { return nil }
        let body = String(head[bodyRange])
        // Explicit line boundaries and dot class retain JavaScript's line
        // terminators (ICU also treats U+0085 as a line boundary).
        let pattern = BackendSharedText.javascriptPattern(#"(?:^|(?<=[\r\n\u2028\u2029]))"# + key + #":\s*([^\r\n\u2028\u2029]+)(?=$|[\r\n\u2028\u2029])"#)
        let line = try NSRegularExpression(pattern: pattern)
        guard let found = line.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)), let range = Range(found.range(at: 1), in: body) else { return nil }
        var value = BackendSharedText.trim(String(body[range]))
        if value.hasPrefix("\"") || value.hasPrefix("'") { value.removeFirst() }
        if value.hasSuffix("\"") || value.hasSuffix("'") { value.removeLast() }
        return value.isEmpty ? nil : value
    }
    public static func shortened(_ text: String, maximum: Int = 60) -> String {
        guard text.utf16.count > maximum else { return text }
        var units = Array(text.utf16.prefix(maximum))
        if let space = units.lastIndex(of: 32), space > maximum / 2 { units = Array(units.prefix(space)) }
        let cut = String(decoding: units, as: UTF16.self)
        return cut.replacingOccurrences(of: BackendSharedText.javascriptPattern(#"[\s,.;:]+$"#), with: "", options: .regularExpression) + "…"
    }
    public static func codexServers(file: String) -> [String] {
        guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: file)) else { return [] }
        let text = String(decoding: bytes, as: UTF8.self)
        let pattern = BackendSharedText.javascriptPattern(#"(?:^|(?<=[\r\n\u2028\u2029]))\s*\[mcp_servers\.(?:"([^"]+)"|([A-Za-z0-9_-]+))\]\s*(?=$|[\r\n\u2028\u2029])"#)
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var names: [String] = [], seen = Set<String>()
        for found in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(found.range(at: found.range(at: 1).location == NSNotFound ? 2 : 1), in: text) else { continue }
            let name = String(text[range]); if seen.insert(name).inserted { names.append(name) }
        }
        return names
    }
    private struct Skill { let name: String; let description: String? }
    private static func skills(in directory: String) -> [Skill] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        var found: [Skill] = []
        for entry in entries.sorted(by: { $0.utf16.lexicographicallyPrecedes($1.utf16) }) {
            let file = join(directory, entry + "/SKILL.md")
            guard FileManager.default.fileExists(atPath: file) else { continue }
            let head = readHead(file)
            let name = (try? frontMatter(head, key: "name")) ?? entry
            guard BackendSharedText.matches(name, #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$"#) else { continue }
            let description = try? frontMatter(head, key: "description")
            found.append(Skill(name: name, description: description.map { shortened($0) }))
        }
        return found
    }
    private static func plugins(in config: String) -> [(name: String, path: String)] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: join(config, "plugins/installed_plugins.json"))),
              let raw = try? NativeRPCValue.parseJSON(Data(String(decoding: data, as: UTF8.self).utf8)) else { return [] }
        // JS Object.entries also accepts an array for the source typeof-object
        // check. Only its first install is considered for each plugin id.
        let entries = raw["plugins"].fields ?? raw["plugins"].elements?.enumerated().map { NativeRPCValue.Field(String($0.offset), $0.element) } ?? []
        return entries.compactMap { entry in
            let name = entry.key.components(separatedBy: "@").first ?? ""
            guard !name.isEmpty, let path = entry.value.elements?.first?["installPath"].string else { return nil }
            return (name, path)
        }
    }
    private static func readHead(_ file: String) -> String {
        let descriptor = Darwin.open(file, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return "" }; defer { Darwin.close(descriptor) }
        var info = stat(); guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return "" }
        // This many UTF-8 bytes always includes the source's first 4096 UTF-16
        // units, plus any split codepoint. No whole skill body is allocated.
        var bytes = [UInt8](repeating: 0, count: headUnits * 4 + 4), used = 0
        let capacity = bytes.count
        while used < capacity {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!.advanced(by: used), capacity - used) }
            if count < 0 { if errno == EINTR { continue }; return "" }
            if count == 0 { break }; used += count
        }
        return BackendSharedText.prefix(String(decoding: bytes.prefix(used), as: UTF8.self), headUnits)
    }
    private static func join(_ root: String, _ path: String) -> String { (root as NSString).appendingPathComponent(path) }
}

/// Concrete supplier for BackendTaskChannelDependencies.inventory. It matches
/// deck-control/index.ts's callback: requested account id/name, provider default,
/// newest 40 saved projects, plus the resolved account label. UI input cannot
/// provide a config directory, home or arbitrary project folder.
public struct BackendAppAgentInventoryTaskAdapter: Sendable {
    private let reader: BackendAppAgentInventory, profiles: BackendAccountProfileStore, store: NativeStateStore
    private let environment: [String: String]
    public init(reader: BackendAppAgentInventory, profiles: BackendAccountProfileStore, store: NativeStateStore, environment: [String: String]) {
        self.reader = reader; self.profiles = profiles; self.store = store; self.environment = environment
    }
    public func inventory(_ raw: NativeRPCValue) async throws -> NativeRPCValue {
        func text(_ value: NativeRPCValue) -> String? { value.string.flatMap { let clean = BackendSharedText.trim($0); return clean.isEmpty ? nil : clean } }
        let requested = text(raw["provider"]), provider = requested == "codex" ? "codex" : "claude", wanted = (text(raw["account"]) ?? "").lowercased()
        let accounts = try await profiles.list(provider: provider)
        let chosen = wanted.isEmpty ? nil : accounts.first { $0.id.lowercased() == wanted || $0.name.lowercased() == wanted }
        let profile: BackendAccountProfile
        if let chosen { profile = chosen }
        else { profile = try await profiles.resolve(sessionProfileID: nil, projectPath: nil, provider: provider) }
        let projects = await store.getProjects().prefix(40).compactMap { $0["path"].string }
        let value = reader.read(.init(provider: requested, configDirectory: profile.configDir, system: profile.system, projects: projects, environment: environment))
        return value.wire.setting("account", .string(profile.name))
    }
    public var callback: @Sendable (NativeRPCValue) async throws -> NativeRPCValue { { raw in try await self.inventory(raw) } }
}
