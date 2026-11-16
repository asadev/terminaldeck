import Foundation
import TerminalDeckNativeCore

/// One GitHub repository as the Code page's actions need it.
public struct BackendCodeBackupRepo: Sendable, Equatable {
    public var nameWithOwner: String
    public var isPrivate: Bool
    public var canPush: Bool
    public var description: String?
    public init(nameWithOwner: String, isPrivate: Bool, canPush: Bool, description: String? = nil) {
        self.nameWithOwner = nameWithOwner; self.isPrivate = isPrivate; self.canPush = canPush; self.description = description
    }
    public var owner: String { String(nameWithOwner.split(separator: "/").first ?? "") }
    public var name: String { String(nameWithOwner.split(separator: "/").last ?? "") }
}

/// Where Git sends and fetches for a GitHub home, and the process settings that carry the sign-in. The token is only
/// ever in the child's environment (`GIT_CONFIG_*`), never in an argument, a URL, a file or a log line.
public struct BackendCodeBackupTransport: Sendable {
    public var url: String
    public var environment: [String: String]
    /// Text to scrub from any Git message before it is shown.
    public var secrets: [String]
    public init(url: String, environment: [String: String], secrets: [String] = []) {
        self.url = url; self.environment = environment; self.secrets = secrets
    }
    public func scrub(_ text: String) -> String {
        var out = text
        for secret in secrets where secret.utf8.count >= 8 { out = out.replacingOccurrences(of: secret, with: "[hidden]") }
        return BackendGitHubSecretRedaction.redact(out)
    }
}

public enum BackendCodeBackupCreated: Sendable, Equatable {
    case made(BackendCodeBackupRepo)
    /// The name is already used on his account.
    case taken
    /// GitHub said no; the plain reason.
    case refused(String)
}

/// The GitHub side of the actions. The live one uses the sign-in the app already has (its own GitHub App sign-in or
/// the GitHub CLI's); tests use a fake and never reach GitHub.
public protocol BackendCodeBackupAccount: Sendable {
    /// His GitHub login; nil when this Mac is not connected to GitHub.
    func login() async -> String?
    /// The repositories the sign-in lists.
    func repositories() async -> [BackendCodeBackupRepo]
    /// One repository ("owner/name"), nil when it does not exist or the sign-in cannot see it.
    func repository(_ home: String) async -> BackendCodeBackupRepo?
    /// Makes a NEW repository on his own account. Always private; never anything else.
    func create(name: String, description: String) async -> BackendCodeBackupCreated
    /// How Git reaches the home with his sign-in; nil without a sign-in.
    func transport(_ home: String) async -> BackendCodeBackupTransport?
    /// Correction 14 Nov: true only when GitHub POSITIVELY says nothing on this home reacts to a push: no webhook, no
    /// deploy key, no Pages site, and no installed app that reaches every repository of his (other than Terminal
    /// Deck's own). Any doubt (an error, a refused question) is false.
    func quiet(_ home: String) async -> Bool
}

public struct BackendCodeBackupLiveAccount: BackendCodeBackupAccount {
    let auth: BackendGitHubAuthenticator
    let http: any BackendGitHubHTTPFetching
    let tools: any BackendGitHubToolRunning
    let environment: [String: String]

    public init(auth: BackendGitHubAuthenticator, http: any BackendGitHubHTTPFetching = BackendGitHubURLSessionHTTP(),
                tools: any BackendGitHubToolRunning, environment: [String: String]) {
        self.auth = auth; self.http = http; self.tools = tools; self.environment = environment
    }

    public func login() async -> String? {
        let status = await auth.status()
        guard status["connected"].bool == true, let login = status["identity"]["login"].string, !login.isEmpty else { return nil }
        return login
    }

    public func repositories() async -> [BackendCodeBackupRepo] {
        let status = await auth.status()
        guard status["connected"].bool == true else { return [] }
        return (status["access"]["repos"].elements ?? []).compactMap { repo in
            guard let full = repo["nameWithOwner"].string else { return nil }
            return BackendCodeBackupRepo(nameWithOwner: full, isPrivate: repo["private"].bool == true, canPush: repo["canPush"].bool == true,
                                         description: repo["description"].string)
        }
    }

    /// The sign-in's token: the app's own, else the GitHub CLI's (as Clone does). Only ever used in a header.
    private func token() async -> String? {
        if let credential = await auth.gitCredential(), !credential.password.isEmpty { return credential.password }
        guard let outcome = try? await tools.run(tool: "gh", arguments: ["auth", "token", "--hostname", auth.host], cwd: nil,
                                                 environment: BackendGitHubAuthenticator.probeEnvironment(environment), timeoutMilliseconds: 5_000,
                                                 maximumBytes: 16_384), outcome.ok else { return nil }
        let found = outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !found.isEmpty, found.utf8.count <= 4096, !found.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return found
    }

    public func repository(_ home: String) async -> BackendCodeBackupRepo? {
        guard let token = await token() else { return nil }
        let url = BackendGitHubRepositories.apiRoot(auth.host) + "/repos/" + home
        guard let response = try? await http.fetch(url: url, method: "GET", headers: BackendGitHubRepositories.headers(token: token), body: nil,
                                                   timeoutMilliseconds: 15_000), response.ok,
              let raw = try? NativeRPCValue.parseJSON(Data(response.body.utf8)), let full = raw["full_name"].string else { return nil }
        return BackendCodeBackupRepo(nameWithOwner: full, isPrivate: raw["private"].bool == true, canPush: raw["permissions"]["push"].bool == true,
                                     description: raw["description"].string)
    }

    public func create(name: String, description: String) async -> BackendCodeBackupCreated {
        guard let token = await token() else { return .refused("GitHub is not connected") }
        // private: true is the only visibility this app ever asks for.
        let body = NativeRPCValue.object([.init("name", .string(name)), .init("private", .bool(true)), .init("description", .string(description)),
                                          .init("auto_init", .bool(false))])
        guard let text = try? String(decoding: body.encodedJSON(), as: UTF8.self) else { return .refused("the request could not be made") }
        var headers = BackendGitHubRepositories.headers(token: token); headers["Content-Type"] = "application/json"
        let response: BackendGitHubHTTPResponse
        do {
            response = try await http.fetch(url: BackendGitHubRepositories.apiRoot(auth.host) + "/user/repos", method: "POST", headers: headers,
                                            body: text, timeoutMilliseconds: 20_000)
        } catch { return .refused("GitHub did not answer") }
        if response.status == 422, response.body.localizedCaseInsensitiveContains("already exists") { return .taken }
        guard response.ok, let raw = try? NativeRPCValue.parseJSON(Data(response.body.utf8)), let full = raw["full_name"].string else {
            if response.status == 403 || response.status == 404 { return .refused("GitHub did not allow this sign-in to make a repository") }
            return .refused("GitHub answered \(response.status)")
        }
        return .made(BackendCodeBackupRepo(nameWithOwner: full, isPrivate: raw["private"].bool == true, canPush: true, description: description))
    }

    public func quiet(_ home: String) async -> Bool {
        guard let token = await token() else { return false }
        let root = BackendGitHubRepositories.apiRoot(auth.host), headers = BackendGitHubRepositories.headers(token: token)
        func get(_ path: String) async -> NativeRPCValue? {
            guard let response = try? await http.fetch(url: root + path, method: "GET", headers: headers, body: nil, timeoutMilliseconds: 15_000),
                  response.ok else { return nil }
            return try? NativeRPCValue.parseJSON(Data(response.body.utf8))
        }
        guard let repository = await get("/repos/" + home), repository["has_pages"].bool == false else { return false }
        guard let hooks = await get("/repos/" + home + "/hooks")?.elements, hooks.isEmpty else { return false }
        guard let keys = await get("/repos/" + home + "/keys")?.elements, keys.isEmpty else { return false }
        guard let installations = await get("/user/installations?per_page=100")?["installations"].elements else { return false }
        let ours = BackendGitHubAppRegistration.resolve(environment: environment).slug?.lowercased()
        return !installations.contains { $0["repository_selection"].string == "all" && $0["app_slug"].string?.lowercased() != ours }
    }

    public func transport(_ home: String) async -> BackendCodeBackupTransport? {
        guard let token = await token() else { return nil }
        return Self.https(host: auth.host, home: home, token: token)
    }

    /// HTTPS only, the sign-in as a header for that host only, no stored helpers, no prompts, no redirects.
    static func https(host: String, home: String, token: String) -> BackendCodeBackupTransport {
        let encoded = Data(("x-access-token:" + token).utf8).base64EncodedString()
        let settings = [
            ("credential.helper", ""), ("core.askPass", "/usr/bin/false"), ("http.followRedirects", "false"),
            ("http.https://\(host)/.extraHeader", "Authorization: Basic \(encoded)"),
            ("protocol.allow", "never"), ("protocol.https.allow", "always"),
        ]
        return BackendCodeBackupTransport(url: "https://\(host)/\(home).git", environment: BackendCodeBackupGitWriter.settings(settings, extra: [
            "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/false", "SSH_ASKPASS": "/usr/bin/false",
        ]), secrets: [token, encoded])
    }
}
