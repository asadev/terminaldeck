import Foundation

// The accounts half of Settings → Coding AI, as pure logic.
//
// Every rule here is a port of the web screen's own (`renderer/accounts.ts`,
// `settings/sections/AccountsSection.tsx`, `account-agent.ts`), kept in the
// same words, so the native screen and the page cannot come to disagree about
// what a login is called, which run it sits in, or what Remove promises.

// MARK: - Model

/// Where an account's login lives (`main/account-vault/runtime.ts`'s `KeptBy`).
public enum CodingAIKeptBy: String, Equatable, Sendable {
    case app, adopting, unavailable, agent
}

/// One account — a login of one agent, in its own config directory.
public struct CodingAIAccount: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Which agent this is a login of; nil when the engine did not say.
    public var provider: String?
    public var configDir: String
    /// The machine's own install — the account every fallback ends on.
    public var system: Bool
    /// A custom-property name from the web theme (`--accent`, `--status-completed`…).
    public var color: String
    public var lastUsedAt: Double?
    /// Absent reads as the agent keeping it.
    public var keptBy: CodingAIKeptBy?
    /// Whether the app holds a login for it, when the app keeps it. Nil: cannot say / not sent.
    public var keptSignedIn: Bool?

    public init(id: String, name: String, provider: String? = nil, configDir: String = "", system: Bool = false,
                color: String = "--accent", lastUsedAt: Double? = nil, keptBy: CodingAIKeptBy? = nil,
                keptSignedIn: Bool? = nil) {
        self.id = id
        self.name = name
        self.provider = provider
        self.configDir = configDir
        self.system = system
        self.color = color
        self.lastUsedAt = lastUsedAt
        self.keptBy = keptBy
        self.keptSignedIn = keptSignedIn
    }
}

/// An agent whose own install is a directory inherited from the shell that launched the app.
public struct CodingAIInheritedInstall: Equatable, Sendable {
    public var provider: String?
    public var env: String
    public var dir: String
}

/// `profiles:list`, read.
public struct CodingAIAccountsSnapshot: Equatable, Sendable {
    public var accounts: [CodingAIAccount]
    /// Nil means "the user's own install" — the system account.
    public var defaultId: String?
    /// Canonical project path → account id.
    public var projectDefaults: [String: String]
    public var inherited: [CodingAIInheritedInstall]
    /// The computer these logins are on, or empty.
    public var machine: String

    public static let empty = CodingAIAccountsSnapshot(accounts: [], defaultId: nil, projectDefaults: [:], inherited: [], machine: "")

    public init(accounts: [CodingAIAccount], defaultId: String?, projectDefaults: [String: String] = [:],
                inherited: [CodingAIInheritedInstall] = [], machine: String = "") {
        self.accounts = accounts
        self.defaultId = defaultId
        self.projectDefaults = projectDefaults
        self.inherited = inherited
        self.machine = machine
    }
}

/// What an agent's own CLI said about one account (`profiles:signin`).
public struct CodingAISignIn: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case signedIn = "signed-in"
        case signedOut = "signed-out"
        case unknown
        case unsupported
    }

    public var state: State
    /// The address the CLI named, when it named one.
    public var account: String?
    public var plan: String?
    public var detail: String
    public var command: String

    public init(state: State, account: String? = nil, plan: String? = nil, detail: String = "", command: String = "") {
        self.state = state
        self.account = account
        self.plan = plan
        self.detail = detail
        self.command = command
    }

    /// What a row shows while its answer is still being read.
    public static let checking = CodingAISignIn(state: .unknown, detail: "Checking with the agent…")
    /// A build that cannot ask the question at all.
    public static let uncheckable = CodingAISignIn(state: .unknown, detail: "This build cannot check whether this account is signed in.")
}

/// Where one account's conversations live (`accounts:history-state`).
public struct CodingAIHistory: Equatable, Sendable {
    public enum Link: String, Equatable, Sendable { case shared, elsewhere, separate, absent, unmanaged }
    public var link: Link
    public var target: String?
    public var root: String
    public var ownProjects: Int
    public var share: String?
    public var unshare: String?
    /// Exactly what deleting this account's files would take with them.
    public var remove: String?
}

// MARK: - Reading the engine's answers

public enum CodingAIAccountsParse {
    private static func isColorToken(_ text: String) -> Bool {
        guard text.hasPrefix("--") else { return false }
        let body = text.dropFirst(2)
        guard (1...64).contains(body.count) else { return false }
        return body.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// `parseAccount`: an id and a name, or not a row at all.
    public static func account(_ value: CodingAIJSON) -> CodingAIAccount? {
        guard value.isObject, let id = value["id"].text, let name = value["name"].text else { return nil }
        let provider = value["provider"].string
        let color = value["color"].string.flatMap { isColorToken($0) ? $0 : nil } ?? "--accent"
        return CodingAIAccount(
            id: id,
            name: name,
            provider: CodingAICatalog.isProvider(provider) ? provider : nil,
            configDir: value["configDir"].string ?? "",
            system: value["system"].isTrue,
            color: color,
            lastUsedAt: value["lastUsedAt"].number)
    }

    /// `parseSnapshot`.
    public static func snapshot(_ value: CodingAIJSON) -> CodingAIAccountsSnapshot {
        var accounts = (value["profiles"].array ?? []).compactMap(account)

        var projectDefaults: [String: String] = [:]
        for (path, id) in value["projectDefaults"].object ?? [:] {
            if let id = id.string { projectDefaults[path] = id }
        }

        var inherited: [CodingAIInheritedInstall] = []
        for row in value["inherited"].array ?? [] {
            guard row.isObject, let dir = row["dir"].text else { continue }
            let provider = row["provider"].string
            inherited.append(CodingAIInheritedInstall(
                provider: CodingAICatalog.isProvider(provider) ? provider : nil,
                env: row["env"].string ?? "",
                dir: dir))
        }

        if let vault = value["vault"].object {
            for index in accounts.indices {
                guard let entry = vault[accounts[index].id], entry.isObject else { continue }
                if let kept = entry["keptBy"].string.flatMap(CodingAIKeptBy.init(rawValue:)) {
                    accounts[index].keptBy = kept
                }
                switch entry["signedIn"] {
                case .bool(let flag): accounts[index].keptSignedIn = flag
                default: break
                }
            }
        }

        return CodingAIAccountsSnapshot(
            accounts: accounts,
            defaultId: value["defaultProfileId"].string,
            projectDefaults: projectDefaults,
            inherited: inherited,
            machine: value["machine"].string ?? "")
    }

    /// `parseSignIn`: anything unrecognised is `unknown` with a reason — never `signed-out`.
    public static func signIn(_ value: CodingAIJSON) -> CodingAISignIn {
        let state = value["state"].string.flatMap(CodingAISignIn.State.init(rawValue:)) ?? .unknown
        return CodingAISignIn(
            state: state,
            account: value["account"].text,
            plan: value["plan"].text,
            detail: value["detail"].text ?? "This account’s sign-in state could not be read.",
            command: value["command"].string ?? "")
    }

    /// `parseAccountHistory`: nil for anything that is not an answer.
    /// An unrecognised link becomes `unmanaged`, never `shared`.
    public static func history(_ value: CodingAIJSON) -> CodingAIHistory? {
        let state = value["state"]
        guard state.isObject else { return nil }
        let link = state["link"].string.flatMap(CodingAIHistory.Link.init(rawValue:)) ?? .unmanaged
        let own = state["ownProjects"].number.map { max(0, Int($0.rounded(.towardZero))) } ?? 0
        func sentence(_ json: CodingAIJSON) -> String? {
            guard let text = json.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }
        return CodingAIHistory(
            link: link,
            target: state["target"].text,
            root: state["root"].string ?? "",
            ownProjects: own,
            share: sentence(value["share"]),
            unshare: sentence(value["unshare"]),
            remove: sentence(value["remove"]))
    }

    /// The id `profiles:create` answered with.
    public static func createdId(_ value: CodingAIJSON) -> String? {
        value["id"].text
    }

    /// `{ ok, message }` from a sign-out (here or on another machine).
    public static func outcome(_ value: CodingAIJSON) -> (ok: Bool, message: String) {
        (value["ok"].isTrue, value["message"].string ?? "")
    }
}

// MARK: - Names

public enum CodingAIAccountLabels {
    /// What a signed-in row says when the agent will not say who is signed in.
    public static let unnamedLogin = "This agent does not name its login"

    /// The address the CLI gave — only for a login that is signed in now
    /// (an expired Claude login still reports its email).
    public static func accountLabel(_ signIn: CodingAISignIn?) -> String? {
        guard let signIn, signIn.state == .signedIn else { return nil }
        return signIn.account
    }

    public static func isSystemAccountId(_ id: String) -> Bool {
        id == "system" || id.hasPrefix("system:")
    }

    /// The name was generated (an install), not chosen.
    public static func isGenerated(_ account: CodingAIAccount) -> Bool {
        account.system || isSystemAccountId(account.id)
    }

    /// `profileLoginLabel`: the address, else a chosen name, else which install.
    public static func profileLoginLabel(_ account: CodingAIAccount, _ signIn: CodingAISignIn?, namesTheAgent: Bool = true) -> String {
        if let address = accountLabel(signIn) { return address }
        if !isGenerated(account) { return account.name }
        let agent = (!namesTheAgent || account.provider == nil) ? nil : CodingAICatalog.agent(account.provider)?.label
        if let agent { return "Your own \(agent) install" }
        return "Your own install"
    }

    /// The login itself when anybody named it, else nil.
    public static func namedLogin(_ account: CodingAIAccount, _ signIn: CodingAISignIn?) -> String? {
        if let address = accountLabel(signIn) { return address }
        if !isGenerated(account) { return account.name }
        return nil
    }

    /// What an account row in Settings is headed with.
    public static func rowLabel(_ account: CodingAIAccount, _ signIn: CodingAISignIn?) -> String {
        if let named = namedLogin(account, signIn) { return named }
        if signIn?.state == .signedIn { return unnamedLogin }
        return profileLoginLabel(account, signIn)
    }

    /// The one line under a name: can this account start a session.
    public static func stateLine(_ signIn: CodingAISignIn?) -> String {
        guard let signIn else { return "Checking with the agent…" }
        switch signIn.state {
        case .signedIn:
            if signIn.account == nil, let plan = signIn.plan { return "Signed in using \(plan)" }
            return "Signed in"
        case .signedOut:
            return "Not signed in"
        case .unknown, .unsupported:
            return signIn.detail
        }
    }
}

// MARK: - The sentences behind a row's ⓘ, and Remove's promise

public enum CodingAIAccountText {
    public static func historyLine(_ history: CodingAIHistory) -> String {
        switch history.link {
        case .shared:
            return "Conversations are kept in \(history.root), shared with your own install."
        case .elsewhere:
            return "Its conversations folder is a link to \(history.target ?? "somewhere else"), which was set up outside this app and is left exactly as it is."
        case .separate:
            if history.ownProjects > 0 {
                let plural = history.ownProjects == 1 ? "" : "s"
                return "Keeps its own conversations — \(history.ownProjects) folder\(plural) of them, which no other account can read."
            }
            return "Keeps its own conversations, which no other account can read."
        case .absent, .unmanaged:
            return "Keeps its own conversations. Nothing has been written yet."
        }
    }

    public static func keptLine(_ account: CodingAIAccount) -> String? {
        switch account.keptBy {
        case .app: return "This app keeps its login, encrypted, so switching to it needs no sign-in."
        case .adopting: return "Its login moves into this app the next time it is used, so switching to it will need no sign-in."
        case .unavailable: return "This app keeps its login and cannot open its saved logins right now, so it cannot be used until it can."
        case .agent, nil: return nil
        }
    }

    /// Why the machine's own install is the directory it is, when it was inherited.
    public static func inheritedInstallNote(_ account: CodingAIAccount, _ inherited: [CodingAIInheritedInstall]) -> String? {
        guard account.system, let match = inherited.first(where: { $0.provider == account.provider }) else { return nil }
        let agent = account.provider.flatMap { CodingAICatalog.agent($0)?.label } ?? "This agent"
        return "\(agent)'s own install here is \(match.dir), not the default one. Deck was launched from a terminal with \(match.env) set to it, and sessions started on this account inherit the same variable — so this is the login they really run as. Launch Deck from a shell without \(match.env) to get the default install back."
    }

    /// Everything a row used to print under its name, for its ⓘ.
    public static func accountNote(_ account: CodingAIAccount, history: CodingAIHistory?, inherited: [CodingAIInheritedInstall] = []) -> String {
        var lines = ["Its own folder is \(account.configDir)."]
        if let history { lines.append(historyLine(history)) }
        if let kept = keptLine(account) { lines.append(kept) }
        if let adopted = inheritedInstallNote(account, inherited) { lines.append(adopted) }
        return lines.joined(separator: " ")
    }

    /// What Remove says it will do, before it does it.
    public static func removeConfirm(_ account: CodingAIAccount) -> String {
        if account.keptBy == .app {
            return "Remove “\(account.name)”? The login this app keeps for it is deleted, so adding it again means signing in again. Its folder stays on disk."
        }
        return "Remove “\(account.name)” from the list? Its folder stays on disk and its login stays in your keychain — adding it again at the same place signs straight back in."
    }

    /// The open sessions running as one account, or nil when there are none.
    public static func sessionsLine(_ titles: [String]?) -> String? {
        guard let titles, !titles.isEmpty else { return nil }
        var names: [String] = []
        for title in titles {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !names.contains(trimmed) { names.append(trimmed) }
        }
        func cut(_ title: String) -> String {
            guard title.count > 28 else { return title }
            let head = String(title.prefix(27))
            let trimmed = head.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            return "\(trimmed)…"
        }
        if titles.count == 1 { return "Running in \(cut(names.first ?? "a session"))" }
        let shown = names.prefix(2).map(cut).joined(separator: ", ")
        let others = names.count > 2 ? " and others" : ""
        return "Running in \(titles.count) sessions\(shown.isEmpty ? "" : " — \(shown)\(others)")"
    }

    /// The copy row's notice: which login it repeats, and what to do.
    public static func duplicateLine(original: String) -> String {
        "Same login as \(original) — remove this one, sign out in your browser, then add it again."
    }
}

// MARK: - Runs and groups

public struct CodingAIAccountGroup: Equatable, Sendable, Identifiable {
    public var provider: String?
    public var label: String
    public var accounts: [CodingAIAccount]
    public var id: String { label }
}

public struct CodingAIAccountRun: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        case signedIn = "signed-in"
        case notSignedIn = "not-signed-in"
        case notAnswered = "not-answered"
    }

    public var kind: Kind
    /// The words over the run; nil over the unanswered one, which gets none.
    public var title: String?
    public var groups: [CodingAIAccountGroup]
    public var id: String { kind.rawValue }

    public static func title(_ kind: Kind) -> String? {
        switch kind {
        case .signedIn: return "Signed in"
        case .notSignedIn: return "Not signed in or not installed"
        case .notAnswered: return nil
        }
    }
}

public enum CodingAIAccountRuns {
    /// One list per agent, catalogue order; unknown agents after, "Other agents" last.
    public static func groupByProvider(_ accounts: [CodingAIAccount]) -> [CodingAIAccountGroup] {
        var groups: [CodingAIAccountGroup] = []
        for account in accounts {
            if let at = groups.firstIndex(where: { $0.provider == account.provider }) {
                groups[at].accounts.append(account)
            } else {
                let label: String
                if let provider = account.provider {
                    label = CodingAICatalog.agent(provider)?.label ?? provider
                } else {
                    label = "Other agents"
                }
                groups.append(CodingAIAccountGroup(provider: account.provider, label: label, accounts: [account]))
            }
        }
        // Stable: equal ranks keep the order the accounts came in.
        return groups.enumerated()
            .sorted { lhs, rhs in
                let a = CodingAICatalog.rank(lhs.element.provider)
                let b = CodingAICatalog.rank(rhs.element.provider)
                return a != b ? a < b : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Which run one account belongs in, from what the agent said and nothing else.
    public static func runOf(_ signIn: CodingAISignIn?) -> CodingAIAccountRun.Kind {
        guard let signIn else { return .notAnswered }
        switch signIn.state {
        case .signedIn: return .signedIn
        case .unknown: return .notAnswered
        case .signedOut, .unsupported: return .notSignedIn
        }
    }

    /// Unanswered (no heading) first, then Signed in, then Not signed in.
    public static func runs(_ accounts: [CodingAIAccount], signIn: [String: CodingAISignIn]) -> [CodingAIAccountRun] {
        let order: [CodingAIAccountRun.Kind] = [.notAnswered, .signedIn, .notSignedIn]
        return order.compactMap { kind in
            let mine = accounts.filter { runOf(signIn[$0.id]) == kind }
            guard !mine.isEmpty else { return nil }
            return CodingAIAccountRun(kind: kind, title: CodingAIAccountRun.title(kind), groups: groupByProvider(mine))
        }
    }
}

// MARK: - One login, one account

public enum CodingAILogins {
    private static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Rows that are a second copy of another row's login, by id → the original.
    /// The machine's own install is always the original.
    public static func duplicates(_ accounts: [CodingAIAccount], signIn: [String: CodingAISignIn]) -> [String: CodingAIAccount] {
        let ordered = accounts.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.system != rhs.element.system { return lhs.element.system }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
        var first: [String: CodingAIAccount] = [:]
        var copies: [String: CodingAIAccount] = [:]
        for account in ordered {
            guard let live = CodingAIAccountLabels.accountLabel(signIn[account.id]) else { continue }
            let key = "\(account.provider ?? "")\u{0}\(fold(live))"
            if let original = first[key] {
                copies[account.id] = original
            } else {
                first[key] = account
            }
        }
        return copies
    }

    /// The account on this machine that already holds this login, or nil.
    public static func holding(_ accounts: [CodingAIAccount], signIn: [String: CodingAISignIn], provider: String, address: String) -> CodingAIAccount? {
        let wanted = fold(address)
        if wanted.isEmpty { return nil }
        for account in accounts where account.provider == provider {
            let facts = signIn[account.id]
            let live = CodingAIAccountLabels.accountLabel(facts)
            let chosenName = !CodingAIAccountLabels.isGenerated(account) && fold(account.name) == wanted
            if facts?.state == .signedIn, live == nil {
                if chosenName { return account }
                continue
            }
            if let live {
                if fold(live) == wanted { return account }
                continue
            }
            if chosenName { return account }
        }
        return nil
    }

    /// The account added for this address whose sign-in never finished, or nil.
    public static func awaiting(_ accounts: [CodingAIAccount], signIn: [String: CodingAISignIn], provider: String, address: String) -> CodingAIAccount? {
        guard let held = holding(accounts, signIn: signIn, provider: provider, address: address) else { return nil }
        return signIn[held.id]?.state != .signedIn && held.keptSignedIn != true ? held : nil
    }

    /// The longest name an account may have.
    public static let maxNameLength = 60

    /// What a typed name means, or nil for "do nothing" (empty, or unchanged).
    public static func normalizeName(_ typed: String, current: String) -> String? {
        let name = String(typed.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength))
        if name.isEmpty || name == current.trimmingCharacters(in: .whitespacesAndNewlines) { return nil }
        return name
    }

    /// The one default: the stored one, or the machine's own install when nothing is set.
    public static func isDefault(_ account: CodingAIAccount, defaultId: String?) -> Bool {
        account.id == defaultId || (defaultId == nil && account.id == "system")
    }

    /// What Sign in asks the main window to start: this account, on its own agent.
    public static func signInRequest(_ account: CodingAIAccount) -> (profileId: String, provider: String?) {
        (account.id, account.provider)
    }
}

// MARK: - One row, decided

/// Everything one account row shows and offers, decided in one place so a test
/// can ask for it without drawing anything.
public struct CodingAIAccountRowModel: Equatable, Sendable {
    public var label: String
    public var defaultBadge: Bool
    public var ownInstallBadge: Bool
    public var keptBadge: Bool
    public var stateLine: String
    /// The state the mark is drawn for (`unknown` while nothing has answered).
    public var state: CodingAISignIn.State
    public var note: String
    public var sessions: String?
    public var duplicate: String?
    public var problem: CodingAIAgentProblem?
    public var signOutNote: String?
    public var offersSignIn: Bool
    public var offersSignOut: Bool
    public var offersUseByDefault: Bool
    public var offersRenameRemove: Bool
    public var hasMenu: Bool { offersUseByDefault || offersRenameRemove }
    public var removeConfirm: String
    public var removeCost: String?

    public static func make(
        account: CodingAIAccount,
        snapshot: CodingAIAccountsSnapshot,
        signIn: [String: CodingAISignIn],
        history: [String: CodingAIHistory],
        providerRows: [CodingAIProviderRow],
        sessionTitles: [String]?,
        canStartSessions: Bool,
        canSignOut: Bool
    ) -> CodingAIAccountRowModel {
        let state = signIn[account.id]
        let isDefault = CodingAILogins.isDefault(account, defaultId: snapshot.defaultId)
        let known = history[account.id]
        let rowHistory = known.flatMap { $0.link == .unmanaged ? nil : $0 }
        let copies = CodingAILogins.duplicates(snapshot.accounts, signIn: signIn)
        let duplicate = copies[account.id].map {
            CodingAIAccountText.duplicateLine(original: CodingAIAccountLabels.rowLabel($0, signIn[$0.id]))
        }
        let provider = account.provider
        let signedIn = state?.state == .signedIn
        let hasSignOut = provider.map(CodingAICatalog.hasSignOut) ?? false
        let moreLogins = CodingAIProviders.canHaveMore(providerRows, provider)

        return CodingAIAccountRowModel(
            label: CodingAIAccountLabels.rowLabel(account, state),
            defaultBadge: isDefault && snapshot.accounts.count > 1,
            ownInstallBadge: account.system && CodingAIAccountLabels.accountLabel(state) != nil,
            keptBadge: account.keptBy == .app && account.keptSignedIn == true,
            stateLine: CodingAIAccountLabels.stateLine(state),
            state: state?.state ?? .unknown,
            note: CodingAIAccountText.accountNote(account, history: rowHistory, inherited: snapshot.inherited),
            sessions: CodingAIAccountText.sessionsLine(sessionTitles),
            duplicate: duplicate,
            problem: CodingAIProviders.agentProblem(providerRows, provider),
            signOutNote: (signedIn && provider != nil && !hasSignOut) ? CodingAICatalog.signOutNote(provider ?? "") : nil,
            offersSignIn: canStartSessions && state != nil && state?.state != .signedIn && state?.state != .unsupported
                && CodingAIProviders.agentCanStart(providerRows, provider),
            offersSignOut: canSignOut && signedIn && provider != nil && hasSignOut,
            offersUseByDefault: !isDefault && moreLogins,
            offersRenameRemove: !account.system,
            removeConfirm: CodingAIAccountText.removeConfirm(account),
            removeCost: rowHistory?.remove)
    }
}

/// The colour a row's dot is drawn in, from the token the engine stored.
public enum CodingAIDotColor: String, Equatable, Sendable {
    case accent, green, amber, orange, red

    public static func of(_ token: String) -> CodingAIDotColor {
        switch token {
        case "--status-completed": return .green
        case "--status-waiting", "--color-warning": return .amber
        case "--status-input": return .orange
        case "--color-critical": return .red
        default: return .accent
        }
    }
}
