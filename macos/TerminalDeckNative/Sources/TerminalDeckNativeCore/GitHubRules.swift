import Foundation

/// GitHub, the native screen's pure half — the Swift reading of
/// `components/GitHubPanel.tsx`, worded and decided exactly as the page does.
/// Channels: `github:auth-status`, `github:overview`, `github:refresh`,
/// `github:auth-connect`, `github:auth-await`, `github:auth-cancel`,
/// `github:auth-disconnect`, and `setup:status` for the Copilot row.

public struct GitHubFailure: Equatable, Sendable {
    public var kind: String
    public var message: String
    public var action: String?
    public var detail: String

    public init(kind: String, message: String, action: String? = nil, detail: String = "") {
        self.kind = kind
        self.message = message
        self.action = action
        self.detail = detail
    }

    /// A `{ ok: false, kind, message, action, detail }`, or nil for anything else.
    public init?(json: Any?) {
        guard let row = json as? [String: Any], row["ok"] as? Bool == false else { return nil }
        self.init(kind: row["kind"] as? String ?? "error", message: row["message"] as? String ?? "",
                  action: (row["action"] as? String).flatMap { $0.isEmpty ? nil : $0 }, detail: row["detail"] as? String ?? "")
    }
}

public struct GitHubRepoRef: Equatable, Sendable {
    public var nameWithOwner: String
    public var url: String
    public var remote: String

    public init(nameWithOwner: String, url: String = "", remote: String = "origin") {
        self.nameWithOwner = nameWithOwner
        self.url = url
        self.remote = remote
    }

    init?(json: Any?) {
        guard let row = json as? [String: Any], row["ok"] == nil, let name = row["nameWithOwner"] as? String else { return nil }
        self.init(nameWithOwner: name, url: row["url"] as? String ?? "", remote: row["remote"] as? String ?? "")
    }
}

/// The folder's repository: a GitHub repository, or why it is not one.
public enum GitHubFolderRepo: Equatable, Sendable {
    case repo(GitHubRepoRef)
    case failed(GitHubFailure)

    init?(json: Any?) {
        if let failure = GitHubFailure(json: json) { self = .failed(failure); return }
        guard let repo = GitHubRepoRef(json: json) else { return nil }
        self = .repo(repo)
    }

    public var ref: GitHubRepoRef? { if case .repo(let ref) = self { ref } else { nil } }
    public var failure: GitHubFailure? { if case .failed(let failure) = self { failure } else { nil } }
}

public struct GitHubBranchRef: Equatable, Sendable {
    public var name: String?
    public var detached: Bool
    public var head: String?

    public init(name: String?, detached: Bool = false, head: String? = nil) {
        self.name = name
        self.detached = detached
        self.head = head
    }
}

public struct GitHubRepoSummary: Equatable, Sendable, Identifiable {
    public var nameWithOwner: String
    public var name: String
    public var url: String
    public var isPrivate: Bool
    public var fork: Bool
    public var archived: Bool
    public var description: String?
    public var language: String?
    public var pushedAt: String?
    public var id: String { nameWithOwner }

    public init(nameWithOwner: String, name: String = "", url: String = "", isPrivate: Bool = false, fork: Bool = false,
                archived: Bool = false, description: String? = nil, language: String? = nil, pushedAt: String? = nil) {
        self.nameWithOwner = nameWithOwner
        self.name = name
        self.url = url
        self.isPrivate = isPrivate
        self.fork = fork
        self.archived = archived
        self.description = description
        self.language = language
        self.pushedAt = pushedAt
    }

    init?(json: Any?) {
        guard let row = json as? [String: Any], let name = row["nameWithOwner"] as? String else { return nil }
        func text(_ key: String) -> String? { (row[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        self.init(nameWithOwner: name, name: row["name"] as? String ?? "", url: row["url"] as? String ?? "",
                  isPrivate: row["private"] as? Bool ?? false, fork: row["fork"] as? Bool ?? false,
                  archived: row["archived"] as? Bool ?? false, description: text("description"), language: text("language"),
                  pushedAt: text("pushedAt"))
    }
}

public struct GitHubRepoAccessList: Equatable, Sendable {
    public var repos: [GitHubRepoSummary]
    public var atLeast: Int
    public var truncated: Bool
    /// `account` or `installation`.
    public var source: String
    /// `all`, `selected`, or nil.
    public var selection: String?

    public init(repos: [GitHubRepoSummary], atLeast: Int = 0, truncated: Bool = false, source: String = "account", selection: String? = nil) {
        self.repos = repos
        self.atLeast = atLeast
        self.truncated = truncated
        self.source = source
        self.selection = selection
    }
}

public enum GitHubRepoAccess: Equatable, Sendable {
    case list(GitHubRepoAccessList)
    case failed(GitHubFailure)

    init?(json: Any?) {
        if let failure = GitHubFailure(json: json) { self = .failed(failure); return }
        guard let row = json as? [String: Any], let repos = row["repos"] as? [Any] else { return nil }
        self = .list(GitHubRepoAccessList(repos: repos.compactMap(GitHubRepoSummary.init(json:)), atLeast: Int(DeviceJSON.number(row["atLeast"])),
                                          truncated: row["truncated"] as? Bool ?? false, source: row["source"] as? String ?? "account",
                                          selection: row["selection"] as? String))
    }
}

public struct GitHubLabel: Equatable, Sendable {
    public var name: String
    /// Six hex digits, as GitHub gives it.
    public var color: String
}

public struct GitHubPull: Equatable, Sendable, Identifiable {
    public var number: Int
    public var title: String
    public var url: String
    /// `draft`, `open`, `merged`, `closed`.
    public var badge: String
    public var author: String?
    public var authorIsBot: Bool
    public var updatedAt: String
    /// `approved`, `changes-requested`, `review-required`, or nil.
    public var review: String?
    public var labels: [GitHubLabel]
    public var fromFork: Bool
    public var additions: Int?
    public var deletions: Int?
    public var id: Int { number }
}

public struct GitHubIssue: Equatable, Sendable, Identifiable {
    public var number: Int
    public var title: String
    public var url: String
    /// `open` or `closed`.
    public var state: String
    public var author: String?
    public var authorIsBot: Bool
    public var updatedAt: String
    public var labels: [GitHubLabel]
    public var assignees: [String]
    public var id: Int { number }
}

public enum GitHubSection<T: Equatable & Sendable>: Equatable, Sendable {
    case rows([T])
    case failed(GitHubFailure)
}

public struct GitHubOverview: Equatable, Sendable {
    public var pulls: GitHubSection<GitHubPull>
    public var issues: GitHubSection<GitHubIssue>
    public var limit: Int
}

public enum GitHubResult: Equatable, Sendable {
    case overview(GitHubOverview)
    case failed(GitHubFailure)

    public init(json: Any?) {
        if let failure = GitHubFailure(json: json) { self = .failed(failure); return }
        guard let row = json as? [String: Any], row["ok"] as? Bool == true else {
            self = .failed(GitHubFailure(kind: "error", message: "No answer from the GitHub bridge."))
            return
        }
        func labels(_ value: Any?) -> [GitHubLabel] {
            (value as? [Any] ?? []).compactMap { entry in
                guard let label = entry as? [String: Any], let name = label["name"] as? String else { return nil }
                return GitHubLabel(name: name, color: label["color"] as? String ?? "888888")
            }
        }
        func count(_ value: Any?) -> Int? { value is NSNumber ? Int(DeviceJSON.number(value)) : nil }
        func section<T>(_ value: Any?, _ read: ([String: Any]) -> T?) -> GitHubSection<T> {
            if let failure = GitHubFailure(json: value) { return .failed(failure) }
            let rows = ((value as? [String: Any])?["value"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(read) }
            return .rows(rows)
        }
        let pulls: GitHubSection<GitHubPull> = section(row["pulls"]) { p in
            guard let number = p["number"] as? NSNumber else { return nil }
            return GitHubPull(number: number.intValue, title: p["title"] as? String ?? "", url: p["url"] as? String ?? "",
                              badge: p["badge"] as? String ?? "open", author: p["author"] as? String,
                              authorIsBot: p["authorIsBot"] as? Bool ?? false, updatedAt: p["updatedAt"] as? String ?? "",
                              review: p["review"] as? String, labels: labels(p["labels"]), fromFork: p["fromFork"] as? Bool ?? false,
                              additions: count(p["additions"]), deletions: count(p["deletions"]))
        }
        let issues: GitHubSection<GitHubIssue> = section(row["issues"]) { i in
            guard let number = i["number"] as? NSNumber else { return nil }
            return GitHubIssue(number: number.intValue, title: i["title"] as? String ?? "", url: i["url"] as? String ?? "",
                               state: i["state"] as? String == "closed" ? "closed" : "open", author: i["author"] as? String,
                               authorIsBot: i["authorIsBot"] as? Bool ?? false, updatedAt: i["updatedAt"] as? String ?? "",
                               labels: labels(i["labels"]), assignees: DeviceJSON.strings(i["assignees"]))
        }
        self = .overview(GitHubOverview(pulls: pulls, issues: issues, limit: Int(DeviceJSON.number(row["limit"]))))
    }
}

public struct GitHubDevicePrompt: Equatable, Sendable {
    public var userCode: String
    public var verificationUri: String
    /// Milliseconds since 1970.
    public var expiresAt: Double

    init?(json: Any?) {
        guard let row = json as? [String: Any], let code = row["userCode"] as? String,
              let uri = row["verificationUri"] as? String else { return nil }
        userCode = code
        verificationUri = uri
        expiresAt = DeviceJSON.number(row["expiresAt"])
    }

    public init(userCode: String, verificationUri: String, expiresAt: Double) {
        self.userCode = userCode
        self.verificationUri = verificationUri
        self.expiresAt = expiresAt
    }
}

public struct GitHubAuthState: Equatable, Sendable {
    public var connected = false
    /// `environment`, `device-flow`, `gh-cli`, or nil.
    public var source: String?
    public var host = "github.com"
    public var login: String?
    public var name: String?
    public var htmlUrl: String?
    public var scopes: [String] = []
    public var scopesReported = false
    public var ghInstalled = false
    /// `oauth`, `github-app`, or nil.
    public var credentialKind: String?
    public var appConfigured = false
    public var installUrl: String?
    public var disconnect: String?
    public var pending: GitHubDevicePrompt?
    public var failure: GitHubFailure?
    public var expiredCredentialRemoved = false
    public var repo: GitHubFolderRepo?
    public var branch: GitHubBranchRef?
    public var access: GitHubRepoAccess?

    public init() {}

    public init(json: Any?) {
        guard let row = json as? [String: Any] else { self = .bridgeSilent; return }
        func text(_ key: String) -> String? { (row[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        connected = row["connected"] as? Bool ?? false
        source = text("source")
        host = text("host") ?? "github.com"
        let identity = row["identity"] as? [String: Any]
        login = (identity?["login"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        name = (identity?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        htmlUrl = identity?["htmlUrl"] as? String
        scopes = DeviceJSON.strings(row["scopes"])
        scopesReported = row["scopesReported"] as? Bool ?? false
        ghInstalled = row["ghInstalled"] as? Bool ?? false
        credentialKind = text("credentialKind")
        appConfigured = row["appConfigured"] as? Bool ?? false
        installUrl = text("installUrl")
        disconnect = text("disconnect")
        pending = GitHubDevicePrompt(json: row["pending"])
        failure = GitHubFailure(json: row["failure"])
        expiredCredentialRemoved = row["expiredCredentialRemoved"] as? Bool ?? false
        repo = GitHubFolderRepo(json: row["repo"])
        if let b = row["branch"] as? [String: Any] {
            branch = GitHubBranchRef(name: b["name"] as? String, detached: b["detached"] as? Bool ?? false, head: b["head"] as? String)
        }
        access = GitHubRepoAccess(json: row["access"])
    }

    /// What the page shows when the bridge did not answer: not connected, and why.
    public static var bridgeSilent: GitHubAuthState {
        var state = GitHubAuthState()
        state.failure = GitHubFailure(kind: "error", message: "The GitHub bridge did not answer, so your sign-in could not be checked.")
        return state
    }
}

public enum GitHubTab: String, Sendable, Equatable, CaseIterable { case pulls, issues, repos }

public enum GitHubRules {
    /// `now`, `5m`, `3h`, `2d`, `1w`, `1y` — the age of an ISO date.
    public static func formatAge(_ iso: String, now: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let then = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return "" }
        let elapsed = max(0, now.timeIntervalSince(then))
        let minute = 60.0, hour = 3600.0, day = 86_400.0, week = 7 * day, year = 365 * day
        if elapsed < minute { return "now" }
        if elapsed < hour { return "\(Int(elapsed / minute))m" }
        if elapsed < day { return "\(Int(elapsed / hour))h" }
        if elapsed < week { return "\(Int(elapsed / day))d" }
        if elapsed < year { return "\(Int(elapsed / week))w" }
        return "\(Int(elapsed / year))y"
    }

    public static func reviewLabel(_ status: String?) -> String? {
        switch status {
        case "approved": "Approved"
        case "changes-requested": "Changes requested"
        case "review-required": "Review required"
        default: nil
        }
    }

    public static func failureTitle(_ kind: String) -> String {
        switch kind {
        case "gh-missing": "GitHub CLI not installed"
        case "not-authenticated": "Not signed in to GitHub"
        case "auth-expired": "GitHub sign-in expired"
        case "missing-scope": "Token is missing a permission"
        case "auth-declined": "Sign-in refused"
        case "auth-code-expired": "The sign-in code expired"
        case "auth-unavailable": "GitHub would not start a sign-in"
        case "not-a-repo": "Not a git repository"
        case "no-such-folder": "Folder is gone"
        case "no-remote": "No git remote"
        case "no-github-remote": "No GitHub remote"
        case "git-missing": "git not installed"
        case "repo-not-found": "Repository not found"
        case "no-access": "No access to this repository"
        case "issues-disabled": "Issues are off"
        case "rate-limited": "GitHub rate limit reached"
        case "network-down": "Cannot reach GitHub"
        case "timeout": "GitHub timed out"
        default: "GitHub request failed"
        }
    }

    public static func isRetryable(_ kind: String) -> Bool { ["network-down", "timeout", "rate-limited", "error"].contains(kind) }

    /// Whether a failure's command is worth saying, because its sentence does not already.
    public static func showsAction(_ failure: GitHubFailure) -> Bool {
        guard let action = failure.action else { return false }
        return !failure.message.contains(action)
    }

    /// The sentence behind the failure's "i".
    public static func explanation(_ failure: GitHubFailure) -> String {
        showsAction(failure) ? "\(failure.message) Run \(failure.action ?? "") in a terminal, then refresh." : failure.message
    }

    /// Retry is offered for a passing trouble, or one with a command to run first.
    public static func offersRetry(_ failure: GitHubFailure) -> Bool { isRetryable(failure.kind) || failure.action != nil }

    public static func sourceWord(_ source: String?) -> String {
        switch source {
        case "device-flow": "signed in here"
        case "gh-cli": "GitHub CLI"
        case "environment": "GH_TOKEN"
        default: "not signed in"
        }
    }

    public static func sourceSentence(_ source: String?, host: String) -> String {
        switch source {
        case "device-flow": "Signed in here, in this app, on \(host)."
        case "gh-cli": "Reusing the GitHub CLI’s own sign-in on \(host) — you were already signed in there."
        case "environment": "Using the GH_TOKEN set in the environment this app was launched with, on \(host)."
        default: "Not signed in to \(host)."
        }
    }

    /// `owner/name · main`, `… · detached at a1b2c3d`, or the reason the folder is not a GitHub repository.
    public static func folderLine(_ repo: GitHubFolderRepo?, branch: GitHubBranchRef?) -> String? {
        guard let repo else { return nil }
        guard case .repo(let ref) = repo else { return repo.failure?.message }
        guard let branch else { return ref.nameWithOwner }
        if branch.detached {
            return branch.head.map { "\(ref.nameWithOwner) · detached at \($0)" } ?? "\(ref.nameWithOwner) · detached HEAD"
        }
        return branch.name.map { "\(ref.nameWithOwner) · \($0)" } ?? ref.nameWithOwner
    }

    /// The failure that belongs to the page rather than one list: the folder's first.
    public static func pageFailure(_ repo: GitHubFolderRepo?, overview: GitHubFailure?) -> GitHubFailure? {
        repo?.failure ?? overview
    }

    /// `20+` when the list hit its limit.
    public static func countLabel(_ rows: Int?, limit: Int) -> String? {
        guard let rows else { return nil }
        return rows >= limit ? "\(rows)+" : String(rows)
    }

    public static func filterRepos(_ repos: [GitHubRepoSummary], query: String) -> [GitHubRepoSummary] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return repos }
        return repos.filter { $0.nameWithOwner.lowercased().contains(needle) || ($0.description ?? "").lowercased().contains(needle) }
    }

    public static func accessSummary(_ access: GitHubRepoAccessList) -> String {
        let shown = access.repos.count
        if !access.truncated { return shown == 1 ? "1 repository" : "\(shown) repositories" }
        return "\(access.atLeast)+ repositories · showing the \(shown) most recently pushed"
    }

    public static func selectionSentence(_ access: GitHubRepoAccessList) -> String? {
        guard access.source == "installation" else { return nil }
        return access.selection == "all"
            ? "This GitHub App is installed on all your repositories."
            : "These are the repositories you selected when installing the app. Change them on GitHub at any time."
    }

    public static func repoCount(_ access: GitHubRepoAccess?) -> String? {
        guard case .list(let list)? = access else { return nil }
        return list.truncated ? "\(list.atLeast)+" : String(list.repos.count)
    }

    public static func minutesLeft(expiresAt: Double, now: Date) -> Int {
        max(0, Int(((expiresAt - now.timeIntervalSince1970 * 1000) / 60_000).rounded(.down)))
    }

    public static func expiryLine(minutes: Int) -> String {
        minutes > 0
            ? "The code works for about \(minutes) more \(minutes == 1 ? "minute" : "minutes")."
            : "This code has expired — press Connect again for a new one."
    }

    /// `A B C D - 1 2 3 4`, so a screen reader reads the code one character at a time.
    public static func spelled(_ code: String) -> String { code.map(String.init).joined(separator: " ") }

    /// The Copilot row's words for a tool's state (`TOOL_STATE_LABEL`).
    public static func toolStateLabel(_ state: String) -> String {
        switch state {
        case "ready": "Installed"
        case "installed-not-authed": "Sign in needed"
        case "missing": "Not found"
        default: "Unknown"
        }
    }

    /// The GitHub Copilot tool out of `setup:status`: its label, state and install link.
    public static func copilotTool(_ json: Any?) -> (label: String, state: String, url: String?)? {
        guard let tools = (json as? [String: Any])?["tools"] as? [Any] else { return nil }
        for case let tool as [String: Any] in tools where tool["id"] as? String == "copilot" {
            let state = tool["state"] as? String ?? "unknown"
            let known = ["ready", "installed-not-authed", "missing", "unknown"].contains(state) ? state : "unknown"
            return (tool["label"] as? String ?? "copilot", known, (tool["url"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
        return nil
    }

    public static func folderName(_ path: String) -> String {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
    }

    /// The colour a label's hex names, as RGB 0…1, or nil when it is not six hex digits.
    public static func labelRGB(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }
}
