import Foundation
import TerminalDeckNativeCore

public actor BackendGitHubService {
    private let environment: [String: String], tools: any BackendGitHubToolRunning
    public nonisolated let cache: BackendGitHubCache
    private let now: @Sendable () -> Double
    private var auth: BackendGitHubAuthenticator?
    public init(environment: [String: String], tools: any BackendGitHubToolRunning, cache: BackendGitHubCache = BackendGitHubCache(), now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.environment = environment; self.tools = tools; self.cache = cache; self.now = now
    }
    public func useAuthenticator(_ auth: BackendGitHubAuthenticator) { self.auth = auth }
    private func run(_ tool: String, _ arguments: [String], cwd: String? = nil) async throws -> BackendGitOutcome {
        var env = BackendGitHubAuthenticator.toolEnvironment(environment, token: await auth?.toolToken())
        env["GIT_TERMINAL_PROMPT"] = "0"
        // execFile's old buffer was 8 MB per stdout/stderr stream. The shared
        // native pipe owner bounds both together, so its bound is 16 MB.
        return try await tools.run(tool: tool, arguments: arguments, cwd: cwd, environment: env, timeoutMilliseconds: tool == "git" ? 5_000 : 15_000, maximumBytes: 16 * 1024 * 1024)
    }
    private func failure(_ kind: String, _ message: String, action: String? = nil, detail: String = "") async -> NativeRPCValue {
        BackendGitHubRules.failure(kind, message, action, detail: detail, secrets: await auth?.secrets() ?? [])
    }
    public func resolveRepo(_ cwd: String) async -> NativeRPCValue {
        guard cwd.hasPrefix("/") else { return await failure("error", "Project path must be absolute.", detail: cwd) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory) else { return await failure("no-such-folder", "This project folder no longer exists.") }
        guard isDirectory.boolValue else { return await failure("no-such-folder", "That project path is not a folder.") }
        do {
            let result = try await run("git", ["config", "--local", "--get-regexp", #"^remote\..*\.(url|gh-resolved)$"#], cwd: cwd)
            if !result.ok {
                if result.exitCode == 1 && result.stderr.isEmpty { return await failure("no-remote", "This repository has no remotes yet.", action: "git remote add origin <url>") }
                if result.missing { return await failure("git-missing", "git is not installed, or not on your login PATH.") }
                if BackendGitHubRules.matches(result.stderr, "--local can only be used inside a git repository|not a git repository") { return await failure("not-a-repo", BackendGitHubRules.notARepo, detail: result.stderr) }
                return BackendGitHubRules.classify(result, secrets: await auth?.secrets() ?? [])
            }
            let entries = BackendGitHubRules.parseRemoteConfig(result.stdout)
            guard !entries.isEmpty else { return await failure("no-remote", "This repository has no remotes yet.", action: "git remote add origin <url>") }
            let extra = (environment["GH_HOST"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let repo = BackendGitHubRules.pickRepo(entries, hosts: extra.isEmpty ? ["github.com"] : ["github.com", extra]) { return repo }
            return await failure("no-github-remote", "None of this repository’s remotes point at GitHub.", action: "git remote add github <url>", detail: entries.map { "\($0.name) → \(BackendGitHubRules.redactURL($0.url))" }.joined(separator: ", "))
        } catch { return BackendGitHubRules.classify(text: error.localizedDescription, secrets: await auth?.secrets() ?? []) }
    }
    public func readBranch(_ cwd: String) async -> NativeRPCValue {
        guard cwd.hasPrefix("/") else { return .null }
        do {
            let result = try await run("git", ["symbolic-ref", "--quiet", "--short", "HEAD"], cwd: cwd)
            let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.ok && !name.isEmpty { return BackendGitHubRules.object([("name", .string(name)), ("detached", .bool(false)), ("head", .null)]) }
            if !result.ok && (!result.stderr.isEmpty || result.missing) { return .null }
        } catch { return .null }
        guard let result = try? await run("git", ["rev-parse", "--short", "HEAD"], cwd: cwd), result.ok else { return .null }
        let head = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return head.isEmpty ? .null : BackendGitHubRules.object([("name", .null), ("detached", .bool(true)), ("head", .string(head))])
    }
    public func fetch(repo: NativeRPCValue, limit: Int, pulls: Bool) async -> NativeRPCValue {
        do {
            let result = try await run("gh", BackendGitHubRules.listArgs(repo: repo, limit: limit, pulls: pulls))
            guard result.ok else { return BackendGitHubRules.classify(result, secrets: await auth?.secrets() ?? []) }
            let parsed: NativeRPCValue
            do { parsed = try NativeRPCValue.parseJSON(Data(result.stdout.utf8)) }
            catch { return await failure("error", "gh returned output that could not be parsed.", detail: error.localizedDescription) }
            guard let rows = parsed.elements else { return await failure("error", pulls ? "gh returned an unexpected pull-request payload." : "gh returned an unexpected issue payload.") }
            return BackendGitHubRules.object([("ok", .bool(true)), ("value", .array(rows.compactMap { BackendGitHubRules.mapRow($0, pulls: pulls) }))])
        } catch { return BackendGitHubRules.classify(text: error.localizedDescription, secrets: await auth?.secrets() ?? []) }
    }
    public func overview(cwd: String, options: NativeRPCValue = .missing, refresh: Bool = false) async -> NativeRPCValue {
        let refresh = refresh || options["refresh"].bool == true, limit = BackendGitHubRules.clampLimit(options["limit"])
        do {
            let repo = try await cache.through("repo " + cwd, refresh: refresh, load: { await self.resolveRepo(cwd) }, ttl: { $0.has("ok") ? 15_000 : 60_000 })
            if repo.has("ok") { return repo }
            async let pulls = cache.through(BackendGitHubRules.sectionKey("pulls", repo: repo, limit: limit), refresh: refresh, load: { await self.fetch(repo: repo, limit: limit, pulls: true) }, ttl: { $0["ok"].bool == true ? 60_000 : 15_000 })
            async let issues = cache.through(BackendGitHubRules.sectionKey("issues", repo: repo, limit: limit), refresh: refresh, load: { await self.fetch(repo: repo, limit: limit, pulls: false) }, ttl: { $0["ok"].bool == true ? 60_000 : 15_000 })
            let (p, i) = try await (pulls, issues)
            return BackendGitHubRules.object([("ok", .bool(true)), ("cwd", .string(cwd)), ("repo", repo), ("pulls", p), ("issues", i), ("limit", .number(Double(limit))), ("fetchedAt", .number(now()))])
        } catch { return await failure("error", "The GitHub CLI failed.", detail: error.localizedDescription) }
    }
}

public enum BackendGitHubChannels {
    public static let channels = ["github:overview", "github:repo", "github:refresh", "github:auth-status", "github:auth-connect", "github:auth-await", "github:auth-cancel", "github:auth-disconnect"]
    /// Integration supplies one authenticator, also used by git credential and
    /// remote-host adapters. Clear-cache is the original send channel.
    public static func register(registry: NativeChannelRegistry, ownerID: String, service: BackendGitHubService, auth: BackendGitHubAuthenticator) async throws -> NativeRPCSubscription {
        await service.useAuthenticator(auth)
        for channel in channels {
            try await registry.register(channel, ownerID: ownerID) { context, args in
                guard context.caller == .nativeApp else { throw NativeRPCError(code: "access-denied", message: "Only the app's own window may use the GitHub panel channels") }
                let raw = context.argument(0, in: args), cwd = raw.string.flatMap { $0.isEmpty ? nil : $0 }
                switch channel {
                case "github:auth-connect": return await auth.connect()
                case "github:auth-status": return await auth.status(cwd: cwd, foldFlowFailure: true)
                case "github:auth-await": return await auth.awaitConnect(cwd: cwd)
                case "github:auth-cancel": return await auth.cancelConnect(cwd: cwd)
                case "github:auth-disconnect": return await auth.disconnect(cwd: cwd)
                default:
                    guard let cwd, cwd.hasPrefix("/") else { return BackendGitHubRules.failure("error", "Project path must be absolute.", detail: raw.string ?? (raw == .missing ? "undefined" : raw.compact)) }
                    if channel == "github:repo" { return await service.resolveRepo(cwd) }
                    return await service.overview(cwd: cwd, options: context.argument(1, in: args), refresh: channel == "github:refresh")
                }
            }
        }
        return try await registry.onSend("github:clear-cache", ownerID: ownerID) { context, _ in
            guard context.caller == .nativeApp else { throw NativeRPCError(code: "access-denied", message: "Only the app's own window may clear GitHub data") }
            await service.cache.clear()
        }
    }
}
