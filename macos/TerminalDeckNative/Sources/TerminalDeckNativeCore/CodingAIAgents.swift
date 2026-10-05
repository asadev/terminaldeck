import Foundation

// The agents half of Settings → Coding AI: what is installed, which agents can
// hold another login, the Add-accounts menu, the Default coding tool picker,
// the Primary account picker, the stale-CLI warning and the Setup notice.
// Ports of `AgentsSection.tsx`, `ProviderPicker.tsx`, `account-agent.ts`,
// `AgentCliUpdate.tsx` and `SetupSection.tsx`, in their words.

// MARK: - What is installed (`prereq:check`)

public struct CodingAITool: Equatable, Sendable, Identifiable {
    public enum State: String, Equatable, Sendable {
        case ready
        case installedNotAuthed = "installed-not-authed"
        case missing
        case unknown
    }

    public var id: String
    public var label: String
    public var state: State
    public var version: String?
    public var purpose: String
    public var remedy: String?
    /// A caveat even when nothing is wrong (e.g. runs from a copy other than the one on PATH).
    public var note: String?
    public var url: String?
    public var required: Bool

    public init(id: String, label: String, state: State, version: String? = nil, purpose: String = "",
                remedy: String? = nil, note: String? = nil, url: String? = nil, required: Bool = false) {
        self.id = id
        self.label = label
        self.state = state
        self.version = version
        self.purpose = purpose
        self.remedy = remedy
        self.note = note
        self.url = url
        self.required = required
    }

    public static let noVersion = "version not reported"
    public static let noVersionHint = "Found on PATH, but it did not answer when asked for its version — usually a broken or partial install."

    /// `toolVersionLabel`: the version, "version not reported", or nothing for a missing tool.
    public var versionLabel: String? {
        if let version, !version.isEmpty { return version }
        if state == .missing { return nil }
        return Self.noVersion
    }
}

public struct CodingAIPrerequisites: Equatable, Sendable {
    public var tools: [CodingAITool]
    public var canRunSessions: Bool
    public var needsLogin: Bool

    public init(tools: [CodingAITool], canRunSessions: Bool = true, needsLogin: Bool = false) {
        self.tools = tools
        self.canRunSessions = canRunSessions
        self.needsLogin = needsLogin
    }

    /// `toPrerequisites`: nil when there is no tools list at all.
    public static func parse(_ value: CodingAIJSON) -> CodingAIPrerequisites? {
        guard let list = value["tools"].array else { return nil }
        let tools: [CodingAITool] = list.compactMap { entry in
            guard entry.isObject, let id = entry["id"].string else { return nil }
            return CodingAITool(
                id: id,
                label: entry["label"].string ?? id,
                state: entry["state"].string.flatMap(CodingAITool.State.init(rawValue:)) ?? .unknown,
                version: entry["version"].string,
                purpose: entry["purpose"].string ?? "",
                remedy: entry["remedy"].string,
                note: entry["note"].string,
                url: entry["url"].string,
                required: entry["required"].isTrue)
        }
        return CodingAIPrerequisites(tools: tools, canRunSessions: value["canRunSessions"].isTrue, needsLogin: value["needsLogin"].isTrue)
    }

    /// `agentsPresent`: the coding agents the probe found. A missing agent is not a row.
    public var agentsPresent: [CodingAITool] {
        let ids = CodingAICatalog.lookup.map(\.id)
        return tools.filter { ids.contains($0.id) && $0.state != .missing }
    }
}

// MARK: - Which agents can hold a login (`providers:detect` + `profiles:account-providers`)

/// What the main process said about one agent's accounts.
public struct CodingAIAccountProviderView: Equatable, Sendable {
    public var id: String
    public var label: String
    public var supported: Bool
    public var canSignIn: Bool
    public var configEnv: String?
    public var reason: String?

    /// `parseAccountProviders`: only an explicit `true` is support.
    public static func parse(_ value: CodingAIJSON) -> [CodingAIAccountProviderView] {
        guard let list = value["providers"].array else { return [] }
        return list.compactMap { row in
            guard row.isObject, let id = row["id"].text else { return nil }
            let supported = row["supported"].isTrue
            return CodingAIAccountProviderView(
                id: id,
                label: row["label"].text ?? id,
                supported: supported,
                canSignIn: row["canSignIn"].isTrue || supported,
                configEnv: row["configEnv"].string,
                reason: row["reason"].text)
        }
    }
}

/// One agent as the account screens see it (`AccountProviderRow`).
public struct CodingAIProviderRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var description: String
    public var install: String?
    /// The agent starts on this machine (measured by running it).
    public var available: Bool
    public var reason: String?
    /// Installed and able to hold another login.
    public var canAdd: Bool
    public var canSignIn: Bool
    /// Why it cannot hold another login, when it cannot.
    public var note: String?

    public init(id: String, label: String, description: String = "", install: String? = nil, available: Bool,
                reason: String? = nil, canAdd: Bool, canSignIn: Bool = true, note: String? = nil) {
        self.id = id
        self.label = label
        self.description = description
        self.install = install
        self.available = available
        self.reason = reason
        self.canAdd = canAdd
        self.canSignIn = canSignIn
        self.note = note
    }

    /// The tag beside the name in the Add-account popup.
    public var tag: String? {
        if available && !canAdd { return "One login only" }
        if !available { return "Not installed" }
        return nil
    }
}

/// One measured fact about an agent that stops Sign in.
public struct CodingAIAgentProblem: Equatable, Sendable {
    public var text: String
    public var install: String?
}

public enum CodingAIProviders {
    /// `installedProviders`: nil means "could not tell" (fail open), never "none".
    public static func installed(_ detected: CodingAIJSON) -> [String]? {
        guard let map = detected.object, !map.isEmpty else { return nil }
        return map.compactMap { id, value in
            let truthy: Bool
            switch value {
            case .bool(let flag): truthy = flag
            case .number(let number): truthy = number != 0
            case .string(let text): truthy = !text.isEmpty
            case .array, .object: truthy = true
            case .null: truthy = false
            }
            return truthy && CodingAICatalog.isProvider(id) ? id : nil
        }
    }

    /// `buildAccountProviderRows`: every agent but the shell, in catalogue order.
    public static func rows(detected: CodingAIJSON, fromMain: [CodingAIAccountProviderView]) -> [CodingAIProviderRow] {
        let found = installed(detected)
        return CodingAICatalog.all.filter { $0.id != "shell" }.map { agent in
            let available = found == nil || found!.contains(agent.id)
            let said = fromMain.first { $0.id == agent.id }
            let supported = said?.supported ?? agent.canHaveAccounts
            let note = supported ? nil : (said?.reason ?? agent.loginsNote)
            return CodingAIProviderRow(
                id: agent.id,
                label: agent.label,
                description: agent.description,
                install: agent.install,
                available: available,
                reason: available ? nil : "Terminal Deck could not start `\(agent.bin ?? agent.id)` on this machine.",
                canAdd: supported && available,
                canSignIn: said?.canSignIn ?? agent.hasAnyLogin,
                note: note)
        }
    }

    /// Can a session be opened on this agent right now? Unknown agent: allowed.
    public static func agentCanStart(_ rows: [CodingAIProviderRow], _ provider: String?) -> Bool {
        guard let provider else { return true }
        guard let row = rows.first(where: { $0.id == provider }) else { return true }
        return row.available
    }

    /// What to say instead of offering Sign in.
    public static func agentProblem(_ rows: [CodingAIProviderRow], _ provider: String?) -> CodingAIAgentProblem? {
        guard let provider, let row = rows.first(where: { $0.id == provider }), !row.available else { return nil }
        return CodingAIAgentProblem(
            text: "\(row.label) will not start on this machine, so signing in cannot open a session yet.",
            install: row.install)
    }

    /// Can this agent hold more than one login? Unknown agent: yes.
    public static func canHaveMore(_ rows: [CodingAIProviderRow], _ provider: String?) -> Bool {
        guard let provider else { return true }
        guard let row = rows.first(where: { $0.id == provider }) else { return true }
        return row.canAdd
    }

    /// `chosenAccountProvider`: the clicked agent if it can take one, else the first that can.
    public static func chosen(_ rows: [CodingAIProviderRow], selected: String?) -> CodingAIProviderRow? {
        rows.first { $0.id == selected && $0.canAdd } ?? rows.first { $0.canAdd }
    }
}

// MARK: - The Add accounts menu

public struct CodingAIAddAccountsRow: Equatable, Sendable, Identifiable {
    public enum Action: String, Equatable, Sendable {
        case addAccount = "add-account"
        case signIn = "sign-in"
        case install
        case none
    }

    public var id: String
    public var label: String
    public var url: String?
    public var installed: Bool
    public var run: CodingAIAccountRun.Kind
    /// The logins of this agent anybody named.
    public var logins: [String]
    public var action: Action

    public var actionTitle: String? {
        switch action {
        case .addAccount: return "Add account"
        case .signIn: return "Sign in"
        case .install: return "Install"
        case .none: return nil
        }
    }
}

public enum CodingAIAddAccounts {
    /// The inputs of the menu, worked out from what the screen already holds.
    public struct Facts: Equatable, Sendable {
        public var present: Set<String>
        public var addable: Set<String>
        public var signedIn: Set<String>
        public var signInable: Set<String>
        public var logins: [String: [String]]
        public var hasAccounts: Set<String>
    }

    /// `AgentsSection`'s derivations: who is installed, who can take another
    /// login, who is signed in (and as whom), and whose install login can be
    /// signed in from here.
    public static func facts(
        prerequisites: CodingAIPrerequisites?,
        providerRows: [CodingAIProviderRow],
        accounts: [CodingAIAccount],
        signIn: [String: CodingAISignIn]
    ) -> Facts {
        let agents = prerequisites?.agentsPresent ?? []
        let present = Set(agents.map(\.id))
        // A row has to exist and say yes — no agent offers Add before the answer lands.
        let addable = Set(agents.filter { tool in providerRows.contains { $0.id == tool.id && $0.canAdd } }.map(\.id))
        var signedIn = Set<String>()
        var logins: [String: [String]] = [:]
        for account in accounts {
            guard let provider = account.provider, signIn[account.id]?.state == .signedIn else { continue }
            signedIn.insert(provider)
            if let named = CodingAIAccountLabels.namedLogin(account, signIn[account.id]) {
                logins[provider, default: []].append(named)
            }
        }
        let hasAccounts = Set(accounts.filter { !$0.system && $0.provider != nil }.compactMap(\.provider))
        let signInable = Set(agents.filter { tool in accounts.contains { $0.provider == tool.id && $0.system } }.map(\.id))
        return Facts(present: present, addable: addable, signedIn: signedIn, signInable: signInable, logins: logins, hasAccounts: hasAccounts)
    }

    /// `addAccountsRows`: one action per row, decided once.
    public static func rows(_ facts: Facts, canAdd: Bool, canSignIn: Bool) -> [CodingAIAddAccountsRow] {
        let addable = canAdd ? facts.addable : []
        let signInable = canSignIn ? facts.signInable : []
        return CodingAICatalog.lookup.map { entry in
            let installed = facts.present.contains(entry.id)
            let signedIn = facts.signedIn.contains(entry.id)
            let offerAnother = signedIn || facts.hasAccounts.contains(entry.id)
            let action: CodingAIAddAccountsRow.Action
            if !installed {
                action = entry.url != nil ? .install : .none
            } else if offerAnother {
                action = addable.contains(entry.id) ? .addAccount : .none
            } else if signInable.contains(entry.id) {
                action = .signIn
            } else if addable.contains(entry.id) {
                action = .addAccount
            } else {
                action = .none
            }
            return CodingAIAddAccountsRow(
                id: entry.id,
                label: entry.label,
                url: entry.url,
                installed: installed,
                run: signedIn ? .signedIn : .notSignedIn,
                logins: facts.logins[entry.id] ?? [],
                action: action)
        }
    }
}

// MARK: - Default coding tool

public enum CodingAIDefaultTool {
    public struct Option: Equatable, Sendable, Identifiable {
        public var value: String
        public var label: String
        public var disabled: Bool
        public var suffix: String?
        public var id: String { value }
        /// What the picker prints: `Codex CLI — not installed`.
        public var title: String { suffix.map { "\(label) — \($0)" } ?? label }
    }

    public static let settingId = "agents.defaultProvider"
    public static let prefsKey = "defaultProvider"
    public static let label = "Default coding tool"
    public static let help = "Runs when you start a session."
    public static let more = "Unless the project or the new-session dialog says otherwise. A tool that is not on your PATH is greyed out here rather than offered and then failing to start."
    public static let fallback = "claude"
    public static let choices: [(value: String, label: String)] = [
        ("claude", "Claude Code"), ("codex", "Codex CLI"), ("gemini", "Gemini CLI"), ("shell", "Plain shell"),
    ]

    /// `optionStateFor`: a missing tool is greyed with a reason; one that needs a login says so.
    public static func options(_ prerequisites: CodingAIPrerequisites?) -> [Option] {
        choices.map { choice in
            var option = Option(value: choice.value, label: choice.label, disabled: false, suffix: nil)
            guard choice.value != "shell", let prerequisites,
                  let tool = prerequisites.tools.first(where: { $0.id == choice.value }) else { return option }
            if tool.state == .missing {
                option.disabled = true
                option.suffix = "not installed"
            } else if tool.state == .installedNotAuthed {
                option.suffix = "sign-in needed"
            }
            return option
        }
    }

    /// The stored value: preferences win, then the settings file (old name too), then Claude Code.
    public static func current(settings: CodingAIJSON, preferences: CodingAIJSON) -> String {
        let valid = Set(choices.map(\.value))
        if let value = preferences[prefsKey].string, valid.contains(value) { return value }
        let stored = CodingAISettingsValues.stored(settings)
        for key in [settingId, "general.defaultProvider"] {
            if let value = stored[key]?.string, valid.contains(value) { return value }
        }
        return fallback
    }
}

// MARK: - The values the main window behaves by

/// What the Settings page hands the main window after a save (`{type:'changed', values}`).
///
/// The page sends its whole merged copy — the settings file with old names
/// moved to new ones, and the four preferences over it — and the main window
/// replaces its own with it. A native save has to send the same shape, or the
/// main window keeps starting sessions on the old default until it relaunches.
public enum CodingAISettingsValues {
    /// `RENAMED_IDS` in `settings-schema.ts`.
    public static let renamed: [String: String] = [
        "notifications.sound": "notifications.onFinishSound",
        "general.soundOnFinish": "notifications.onFinishSound",
        "general.notifyOnAttention": "notifications.onNeedsInput",
        "general.showInsightAlerts": "notifications.showInsightAlerts",
        "general.defaultProvider": "agents.defaultProvider",
        "advanced.restoreSessions": "general.restoreSessions",
    ]

    /// The settings that live in the preferences store, and their key there.
    public static let fromPreferences: [(setting: String, key: String)] = [
        ("general.restoreSessions", "restoreSessions"),
        ("appearance.theme", "theme"),
        ("notifications.onComplete", "notifyOnComplete"),
        ("agents.defaultProvider", "defaultProvider"),
    ]

    /// `toStoredSettings`: the `{version, values}` envelope, or a bare map.
    public static func stored(_ settings: CodingAIJSON) -> [String: CodingAIJSON] {
        if let values = settings["values"].object { return values }
        return settings.object ?? [:]
    }

    /// The merged values: stored settings under their current names, preferences over them.
    public static func merged(settings: CodingAIJSON, preferences: CodingAIJSON) -> [String: CodingAIJSON] {
        var out: [String: CodingAIJSON] = [:]
        let stored = stored(settings)
        // Old names first, so a value stored under the current name wins.
        for (key, value) in stored where key != "__proto__" {
            if let current = renamed[key] { out[current] = value }
        }
        for (key, value) in stored where key != "__proto__" && renamed[key] == nil {
            out[key] = value
        }
        for pair in fromPreferences {
            let value = preferences[pair.key]
            if value != .null { out[pair.setting] = value }
        }
        return out
    }

    /// The relay message the main window listens for.
    public static func changedMessage(_ values: [String: CodingAIJSON]) -> CodingAIJSON {
        .object(["type": .string("changed"), "values": .object(values)])
    }
}

// MARK: - Primary account

public enum CodingAIPrimaryAccount {
    public static let label = "Primary account"
    public static let more = "One account, and only sessions of the agent it is a login of use it. Choosing an account of another agent replaces this one rather than sitting beside it."

    /// The accounts the picker may offer: not a one-login agent's install, which would change nothing.
    public static func choices(_ accounts: [CodingAIAccount], providerRows: [CodingAIProviderRow]) -> [CodingAIAccount] {
        accounts.filter { $0.provider == nil || CodingAIProviders.canHaveMore(providerRows, $0.provider) }
    }

    /// The selected id: the stored default, or the machine's own install.
    public static func selected(defaultId: String?) -> String { defaultId ?? "system" }
}

// MARK: - Agent CLIs too old to sign in (`browser-signin:agents`)

public struct CodingAIStaleAgent: Equatable, Sendable, Identifiable {
    public var command: String
    public var version: String?
    public var advice: String
    public var id: String { command }

    /// `readStaleAgents`: only the rows marked stale.
    public static func parse(_ value: CodingAIJSON) -> [CodingAIStaleAgent] {
        guard let list = value.array else { return [] }
        return list.compactMap { entry in
            guard entry.isObject, let command = entry["command"].string, entry["stale"].isTrue else { return nil }
            return CodingAIStaleAgent(command: command, version: entry["version"].string, advice: entry["advice"].string ?? "")
        }
    }

    /// The id a dismissal is filed under — a newer version is a new warning.
    public var dismissalId: String { "agent-cli:\(command)@\(version ?? "unknown")" }

    /// `withCommands`: the advice split on backticks into plain and code pieces.
    public var advicePieces: [(code: Bool, text: String)] {
        advice.components(separatedBy: "`").enumerated()
            .map { (code: $0.offset % 2 == 1, text: $0.element) }
            .filter { !$0.text.isEmpty }
    }

    /// The fix id `readiness:fix` runs.
    public static let upgradeFix = "upgrade-agent-cli"

    /// `{ ok, message }` from the upgrade, or nil when there was none.
    public static func fixResult(_ value: CodingAIJSON) -> (ok: Bool, message: String)? {
        guard value.isObject, let message = value["message"].string else { return nil }
        return (value["ok"].isTrue, message)
    }
}

/// The page's per-machine list of warnings somebody put away (`readiness.dismissed.v1`).
public struct CodingAIDismissed: Equatable, Sendable {
    public static let storageKey = "readiness.dismissed.v1"
    public static let machineScope = "*machine*"

    public var map: [String: [String]]

    public init(_ map: [String: [String]] = [:]) { self.map = map }

    /// `parseDismissed`: anything unreadable is nothing put away.
    public static func parse(_ raw: String?) -> CodingAIDismissed {
        guard let raw, !raw.isEmpty else { return CodingAIDismissed() }
        let json = CodingAIJSON.parse(raw)
        guard let object = json.object else { return CodingAIDismissed() }
        var out: [String: [String]] = [:]
        for (key, value) in object where key != "__proto__" {
            guard let list = value.array else { continue }
            let ids = list.compactMap { $0.text }
            if !ids.isEmpty { out[key] = ids }
        }
        return CodingAIDismissed(out)
    }

    public var serialized: String {
        CodingAIJSON.object(map.mapValues { .array($0.map(CodingAIJSON.string)) }).jsonText
    }

    public func isDismissed(_ id: String, scope: String = machineScope) -> Bool {
        (map[scope] ?? []).contains(id)
    }

    public func dismissing(_ id: String, scope: String = machineScope) -> CodingAIDismissed {
        guard !isDismissed(id, scope: scope) else { return self }
        var next = map
        next[scope, default: []].append(id)
        return CodingAIDismissed(next)
    }

    public func restoringAll(scope: String = machineScope) -> CodingAIDismissed {
        var next = map
        next[scope] = nil
        return CodingAIDismissed(next)
    }

    /// "1 update hidden." / "2 updates hidden."
    public static func hiddenLine(_ count: Int) -> String {
        count == 1 ? "1 update hidden." : "\(count) updates hidden."
    }
}

// MARK: - Setup (`setup:status`)

public enum CodingAISetupNotice {
    /// The one warning the Setup half of the pane draws, or nil when a session can run.
    public static func warning(_ value: CodingAIJSON) -> String? {
        guard value["tools"].array != nil else { return nil }
        guard !value["canRunSessions"].isTrue else { return nil }
        return value["needsLogin"].isTrue
            ? "An agent CLI is installed but none of them is signed in, so a new session would open at a login prompt."
            : "No agent CLI was found, so a new session can only run a plain shell."
    }

    /// Whether the answer could be read at all.
    public static func readable(_ value: CodingAIJSON) -> Bool { value["tools"].array != nil }
}
