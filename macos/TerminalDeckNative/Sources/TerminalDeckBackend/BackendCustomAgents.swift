import Foundation
import Darwin
import TerminalDeckNativeCore

public enum BackendCustomAgentsRules {
    public static let fileName = "custom-agents.json", maximumAgents = 32
    public static func isCustom(_ id: String?) -> Bool { NewSessionCustomAgent.isCustom(id) }
    public static func splitArgs(_ raw: String) -> [String] { NewSessionAddAgent.splitArgs(raw) }
    public static func id(label: String, taken: [String] = []) -> String {
        let slug = label.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = "custom:" + (slug.isEmpty ? "agent" : String(slug.prefix(32)))
        var candidate = base, suffix = 2
        while taken.contains(candidate) { candidate = base + "-\(suffix)"; suffix += 1 }
        return candidate
    }
    public static func draft(_ raw: NativeRPCValue) -> NativeRPCValue {
        BackendGitHubRules.object(["label", "description", "command", "args", "resumeArgs"].map { ($0, .string(raw[$0].string ?? "")) })
    }
    private static func control(_ text: String) -> Bool { text.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
    private static func meta(_ text: String) -> Bool { text.rangeOfCharacter(from: CharacterSet(charactersIn: "&|;<>^\"'`$()%!\n\r\t")) != nil }
    public static func validate(_ draft: NativeRPCValue, takenLabels: [String] = []) -> NativeRPCValue {
        var result = NativeRPCValue.object([])
        let label = (draft["label"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if label.isEmpty { result = result.setting("label", .string("Give it a name — this is what the picker and the tab will call it.")) }
        else if label.utf16.count > 40 { result = result.setting("label", .string("Keep the name under 40 characters.")) }
        else if control(label) { result = result.setting("label", .string("The name cannot contain control characters.")) }
        else if takenLabels.contains(where: { $0.lowercased() == label.lowercased() }) { result = result.setting("label", .string("There is already an agent called “\(label)”. Two rows with one name cannot be told apart.")) }
        let description = draft["description"].string ?? ""
        if description.utf16.count > 120 { result = result.setting("description", .string("Keep the description under 120 characters.")) }
        else if control(description) { result = result.setting("description", .string("The description cannot contain control characters.")) }
        let command = (draft["command"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if command.isEmpty { result = result.setting("command", .string("Name the command to run. A name on your PATH, or a full path to it.")) }
        else if command.utf16.count > 512 { result = result.setting("command", .string("That is longer than 512 characters.")) }
        else if meta(command) || control(command) || command.contains(where: \.isWhitespace) { result = result.setting("command", .string("Just the program — no spaces, quotes, pipes or redirects. Put the rest in Arguments below, or point this at a wrapper script.")) }
        else if !BackendGitHubRules.asciiMatches(command, #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, full: true) && !command.hasPrefix("/") && !BackendGitHubRules.asciiMatches(command, #"^[A-Za-z]:[\\/]"#) { result = result.setting("command", .string("That is neither a plain command name nor a full path. Use the name you would type in a terminal, or the whole path to the program.")) }
        for field in ["args", "resumeArgs"] {
            let args = splitArgs(draft[field].string ?? "")
            if args.count > 24 { result = result.setting(field, .string("That is more than 24 arguments.")); continue }
            for arg in args {
                if control(arg) { result = result.setting(field, .string("Arguments cannot contain control characters.")); break }
                if meta(arg) { result = result.setting(field, .string("Arguments cannot contain shell characters like & | ; < > $ or %.")); break }
            }
        }
        return result
    }
    /// Disk parsing is total: one invalid agent costs one row, duplicates keep
    /// the first. Label complaints are ignored here, just as in shared TS.
    public static func parseAgents(_ raw: NativeRPCValue) -> [NativeRPCValue] {
        var seen = Set<String>(), result: [NativeRPCValue] = []
        for value in raw.elements ?? [] {
            guard let id = value["id"].string, isCustom(id), !seen.contains(id) else { continue }
            let label = (value["label"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let command = (value["command"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let description = (value["description"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let args = (value["args"].elements ?? []).compactMap(\.string), resume = (value["resumeArgs"].elements ?? []).compactMap(\.string)
            let draft = BackendGitHubRules.object([("label", .string(label)), ("description", .string(description)), ("command", .string(command)), ("args", .string(args.map { NativeRPCValue.string($0).compact }.joined(separator: " "))), ("resumeArgs", .string(resume.map { NativeRPCValue.string($0).compact }.joined(separator: " ")))])
            guard validate(draft).removing("label").fields?.isEmpty == true else { continue }
            seen.insert(id)
            result.append(BackendGitHubRules.object([("id", .string(id)), ("label", .string(label)), ("description", .string(description)), ("command", .string(command)), ("args", .array(args.map(NativeRPCValue.string))), ("resumeArgs", .array(resume.map(NativeRPCValue.string))), ("addedAt", .number(value["addedAt"].number ?? 0)), ("resolvedPath", .string(value["resolvedPath"].string ?? command))]))
        }
        return result
    }
    public static func entry(_ agent: NativeRPCValue) -> NativeRPCValue {
        let command = agent["command"].string ?? "", description = agent["description"].string ?? ""
        var fields: [(String, NativeRPCValue)] = [("id", agent["id"]), ("label", agent["label"]), ("description", .string(description.isEmpty ? "Runs `\(command)` in the project folder." : description)), ("bin", .string(command)), ("args", agent["args"]), ("resumeArgs", agent["resumeArgs"]), ("alternateBins", .array([])), ("logins", .string("unmeasured")), ("loginsNote", .string(NewSessionProviders.customLoginsNote)), ("signOutNote", .string(NewSessionProviders.customLoginsNote)), ("verified", .string("Added by you. `\(command)` resolved to \(agent["resolvedPath"].string ?? command) on this machine when it was added; nothing about it has been measured since."))]
        fields += ["install", "url", "versionArgs", "configEnv", "credentialFile", "statusArgs", "statusFormat", "signInArgs", "signOutArgs"].map { ($0, .null) }
        return BackendGitHubRules.object(fields)
    }
}

public actor BackendCustomAgentsStore {
    public typealias Lookup = @Sendable (String) async throws -> String?
    public nonisolated let file: URL
    private let lookup: Lookup
    private let now: @Sendable () -> Double
    private var agents: [NativeRPCValue] = [], loaded = false
    public init(dataDirectory: URL, lookup: @escaping Lookup, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) throws {
        guard dataDirectory.isFileURL, dataDirectory.path.hasPrefix("/"), !dataDirectory.path.contains("\0") else { throw NativeRPCError.invalidArguments("Added agents need an absolute data directory") }
        file = dataDirectory.appendingPathComponent(BackendCustomAgentsRules.fileName); self.lookup = lookup; self.now = now
    }
    /// Production lookup is executable presence only, never an unknown agent's
    /// guessed --version probe. Windows PATHEXT/where.exe are not applicable.
    public nonisolated static func nativeLookup(loginPath: @escaping @Sendable () async throws -> String) -> Lookup {
        { command in
            if command.hasPrefix("/") { return access(command, X_OK) == 0 ? command : nil }
            // A drive-letter path remains readable in the persisted schema but
            // is not executable on a Mac; never reinterpret it as a bare name.
            if BackendGitHubRules.asciiMatches(command, #"^[A-Za-z]:[\\/]"#) { return nil }
            return BackendNativeProviders.lookup(command, path: try await loginPath())
        }
    }
    private func load() {
        if loaded { return }; loaded = true
        guard let data = try? Data(contentsOf: file) else { return }
        let text = String(decoding: data, as: UTF8.self)
        guard text.utf16.count <= 256 * 1024,
              let parsed = try? NativeRPCValue.parseJSON(data) else { return }
        agents = Array(BackendCustomAgentsRules.parseAgents(parsed["agents"]).prefix(32))
    }
    public func list() -> NativeRPCValue { load(); return .array(agents) }
    public func get(_ id: String) -> NativeRPCValue? { load(); return BackendCustomAgentsRules.isCustom(id) ? agents.first { $0["id"].string == id } : nil }
    private func commit(_ next: [NativeRPCValue]) throws {
        let value = BackendGitHubRules.object([("version", .number(1)), ("agents", .array(next))])
        var bytes = try value.encodedJSON(pretty: true); bytes.append(10)
        try BackendAccountFiles.writeAtomic(bytes, to: file)
        agents = next
    }
    public func add(_ raw: NativeRPCValue) async throws -> NativeRPCValue {
        load()
        let draft = BackendCustomAgentsRules.draft(raw)
        func problems(_ value: NativeRPCValue) -> NativeRPCValue { BackendGitHubRules.object([("ok", .bool(false)), ("problems", value)]) }
        let taken = CodingAICatalog.all.map(\.label) + agents.compactMap { $0["label"].string }
        let invalid = BackendCustomAgentsRules.validate(draft, takenLabels: taken)
        guard invalid.fields?.isEmpty == true else { return problems(invalid) }
        guard agents.count < 32 else { return problems(BackendGitHubRules.object([("label", .string("This machine already has 32 added agents. Remove one first."))])) }
        let command = (draft["command"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path = try await lookup(command) else { return problems(BackendGitHubRules.object([("command", .string("`\(command)` is not on your PATH and is not a program this machine can run. Check the spelling, or give the full path to it."))])) }
        // Lookup awaits; revalidate uniqueness and limits after actor reentry.
        let current = BackendCustomAgentsRules.validate(draft, takenLabels: CodingAICatalog.all.map(\.label) + agents.compactMap { $0["label"].string })
        guard current.fields?.isEmpty == true else { return problems(current) }
        guard agents.count < 32 else { return problems(BackendGitHubRules.object([("label", .string("This machine already has 32 added agents. Remove one first."))])) }
        let label = (draft["label"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let agent = BackendGitHubRules.object([("id", .string(BackendCustomAgentsRules.id(label: label, taken: agents.compactMap { $0["id"].string }))), ("label", .string(label)), ("description", .string((draft["description"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines))), ("command", .string(command)), ("args", .array(BackendCustomAgentsRules.splitArgs(draft["args"].string ?? "").map(NativeRPCValue.string))), ("resumeArgs", .array(BackendCustomAgentsRules.splitArgs(draft["resumeArgs"].string ?? "").map(NativeRPCValue.string))), ("addedAt", .number(now())), ("resolvedPath", .string(path))])
        try commit(agents + [agent])
        return BackendGitHubRules.object([("ok", .bool(true)), ("agent", agent)])
    }
    public func remove(_ id: String) throws -> Bool {
        load(); guard agents.contains(where: { $0["id"].string == id }) else { return false }
        try commit(agents.filter { $0["id"].string != id }); return true
    }
}

public enum BackendCustomAgentsChannels {
    public static func register(registry: NativeChannelRegistry, ownerID: String, store: BackendCustomAgentsStore) async throws -> [String] {
        let channels = ["agents:list", "agents:add", "agents:remove"]
        for channel in channels {
            try await registry.register(channel, ownerID: ownerID) { context, args in
                guard context.caller == .nativeApp else { throw NativeRPCError(code: "access-denied", message: "Only the app's own window may edit this machine's agents") }
                if channel == "agents:list" { return await store.list() }
                let value = context.argument(0, in: args)
                if channel == "agents:add" { return try await store.add(value) }
                guard let id = value.string, id.hasPrefix("custom:") else { return .bool(false) }
                return .bool(try await store.remove(id))
            }
        }
        return channels
    }
}
