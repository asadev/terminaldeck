import Foundation
import Darwin
import TerminalDeckNativeCore

/// Reads the small frontmatter schema Claude Code uses. Bodies remain owned by
/// Claude Code; importing never copies a second system identity into the profile.
public enum BackendTAGAgentImport {
    public struct Definition: Sendable {
        public let name: String, description: String, model: String?, prompt: String
        public let tools: [String]?
        public var profile: NativeRPCValue {
            BackendTaskValues.object([("id", .string(name.lowercased())), ("name", .string(name)),
                ("role", .string(description)), ("provider", .string("claude")), ("claudeAgent", .string(name)),
                ("model", model.map(NativeRPCValue.string) ?? .null),
                ("allowedTools", tools.map { .array($0.map(NativeRPCValue.string)) } ?? .null)])
        }
    }
    public static func directory(_ folder: String) throws -> URL {
        guard folder.hasPrefix("/"), !folder.contains("\0") else { throw NativeRPCError.invalidArguments("Choose a full project folder or .claude/agents folder.") }
        let selected = URL(fileURLWithPath: folder).standardizedFileURL
        let directory: URL
        if selected.lastPathComponent == "agents", selected.deletingLastPathComponent().lastPathComponent == ".claude" { directory = selected }
        else if selected.lastPathComponent == ".claude" { directory = selected.appendingPathComponent("agents", isDirectory: true) }
        else { directory = selected.appendingPathComponent(".claude/agents", isDirectory: true) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NativeRPCError.invalidArguments("There is no .claude/agents folder at \(directory.path).")
        }
        return directory.resolvingSymlinksInPath()
    }
    public static func read(_ file: URL) throws -> Definition? {
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NativeRPCError.invalidArguments("The agent definition could not be read.") }; defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 512_000 else { throw NativeRPCError.invalidArguments("The agent definition must be a regular file of at most 512 KB.") }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw NativeRPCError.invalidArguments("The agent definition could not be read.") }
            guard data.count + count <= 512_000 else { throw NativeRPCError.invalidArguments("The agent definition is too large.") }
            data.append(contentsOf: bytes.prefix(count))
        }
        guard let text = String(data: data, encoding: .utf8) else { throw NativeRPCError.invalidArguments("The agent definition is not UTF-8 text.") }
        return try parse(text)
    }
    public static func parse(_ source: String) throws -> Definition? {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else { return nil }
        guard let end = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) == "---" }) else { throw NativeRPCError.invalidArguments("The agent frontmatter has no closing --- line.") }
        var values: [String: String] = [:], listTools: [String] = [], current: String?, block = false
        for raw in lines[1..<end] {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if raw.first?.isWhitespace == true, let current {
                if current == "tools", line.hasPrefix("- ") { listTools.append(unquote(String(line.dropFirst(2)))) }
                else if block { let prior = values[current] ?? ""; values[current] = prior + (prior.isEmpty ? "" : " ") + line }
                else { throw NativeRPCError.invalidArguments("Unsupported continuation in the \(current) frontmatter.") }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { throw NativeRPCError.invalidArguments("An agent frontmatter line has no field name.") }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard values[key] == nil else { throw NativeRPCError.invalidArguments("The agent frontmatter repeats \(key).") }
            current = key; block = [">", ">-", "|", "|-"].contains(value); values[key] = block ? "" : unquote(value)
        }
        guard let name = values["name"], !name.isEmpty else { return nil }
        guard name.range(of: #"^[a-z0-9][a-z0-9-]{0,39}$"#, options: .regularExpression) != nil else { throw NativeRPCError.invalidArguments("The imported name has to be a task agent id of at most 40 letters, digits and dashes.") }
        guard let description = values["description"], !description.isEmpty else { throw NativeRPCError.invalidArguments("The agent definition needs a description.") }
        var tools: [String]?
        if let value = values["tools"] {
            let scalar = value.hasPrefix("[") && value.hasSuffix("]") ? String(value.dropFirst().dropLast()) : value
            let entries = listTools.isEmpty ? scalar.split(separator: ",").map { unquote(String($0).trimmingCharacters(in: .whitespaces)) } : listTools
            var names: [String] = []
            for name in entries where !name.isEmpty {
                guard BackendSharedAgentTools.isToolName(name) else { throw NativeRPCError.invalidArguments("\(name) is not a supported Claude Code tool name.") }
                if !names.contains(name) { names.append(name) }
            }
            tools = names
        }
        let model = values["model"].flatMap { $0.isEmpty || $0 == "inherit" ? nil : $0 }
        return Definition(name: name, description: description, model: model, prompt: lines.dropFirst(end + 1).joined(separator: "\n"), tools: tools)
    }
    private static func unquote(_ text: String) -> String {
        if text.count >= 2, (text.first == "\"" && text.last == "\"" || text.first == "'" && text.last == "'") { return String(text.dropFirst().dropLast()) }
        return text
    }
    /// Synchronization can narrow an imported allow-list but never discard owner
    /// restrictions. The rest of the owner's profile settings stay as saved.
    public static func merge(_ definition: Definition, existing: NativeRPCValue?, directory: URL, file: URL) -> NativeRPCValue {
        var row = (existing ?? .object([])).merging(definition.profile)
        if let old = existing?["allowedTools"].elements {
            let imported = definition.tools.map { BackendTAGToolPolicy.intersection(old.compactMap(\.string), $0).map(NativeRPCValue.string) } ?? old
            row = row.setting("allowedTools", .array(imported))
        }
        if existing?["defaultProject"].string == nil { row = row.setting("defaultProject", .string(directory.deletingLastPathComponent().deletingLastPathComponent().path)) }
        return row.setting("sourceFile", .string(file.path)).setting("sourceDirectory", .string(directory.path))
            .setting("syncStatus", .string("synced")).setting("syncedAt", .number(BackendTaskValues.time())).setting("syncError", .null)
    }
}
