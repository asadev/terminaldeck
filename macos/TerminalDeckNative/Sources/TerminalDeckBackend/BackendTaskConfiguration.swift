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
    /// Ids of saved agents that did not read and were left out at start; nil when one of them had no readable id.
    private var unreadAgentIDs: Set<String>? = []
    /// U1: agents were left out at start and not even a copy of task-config.json could be kept; nothing is saved over it.
    private var configBlocked: String?
    private let changed: @Sendable () async -> Void
    private let importWatchers = BackendRoutinesFileWatchers()
    private var importStops: [String: @Sendable () -> Void] = [:]
    private var importWatching = true
    private var importGeneration: UInt64 = 0
    private var importSelections: [String: Set<String>] = [:]
    private var agsStore: BackendAGSStore?
    private var savingAGS = false
    private var agsWaiters: [CheckedContinuation<Void, Never>] = []
    private var agsFailure: NativeRPCError?
    private var profileChangePlans: [String: NativeRPCValue] = [:]
    private var canonicalToolIDs: (@Sendable () async -> Set<String>)?
    public func setToolUseCatalogue(_ read: @escaping @Sendable () async -> Set<String>) { canonicalToolIDs = read }
    private func checkToolUseChange(_ next: NativeRPCValue, previous: NativeRPCValue) async throws {
        try ToolUseRestrictions.validateChange(next, previous: previous)
        guard !next.isNullish, !ToolUseRestrictions.equal(next, previous), let read = canonicalToolIDs else { return }
        let known = await read()
        guard try ToolUseRestrictions(next).rules.allSatisfy({ known.contains($0.tool) }) else {
            throw NativeRPCError.invalidArguments("Choose an exact canonical tool ID from Deck's current tool catalogue; aliases and unknown tools cannot be saved as rules.")
        }
    }
    private let creatorHistoryURL: URL
    /// The CRM events signing secrets, one per connection; task-config.json keeps only that there is one (#340).
    private let secrets: any BackendConnectedTasksSecrets
    public init(persistence: BackendTaskPersistence, creatorHistoryURL: URL? = nil, secrets: any BackendConnectedTasksSecrets = BackendConnectedTasksMemorySecrets(),
                changed: @escaping @Sendable () async -> Void = {}) throws {
        self.persistence = persistence; self.changed = changed; self.secrets = secrets
        self.creatorHistoryURL = creatorHistoryURL ?? persistence.directory.deletingLastPathComponent().appendingPathComponent("hoot-log/actions.jsonl")
        instructions = try BackendTaskPersistence(directory: persistence.directory.appendingPathComponent("agent-instructions"), ownership: persistence.ownership)
    }
    public func start() throws {
        guard !loaded else { return }
        if let raw = try persistence.read("task-config.json") {
            guard raw["v"].number == 1 else { throw NativeRPCError.malformed("Unsupported task-config.json version") }
            // task-config.ts load: every stored agent cleaned as a save would clean it; one that no longer reads is
            // skipped, and a status or effort that no longer reads (an old "ultracode" on an agent that cannot take
            // it) costs the agent that setting, not the agent nor every other one. Normalised in memory only; the
            // stored bytes are rewritten only by a real change, and (U1) only after a .damaged copy keeps them.
            var cleaned: [NativeRPCValue] = [], lost = false, unread: Set<String>? = []
            for entry in raw["agents"].elements ?? [] {
                var input = entry
                if entry.fields != nil, case .failure = Self.lifecycleOf(entry) { input = entry.removing("status").removing("statusAt"); lost = true }
                if let agent = try? Self.cleanAgent(input, others: cleaned) { cleaned.append(agent); continue }
                lost = true
                if !input["effort"].isNullish, let agent = try? Self.cleanAgent(input.removing("effort"), others: cleaned) { cleaned.append(agent); continue }
                if let id = entry["id"].string?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !id.isEmpty { unread?.insert(id) } else { unread = nil }
            }
            if lost, (try? persistence.file("task-config.json")).flatMap({ DamagedFile.keepCopy(of: $0) }) == nil {
                configBlocked = DamagedFile.sentence("The saved task agents", copy: nil)
            }
            unreadAgentIDs = unread
            // Attribution is repaired in memory; the action log is never written.
            let history = (try? BackendAGOPTProfileCreators.rows(at: creatorHistoryURL)) ?? []
            agents = cleaned.map { BackendAGOPTProfileCreators.backfill($0, rows: history) }
            for plan in (raw["profileChangePlans"].elements ?? []).prefix(50) {
                guard let id = plan["planId"].string, plan["keyId"].string != nil, plan["entries"].elements != nil,
                      profileChangePlans[id] == nil else { continue }
                profileChangePlans[id] = plan
            }
            connections = raw["connections"].elements ?? []
            // #340: a signing secret still written in the file moves to the secret store, and the
            // file keeps only that there is one. One that cannot be moved stays where it was.
            var movedSecrets = false
            connections = connections.map { row in
                guard let secret = row["eventsSecret"].string, let keyID = row["keyId"].string,
                      (try? secrets.write(Self.eventsSecretID(keyID), token: secret)) != nil else { return row }
                movedSecrets = true; return row.removing("eventsSecret").setting("hasEventsSecret", .bool(true))
            }
            importSelections = try Self.readImportSelections(raw["agentImportSelections"])
            // After the connections, so the rewrite carries them too. A rewrite that fails keeps what was read.
            let movedInstructions = moveInstructionsToFiles()
            if movedInstructions || movedSecrets { try? flush() }
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
        let blockedTools = try textList(input["blockedTools"], "Blocked tools", max: 200, maxLength: 200)
        let skillsOff = input["skillsOff"].bool == true
        if SourceNamespace.agentSettingsEnabled {
            if !blockedTools.isEmpty { try BackendAGSValidation.check(AGSAgentSettings(provider: provider.string ?? "claude", deniedTools: blockedTools)) }
            if !blockedTools.isEmpty && !AGSCapabilities.providers.contains(provider.string ?? "claude") {
                throw NativeRPCError.invalidArguments("Choose a supported coding agent for tool restrictions.")
            }
            if skillsOff && !Capabilities.enforces(provider.string, setting: .skillsOff) {
                throw NativeRPCError.invalidArguments("Only Claude Code can turn every skill off. Clear it, or choose Claude Code.")
            }
        } else {
            if let odd = blockedTools.first(where: { !BackendSharedAgentTools.isToolName($0) }) {
                throw NativeRPCError.invalidArguments("\(odd) is not a tool name that can be blocked.")
            }
            if (!blockedTools.isEmpty && !Capabilities.enforces(provider.string, setting: .blockedTools)) || (skillsOff && !Capabilities.enforces(provider.string, setting: .skillsOff)) {
                throw NativeRPCError.invalidArguments("Only Claude Code can block tools or turn skills off. Clear them, or choose Claude Code.")
            }
        }
        let lifecycle: (status: String, statusAt: Double?)
        switch lifecycleOf(input) { case .success(let value): lifecycle = value; case .failure(let problem): throw NativeRPCError.invalidArguments(problem.sentence) }
        let role = try optionalText(input["role"], "The role", max: 4_000), account = try optionalText(input["account"], "The account", max: 80)
        let model = try optionalText(input["model"], "The model", max: 80), effort = try optionalText(input["effort"], "The effort", max: 20)
        if let level = effort.string {
            if SourceNamespace.agentSettingsEnabled {
                if level != "auto", !AGSCapabilities.efforts(provider: provider.string ?? "claude").contains(level) {
                    throw NativeRPCError.invalidArguments("That effort is not supported by the selected coding agent. The effort has to be one of: \((["auto"] + AGSCapabilities.efforts(provider: provider.string ?? "claude")).joined(separator: ", ")).")
                }
            } else if !EFFORT_CHOICES.contains(where: { $0.id == level }) {
                throw NativeRPCError.invalidArguments("The effort has to be one of: \(EFFORT_CHOICES.map(\.id).joined(separator: ", ")).")
            }
        }
        let instructions = try optionalText(input["instructions"], "The instructions", max: 32_000)
        let preferred = try textList(input["toolsPreferred"], "Tools to prefer", max: 30, maxLength: 80), avoided = try textList(input["toolsAvoided"], "Tools to avoid", max: 30, maxLength: 80)
        let skills = try textList(input["skills"], "The skills", max: 20, maxLength: 80)
        let concurrent = try whole(input["maxConcurrent"], "Tasks at once", min: 0, max: 5, fallback: 0)   // 0: no limit
        // Defaults from the one place (TasksLimits): no run limit, keep open 60 minutes.
        let runMinutes = try whole(input["maxRunMinutes"], "Longest run", min: 0, max: 1_440, fallback: TasksLimits.defaultRunMinutes)
        let keepAlive = try whole(input["keepAliveMinutes"], "Keep open", min: 0, max: 1_440, fallback: TasksLimits.defaultKeepAliveMinutes)
        let verify = try optionalText(input["verifyCommand"], "The check command", max: 500)
        return try BackendTaskValues.object([("id", .string(id)), ("name", .string(name)), ("role", role.string.map(NativeRPCValue.string) ?? .string("general")), ("provider", provider),
            ("account", account), ("model", model), ("effort", effort), ("instructions", instructions), ("instructionsFile", .null),
            ("toolsPreferred", .array(preferred.map(NativeRPCValue.string))), ("toolsAvoided", .array(avoided.map(NativeRPCValue.string))), ("skills", .array(skills.map(NativeRPCValue.string))),
            ("blockedTools", .array(blockedTools.map(NativeRPCValue.string))), ("skillsOff", .bool(skillsOff)), ("maxConcurrent", concurrent), ("maxRunMinutes", runMinutes),
            ("keepAliveMinutes", keepAlive), ("verifyCommand", verify), ("status", .string(lifecycle.status)), ("statusAt", lifecycle.statusAt.map(NativeRPCValue.number) ?? .null)] + BackendTAGAgentProfile.fields(input, provider: provider.string))
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
    public func allAgents() async throws -> [NativeRPCValue] { try await waitForAGS(); try started(); return try agents.map(view) }
    /// Every agent id in the saved file, including agents left out at start because they did not read (U1):
    /// nil when one of those had no readable id, so nobody can say which agents are really gone.
    public func savedAgentIDs() async throws -> Set<String>? {
        try await waitForAGS(); try started()
        return unreadAgentIDs.map { $0.union(agents.compactMap { $0["id"].string }) }
    }
    public func agent(_ nameOrID: String) async throws -> NativeRPCValue? {
        try await waitForAGS()
        try started(); let wanted = nameOrID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return try agents.first { $0["id"].string == wanted || $0["name"].string?.lowercased() == wanted }.map(view)
    }
    public func connection(_ keyID: String) throws -> NativeRPCValue? { try started(); return connections.first { $0["keyId"].string == keyID } }
    public func connectionViews() throws -> [NativeRPCValue] { try started(); return connections.map(Self.connectionView) }
    /// The CRM events signing secret, read from the secret store (or from a row it could not be moved out of yet).
    public func eventsSecret(_ keyID: String) throws -> String? {
        try started()
        guard let row = connections.first(where: { $0["keyId"].string == keyID }) else { return nil }
        if let secret = row["eventsSecret"].string { return secret }
        return row["hasEventsSecret"].bool == true ? try secrets.read(Self.eventsSecretID(keyID)) : nil
    }
    static func eventsSecretID(_ keyID: String) -> String { "crm-events-" + keyID }
    private static func hasEventsSecret(_ row: NativeRPCValue) -> Bool { row["hasEventsSecret"].bool == true || !row["eventsSecret"].isNullish }
    private static func connectionView(_ row: NativeRPCValue) -> NativeRPCValue { row.removing("eventsSecret").setting("hasEventsSecret", .bool(hasEventsSecret(row))) }
    /// Apply one skill selection to the actor-current profile after approval.
    public func setROUTINESSkill(id: String, skill: String, assigned: Bool, projectRoot: String? = nil) async throws -> NativeRPCValue {
        try await setROUTINESSkillGuarded(id: id, skill: skill, assigned: assigned, projectRoot: projectRoot, beforeWrite: {})
    }
    public func setROUTINESSkillGuarded(id: String, skill: String, assigned: Bool, projectRoot: String? = nil,
                                      beforeWrite: @escaping @Sendable () async throws -> Void) async throws -> NativeRPCValue {
        try await waitForAGS(); try await beforeWrite()
        guard !savingAGS else { throw NativeRPCError(code: "busy", message: "The agent's settings are saving. Try again when they finish.") }
        try started(); try persistence.writable()
        guard let index = agents.firstIndex(where: { $0["id"].string == id }) else { throw NativeRPCError.invalidArguments("That saved agent no longer exists.") }
        let current = agents[index]
        if let projectRoot {
            guard let folder = current["defaultProject"].string,
                  TaskProjects.within(URL(fileURLWithPath: folder).resolvingSymlinksInPath().path, URL(fileURLWithPath: projectRoot).resolvingSymlinksInPath().path) else {
                throw NativeRPCError(code: "not-granted", message: "The agent moved outside this session's project.")
            }
        }
        let checked = try Self.text(.string(skill), "The skill", max: 80)
        let next = ROUTINESSkillsRules.changing(current, skill: checked, assigned: assigned)
        _ = try Self.textList(next["skills"], "The skills", max: 20, maxLength: 80)
        if current == next { return try view(current) }
        agents[index] = next
        do { try flush() } catch { agents[index] = current; throw error }
        let result = try view(next); await changed(); return result
    }
    /// L4-AGENTS: set by the app; a new agent (or a removed one) has any run history under its id retired, so a
    /// new hire with a name used before starts with no runs of the agent that had that id.
    private var retireHistory: (@Sendable (String) async -> Void)?
    public func setHistoryRetirement(_ retire: (@Sendable (String) async -> Void)?) { retireHistory = retire }
    /// L4-AGENTS: told after an agent is removed for good (a project it led then gets no lead).
    private var agentRemoved: (@Sendable (String) async -> Void)?
    public func setAgentRemoved(_ removed: (@Sendable (String) async -> Void)?) { agentRemoved = removed }
    private func retireIfNew(_ input: NativeRPCValue) async {
        guard let id = input["id"].string, !id.isEmpty, !agents.contains(where: { $0["id"].string == id }) else { return }
        await retireHistory?(id)
    }
    public func saveAgent(_ originalInput: NativeRPCValue, keyMutation: Bool = false) async throws -> NativeRPCValue {
        try await waitForAGS()
        await retireIfNew(originalInput)
        // AGT: keep icon/reports-to through saves that do not mention them; refuse a loop.
        try await checkToolUseChange(originalInput["toolUseRestrictions"], previous: agents.first { $0["id"] == originalInput["id"] }?["toolUseRestrictions"] ?? .missing)
        let rawInput = BackendAGTOrg.carry(originalInput, existing: agents.first { $0["id"] == originalInput["id"] })
        try BackendAGTOrg.check(rawInput, agents: agents)
        let input = BackendTAGProfilePolicy.ownershipForSave(rawInput, existing: agents.first { $0["id"] == rawInput["id"] }, keyMutation: keyMutation)
        if let store = agsStore {
            let id = input["id"].string ?? ""
            if !input["ags"].isNullish {
                let settings = try BackendAGSCodec.decode(AGSAgentSettings.self, input["ags"])
                let expected = try BackendAGSMCP.expectedRevision(input.setting("revision", input["agsRevision"]))
                return try await saveAgentWithAGS(input.removing("ags").removing("agsRevision"), settings: settings, expectedRevision: expected, keyMutation: keyMutation)
            }
            if AGSCapabilities.providers.contains(input["provider"].string ?? "claude") {
                let previous = id.isEmpty ? nil : try await store.profile(id)
                let projection = try BackendAGSProfileProjection.settings(input, defaultProvider: previous?.provider ?? "claude")
                var next = previous ?? projection
                next.provider = projection.provider; next.model = projection.model; next.effort = projection.effort
                next.permissionMode = projection.permissionMode; next.allowedTools = projection.allowedTools
                next.deniedTools = projection.deniedTools; next.workingFolder = projection.workingFolder; next.keepOpen = projection.keepOpen
                return try await saveAgentWithAGS(input, settings: next, expectedRevision: try await store.currentRevision(), keyMutation: keyMutation)
            }
        }
        try started(); try persistence.writable()
        // What a save carries about status is not read at all: it is kept below.
        let cleaned = try Self.cleanAgent(input.fields == nil ? input : input.removing("status").removing("statusAt"), others: agents)
        let id = cleaned["id"].string ?? "", index = agents.firstIndex { $0["id"].string == id }
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
    /// Compare against the actor's current profile and mutate before the first
    /// suspension, so stale key edits cannot remove a newer owner/key block.
    public func saveAgentNarrowed(_ input: NativeRPCValue, inheritedPermissionMode: String = "default", callerKeyID: String? = nil) async throws -> NativeRPCValue {
        try await waitForAGS(); try started()
        let existing: NativeRPCValue?
        if let id = input["id"].string { existing = try await agent(id) } else { existing = nil }
        // A NEW agent from a caller with no key (Hoot, a task or lead session) is a hire, saved as the New Agent
        // screen saves it; only a key's first values and existing agents follow the narrow-only rules below.
        if existing == nil, callerKeyID == nil, input["id"].string != nil {
            let saved = try await saveAgentsAsCaller(request: .object([.init("do", .string("save")), .init("agent", input)]), inheritedPermissionMode: inheritedPermissionMode)
            guard let first = saved.first else { throw NativeRPCError(code: "save-failed", message: "The new agent was not saved.") }
            return first
        }
        let narrowed = try BackendTAGProfilePolicy.validate(input: input, existing: existing, inheritedPermissionMode: inheritedPermissionMode, callerKeyID: callerKeyID)
        let first = BackendTAGProfilePolicy.hasInitialSelection(input: narrowed, existing: existing, callerKeyID: callerKeyID)
        if let store = agsStore, let id = input["id"].string {
            guard existing != nil || callerKeyID != nil else { throw NativeRPCError(code: "owner-required", message: "A key may only narrow an existing owner task profile.") }
            let owner = try await store.profile(id) ?? BackendAGSProfileProjection.settings(existing ?? narrowed, defaultProvider: (existing ?? narrowed)["provider"].string ?? "claude")
            var next = owner
            let projection = try BackendAGSProfileProjection.settings(narrowed, defaultProvider: owner.provider)
            next.model = projection.model; next.effort = projection.effort; next.permissionMode = projection.permissionMode
            next.allowedTools = projection.allowedTools; next.deniedTools = projection.deniedTools
            next.workingFolder = projection.workingFolder; next.keepOpen = projection.keepOpen
            if !first, owner.permissionMode == nil || owner.permissionMode == "default", next.permissionMode != owner.permissionMode {
                throw NativeRPCError(code: "not-permitted", message: "The owner's inherited permission mode must be resolved before a key can change it.")
            }
            let defaults = try await store.defaults().providers[owner.provider]
            if !first { try BackendAGSPolicy.requireNarrowing(BackendAGSPolicy.resolve(defaults: defaults, profile: next), owner: BackendAGSPolicy.resolve(defaults: defaults, profile: owner)) }
            return try await saveAgentWithAGS(narrowed, settings: next, expectedRevision: try await store.currentRevision(), narrowOnly: true, inheritedPermissionMode: inheritedPermissionMode, keyMutation: true, callerKeyID: callerKeyID)
        }
        return try await saveAgent(narrowed, keyMutation: true)
    }
    /// Hoot, a task agent's session or a lead's session: callers with no key (Asad, 11 Oct: Hoot has full control of
    /// the app except its own settings, and every AI gets the same tools). The request has already passed the
    /// caller's task grant and the one consent its permission mode decides (one card for the whole request).
    /// A NEW agent is saved exactly as the New Agent screen saves it: every field the screen offers. An EXISTING agent
    /// keeps the narrow-only rules (restrict freely; widening it is refused: it needs the owner in the app), unless
    /// `ownerMode`: Hoot, or a project's lead for its own project, changes an existing agent as the owner would on its
    /// settings page, widening included (Asad, 12 Oct: Hoot has full control except its own settings). All or nothing:
    /// every agent is checked first, then all are published together. `dryRun` checks and returns the rows, writing nothing.
    public func saveAgentsAsCaller(request: NativeRPCValue, inheritedPermissionMode: String = "default", dryRun: Bool = false, ownerMode: Bool = false) async throws -> [NativeRPCValue] {
        try await waitForAGS(); try started()
        if !dryRun { try persistence.writable() }
        let changes = try requestedChanges(request)
        let checked = try await callerRows(changes, inheritedPermissionMode: inheritedPermissionMode, ownerMode: ownerMode)
        if dryRun { return checked.rows }
        // A new hire with an id used before starts with no runs of the agent that had it (as a single save does).
        for id in checked.created { await retireHistory?(id) }
        let fresh = try await callerRows(changes, inheritedPermissionMode: inheritedPermissionMode, ownerMode: ownerMode)
        try await publishAgentRows(fresh.rows, expectedAgents: fresh.before, nextPlans: profileChangePlans, enforceNarrowing: !ownerMode,
                                   callerKeyID: "", inheritedPermissionMode: inheritedPermissionMode)
        return try fresh.rows.compactMap { row in try agents.first { $0["id"] == row["id"] }.map(view) }
    }
    private func callerRows(_ changes: [(id: String, patch: NativeRPCValue)], inheritedPermissionMode: String, ownerMode: Bool = false) async throws -> (rows: [NativeRPCValue], created: [String], before: [NativeRPCValue]) {
        try started()
        var rows: [NativeRPCValue] = [], created: [String] = []
        var owners: [String: AGSAgentSettings] = [:]
        // The AGS reads suspend; every check below runs on one picture of the agents, read after them.
        if let store = agsStore {
            for (id, _) in changes { if let settings = try await store.profile(id) { owners[id] = settings } }
        }
        let before = agents
        for (id, patch) in changes {
            guard let fields = patch.fields else { throw NativeRPCError.invalidArguments("Each agent has to be an object of its fields.") }
            let existing = try before.first { $0["id"].string == id }.map(view)
            var clean = NativeRPCValue.object([])
            for field in fields {
                if BackendAGOPTProfileChanges.protectedFields.contains(field.key) || field.key == "instructionsFile" {
                    guard field.value == existing?[field.key] || field.value.isNullish && (existing?[field.key].isNullish ?? true) else {
                        throw NativeRPCError(code: "not-permitted", message: "Profile ownership, imported source and private settings cannot be changed by this request.")
                    }
                    continue
                }
                guard BackendAGOPTProfileChanges.editableFields.contains(field.key) else {
                    throw NativeRPCError.invalidArguments("\(field.key) is not an agent field. Fields: " + BackendAGOPTProfileChanges.editableFields.subtracting(["id"]).sorted().joined(separator: ", ") + ".")
                }
                clean = clean.setting(field.key, field.value)
            }
            clean = clean.setting("id", .string(id))
            var row: NativeRPCValue
            if let existing, ownerMode {
                // Hoot or the project's lead: the change the owner could make on the agent's settings page, widening included.
                let owned = BackendTAGProfilePolicy.ownershipForSave(existing.merging(clean), existing: existing, keyMutation: false)
                row = try Self.cleanAgent(owned.removing("status").removing("statusAt"), others: before)
                row = row.setting("status", existing["status"].isNullish ? .string("active") : existing["status"]).setting("statusAt", existing["statusAt"])
            } else if let existing {
                // Unchanged rules for an agent that exists: restrict freely; widening needs the owner in the app.
                let narrowed = try BackendTAGProfilePolicy.validate(input: clean, existing: existing, inheritedPermissionMode: inheritedPermissionMode)
                let owned = BackendTAGProfilePolicy.ownershipForSave(narrowed, existing: existing, keyMutation: true)
                row = try Self.cleanAgent(owned.removing("status").removing("statusAt"), others: before)
                row = row.setting("status", existing["status"].isNullish ? .string("active") : existing["status"]).setting("statusAt", existing["statusAt"])
                if agsStore != nil, AGSCapabilities.providers.contains(row["provider"].string ?? "claude") {
                    let owner = try owners[id] ?? BackendAGSProfileProjection.settings(existing, defaultProvider: existing["provider"].string ?? "claude")
                    let next = try BackendAGSProfileProjection.settings(row, defaultProvider: owner.provider)
                    if owner.permissionMode == nil || owner.permissionMode == "default", next.permissionMode != owner.permissionMode {
                        throw NativeRPCError(code: "not-permitted", message: "The owner's inherited permission mode must be resolved before it can be changed here.")
                    }
                }
            } else {
                // A hire: what the New Agent screen saves, field for field (no key owns it; the owner does).
                let owned = BackendTAGProfilePolicy.ownershipForSave(clean, existing: nil, keyMutation: false)
                row = try Self.cleanAgent(owned, others: before)
                created.append(id)
            }
            try Self.checkSupported(row)
            rows.append(row)
        }
        // Names stay unique and reports-to has no loops across the whole request (an agent may report to another new one).
        var prospective = before
        for row in rows {
            if let index = prospective.firstIndex(where: { $0["id"] == row["id"] }) { prospective[index] = row } else { prospective.append(row) }
        }
        for row in rows { _ = try Self.cleanAgent(row, others: prospective); try BackendAGTOrg.check(row, agents: prospective) }
        return (rows, created, before)
    }
    public func bindAGS(_ store: BackendAGSStore) throws {
        guard agsStore == nil, !savingAGS else { throw NativeRPCError(code: "composition-conflict", message: "Agent settings already have a canonical profile owner.") }
        agsStore = store
    }
    public func saveSettingsForProfile(_ id: String, settings: AGSAgentSettings, expectedRevision: UInt64,
                                       narrowOnly: Bool = false, inheritedPermissionMode: String = "default") async throws -> NativeRPCValue {
        guard let current = try await agent(id), current["status"].string == "active" else {
            throw NativeRPCError(code: "unavailable", message: "Choose an active existing task profile before changing its settings.")
        }
        return try await saveAgentWithAGS(current, settings: settings, expectedRevision: expectedRevision,
            narrowOnly: narrowOnly, inheritedPermissionMode: inheritedPermissionMode)
    }
    private func waitForAGS() async throws {
        try Task.checkCancellation()
        if let failure = agsFailure { throw failure }
        try Task.checkCancellation()
        if savingAGS { await withCheckedContinuation { agsWaiters.append($0) } }
        if let failure = agsFailure { throw failure }
    }
    private func releaseAGSBarrier() {
        savingAGS = false
        let waiters = agsWaiters; agsWaiters = []
        waiters.forEach { $0.resume() }
    }
    /// Both owned records, plus the existing instructions file, publish under
    /// this actor's claim barrier. Cache/events publish only after disk success.
    public func saveAgentWithAGS(_ originalInput: NativeRPCValue, settings: AGSAgentSettings, expectedRevision: UInt64,
                                 narrowOnly: Bool = false, inheritedPermissionMode: String = "default", keyMutation: Bool = false, callerKeyID: String? = nil) async throws -> NativeRPCValue {
        try await waitForAGS(); try started(); try persistence.writable()
        await retireIfNew(originalInput)
        try await checkToolUseChange(originalInput["toolUseRestrictions"], previous: agents.first { $0["id"] == originalInput["id"] }?["toolUseRestrictions"] ?? .missing)
        let input = BackendAGTOrg.carry(originalInput, existing: agents.first { $0["id"] == originalInput["id"] }) // AGT
        try BackendAGTOrg.check(input, agents: agents)
        guard let store = agsStore else { throw NativeRPCError(code: "unavailable", message: "The combined agent profile save is not installed.") }
        try BackendAGSValidation.check(settings)
        let ownershipInput = BackendTAGProfilePolicy.ownershipForSave(input, existing: agents.first { $0["id"] == input["id"] }, keyMutation: keyMutation)
        var proposal = ownershipInput.removing("ags").removing("agsRevision")
            .setting("provider", .string(settings.provider)).setting("model", settings.model.map(NativeRPCValue.string) ?? .null)
            .setting("effort", settings.effort.map(NativeRPCValue.string) ?? .null)
            .setting("permissionMode", settings.permissionMode.map(NativeRPCValue.string) ?? .null)
            .setting("allowedTools", settings.allowedTools.map { .array($0.map(NativeRPCValue.string)) } ?? .null)
            .setting("blockedTools", .array(settings.deniedTools.map(NativeRPCValue.string)))
            .setting("defaultProject", settings.workingFolder.map(NativeRPCValue.string) ?? .null)
            .setting("keepAliveUntilClose", .bool(settings.keepOpen))
        let existing = agents.first { $0["id"] == proposal["id"] }
        if narrowOnly { proposal = try BackendTAGProfilePolicy.validate(input: proposal, existing: existing, inheritedPermissionMode: inheritedPermissionMode, callerKeyID: callerKeyID, trustedOwnership: keyMutation) }
        let initial = BackendTAGProfilePolicy.hasInitialSelection(input: proposal, existing: existing, callerKeyID: callerKeyID)
        let clean = try Self.cleanAgent(proposal.removing("status").removing("statusAt"), others: agents)
        let id = try clean["id"].requireString("agent id", nonempty: true)
        var row = clean.setting("status", existing?["status"] ?? .string("active")).setting("statusAt", existing?["statusAt"] ?? .null)
        try Self.checkSupported(row)
        try savable()
        let beforeConfig = try persistence.readOwnedBytes("task-config.json")
        let beforeInstructions = try instructions.readOwnedBytes(id + ".md", maximumBytes: 128_000)
        savingAGS = true
        defer { if savingAGS { releaseAGSBarrier() } }
        let prepared: BackendAGSProfileTransaction
        do {
            if narrowOnly && !initial {
                let owner = try await store.profile(id) ?? BackendAGSProfileProjection.settings(try view(existing ?? clean), defaultProvider: settings.provider)
                let defaults = try await store.defaults().providers[owner.provider]
                try BackendAGSPolicy.requireNarrowing(BackendAGSPolicy.resolve(defaults: defaults, profile: settings), owner: BackendAGSPolicy.resolve(defaults: defaults, profile: owner))
            }
            prepared = try await store.prepareProfileTransaction(id, settings: settings, expectedRevision: expectedRevision)
        } catch { throw error }
        do {
            try Task.checkCancellation()
            if persistence.ownership != .memory {
                if let text = row["instructions"].string, !text.isEmpty { try instructions.writeBytes(id + ".md", data: Data((text + "\n").utf8)) }
                else { try instructions.remove(id + ".md") }
                row = row.setting("instructions", .null)
            }
            var next = agents
            if let index = next.firstIndex(where: { $0["id"].string == id }) { next[index] = row } else { next.append(row) }
            try persistence.write("task-config.json", value: BackendTaskValues.object([("v", .number(1)), ("agents", .array(next.map { $0.removing("instructionsFile") })), ("connections", .array(connections)), ("agentImportSelections", importSelectionsWire), ("profileChangePlans", .array(profileChangePlans.keys.sorted().compactMap { profileChangePlans[$0] }))]))
            try prepared.publish()
            try await store.finishProfileTransaction(prepared)
            agents = next
        } catch {
            do {
                try prepared.restore()
                if let beforeConfig { try persistence.writeBytes("task-config.json", data: beforeConfig) } else { try persistence.remove("task-config.json") }
                if let beforeInstructions { try instructions.writeBytes(id + ".md", data: beforeInstructions) } else { try instructions.remove(id + ".md") }
                try await store.cancelProfileTransaction(prepared)
            } catch {
                let failure = NativeRPCError(code: "settings-rollback-failed", message: "The combined agent profile save could not restore its original records. Task claims are paused until the owner recovers them.")
                agsFailure = failure; throw failure
            }
            throw error
        }
        releaseAGSBarrier()
        await store.announceProfileTransaction(); await changed()
        return try view(row)
    }
    public func setStatus(_ id: String, action: String) async throws -> NativeRPCValue {
        try await waitForAGS()
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
        where !value.isNullish && !(SourceNamespace.agentSettingsEnabled && AGSCapabilities.providers.contains(provider ?? "claude")) && !Capabilities.enforces(provider, setting: setting) {
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
        try await waitForAGS()
        try started(); try persistence.writable(); guard agents.contains(where: { $0["id"].string == id }) else { throw NativeRPCError.invalidArguments("That agent no longer exists.") }
        let before = (agents, connections); agents.removeAll { $0["id"].string == id }
        agents = BackendAGTOrg.clearReports(to: id, in: agents) // AGT: its reports become independent
        connections = connections.map { connection in var identities = connection["identities"]; for field in identities.fields ?? [] where field.value.string == id { identities = identities.removing(field.key) }; return connection.setting("identities", identities) }
        do { try flush(); try instructions.remove(id + ".md") } catch { (agents, connections) = before; throw error }; await changed()
        await retireHistory?(id)   // L4-AGENTS: its runs are kept for the totals, under a retired id
        await agentRemoved?(id)
    }
    /// Folder reads create/update profiles only; source files are never changed.
    /// Explicit import and event-driven re-sync share the same restrictions.
    public func importAgents(folder: String, narrowOnly: Bool = false, inheritedPermissionMode: String = "default", callerKeyID: String? = nil, options rawOptions: NativeRPCValue = .object([]), authorizeProject: (@Sendable (String) async throws -> Void)? = nil) async throws -> NativeRPCValue {
        try await importAgentsImpl(folder: folder, narrowOnly: narrowOnly, inheritedPermissionMode: inheritedPermissionMode, generation: nil, callerKeyID: callerKeyID, options: rawOptions, authorizeProject: authorizeProject)
    }
    /// A remembered partial choice must not be filled out by first-install import.
    public func hasAgentImportSelection(folder: String) throws -> Bool {
        try started()
        return importSelections[try BackendTAGAgentImport.directory(folder).path] != nil
    }
    private static func isStoredImportPath(_ path: String, directory: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return url.path == path && url.deletingLastPathComponent().path == directory && url.pathExtension.lowercased() == "md"
    }
    private static func readImportSelections(_ raw: NativeRPCValue) throws -> [String: Set<String>] {
        if raw.isNullish { return [:] }
        let fields = try raw.requireObject("saved agent import selections").fields ?? []
        var result: [String: Set<String>] = [:]
        for field in fields {
            let directory = URL(fileURLWithPath: field.key).standardizedFileURL
            guard field.key.hasPrefix("/"), !field.key.contains("\0"), directory.path == field.key,
                  directory.lastPathComponent == "agents", directory.deletingLastPathComponent().lastPathComponent == ".claude",
                  let entries = field.value.elements else {
                throw NativeRPCError.malformed("The saved agent file selection cannot be read safely.")
            }
            var paths = Set<String>()
            for entry in entries {
                guard let path = entry.string, isStoredImportPath(path, directory: field.key), paths.insert(path).inserted else {
                    throw NativeRPCError.malformed("The saved agent file selection contains an invalid or repeated path.")
                }
            }
            result[field.key] = paths
        }
        return result
    }
    private var importSelectionsWire: NativeRPCValue {
        .object(importSelections.keys.sorted().map { directory in
            .init(directory, .array((importSelections[directory] ?? []).sorted().map(NativeRPCValue.string)))
        })
    }
    private func rememberImportSelection(_ paths: Set<String>?, directory: String) throws {
        let before = importSelections
        importSelections[directory] = paths
        guard before != importSelections else { return }
        // Persist before the first profile save, so restart cannot import unchecked files.
        do { try flush() } catch { importSelections = before; throw error }
    }
    public func importPreview(folder: String, options: NativeRPCValue = .object([])) throws -> [String] {
        _ = try BackendTAGAgentImport.options(options.removing("selectedFiles"))
        let directory = try BackendTAGAgentImport.directory(folder)
        let selected = options.has("selectedFiles") ? try BackendPROJAgentBatches.selectedFiles(options["selectedFiles"], directory: directory) : nil
        // Build file URLs from the canonical directory: a listing of /var or /tmp reports /private paths.
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.lowercased().hasSuffix(".md") }.sorted()
            .map { directory.appendingPathComponent($0) }
            .filter { selected?.contains($0.path) ?? true }.compactMap { try BackendTAGAgentImport.read($0)?.shownName }
    }
    private func importAgentsImpl(folder: String, narrowOnly: Bool, inheritedPermissionMode: String, generation: UInt64?, callerKeyID: String? = nil, options rawOptions: NativeRPCValue = .object([]), authorizeProject: (@Sendable (String) async throws -> Void)? = nil) async throws -> NativeRPCValue {
        try await waitForAGS()
        try started(); try persistence.writable()
        try requireImportGeneration(generation)
        let directory = try BackendTAGAgentImport.directory(folder)
        // selectedFiles is a batch control, never a profile setting.
        let options = try BackendTAGAgentImport.options(rawOptions.removing("selectedFiles"))
        let allFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.lowercased().hasSuffix(".md") }.sorted()
            .map { directory.appendingPathComponent($0) }
        let selected: Set<String>?
        if generation != nil {
            guard directory.path == URL(fileURLWithPath: folder).standardizedFileURL.path else {
                throw NativeRPCError.invalidArguments("The watched agent folder changed. Choose it again before importing.")
            }
            selected = importSelections[directory.path]
        } else if rawOptions.has("selectedFiles") {
            let chosen = try BackendPROJAgentBatches.selectedFiles(rawOptions["selectedFiles"], directory: directory)
            let existing = Set(agents.compactMap { row -> String? in
                guard row["sourceDirectory"].string == directory.path, let path = row["sourceFile"].string,
                      Self.isStoredImportPath(path, directory: directory.path) else { return nil }
                return path
            })
            let remembered = chosen.union(existing)
            try rememberImportSelection(remembered, directory: directory.path)
            // Grey Already here rows stay untouched by this explicit selected import.
            selected = chosen
        } else {
            try rememberImportSelection(nil, directory: directory.path)
            selected = nil
        }
        let files = allFiles.filter { selected?.contains($0.path) ?? true }
        var imported = 0, updated = 0, errors: [NativeRPCValue] = [], seen = Set<String>()
        for file in files {
            try requireImportGeneration(generation)
            do {
                guard let definition = try BackendTAGAgentImport.read(file) else {
                    if agents.contains(where: { $0["sourceFile"].string == file.path }) { throw NativeRPCError.invalidArguments("The source file no longer contains an agent name and frontmatter.") }
                    continue
                }
                guard seen.insert(definition.name).inserted else { throw NativeRPCError.invalidArguments("More than one source file names \(definition.name).") }
                let old = try await agent(definition.name)
                if let source = old?["sourceFile"].string, source != file.path { throw NativeRPCError.invalidArguments("\(definition.name) is already synced from \(source).") }
                var row = BackendTAGAgentImport.merge(definition, existing: old, directory: directory, file: file)
                let intent = definition.profile.merging(options.removing("agents")).merging(options["agents"][definition.name])
                row = row.merging(options.removing("agents")).merging(options["agents"][definition.name])
                if let project = row["defaultProject"].string { try await authorizeProject?(project) }
                if narrowOnly {
                    var proposed = row
                    for key in ["sourceFile", "sourceDirectory", "syncStatus", "syncedAt", "syncError"] { proposed = proposed.removing(key) }
                    for key in BackendTAGProfilePolicy.initialFields where !intent.has(key) { proposed = proposed.removing(key) }
                    let restricted = try BackendTAGProfilePolicy.validate(input: proposed, existing: old, inheritedPermissionMode: inheritedPermissionMode, callerKeyID: callerKeyID)
                    for key in BackendTAGProfilePolicy.initialFields + ["creatorKeyId", "keyInitializedFields"] where restricted.has(key) { row = row.setting(key, restricted[key]) }
                }
                _ = try await saveAgent(row, keyMutation: narrowOnly || generation != nil)
                try requireImportGeneration(generation)
                if old == nil { imported += 1 } else { updated += 1 }
            } catch is CancellationError { throw CancellationError()
            } catch {
                let message = String(error.localizedDescription.prefix(2_000))
                errors.append(BackendTaskValues.object([("file", .string(file.path)), ("message", .string(message))]))
                if let index = agents.firstIndex(where: { $0["sourceFile"].string == file.path }) {
                    agents[index] = agents[index].setting("syncStatus", .string("error")).setting("syncError", .string(message))
                }
            }
        }
        try requireImportGeneration(generation)
        let paths = Set(allFiles.map(\.path))
        for index in agents.indices where agents[index]["sourceDirectory"].string == directory.path && !paths.contains(agents[index]["sourceFile"].string ?? "") {
            agents[index] = agents[index].setting("syncStatus", .string("missing")).setting("syncError", .string("The source file is missing. The last synced profile was kept."))
        }
        try flush(); await changed(); try watchImportDirectory(directory.path)
        return BackendTaskValues.object([("agents", .array(try await allAgents())), ("folder", .string(directory.path)), ("imported", .number(Double(imported))), ("updated", .number(Double(updated))), ("errors", .array(errors))])
    }
    public func startImportWatchers() async throws {
        try started(); guard persistence.ownership != .readOnly else { return }; importWatching = true
        for directory in Set(agents.compactMap { $0["sourceDirectory"].string }).union(importSelections.keys) {
            do { try watchImportDirectory(directory) }
            catch { markImportProblem(directory, error: error); try? flush(); await changed(); continue }
            // One startup read catches edits made while the app was closed.
            // Subsequent syncs come only from the shared FSEvents stream.
            await syncImportDirectory(directory, generation: importGeneration)
        }
    }
    public func stopImportWatchers() {
        importWatching = false; importGeneration &+= 1
        for off in importStops.values { off() }; importStops.removeAll()
    }
    private func watchImportDirectory(_ directory: String) throws {
        guard importWatching, importStops[directory] == nil else { return }
        let generation = importGeneration
        importStops[directory] = try importWatchers.watch(directory) { [weak self] relative in
            guard !relative.contains("/"), relative.lowercased().hasSuffix(".md") else { return }
            Task { await self?.syncImportDirectory(directory, generation: generation) }
        }
    }
    private func requireImportGeneration(_ generation: UInt64?) throws {
        if let generation, !importWatching || generation != importGeneration { throw CancellationError() }
    }
    private func markImportProblem(_ directory: String, error: any Error) {
        for index in agents.indices where agents[index]["sourceDirectory"].string == directory {
            agents[index] = agents[index].setting("syncStatus", .string("error")).setting("syncError", .string(String(error.localizedDescription.prefix(2_000))))
        }
    }
    private func syncImportDirectory(_ directory: String, generation: UInt64) async {
        guard importWatching, generation == importGeneration else { return }
        do { _ = try await importAgentsImpl(folder: directory, narrowOnly: false, inheritedPermissionMode: "default", generation: generation) }
        catch is CancellationError { return }
        catch {
            guard importWatching, generation == importGeneration else { return }
            markImportProblem(directory, error: error)
            try? flush(); await changed()
        }
    }
    public func stop() throws {
        guard !savingAGS else { throw NativeRPCError(code: "settings-saving", message: "The combined agent profile save is still draining.") }
        if let failure = agsFailure { throw failure }
        stopImportWatchers(); if loaded, persistence.ownership != .readOnly { try flush() }
    }
    /// U140 (#194, #361): each agent's instructions text with the file's identity, size and change times when it was
    /// read. Every view of an agent (each task, each state) checked the file with one stat and read it again only when
    /// one of those changed; before, it opened and read every agent's file on every look.
    private var instructionsRead: [String: (stamp: [Int], text: String)] = [:]
    private static func stamp(_ info: stat) -> [Int] {
        [Int(info.st_dev), Int(truncatingIfNeeded: info.st_ino), Int(info.st_size), info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec, info.st_ctimespec.tv_sec, info.st_ctimespec.tv_nsec]
    }
    private func view(_ agent: NativeRPCValue) throws -> NativeRPCValue {
        guard persistence.ownership != .memory, let id = agent["id"].string else { return agent.setting("instructionsFile", .null) }
        let path = try instructions.file(id + ".md")
        guard FileManager.default.fileExists(atPath: path.path) else { instructionsRead[id] = nil; return agent.setting("instructionsFile", .null) }
        func shown(_ text: String) -> NativeRPCValue { text.isEmpty ? agent.setting("instructionsFile", .null) : agent.setting("instructions", .string(text)).setting("instructionsFile", .string(path.path)) }
        var info = stat()
        if lstat(path.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, let known = instructionsRead[id], known.stamp == Self.stamp(info) { return shown(known.text) }
        let fd = Darwin.open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { instructionsRead[id] = nil; throw NativeRPCError(code: "instructions-unreadable", message: "The agent's instructions file could not be read") }; defer { Darwin.close(fd) }
        // The stamp is taken before the read: a write during it changes the times, so the next look reads again.
        let opened = fstat(fd, &info) == 0 ? Self.stamp(info) : nil
        instructionsRead[id] = nil
        var buffer = [UInt8](repeating: 0, count: 128_001), done = 0
        while done < buffer.count { let read = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: done), $0.count - done) }; if read == 0 { break }; if read < 0 { if errno == EINTR { continue }; throw NativeRPCError.malformed("Agent instruction read failed") }; done += read }
        guard done <= 128_000 else { throw NativeRPCError.malformed("Agent instructions are too large") }
        let text = String(decoding: buffer.prefix(done), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf16.count <= 32_000 else { throw NativeRPCError.malformed("Agent instructions are longer than 32000 characters") }
        if let opened { instructionsRead[id] = (opened, text) }
        return shown(text)
    }
    public func saveConnection(_ keyID: String, input: NativeRPCValue) async throws -> NativeRPCValue {
        try await waitForAGS()
        try started(); try persistence.writable(); guard !keyID.isEmpty else { throw NativeRPCError.invalidArguments("Choose an access key first.") }
        let index = connections.firstIndex { $0["keyId"].string == keyID }
        var row = index.map { connections[$0] } ?? BackendTaskValues.object([("keyId", .string(keyID)), ("name", .null), ("enabled", .bool(false)), ("eventsUrl", .null), ("hasEventsSecret", .bool(false)), ("statuses", Self.defaultStatuses), ("hootIdentity", .null), ("identities", .object([])), ("allowedSenders", .array([])), ("folders", .array([])), ("maxHops", .number(3))])
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
        // CRM-LINK: the one CRM profile allowed to give work (user:<uuid>), and the projects the link reaches.
        if input.has("ownerProfile") {
            let owner = try BackendTaskValues.text(input["ownerProfile"], "The owner profile", max: 200)
            guard owner == nil || owner == "" || owner!.hasPrefix("user:") else { throw NativeRPCError.invalidArguments("The owner profile is a CRM user identity, user:<id>.") }
            row = row.setting("ownerProfile", owner.flatMap { $0.isEmpty ? nil : NativeRPCValue.string($0) } ?? .null)
        }
        if input.has("projects") { row = row.setting("projects", .array(try BackendTaskValues.strings(input["projects"], label: "The projects", maximum: 10, length: 80).map(NativeRPCValue.string))) }
        if input.has("maxHops") { row = row.setting("maxHops", .number(Double(try BackendTaskValues.whole(input["maxHops"], label: "Hand-offs", min: 1, max: 5, fallback: 3)))) }
        if let hoot = row["hootIdentity"].string, row["identities"].has(hoot) { throw NativeRPCError.invalidArguments("The Hoot identity cannot also be an agent’s identity.") }
        var secret: String?, previous: String?
        let secretID = Self.eventsSecretID(keyID)
        if !Self.hasEventsSecret(row) || input["rotateSecret"].bool == true {
            var random = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw NativeRPCError(code: "entropy", message: "macOS could not create a private task events signing secret") }
            // Into the secret store, never the settings file (#340).
            previous = try? secrets.read(secretID)
            secret = "whsec_" + Data(random).base64EncodedString(); try secrets.write(secretID, token: secret!)
            row = row.removing("eventsSecret").setting("hasEventsSecret", .bool(true))
        }
        let before = connections; if let index { connections[index] = row } else { connections.append(row) }
        do { try flush() } catch {
            connections = before
            if secret != nil { if let previous { try? secrets.write(secretID, token: previous) } else { try? secrets.remove(secretID) } }
            throw error
        }; await changed()
        return BackendTaskValues.object([("view", Self.connectionView(row)), ("secret", secret.map(NativeRPCValue.string) ?? .null)])
    }
    public func removeConnection(_ keyID: String) async throws {
        try started(); try persistence.writable(); guard connections.contains(where: { $0["keyId"].string == keyID }) else { throw NativeRPCError.invalidArguments("That connection no longer exists.") }
        let before = connections; connections.removeAll { $0["keyId"].string == keyID }
        do { try flush() } catch { connections = before; throw error }
        try? secrets.remove(Self.eventsSecretID(keyID)); await changed()
    }
    public nonisolated static var defaultStatuses: NativeRPCValue { BackendTaskValues.object([("statuses", .array(BackendTaskLocalService.statuses.map(NativeRPCValue.string))), ("initial", .string("To-Do")), ("completed", .string("Done")), ("onStarted", .string("Working on it")), ("onVerified", .string("Done")), ("onBlocked", .string("Stuck"))]) }
    /// Preview and prepare share validation; previews cannot mutate profiles.
    public func profileChangePreview(request: NativeRPCValue, callerKeyID: String, inheritedPermissionMode: String = "default", ownerReviewOrdinaryFields: Bool = false) async throws -> NativeRPCValue {
        try await waitForAGS(); try started()
        let planID = try profileRequestID(request, key: callerKeyID)
        if let plan = profileChangePlans[planID] { try await verifyProfilePlan(plan); return profilePlanView(plan) }
        return profilePlanView(try await buildProfilePlan(request: request, callerKeyID: callerKeyID, inheritedPermissionMode: inheritedPermissionMode, planID: planID, ownerReviewOrdinaryFields: ownerReviewOrdinaryFields).plan)
    }
    public func prepareAgentChanges(request: NativeRPCValue, callerKeyID: String, inheritedPermissionMode: String = "default", ownerReviewOrdinaryFields: Bool = false) async throws -> NativeRPCValue {
        try await waitForAGS(); try started(); try persistence.writable()
        let planID = try profileRequestID(request, key: callerKeyID)
        if let plan = profileChangePlans[planID] { try await verifyProfilePlan(plan); return profilePlanView(plan) }
        let before = agents, priorPlans = profileChangePlans
        let built = try await buildProfilePlan(request: request, callerKeyID: callerKeyID, inheritedPermissionMode: inheritedPermissionMode, planID: planID, ownerReviewOrdinaryFields: ownerReviewOrdinaryFields)
        guard agents == before, profileChangePlans == priorPlans else { throw profilePlanChanged() }
        var plans = profileChangePlans
        if built.plan["needsApproval"].bool == true {
            guard profileChangePlans.count < 50 else { throw NativeRPCError(code: "too-many-pending", message: "Finish the waiting agent approvals before adding more.") }
            plans[planID] = built.plan
        }
        try await publishAgentRows(built.narrowRows, expectedAgents: before, nextPlans: plans, enforceNarrowing: true, callerKeyID: callerKeyID, inheritedPermissionMode: inheritedPermissionMode)
        if let plan = profileChangePlans[planID] { return profilePlanView(plan) }
        return profilePlanView(built.plan)
    }
    /// Field adapters share the same frozen plan and encrypted AGS publication.
    /// The original public request is the approval identity, never a rewritten save.
    public func prepareSettingsFieldChange(request: NativeRPCValue, callerKeyID: String, inheritedPermissionMode: String = "default", ownerReviewOrdinaryFields: Bool = false) async throws -> NativeRPCValue {
        try await waitForAGS(); try started(); try persistence.writable()
        let planID = try profileRequestID(request, key: callerKeyID)
        if let plan = profileChangePlans[planID] { try await verifyProfilePlan(plan); return profilePlanView(plan) }
        let id = try request["id"].requireString("agent id", nonempty: true)
        let field = try request["field"].requireString("setting field", nonempty: true)
        guard let current = try await agent(id), let store = agsStore else { throw NativeRPCError(code: "missing-agent", message: "Choose an existing agent with installed settings.") }
        let before = agents, priorPlans = profileChangePlans, revision = try await store.currentRevision()
        let prior = try await store.profile(id) ?? BackendAGSProfileProjection.settings(current, defaultProvider: current["provider"].string ?? "claude")
        let proposal = try BackendAGOPTProfileFieldAdapter.proposal(profile: current, settings: prior, field: field, value: request["value"])
        guard !proposal.privateField else { throw NativeRPCError(code: "not-granted", message: "Private hooks and environment values can only be edited in the owner's native settings.") }
        var patch = NativeRPCValue.object([])
        for property in BackendAGOPTProfileChanges.editableFields where property != "id" && proposal.profile[property] != current[property] {
            patch = patch.setting(property, proposal.profile[property])
        }
        let normalized = NativeRPCValue.object([.init("do", .string("save")), .init("agent", patch.setting("id", .string(id)))])
        let built = try await buildProfilePlan(request: normalized, callerKeyID: callerKeyID, inheritedPermissionMode: inheritedPermissionMode, planID: planID, ownerReviewOrdinaryFields: ownerReviewOrdinaryFields)
        let priorRaw = try BackendAGSCodec.value(prior), nextRaw = try BackendAGSCodec.value(proposal.settings)
        var delta = NativeRPCValue.object([])
        for property in ["provider", "model", "effort", "permissionMode", "allowedTools", "deniedTools", "mcpServers", "workingFolder", "keepOpen", "efficiency"] where priorRaw[property] != nextRaw[property] {
            delta = delta.setting(property, nextRaw[property])
        }
        var wideAGS = false
        if !(delta.fields ?? []).isEmpty, BackendAGOPTProfileFields.profile[field] == nil, field != "stop_when_done" {
            let defaults = try await store.defaults()
            do {
                try BackendAGSPolicy.requireNarrowing(BackendAGSPolicy.resolve(defaults: defaults.providers[proposal.settings.provider], profile: proposal.settings), owner: BackendAGSPolicy.resolve(defaults: defaults.providers[prior.provider], profile: prior))
            } catch { wideAGS = true }
        }
        // A TAG widening and its mirrored AGS scalar cannot publish separately.
        let needsApproval = built.plan["needsApproval"].bool == true || wideAGS
        var plan = built.plan, plans = profileChangePlans
        if needsApproval {
            guard plans.count < 50 else { throw NativeRPCError(code: "too-many-pending", message: "Finish the waiting agent approvals before adding more.") }
            let entry = (plan["entries"].elements ?? []).first ?? .object([.init("id", .string(id)), .init("wide", .object([])), .init("before", .string("awaiting-narrow-commit"))])
            plan = plan.setting("needsApproval", .bool(true)).setting("count", .number(1))
                .setting("names", .array([current["name"]])).setting("summary", .string("change \(field.replacingOccurrences(of: "_", with: " ")) for \(current["name"].string ?? id)"))
                .setting("entries", .array([entry.setting("publicAGS", delta)]))
            plans[planID] = plan
        }
        guard agents == before, profileChangePlans == priorPlans, try await store.currentRevision() == revision else { throw profilePlanChanged() }
        let overrides = needsApproval ? [:] : [id: proposal.settings]
        try await publishAgentRows(built.narrowRows, expectedAgents: before, nextPlans: plans, enforceNarrowing: false, callerKeyID: callerKeyID, inheritedPermissionMode: inheritedPermissionMode, pinnedAGSRevision: revision, settingsOverrides: overrides)
        return profilePlanView(profileChangePlans[planID] ?? plan)
    }
    /// Native callers obtain owner consent before this revision-bound save.
    public func saveSettingsFieldOwner(_ id: String, field: String, value: NativeRPCValue, expectedRevision: UInt64) async throws -> NativeRPCValue {
        try await waitForAGS(); try started()
        guard let current = try await agent(id), let store = agsStore else { throw NativeRPCError(code: "missing-agent", message: "That saved agent no longer exists.") }
        let before = agents
        let prior = try await store.profile(id) ?? BackendAGSProfileProjection.settings(current, defaultProvider: current["provider"].string ?? "claude")
        let proposal = try BackendAGOPTProfileFieldAdapter.proposal(profile: current, settings: prior, field: field, value: value)
        guard agents == before else { throw profilePlanChanged() }
        let owned = BackendTAGProfilePolicy.ownershipForSave(proposal.profile, existing: current, keyMutation: false)
        try await publishAgentRows([owned], expectedAgents: before, nextPlans: profileChangePlans, enforceNarrowing: false, callerKeyID: "", inheritedPermissionMode: "default", pinnedAGSRevision: expectedRevision, settingsOverrides: [id: proposal.settings])
        return try view(owned)
    }
    public func managedInstructionsPath(_ id: String) throws -> String {
        try started(); guard agents.contains(where: { $0["id"].string == id }) else { throw NativeRPCError.invalidArguments("That saved agent no longer exists.") }
        return instructions.directory.appendingPathComponent(id + ".md").path
    }
    /// Called only by the existing trusted approval settlement event. Narrow
    /// profile changes stay applied; only the frozen review metadata is removed.
    public func discardAgentChangeRequest(request: NativeRPCValue, callerKeyID: String) async throws {
        try await waitForAGS(); try started(); try persistence.writable()
        let id = try profileRequestID(request, key: callerKeyID)
        guard profileChangePlans[id] != nil else { return }
        let previous = profileChangePlans; profileChangePlans[id] = nil
        do { try flush() } catch { profileChangePlans = previous; throw error }
    }
    /// Only the mandatory approval callback's normal return may call this method.
    /// The key, exact plan and every reviewed source record are checked anew.
    public func applyApprovedAgentChanges(planID: String, callerKeyID: String) async throws -> [NativeRPCValue] {
        try await waitForAGS(); try started(); try persistence.writable()
        guard let plan = profileChangePlans[planID], plan["keyId"].string == callerKeyID else { throw NativeRPCError(code: "approval-stale", message: "That reviewed agent change no longer exists for this key.") }
        let before = agents
        let pinnedAGSRevision = try await agsStore?.currentRevision()
        try await verifyProfilePlan(plan)
        guard agents == before, try await agsStore?.currentRevision() == pinnedAGSRevision else { throw profilePlanChanged() }
        var rows: [NativeRPCValue] = [], overrides: [String: AGSAgentSettings] = [:]
        for entry in plan["entries"].elements ?? [] {
            let id = try entry["id"].requireString("agent id")
            let patch = try entry["wide"].requireObject("reviewed agent fields")
            if entry["created"].bool == true {
                guard try await agent(id) == nil else { throw profilePlanChanged() }
                rows.append(try Self.cleanAgent(patch, others: agents)); continue
            }
            guard let current = try await agent(id) else { throw profilePlanChanged() }
            if let delta = entry["publicAGS"].fields {
                guard let store = agsStore else { throw profilePlanChanged() }
                let allowed: Set<String> = ["provider", "model", "effort", "permissionMode", "allowedTools", "deniedTools", "mcpServers", "workingFolder", "keepOpen", "efficiency"]
                guard delta.allSatisfy({ allowed.contains($0.key) }) else { throw profilePlanChanged() }
                let prior = try await store.profile(id) ?? BackendAGSProfileProjection.settings(current, defaultProvider: current["provider"].string ?? "claude")
                let merged = try BackendAGSCodec.value(prior).merging(entry["publicAGS"])
                let reviewed = try BackendAGSCodec.decode(AGSAgentSettings.self, merged)
                try BackendAGSValidation.check(reviewed); overrides[id] = reviewed
            }
            var input = current.merging(patch)
            let chosen = Set((current["keyInitializedFields"].elements ?? []).compactMap(\.string)).union(BackendTAGProfilePolicy.initialFields.filter { patch.has($0) })
            input = input.setting("keyInitializedFields", .array(chosen.sorted().map(NativeRPCValue.string)))
            rows.append(try Self.cleanAgent(input, others: agents))
        }
        var plans = profileChangePlans; plans[planID] = nil
        try await publishAgentRows(rows, expectedAgents: before, nextPlans: plans, enforceNarrowing: false, callerKeyID: callerKeyID, inheritedPermissionMode: "default", pinnedAGSRevision: pinnedAGSRevision, settingsOverrides: overrides)
        return try (plan["ids"].elements ?? []).compactMap(\.string).compactMap { id in
            try agents.first(where: { $0["id"].string == id }).map(view)
        }
    }
    private func profileRequestID(_ request: NativeRPCValue, key: String) throws -> String {
        guard !key.isEmpty else { throw NativeRPCError(code: "not-granted", message: "Agent changes need the actual caller key.") }
        return try BackendAGOPTProfileChanges.fingerprint(.object([.init("key", .string(key)), .init("request", request)]))
    }
    /// A new agent's id from its name, as the New Agent screen and tasks_agents make it: lowercase words joined by
    /// dashes, at most 36 characters, "-2", "-3"… when taken.
    public nonisolated static func newID(name: String?, taken: Set<String>) -> String { TaskNames.agentID(name ?? "agent", taken: taken) }
    /// The agents one tasks_agents save/save-many request names, each with its own change (no id in the change):
    /// save = one agent (a new one gets an id from its name); save-many = one shared change for existing `ids`, or
    /// `agents`, a list of whole agents, new or existing, each with its own fields. At most 50 per request.
    private func requestedChanges(_ request: NativeRPCValue) throws -> [(id: String, patch: NativeRPCValue)] {
        let verb = request["do"].string ?? "save"
        var taken = Set(agents.compactMap { $0["id"].string })
        if verb == "save-many", request.has("agents") {
            guard request["agent"].isNullish, request["ids"].isNullish else { throw NativeRPCError.invalidArguments("Give agents (a list of whole agents), or agent with ids (one change for several agents), not both.") }
            let list = try request["agents"].requireArray("agents")
            guard !list.isEmpty, list.count <= BackendTAGAgentProfile.maximumPerCall else { throw NativeRPCError.invalidArguments("Give from 1 to \(BackendTAGAgentProfile.maximumPerCall) agents in one request; send the rest in another.") }
            var result: [(id: String, patch: NativeRPCValue)] = [], seen = Set<String>()
            for entry in list {
                let patch = try entry.requireObject("agent")
                let id: String
                if let given = patch["id"].string, !given.isEmpty { id = given.lowercased() }
                else { id = Self.newID(name: patch["name"].string, taken: taken.union(seen)) }
                guard seen.insert(id).inserted else { throw NativeRPCError.invalidArguments("Each agent may appear only once in one request.") }
                taken.insert(id); result.append((id, patch.removing("id")))
            }
            return result
        }
        let patch = try request["agent"].requireObject("agent")
        if verb == "save-many" {
            guard patch["id"].isNullish, let values = request["ids"].elements, !values.isEmpty, values.count <= BackendTAGAgentProfile.maximumPerCall else { throw NativeRPCError.invalidArguments("Choose from 1 to \(BackendTAGAgentProfile.maximumPerCall) agent ids in one request and omit id from the shared change.") }
            let ids = try values.map { try $0.requireString("agent id", nonempty: true) }
            guard Set(ids).count == ids.count else { throw NativeRPCError.invalidArguments("Each agent id may appear only once.") }
            guard ids.allSatisfy({ id in agents.contains { $0["id"].string == id } }) else { throw NativeRPCError.invalidArguments("Every agent named in ids must already exist; to add new agents, give them in agents.") }
            return ids.map { ($0, patch) }
        }
        guard verb == "save" else { throw NativeRPCError.invalidArguments("Use save or save-many for agent changes.") }
        return [(patch["id"].string ?? Self.newID(name: patch["name"].string, taken: taken), patch.removing("id"))]
    }
    private func buildProfilePlan(request: NativeRPCValue, callerKeyID: String, inheritedPermissionMode: String, planID: String, ownerReviewOrdinaryFields: Bool) async throws -> (plan: NativeRPCValue, narrowRows: [NativeRPCValue]) {
        let changes = try requestedChanges(request), ids = changes.map(\.id)
        var rows: [NativeRPCValue] = [], finalRows: [NativeRPCValue] = [], entries: [NativeRPCValue] = [], names: [String] = [], allWide = NativeRPCValue.object([])
        for (id, patch) in changes {
            let existing = try await agent(id)
            let split = try BackendAGOPTProfileChanges.split(patch: patch, existing: existing, callerKeyID: callerKeyID, inheritedPermissionMode: inheritedPermissionMode, ownerReviewOrdinaryFields: ownerReviewOrdinaryFields)
            if existing == nil, ownerReviewOrdinaryFields {
                var safePatch = patch.removing("instructionsFile")
                for field in BackendAGOPTProfileChanges.protectedFields { safePatch = safePatch.removing(field) }
                var seed = try BackendTAGProfilePolicy.validate(input: safePatch.removing("keepAliveUntilClose").removing("verifyCommand").setting("id", .string(id)), existing: nil, inheritedPermissionMode: inheritedPermissionMode, callerKeyID: callerKeyID)
                seed = seed.merging(safePatch).setting("id", .string(id))
                let selected = Set((seed["keyInitializedFields"].elements ?? []).compactMap(\.string)).union(BackendTAGProfilePolicy.initialFields.filter { safePatch.has($0) && !safePatch[$0].isNullish })
                seed = seed.setting("keyInitializedFields", .array(selected.sorted().map(NativeRPCValue.string)))
                let created = try Self.cleanAgent(seed, others: agents); try Self.checkSupported(created); finalRows.append(created)
                names.append(created["name"].string ?? id); allWide = allWide.merging(safePatch)
                entries.append(.object([.init("id", .string(id)), .init("created", .bool(true)), .init("wide", created), .init("before", .string("awaiting-narrow-commit"))]))
                continue
            }
            let narrow = try BackendTAGProfilePolicy.validate(input: split.narrow.setting("id", .string(id)), existing: existing, inheritedPermissionMode: inheritedPermissionMode, callerKeyID: callerKeyID)
            var cleaned = try Self.cleanAgent(narrow, others: agents)
            // Missing current instructions are already read through the one profile view.
            cleaned = cleaned.setting("status", existing?["status"] ?? .string("active")).setting("statusAt", existing?["statusAt"] ?? .null)
            try Self.checkSupported(cleaned)
            let full = try Self.cleanAgent(cleaned.merging(split.wide), others: agents)
            try Self.checkSupported(full); finalRows.append(full); rows.append(cleaned)
            if !(split.wide.fields ?? []).isEmpty {
                let name = cleaned["name"].string ?? id; names.append(name); allWide = allWide.merging(split.wide)
                entries.append(.object([.init("id", .string(id)), .init("wide", split.wide), .init("before", .string("awaiting-narrow-commit"))]))
            }
        }
        var prospective = agents
        for row in finalRows {
            if let index = prospective.firstIndex(where: { $0["id"] == row["id"] }) { prospective[index] = row } else { prospective.append(row) }
        }
        for row in finalRows {
            _ = try Self.cleanAgent(row, others: prospective)
            try BackendAGTOrg.check(row, agents: prospective)
        }
        return (.object([.init("planId", .string(planID)), .init("keyId", .string(callerKeyID)), .init("needsApproval", .bool(!entries.isEmpty)), .init("names", .array(names.map(NativeRPCValue.string))), .init("count", .number(Double(names.count))), .init("summary", .string(BackendAGOPTProfileChanges.summary(names: names, wide: allWide))), .init("entries", .array(entries)), .init("ids", .array(ids.map(NativeRPCValue.string)))]), rows)
    }
    private func profilePlanView(_ plan: NativeRPCValue) -> NativeRPCValue { plan.removing("keyId").removing("entries") }
    private func profileFingerprint(row: NativeRPCValue, settings: AGSAgentSettings?, defaults: AGSDefaults?) throws -> String {
        try BackendAGOPTProfileChanges.fingerprint(.object([.init("agent", row.removing("instructionsFile")), .init("settings", try settings.map(BackendAGSCodec.value) ?? .null), .init("defaults", try defaults.map(BackendAGSCodec.value) ?? .null)]))
    }
    private func profileFingerprint(_ id: String) async throws -> String {
        let row = try await agent(id)
        let settings = try await agsStore?.profile(id)
        let defaults = try await agsStore?.defaults()
        if let row { return try profileFingerprint(row: row, settings: settings, defaults: defaults) }
        return try BackendAGOPTProfileChanges.fingerprint(.object([.init("agent", .null), .init("settings", try settings.map(BackendAGSCodec.value) ?? .null), .init("defaults", try defaults.map(BackendAGSCodec.value) ?? .null)]))
    }
    private func verifyProfilePlan(_ plan: NativeRPCValue) async throws {
        guard let entries = plan["entries"].elements, !entries.isEmpty, entries.count <= BackendTAGAgentProfile.maximumPerCall else { throw profilePlanChanged() }
        for entry in entries {
            let id = try entry["id"].requireString("agent id")
            if entry["created"].bool == true, try await agent(id) != nil { throw profilePlanChanged() }
            guard try await profileFingerprint(id) == entry["before"].string else { throw profilePlanChanged() }
        }
    }
    private func profilePlanChanged() -> NativeRPCError { .init(code: "approval-stale", message: "An agent changed after this card was prepared. Request a new review; the old card cannot change it.") }
    /// Publish the canonical rows and their existing encrypted AGS extension as
    /// one group, with the same claim barrier and rollback as a single save.
    private func publishAgentRows(_ rows: [NativeRPCValue], expectedAgents: [NativeRPCValue], nextPlans: [String: NativeRPCValue], enforceNarrowing: Bool, callerKeyID: String, inheritedPermissionMode: String, pinnedAGSRevision: UInt64? = nil, settingsOverrides: [String: AGSAgentSettings] = [:]) async throws {
        try await waitForAGS(); try started(); try persistence.writable()
        guard agents == expectedAgents else { throw profilePlanChanged() }
        let initialPlans = profileChangePlans
        var next = agents, settingsMap: [String: AGSAgentSettings] = [:]
        let expectedAGSRevision = try await agsStore?.currentRevision()
        if let pinnedAGSRevision, expectedAGSRevision != pinnedAGSRevision { throw profilePlanChanged() }
        let currentDefaults = try await agsStore?.defaults()
        for row in rows {
            let id = try row["id"].requireString("agent id")
            // Reports-to is checked below against the whole group: a new agent may report to another new one.
            if let store = agsStore, AGSCapabilities.providers.contains(row["provider"].string ?? "claude") {
                let old = agents.first { $0["id"].string == id }
                let prior = try await store.profile(id) ?? BackendAGSProfileProjection.settings(old ?? row, defaultProvider: row["provider"].string ?? "claude")
                let projection = try BackendAGSProfileProjection.settings(row, defaultProvider: prior.provider)
                var updated = settingsOverrides[id] ?? prior
                updated.provider = projection.provider; updated.model = projection.model; updated.effort = projection.effort
                updated.permissionMode = projection.permissionMode; updated.allowedTools = projection.allowedTools; updated.deniedTools = projection.deniedTools
                updated.workingFolder = projection.workingFolder; updated.keepOpen = projection.keepOpen
                if enforceNarrowing, !BackendTAGProfilePolicy.hasInitialSelection(input: row, existing: old, callerKeyID: callerKeyID) {
                    let defaults = try await store.defaults().providers[prior.provider]
                    try BackendAGSPolicy.requireNarrowing(BackendAGSPolicy.resolve(defaults: defaults, profile: updated), owner: BackendAGSPolicy.resolve(defaults: defaults, profile: prior))
                }
                settingsMap[id] = updated
            }
            if let index = next.firstIndex(where: { $0["id"].string == id }) { next[index] = row } else { next.append(row) }
        }
        guard agents == expectedAgents else { throw profilePlanChanged() }
        var frozenPlans = nextPlans
        for (planID, draft) in nextPlans where draft["entries"].elements?.contains(where: { $0["before"].string == "awaiting-narrow-commit" }) == true {
            var entries: [NativeRPCValue] = []
            for entry in draft["entries"].elements ?? [] {
                let id = try entry["id"].requireString("agent id")
                if entry["created"].bool == true {
                    guard try await agent(id) == nil else { throw profilePlanChanged() }
                    entries.append(entry.setting("before", .string(try await profileFingerprint(id)))); continue
                }
                guard let reviewed = rows.first(where: { $0["id"].string == id }) else { throw profilePlanChanged() }
                let fingerprint = try profileFingerprint(row: reviewed, settings: settingsMap[id], defaults: currentDefaults)
                entries.append(entry.setting("before", .string(fingerprint)))
            }
            frozenPlans[planID] = draft.setting("entries", .array(entries))
        }
        guard agents == expectedAgents, profileChangePlans == initialPlans else { throw profilePlanChanged() }
        for row in rows {
            try await checkToolUseChange(row["toolUseRestrictions"], previous: agents.first { $0["id"] == row["id"] }?["toolUseRestrictions"] ?? .missing)
            _ = try Self.cleanAgent(row, others: next); try BackendAGTOrg.check(row, agents: next)
        }
        guard agents == expectedAgents, profileChangePlans == initialPlans else { throw profilePlanChanged() }
        let recordRows = persistence.ownership == .memory ? next : next.map { $0.setting("instructions", .null) }
        let record = BackendTaskValues.object([("v", .number(1)), ("agents", .array(recordRows.map { $0.removing("instructionsFile") })), ("connections", .array(connections)), ("agentImportSelections", importSelectionsWire), ("profileChangePlans", .array(frozenPlans.keys.sorted().compactMap { frozenPlans[$0] }))])
        let recordBytes = try record.encodedJSON(pretty: true)
        guard recordBytes.count <= 4 * 1024 * 1024 else { throw NativeRPCError(code: "profile-review-limit", message: "The grouped profile changes exceed the safe record size. Finish pending reviews or use a smaller change.") }
        try savable()
        let beforeConfig = try persistence.readOwnedBytes("task-config.json")
        var beforeFiles: [String: Data?] = [:]
        for row in rows { let id = row["id"].string!; beforeFiles[id] = .some(try instructions.readOwnedBytes(id + ".md", maximumBytes: 128_000)) }
        let previousPlans = profileChangePlans
        savingAGS = true; defer { if savingAGS { releaseAGSBarrier() } }
        let prepared: BackendAGSProfileTransaction?
        if let store = agsStore, !settingsMap.isEmpty { prepared = try await store.prepareProfilesTransaction(settingsMap, expectedRevision: expectedAGSRevision!) } else { prepared = nil }
        do {
            try Task.checkCancellation()
            if persistence.ownership != .memory {
                for row in rows {
                    let id = row["id"].string!
                    if let text = row["instructions"].string, !text.isEmpty { try instructions.writeBytes(id + ".md", data: Data((text + "\n").utf8)) } else { try instructions.remove(id + ".md") }
                    if let index = next.firstIndex(where: { $0["id"].string == id }) { next[index] = next[index].setting("instructions", .null) }
                }
            }
            profileChangePlans = frozenPlans
            try persistence.writeBytes("task-config.json", data: recordBytes)
            try prepared?.publish()
            if let prepared, let store = agsStore { try await store.finishProfileTransaction(prepared) }
            agents = next
        } catch {
            profileChangePlans = previousPlans
            do {
                try prepared?.restore()
                if let beforeConfig { try persistence.writeBytes("task-config.json", data: beforeConfig) } else { try persistence.remove("task-config.json") }
                for (id, bytes) in beforeFiles { if let bytes { try instructions.writeBytes(id + ".md", data: bytes) } else { try instructions.remove(id + ".md") } }
                if let prepared, let store = agsStore { try await store.cancelProfileTransaction(prepared) }
            } catch { agsFailure = .init(code: "settings-rollback-failed", message: "The grouped profile save could not restore its original records. Task claims are paused."); throw agsFailure! }
            throw error
        }
        releaseAGSBarrier()
        if let store = agsStore, prepared != nil { await store.announceProfileTransaction() }
        await changed()
    }
    private func started() throws { guard loaded else { throw NativeRPCError(code: "not-started", message: "Task settings have not been opened") } }
    private func savable() throws { if let configBlocked { throw NativeRPCError(code: "task-config-unreadable", message: configBlocked) } }
    private func flush() throws { try savable(); try persistence.write("task-config.json", value: BackendTaskValues.object([("v", .number(1)), ("agents", .array(agents.map { $0.removing("instructionsFile") })), ("connections", .array(connections)), ("agentImportSelections", importSelectionsWire), ("profileChangePlans", .array(profileChangePlans.keys.sorted().compactMap { profileChangePlans[$0] }))])) }
}
