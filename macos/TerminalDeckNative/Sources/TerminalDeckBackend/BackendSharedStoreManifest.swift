import Foundation
import TerminalDeckNativeCore

public struct BackendSharedManifestRefusal: Error, LocalizedError, Equatable, Sendable {
    public let why: String
    public init(_ why: String) { self.why = why }
    public var errorDescription: String? { why }
}

/// The closed grammar from shared/store-manifest.ts, also usable by the local
/// plugin parser. NativeRPCValue retains missing/null and source key order.
public enum BackendSharedManifestGrammar {
    public static let safeID = #"^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$"#
    public static let version = #"^\d+\.\d+\.\d+$"#
    public static func fail(_ why: String) throws -> Never { throw BackendSharedManifestRefusal(why) }
    public static func isRecord(_ value: NativeRPCValue) -> Bool { value.fields != nil }
    public static func onlyKeys(_ whereName: String, _ value: NativeRPCValue, _ allowed: [String]) throws {
        for key in (value.fields ?? []).map(\.key) where !allowed.contains(key) { try fail("\(whereName) has a key this app does not know about: \(key)") }
    }
    public static func text(_ whereName: String, _ value: NativeRPCValue, _ max: Int) throws -> String {
        guard let raw = value.string else { try fail("\(whereName) must be text") }
        let text = BackendSharedText.trim(raw)
        if text.isEmpty { try fail("\(whereName) must not be empty") }
        if text.utf16.count > max { try fail("\(whereName) must be \(max) characters or fewer") }
        if text.contains("\r") || text.contains("\n") { try fail("\(whereName) must be a single line") }
        return text
    }
    public static func oneOf(_ whereName: String, _ value: NativeRPCValue, _ allowed: [String]) throws -> String {
        guard let text = value.string, allowed.contains(text) else { try fail("\(whereName) must be one of: \(allowed.joined(separator: ", "))") }
        return text
    }
    public static func list(_ whereName: String, _ value: NativeRPCValue, _ max: Int) throws -> [NativeRPCValue] {
        guard let list = value.elements else { try fail("\(whereName) must be a list") }
        if list.count > max { try fail("\(whereName) may hold at most \(max) entries") }
        return list
    }
    public static func insidePath(_ whereName: String, _ value: NativeRPCValue, allowDot: Bool) throws -> String {
        let raw = try text(whereName, value, 200)
        if allowDot && raw == "." { return "." }
        if raw.hasPrefix("/") { try fail("\(whereName) must be a path inside the item, so it cannot start with /") }
        if BackendSharedText.matches(raw, #"^[A-Za-z]:"#) { try fail("\(whereName) must be a path inside the item, so it cannot name a drive") }
        if raw.contains("\\") { try fail("\(whereName) must use / between folders") }
        if raw.contains("\0") { try fail("\(whereName) contains a character a file name cannot have") }
        let parts = raw.components(separatedBy: "/")
        if parts.contains("..") { try fail("\(whereName) must not step outside the item with ..") }
        if parts.contains("") { try fail("\(whereName) has an empty folder name in it") }
        return raw
    }
    public static func isRefusal(_ error: Error) -> Bool { error is BackendSharedManifestRefusal }
}

public enum BackendSharedStoreManifest {
    public static let maxManifestBytes = 64 * 1024
    public static let manifestFile = "terminaldeck.json"
    public static let format = 1
    public static let kinds = ["skill", "instructions", "hooks", "mcp", "extension", "routine", "tool"]
    public static let kindNames = ["skill": "Skill", "instructions": "Instructions", "hooks": "Hooks", "mcp": "MCP server", "extension": "Browser extension", "routine": "Routine", "tool": "Open-source tool"]
    public static let kindOneLine = ["skill": "A folder of instructions an agent reads when it needs them.", "instructions": "One file of standing instructions, added to what an agent already reads.", "hooks": "A script your agent runs at named moments in a session.", "mcp": "A server that gives an agent new tools.", "extension": "An extension for the browser inside this app.", "routine": "A saved job you can schedule or start by hand.", "tool": "A program you install yourself. This lists it and links to it."]
    public static let kindHasArtifact = ["skill": true, "instructions": true, "hooks": true, "mcp": false, "extension": true, "routine": true, "tool": false]
    public static let tierWords = [1: "Text only — nothing runs", 2: "Ships scripts the agent may run", 3: "Runs a program on this machine"]
    public static let kindTierFloor = ["skill": 1, "instructions": 1, "hooks": 3, "mcp": 3, "extension": 2, "routine": 2, "tool": 1]
    public static let deliveries = ["repo", "off-site"]
    public static let costs = ["free", "account", "metered", "paid"]
    public static let needs = ["runs-scripts", "node", "python", "api-key", "account", "local-app"]
    public static let needWords = ["runs-scripts": "Runs scripts on this machine", "node": "Needs Node.js", "python": "Needs Python", "api-key": "Needs a key you supply", "account": "Needs an account somewhere", "local-app": "Needs another app installed"]
    public static let agents = ["claude", "codex", "gemini"]
    public static let hookEvents = [
        "claude": ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "Notification", "Stop", "StopFailure", "SessionEnd"],
        "codex": ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"],
        "gemini": ["SessionStart", "BeforeAgent", "BeforeTool", "AfterTool", "AfterAgent", "Notification", "SessionEnd"],
    ]
    public static let platforms = ["darwin", "win32", "linux"]
    public static let mcpRuntimes = ["node", "python"]
    public static let runtimeCommand = ["node": "npx", "python": "uvx"]
    public static let categories = ["files", "code", "work", "data", "cloud", "web", "browser", "knowledge", "design", "business", "thinking", "messaging", "utility"]
    public static let licences = ["0BSD", "AGPL-3.0-only", "AGPL-3.0-or-later", "Apache-2.0", "Artistic-2.0", "BSD-2-Clause", "BSD-3-Clause", "BSL-1.0", "CC0-1.0", "CC-BY-4.0", "CC-BY-SA-4.0", "EPL-2.0", "GPL-2.0-only", "GPL-3.0-only", "GPL-3.0-or-later", "ISC", "LGPL-2.1-only", "LGPL-3.0-only", "MIT", "MPL-2.0", "Unlicense", "Zlib"]
    public static let repoHosts = ["github.com", "gitlab.com", "codeberg.org"]
    public static let tagPattern = #"^[a-z0-9][a-z0-9-]{0,23}$"#
    private static let envPattern = #"^[A-Z][A-Z0-9_]{0,63}$"#
    private static let packagePattern = #"^(?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]{0,127}(?:@[A-Za-z0-9._-]{1,64})?$"#
    private static let argumentLiteral = #"^[A-Za-z0-9._:/@=-]{1,120}$"#
    private static let argumentPlaceholder = #"^\$\{input:([A-Z][A-Z0-9_]{0,63})\}$"#
    private static let hostReach = #"^(?:\*\.)?[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$"#
    public struct TierFile: Equatable, Sendable {
        public let path: String; public let bytes: Int; public let mode: Int
        public init(path: String, bytes: Int, mode: Int) { self.path = path; self.bytes = bytes; self.mode = mode }
    }
    public struct Tier: Equatable, Sendable { public let tier: Int; public let because: String }
    public enum Parse: Equatable, Sendable {
        case accepted(NativeRPCValue), refused(String)
        public var value: NativeRPCValue? { if case .accepted(let value) = self { return value }; return nil }
        public var why: String? { if case .refused(let why) = self { return why }; return nil }
    }
    public static func deriveTier(kind: String, files: [TierFile]) -> Tier {
        if kind == "hooks" || kind == "mcp" { return .init(tier: 3, because: kind == "mcp" ? "an MCP server is a program your agent starts and talks to" : "a hook is a script your agent runs at named moments") }
        if kind == "extension" { return .init(tier: 2, because: "a browser extension runs inside the browser pane") }
        if kind == "routine" { return .init(tier: 2, because: "a routine drives an agent session on a schedule") }
        if kind == "instructions" || kind == "tool" { return .init(tier: 1, because: kind == "tool" ? "nothing is installed from here" : "it is one text file") }
        let suffixes = [".sh", ".bash", ".zsh", ".fish", ".ps1", ".bat", ".cmd", ".py", ".rb", ".pl", ".js", ".mjs", ".cjs", ".ts", ".tsx"]
        for file in files {
            if suffixes.contains(where: { file.path.lowercased().hasSuffix($0) }) { return .init(tier: 2, because: "it ships \(file.path)") }
            if file.mode & 0o111 != 0 { return .init(tier: 2, because: "\(file.path) is marked runnable") }
        }
        return .init(tier: 1, because: "every file in it is text")
    }
    private static func object(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(fields.map { .init($0.0, $0.1) }) }
    private static func words(_ values: [String]) -> NativeRPCValue { .array(values.map(NativeRPCValue.string)) }
    private static func nullable(_ text: String?) -> NativeRPCValue { text.map(NativeRPCValue.string) ?? .null }
    private static func optionalText(_ name: String, _ value: NativeRPCValue, _ max: Int) throws -> String? {
        value.isNullish ? nil : try BackendSharedManifestGrammar.text(name, value, max)
    }
    private static func httpsUrl(_ name: String, _ value: NativeRPCValue, hosts: [String]? = nil) throws -> String {
        let raw = try BackendSharedManifestGrammar.text(name, value, 300)
        guard let url = URLComponents(string: raw), let scheme = url.scheme, url.url != nil else { try BackendSharedManifestGrammar.fail("\(name) is not a web address") }
        if scheme.lowercased() != "https" { try BackendSharedManifestGrammar.fail("\(name) must be an https address") }
        guard let host = url.host?.lowercased(), !host.isEmpty else { try BackendSharedManifestGrammar.fail("\(name) is not a web address") }
        if BackendSharedText.matches(host, #"^\d{1,3}(?:\.\d{1,3}){3}$"#) || host.hasPrefix("[") || host.contains(":") {
            try BackendSharedManifestGrammar.fail("\(name) must name a domain, not a bare address")
        }
        if let hosts, !hosts.contains(host) { try BackendSharedManifestGrammar.fail("\(name) must be on one of: \(hosts.joined(separator: ", "))") }
        return raw
    }
    private static func placeholder(_ value: String) -> String? {
        guard BackendSharedText.matches(value, argumentPlaceholder) else { return nil }
        return String(value.dropFirst("${input:".count).dropLast())
    }
    public static func composeMcpCommand(_ install: NativeRPCValue) -> String {
        let head = install["runtime"].string == "node" ? "npx -y" : "uvx"
        let args = (install["args"].elements ?? []).compactMap(\.string).map { arg in placeholder(arg).map { "${\($0)}" } ?? arg }
        return BackendSharedText.trim(([head, install["package"].string ?? ""] + args).joined(separator: " "))
    }
    private static func mcpInput(_ name: String, _ raw: NativeRPCValue) throws -> NativeRPCValue {
        let g = BackendSharedManifestGrammar.self
        if !g.isRecord(raw) { try g.fail("\(name) must be an object") }
        try g.onlyKeys(name, raw, ["key", "label", "hint", "kind", "into", "required"])
        let key = try g.text("\(name).key", raw["key"], 64)
        if !BackendSharedText.matches(key, envPattern) { try g.fail("\(name).key must be capitals, digits and underscores, starting with a letter") }
        guard let required = raw["required"].bool else { try g.fail("\(name).required must be true or false") }
        return try object([
            ("key", .string(key)), ("label", .string(g.text("\(name).label", raw["label"], 60))),
            ("hint", .string(g.text("\(name).hint", raw["hint"], 200))), ("kind", .string(g.oneOf("\(name).kind", raw["kind"], ["secret", "path", "text"]))),
            ("into", .string(g.oneOf("\(name).into", raw["into"], ["env", "arg"]))), ("required", .bool(required)),
        ])
    }
    private static func install(kind: String, raw: NativeRPCValue, agents: [String]) throws -> NativeRPCValue {
        let g = BackendSharedManifestGrammar.self
        if !g.isRecord(raw) { try g.fail("install must be an object") }
        if kind == "tool" { try g.fail("a tool installs nothing, so it cannot carry an install block") }
        if kind == "skill" {
            try g.onlyKeys("install", raw, ["dir"])
            return try object([("kind", .string(kind)), ("dir", .string(g.insidePath("install.dir", raw["dir"], allowDot: true)))])
        }
        if kind == "instructions" || kind == "routine" {
            try g.onlyKeys("install", raw, ["file"])
            let file = try g.insidePath("install.file", raw["file"], allowDot: false)
            if !file.lowercased().hasSuffix(".md") { try g.fail("install.file must be a .md file") }
            return object([("kind", .string(kind)), ("file", .string(file))])
        }
        if kind == "hooks" {
            try g.onlyKeys("install", raw, ["script", "events", "runtime"])
            let script = try g.insidePath("install.script", raw["script"], allowDot: false)
            let runtime = try g.oneOf("install.runtime", raw["runtime"], ["node"])
            let entries = try g.list("install.events", raw["events"], 20)
            if entries.isEmpty { try g.fail("install.events must name at least one moment to run at") }
            var events: [String] = []
            for (index, entry) in entries.enumerated() {
                let event = try g.text("install.events[\(index)]", entry, 40)
                for agent in agents where !(hookEvents[agent] ?? []).contains(event) { try g.fail("\(agent) has no hook called \(event), and this item says it works with \(agent)") }
                if !events.contains(event) { events.append(event) }
            }
            return object([("kind", .string(kind)), ("script", .string(script)), ("events", words(events)), ("runtime", .string(runtime))])
        }
        if kind == "extension" {
            try g.onlyKeys("install", raw, ["dir", "reach"])
            let dir = try g.insidePath("install.dir", raw["dir"], allowDot: true)
            var reach: [String] = []
            for (index, entry) in try g.list("install.reach", raw["reach"], 40).enumerated() {
                let host = try g.text("install.reach[\(index)]", entry, 120).lowercased()
                if host != "*" && !BackendSharedText.matches(host, hostReach) { try g.fail("install.reach[\(index)] is not a host or \"*\"") }
                if !reach.contains(host) { reach.append(host) }
            }
            return object([("kind", .string(kind)), ("dir", .string(dir)), ("reach", words(reach))])
        }
        try g.onlyKeys("install", raw, ["runtime", "package", "args", "inputs", "token"])
        if raw["runtime"].string == "docker" { try g.fail("this item asks to be run with docker, which the community store does not compose. A docker line carries its own mounts, network and environment, and this app builds every command itself. It may use: node, python") }
        let runtime = try g.oneOf("install.runtime", raw["runtime"], mcpRuntimes)
        let package = try g.text("install.package", raw["package"], 140)
        if !BackendSharedText.matches(package, packagePattern) { try g.fail("install.package must be a package name, not a path or an address") }
        let inputs = try g.list("install.inputs", raw["inputs"], 12).enumerated().map { try mcpInput("install.inputs[\($0.offset)]", $0.element) }
        var keys = Set<String>()
        for input in inputs {
            let key = input["key"].string!
            if !keys.insert(key).inserted { try g.fail("install.inputs names \(key) twice") }
        }
        var args: [String] = []
        for (index, entry) in try g.list("install.args", raw["args"], 20).enumerated() {
            let arg = try g.text("install.args[\(index)]", entry, 120)
            if let key = placeholder(arg) {
                guard let input = inputs.first(where: { $0["key"].string == key }) else { try g.fail("install.args[\(index)] uses ${input:\(key)}, which is not declared") }
                if input["into"].string != "arg" { try g.fail("\(key) is filled in as an environment variable, so it cannot be an argument") }
            } else if !BackendSharedText.matches(arg, argumentLiteral) { try g.fail("install.args[\(index)] may only be a plain word or ${input:KEY}") }
            args.append(arg)
        }
        let token = try g.text("install.token", raw["token"], 140)
        let block = object([("kind", .string(kind)), ("runtime", .string(runtime)), ("package", .string(package)), ("args", words(args)), ("inputs", .array(inputs)), ("token", .string(token))])
        if !composeMcpCommand(block).contains(token) { try g.fail("install.token must appear in the command this app builds, and \(token) does not") }
        return block
    }
    public static func readInstallBlock(kind: String, value: NativeRPCValue, agents: [String]) -> Parse {
        do { return .accepted(try install(kind: kind, raw: value, agents: agents)) }
        catch let refusal as BackendSharedManifestRefusal { return .refused(refusal.why) }
        catch { return .refused("this install block could not be read") }
    }
    private static func stringValue(_ value: NativeRPCValue) -> String {
        if value == .missing { return "undefined" }; if value == .null { return "null" }
        if let text = value.string { return text }; if let number = value.number { return BackendSharedText.jsNumber(number) }
        if let bool = value.bool { return bool ? "true" : "false" }
        if let array = value.elements { return array.map { $0.isNullish ? "" : stringValue($0) }.joined(separator: ",") }
        return "[object Object]"
    }
    public static func parse(_ bytes: String, expectedPublisher: String, expectedID: String) -> Parse {
        do {
            let g = BackendSharedManifestGrammar.self
            if bytes.utf8.count > maxManifestBytes { try g.fail("a manifest must be \(maxManifestBytes) bytes or fewer") }
            guard let raw = try? NativeRPCValue.parseJSON(Data(bytes.utf8), maximumBytes: maxManifestBytes) else { try g.fail("this is not valid JSON") }
            if !g.isRecord(raw) { try g.fail("a manifest must be a JSON object") }
            try g.onlyKeys("the manifest", raw, ["terminaldeck", "publisher", "id", "kind", "name", "summary", "version", "licence", "category", "tags", "agents", "platforms", "delivery", "pricing", "licenceEnv", "aiFile", "links", "needs", "install"])
            if raw["terminaldeck"] != .number(Double(format)) { try g.fail("this manifest is written for format \(stringValue(raw["terminaldeck"])), and this app reads format \(format)") }
            let publisher = try g.text("publisher", raw["publisher"], 40)
            if !BackendSharedText.matches(publisher, g.safeID) { try g.fail("publisher must be lower-case letters, digits and hyphens") }
            if publisher != expectedPublisher { try g.fail("this manifest says it belongs to \(publisher), and it was offered as \(expectedPublisher)") }
            let id = try g.text("id", raw["id"], 40)
            if !BackendSharedText.matches(id, g.safeID) { try g.fail("id must be lower-case letters, digits and hyphens") }
            if id != expectedID { try g.fail("this manifest calls itself \(id), and it was offered as \(expectedID)") }
            let kind = try g.oneOf("kind", raw["kind"], kinds)
            let name = try g.text("name", raw["name"], 60), summary = try g.text("summary", raw["summary"], 120)
            let version = try g.text("version", raw["version"], 20)
            if !BackendSharedText.matches(version, g.version) { try g.fail("version must look like 1.2.3") }
            let licence = try g.oneOf("licence", raw["licence"], licences), category = try g.oneOf("category", raw["category"], categories)
            var tags: [String] = []
            for (index, entry) in try g.list("tags", raw["tags"], 12).enumerated() {
                let tag = try g.text("tags[\(index)]", entry, 24)
                if !BackendSharedText.matches(tag, tagPattern) { try g.fail("tags[\(index)] must be lower-case letters, digits and hyphens") }
                if !tags.contains(tag) { tags.append(tag) }
            }
            var selectedAgents: [String] = []
            for (index, entry) in try g.list("agents", raw["agents"], agents.count).enumerated() {
                let agent = try g.oneOf("agents[\(index)]", entry, agents)
                if !selectedAgents.contains(agent) { selectedAgents.append(agent) }
            }
            if selectedAgents.isEmpty { try g.fail("agents must name at least one agent this was tested with") }
            var selectedPlatforms: [String] = []
            for (index, entry) in try g.list("platforms", raw["platforms"], platforms.count).enumerated() {
                let platform = try g.oneOf("platforms[\(index)]", entry, platforms)
                if !selectedPlatforms.contains(platform) { selectedPlatforms.append(platform) }
            }
            if selectedPlatforms.isEmpty { try g.fail("platforms must name at least one system this runs on") }
            let delivery = try g.oneOf("delivery", raw["delivery"], deliveries)
            let pricing = raw["pricing"]
            if !g.isRecord(pricing) { try g.fail("pricing must be an object") }
            try g.onlyKeys("pricing", pricing, ["model", "note", "url"])
            let model = try g.oneOf("pricing.model", pricing["model"], costs)
            let note = try optionalText("pricing.note", pricing["note"], 160)
            if model != "free" && note == nil { try g.fail("pricing.note is required for anything that is not free, in one sentence, before the button") }
            let url = pricing["url"].isNullish ? nil : try httpsUrl("pricing.url", pricing["url"])
            let licenceEnv = try optionalText("licenceEnv", raw["licenceEnv"], 64)
            if let licenceEnv, !BackendSharedText.matches(licenceEnv, envPattern) { try g.fail("licenceEnv must be an environment variable name, in capitals") }
            let aiFile = raw["aiFile"].isNullish ? nil : try g.insidePath("aiFile", raw["aiFile"], allowDot: false)
            if let aiFile, !aiFile.lowercased().hasSuffix(".txt") && !aiFile.lowercased().hasSuffix(".md") { try g.fail("aiFile must be a .txt or a .md file") }
            let links = raw["links"]
            if !g.isRecord(links) { try g.fail("links must be an object") }
            try g.onlyKeys("links", links, ["repo", "home", "docs"])
            let repo = try httpsUrl("links.repo", links["repo"], hosts: repoHosts)
            let home = links["home"].isNullish ? nil : try httpsUrl("links.home", links["home"])
            let docs = links["docs"].isNullish ? nil : try httpsUrl("links.docs", links["docs"])
            var selectedNeeds: [String] = []
            for (index, entry) in try g.list("needs", raw["needs"], needs.count).enumerated() {
                let need = try g.oneOf("needs[\(index)]", entry, needs)
                if !selectedNeeds.contains(need) { selectedNeeds.append(need) }
            }
            let hasInstall = !raw["install"].isNullish
            if delivery == "off-site" {
                if hasInstall { try g.fail("an off-site listing installs nothing here, so it cannot carry an install block") }
                if url == nil { try g.fail("an off-site listing must say where to get it, in pricing.url") }
            }
            if kind == "tool" {
                if hasInstall { try g.fail("a tool is a program you install yourself, so it cannot carry an install block") }
            } else if delivery == "repo" && !hasInstall { try g.fail("a \(kind) must say what to install, in an install block") }
            let block = hasInstall ? try install(kind: kind, raw: raw["install"], agents: selectedAgents) : .null
            return .accepted(object([
                ("terminaldeck", .number(Double(format))), ("publisher", .string(publisher)), ("id", .string(id)), ("kind", .string(kind)), ("name", .string(name)), ("summary", .string(summary)), ("version", .string(version)), ("licence", .string(licence)), ("category", .string(category)), ("tags", words(tags)), ("agents", words(selectedAgents)), ("platforms", words(selectedPlatforms)), ("delivery", .string(delivery)),
                ("pricing", object([("model", .string(model)), ("note", nullable(note)), ("url", nullable(url))])), ("licenceEnv", nullable(licenceEnv)), ("aiFile", nullable(aiFile)),
                ("links", object([("repo", .string(repo)), ("home", nullable(home)), ("docs", nullable(docs))])), ("needs", words(selectedNeeds)), ("install", block),
            ]))
        } catch let refusal as BackendSharedManifestRefusal { return .refused(refusal.why) }
        catch { return .refused("this manifest could not be read") }
    }
}
