import Foundation
import TerminalDeckNativeCore

/// Ordered wire values reuse the existing bridge codec rather than round-trip
/// another application's configuration through a lossy Codable model.
enum BackendMcpClientValue {
    static func text(_ value: NativeRPCValue) -> String { (value.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    static func strings(_ values: [String]) -> NativeRPCValue { .array(values.map(NativeRPCValue.string)) }
    static func optional(_ text: String?) -> NativeRPCValue { text.map(NativeRPCValue.string) ?? .null }
    static func jsString(_ value: NativeRPCValue) -> String {
        switch value {
        case .string(let text): return text
        case .number(let n): return OrderedJSON.jsNumber(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .missing: return "undefined"
        case .array(let a): return a.map { $0.isNullish ? "" : jsString($0) }.joined(separator: ",")
        default: return "[object Object]"
        }
    }
    static func failure(_ message: String) -> NativeRPCValue { result(false, message) }
    static func result(_ ok: Bool, _ message: String) -> NativeRPCValue { .object([.init("ok", .bool(ok)), .init("message", .string(message))]) }
    static func error(_ message: String) -> NativeRPCError { .init(code: "mcp", message: message) }
}

public struct BackendMcpClientConfiguration: Sendable {
    public let home: String
    public let environment: [String: String]
    public init(home: String, environment: [String: String]) { self.home = home; self.environment = environment }

    public var claudeJSONPath: String {
        let override = (environment["CLAUDE_CONFIG_DIR"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: override.isEmpty ? home : override).appendingPathComponent(".claude.json").path
    }
    public var claudeSettingsDirectory: String {
        let override = (environment["CLAUDE_CONFIG_DIR"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return override.isEmpty ? URL(fileURLWithPath: home).appendingPathComponent(".claude").path : override
    }
    public static func projectPath(_ value: NativeRPCValue) throws -> String? {
        guard let path = value.string, !path.isEmpty else { return nil }
        guard path.hasPrefix("/") else { throw BackendMcpClientValue.error("mcp: a project path must be absolute") }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
    public static func readJSON(_ path: String) -> NativeRPCValue {
        let url = URL(fileURLWithPath: path)
        guard let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), info.isRegularFile == true,
              (info.fileSize ?? Int.max) <= 4 * 1024 * 1024, let bytes = try? Data(contentsOf: url),
              let json = try? NativeRPCValue.parseJSON(bytes, maximumBytes: 4 * 1024 * 1024) else { return .null }
        return json
    }
    public static func expand(_ value: String, environment: [String: String]) -> String {
        let regex = try! NSRegularExpression(pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}"#)
        var output = value
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let whole = Range(match.range, in: output), let nameRange = Range(match.range(at: 1), in: value) else { continue }
            let found = environment[String(value[nameRange])]
            let fallback = Range(match.range(at: 2), in: value).map { String(value[$0]) }
            output.replaceSubrange(whole, with: found.flatMap { $0.isEmpty ? nil : $0 } ?? fallback ?? String(value[Range(match.range, in: value)!]))
        }
        return output
    }
    public static func parse(name: String, raw: NativeRPCValue, scope: String, source: String, environment: [String: String]) -> NativeRPCValue? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, raw.fields != nil else { return nil }
        let declared = (raw["type"].string ?? "").lowercased()
        let commandText = BackendMcpClientValue.text(raw["command"]), urlText = BackendMcpClientValue.text(raw["url"])
        let transport = ["stdio", "http", "sse"].contains(declared) ? declared : !commandText.isEmpty ? "stdio" : !urlText.isEmpty ? "http" : ""
        guard !transport.isEmpty, transport == "stdio" ? !commandText.isEmpty : !urlText.isEmpty else { return nil }
        let args = (raw["args"].elements ?? []).compactMap { value -> String? in
            guard value.string != nil || value.number != nil else { return nil }
            return expand(BackendMcpClientValue.jsString(value), environment: environment)
        }
        let env: [NativeRPCValue.Field] = (raw["env"].fields ?? []).compactMap { field in
            guard field.value.string != nil || field.value.number != nil || field.value.bool != nil else { return nil }
            return .init(field.key, .string(expand(BackendMcpClientValue.jsString(field.value), environment: environment)))
        }
        let cwd = BackendMcpClientValue.text(raw["cwd"])
        return .object([
            .init("id", .string(scope + ":" + name)), .init("name", .string(name)), .init("scope", .string(scope)), .init("transport", .string(transport)),
            .init("command", commandText.isEmpty ? .null : .string(expand(commandText, environment: environment))), .init("args", BackendMcpClientValue.strings(args)),
            .init("env", .object(env)), .init("cwd", cwd.isEmpty ? .null : .string(expand(cwd, environment: environment))),
            .init("url", urlText.isEmpty ? .null : .string(urlText)), .init("source", .string(source)), .init("enabled", .bool(true)), .init("disabledReason", .null),
            .init("unsupported", transport == "stdio" ? .null : .string("Claude Code dials \(transport.uppercased()) servers itself, so this panel cannot inspect it."))
        ])
    }
    public static func collect(claude: NativeRPCValue, settings: NativeRPCValue, projectJSON: NativeRPCValue, projectPath: String?, claudePath: String, projectFile: String?, environment: [String: String]) -> [NativeRPCValue] {
        let project = projectPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let local = project.map { claude["projects"][$0] } ?? .null
        let gates = projectGates(claude: claude, settings: settings, projectPath: project)
        var groups: [[NativeRPCValue]] = []
        for (scope, map, source) in [("user", claude["mcpServers"], claudePath), ("project", projectJSON["mcpServers"], projectFile ?? ""), ("local", local["mcpServers"], claudePath)] {
            if scope == "project" && projectFile == nil { continue }
            let servers = parseMap(map, scope: scope, source: source, environment: environment)
            groups.append(scope == "project" ? applyProjectGates(servers, gates: gates) : servers)
        }
        return mergeByPrecedence(groups)
    }
    public static func parseMap(_ raw: NativeRPCValue, scope: String, source: String, environment: [String: String]) -> [NativeRPCValue] {
        (raw.fields ?? []).compactMap { parse(name: $0.key, raw: $0.value, scope: scope, source: source, environment: environment) }
    }
    public static func projectGates(claude: NativeRPCValue, settings: NativeRPCValue, projectPath: String?) -> NativeRPCValue {
        let local = projectPath.map { claude["projects"][URL(fileURLWithPath: $0).standardizedFileURL.path] } ?? .null
        let sources = [settings, local]
        return .object([.init("enabled", .array(sources.flatMap { $0["enabledMcpjsonServers"].elements ?? [] }.filter { $0.string != nil })),
            .init("disabled", .array(sources.flatMap { $0["disabledMcpjsonServers"].elements ?? [] }.filter { $0.string != nil })), .init("enableAll", .bool(sources.contains { $0["enableAllProjectMcpServers"].bool == true }))])
    }
    public static func applyProjectGates(_ servers: [NativeRPCValue], gates: NativeRPCValue) -> [NativeRPCValue] {
        let enabled = Set((gates["enabled"].elements ?? []).compactMap(\.string)), disabled = Set((gates["disabled"].elements ?? []).compactMap(\.string))
        return servers.map { server in
            guard server["scope"].string == "project" else { return server }; let name = server["name"].string ?? ""
            let why = disabled.contains(name) ? "Rejected for this project in Claude Code." : !enabled.contains(name) && gates["enableAll"].bool != true ? "Not approved for this project yet." : nil
            return why.map { server.setting("enabled", .bool(false)).setting("disabledReason", .string($0)) } ?? server
        }
    }
    public static func mergeByPrecedence(_ groups: [[NativeRPCValue]]) -> [NativeRPCValue] {
        var byName: [String: NativeRPCValue] = [:]
        for group in groups { for server in group { if let name = server["name"].string { byName[name] = server } } }
        return byName.keys.sorted { $0.localizedCompare($1) == .orderedAscending }.compactMap { byName[$0] }
    }
    public func load(project: String?) -> [NativeRPCValue] {
        let file = project.map { URL(fileURLWithPath: $0).appendingPathComponent(".mcp.json").path }
        return Self.collect(claude: Self.readJSON(claudeJSONPath), settings: Self.readJSON(URL(fileURLWithPath: claudeSettingsDirectory).appendingPathComponent("settings.json").path),
            projectJSON: file.map(Self.readJSON) ?? .null, projectPath: project, claudePath: claudeJSONPath, projectFile: file, environment: environment)
    }
    public func find(id: NativeRPCValue, project: String?) throws -> NativeRPCValue {
        guard let name = id.string, !name.isEmpty else { throw BackendMcpClientValue.error("mcp: a server id is required") }
        guard let server = load(project: project).first(where: { $0["id"].string == name }) else { throw BackendMcpClientValue.error("mcp: no configured server with id \(name)") }
        return server
    }
    public static func configured(_ server: NativeRPCValue) -> BackendMcpClientConfigured {
        let transport = McpAddTransport(rawValue: server["transport"].string ?? "") ?? .stdio
        let command = transport == .stdio ? BackendMcpClientCommands.quoteArgv(([server["command"].string ?? ""] + (server["args"].elements ?? []).compactMap(\.string)).filter { !$0.isEmpty }) : server["url"].string ?? ""
        return .init(name: server["name"].string ?? "", scope: server["scope"].string ?? "user", command: command, transport: transport, envKeys: (server["env"].fields ?? []).map(\.key).sorted())
    }
}

/// Deliberately has no slot for secret values: custom rows and exports accept only this type.
public struct BackendMcpClientConfigured: Sendable {
    public let name: String; public let scope: String; public let command: String; public let transport: McpAddTransport; public let envKeys: [String]
    public init(name: String, scope: String, command: String, transport: McpAddTransport = .stdio, envKeys: [String] = []) {
        self.name = name; self.scope = scope; self.command = command; self.transport = transport; self.envKeys = envKeys
    }
}
