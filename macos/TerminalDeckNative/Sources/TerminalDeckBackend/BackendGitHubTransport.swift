import Foundation
import TerminalDeckNativeCore

public struct BackendGitHubAppRegistration: Equatable, Sendable {
    public let clientID: String?; public let slug: String?
    public init(clientID: String?, slug: String?) { self.clientID = clientID; self.slug = slug }
    public static let shipping = Self(clientID: "Iv23limkNV4N6mChRl60", slug: "terminal-deck")
    public static let absent = Self(clientID: nil, slug: nil)
    public static let clientIDEnvironment = "TERMINALDECK_GITHUB_APP_CLIENT_ID"
    public static let slugEnvironment = "TERMINALDECK_GITHUB_APP_SLUG"
    public static let unconfiguredReason = "This build has no GitHub App registered, so there is nothing here to sign in through. Run gh auth login in a terminal and this app will use it, or set TERMINALDECK_GITHUB_APP_CLIENT_ID to a registration of your own."
    public static func resolve(environment: [String: String], built: Self = .shipping) -> Self {
        func clean(_ raw: String?) -> String? { let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines); return value.isEmpty ? nil : value }
        guard let clientID = clean(environment[clientIDEnvironment]) ?? clean(built.clientID) else { return .absent }
        return Self(clientID: clientID, slug: clean(environment[slugEnvironment]) ?? clean(built.slug))
    }
    public func installURL(host: String = "github.com") -> String? {
        guard let slug, BackendGitHubRules.asciiMatches(slug, #"^[A-Za-z0-9][A-Za-z0-9-]*$"#, full: true) else { return nil }
        return "https://\(host)/apps/\(slug.lowercased())/installations/new"
    }
}

public struct BackendGitHubHTTPResponse: Sendable {
    public let status: Int; public let body: String; public let headers: [String: String]
    public var ok: Bool { (200..<300).contains(status) }
    public init(status: Int, body: String, headers: [String: String] = [:]) {
        self.status = status; self.body = body
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
    }
    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}
public protocol BackendGitHubHTTPFetching: Sendable {
    /// Zero preserves the device poll's cancellable, otherwise unbounded wait.
    func fetch(url: String, method: String, headers: [String: String], body: String?, timeoutMilliseconds: Int) async throws -> BackendGitHubHTTPResponse
}
/// A native, ephemeral HTTP transport. No requests occur on initialization.
public struct BackendGitHubURLSessionHTTP: BackendGitHubHTTPFetching {
    public init() {}
    public func fetch(url: String, method: String, headers: [String: String], body: String?, timeoutMilliseconds: Int) async throws -> BackendGitHubHTTPResponse {
        guard let url = URL(string: url), url.scheme == "https", let host = url.host, !host.isEmpty else { throw NativeRPCError.invalidArguments("GitHub endpoint must be an HTTPS URL") }
        let timeout: TimeInterval = timeoutMilliseconds > 0 ? Double(timeoutMilliseconds) / 1000 : .infinity
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method; request.allHTTPHeaderFields = headers; request.httpBody = body.map { Data($0.utf8) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw NativeRPCError(code: "network", message: "GitHub returned no HTTP response") }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { out, field in out[String(describing: field.key).lowercased()] = String(describing: field.value) }
        return BackendGitHubHTTPResponse(status: response.statusCode, body: String(decoding: data, as: UTF8.self), headers: headers)
    }
}

public protocol BackendGitHubToolRunning: Sendable {
    func run(tool: String, arguments: [String], cwd: String?, environment: [String: String], timeoutMilliseconds: Int, maximumBytes: Int) async throws -> BackendGitOutcome
}
/// Uses the existing native POSIX pipe owner, preserving stdout/stderr. Login
/// PATH comes from the shared provider resolver, never a guessed GUI PATH.
public struct BackendGitHubNativeTools: BackendGitHubToolRunning {
    private let loginPath: @Sendable () async throws -> String
    private let home: String
    private let executor = BackendDevProcessExecutor()
    public init(home: String, loginPath: @escaping @Sendable () async throws -> String) { self.home = home; self.loginPath = loginPath }
    public func run(tool: String, arguments: [String], cwd: String?, environment: [String: String], timeoutMilliseconds: Int, maximumBytes: Int) async throws -> BackendGitOutcome {
        let path = try await loginPath()
        guard let command = BackendNativeProviders.lookup(tool, path: path) else { return BackendGitOutcome(ok: false, stdout: "", stderr: "spawn \(tool) ENOENT", missing: true, exitCode: 127, timedOut: false) }
        var env = environment; env["PATH"] = path
        let result = try await executor.run(command: command, arguments: arguments, environment: env, cwd: cwd ?? home, timeoutMilliseconds: timeoutMilliseconds, maximumBytes: maximumBytes)
        // Node's maxBuffer was per stream. The shared owner uses one total
        // ceiling, so additionally reject either completed stream past half.
        if result.stdout.utf8.count > maximumBytes / 2 || result.stderr.utf8.count > maximumBytes / 2 {
            return BackendGitOutcome(ok: false, stdout: result.stdout, stderr: result.stderr, missing: result.missing, exitCode: result.exitCode, timedOut: true)
        }
        return result
    }
}

/// Redaction used by auth/repository failures follows redact.ts, including
/// exact literals (handled by failure), structural keys, tokens, entropy and
/// identity folding. The overview path uses only its original URL redactor.
/// The patterns are compiled once (2 Nov, Agents seat: At work cleaned every Hoot tool result on every refresh and
/// compiled each pattern again for each one); order, options and templates are unchanged.
enum BackendGitHubSecretRedaction {
    private typealias Rule = (expression: NSRegularExpression, template: String)
    private static func rule(_ pattern: String, _ template: String, _ options: NSRegularExpression.Options = []) -> Rule? {
        (try? NSRegularExpression(pattern: pattern, options: options)).map { (expression: $0, template: template) }
    }
    private static let key = #"[A-Za-z0-9_.\[\]-]*(?:token|secret|passwd|password|pwd|api[_-]?key|access[_-]?key|apikey|credential|auth(?!or)|bearer|private[_-]?key|client[_-]?secret|signature|session[_-]?key)[A-Za-z0-9_.\[\]-]*"#
    private static let headers = "authorization|proxy-authorization|www-authenticate|x-api-key|api-key|apikey|x-auth-token|x-access-token|cookie|set-cookie|x-csrf-token"
    private static let tokenPatterns = [#"\bsk-ant-[A-Za-z0-9_-]{10,}"#, #"\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{16,}"#, #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{16,}"#, #"\bgithub_pat_[A-Za-z0-9_]{20,}"#, #"\bglpat-[A-Za-z0-9_-]{16,}"#, #"\bxox[abprse]-[A-Za-z0-9-]{10,}"#, #"\bxapp-[0-9]-[A-Za-z0-9-]{10,}"#, #"https://hooks\.slack\.com/services/[A-Za-z0-9/]+"#, #"\b(?:AKIA|ASIA|AGPA|AIDA|AROA)[0-9A-Z]{16}\b"#, #"\bAIza[A-Za-z0-9_-]{30,}"#, #"\bya29\.[A-Za-z0-9_-]{10,}"#, #"\b[sprk]k_(?:live|test)_[A-Za-z0-9]{10,}"#, #"\bnpm_[A-Za-z0-9]{30,}"#, #"\bdop_v1_[a-f0-9]{40,}"#, #"\bhf_[A-Za-z0-9]{20,}"#, #"\bsbp_[a-f0-9]{20,}"#, #"\bshp(?:at|ca|pa|ss)_[a-f0-9]{20,}"#, #"\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}"#, #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}"#]
    private static let structural: [Rule?] = [
        rule(#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, "-----BEGIN PRIVATE KEY-----[redacted]-----END PRIVATE KEY-----"),
        rule(#"-----BEGIN (?:OPENSSH|PGP|RSA|EC|DSA) [A-Z ]*-----[\s\S]*?-----END [A-Z ]*-----"#, "-----BEGIN KEY-----[redacted]-----END KEY-----"),
        rule(#"\b([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^/\s@]+@"#, "$1[redacted]@", .caseInsensitive),
        rule("(\"(?:" + headers + ")\"\\s*:\\s*)\"[^\"]*\"", "$1\"[redacted]\"", .caseInsensitive),
        rule("\\b((?:" + headers + ")\\s*:\\s*)[^\\r\\n\"']+", "$1[redacted]", .caseInsensitive),
        rule("\\b(" + key + #")("?\s*[:=]\s*)(["'])(?:\\.|(?!\3)[^\\])*\3"#, "$1$2$3[redacted]$3", .caseInsensitive),
        rule("\\b(" + key + #")(\s*[:=]\s*)(?!\[redacted\])([^\s,;)}\]"']+)"#, "$1$2[redacted]", .caseInsensitive),
        rule(#"\b(Bearer|Basic|Token|ApiKey)\s+[A-Za-z0-9._~+/=-]{8,}"#, "$1 [redacted]", .caseInsensitive),
        rule(#"\b(USER|USERNAME|LOGNAME)(\s*[:=]\s*)([A-Za-z0-9._-]+)"#, "$1$2<user>"),
    ]
    /// Everything before the high-entropy pass, in its original order.
    private static let leading: [Rule] = structural.compactMap { $0 } + tokenPatterns.compactMap { rule($0, "[redacted]") }
    private static let longRun = try? NSRegularExpression(pattern: #"[A-Za-z0-9+=_-]{32,}"#)
    // BackendGitHubRules.matches semantics: case-insensitive.
    private static let uuid = try? NSRegularExpression(pattern: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#, options: .caseInsensitive)
    private static let digit = try? NSRegularExpression(pattern: "[0-9]", options: .caseInsensitive)
    private static let letter = try? NSRegularExpression(pattern: "[A-Za-z]", options: .caseInsensitive)
    /// After the home folder becomes "~".
    private static let trailingRules: [Rule?] = [
        rule(#"(/Users/|/home/)[A-Za-z0-9._-]+"#, "$1<user>"),
        rule(#"([A-Za-z]:\\Users\\)[A-Za-z0-9._-]+"#, "$1<user>", .caseInsensitive),
    ]
    private static let trailing: [Rule] = trailingRules.compactMap { $0 }
    /// The bare user name fold, compiled once per name (in practice one or two names per run).
    private static let userLock = NSLock()
    nonisolated(unsafe) private static var userRules: [String: NSRegularExpression] = [:]
    private static func userRule(_ username: String) -> NSRegularExpression? {
        userLock.lock(); defer { userLock.unlock() }
        if let known = userRules[username] { return known }
        let name = NSRegularExpression.escapedPattern(for: username)
        guard let expression = try? NSRegularExpression(pattern: "(?:(?<=^|[\\s/\\\\:~@])" + name + "(?=[/\\\\@]))|(?:(?<=[/\\\\~@])" + name + "(?=$|[/\\\\@\\s'\"]))", options: .anchorsMatchLines) else { return nil }
        if userRules.count >= 16 { userRules.removeAll() }
        userRules[username] = expression
        return expression
    }
    private static func found(_ expression: NSRegularExpression?, _ text: String) -> Bool {
        expression?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func redact(_ value: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        var out = value
        func replace(_ expression: NSRegularExpression, _ template: String) {
            out = expression.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        for rule in leading { replace(rule.expression, rule.template) }
        if let longRun {
            for match in longRun.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
                guard let range = Range(match.range, in: out) else { continue }
                let candidate = String(out[range])
                guard !found(uuid, candidate), found(digit, candidate), found(letter, candidate), candidate.filter({ $0 == "-" || $0 == "_" }).count <= 2 else { continue }
                let counts = candidate.reduce(into: [Character: Int]()) { $0[$1, default: 0] += 1 }
                let entropy = counts.values.reduce(0.0) { let p = Double($1) / Double(candidate.count); return $0 - p * log2(p) }
                if entropy >= 3 { out.replaceSubrange(range, with: "[redacted]") }
            }
        }
        if !home.isEmpty { out = out.replacingOccurrences(of: home, with: "~") }
        for rule in trailing { replace(rule.expression, rule.template) }
        let username = URL(fileURLWithPath: home).lastPathComponent
        if username.count >= 2, let expression = userRule(username) { replace(expression, "<user>") }
        return out
    }
}
