import Foundation
import TerminalDeckNativeCore

/// Backend wire rules from github.ts. Native display models intentionally omit
/// API-only fields, so wire values use the existing NativeRPCValue throughout.
public enum BackendGitHubRules {
    public struct Remote: Equatable, Sendable {
        public var name: String; public var url: String; public var resolved: String?
        public init(name: String, url: String, resolved: String? = nil) { self.name = name; self.url = url; self.resolved = resolved }
    }
    public static let notARepo = "This folder is not a git repository. Source control can create one."
    public static func object(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(fields.map { .init($0.0, $0.1) }) }
    public static func text(_ value: String?) -> NativeRPCValue { value.map(NativeRPCValue.string) ?? .null }
    static func matches(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
    /// Explicit ASCII classes retain source no-i/no-u semantics. The ordinary
    /// classifier matcher above remains case-insensitive. Full rules also
    /// refuse any engine-specific before-final-newline anchor match.
    static func asciiMatches(_ text: String, _ pattern: String, full: Bool = false) -> Bool {
        guard let range = text.range(of: pattern, options: .regularExpression) else { return false }
        return !full || range == (text.startIndex..<text.endIndex)
    }
    static func captures(_ text: String, _ pattern: String, options: NSRegularExpression.Options = []) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<found.numberOfRanges).map { Range(found.range(at: $0), in: text).map { String(text[$0]) } }
    }
    /// github.ts:275-282 `redact`: `text.replace(/([a-z][a-z0-9+.-]{0,31}:\/\/)[^/\s@]{1,512}@/gi, '$1***@')`.
    /// Hand-run over UTF-16 code units (the JS regex's own units, no `u` flag) in one linear pass:
    /// the ICU regex backtracked ~32 steps at every position of a long run and took 4.5 s on the
    /// 800 kB blob github.test.ts:106 bounds at 2 s. Same leftmost, non-overlapping matches;
    /// `/i` without `u` widens only ASCII letters (never ſ or the Kelvin sign); `\s` is JS's set.
    public static func redactURL(_ text: String) -> String {
        guard text.contains("://") else { return text }
        let units = Array(text.utf16), count = units.count
        func isLetter(_ u: UInt16) -> Bool { (u >= 0x61 && u <= 0x7A) || (u >= 0x41 && u <= 0x5A) }
        func isScheme(_ u: UInt16) -> Bool { isLetter(u) || (u >= 0x30 && u <= 0x39) || u == 0x2B || u == 0x2E || u == 0x2D }
        func isSpace(_ u: UInt16) -> Bool {
            switch u {
            case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
            default: return false
            }
        }
        var out: [UInt16] = [], copied = 0, floor = 0, colon = 0, changed = false
        while colon + 2 < count {
            guard units[colon] == 0x3A, units[colon + 1] == 0x2F, units[colon + 2] == 0x2F else { colon += 1; continue }
            // Leftmost scheme start: a letter followed only by scheme characters up to the colon,
            // at most 32 units in all, never reaching back into the previous match.
            var start = colon
            while start > max(floor, colon - 32), isScheme(units[start - 1]) { start -= 1 }
            while start < colon, !isLetter(units[start]) { start += 1 }
            let user = colon + 3
            guard start < colon else { colon += 1; continue }
            // Userinfo: 1...512 units outside `/`, whitespace and `@`, then the `@` itself.
            var end = user
            while end < count, end - user <= 512, units[end] != 0x2F, units[end] != 0x40, !isSpace(units[end]) { end += 1 }
            guard end < count, units[end] == 0x40, end > user, end - user <= 512 else { colon += 1; continue }
            if !changed { out.reserveCapacity(count); changed = true }
            out.append(contentsOf: units[copied..<user]); out.append(contentsOf: "***@".utf16)
            copied = end + 1; floor = end + 1; colon = end + 1
        }
        guard changed else { return text }
        out.append(contentsOf: units[copied...])
        return String(decoding: out, as: UTF16.self)
    }
    public static func failure(_ kind: String, _ message: String, _ action: String? = nil, detail: String = "", secrets: [String] = [], broad: Bool = false) -> NativeRPCValue {
        var clean = detail
        for secret in secrets.filter({ $0.utf16.count >= (broad ? 6 : 8) }).sorted(by: { $0.count > $1.count }) {
            clean = clean.replacingOccurrences(of: secret, with: "[redacted]")
        }
        clean = broad ? BackendGitHubSecretRedaction.redact(clean) : redactURL(clean)
        let size = clean.utf16.count
        if size > 4_000 { clean = String(decoding: clean.utf16.prefix(4_000), as: UTF16.self) + "\n… \(size - 4_000) more characters" }
        return object([("ok", .bool(false)), ("kind", .string(kind)), ("message", .string(message)), ("action", text(action)), ("detail", .string(clean))])
    }
    public static func classify(_ result: BackendGitOutcome, secrets: [String] = []) -> NativeRPCValue {
        classify(text: [result.stderr, result.stdout].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), missing: result.missing, timedOut: result.timedOut, secrets: secrets)
    }
    public static func classify(text: String, missing: Bool = false, timedOut: Bool = false, secrets: [String] = []) -> NativeRPCValue {
        func fail(_ kind: String, _ message: String, _ action: String? = nil) -> NativeRPCValue { failure(kind, message, action, detail: text, secrets: secrets) }
        if missing { return fail("gh-missing", "The GitHub CLI is not installed, or is not on your login PATH.", "brew install gh") }
        if timedOut { return fail("timeout", "GitHub did not answer in time.") }
        if text.contains("EAI_AGAIN") || text.contains("ENOTFOUND") || matches(text, #"dial tcp|connection refused|no such host|network is unreachable|host is down|i/o timeout|tls handshake timeout|proxyconnect|connection reset by peer|certificate.*(expired|not valid|unknown authority)"#) {
            return fail("network-down", "Could not reach github.com — check your connection.")
        }
        if matches(text, "not a git repository") { return fail("not-a-repo", notARepo) }
        if matches(text, "no git remotes found") { return fail("no-remote", "This repository has no remotes.", "git remote add origin <url>") }
        if matches(text, "point to a known GitHub host") { return fail("no-github-remote", "None of this repository’s remotes point at GitHub.") }
        if matches(text, "To get started with GitHub CLI|not logged into any GitHub hosts") { return fail("not-authenticated", "You are not signed in to GitHub.", "gh auth login") }
        if matches(text, "HTTP 401|Bad credentials") { return fail("auth-expired", "Your GitHub credentials were rejected — the token has expired or been revoked.", "gh auth login") }
        if matches(text, "rate limit|HTTP 429|submitted too quickly") { return fail("rate-limited", "GitHub’s API rate limit is exhausted. It resets within the hour.", "gh api rate_limit") }
        if let values = captures(text, #"missing required scopes?\s*\[([^\]]+)\]|at least ([a-z:_]+) scope"#, options: .caseInsensitive) {
            let needed = (values[0] ?? values[1] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let first = needed.split(whereSeparator: { $0.isWhitespace || $0 == "," }).first.map(String.init) ?? ""
            return fail("missing-scope", "Your GitHub token is missing the \(needed.isEmpty ? "required" : needed) scope.", needed.isEmpty ? "gh auth refresh" : "gh auth refresh -h github.com -s \(first)")
        }
        if matches(text, "has disabled issues") { return fail("issues-disabled", "Issues are off for this repository.") }
        if matches(text, "Could not resolve to a Repository|HTTP 404|Not Found") { return fail("repo-not-found", "GitHub has no such repository — it may be private, renamed, or deleted.") }
        if matches(text, "HTTP 403|Resource not accessible|must have (push|admin) access") { return fail("no-access", "Your GitHub account cannot read this repository.", "gh auth status") }
        return failure("error", "The GitHub CLI failed.", detail: text.isEmpty ? "gh failed" : text, secrets: secrets)
    }
    public static func parseRemoteConfig(_ output: String) -> [Remote] {
        var entries: [Remote] = []
        for line in output.components(separatedBy: "\n") {
            guard let fields = captures(line.trimmingCharacters(in: .whitespacesAndNewlines), #"^remote\.(.+?)\.(url|gh-resolved)\s+(.*)$"#),
                  let name = fields[0], let key = fields[1], let value = fields[2] else { continue }
            let index: Int
            if let existing = entries.firstIndex(where: { $0.name == name }) { index = existing }
            else { index = entries.count; entries.append(Remote(name: name, url: "")) }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if key == "url" { if entries[index].url.isEmpty { entries[index].url = trimmed } }
            else { entries[index].resolved = trimmed }
        }
        return entries.filter { !$0.url.isEmpty }
    }
    static func segment(_ text: String) -> Bool { !["", ".", ".."].contains(text) && asciiMatches(text, #"^[A-Za-z0-9._-]+$"#, full: true) }
    static func hostName(_ text: String) -> Bool { asciiMatches(text, #"^[A-Za-z0-9][A-Za-z0-9.-]*$"#, full: true) }
    public static func parseRemoteURL(_ raw: String) -> NativeRPCValue? {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        var host: String, path: String
        if asciiMatches(raw, #"^[A-Za-z][A-Za-z0-9+.-]*://"#), let scheme = raw.range(of: "://") {
            let after = String(raw[scheme.upperBound...]); let slash = after.firstIndex(of: "/")
            let authority = slash.map { String(after[..<$0]) } ?? after
            host = authority.split(separator: "@", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            path = slash.map { String(after[$0...]) } ?? ""
        } else {
            guard let fields = captures(raw, #"^(?:([^@/]+)@)?([^:/]+):(.+)$"#), let found = fields[1], let rest = fields[2] else { return nil }
            host = found; path = rest
        }
        host = host.replacingOccurrences(of: #":\d+$"#, with: "", options: .regularExpression).lowercased()
        let parts = path.split(separator: "/").map(String.init)
        guard hostName(host), parts.count == 2 else { return nil }
        let name = parts[1].replacingOccurrences(of: #"\.git$"#, with: "", options: [.regularExpression, .caseInsensitive])
        guard segment(parts[0]), segment(name), !parts[0].hasPrefix("-") else { return nil }
        return object([("host", .string(host)), ("owner", .string(parts[0])), ("name", .string(name))])
    }
    public static func parseResolved(_ value: String) -> NativeRPCValue? {
        let parts = value.split(separator: "/").map(String.init)
        guard [2, 3].contains(parts.count) else { return nil }
        let owner = parts[parts.count - 2], name = parts[parts.count - 1], host = parts.count == 3 ? parts[0] : nil
        guard segment(owner), segment(name), host.map(hostName) ?? true else { return nil }
        return object([("host", text(host?.lowercased())), ("owner", .string(owner)), ("name", .string(name))])
    }
    public static func isGitHubHost(_ host: String, hosts: [String] = ["github.com"]) -> Bool {
        hosts.contains { host.lowercased() == $0 || host.lowercased().hasSuffix("." + $0) }
    }
    public static func ref(host: String, owner: String, name: String, remote: String) -> NativeRPCValue {
        object([("host", .string(host)), ("owner", .string(owner)), ("name", .string(name)), ("nameWithOwner", .string(owner + "/" + name)), ("url", .string("https://" + host + "/" + owner + "/" + name)), ("remote", .string(remote))])
    }
    public static func pickRepo(_ entries: [Remote], hosts: [String] = ["github.com"]) -> NativeRPCValue? {
        let candidates = entries.compactMap { entry -> (Remote, NativeRPCValue)? in
            guard let parsed = parseRemoteURL(entry.url), isGitHubHost(parsed["host"].string ?? "", hosts: hosts) else { return nil }
            return (entry, parsed)
        }
        guard !candidates.isEmpty else { return nil }
        if let explicit = candidates.first(where: { !($0.0.resolved ?? "").isEmpty && $0.0.resolved != "base" }),
           let resolved = parseResolved(explicit.0.resolved ?? ""), resolved["host"].isNullish || isGitHubHost(resolved["host"].string ?? "", hosts: hosts) {
            return ref(host: resolved["host"].string ?? explicit.1["host"].string ?? "", owner: resolved["owner"].string ?? "", name: resolved["name"].string ?? "", remote: explicit.0.name)
        }
        let rank = ["upstream", "github", "origin"]
        let chosen = candidates.first(where: { $0.0.resolved == "base" }) ?? candidates.enumerated().min {
            let a = rank.firstIndex(of: $0.element.0.name) ?? 3, b = rank.firstIndex(of: $1.element.0.name) ?? 3
            return a == b ? $0.offset < $1.offset : a < b
        }!.element
        return ref(host: chosen.1["host"].string ?? "", owner: chosen.1["owner"].string ?? "", name: chosen.1["name"].string ?? "", remote: chosen.0.name)
    }
    public static func clampLimit(_ raw: NativeRPCValue = .missing) -> Int {
        let value = floor(raw.number ?? 20)
        return Int(min(100, max(1, value)))
    }
    public static func sectionKey(_ kind: String, repo: NativeRPCValue, limit: Int? = nil) -> String {
        kind + " " + (repo["host"].string ?? "") + "/" + (repo["nameWithOwner"].string ?? "") + (limit.map { " \($0)" } ?? "")
    }
    public static func listArgs(repo: NativeRPCValue, limit: Int, pulls: Bool) -> [String] {
        let scope = (repo["host"].string == "github.com" ? "" : (repo["host"].string ?? "") + "/") + (repo["nameWithOwner"].string ?? "")
        let fields = pulls ? "number,title,url,state,isDraft,mergedAt,author,createdAt,updatedAt,reviewDecision,labels,headRefName,isCrossRepository,additions,deletions" : "number,title,url,state,stateReason,author,createdAt,updatedAt,labels,assignees"
        return [pulls ? "pr" : "issue", "list", "-R", scope, "--state", "open", "--limit", String(limit), "--json", fields]
    }
    public static func pullBadge(_ raw: NativeRPCValue) -> String {
        let state = (raw["state"].string ?? "").uppercased()
        if state == "MERGED" || !(raw["mergedAt"].string ?? "").isEmpty { return "merged" }
        if state == "CLOSED" { return "closed" }
        return raw["isDraft"].bool == true ? "draft" : "open"
    }
    public static func mapRow(_ raw: NativeRPCValue, pulls: Bool) -> NativeRPCValue? {
        guard raw["number"].number != nil, raw["url"].string != nil else { return nil }
        let labels = (raw["labels"].elements ?? []).compactMap { label -> NativeRPCValue? in
            guard let name = label["name"].string else { return nil }
            let color = label["color"].string ?? ""
            return object([("name", .string(name)), ("color", .string(matches(color, #"^[0-9a-f]{6}$"#) ? color : "8b949e"))])
        }
        var row = object([("number", raw["number"]), ("title", raw["title"].isNullish ? .string("(untitled)") : raw["title"]), ("url", raw["url"]), ("author", raw["author"]["login"].isNullish ? .null : raw["author"]["login"]), ("authorIsBot", .bool(raw["author"]["is_bot"].bool == true)), ("createdAt", .string(raw["createdAt"].string ?? "")), ("updatedAt", .string(raw["updatedAt"].string ?? raw["createdAt"].string ?? "")), ("labels", .array(labels))])
        if pulls {
            let review = ["APPROVED": "approved", "CHANGES_REQUESTED": "changes-requested", "REVIEW_REQUIRED": "review-required"][(raw["reviewDecision"].string ?? "").uppercased()]
            row = row.merging(object([("badge", .string(pullBadge(raw))), ("draft", .bool(raw["isDraft"].bool == true)), ("review", text(review)), ("branch", text(raw["headRefName"].string)), ("fromFork", .bool(raw["isCrossRepository"].bool == true)), ("additions", raw["additions"].number.map(NativeRPCValue.number) ?? .null), ("deletions", raw["deletions"].number.map(NativeRPCValue.number) ?? .null)]))
        } else {
            let reason = ["COMPLETED": "completed", "NOT_PLANNED": "not-planned"][(raw["stateReason"].string ?? "").uppercased()]
            row = row.merging(object([("state", .string((raw["state"].string ?? "").uppercased() == "CLOSED" ? "closed" : "open")), ("reason", text(reason)), ("assignees", .array((raw["assignees"].elements ?? []).compactMap { $0["login"].string.map(NativeRPCValue.string) }))]))
        }
        return row
    }
}

/// Mirrors github.ts's one cache: joined work is disowned on clear/refresh,
/// stale completions cannot overwrite new answers, and storage is capped at 200.
public actor BackendGitHubCache {
    private struct Entry { let value: NativeRPCValue; let expiresAt: Double }
    private struct Pending { let id: UUID; let task: Task<NativeRPCValue, Error> }
    private var values: [String: Entry] = [:], order: [String] = []
    private var inflight: [String: Pending] = [:]
    private let now: @Sendable () -> Double
    public init(now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) { self.now = now }
    public func clear(prefix: String? = nil) {
        if let prefix, !prefix.isEmpty {
            values = values.filter { !$0.key.hasPrefix(prefix) }; order.removeAll { $0.hasPrefix(prefix) }; inflight = inflight.filter { !$0.key.hasPrefix(prefix) }
        } else { values.removeAll(); order.removeAll(); inflight.removeAll() }
    }
    public func through(_ key: String, refresh: Bool = false, load: @escaping @Sendable () async throws -> NativeRPCValue,
                        ttl: @escaping @Sendable (NativeRPCValue) -> Double) async throws -> NativeRPCValue {
        if !refresh {
            if let hit = values[key], hit.expiresAt > now() { return hit.value }
            if let pending = inflight[key] { return try await pending.task.value }
        }
        let id = UUID(), task = Task { try await load() }; inflight[key] = Pending(id: id, task: task)
        do {
            let value = try await task.value
            if inflight[key]?.id == id {
                let clock = now(); values = values.filter { $0.value.expiresAt > clock }; order.removeAll { values[$0] == nil || $0 == key }
                while order.count >= 200 { values[order.removeFirst()] = nil }
                values[key] = Entry(value: value, expiresAt: clock + ttl(value)); order.append(key); inflight[key] = nil
            }
            return value
        } catch { if inflight[key]?.id == id { inflight[key] = nil }; throw error }
    }
}
