import Foundation

// The Overview's data and words: src/renderer/dashboard/board.ts + useBoard.ts
// (the running-sessions board) and widgets.tsx (Usage, Git, AI Readiness, GitHub,
// Sessions), with the helpers they lean on (session-transcript.ts, session-title.ts,
// workspace-tabs.ts, accounts.ts) — ported one for one.

private func obj(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
private func arr(_ value: Any?) -> [Any] { value as? [Any] ?? [] }
private func numberAt(_ value: Any?, _ path: String...) -> Double {
    var cursor: Any? = value
    for key in path {
        guard let dict = cursor as? [String: Any] else { return 0 }
        cursor = dict[key]
    }
    guard let n = cursor as? NSNumber, !(cursor is Bool), n.doubleValue.isFinite else { return 0 }
    return n.doubleValue
}

// MARK: - Words shared by the widgets

public enum DashboardWords {
    public static func formatTokens(_ tokens: Double) -> String {
        let a = abs(tokens)
        func trimmed(_ value: Double, _ digits: Int) -> String {
            var text = String(format: "%.\(digits)f", value)
            if text.contains(".") {
                while text.hasSuffix("0") { text.removeLast() }
                if text.hasSuffix(".") { text.removeLast() }
            }
            return text
        }
        if a >= 999_999_500 { return "\(trimmed(tokens / 1_000_000_000, 2))B" }
        if a >= 999_950 { return "\(trimmed(tokens / 1_000_000, 2))M" }
        if a >= 1000 { return "\(trimmed(tokens / 1000, 1))k" }
        return String(Int(tokens.rounded()))
    }

    public static func plural(_ count: Int, _ singular: String, _ many: String? = nil) -> String {
        count == 1 ? singular : (many ?? "\(singular)s")
    }

    public static func formatPercent(_ fraction: Double) -> String {
        let percent = fraction * 100
        if percent > 0 && percent < 1 { return "<1%" }
        return "\(Int(percent.rounded()))%"
    }

    /// The tone of a context or score figure: `crit`, `warn` or none.
    public enum Tone: String, Sendable { case warn, crit }

    public static func contextTone(_ percent: Double?) -> Tone? {
        guard let percent else { return nil }
        return percent >= 90 ? .crit : percent >= 70 ? .warn : nil
    }
}

// MARK: - Usage (cost:project)

public struct TokenParts: Equatable, Sendable {
    public var input: Double, output: Double, cacheWrite: Double, cacheRead: Double
    public init(input: Double, output: Double, cacheWrite: Double, cacheRead: Double) {
        self.input = input; self.output = output; self.cacheWrite = cacheWrite; self.cacheRead = cacheRead
    }
    public var prompt: Double { input + cacheWrite + cacheRead }
    public var total: Double { prompt + output }
    public var cacheHitRate: Double { prompt == 0 ? 0 : cacheRead / prompt }
}

public struct UsageLine: Equatable, Sendable {
    public var label: String
    public var tokens: Double
    public var share: Double
}

public struct UsageContext: Equatable, Sendable {
    public var id: String
    public var model: String
    public var percent: Double
    public var tokens: Double
    public var window: Double
}

public struct UsageView: Equatable, Sendable {
    public var tokens: TokenParts
    public var requests: Int
    public var sessions: Int
    public var context: UsageContext?
    public var models: [String]
    public var scanning: Bool
    public var truncated: Bool
}

public enum UsageRules {
    public static func lines(_ tokens: TokenParts) -> [UsageLine] {
        let total = tokens.total
        func line(_ label: String, _ count: Double) -> UsageLine { UsageLine(label: label, tokens: count, share: total > 0 ? count / total : 0) }
        return [line("Fresh input", tokens.input), line("Cache writes", tokens.cacheWrite),
                line("Cache reads", tokens.cacheRead), line("Output", tokens.output)]
    }

    public static func view(_ raw: Any?) -> UsageView {
        let record = obj(raw)
        let sessions = arr(record["sessions"])
        let usage = record["usage"]
        let tokens = TokenParts(input: numberAt(usage, "input"), output: numberAt(usage, "output"),
                                cacheWrite: numberAt(usage, "cacheWrite5m") + numberAt(usage, "cacheWrite1h"),
                                cacheRead: numberAt(usage, "cacheRead"))
        let activeId = record["activeSessionId"] as? String
        let active = sessions.compactMap { $0 as? [String: Any] }.first { ($0["sessionId"] as? String) == activeId && activeId != nil }
        var context: UsageContext?
        if let active, let contextRecord = active["context"] as? [String: Any], let activeId {
            let models = arr(active["models"])
            context = UsageContext(id: activeId, model: models.first as? String ?? "",
                                   percent: numberAt(contextRecord, "percent"), tokens: numberAt(contextRecord, "tokens"),
                                   window: numberAt(contextRecord, "window"))
        }
        let byModel = obj(record["usageByModel"])
        func modelTokens(_ model: String) -> Double {
            numberAt(byModel[model], "input") + numberAt(byModel[model], "output") + numberAt(byModel[model], "cacheWrite5m")
                + numberAt(byModel[model], "cacheWrite1h") + numberAt(byModel[model], "cacheRead")
        }
        // A stable sort, so equal models keep the order the engine gave (as JS's sort does).
        let models = byModel.keys.sorted().enumerated()
            .sorted { modelTokens($0.element) != modelTokens($1.element) ? modelTokens($0.element) > modelTokens($1.element) : $0.offset < $1.offset }
            .map(\.element)
        return UsageView(tokens: tokens, requests: Int(numberAt(raw, "requests")), sessions: sessions.count, context: context,
                         models: models, scanning: (record["scanning"] as? Bool) == true, truncated: (record["truncated"] as? Bool) == true)
    }

    public static func emptyTitle(_ view: UsageView) -> String { view.scanning ? "Still scanning…" : "Nothing recorded yet" }

    public static func emptyDetail(_ view: UsageView) -> String {
        view.truncated
            ? "Nothing was recorded in this folder’s most recent sessions. Older work was not read."
            : "Usage appears once an agent session in this folder has recorded its first request."
    }

    public static func note(_ view: UsageView) -> String {
        let total = DashboardWords.formatTokens(view.tokens.total)
        let tail = view.truncated
            ? "counted once from this folder’s most recent sessions, from their own session records. Older work not read."
            : "every request your agents made in this folder, counted once, from their own session records."
        return "\(total) tokens across \(view.requests) \(DashboardWords.plural(view.requests, "request")) — \(tail)"
    }

    public static func contextNote(_ context: UsageContext) -> String {
        let model = context.model.isEmpty ? "" : ", on \(context.model)"
        let window = context.window > 0
            ? "\(context.model.isEmpty ? "a " : "its ")\(DashboardWords.formatTokens(context.window)) window"
            : "an unknown window"
        return "Most recent session here\(model) — \(DashboardWords.formatTokens(context.tokens)) of \(window)."
    }

    public static func quietNote(_ view: UsageView) -> String {
        var text = ""
        let rate = view.tokens.cacheHitRate
        if rate > 0 { text += "\(DashboardWords.formatPercent(rate)) of the prompt came from cache, re-read each turn rather than sent again. " }
        if !view.models.isEmpty { text += "Models seen: \(view.models.joined(separator: ", "))." }
        return text
    }
}

// MARK: - Git (git:status)

public struct GitFileRow: Equatable, Sendable {
    public var path: String
    public var group: String
    public var kind: String
    public var code: String
}

public struct GitWidgetStatus: Equatable, Sendable {
    public var repo: Bool
    public var reason: String?
    public var message: String?
    public var branchName: String?
    public var detached: Bool
    public var oid: String?
    public var ahead: Int
    public var behind: Int
    public var staged: [GitFileRow]
    public var unstaged: [GitFileRow]
    public var untracked: [GitFileRow]
    public var conflicted: [GitFileRow]
    public var clean: Bool
}

public enum GitWidgetRules {
    public static let maxFileRows = 40

    public static func status(_ raw: Any?) -> GitWidgetStatus {
        let v = obj(raw)
        let branch = obj(v["branch"])
        func files(_ key: String) -> [GitFileRow] {
            arr(v[key]).compactMap { $0 as? [String: Any] }.map {
                GitFileRow(path: $0["path"] as? String ?? "", group: $0["group"] as? String ?? key,
                           kind: $0["kind"] as? String ?? "unknown", code: $0["code"] as? String ?? "")
            }
        }
        return GitWidgetStatus(
            repo: (v["repo"] as? Bool) == true, reason: v["reason"] as? String, message: v["message"] as? String,
            branchName: branch["name"] as? String, detached: (branch["detached"] as? Bool) == true, oid: branch["oid"] as? String,
            ahead: Int(numberAt(branch, "ahead")), behind: Int(numberAt(branch, "behind")),
            staged: files("staged"), unstaged: files("unstaged"), untracked: files("untracked"), conflicted: files("conflicted"),
            clean: (v["clean"] as? Bool) == true)
    }

    public static func notRepoTitle(_ reason: String?) -> String {
        switch reason {
        case "not-a-repo": return "Nothing to track here"
        case "git-missing": return "git is not installed"
        case "no-such-folder": return "That folder is gone"
        default: return "Source control is unavailable"
        }
    }

    public static func branchName(_ status: GitWidgetStatus) -> String {
        if status.detached { return "detached at \(status.oid.map { String($0.prefix(7)) } ?? "—")" }
        return status.branchName ?? "no branch yet"
    }

    public static func changeLabel(kind: String, code: String) -> String {
        let words = ["added": "Added", "modified": "Modified", "deleted": "Deleted", "renamed": "Renamed", "copied": "Copied",
                     "typechange": "Type", "untracked": "Untracked", "conflicted": "Conflict", "unknown": ""]
        if let word = words[kind], !word.isEmpty { return word }
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "?" : trimmed
    }

    public static func visibleFiles(_ status: GitWidgetStatus, limit: Int = maxFileRows) -> (shown: [GitFileRow], hidden: Int) {
        let files = status.conflicted + status.staged + status.unstaged + status.untracked
        let shown = Array(files.prefix(max(0, limit)))
        return (shown, files.count - shown.count)
    }
}

// MARK: - AI Readiness (readiness:scan)

public struct ReadinessCheckRow: Equatable, Sendable {
    public var id: String
    public var title: String
    public var status: String
    public var gate: Bool
}

public struct ReadinessWidgetView: Equatable, Sendable {
    public var score: Int
    public var band: String
    public var cappedBy: String?
    public var checks: [ReadinessCheckRow]
}

public enum ReadinessWidgetRules {
    public static func view(_ raw: Any?) -> ReadinessWidgetView {
        let v = obj(raw)
        let checks = arr(v["checks"]).compactMap { $0 as? [String: Any] }.enumerated().map { i, check in
            let status = check["status"] as? String ?? ""
            return ReadinessCheckRow(id: check["id"] as? String ?? String(i), title: check["title"] as? String ?? "Check",
                                     status: ["pass", "warn", "fail", "skip"].contains(status) ? status : "skip",
                                     gate: (check["gate"] as? Bool) == true)
        }
        return ReadinessWidgetView(score: Int(numberAt(raw, "score").rounded()), band: v["band"] as? String ?? "",
                                   cappedBy: v["cappedBy"] as? String, checks: checks)
    }

    public static func tone(_ score: Int) -> DashboardWords.Tone? { score >= 80 ? nil : score >= 50 ? .warn : .crit }

    /// Failures first, then warnings, passes, and skipped — stable within each.
    public static func sorted(_ checks: [ReadinessCheckRow]) -> [ReadinessCheckRow] {
        let order = ["fail": 0, "warn": 1, "pass": 2, "skip": 3]
        return checks.enumerated().sorted { (order[$0.element.status] ?? 3, $0.offset) < (order[$1.element.status] ?? 3, $1.offset) }.map(\.element)
    }

    public static func passing(_ checks: [ReadinessCheckRow]) -> String {
        let applicable = checks.filter { $0.status != "skip" }
        return "\(applicable.filter { $0.status == "pass" }.count)/\(applicable.count)"
    }
}

// MARK: - GitHub (github:overview)

public struct GithubItemRow: Equatable, Sendable {
    public var key: String
    public var number: Int
    public var title: String
    public var pr: Bool
}

public struct GithubWidgetView: Equatable, Sendable {
    public var repo: String?
    public var failure: String?
    public var partial: [String]
    public var items: [GithubItemRow]
}

public enum GithubWidgetRules {
    public static let maxRows = 30

    public static func section(_ source: [String: Any], _ key: String, pr: Bool) -> (items: [GithubItemRow], error: String?) {
        guard let section = source[key] as? [String: Any] else { return ([], nil) }
        if (section["ok"] as? Bool) != true { return ([], section["message"] as? String ?? "\(key) unavailable") }
        let items = arr(section["value"]).compactMap { $0 as? [String: Any] }.enumerated().map { i, item in
            let number = Int(numberAt(item, "number"))
            return GithubItemRow(key: "\(pr ? "pr" : "issue")-\(i)-\(number)", number: number,
                                 title: item["title"] as? String ?? "Untitled", pr: pr)
        }
        return (items, nil)
    }

    public static func view(_ raw: Any?) -> GithubWidgetView {
        guard let record = raw as? [String: Any] else { return GithubWidgetView(repo: nil, failure: "No answer from gh.", partial: [], items: []) }
        if (record["ok"] as? Bool) != true {
            return GithubWidgetView(repo: nil, failure: record["message"] as? String ?? "GitHub is unavailable.", partial: [], items: [])
        }
        let pulls = section(record, "pulls", pr: true)
        let issues = section(record, "issues", pr: false)
        return GithubWidgetView(repo: obj(record["repo"])["nameWithOwner"] as? String, failure: nil,
                                partial: [pulls.error, issues.error].compactMap { $0 }, items: pulls.items + issues.items)
    }
}

// MARK: - The running-sessions board (board.ts, useBoard.ts)

public enum Attention: String, Equatable, Sendable, CaseIterable {
    case blocked, finished, working, ready, exited
}

public struct SessionWork: Equatable, Sendable {
    public var transcriptPath: String
    public var requests: Int
    public var tokens: Double
    public var contextPercent: Double?
    public var lastActivityAt: Double
}

public struct BoardAccount: Equatable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct BoardSession: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var projectPath: String
    public var provider: String
    public var account: BoardAccount?
    public var status: String
    /// ms; 0 when the status was not seen changing.
    public var statusSince: Double
    public var startedAt: Double
    public var resumed: Bool
    public var work: SessionWork?
    public init(id: String, title: String, projectPath: String, provider: String = "shell", account: BoardAccount? = nil,
                status: String = "idle", statusSince: Double = 0, startedAt: Double = 0, resumed: Bool = false, work: SessionWork? = nil) {
        self.id = id; self.title = title; self.projectPath = projectPath; self.provider = provider; self.account = account
        self.status = status; self.statusSince = statusSince; self.startedAt = startedAt; self.resumed = resumed; self.work = work
    }
}

public struct BoardCounts: Equatable, Sendable {
    public var blocked = 0, finished = 0, working = 0, ready = 0, exited = 0, total = 0, wantsYou = 0
}

public struct TranscriptFile: Equatable, Sendable {
    public var path: String
    public var sessionId: String
    public var createdAt: Double
    public var modifiedAt: Double
    public init(path: String, sessionId: String, createdAt: Double, modifiedAt: Double) {
        self.path = path; self.sessionId = sessionId; self.createdAt = createdAt; self.modifiedAt = modifiedAt
    }
}

public struct TranscriptChoice: Equatable, Sendable {
    public enum Attribution: String, Sendable { case declared, session, resumed, project }
    public var path: String
    public var sessionId: String
    public var attribution: Attribution
}

public enum BoardRules {
    public static let awaitTranscript: Duration = .seconds(4)

    public static func attention(_ status: String) -> Attention {
        switch status {
        case "input": return .blocked
        case "completed": return .finished
        case "working": return .working
        case "exited": return .exited
        default: return .ready
        }
    }

    public static func wantsYou(_ attention: Attention) -> Bool { attention == .blocked || attention == .finished }

    private static func rank(_ attention: Attention) -> Int { Attention.allCases.firstIndex(of: attention) ?? 4 }

    public static func sort(_ sessions: [BoardSession]) -> [BoardSession] {
        sessions.sorted { a, b in
            let r = rank(attention(a.status)) - rank(attention(b.status))
            if r != 0 { return r < 0 }
            let oldestFirst = wantsYou(attention(a.status))
            let at = a.statusSince != 0 ? a.statusSince : a.startedAt
            let bt = b.statusSince != 0 ? b.statusSince : b.startedAt
            if at != bt { return oldestFirst ? at < bt : at > bt }
            return a.id < b.id
        }
    }

    public static func count(_ sessions: [BoardSession]) -> BoardCounts {
        var c = BoardCounts()
        c.total = sessions.count
        for session in sessions {
            let a = attention(session.status)
            switch a {
            case .blocked: c.blocked += 1
            case .finished: c.finished += 1
            case .working: c.working += 1
            case .ready: c.ready += 1
            case .exited: c.exited += 1
            }
            if wantsYou(a) { c.wantsYou += 1 }
        }
        return c
    }

    public static func formatElapsed(_ ms: Double) -> String {
        guard ms.isFinite, ms >= 0 else { return "" }
        let minute = 60_000.0, hour = 60 * minute, day = 24 * hour
        if ms < minute { return "\(max(1, Int((ms / 1000).rounded())))s" }
        if ms < hour { return "\(Int(ms / minute))m" }
        if ms < day {
            let hours = Int(ms / hour), minutes = Int(ms.truncatingRemainder(dividingBy: hour) / minute)
            return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
        }
        let days = Int(ms / day), hours = Int(ms.truncatingRemainder(dividingBy: day) / hour)
        return hours == 0 ? "\(days)d" : "\(days)d \(hours)h"
    }

    public static func statusObserved(_ session: BoardSession) -> Bool { session.statusSince > 0 && session.status != "idle" }

    public static func stateSentence(_ session: BoardSession, now: Double) -> String {
        let elapsed = statusObserved(session) ? formatElapsed(now - session.statusSince) : ""
        let since = elapsed.isEmpty ? "" : " for \(elapsed)"
        switch attention(session.status) {
        case .blocked: return "Waiting on you\(since)"
        case .finished: return "Finished its turn\(since)"
        case .working: return "Working\(since)"
        case .exited: return elapsed.isEmpty ? "Exited" : "Exited \(elapsed) ago"
        case .ready: return "At a prompt"
        }
    }

    public static func label(_ attention: Attention) -> String {
        switch attention {
        case .blocked: return "Needs you"
        case .finished: return "Finished"
        case .working: return "Working"
        case .exited: return "Exited"
        case .ready: return "Ready"
        }
    }

    public static func summaryParts(_ c: BoardCounts) -> [(attention: Attention, text: String)] {
        var parts: [(Attention, String)] = []
        if c.blocked > 0 { parts.append((.blocked, "\(c.blocked) need\(c.blocked == 1 ? "s" : "") you")) }
        if c.finished > 0 { parts.append((.finished, "\(c.finished) finished")) }
        if c.working > 0 { parts.append((.working, "\(c.working) working")) }
        if c.ready > 0 { parts.append((.ready, "\(c.ready) at a prompt")) }
        if c.exited > 0 { parts.append((.exited, "\(c.exited) exited")) }
        return parts
    }

    public static func folderOf(_ path: String) -> String {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
    }

    public static func providerLabel(_ provider: String) -> String {
        ["claude": "Claude Code", "codex": "Codex", "gemini": "Gemini", "shell": "Shell"][provider] ?? provider
    }

    /// `isMachineAndPath` (session-title.ts): a title that is only "user@host:path" or a path.
    public static func isMachineAndPath(_ title: String) -> Bool {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return false }
        let patterns = [#"^[^\s@:]+@[^\s@:]+(?::.*)?$"#, #"^[\w.-]+:\s*(?:[~/]|[A-Za-z]:\\).*$"#, #"^~?/[^\s]*$"#, #"^[A-Za-z]:\\"#]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// `sessionLabel` (workspace-tabs.ts).
    public static func sessionLabel(_ title: String, index: Int, folderName: String?) -> String {
        !title.isEmpty && title != folderName && !isMachineAndPath(title) ? title : "Session \(index + 1)"
    }

    public static func shortSessionId(_ id: String) -> String { id.split(separator: "-", omittingEmptySubsequences: false).first.map(String.init) ?? id }

    /// Card names, numbered per folder, and which cards share a name (they show their short id).
    public static func names(_ sessions: [BoardSession]) -> (names: [String: String], twins: Set<String>) {
        var names: [String: String] = [:]
        var seen: [String: Int] = [:]
        for session in sessions {
            let nth = seen[session.projectPath] ?? 0
            seen[session.projectPath] = nth + 1
            names[session.id] = sessionLabel(session.title, index: nth, folderName: folderOf(session.projectPath))
        }
        var counts: [String: Int] = [:]
        func key(_ s: BoardSession) -> String { [names[s.id] ?? "", s.projectPath, s.account?.id ?? ""].joined(separator: "\u{0}") }
        for session in sessions { counts[key(session), default: 0] += 1 }
        return (names, Set(sessions.filter { (counts[key($0)] ?? 0) > 1 }.map(\.id)))
    }

    /// `profileLoginLabel` without a known sign-in: the account's own name, or "Your own … install".
    public static func loginLabel(_ account: BoardAccount?, provider: String) -> String? {
        guard let account else { return nil }
        let generated = account.id == "system" || account.id.hasPrefix("system:")
        if !generated { return account.name }
        let agent = ["claude": "Claude Code", "codex": "Codex CLI", "gemini": "Gemini CLI"][provider]
        return agent.map { "Your own \($0) install" } ?? "Your own install"
    }

    public static func meta(_ session: BoardSession, now: Double) -> String {
        var text = providerLabel(session.provider)
        if let login = loginLabel(session.account, provider: session.provider) { text += " · \(login)" }
        if session.startedAt > 0 { text += " · started \(formatElapsed(now - session.startedAt)) ago" }
        return text
    }

    // MARK: Gathering (asSessionMeta, transcripts, work)

    public static func sessionMeta(_ value: Any?) -> BoardSession? {
        guard let v = value as? [String: Any], let id = v["id"] as? String, !id.isEmpty,
              let cwd = v["cwd"] as? String, !cwd.isEmpty else { return nil }
        let title = (v["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? folderOf(cwd)
        var account: BoardAccount?
        if let pid = v["profileId"] as? String, !pid.isEmpty, let pname = v["profileName"] as? String, !pname.isEmpty {
            account = BoardAccount(id: pid, name: pname)
        }
        let exited = v["exitCode"] is NSNumber && !(v["exitCode"] is Bool)
        return BoardSession(id: id, title: title, projectPath: cwd, provider: v["provider"] as? String ?? "shell", account: account,
                            status: exited ? "exited" : "idle", statusSince: 0, startedAt: numberAt(v, "createdAt"),
                            resumed: (v["resumed"] as? Bool) == true)
    }

    public static func transcriptFiles(_ raw: Any?) -> [TranscriptFile] {
        arr(raw).compactMap { item in
            guard let v = item as? [String: Any], let path = v["path"] as? String, let sid = v["sessionId"] as? String,
                  let created = v["createdAt"] as? NSNumber, let modified = v["modifiedAt"] as? NSNumber else { return nil }
            return TranscriptFile(path: path, sessionId: sid, createdAt: created.doubleValue, modifiedAt: modified.doubleValue)
        }
    }

    /// `pickSessionTranscript(files, { startedAt, resumed })`.
    public static func pickTranscript(_ files: [TranscriptFile], startedAt: Double, resumed: Bool) -> TranscriptChoice? {
        if files.isEmpty { return nil }
        let byWrite = files.enumerated().sorted { $0.element.modifiedAt != $1.element.modifiedAt ? $0.element.modifiedAt > $1.element.modifiedAt : $0.offset < $1.offset }.map(\.element)
        let newest = byWrite[0]
        if resumed {
            let continued = byWrite.first { $0.createdAt < startedAt } ?? newest
            return TranscriptChoice(path: continued.path, sessionId: continued.sessionId, attribution: .resumed)
        }
        let candidates = files.filter { $0.createdAt >= startedAt }
        guard let own = candidates.enumerated().sorted(by: { $0.element.createdAt != $1.element.createdAt ? $0.element.createdAt > $1.element.createdAt : $0.offset < $1.offset }).first?.element else { return nil }
        return TranscriptChoice(path: own.path, sessionId: own.sessionId, attribution: .session)
    }

    public static func work(_ summary: Any?, sessionId: String, transcriptPath: String) -> SessionWork? {
        guard let row = arr(obj(summary)["sessions"]).compactMap({ $0 as? [String: Any] }).first(where: { ($0["sessionId"] as? String) == sessionId }) else { return nil }
        let tokens = numberAt(row, "usage", "input") + numberAt(row, "usage", "output") + numberAt(row, "usage", "cacheWrite5m")
            + numberAt(row, "usage", "cacheWrite1h") + numberAt(row, "usage", "cacheRead")
        let context = row["context"] as? [String: Any]
        return SessionWork(transcriptPath: transcriptPath, requests: Int(numberAt(row, "requests")), tokens: tokens,
                           contextPercent: context.map { numberAt($0, "percent") }, lastActivityAt: numberAt(row, "lastActivityAt"))
    }

    public struct FolderWork: Equatable, Sendable {
        public var files: [TranscriptFile]
        public var summaryAny: Box
        public init(files: [TranscriptFile] = [], summary: Any? = nil) { self.files = files; self.summaryAny = Box(summary) }
    }

    /// The engine's summary, carried as it came.
    public struct Box: Equatable, @unchecked Sendable {
        public let value: Any?
        public init(_ value: Any?) { self.value = value }
        public static func == (a: Box, b: Box) -> Bool {
            switch (a.value, b.value) {
            case (nil, nil): return true
            case (let x as NSObject, let y as NSObject): return x.isEqual(y)
            default: return false
            }
        }
    }

    public static func attachWork(_ sessions: [BoardSession], folders: [String: FolderWork]) -> [BoardSession] {
        sessions.map { session in
            var next = session
            next.work = nil
            if let folder = folders[session.projectPath],
               let choice = pickTranscript(folder.files, startedAt: session.startedAt, resumed: session.resumed),
               choice.attribution != .project {
                next.work = work(folder.summaryAny.value, sessionId: choice.sessionId, transcriptPath: choice.path)
            }
            return next
        }
    }

    public struct FolderPlan: Equatable, Sendable {
        public var cwd: String
        public var sessionKey: String
        public var awaiting: Bool
        public var live: Bool
    }

    public static func folderPlan(_ sessions: [BoardSession], folders: [String: FolderWork]) -> [FolderPlan] {
        var order: [String] = []
        var byFolder: [String: [BoardSession]] = [:]
        for session in sessions {
            if byFolder[session.projectPath] == nil { order.append(session.projectPath) }
            byFolder[session.projectPath, default: []].append(session)
        }
        return order.map { cwd in
            let list = byFolder[cwd] ?? []
            let work = folders[cwd]
            let awaiting = list.contains { session in
                if session.status == "exited" { return false }
                guard let work else { return true }
                let choice = pickTranscript(work.files, startedAt: session.startedAt, resumed: session.resumed)
                return choice == nil || choice?.attribution == .project
            }
            return FolderPlan(cwd: cwd, sessionKey: list.map(\.id).sorted().joined(separator: ","), awaiting: awaiting,
                              live: list.contains { $0.status != "exited" })
        }
    }
}
