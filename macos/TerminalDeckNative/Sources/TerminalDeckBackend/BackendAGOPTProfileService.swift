import Foundation
import TerminalDeckNativeCore

/// Credential facts are supplied by the existing native or MCP dispatcher;
/// neither the agent id nor an attended bit creates owner authority.
public enum BackendAGOPTProfileCall: Sendable {
    case app(NativeRPCContext)
    case tool(BackendMCPCallContext)
}

public struct BackendAGOPTProfileAccess: Sendable {
    public let require: @Sendable (BackendAGOPTProfileCall, String, Bool) async throws -> Void
    public let authorize: @Sendable (BackendAGOPTProfileCall, String, NativeRPCValue, String) async throws -> Void
    public let rpc: @Sendable (BackendAGOPTProfileCall) async throws -> NativeRPCContext
    public let visibleRecord: (@Sendable (BackendAGOPTProfileCall, NativeRPCValue) async throws -> Bool)?
    public let completeHistory: (@Sendable (BackendAGOPTProfileCall) async throws -> Bool)?
    public init(require: @escaping @Sendable (BackendAGOPTProfileCall, String, Bool) async throws -> Void,
                authorize: @escaping @Sendable (BackendAGOPTProfileCall, String, NativeRPCValue, String) async throws -> Void,
                rpc: @escaping @Sendable (BackendAGOPTProfileCall) async throws -> NativeRPCContext,
                visibleRecord: (@Sendable (BackendAGOPTProfileCall, NativeRPCValue) async throws -> Bool)? = nil,
                completeHistory: (@Sendable (BackendAGOPTProfileCall) async throws -> Bool)? = nil) {
        self.require = require; self.authorize = authorize; self.rpc = rpc
        self.visibleRecord = visibleRecord; self.completeHistory = completeHistory
    }
}

/// A view/action facade over the original configuration, private AGS record,
/// task runtime, skill service and file authority. It owns no profile store.
public struct BackendAGOPTProfileService: Sendable {
    public struct Dependencies: Sendable {
        public var cliDefaults: (@Sendable (NativeRPCValue, String) async throws -> NativeRPCValue)? = nil
        public let dashboard: (@Sendable (String) async throws -> NativeRPCValue)?
        public let runs: (@Sendable (String, Int?) async throws -> [NativeRPCValue])?
        public let budget: (@Sendable (String) async throws -> NativeRPCValue)?
        public let skills: (@Sendable (BackendAGOPTProfileCall, String) async throws -> NativeRPCValue)?
        public let choices: (@Sendable (BackendAGOPTProfileCall, String) async throws -> NativeRPCValue)?
        public let routines: (@Sendable (BackendAGOPTProfileCall, String) async throws -> NativeRPCValue)?
        public let perform: (@Sendable (BackendAGOPTProfileCall, String, String, String?) async throws -> NativeRPCValue)?
        /// The canonical field writer owns exact field approval and key narrowing.
        public let settingsSet: (@Sendable (BackendAGOPTProfileCall, String, String, NativeRPCValue) async throws -> NativeRPCValue)?
        public let instructionsGet: (@Sendable (BackendAGOPTProfileCall, String, NativeRPCValue) async throws -> NativeRPCValue)?
        public let instructionsSet: (@Sendable (BackendAGOPTProfileCall, String, NativeRPCValue, String, String, Bool) async throws -> NativeRPCValue)?
        public let hoot: (@Sendable (BackendAGOPTProfileCall) async throws -> NativeRPCValue)?
        public init(dashboard: (@Sendable (String) async throws -> NativeRPCValue)? = nil,
                    runs: (@Sendable (String, Int?) async throws -> [NativeRPCValue])? = nil,
                    budget: (@Sendable (String) async throws -> NativeRPCValue)? = nil,
                    skills: (@Sendable (BackendAGOPTProfileCall, String) async throws -> NativeRPCValue)? = nil,
                    choices: (@Sendable (BackendAGOPTProfileCall, String) async throws -> NativeRPCValue)? = nil,
                    routines: (@Sendable (BackendAGOPTProfileCall, String) async throws -> NativeRPCValue)? = nil,
                    perform: (@Sendable (BackendAGOPTProfileCall, String, String, String?) async throws -> NativeRPCValue)? = nil,
                    settingsSet: (@Sendable (BackendAGOPTProfileCall, String, String, NativeRPCValue) async throws -> NativeRPCValue)? = nil,
                    instructionsGet: (@Sendable (BackendAGOPTProfileCall, String, NativeRPCValue) async throws -> NativeRPCValue)? = nil,
                    instructionsSet: (@Sendable (BackendAGOPTProfileCall, String, NativeRPCValue, String, String, Bool) async throws -> NativeRPCValue)? = nil,
                    hoot: (@Sendable (BackendAGOPTProfileCall) async throws -> NativeRPCValue)? = nil) {
            self.dashboard = dashboard; self.runs = runs; self.budget = budget; self.skills = skills; self.routines = routines
            self.choices = choices; self.perform = perform; self.settingsSet = settingsSet; self.instructionsGet = instructionsGet
            self.instructionsSet = instructionsSet; self.hoot = hoot
        }
    }
    public let configuration: BackendTaskConfiguration
    public let ags: BackendAGSStore
    public let access: BackendAGOPTProfileAccess
    public let dependencies: Dependencies
    public init(configuration: BackendTaskConfiguration, ags: BackendAGSStore, access: BackendAGOPTProfileAccess, dependencies: Dependencies) {
        self.configuration = configuration; self.ags = ags; self.access = access; self.dependencies = dependencies
    }
    private func row(_ id: String, call: BackendAGOPTProfileCall, change: Bool = false) async throws -> NativeRPCValue {
        try await access.require(call, id, change)
        guard let row = try await configuration.agent(id), row["id"].string == id else {
            throw NativeRPCError(code: "missing-agent", message: "That saved agent no longer exists.")
        }
        return row
    }
    public func profile(_ id: String, call: BackendAGOPTProfileCall) async throws -> NativeRPCValue {
        if id == AGTDirectory.hootID {
            try await access.require(call, id, false)
            guard let hoot = dependencies.hoot else { throw unavailable("Hoot's existing profile") }
            return publicValue(try await hoot(call), call: call)
        }
        let profile = try await row(id, call: call)
        let base = try BackendAGSProfileProjection.settings(profile, defaultProvider: profile["provider"].string ?? "claude")
        let settings = try await ags.controlsView(profile: id, base: base)
        let dashboard = try await dependencies.dashboard?(id) ?? sectionUnavailable("The agent runtime")
        let runs: NativeRPCValue
        if let read = dependencies.runs { runs = .array(try await read(id, nil)) } else { runs = sectionUnavailable("Run history") }
        let skills = try await dependencies.skills?(call, id) ?? sectionUnavailable("The existing Skills service")
        let routines = try await dependencies.routines?(call, id) ?? sectionUnavailable("The existing Routines service")
        let budget = try await scopedBudget(safeBudget(try await dependencies.budget?(id) ?? sectionUnavailable("The monthly budget runtime")), call: call)
        var safeProfile = profile.removing("instructions").removing("creatorKeyId").removing("keyInitializedFields")
        safeProfile = safeProfile.setting("routines", routines)
        let api = dashboard["stats"]["isAPIAccount"].bool == true
        var stats = api ? dashboard["stats"] : dashboard["stats"].setting("costUSD", .null)
        let safeRuns = try await scopedRecords(runs, call: call, api: api)
        let tasks = try await scopedRecords(dashboard["tasks"], call: call, api: api)
        var runtime = dashboard["runtime"].isNullish ? dashboard : dashboard["runtime"]
        if case .tool = call, !(try await hasCompleteHistory(call)) {
            stats = .object([.init("isAPIAccount", dashboard["stats"]["isAPIAccount"]), .init("coverage", .string("current-granted-records"))])
            if !(try await visible(runtime, call: call)) { runtime = .object([.init("state", runtime["state"]), .init("coverage", .string("scope-limited"))]) }
        }
        let latest = safeRuns.elements?.first
        let provider = latest?["provider"].string ?? settings["effective"]["provider"].string ?? base.provider
        let cli = try await dependencies.cliDefaults?(profile, provider) ?? .object([])
        let effective = Self.displayChoices(settings["effective"], latest: latest, cli: cli, own: settings["settings"])
        let result = NativeRPCValue.object([.init("choiceLine", AGTChoiceLine.text(run: effective).map(NativeRPCValue.string) ?? .null), .init("profile", safeProfile), .init("ags", settings.removing("profile").removing("effective")),
                        .init("effective", effective), .init("source", source(profile)),
                        .init("runtime", runtime),
                        .init("stats", stats), .init("tasks", tasks),
                        .init("runs", safeRuns), .init("skills", skills), .init("budget", budget)])
        return publicValue(result, call: call)
    }
    /// Display the last job's resolved choices without turning inferred CLI defaults into launch overrides.
    public static func displayChoices(_ settings: NativeRPCValue, latest: NativeRPCValue?, cli: NativeRPCValue, own: NativeRPCValue = .null) -> NativeRPCValue {
        var value = settings
        var sources = latest?["sources"] ?? .object([])
        for (field, requested) in [("model", "requested_model"), ("effort", "requested_effort")] {
            let chosen = latest == nil ? settings[field].string ?? cli[field].string : latest?[requested].string ?? cli[field].string
            value = value.setting(field, chosen.map(NativeRPCValue.string) ?? .null)
                .setting(requested, chosen.map(NativeRPCValue.string) ?? .null)
            if sources[field].isNullish { sources = sources.setting(field, .string(latest == nil && own[field].string != nil ? "agent" : "default")) }
        }
        if let latest {
            for field in ["provider", "permission", "playbook_job"] where !latest[field].isNullish { value = value.setting(field, latest[field]) }
        }
        if sources["ai"].isNullish { sources = sources.setting("ai", .string("agent")) }
        return value.setting("sources", sources)
    }
    public func settings(_ id: String, call: BackendAGOPTProfileCall) async throws -> NativeRPCValue {
        let profile = try await row(id, call: call)
        let base = try BackendAGSProfileProjection.settings(profile, defaultProvider: profile["provider"].string ?? "claude")
        var view = try await ags.controlsView(profile: id, base: base)
        var selected = try BackendAGSCodec.decode(AGSAgentSettings.self, view["settings"])
        var choices = NativeRPCValue.null
        if case .app(let context) = call, context.caller == .nativeApp {
            selected = try await ags.profile(id) ?? base
            view = view.setting("settings", try BackendAGSCodec.value(selected))
            choices = try await dependencies.choices?(call, id) ?? .null
        }
        let result = NativeRPCValue.object([.init("id", .string(id)), .init("profile", profile.removing("creatorKeyId").removing("keyInitializedFields")),
                        .init("ags", view.removing("profile")), .init("values", try BackendAGOPTProfileFieldAdapter.values(profile: profile, settings: selected)),
                        .init("source", source(profile)), .init("choices", choices), .init("toolUseRestrictionProblem", ToolUseRestrictions.problem(profile["toolUseRestrictions"]).map(NativeRPCValue.string) ?? .null)])
        return publicValue(result, call: call)
    }
    public func setSetting(_ id: String, field: String, value: NativeRPCValue, call: BackendAGOPTProfileCall) async throws -> NativeRPCValue {
        _ = try await row(id, call: call, change: true)
        guard BackendAGOPTProfileFields.names.contains(field) else { throw NativeRPCError.invalidArguments("Choose an existing agent settings field.") }
        guard let set = dependencies.settingsSet else { throw unavailable("The canonical agent settings field writer") }
        // The existing combined writer handles classification, exact owner approval,
        // private data masking, source conflict and after-approval scope checks.
        return publicValue(try await set(call, id, field, value), call: call)
    }
    public func action(_ id: String, action: String, target: String? = nil, call: BackendAGOPTProfileCall) async throws -> NativeRPCValue {
        let actions: Set<String> = ["assign_task", "wake", "pause", "resume", "duplicate", "reset_sessions", "stop_all", "archive", "settings", "show_file", "open_editor", "watch", "open_task", "open_run", "show_change", "skills", "routines", "team"]
        guard actions.contains(action) else { throw NativeRPCError.invalidArguments("Choose an existing agent action.") }
        if ["open_task", "open_run", "show_change"].contains(action), target == nil { throw NativeRPCError.invalidArguments("Choose the task or run to open.") }
        let change = ["wake", "pause", "resume", "duplicate", "reset_sessions", "stop_all", "archive"].contains(action)
        if id == AGTDirectory.hootID { try await access.require(call, id, change) }
        else { _ = try await row(id, call: call, change: change) }
        guard let perform = dependencies.perform else { throw unavailable("The agent action") }
        let args = NativeRPCValue.object([.init("id", .string(id)), .init("action", .string(action)), .init("target", target.map(NativeRPCValue.string) ?? .null)])
        if change { try await access.authorize(call, "agents.profile_action", args, sentence(action, id)) }
        if id == AGTDirectory.hootID { try await access.require(call, id, change) }
        else { _ = try await row(id, call: call, change: change) }
        return publicValue(try await perform(call, id, action, target), call: call)
    }
    public func instructions(_ id: String, call: BackendAGOPTProfileCall) async throws -> NativeRPCValue {
        let profile = try await row(id, call: call)
        guard let read = dependencies.instructionsGet else { throw unavailable("The existing authorized agent file reader") }
        return try await read(call, id, profile)
    }
    public func saveInstructions(_ id: String, text: String, hash: String, keepMine: Bool, call: BackendAGOPTProfileCall) async throws -> NativeRPCValue {
        let profile = try await row(id, call: call, change: true)
        guard text.utf8.count <= 512_000, !text.contains("\0"), !hash.isEmpty else { throw NativeRPCError.invalidArguments("Read the agent file first and save text under 512 KB.") }
        guard let save = dependencies.instructionsSet else { throw unavailable("The existing authorized agent file writer") }
        // The writer pins the current file before approval and rechecks it after;
        // Keep mine never becomes an unreviewed unconditional overwrite.
        return try await save(call, id, profile, text, hash, keepMine)
    }
    public func budget(_ id: String, call: BackendAGOPTProfileCall) async throws -> NativeRPCValue {
        if id == AGTDirectory.hootID { try await access.require(call, id, false) }
        else { _ = try await row(id, call: call) }
        guard let read = dependencies.budget else { throw unavailable("The monthly budget runtime") }
        return publicValue(try await scopedBudget(safeBudget(try await read(id)), call: call), call: call)
    }
    private func hasCompleteHistory(_ call: BackendAGOPTProfileCall) async throws -> Bool {
        if case .app = call { return true }
        return try await access.completeHistory?(call) ?? false
    }
    private func visible(_ value: NativeRPCValue, call: BackendAGOPTProfileCall) async throws -> Bool {
        if case .app = call { return true }
        return try await access.visibleRecord?(call, value) ?? false
    }
    private func scopedRecords(_ value: NativeRPCValue, call: BackendAGOPTProfileCall, api: Bool) async throws -> NativeRPCValue {
        guard let records = value.elements else { return value }
        var granted: [NativeRPCValue] = []
        for record in records {
            if try await visible(record, call: call) { granted.append(api ? record : record.setting("costUSD", .null).setting("cost_usd", .null)) }
        }
        return .array(granted)
    }
    private func scopedBudget(_ value: NativeRPCValue, call: BackendAGOPTProfileCall) async throws -> NativeRPCValue {
        guard !(try await hasCompleteHistory(call)) else { return value }
        return value.setting("used", .null).setting("spent", .null).setting("tokens", .null).setting("costUSD", .null).setting("cost_usd", .null).setting("days", .array([])).setting("coverage", .string("scope-limited"))
    }
    private func publicValue(_ value: NativeRPCValue, call: BackendAGOPTProfileCall) -> NativeRPCValue {
        guard case .tool = call else { return value }
        let privateNames: Set<String> = ["account", "account_id", "accountID", "accountId", "configDir", "configDirectory", "sourceFile", "sourceDirectory", "instructionsFile", "managed_path", "path", "cwd", "environment", "environment_variables", "hooks", "creatorKeyId", "keyInitializedFields"]
        func clean(_ value: NativeRPCValue) -> NativeRPCValue {
            if let fields = value.fields { return .object(fields.filter { !privateNames.contains($0.key) }.map { .init($0.key, clean($0.value)) }) }
            if let values = value.elements { return .array(values.map(clean)) }
            return value
        }
        return clean(value)
    }
    public func setBudget(_ id: String, field: String, value: NativeRPCValue, call: BackendAGOPTProfileCall) async throws -> NativeRPCValue {
        let allowed: Set<String> = ["monthly_token_budget", "monthly_budget_usd", "warn_percent", "on_exhaustion", "per_task_token_budget"]
        guard allowed.contains(field) else { throw NativeRPCError.invalidArguments("Choose an existing budget setting.") }
        return try await setSetting(id, field: field, value: value, call: call)
    }
    private func safeBudget(_ value: NativeRPCValue) -> NativeRPCValue {
        guard value["billing_kind"].string != "api" else { return value }
        var safe = value.setting("cost_usd", .null).setting("costUSD", .null)
        if value["unit"].string == "usd" { safe = safe.setting("unit", .string("unknown")).setting("used", .null) }
        if let days = value["days"].elements { safe = safe.setting("days", .array(days.map { $0.setting("cost_usd", .null).setting("costUSD", .null) })) }
        return safe
    }
    private func source(_ profile: NativeRPCValue) -> NativeRPCValue {
        let imported = profile["sourceFile"].string
        let managed = profile["instructionsFile"].string
        return .object([.init("path", (imported ?? managed).map(NativeRPCValue.string) ?? .null),
                        .init("imported", .bool(imported != nil)), .init("managed_path", managed.map(NativeRPCValue.string) ?? .null),
                        .init("has_extra_instructions", .bool(imported != nil || profile.has("extraTaskInstructions"))),
                        .init("separateExtraInstructions", .bool(imported != nil || profile.has("extraTaskInstructions")))])
    }
    private func sentence(_ action: String, _ id: String) -> String {
        switch action {
        case "assign_task": "Open a new task sheet for \(id). This does not create or start a task."
        case "wake": "Start \(id)'s next queued task, or its actual configured standing check."
        case "reset_sessions": "Forget the sessions \(id) reuses. Current sessions are not ended."
        case "stop_all": "Stop all running tasks and exactly attributed sessions for \(id)."
        case "archive": "Archive \(id) and stop its assigned routines. Its file stays."
        default: "\(action.replacingOccurrences(of: "_", with: " ").capitalized) for \(id)."
        }
    }
    private func unavailable(_ name: String) -> NativeRPCError { .init(code: "unavailable", message: name + " is not connected yet.") }
    private func sectionUnavailable(_ name: String) -> NativeRPCValue { .object([.init("state", .string("unavailable")), .init("message", .string(name + " is not connected yet."))]) }
}

public enum BackendAGOPTProfileFields {
    public static let profile: [String: String] = ["tool_use_restrictions": "toolUseRestrictions", "name": "name", "picture": "icon", "role": "role", "project": "projectId", "reports_to": "reportsTo", "reviewer": "reviewerAgent", "coding_ai": "provider", "account": "account", "model": "model", "effort": "effort", "before_it_changes_files": "permissionMode", "tasks_at_once": "maxConcurrent", "longest_run": "maxRunMinutes", "keep_open_minutes": "keepAliveMinutes", "keep_open_until_close": "keepAliveUntilClose", "tools_it_should_use": "toolsPreferred", "tools_it_must_not_use": "blockedTools", "turn_all_skills_off": "skillsOff", "working_folder": "defaultProject", "claude_code_agent_name": "claudeAgent", "check_command": "verifyCommand", "extra_task_instructions": "extraTaskInstructions"]
    public static let privateSettings: [String: String] = ["mcp_servers": "mcpServers", "hooks": "hooks", "environment_variables": "environment"]
    public static let efficiency: [String: String] = ["reuse_session": "reuseContext", "stop_when_done": "completion", "heavy_jobs_one_at_a_time": "serializeHeavyJobs", "extra_tools_off": "addonsOff", "monthly_token_budget": "agentTokenBudget", "monthly_budget_usd": "monthlyBudgetUSD", "on_exhaustion": "onExhaustion", "warn_percent": "warningPercent", "per_task_token_budget": "taskTokenBudget"]
    public static var names: Set<String> { Set(profile.keys).union(privateSettings.keys).union(efficiency.keys) }
}
