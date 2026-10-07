import Foundation
import TerminalDeckNativeCore

enum BackendPluginsText {
    static func prefix(_ value: String, _ count: Int) -> String { String(decoding: Array(value.utf16.prefix(count)), as: UTF16.self) }
    static func suffix(_ value: String, _ count: Int) -> String { String(decoding: Array(value.utf16.suffix(count)), as: UTF16.self) }
}

public struct BackendPluginsToolManifest: Sendable {
    public let name, title, description, tier: String
    public let inputSchema: NativeRPCValue
    public func wire(_ id: String) -> String { "plugin_\(id)_\(name)" }
    public func actionID(_ id: String) -> String { "plugin.\(id).\(name)" }
}

public struct BackendPluginsManifest: Sendable {
    public let id, name, summary, version, main: String
    public let capabilities: [String]
    public let tools: [BackendPluginsToolManifest]
}

/// Closed grammar from plugins/manifest.ts. A refusal names the offending key.
public enum BackendPluginsManifestReader {
    /// Source PLUGIN_TIER / KIND_TIER_FLOOR.mcp: a plugin runs a program.
    public static let tier = 3
    public static let maximumBytes = 65_536
    public static let maximumTools = 8
    public static let capabilities = PluginCatalog.capabilities
    public static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
    static func refusal(_ text: String) -> NativeRPCError { NativeRPCError(code: "plugin-refusal", message: text) }
    static func object(_ value: NativeRPCValue, _ where_: String) throws {
        guard value.fields != nil else { throw refusal("\(where_) must be an object") }
    }
    static func keys(_ value: NativeRPCValue, _ where_: String, _ allowed: [String]) throws {
        for field in value.fields ?? [] where !allowed.contains(field.key) {
            throw refusal("\(where_) has a key this app does not know about: \(field.key)")
        }
    }
    static func text(_ value: NativeRPCValue, _ where_: String, _ maximum: Int) throws -> String {
        guard let raw = value.string else { throw refusal("\(where_) must be text") }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw refusal("\(where_) must not be empty") }
        guard text.utf16.count <= maximum else { throw refusal("\(where_) must be \(maximum) characters or fewer") }
        guard !text.contains("\r"), !text.contains("\n") else { throw refusal("\(where_) must be a single line") }
        return text
    }
    static func choice(_ value: NativeRPCValue, _ where_: String, _ choices: [String]) throws -> String {
        guard let text = value.string, choices.contains(text) else { throw refusal("\(where_) must be one of: \(choices.joined(separator: ", "))") }
        return text
    }
    static func list(_ value: NativeRPCValue, _ where_: String, _ maximum: Int) throws -> [NativeRPCValue] {
        guard let values = value.elements else { throw refusal("\(where_) must be a list") }
        guard values.count <= maximum else { throw refusal("\(where_) may hold at most \(maximum) entries") }
        return values
    }
    static func schema(_ value: NativeRPCValue, _ where_: String, _ depth: Int) throws {
        try object(value, where_)
        guard depth <= 6 else { throw refusal("\(where_) is nested too deeply") }
        try keys(value, where_, ["type", "properties", "required", "enum", "items", "additionalProperties", "description"])
        if value.has("properties") {
            try object(value["properties"], where_ + ".properties")
            for field in value["properties"].fields ?? [] { try schema(field.value, where_ + ".properties." + field.key, depth + 1) }
        }
        if value.has("items") { try schema(value["items"], where_ + ".items", depth + 1) }
    }
    public static func parse(_ bytes: String, folder: String) throws -> BackendPluginsManifest {
        guard bytes.utf8.count <= maximumBytes else { throw refusal("a manifest must be \(maximumBytes) bytes or fewer") }
        guard let raw = try? NativeRPCValue.parseJSON(Data(bytes.utf8)) else { throw refusal("this is not valid JSON") }
        guard raw.fields != nil else { throw refusal("a manifest must be a JSON object") }
        try keys(raw, "the manifest", ["terminaldeck", "id", "name", "summary", "version", "plugin"])
        guard raw["terminaldeck"].number == 1 else {
            let format = raw["terminaldeck"] == .missing ? "undefined" : raw["terminaldeck"].string ?? raw["terminaldeck"].compact
            throw refusal("this manifest is written for format \(format), and this app reads format 1")
        }
        let id = try text(raw["id"], "id", 40)
        guard matches(id, #"^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$"#) else { throw refusal("id must be lower-case letters, digits and hyphens") }
        guard id == folder else { throw refusal("this manifest calls itself \(id), and its folder is called \(folder)") }
        let name = try text(raw["name"], "name", 60), summary = try text(raw["summary"], "summary", 120)
        let version = try text(raw["version"], "version", 20)
        guard matches(version, #"^\d+\.\d+\.\d+$"#) else { throw refusal("version must look like 1.2.3") }
        let block = raw["plugin"]
        try object(block, "plugin"); try keys(block, "plugin", ["main", "runtime", "capabilities", "tools"])
        let main = try text(block["main"], "plugin.main", 200)
        guard !main.hasPrefix("/") else { throw refusal("plugin.main must be a path inside the item, so it cannot start with /") }
        guard !matches(main, #"^[A-Za-z]:"#) else { throw refusal("plugin.main must be a path inside the item, so it cannot name a drive") }
        guard !main.contains("\\") else { throw refusal("plugin.main must use / between folders") }
        guard !main.contains("\0") else { throw refusal("plugin.main contains a character a file name cannot have") }
        guard !main.components(separatedBy: "/").contains("..") else { throw refusal("plugin.main must not step outside the item with ..") }
        guard !main.components(separatedBy: "/").contains("") else { throw refusal("plugin.main has an empty folder name in it") }
        guard [".js", ".mjs", ".cjs"].contains(where: { main.lowercased().hasSuffix($0) }) else { throw refusal("plugin.main must be a .js, .mjs or .cjs file") }
        _ = try choice(block["runtime"], "plugin.runtime", ["node"])
        var granted: [String] = []
        for (i, value) in try list(block["capabilities"], "plugin.capabilities", capabilities.count).enumerated() {
            let cap = try choice(value, "plugin.capabilities[\(i)]", capabilities)
            if !granted.contains(cap) { granted.append(cap) }
        }
        var tools: [BackendPluginsToolManifest] = []
        for (i, tool) in try (block.has("tools") ? list(block["tools"], "plugin.tools", maximumTools) : []).enumerated() {
            let at = "plugin.tools[\(i)]"
            try object(tool, at); try keys(tool, at, ["name", "title", "description", "tier", "inputSchema"])
            let name = try text(tool["name"], at + ".name", 16)
            guard matches(name, #"^[a-z][a-z0-9_]{0,15}$"#) else { throw refusal("\(at).name must be lower-case letters, digits and _, starting with a letter") }
            try schema(tool["inputSchema"], at + ".inputSchema", 0)
            guard tool["inputSchema"]["type"].string == "object" else { throw refusal("\(at).inputSchema must have \"type\": \"object\"") }
            guard tool["inputSchema"].compact.utf8.count <= 8192 else { throw refusal("\(at).inputSchema must be 8192 bytes or fewer") }
            guard !tools.contains(where: { $0.name == name }) else { throw refusal("plugin.tools names \(name) twice") }
            tools.append(BackendPluginsToolManifest(name: name, title: try text(tool["title"], at + ".title", 60), description: try text(tool["description"], at + ".description", 300), tier: try choice(tool["tier"], at + ".tier", PluginCatalog.tiers), inputSchema: tool["inputSchema"]))
        }
        if !tools.isEmpty && !granted.contains("tools.contribute") { throw refusal("plugin.tools are only offered with the tools.contribute capability, which this manifest does not ask for") }
        if tools.isEmpty && granted.contains("tools.contribute") { throw refusal("tools.contribute is asked for, and plugin.tools declares none") }
        return BackendPluginsManifest(id: id, name: name, summary: summary, version: version, main: main, capabilities: granted, tools: tools)
    }
    public static func read(_ dir: URL, folder: String) throws -> BackendPluginsManifest {
        let file = dir.appendingPathComponent("terminaldeck.json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path), let size = attributes[.size] as? NSNumber else { throw refusal("there is no terminaldeck.json in this folder") }
        guard size.intValue <= maximumBytes else { throw refusal("terminaldeck.json must be \(maximumBytes) bytes or fewer") }
        guard let bytes = try? String(contentsOf: file, encoding: .utf8) else { throw refusal("there is no terminaldeck.json in this folder") }
        return try parse(bytes, folder: folder)
    }
}
