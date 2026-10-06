import Foundation

// The account chip on a session's bar (`shell/AccountChip.tsx`, `accounts.ts`),
// and its two cousins for a session somewhere else (`machines/MachineAccountChip.tsx`,
// `machines/servers/ServerAccountChip.tsx`): which login a session runs as, and
// the rows that start (or switch to) another.

/// `parseSessionAccount` (`session:account`): which account the agent in a session really runs as.
public enum SessionAccountView: Equatable, Sendable {
    case known(provider: String, configDir: String, profileId: String?, profileName: String?, email: String?)
    case withheld(String)

    static let unreadable = "This session’s account could not be read, so none is named."

    public static func decode(_ raw: Any?) -> SessionAccountView {
        guard let record = raw as? [String: Any] else { return .withheld(unreadable) }
        if record["kind"] as? String == "withheld" {
            let reason = (record["reason"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            return .withheld(reason.isEmpty ? unreadable : reason)
        }
        guard record["kind"] as? String == "known", let dir = TerminalJSON.text(record["configDir"]),
              !dir.trimmingCharacters(in: .whitespaces).isEmpty, let provider = TerminalJSON.text(record["provider"]) else {
            return .withheld(unreadable)
        }
        let email = (record["email"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        return .known(provider: provider, configDir: dir, profileId: record["profileId"] as? String,
                      profileName: record["profileName"] as? String, email: email)
    }
}

/// What a chip says about an account: a label, a longer line, and whether the agent itself named it.
public struct AccountIdentity: Equatable, Sendable {
    public let label: String
    public let detail: String?
    public let verified: Bool
}

public enum AccountChipRules {
    /// `MENU_HEAD`, `FIXED_ACCOUNT_NOTE`.
    public static let menuHead = "Account"
    public static let fixedShell = "The agent here was started inside a shell, so this app never handed it an account and cannot restart it as another one. Picking an account opens a new session on it, and this one keeps the login it has."
    public static let fixedAgent = "This app cannot give this agent an account of its own, so this session cannot be restarted as another one. Picking an account opens a new session on it, and this one keeps the login it has."
    public static let switchedInPlace = "Switched here without a restart: its requests go out as this account. Claude Code’s own /status keeps naming the account this session started on until it restarts."
    public static let blockedFoot = "Change the default coding tool in Settings to start a session under one of these."

    /// `signInStateSummary`.
    public static func stateSummary(_ signIn: CodingAISignIn?) -> AccountIdentity {
        guard let signIn, signIn != .checking else {
            return AccountIdentity(label: "Checking…", detail: "Asking the agent which account this session is running as.", verified: false)
        }
        switch signIn.state {
        case .signedIn:
            return AccountIdentity(label: signIn.plan.map { "Signed in · \($0)" } ?? "Signed in",
                                   detail: signIn.account == nil ? "\(signIn.detail) This agent’s CLI does not print an email address." : signIn.detail,
                                   verified: false)
        case .signedOut: return AccountIdentity(label: "Not signed in", detail: signIn.detail, verified: false)
        case .unsupported: return AccountIdentity(label: "No login", detail: signIn.detail, verified: false)
        case .unknown: return AccountIdentity(label: "Account unknown", detail: signIn.detail, verified: false)
        }
    }

    /// `signInSummary`: the address the agent named, else its state.
    public static func summary(_ signIn: CodingAISignIn?) -> AccountIdentity {
        if let address = CodingAIAccountLabels.accountLabel(signIn) {
            return AccountIdentity(label: address, detail: signIn?.detail ?? "Signed in as \(address)", verified: true)
        }
        return stateSummary(signIn)
    }

    /// `accountIdentity`.
    public static func identity(_ account: (id: String, name: String, system: Bool?)?, _ signIn: CodingAISignIn?) -> AccountIdentity {
        guard let account else {
            return AccountIdentity(label: "Account", detail: "Choose which account a new session here uses.", verified: false)
        }
        let summary = summary(signIn)
        if summary.verified { return summary }
        if account.system ?? CodingAIAccountLabels.isSystemAccountId(account.id) { return summary }
        return AccountIdentity(
            label: account.name,
            detail: signIn == nil
                ? "The account you named \(account.name). Which login it holds has not been read yet."
                : "\(account.name) — \(summary.detail ?? "")",
            verified: false)
    }

    /// `oneRowPerLogin`: one row per agent and login, the preferred (or own, or latest-used) kept.
    public static func oneRowPerLogin(_ accounts: [CodingAIAccount], signIn: [String: CodingAISignIn], prefer: String?) -> [CodingAIAccount] {
        var kept: [String: CodingAIAccount] = [:]
        var order: [String] = []
        var unnamed: [CodingAIAccount] = []
        for account in accounts {
            guard let login = CodingAIAccountLabels.namedLogin(account, signIn[account.id]) else {
                unnamed.append(account)
                continue
            }
            let key = "\(account.provider ?? "")\u{0}\(login)"
            guard let held = kept[key] else {
                kept[key] = account
                order.append(key)
                continue
            }
            kept[key] = better(held, account, prefer: prefer)
        }
        return order.compactMap { kept[$0] } + unnamed
    }

    static func better(_ held: CodingAIAccount, _ next: CodingAIAccount, prefer: String?) -> CodingAIAccount {
        if let prefer {
            if held.id == prefer { return held }
            if next.id == prefer { return next }
        }
        if held.system != next.system { return held.system ? held : next }
        return (next.lastUsedAt ?? -1) > (held.lastUsedAt ?? -1) ? next : held
    }

    /// `accountForFolder`: the project's default, else the app's, else the system install, else the first.
    public static func accountForFolder(_ snapshot: CodingAIAccountsSnapshot, projectPath: String?) -> CodingAIAccount? {
        func known(_ id: String?) -> CodingAIAccount? { id.flatMap { id in snapshot.accounts.first { $0.id == id } } }
        return known(projectPath.flatMap { snapshot.projectDefaults[$0] }) ?? known(snapshot.defaultId)
            ?? snapshot.accounts.first { $0.system } ?? snapshot.accounts.first
    }

    /// `fixedAccountNote`: why picking cannot switch this session, when it cannot.
    public static func fixedNote(hasSession: Bool, showAccount: Bool, switching: Bool, sessionAgent: String?, sessionProvider: String?) -> String? {
        guard hasSession, showAccount, !switching, sessionAgent == nil else { return nil }
        return sessionProvider == "shell" ? fixedShell : fixedAgent
    }

    /// `chipMode`: a named account, the "Run …" button (a shell with no agent in it), or nothing.
    public enum Mode: Equatable, Sendable { case account, run, none }
    public static func mode(hasSession: Bool, agentRunning: Bool?) -> Mode {
        guard hasSession else { return .account }
        switch agentRunning {
        case true?: return .account
        case false?: return .run
        case nil: return .none
        }
    }

    /// `runAgentCommand`: what the Run button types (the agent's binary and arguments, then Return).
    public static func runCommand(_ provider: String?) -> (label: String, command: String)? {
        switch provider {
        case "claude": return ("Claude Code", "claude\r")
        case "codex": return ("Codex CLI", "codex\r")
        case "gemini": return ("Gemini CLI", "gemini\r")
        default: return nil
        }
    }

    /// The chip's hover label for a named account.
    public static func chipHelp(switching: Bool, named: Bool, chosenName: String?, identityDetail: String?, switchedInPlace: Bool) -> String {
        [switching
            ? "This session is running as this account — pick another to run this session as instead."
            : named ? "This session is running as this account — start one under a different account."
                    : "A new session here would use this account.",
         chosenName.map { "Account: \($0)." }, identityDetail, switchedInPlace ? switchedInPlace_ : nil]
            .compactMap { $0 }.joined(separator: " ")
    }
    private static let switchedInPlace_ = switchedInPlace

    /// The "only a … account can run this session" ⓘ.
    public static func foreignNote(_ agentLabel: String?) -> String {
        "Only a \(agentLabel ?? "matching") account can run this session — an account is a login of one agent."
    }
}

/// `session:switch-armed`: switches waiting for the person's next message.
public struct ArmedSwitch: Equatable, Sendable {
    public let sessionId: String
    public let profileId: String
    public let accountName: String
    public let note: String

    public static func list(_ raw: Any?) -> [ArmedSwitch] {
        (raw as? [Any] ?? []).compactMap {
            guard let r = $0 as? [String: Any], let id = r["sessionId"] as? String else { return nil }
            return ArmedSwitch(sessionId: id, profileId: r["profileId"] as? String ?? "", accountName: r["accountName"] as? String ?? "",
                               note: r["note"] as? String ?? "")
        }
    }

    public var help: String { "Switching to \(accountName) when you send your next message." }
}

// MARK: - A session on a paired machine (`machines:account:read` / `:switch`)

public struct MachineAccount: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let provider: String?
    public let color: String?
    public let system: Bool
    public let signIn: CodingAISignIn?

    /// `NOT_REPORTED`: a build over there too old to say which login it holds.
    public static let notReported = CodingAISignIn(state: .unknown, detail: "That machine is running a build that does not say which login it is signed in as.")
    public var signInOrNotReported: CodingAISignIn { signIn ?? Self.notReported }

    public var asAccount: CodingAIAccount {
        CodingAIAccount(id: id, name: name, provider: provider, system: system, color: color ?? "--accent")
    }

    public static func decode(_ raw: Any?) -> MachineAccount? {
        guard let r = raw as? [String: Any], let id = TerminalJSON.text(r["id"]), let name = TerminalJSON.text(r["name"]) else { return nil }
        return MachineAccount(id: id, name: name, provider: r["provider"] as? String, color: TerminalJSON.text(r["color"]),
                              system: TerminalJSON.bool(r["system"]) == true,
                              signIn: (r["signIn"] as? [String: Any]).map { CodingAIAccountsParse.signIn(CodingAIJSON($0)) })
    }

    /// `readAccountState`: the session's own account and the rest of the machine's.
    public static func state(_ raw: Any?) -> (current: MachineAccount?, accounts: [MachineAccount])? {
        guard let r = raw as? [String: Any] else { return nil }
        return (decode(r["current"]), (r["accounts"] as? [Any] ?? []).compactMap(decode))
    }

    /// What `machines:account:switch` answers.
    public static func switchAnswer(_ raw: Any?) -> (ok: Bool, message: String, session: String?) {
        guard let r = raw as? [String: Any] else { return (false, "That machine did not answer.", nil) }
        return (TerminalJSON.bool(r["ok"]) == true, r["message"] as? String ?? "", TerminalJSON.text(r["session"]))
    }
}

// MARK: - A shell on a server (`servers:shell:account`)

public enum ServerSignIn: Equatable, Sendable {
    case yes(agents: Int, logins: [(agentId: String, account: String?)])
    case cannot(String)

    public static func == (a: ServerSignIn, b: ServerSignIn) -> Bool {
        switch (a, b) {
        case let (.cannot(x), .cannot(y)): return x == y
        case let (.yes(n, l), .yes(m, k)):
            return n == m && l.count == k.count && zip(l, k).allSatisfy { $0.agentId == $1.agentId && $0.account == $1.account }
        default: return false
        }
    }

    /// `asServerSignIn`.
    public static func decode(_ raw: Any?) -> ServerSignIn? {
        guard let r = raw as? [String: Any] else { return nil }
        if r["known"] as? String == "cannot" {
            return .cannot(TerminalJSON.text(r["why"]) ?? "This server did not say.")
        }
        guard r["known"] as? String == "yes" else { return nil }
        let agents = max(0, TerminalJSON.int(r["agents"]) ?? 0)
        let logins: [(agentId: String, account: String?)] = (r["logins"] as? [Any] ?? []).compactMap {
            guard let row = $0 as? [String: Any], let agent = TerminalJSON.text(row["agentId"]) else { return nil }
            return (agent, TerminalJSON.text(row["account"]))
        }
        return .yes(agents: max(agents, logins.count), logins: logins)
    }

    public static let note = "These are the coding logins of the account this shell signed in as. This app did not start what is running in this terminal, so nothing here can restart it as somebody else — picking a login opens a new terminal on this server with that agent running, and this one keeps what it has. The logins themselves are changed by signing in, under Manage sign-ins below."

    /// `signInLine`: the chip's words and its hover label.
    public func words(_ where_: String) -> (line: String, title: String) {
        let place = where_.isEmpty ? "this server" : where_
        switch self {
        case .cannot(let why):
            return ("Coding logins unknown", "\(why) So this app cannot say which login a coding agent started in this terminal would run as.")
        case .yes(let agents, let logins):
            if logins.isEmpty {
                return agents == 0
                    ? ("No coding agent here", "The account you signed in to \(place) as has no coding agent installed. Settings → Coding AI → Servers can put one there and sign it in.")
                    : ("No coding login here", "A coding agent is installed on \(place) under the account you signed in as, and none of them has a login. Settings → Coding AI → Servers signs one in.")
            }
            let named = logins.map { "\(Self.agentLabel($0.agentId))\($0.account.map { " signs in as \($0)" } ?? " is signed in")" }
            return (named.joined(separator: " · "),
                    "\(named.joined(separator: ". ")). That is the login the account you signed in to \(place) as holds. This app did not start what is running in this terminal, so it is a fact about that account rather than about this session.")
        }
    }

    /// `menuStateLine`.
    public func menuState(_ serverName: String) -> String? {
        switch self {
        case .cannot(let why): return why
        case .yes(let agents, let logins):
            if agents == 0 { return "No coding agent is installed on \(serverName.isEmpty ? "this server" : serverName)." }
            if logins.isEmpty { return "A coding agent is installed there and none of them has a login." }
            return nil
        }
    }

    public var logins: [(agentId: String, account: String?)] {
        if case .yes(_, let logins) = self { return logins }
        return []
    }

    public static func agentLabel(_ id: String) -> String {
        switch id {
        case "claude": return "Claude Code"
        case "codex": return "Codex CLI"
        case "gemini": return "Gemini CLI"
        case "shell": return "Shell"
        default: return id
        }
    }

    /// `agentCommand`: what a new terminal runs for that agent.
    public static func command(_ agentId: String) -> String {
        ["claude", "codex", "gemini"].contains(agentId) ? agentId : agentId
    }
}

// MARK: - The note under the chip (`accountSwitchNote` / `switchingNote`)

/// "Switching to …" from the pick, then "Switched to …" for the page's four
/// seconds, for one session. The page holds the switcher and clears the note
/// itself; this is what its tabs state says (`accountSwitch`).
public struct AccountSwitchNote: Equatable, Sendable, Decodable {
    public enum State: String, Sendable, Decodable { case working, done }
    public var sessionId: String
    public var state: State
    public var text: String

    public init(sessionId: String, state: State, text: String) {
        self.sessionId = sessionId
        self.state = state
        self.text = text
    }

    /// The note for the session a bar is drawn for, or nil (another session's, or empty).
    public static func shown(_ note: AccountSwitchNote?, for sessionId: String) -> AccountSwitchNote? {
        guard let note, note.sessionId == sessionId, !note.text.isEmpty else { return nil }
        return note
    }

    /// `justSwitched`: the account name lit while the "Switched to …" note shows.
    public var lightsTheName: Bool { state == .done }
}
