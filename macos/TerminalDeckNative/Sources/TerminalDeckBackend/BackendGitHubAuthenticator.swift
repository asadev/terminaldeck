import Foundation
import TerminalDeckNativeCore

/// One host-owned login, shared by native channels, Git commands and remote
/// feature suppliers. Constructor performs no network, credential or file IO.
public actor BackendGitHubAuthenticator {
    public typealias Resolver = @Sendable (String) async -> NativeRPCValue
    public nonisolated let host: String
    public nonisolated let appConfigured: Bool
    public nonisolated let installURL: String?
    private let file: URL, environment: [String: String]
    private let http: any BackendGitHubHTTPFetching, tools: any BackendGitHubToolRunning
    private let now: @Sendable () -> Double
    private let sleep: @Sendable (Double) async throws -> Void
    private let resolveRepo: Resolver, resolveBranch: Resolver
    private let changed: @Sendable () async -> Void
    private let clientID: String?
    private var loaded = false, stored: NativeRPCValue?
    private var ghPresent: Bool?
    private var cached: (at: Double, value: NativeRPCValue)?
    private var accessCache: (at: Double, token: String, value: NativeRPCValue)?
    private var generation = 0
    private struct Flow: Sendable { let id: UUID; let prompt: NativeRPCValue; let task: Task<Void, Never> }
    private var flow: Flow?
    private var lastFlowFailure: NativeRPCValue?
    public init(dataDirectory: URL, environment: [String: String], host: String? = nil,
                registration: BackendGitHubAppRegistration = .shipping,
                http: any BackendGitHubHTTPFetching = BackendGitHubURLSessionHTTP(), tools: any BackendGitHubToolRunning,
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 },
                sleep: @escaping @Sendable (Double) async throws -> Void = { milliseconds in try await Task.sleep(for: .milliseconds(milliseconds)) },
                resolveRepo: @escaping Resolver, resolveBranch: @escaping Resolver = { _ in .null },
                onAuthChanged: @escaping @Sendable () async -> Void = {}) throws {
        guard dataDirectory.isFileURL, dataDirectory.path.hasPrefix("/"), !dataDirectory.path.contains("\0") else { throw NativeRPCError.invalidArguments("GitHub storage needs an absolute data directory") }
        self.file = dataDirectory.appendingPathComponent("github/auth.json")
        self.environment = environment; self.http = http; self.tools = tools; self.now = now; self.sleep = sleep
        self.resolveRepo = resolveRepo; self.resolveBranch = resolveBranch; changed = onAuthChanged
        let value = (host ?? environment["GH_HOST"] ?? "github.com").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.host = value.isEmpty ? "github.com" : value
        let registration = BackendGitHubAppRegistration.resolve(environment: environment, built: registration)
        clientID = registration.clientID; appConfigured = clientID != nil; installURL = registration.installURL(host: self.host)
    }
    public static func probeEnvironment(_ environment: [String: String]) -> [String: String] {
        var result = environment
        for key in ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"] { result[key] = nil }
        return toolEnvironment(result)
    }
    public static func toolEnvironment(_ environment: [String: String], token: String? = nil) -> [String: String] {
        var result = environment
        if let token { result["GH_TOKEN"] = token }
        for (key, value) in ["LC_ALL": "C", "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1", "GH_PAGER": "cat", "NO_COLOR": "1", "CLICOLOR": "0"] { result[key] = value }
        return result
    }
    public static func parseScopes(_ header: String?) -> [String] { (header ?? "").components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    private func envToken() -> String? {
        for name in ["GH_TOKEN", "GITHUB_TOKEN"] { let value = (environment[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines); if !value.isEmpty { return value } }
        return nil
    }
    private func readStored() -> NativeRPCValue? {
        if loaded { return stored }; loaded = true
        // Same byte schema as TS: legacy missing clientKind remains OAuth.
        if let data = try? BackendAccountFiles.boundedRead(file, maximum: Int.max), let value = try? NativeRPCValue.parseJSON(data, maximumBytes: Int.max), let token = value["token"].string, !token.isEmpty { stored = value }
        return stored
    }
    public func secrets() -> [String] { [envToken(), readStored()?["token"].string].compactMap { $0 } }
    public func scrubSecrets(_ text: String) -> String {
        var out = text
        for secret in secrets() where secret.utf16.count >= 8 { out = out.replacingOccurrences(of: secret, with: "[redacted]") }
        return out
    }
    public func toolToken() -> String? { envToken() == nil ? readStored()?["token"].string : nil }
    /// Internal credential supplier only. Never register this as a UI channel.
    public func gitCredential() -> (username: String, password: String)? {
        if let token = envToken() { return (readStored()?["login"].string ?? "x-access-token", token) }
        guard let credential = readStored(), let token = credential["token"].string, !token.isEmpty else { return nil }
        let login = credential["login"].string ?? ""
        return (login.isEmpty ? "x-access-token" : login, token)
    }
    private func writeStored(_ credential: NativeRPCValue) async throws {
        try BackendAccountFiles.writeAtomic(try credential.encodedJSON(pretty: true), to: file)
        stored = credential; loaded = true; generation += 1; cached = nil; accessCache = nil
        await changed()
    }
    private func clearStored() async throws {
        // A failed deletion cannot be presented as successful disconnection.
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        stored = nil; loaded = true; generation += 1; cached = nil; accessCache = nil
        await changed()
    }
    private func fail(_ kind: String, _ message: String, detail: String = "", token: String? = nil, action: String? = nil) -> NativeRPCValue {
        BackendGitHubRules.failure(kind, message, action, detail: detail, secrets: secrets() + (token.map { [$0] } ?? []), broad: true)
    }
    private func gh(_ args: [String]) async throws -> BackendGitOutcome {
        try await tools.run(tool: "gh", arguments: args, cwd: nil, environment: Self.probeEnvironment(environment), timeoutMilliseconds: 10_000, maximumBytes: 2 * 1024 * 1024)
    }
    public func ghInstalled() async -> Bool {
        if let ghPresent { return ghPresent }
        do { let result = try await gh(["--version"]); ghPresent = !result.missing }
        catch { ghPresent = true }
        return ghPresent ?? false
    }
    private func ghToken() async -> String? {
        guard let result = try? await gh(["auth", "token", "--hostname", host]), result.ok else { return nil }
        let token = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines); return token.isEmpty ? nil : token
    }
    private func identify(_ token: String) async -> NativeRPCValue {
        do {
            let response = try await http.fetch(url: BackendGitHubRepositories.apiRoot(host) + "/user", method: "GET", headers: BackendGitHubRepositories.headers(token: token), body: nil, timeoutMilliseconds: 15_000)
            if response.status == 401 { return fail("auth-expired", "GitHub rejected this sign-in — the token has expired or been revoked.", detail: response.body, token: token) }
            if response.status == 403 && BackendGitHubRules.matches(response.body, "rate limit") { return fail("rate-limited", "GitHub’s API rate limit is exhausted, so the sign-in could not be checked. It resets within the hour.", detail: response.body, token: token) }
            guard response.ok else { return fail("error", "GitHub answered HTTP \(response.status) when asked who this sign-in belongs to.", detail: response.body, token: token) }
            guard let raw = try? NativeRPCValue.parseJSON(Data(response.body.utf8)), let login = raw["login"].string else { return fail("error", "GitHub returned an account it did not name.", detail: response.body, token: token) }
            let name = raw["name"].string
            let identity = BackendGitHubRules.object([("login", .string(login)), ("name", BackendGitHubRules.text(name?.isEmpty == false ? name : nil)), ("htmlUrl", .string(raw["html_url"].string ?? "https://\(host)/\(login)")), ("avatarUrl", BackendGitHubRules.text(raw["avatar_url"].string))])
            return BackendGitHubRules.object([("ok", .bool(true)), ("identity", identity), ("scopes", .array(Self.parseScopes(response.header("x-oauth-scopes")).map(NativeRPCValue.string))), ("scopesReported", .bool(response.header("x-oauth-scopes") != nil))])
        } catch {
            return BackendGitHubRepositories.timedOut(error) ? fail("timeout", "GitHub did not answer in time.") : fail("network-down", "Could not reach \(host) — check your connection.", detail: error.localizedDescription, token: token)
        }
    }
    private func access(_ token: String, kind: String) async -> NativeRPCValue {
        if let cached = accessCache, now() - cached.at < 300_000, cached.token == token { return cached.value }
        let revision = generation
        let value = await BackendGitHubRepositories.read(token: token, host: host, kind: kind, http: http, secrets: secrets() + [token], now: now)
        if value["ok"].bool == true && revision == generation { accessCache = (now(), token, value) }
        return value
    }
    private func check(_ token: String, kind: String) async -> NativeRPCValue {
        async let identity = identify(token)
        async let repositories = access(token, kind: kind)
        let (checked, repos) = await (identity, repositories)
        return checked["ok"].bool == true ? checked.setting("access", repos) : checked
    }
    private func base(installed: Bool) -> NativeRPCValue {
        BackendGitHubRules.object([("connected", .bool(false)), ("source", .null), ("host", .string(host)), ("identity", .null), ("scopes", .array([])), ("scopesReported", .bool(false)), ("ghInstalled", .bool(installed)), ("credentialKind", .null), ("appConfigured", .bool(appConfigured)), ("installUrl", BackendGitHubRules.text(installURL)), ("disconnect", .null), ("pending", .null), ("failure", .null), ("expiredCredentialRemoved", .bool(false)), ("repo", .null), ("branch", .null), ("access", .null)])
    }
    private func connection() async -> NativeRPCValue {
        let installed = await ghInstalled(), initial = base(installed: installed)
        func connected(_ checked: NativeRPCValue, source: String, kind: String, disconnect: String?) -> NativeRPCValue {
            initial.merging(checked.removing("ok")).merging(BackendGitHubRules.object([("connected", .bool(true)), ("source", .string(source)), ("credentialKind", .string(kind)), ("disconnect", BackendGitHubRules.text(disconnect))]))
        }
        if let token = envToken() {
            let checked = await check(token, kind: "oauth")
            if checked["ok"].bool == true { return connected(checked, source: "environment", kind: "oauth", disconnect: nil) }
            return initial.setting("failure", checked.setting("message", .string((checked["message"].string ?? "") + " It came from the GH_TOKEN environment variable.")).setting("action", .null))
        }
        var removed = false
        if let stored = readStored(), let token = stored["token"].string {
            let kind = stored["clientKind"].string ?? "oauth"
            let checked: NativeRPCValue
            if let expiry = stored["expiresAt"].number, now() >= expiry { checked = fail("auth-expired", "The GitHub sign-in this app stored has expired.") }
            else { checked = await check(token, kind: kind) }
            if checked["ok"].bool == true { return connected(checked, source: "device-flow", kind: kind, disconnect: installed ? "Deletes the sign-in this app stored. The GitHub CLI in your terminal keeps its own." : "Deletes the sign-in this app stored.") }
            if checked["kind"].string == "auth-expired" {
                do { try await clearStored(); removed = true }
                catch { return initial.setting("failure", fail("error", "The expired GitHub sign-in could not be removed.", detail: error.localizedDescription, token: token)) }
            } else { return initial.setting("failure", checked) }
        }
        let withRemoval = initial.setting("expiredCredentialRemoved", .bool(removed))
        if installed, let token = await ghToken() {
            let checked = await check(token, kind: "oauth")
            if checked["ok"].bool == true { return connected(checked, source: "gh-cli", kind: "oauth", disconnect: "Signs the GitHub CLI out on this machine, so your terminal is signed out too.").setting("expiredCredentialRemoved", .bool(removed)) }
            return withRemoval.setting("failure", checked)
        }
        let message = !appConfigured ? BackendGitHubAppRegistration.unconfiguredReason : installed ? "Connect here, or run gh auth login in a terminal — either one works." : "Connect here; the GitHub CLI is not needed to sign in."
        return withRemoval.setting("failure", fail("not-authenticated", message, action: installed ? "gh auth login" : nil))
    }
    public func status(cwd: String? = nil, refresh: Bool = false, foldFlowFailure: Bool = false) async -> NativeRPCValue {
        let revision = generation
        var value: NativeRPCValue
        if !refresh, let cached, now() - cached.at < 60_000 { value = cached.value }
        else {
            value = await connection()
            if value["connected"].bool == true, value["access"]["ok"].bool != false, revision == generation { cached = (now(), value) }
        }
        if let cwd, !cwd.isEmpty {
            async let repo = resolveRepo(cwd); async let branch = resolveBranch(cwd)
            let (r, b) = await (repo, branch); value = value.setting("repo", r).setting("branch", b)
        }
        value = value.setting("pending", flow?.prompt ?? .null)
        if foldFlowFailure, value["connected"].bool != true, let lastFlowFailure { value = value.setting("failure", lastFlowFailure) }
        return value
    }
    private static let formCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
    static func form(_ fields: [(String, String)]) -> String { fields.map { ($0.0.addingPercentEncoding(withAllowedCharacters: formCharacters) ?? "") + "=" + ($0.1.addingPercentEncoding(withAllowedCharacters: formCharacters) ?? "") }.joined(separator: "&") }
    private static let formHeaders = ["Accept": "application/json", "Content-Type": "application/x-www-form-urlencoded", "User-Agent": "terminaldeck"]
    public func connect() async -> NativeRPCValue {
        if let flow { return flow.prompt }
        guard let clientID else { return fail("auth-unavailable", BackendGitHubAppRegistration.unconfiguredReason) }
        let response: BackendGitHubHTTPResponse
        do { response = try await http.fetch(url: "https://\(host)/login/device/code", method: "POST", headers: Self.formHeaders, body: Self.form([("client_id", clientID)]), timeoutMilliseconds: 15_000) }
        catch { return BackendGitHubRepositories.timedOut(error) ? fail("timeout", "GitHub did not answer in time.") : fail("network-down", "Could not reach \(host) — check your connection.", detail: error.localizedDescription) }
        let parsed = try? NativeRPCValue.parseJSON(Data(response.body.utf8))
        guard response.ok, let device = parsed?["device_code"].string, !device.isEmpty, let user = parsed?["user_code"].string, !user.isEmpty else { return fail("auth-unavailable", "GitHub would not start a sign-in for GitHub App client \(clientID). Check the app still exists and has Enable Device Flow ticked.", detail: response.body) }
        if let flow { return flow.prompt } // Collapse overlapping Connect calls.
        let interval = max(1, parsed?["interval"].number ?? 5) * 1000
        let prompt = BackendGitHubRules.object([("userCode", .string(user)), ("verificationUri", .string(parsed?["verification_uri"].string ?? "https://\(host)/login/device")), ("expiresAt", .number(now() + max(60, parsed?["expires_in"].number ?? 900) * 1000)), ("installUrl", BackendGitHubRules.text(installURL))])
        let id = UUID()
        let task = Task { await self.poll(device: device, prompt: prompt, clientID: clientID, interval: interval, id: id) }
        flow = Flow(id: id, prompt: prompt, task: task)
        return prompt
    }
    private func poll(device: String, prompt: NativeRPCValue, clientID: String, interval: Double, id: UUID) async {
        defer { if flow?.id == id { flow = nil } }
        var wait = interval
        while !Task.isCancelled, flow?.id == id {
            do { try await sleep(wait) } catch { return }
            guard !Task.isCancelled, flow?.id == id else { return }
            if now() >= (prompt["expiresAt"].number ?? 0) { lastFlowFailure = codeExpired(); return }
            let response: BackendGitHubHTTPResponse
            do {
                response = try await http.fetch(url: "https://\(host)/login/oauth/access_token", method: "POST", headers: Self.formHeaders, body: Self.form([("client_id", clientID), ("device_code", device), ("grant_type", "urn:ietf:params:oauth:grant-type:device_code")]), timeoutMilliseconds: 0)
            } catch {
                guard !Task.isCancelled, flow?.id == id else { return }
                lastFlowFailure = fail("network-down", "Could not reach \(host) — check your connection.", detail: error.localizedDescription); continue
            }
            guard !Task.isCancelled, flow?.id == id else { return }
            let parsed = try? NativeRPCValue.parseJSON(Data(response.body.utf8))
            if response.ok, let token = parsed?["access_token"].string, !token.isEmpty {
                let checked = await identify(token)
                guard !Task.isCancelled, flow?.id == id else { return }
                guard checked["ok"].bool == true else { lastFlowFailure = checked; return }
                let expires = parsed?["expires_in"].number
                let credential = BackendGitHubRules.object([("version", .number(1)), ("host", .string(host)), ("token", .string(token)), ("login", checked["identity"]["login"]), ("scopes", checked["scopes"]), ("obtainedAt", .number(now())), ("expiresAt", expires.flatMap { $0 > 0 ? .number(now() + $0 * 1000) : nil } ?? .null), ("clientKind", .string("github-app"))])
                do { try await writeStored(credential); lastFlowFailure = nil }
                catch { lastFlowFailure = fail("not-authenticated", "GitHub signed you in, but this Mac would not store the credential safely, so it was not saved.", detail: error.localizedDescription, token: token) }
                return
            }
            switch parsed?["error"].string {
            case "authorization_pending": continue
            case "slow_down": wait = max(1, parsed?["interval"].number ?? ceil(wait / 1000) + 5) * 1000
            case "expired_token": lastFlowFailure = codeExpired(); return
            case "access_denied": lastFlowFailure = fail("auth-declined", "The sign-in was refused on GitHub. Nothing was changed."); return
            default: lastFlowFailure = fail("error", parsed?["error_description"].string ?? "GitHub refused the sign-in and did not say why.", detail: response.body); return
            }
        }
    }
    private func codeExpired() -> NativeRPCValue { fail("auth-code-expired", "The sign-in code expired before it was entered. Press Connect to get a new one.") }
    public func awaitConnect(cwd: String? = nil) async -> NativeRPCValue { if let flow { await flow.task.value }; return await status(cwd: cwd, refresh: true, foldFlowFailure: true) }
    public func cancelConnect(cwd: String? = nil) async -> NativeRPCValue { flow?.task.cancel(); flow = nil; return await status(cwd: cwd, refresh: true, foldFlowFailure: true) }
    /// Lifecycle stop cancels only in-memory work and never signs the user out.
    public func shutdown() { flow?.task.cancel(); flow = nil; generation += 1; cached = nil; accessCache = nil }
    public func flowFailure() -> NativeRPCValue? { lastFlowFailure }
    public func disconnect(cwd: String? = nil) async -> NativeRPCValue {
        let before = await status(refresh: true)
        if before["source"].string == "device-flow" {
            do { try await clearStored() }
            catch { return (await status(cwd: cwd, refresh: true)).setting("failure", fail("error", "The stored GitHub sign-in could not be deleted.", detail: error.localizedDescription)) }
        } else if before["source"].string == "gh-cli" {
            var args = ["auth", "logout", "--hostname", host]
            if let login = before["identity"]["login"].string { args += ["--user", login] }
            do {
                let result = try await gh(args)
                guard result.ok else { throw NativeRPCError(code: "gh", message: result.stderr + "\n" + result.stdout) }
            } catch { return (await status(cwd: cwd, refresh: true)).setting("failure", fail("error", "The GitHub CLI would not sign out. Run gh auth logout in a terminal to finish it.", detail: error.localizedDescription, action: "gh auth logout")) }
        }
        generation += 1; cached = nil; accessCache = nil; ghPresent = nil; lastFlowFailure = nil
        if before["source"].string != "device-flow" { await changed() }
        return await status(cwd: cwd, refresh: true)
    }
}
