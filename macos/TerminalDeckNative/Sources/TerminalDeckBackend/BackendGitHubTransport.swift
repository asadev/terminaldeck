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
enum BackendGitHubSecretRedaction {
    static func redact(_ value: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        var out = value
        func replace(_ pattern: String, _ template: String, options: NSRegularExpression.Options = []) {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            out = expression.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        let key = #"[A-Za-z0-9_.\[\]-]*(?:token|secret|passwd|password|pwd|api[_-]?key|access[_-]?key|apikey|credential|auth(?!or)|bearer|private[_-]?key|client[_-]?secret|signature|session[_-]?key)[A-Za-z0-9_.\[\]-]*"#
        let headers = "authorization|proxy-authorization|www-authenticate|x-api-key|api-key|apikey|x-auth-token|x-access-token|cookie|set-cookie|x-csrf-token"
        replace(#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, "-----BEGIN PRIVATE KEY-----[redacted]-----END PRIVATE KEY-----")
        replace(#"-----BEGIN (?:OPENSSH|PGP|RSA|EC|DSA) [A-Z ]*-----[\s\S]*?-----END [A-Z ]*-----"#, "-----BEGIN KEY-----[redacted]-----END KEY-----")
        replace(#"\b([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^/\s@]+@"#, "$1[redacted]@", options: .caseInsensitive)
        replace("(\"(?:" + headers + ")\"\\s*:\\s*)\"[^\"]*\"", "$1\"[redacted]\"", options: .caseInsensitive)
        replace("\\b((?:" + headers + ")\\s*:\\s*)[^\\r\\n\"']+", "$1[redacted]", options: .caseInsensitive)
        replace("\\b(" + key + #")("?\s*[:=]\s*)(["'])(?:\\.|(?!\3)[^\\])*\3"#, "$1$2$3[redacted]$3", options: .caseInsensitive)
        replace("\\b(" + key + #")(\s*[:=]\s*)(?!\[redacted\])([^\s,;)}\]"']+)"#, "$1$2[redacted]", options: .caseInsensitive)
        replace(#"\b(Bearer|Basic|Token|ApiKey)\s+[A-Za-z0-9._~+/=-]{8,}"#, "$1 [redacted]", options: .caseInsensitive)
        replace(#"\b(USER|USERNAME|LOGNAME)(\s*[:=]\s*)([A-Za-z0-9._-]+)"#, "$1$2<user>")
        let tokenPatterns = [#"\bsk-ant-[A-Za-z0-9_-]{10,}"#, #"\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{16,}"#, #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{16,}"#, #"\bgithub_pat_[A-Za-z0-9_]{20,}"#, #"\bglpat-[A-Za-z0-9_-]{16,}"#, #"\bxox[abprse]-[A-Za-z0-9-]{10,}"#, #"\bxapp-[0-9]-[A-Za-z0-9-]{10,}"#, #"https://hooks\.slack\.com/services/[A-Za-z0-9/]+"#, #"\b(?:AKIA|ASIA|AGPA|AIDA|AROA)[0-9A-Z]{16}\b"#, #"\bAIza[A-Za-z0-9_-]{30,}"#, #"\bya29\.[A-Za-z0-9_-]{10,}"#, #"\b[sprk]k_(?:live|test)_[A-Za-z0-9]{10,}"#, #"\bnpm_[A-Za-z0-9]{30,}"#, #"\bdop_v1_[a-f0-9]{40,}"#, #"\bhf_[A-Za-z0-9]{20,}"#, #"\bsbp_[a-f0-9]{20,}"#, #"\bshp(?:at|ca|pa|ss)_[a-f0-9]{20,}"#, #"\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}"#, #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}"#]
        for pattern in tokenPatterns { replace(pattern, "[redacted]") }
        if let regex = try? NSRegularExpression(pattern: #"[A-Za-z0-9+=_-]{32,}"#) {
            for match in regex.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
                guard let range = Range(match.range, in: out) else { continue }
                let candidate = String(out[range])
                guard !BackendGitHubRules.matches(candidate, #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#),
                      BackendGitHubRules.matches(candidate, "[0-9]"), BackendGitHubRules.matches(candidate, "[A-Za-z]"), candidate.filter({ $0 == "-" || $0 == "_" }).count <= 2 else { continue }
                let counts = candidate.reduce(into: [Character: Int]()) { $0[$1, default: 0] += 1 }
                let entropy = counts.values.reduce(0.0) { let p = Double($1) / Double(candidate.count); return $0 - p * log2(p) }
                if entropy >= 3 { out.replaceSubrange(range, with: "[redacted]") }
            }
        }
        if !home.isEmpty { out = out.replacingOccurrences(of: home, with: "~") }
        replace(#"(/Users/|/home/)[A-Za-z0-9._-]+"#, "$1<user>")
        replace(#"([A-Za-z]:\\Users\\)[A-Za-z0-9._-]+"#, "$1<user>", options: .caseInsensitive)
        let username = URL(fileURLWithPath: home).lastPathComponent
        if username.count >= 2 { replace("(?:(?<=^|[\\s/\\\\:~@])" + NSRegularExpression.escapedPattern(for: username) + "(?=[/\\\\@]))|(?:(?<=[/\\\\~@])" + NSRegularExpression.escapedPattern(for: username) + "(?=$|[/\\\\@\\s'\"]))", "<user>", options: .anchorsMatchLines) }
        return out
    }
}
