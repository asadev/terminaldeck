import Foundation
import Darwin
import TerminalDeckNativeCore

/// Reads the small frontmatter schema Claude Code uses. Bodies remain owned by
/// Claude Code; importing never copies a second system identity into the profile.
public enum BackendTAGAgentImport {
    public struct Definition: Sendable {
        public let name: String, description: String, model: String?, prompt: String
        public let tools: [String]?
        public var settings: NativeRPCValue = .object([])
        /// Asad, 11 Oct: names show as people read them ("Hoot Builder"), the id stays lowercase-dash for Claude Code.
        /// From the optional frontmatter `display_name:` (Claude Code ignores keys it does not know).
        public var displayName: String? = nil
        /// The name a profile gets: the display name, else the id (only a brand-new import uses the id; a sync of an
        /// existing profile keeps the name its owner gave it, see `merge`).
        public var shownName: String { displayName ?? name }
        public var profile: NativeRPCValue {
            BackendTaskValues.object([("id", .string(name.lowercased())), ("name", .string(shownName)),
                ("role", .string(description)), ("provider", .string("claude")), ("claudeAgent", .string(name)),
                ("model", model.map(NativeRPCValue.string) ?? .null),
                ("allowedTools", tools.map { .array($0.map(NativeRPCValue.string)) } ?? .null)]).merging(settings)
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
        var values: [String: String] = [:], lists: [String: [String]] = [:], current: String?, block = false
        for raw in lines[1..<end] {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if raw.first?.isWhitespace == true, let current {
                if ["tools", "blockedTools", "blocked_tools", "disallowedTools"].contains(current), line.hasPrefix("- ") { lists[current, default: []].append(unquote(String(line.dropFirst(2)))) }
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
            let entries = (lists["tools"] ?? []).isEmpty ? scalar.split(separator: ",").map { unquote(String($0).trimmingCharacters(in: .whitespaces)) } : lists["tools"]!
            var names: [String] = []
            for name in entries where !name.isEmpty {
                guard BackendSharedAgentTools.isToolName(name) else { throw NativeRPCError.invalidArguments("\(name) is not a supported Claude Code tool name.") }
                if !names.contains(name) { names.append(name) }
            }
            tools = names
        }
        let model = values["model"].flatMap { $0.isEmpty || $0 == "inherit" ? nil : $0 }
        var settings = NativeRPCValue.object([])
        for (field, alias) in [("defaultProject", "default_project"), ("maxConcurrent", "max_concurrent"), ("maxRunMinutes", "max_run_minutes")] {
            if let raw = values[field] ?? values[alias] {
                if field == "defaultProject" { settings = settings.setting(field, .string(raw)) }
                else { guard let number = Int(raw) else { throw NativeRPCError.invalidArguments("\(field) has to be a whole number.") }; settings = settings.setting(field, .number(Double(number))) }
            }
        }
        if let field = ["blockedTools", "blocked_tools", "disallowedTools"].first(where: { values[$0] != nil }) {
            let raw = values[field]!, scalar = raw.hasPrefix("[") && raw.hasSuffix("]") ? String(raw.dropFirst().dropLast()) : raw
            let names = lists[field] ?? scalar.split(separator: ",").map { unquote(String($0).trimmingCharacters(in: .whitespaces)) }
            guard names.allSatisfy(BackendSharedAgentTools.isToolName) else { throw NativeRPCError.invalidArguments("The imported blocked tool name is invalid.") }
            settings = settings.setting("blockedTools", .array(names.map(NativeRPCValue.string)))
        }
        var display: String?
        if let raw = (values["display_name"] ?? values["displayName"])?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            guard raw.utf16.count <= 60, !raw.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                throw NativeRPCError.invalidArguments("The display_name has to be one line of at most 60 characters.")
            }
            display = raw
        }
        return Definition(name: name, description: description, model: model, prompt: lines.dropFirst(end + 1).joined(separator: "\n"), tools: tools, settings: settings, displayName: display)
    }
    private static func unquote(_ text: String) -> String {
        guard text.count >= 2 else { return text }
        let inner = String(text.dropFirst().dropLast())
        // YAML: inside double quotes \\ and \" are escapes; inside single quotes '' is one quote.
        if text.first == "\"" && text.last == "\"" {
            var out = "", escaped = false
            for character in inner {
                if escaped && (character == "\\" || character == "\"") { out.append(character); escaped = false; continue }
                if escaped { out.append("\\"); escaped = false }
                if character == "\\" { escaped = true } else { out.append(character) }
            }
            return escaped ? out + "\\" : out
        }
        if text.first == "'" && text.last == "'" { return inner.replacingOccurrences(of: "''", with: "'") }
        return text
    }
    /// Synchronization can narrow an imported allow-list but never discard owner
    /// restrictions. The rest of the owner's profile settings stay as saved.
    public static func merge(_ definition: Definition, existing: NativeRPCValue?, directory: URL, file: URL) -> NativeRPCValue {
        var row = (existing ?? .object([])).merging(definition.profile)
        // No display_name in the file: a sync keeps the name the owner gave the profile (before, every sync put the id back).
        if definition.displayName == nil, let named = existing?["name"].string, !named.isEmpty { row = row.setting("name", .string(named)) }
        // No model: line in the file: a sync keeps the model the owner picked in the app (before, every sync cleared it).
        if definition.model == nil, let model = existing?["model"].string, !model.isEmpty { row = row.setting("model", .string(model)) }
        if let old = existing?["allowedTools"].elements {
            let imported = definition.tools.map { BackendTAGToolPolicy.intersection(old.compactMap(\.string), $0).map(NativeRPCValue.string) } ?? old
            row = row.setting("allowedTools", .array(imported))
        }
        if let old = existing {
            for field in ["maxConcurrent", "maxRunMinutes"] where old[field].number != nil {
                let before = old[field].number!, next = row[field].number ?? before
                // Longest run: 0 is "no limit". A limit the owner turned off stays off (a sync never puts one back);
                // a file saying "no limit" keeps the owner's limit; otherwise the shorter one.
                row = row.setting(field, .number(field == "maxRunMinutes" && (before == 0 || next == 0) ? before : min(before, next)))
            }
            var blocks = old["blockedTools"].elements ?? []
            for tool in row["blockedTools"].elements ?? [] where !blocks.contains(tool) { blocks.append(tool) }
            row = row.setting("blockedTools", .array(blocks))
            if old["defaultProject"].string != nil { row = row.setting("defaultProject", old["defaultProject"]) }
        }
        if row["defaultProject"].string == nil { row = row.setting("defaultProject", .string(directory.deletingLastPathComponent().deletingLastPathComponent().path)) }
        let storedProject = existing?["projectIdInferred"].bool == true ? nil : existing?["projectId"].string
        let resolvedProject = PROJProjects.resolve(projectID: storedProject, folder: directory.path)
        row = row.setting("projectId", .string(resolvedProject))
            .setting("projectIdInferred", .bool(storedProject == nil && resolvedProject == PROJProjects.independentID))
        return row.setting("sourceFile", .string(file.path)).setting("sourceDirectory", .string(directory.path))
            .setting("syncStatus", .string("synced")).setting("syncedAt", .number(BackendTaskValues.time())).setting("syncError", .null)
    }
    public static func options(_ raw: NativeRPCValue) throws -> NativeRPCValue {
        if raw.isNullish { return .object([]) }
        _ = try raw.requireObject("import options")
        let allowed: Set<String> = ["projectId", "projectIdInferred", "defaultProject", "maxConcurrent", "maxRunMinutes", "blockedTools", "agents"]
        guard raw.fields?.allSatisfy({ allowed.contains($0.key) }) == true else { throw NativeRPCError.invalidArguments("Import options accept projectId, defaultProject, maxConcurrent, maxRunMinutes, blockedTools and agents.") }
        if raw.has("projectId") {
            guard let id = raw["projectId"].string, PROJProjects.isValidID(id) else { throw NativeRPCError.invalidArguments("Choose a project for this batch, or Independent.") }
        }
        // Re-validating normalized options is safe. Callers cannot ask for an
        // inferred marker; an explicit batch choice always closes inference.
        if raw.has("projectIdInferred"), raw["projectIdInferred"].bool != false || !raw.has("projectId") {
            throw NativeRPCError.invalidArguments("Choose a project id rather than an inferred project marker.")
        }
        var normalized = raw.has("projectId") ? raw.setting("projectIdInferred", .bool(false)) : raw
        if raw.has("agents") {
            _ = try raw["agents"].requireObject("per-agent import options")
            var entries: [NativeRPCValue.Field] = []
            for field in raw["agents"].fields ?? [] {
                let value = try options(field.value)
                guard !value.has("agents") else { throw NativeRPCError.invalidArguments("Per-agent import options cannot nest agents.") }
                entries.append(.init(field.key, value))
            }
            normalized = normalized.setting("agents", .object(entries))
        }
        return normalized
    }
}
