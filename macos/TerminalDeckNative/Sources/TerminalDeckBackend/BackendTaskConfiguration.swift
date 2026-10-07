import Foundation
import Darwin
import Security
import TerminalDeckNativeCore

/// task-config.ts agent settings and instruction-file ownership. Existing CRM
/// connection records are preserved and redacted, while their transport belongs
/// to the authenticated CRM integration; it is never fabricated here.
public actor BackendTaskConfiguration {
    private let persistence: BackendTaskPersistence, instructions: BackendTaskPersistence
    private var agents: [NativeRPCValue] = [], connections: [NativeRPCValue] = [], loaded = false
    private let changed: @Sendable () async -> Void
    public init(persistence: BackendTaskPersistence, changed: @escaping @Sendable () async -> Void = {}) throws {
        self.persistence = persistence; self.changed = changed
        instructions = try BackendTaskPersistence(directory: persistence.directory.appendingPathComponent("agent-instructions"), ownership: persistence.ownership)
    }
    public func start() throws {
        guard !loaded else { return }
        if let raw = try persistence.read("task-config.json") {
            guard raw["v"].number == 1 else { throw NativeRPCError.malformed("Unsupported task-config.json version") }
            // task-config.ts load: every stored agent cleaned as a save would clean it; one that no longer reads is
            // skipped, and a status that no longer reads costs the agent its status, not the agent. Normalised in
            // memory only; the stored bytes are rewritten only by a real change.
            var cleaned: [NativeRPCValue] = []
            for entry in raw["agents"].elements ?? [] {
                var input = entry
                if entry.fields != nil, case .failure = Self.lifecycleOf(entry) { input = entry.removing("status").removing("statusAt") }
                if let agent = try? Self.cleanAgent(input, others: cleaned) { cleaned.append(agent) }
            }
            agents = cleaned
            connections = raw["connections"].elements ?? []
            // After the connections, so the rewrite carries them too. A rewrite that fails keeps what was read.
            if moveInstructionsToFiles() { try? flush() }
        }; loaded = true
    }
    struct LifecycleProblem: Error { let sentence: String }
    /// agent-lifecycle.ts `lifecycleOf`: a stored lifecycle, checked, or the sentence saying why it does not read.
    /// Absent fields read as active.
    static func lifecycleOf(_ raw: NativeRPCValue) -> Result<(status: String, statusAt: Double?), LifecycleProblem> {
        guard let status = raw["status"].isNullish ? "active" : raw["status"].string, ["active", "paused", "archived"].contains(status) else {
            return .failure(.init(sentence: "The agent status has to be one of: active, paused, archived."))
        }
        let at = raw["statusAt"]
        if !at.isNullish, (at.number.map { $0 < 0 } ?? true) { return .failure(.init(sentence: "The status time has to be a time.")) }
        if status != "active", at.isNullish { return .failure(.init(sentence: "\(status == "paused" ? "A paused" : "An archived") agent has to say when it was \(status).")) }
        return .success((status, at.number))
    }
    /// task-config.ts `text`, `optionalText`, `textList` and `whole`, in their words.
    private static func text(_ value: NativeRPCValue, _ field: String, max: Int) throws -> String {
        guard let raw = value.string else { throw NativeRPCError.invalidArguments("\(field) has to be text.") }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NativeRPCError.invalidArguments("\(field) cannot be empty.") }
        guard trimmed.utf16.count <= max else { throw NativeRPCError.invalidArguments("\(field) is longer than \(max) characters.") }
        return trimmed
    }
    private static func optionalText(_ value: NativeRPCValue, _ field: String, max: Int) throws -> NativeRPCValue {
        if value.isNullish || value.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { return .null }
        return .string(try text(value, field, max: max))
    }
    private static func textList(_ value: NativeRPCValue, _ field: String, max: Int, maxLength: Int) throws -> [String] {
        if value.isNullish { return [] }
        guard let entries = value.elements else { throw NativeRPCError.invalidArguments("\(field) has to be a list.") }
        var out: [String] = []
        for entry in entries { let one = try text(entry, field, max: maxLength); if !out.contains(one) { out.append(one) } }
        guard out.count <= max else { throw NativeRPCError.invalidArguments("\(field) takes at most \(max).") }
        return out
    }
    private static func whole(_ value: NativeRPCValue, _ field: String, min: Int, max: Int, fallback: Int) throws -> NativeRPCValue {
        if value.isNullish { return .number(Double(fallback)) }
        guard let number = value.number, number.rounded() == number, number >= Double(min), number <= Double(max) else {
            throw NativeRPCError.invalidArguments("\(field) has to be a whole number from \(min) to \(max).")
        }
        return .number(number)
    }
    /// task-config.ts `cleanAgent`: one agent checked, in its stored shape and key order, its lifecycle from the input.
    static func cleanAgent(_ raw: NativeRPCValue, others: [NativeRPCValue]) throws -> NativeRPCValue {
        typealias Capabilities = BackendSharedAgentCapabilities
        let input = raw.fields != nil ? raw : .object([])
        let id = try text(input["id"], "The agent id", max: 40).lowercased()
        guard id.range(of: #"^[a-z0-9][a-z0-9-]*$"#, options: .regularExpression) != nil else { throw NativeRPCError.invalidArguments("The agent id can only use letters, digits and dashes.") }
        let name = try text(input["name"], "The agent name", max: 60)
        guard !others.contains(where: { $0["id"].string != id && $0["name"].string?.lowercased() == name.lowercased() }) else { throw NativeRPCError.invalidArguments("Another agent is already called \(name).") }
        let provider = try optionalText(input["provider"], "The coding agent", max: 40)
        // blockedToolsOf: a name Claude Code would not take is refused first, then a setting this agent cannot keep.
        let blockedTools = try textList(input["blockedTools"], "Blocked tools", max: 30, maxLength: 140)
        if let odd = blockedTools.first(where: { !BackendSharedAgentTools.isToolName($0) }) { throw NativeRPCError.invalidArguments("\(odd) is not a tool name that can be blocked.") }
        let skillsOff = input["skillsOff"].bool == true
        if (!blockedTools.isEmpty && !Capabilities.enforces(provider.string, setting: .blockedTools)) || (skillsOff && !Capabilities.enforces(provider.string, setting: .skillsOff)) {
            throw NativeRPCError.invalidArguments("Only Claude Code can block tools or turn skills off. Clear them, or choose Claude Code.")
        }
        let lifecycle: (status: String, statusAt: Double?)
        switch lifecycleOf(input) { case .success(let value): lifecycle = value; case .failure(let problem): throw NativeRPCError.invalidArguments(problem.sentence) }
        let role = try optionalText(input["role"], "The role", max: 60), account = try optionalText(input["account"], "The account", max: 80)
        let model = try optionalText(input["model"], "The model", max: 80), effort = try optionalText(input["effort"], "The effort", max: 20)
        if let level = effort.string, !["low", "medium", "high", "xhigh", "max", "ultracode", "auto"].contains(level) {
            throw NativeRPCError.invalidArguments("The effort has to be one of: low, medium, high, xhigh, max, ultracode, auto.")
        }
        let instructions = try optionalText(input["instructions"], "The instructions", max: 32_000)
        let preferred = try textList(input["toolsPreferred"], "Tools to prefer", max: 30, maxLength: 80), avoided = try textList(input["toolsAvoided"], "Tools to avoid", max: 30, maxLength: 80)
        let skills = try textList(input["skills"], "The skills", max: 20, maxLength: 80)
        let concurrent = try whole(input["maxConcurrent"], "Tasks at once", min: 1, max: 5, fallback: 1)
        let runMinutes = try whole(input["maxRunMinutes"], "Longest run", min: 0, max: 1_440, fallback: 60)
        let keepAlive = try whole(input["keepAliveMinutes"], "Keep open", min: 0, max: 1_440, fallback: 30)
        let verify = try optionalText(input["verifyCommand"], "The check command", max: 500)
        return BackendTaskValues.object([("id", .string(id)), ("name", .string(name)), ("role", role.string.map(NativeRPCValue.string) ?? .string("general")), ("provider", provider),
            ("account", account), ("model", model), ("effort", effort), ("instructions", instructions), ("instructionsFile", .null),
            ("toolsPreferred", .array(preferred.map(NativeRPCValue.string))), ("toolsAvoided", .array(avoided.map(NativeRPCValue.string))), ("skills", .array(skills.map(NativeRPCValue.string))),
            ("blockedTools", .array(blockedTools.map(NativeRPCValue.string))), ("skillsOff", .bool(skillsOff)), ("maxConcurrent", concurrent), ("maxRunMinutes", runMinutes),
            ("keepAliveMinutes", keepAlive), ("verifyCommand", verify), ("status", .string(lifecycle.status)), ("statusAt", lifecycle.statusAt.map(NativeRPCValue.number) ?? .null)])
    }
    /// agent-lifecycle.ts `applyLifecycle`: the status one action leads to, or the sentence saying why it cannot.
    static func applyLifecycle(_ current: String, action: String, name: String) -> (to: String?, refusal: String?) {
        let steps: [String: (from: [String], to: String, refuse: String)] = [
            "pause": (["active"], "paused", current == "archived" ? "\(name) is archived. Restore it first." : "\(name) is already paused."),
            "resume": (["paused"], "active", current == "archived" ? "\(name) is archived. Restore it instead." : "\(name) is not paused."),
            "archive": (["active", "paused"], "archived", "\(name) is already archived."),
            "restore": (["archived"], "active", "\(name) is not archived."),
        ]
        guard let step = steps[action] else { return (nil, "That is not something an agent can do: \(action).") }
        return step.from.contains(current) ? (step.to, nil) : (nil, step.refuse)
    }
    /// task-config.ts `moveInstructionsToFiles`: instructions saved before they had files, written into them. A file
    /// that already exists wins; one that cannot be written leaves the text where it was, still read. True when anything moved.
    private func moveInstructionsToFiles() -> Bool {
        guard persistence.ownership != .memory else { return false }
        var moved = false
        for index in agents.indices {
            guard let id = agents[index]["id"].string, let stored = agents[index]["instructions"].string else { continue }
            let text = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            do {
                // agent-instructions.ts writeInstructions: whole file, newline-terminated, within the limit.
                guard text.utf16.count <= 32_000 else { throw NativeRPCError.invalidArguments("The instructions are longer than 32000 characters.") }
                if !FileManager.default.fileExists(atPath: try instructions.file(id + ".md").path) { try instructions.writeBytes(id + ".md", data: Data((text + "\n").utf8)) }
                agents[index] = agents[index].setting("instructions", .null); moved = true
            } catch { continue }
        }
        return moved
    }
    public func allAgents() throws -> [NativeRPCValue] { try started(); return try agents.map(view) }
    public func agent(_ nameOrID: String) throws -> NativeRPCValue? {
        try started(); let wanted = nameOrID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return try agents.first { $0["id"].string == wanted || $0["name"].string?.lowercased() == wanted }.map(view)
    }
    public func connection(_ keyID: String) throws -> NativeRPCValue? { try started(); return connections.first { $0["keyId"].string == keyID } }
    public func connectionViews() throws -> [NativeRPCValue] { try started(); return connections.map { $0.removing("eventsSecret").setting("hasEventsSecret", .bool(!$0["eventsSecret"].isNullish)) } }
    public func saveAgent(_ input: NativeRPCValue) async throws -> NativeRPCValue {
        try started(); try persistence.writable()
        // What a save carries about status is not read at all: it is kept below.
        let cleaned = try Self.cleanAgent(input.fields == nil ? input : input.removing("status").removing("statusAt"), others: agents)
        let id = cleaned["id"].string ?? "", index = agents.firstIndex { $0["id"].string == id }
        guard index != nil || agents.count < 20 else { throw NativeRPCError.invalidArguments("There can be at most 20 agents.") }
        let existing = index.map { agents[$0] }
        var row = cleaned.setting("status", existing?["status"] ?? .string("active")).setting("statusAt", existing?["statusAt"] ?? .null)
        try Self.checkSupported(row)
        let before = agents
        if persistence.ownership != .memory {
            // The file first: a save that cannot write it changes nothing.
            do {
                if let text = row["instructions"].string, !text.isEmpty { try instructions.writeBytes(id + ".md", data: Data((text + "\n").utf8)) }
                else { try instructions.remove(id + ".md") }
            } catch { throw NativeRPCError.invalidArguments("The instructions file could not be written: \(error.localizedDescription)") }
            row = row.setting("instructions", .null)
        }
        if let index { agents[index] = row } else { agents.append(row) }
        do { try flush() } catch { agents = before; throw error }; await changed(); return try view(row)
    }
    public func setStatus(_ id: String, action: String) async throws -> NativeRPCValue {
        try started(); try persistence.writable(); guard let index = agents.firstIndex(where: { $0["id"].string == id }) else { throw NativeRPCError.invalidArguments("That agent no longer exists.") }
        let step = Self.applyLifecycle(agents[index]["status"].string ?? "active", action: action, name: agents[index]["name"].string ?? id)
        guard let next = step.to else { throw NativeRPCError.invalidArguments(step.refusal ?? "That is not something an agent can do: \(action).") }
        let before = agents; agents[index] = agents[index].setting("status", .string(next)).setting("statusAt", .number(BackendTaskValues.time()))
        do { try flush() } catch { agents = before; throw error }; await changed(); return try view(agents[index])
    }
    /// task-config.ts `checkSupported`: a setting the chosen coding agent cannot be made to keep, refused when the
    /// agent is saved rather than dropped when it starts.
    static func checkSupported(_ agent: NativeRPCValue) throws {
        typealias Capabilities = BackendSharedAgentCapabilities
        let provider = agent["provider"].string, label = Capabilities.agentLabel(provider)
        for (setting, value, what) in [(Capabilities.Setting.model, agent["model"], "a model"), (.effort, agent["effort"], "an effort level")]
        where !value.isNullish && !Capabilities.enforces(provider, setting: setting) {
            throw NativeRPCError.invalidArguments("\(label) cannot be given \(what) by this app. Clear it, or choose Claude Code.")
        }
        // What only a brief can carry, for an agent that reads none.
        let advice = !(agent["toolsPreferred"].elements ?? []).isEmpty || !(agent["toolsAvoided"].elements ?? []).isEmpty
        for (setting, set, what) in [(Capabilities.Setting.instructions, !agent["instructions"].isNullish, "instructions"), (.toolAdvice, advice, "tools to prefer or avoid"),
                                     (.skillSelection, !(agent["skills"].elements ?? []).isEmpty, "skills")]
        where set && Capabilities.capabilityFor(provider, setting: setting).support == .unsupported {
            throw NativeRPCError.invalidArguments("\(label) cannot be given \(what). Clear them, or choose a coding agent.")
        }
    }
    public func removeAgent(_ id: String) async throws {
        try started(); try persistence.writable(); guard agents.contains(where: { $0["id"].string == id }) else { throw NativeRPCError.invalidArguments("That agent no longer exists.") }
        let before = (agents, connections); agents.removeAll { $0["id"].string == id }
        connections = connections.map { connection in var identities = connection["identities"]; for field in identities.fields ?? [] where field.value.string == id { identities = identities.removing(field.key) }; return connection.setting("identities", identities) }
        do { try flush(); try instructions.remove(id + ".md") } catch { (agents, connections) = before; throw error }; await changed()
    }
    public func stop() throws { if loaded, persistence.ownership != .readOnly { try flush() } }
    private func view(_ agent: NativeRPCValue) throws -> NativeRPCValue {
        guard persistence.ownership != .memory, let id = agent["id"].string else { return agent.setting("instructionsFile", .null) }
        let path = try instructions.file(id + ".md")
        guard FileManager.default.fileExists(atPath: path.path) else { return agent.setting("instructionsFile", .null) }
        let fd = Darwin.open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NativeRPCError(code: "instructions-unreadable", message: "The agent's instructions file could not be read") }; defer { Darwin.close(fd) }
        var buffer = [UInt8](repeating: 0, count: 128_001), done = 0
        while done < buffer.count { let read = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: done), $0.count - done) }; if read == 0 { break }; if read < 0 { if errno == EINTR { continue }; throw NativeRPCError.malformed("Agent instruction read failed") }; done += read }
        guard done <= 128_000 else { throw NativeRPCError.malformed("Agent instructions are too large") }
        let text = String(decoding: buffer.prefix(done), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf16.count <= 32_000 else { throw NativeRPCError.malformed("Agent instructions are longer than 32000 characters") }
        return text.isEmpty ? agent.setting("instructionsFile", .null) : agent.setting("instructions", .string(text)).setting("instructionsFile", .string(path.path))
    }
    public func saveConnection(_ keyID: String, input: NativeRPCValue) async throws -> NativeRPCValue {
        try started(); try persistence.writable(); guard !keyID.isEmpty else { throw NativeRPCError.invalidArguments("Choose an access key first.") }
        let index = connections.firstIndex { $0["keyId"].string == keyID }
        var row = index.map { connections[$0] } ?? BackendTaskValues.object([("keyId", .string(keyID)), ("name", .null), ("enabled", .bool(false)), ("eventsUrl", .null), ("eventsSecret", .null), ("statuses", Self.defaultStatuses), ("hootIdentity", .null), ("identities", .object([])), ("allowedSenders", .array([])), ("folders", .array([])), ("maxHops", .number(3))])
        for (key, label, limit) in [("name", "The CRM name", 60), ("eventsUrl", "The events address", 2_048), ("hootIdentity", "The Hoot identity", 200)] where input.has(key) {
            let value = try BackendTaskValues.text(input[key], label, max: limit)
            if key == "eventsUrl", let value, !value.isEmpty {
                // notify-webhook.ts webhookUrlProblem
                guard let url = URL(string: value), url.scheme != nil, url.host != nil else { throw NativeRPCError.invalidArguments("That is not a web address.") }
                guard url.user == nil, url.password == nil else { throw NativeRPCError.invalidArguments("Leave the user name and password out of the address.") }
                guard url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host ?? "")) else { throw NativeRPCError.invalidArguments("Use an https:// address. Plain http:// is only allowed to this Mac (localhost).") }
            }; row = row.setting(key, value == nil || value == "" ? .null : .string(value!))
        }
        if input.has("enabled") { row = row.setting("enabled", .bool(input["enabled"].bool == true)) }
        if input.has("statuses") {
            let settings = input["statuses"], list = try BackendTaskValues.strings(settings["statuses"], label: "The statuses", maximum: 20, length: 60)
            guard !list.isEmpty else { throw NativeRPCError.invalidArguments("Name at least one status.") }
            var statuses = BackendTaskValues.object([("statuses", .array(list.map(NativeRPCValue.string)))])
            for (key, label) in [("initial", "The initial status"), ("completed", "The completed status"), ("onStarted", "The status on start"), ("onVerified", "The status on a verified completion"), ("onBlocked", "The status when blocked")] {
                if ["onStarted", "onVerified", "onBlocked"].contains(key), settings[key].isNullish || settings[key].string == "" { statuses = statuses.setting(key, .null); continue }
                guard let value = settings[key].string, list.contains(value) else { throw NativeRPCError.invalidArguments("\(label) has to be one of: \(list.joined(separator: ", ")).") }; statuses = statuses.setting(key, .string(value))
            }; row = row.setting("statuses", statuses)
        }
        if input.has("identities") {
            var map = NativeRPCValue.object([])
            for field in input["identities"].fields ?? [] {
                let identity = try BackendTaskValues.text(.string(field.key), "A CRM identity", max: 200, required: true)!
                guard let id = field.value.string, agents.contains(where: { $0["id"].string == id }) else { throw NativeRPCError.invalidArguments("\(identity) points at an agent that does not exist.") }; map = map.setting(identity, .string(id))
            }; row = row.setting("identities", map)
        }
        for key in ["allowedSenders", "folders"] where input.has(key) {
            let list = try BackendTaskValues.strings(input[key], label: key == "folders" ? "The folders" : "The allowed senders", maximum: 20, length: key == "folders" ? 1_024 : 200)
            if key == "folders", let folder = list.first(where: { !$0.hasPrefix("/") || $0.contains("\0") }) { throw NativeRPCError.invalidArguments("\(folder) is not a full folder path.") }; row = row.setting(key, .array(list.map(NativeRPCValue.string)))
        }
        if input.has("maxHops") { row = row.setting("maxHops", .number(Double(try BackendTaskValues.whole(input["maxHops"], label: "Hand-offs", min: 1, max: 5, fallback: 3)))) }
        if let hoot = row["hootIdentity"].string, row["identities"].has(hoot) { throw NativeRPCError.invalidArguments("The Hoot identity cannot also be an agent’s identity.") }
        var secret: String?
        if row["eventsSecret"].isNullish || input["rotateSecret"].bool == true {
            var random = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw NativeRPCError(code: "entropy", message: "macOS could not create a private task events signing secret") }
            secret = "whsec_" + Data(random).base64EncodedString(); row = row.setting("eventsSecret", .string(secret!))
        }
        let before = connections; if let index { connections[index] = row } else { connections.append(row) }
        do { try flush() } catch { connections = before; throw error }; await changed()
        return BackendTaskValues.object([("view", row.removing("eventsSecret").setting("hasEventsSecret", .bool(!row["eventsSecret"].isNullish))), ("secret", secret.map(NativeRPCValue.string) ?? .null)])
    }
    public func removeConnection(_ keyID: String) async throws {
        try started(); try persistence.writable(); guard connections.contains(where: { $0["keyId"].string == keyID }) else { throw NativeRPCError.invalidArguments("That connection no longer exists.") }
        let before = connections; connections.removeAll { $0["keyId"].string == keyID }
        do { try flush() } catch { connections = before; throw error }; await changed()
    }
    public nonisolated static var defaultStatuses: NativeRPCValue { BackendTaskValues.object([("statuses", .array(BackendTaskLocalService.statuses.map(NativeRPCValue.string))), ("initial", .string("To-Do")), ("completed", .string("Done")), ("onStarted", .string("Working on it")), ("onVerified", .string("Done")), ("onBlocked", .string("Stuck"))]) }
    private func started() throws { guard loaded else { throw NativeRPCError(code: "not-started", message: "Task settings have not been opened") } }
    private func flush() throws { try persistence.write("task-config.json", value: BackendTaskValues.object([("v", .number(1)), ("agents", .array(agents.map { $0.removing("instructionsFile") })), ("connections", .array(connections))])) }
}
