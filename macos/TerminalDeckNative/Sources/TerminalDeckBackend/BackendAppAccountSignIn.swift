import Foundation
import TerminalDeckNativeCore

public struct BackendAppAccountAuthAnswer: Sendable, Equatable {
    public let loggedIn: Bool
    public let account: String?
    public let plan: String?
}
public struct BackendAppAccountSignInReport: Sendable, Equatable {
    public let profileId: String
    public let provider: String
    public let state: String
    public let account: String?
    public let plan: String?
    public let detail: String
    public let command: String
    public let checkedAt: Double
    public var wireValue: NativeRPCValue {
        .object([.init("profileId", .string(profileId)), .init("provider", .string(provider)), .init("state", .string(state)),
            .init("account", account.map(NativeRPCValue.string) ?? .null), .init("plan", plan.map(NativeRPCValue.string) ?? .null),
            .init("detail", .string(detail)), .init("command", .string(command)), .init("checkedAt", .number(checkedAt))])
    }
}
public struct BackendAppAccountGeminiSignIn: Sendable, Equatable {
    public let signedIn: Bool
    public let account: String?
    public let method: String?
    public let evidence: String?
    public var description: String {
        if !signedIn { return "Not signed in. Press Sign in and Gemini opens in a session, where it asks which Google account to use." }
        if let account, let method { return "Signed in as \(account) · \(method)" }
        if let account { return "Signed in as \(account)" }
        if let method { return "Signed in with \(method)" }
        return "Signed in."
    }
}
public enum BackendAppAccountSignInParsing {
    public static let timeoutMilliseconds = 10_000
    public static let cacheMilliseconds = 30_000
    static func text(_ value: NativeRPCValue) -> String? {
        value.string.flatMap { value in let clean = value.trimmingCharacters(in: .whitespacesAndNewlines); return clean.isEmpty ? nil : clean }
    }
    public static func accountEnvironment(_ profile: BackendAccountProfile, provider: String, inherited: [String: String], path: String,
                                          vaultVariables: Set<String>, overrides: [String: String] = [:], shimDirectory: String? = nil) -> [String: String] {
        // An outer Claude Code's own markers (CLAUDE_CODE_*, CLAUDECODE …) never reach a probe:
        // with them a status check runs as that session's child or signs in as its account
        // (walk 4: a leaked launcher env wrote the wrong account into a fresh config).
        var env = BackendSessionEnvironment.stripInherited(inherited)
        for key in vaultVariables { env[key] = nil }
        env["PATH"] = path
        // sessionEnv: the machine's own install exports nothing; an account
        // exports its agent's own variable only (accountEnv).
        if !profile.system { env.merge(BackendAccountStrategies.accountEnv(provider: provider, account: (profile.provider, profile.configDir))) { _, new in new } }
        env.merge(overrides) { _, new in new }
        if let shimDirectory { env["PATH"] = ([shimDirectory] + path.split(separator: ":").map(String.init).filter { $0 != shimDirectory }).joined(separator: ":") }
        return env
    }
    public static func unsupportedReason(_ provider: String) -> String {
        BackendAccountStrategies.unsupportedReason(provider)
    }
    public static func claude(_ raw: String) -> BackendAppAccountAuthAnswer? {
        guard let first = raw.firstIndex(of: "{"), let last = raw.lastIndex(of: "}"), last > first,
              let value = try? NativeRPCValue.parseJSON(Data(raw[first...last].utf8)), value.fields != nil,
              let loggedIn = value["loggedIn"].bool else { return nil }
        return .init(loggedIn: loggedIn, account: text(value["email"]) ?? text(value["orgName"]), plan: text(value["subscriptionType"]) ?? text(value["authMethod"]))
    }
    public static func codex(_ raw: String) -> BackendAppAccountAuthAnswer? {
        for line in raw.components(separatedBy: "\n") {
            let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("Not logged in") { return .init(loggedIn: false, account: nil, plan: nil) }
            if line.hasPrefix("Logged in using") {
                let plan = String(line.dropFirst("Logged in using".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return .init(loggedIn: true, account: nil, plan: plan.isEmpty ? nil : plan)
            }
        }
        return nil
    }
    public static func describe(_ answer: BackendAppAccountAuthAnswer, signInCommand: String? = nil) -> String {
        if !answer.loggedIn {
            return signInCommand.map { "Not signed in. Open a session with this account to log in, or run `\($0)`." }
                ?? "Not signed in. Open a session with this account to log in."
        }
        if let account = answer.account, let plan = answer.plan { return "Signed in as \(account) · \(plan)" }
        if let account = answer.account { return "Signed in as \(account)" }
        if let plan = answer.plan { return "Signed in using \(plan)" }
        return "Signed in."
    }
    public static func report(profileID: String, provider: String, command: String, probe: BackendAppSessionCommandResult,
                              now: Double = Date().timeIntervalSince1970 * 1000) -> BackendAppAccountSignInReport {
        let raw = probe.stdout + "\n" + probe.stderr
        let answer = BackendAccountStrategies.strategy(provider)?.statusFormat == .codexText ? codex(raw) : claude(raw)
        let state: String, detail: String
        if let answer {
            return .init(profileId: profileID, provider: provider, state: answer.loggedIn ? "signed-in" : "signed-out", account: answer.account, plan: answer.plan,
                detail: describe(answer, signInCommand: BackendAccountStrategies.signInCommandLine(provider, bin: BackendAccountStrategies.bin(provider))), command: command, checkedAt: now)
        } else if probe.killed {
            state = "unknown"; detail = "The agent did not answer within 10 seconds, so this account's sign-in state is unread."
        } else {
            state = "unknown"
            let said = (probe.stderr + "\n" + probe.stdout).components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            detail = said.map { "Could not read this account's sign-in state. \(command) said: \(String(decoding: Array($0.utf16.prefix(160)), as: UTF16.self))" }
                ?? "Could not read this account's sign-in state — \(command) answered nothing."
        }
        return .init(profileId: profileID, provider: provider, state: state, account: nil, plan: nil, detail: detail, command: command, checkedAt: now)
    }
    public static func geminiDirectory(environment: [String: String], home: String) -> String {
        let configured = environment["GEMINI_CLI_HOME"] ?? ""
        return URL(fileURLWithPath: configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? home : configured).appendingPathComponent(".gemini").path
    }
    public static func gemini(environment: [String: String], accounts: NativeRPCValue, settings: NativeRPCValue,
                              credentialsFilePresent: Bool, keychainPresent: Bool) -> BackendAppAccountGeminiSignIn {
        let apiKey = ["GEMINI_API_KEY", "GOOGLE_API_KEY"].first { !(environment[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let account = text(accounts["active"]), selected = text(settings["security"]["auth"]["selectedType"])
        let labels = ["oauth-personal": "Google account", "gemini-api-key": "Gemini API key", "vertex-ai": "Vertex AI", "cloud-shell": "Cloud Shell"]
        let method = apiKey.map { "an API key in \($0)" } ?? selected.map { labels[$0] ?? $0 } ?? (keychainPresent || credentialsFilePresent ? "Google account" : nil)
        let evidence = keychainPresent ? "keychain" : credentialsFilePresent ? "oauth_creds.json" : apiKey ?? (account != nil ? "google_accounts.json" : selected != nil ? "settings.json" : nil)
        return .init(signedIn: keychainPresent || credentialsFilePresent || apiKey != nil || account != nil, account: account, method: method, evidence: evidence)
    }
}

/// Small read/probe seam: production delegates to the existing single account
/// owners; tests supply metadata and fake process evidence without a vault.
public protocol BackendAppAccountSignInDependencies: Sendable {
    var configuration: BackendAccountConfiguration { get }
    func find(_ id: String) async throws -> BackendAccountProfile?
    func managed(_ profile: BackendAccountProfile) async -> Bool
    func summaries() async throws -> [BackendAccountVaultSummary]
    /// TS runtime.ts `usable()`: this process can answer the agent's logins (the vault opens).
    func vaultUsable() async -> Bool
    func loginPath() async throws -> String
    func binary(_ provider: String, path: String, refresh: Bool) async -> BackendNativeProviders.Binary
    func probeEnvironment(_ profile: BackendAccountProfile, provider: String, path: String) async throws -> [String: String]
    func recheck(_ profile: BackendAccountProfile) async throws
    func readJSON(_ file: URL) -> NativeRPCValue
    func nonEmptyFile(_ file: URL) -> Bool
}
extension BackendAppAccountSignInDependencies {
    /// Conformers that predate the vault rule answer from `summaries()`.
    public func vaultUsable() async -> Bool { (try? await summaries()) != nil }
}
public struct BackendAppAccountSignInNativeDependencies: BackendAppAccountSignInDependencies {
    private let accounts: BackendAccountLaunchAdapter
    private let providers: BackendNativeProviders
    public let configuration: BackendAccountConfiguration
    public init(accounts: BackendAccountLaunchAdapter, providers: BackendNativeProviders, configuration: BackendAccountConfiguration) {
        self.accounts = accounts; self.providers = providers; self.configuration = configuration
    }
    public func find(_ id: String) async throws -> BackendAccountProfile? { try await accounts.profiles.find(id) }
    public func managed(_ profile: BackendAccountProfile) async -> Bool { await accounts.profiles.managed(profile) }
    public func summaries() async throws -> [BackendAccountVaultSummary] { try await accounts.vault.summaries() }
    public func vaultUsable() async -> Bool { await accounts.vault.openState() == .ready }
    public func loginPath() async throws -> String { try await providers.loginPath() }
    public func binary(_ provider: String, path: String, refresh: Bool) async -> BackendNativeProviders.Binary { await providers.resolveBinary(provider, path: path, refresh: refresh) }
    public func recheck(_ profile: BackendAccountProfile) async throws { try await accounts.codex.capture(profile) }
    public func readJSON(_ file: URL) -> NativeRPCValue {
        guard let data = try? Data(contentsOf: file), let value = try? NativeRPCValue.parseJSON(data) else { return .null }; return value
    }
    public func nonEmptyFile(_ file: URL) -> Bool { (((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value ?? 0) > 0 }
    public func probeEnvironment(_ profile: BackendAccountProfile, provider: String, path: String) async throws -> [String: String] {
        var overrides: [String: String] = [:], shim: String?
        if !profile.system, provider == profile.provider, provider == "claude", await accounts.profiles.managed(profile) {
            overrides = try await accounts.broker.allocateAccount(profile).environment; shim = accounts.broker.shimDirectory
        } else if !profile.system, provider == profile.provider, provider == "codex", await accounts.profiles.managed(profile) { try await accounts.codex.settle(profile) }
        return BackendAppAccountSignInParsing.accountEnvironment(profile, provider: provider, inherited: configuration.inheritedEnvironment,
            path: path, vaultVariables: configuration.vaultVariables, overrides: overrides, shimDirectory: shim)
    }
}

/// Account probing uses the existing vault/profile/provider owners. Tokens
/// never cross this facade; Gemini's security call omits -w deliberately.
public actor BackendAppAccountSignInService {
    public static let channels: Set<String> = ["profiles:signin", "profiles:signout"]
    private let dependencies: any BackendAppAccountSignInDependencies
    private let clock: any BackendAppSessionClock
    private let configuration: BackendAccountConfiguration
    private let executor: any BackendAppSessionCommandExecuting
    private let authorize: @Sendable (NativeRPCContext) throws -> Void
    private let authorizeRead: @Sendable (NativeRPCContext) throws -> Void
    private var cache: [String: BackendAppAccountSignInReport] = [:]
    public init(accounts: BackendAccountLaunchAdapter, providers: BackendNativeProviders, configuration: BackendAccountConfiguration,
                executor: any BackendAppSessionCommandExecuting = BackendAppSessionCommandExecutor(),
                clock: any BackendAppSessionClock = BackendAppSessionSystemClock(),
                authorizeMetadata: @escaping @Sendable (NativeRPCContext) throws -> Void,
                authorizeMutation: @escaping @Sendable (NativeRPCContext) throws -> Void) {
        self.configuration = configuration; self.executor = executor; self.clock = clock
        dependencies = BackendAppAccountSignInNativeDependencies(accounts: accounts, providers: providers, configuration: configuration)
        authorize = authorizeMutation; authorizeRead = authorizeMetadata
    }
    public init(dependencies: any BackendAppAccountSignInDependencies,
                executor: any BackendAppSessionCommandExecuting, clock: any BackendAppSessionClock,
                authorizeMetadata: @escaping @Sendable (NativeRPCContext) throws -> Void,
                authorizeMutation: @escaping @Sendable (NativeRPCContext) throws -> Void) {
        self.dependencies = dependencies; configuration = dependencies.configuration; self.executor = executor; self.clock = clock
        authorize = authorizeMutation; authorizeRead = authorizeMetadata
    }
    public func resetCache() { cache.removeAll() }
    private func unknown(_ profile: BackendAccountProfile, provider: String, detail: String, command: String = "") -> BackendAppAccountSignInReport {
        .init(profileId: profile.id, provider: provider, state: "unknown", account: nil, plan: nil, detail: detail, command: command, checkedAt: clock.now().timeIntervalSince1970 * 1000)
    }
    private func readJSON(_ file: URL) -> NativeRPCValue { dependencies.readJSON(file) }
    /// TS profiles-signin.ts `keptSignIn` (:439) over runtime.ts `vaultSignedIn`: answered from the vault, never
    /// by running the agent; nil when the vault cannot say (the agent's own answer is needed).
    private func kept(_ profile: BackendAccountProfile, provider: String, keptBy: BackendSessionSwitchKeptLogin.KeptBy, usable: Bool) async throws -> BackendAppAccountSignInReport? {
        guard provider == "claude", profile.provider == "claude", usable else { return nil }
        let summary = try await dependencies.summaries().first { $0.accountId == profile.id }
        guard let held = BackendSessionSwitchKeptLogin.signedIn(profile, kept: keptBy, held: summary?.held == true) else { return nil }
        let now = clock.now().timeIntervalSince1970 * 1000
        guard held else {
            return .init(profileId: profile.id, provider: provider, state: "signed-out", account: nil, plan: nil,
                detail: "Not signed in. Sign in to it here, and this app keeps the login.", command: "", checkedAt: now)
        }
        let oauth = readJSON(URL(fileURLWithPath: profile.configDir).appendingPathComponent(".claude.json"))["oauthAccount"]
        let answer = BackendAppAccountAuthAnswer(loggedIn: true,
            account: BackendAppAccountSignInParsing.text(oauth["emailAddress"]) ?? BackendAppAccountSignInParsing.text(oauth["organizationName"]), plan: summary?.plan)
        return .init(profileId: profile.id, provider: provider, state: "signed-in", account: answer.account, plan: answer.plan,
            detail: BackendAppAccountSignInParsing.describe(answer), command: "", checkedAt: now)
    }
    public func gemini() async -> BackendAppAccountGeminiSignIn {
        let env = configuration.inheritedEnvironment, directory = URL(fileURLWithPath: BackendAppAccountSignInParsing.geminiDirectory(environment: env, home: configuration.homeDirectory.path))
        let credentials = dependencies.nonEmptyFile(directory.appendingPathComponent("oauth_creds.json"))
        let keychain = await executor.run("/usr/bin/security", arguments: ["find-generic-password", "-s", "gemini-cli-oauth", "-a", "main-account"], environment: env, cwd: configuration.homeDirectory.path, timeoutMilliseconds: 3_000, maximumBytes: 256 * 1024)
        return BackendAppAccountSignInParsing.gemini(environment: env, accounts: readJSON(directory.appendingPathComponent("google_accounts.json")), settings: readJSON(directory.appendingPathComponent("settings.json")), credentialsFilePresent: credentials, keychainPresent: keychain.ok)
    }
    public func read(_ profile: BackendAccountProfile, provider requested: String? = nil, refresh: Bool = false) async -> BackendAppAccountSignInReport {
        let provider = requested ?? profile.provider
        guard ["claude", "codex", "gemini"].contains(provider) else {
            return .init(profileId: profile.id, provider: provider, state: "unsupported", account: nil, plan: nil, detail: BackendAppAccountSignInParsing.unsupportedReason(provider), command: "", checkedAt: clock.now().timeIntervalSince1970 * 1000)
        }
        do {
            let managed = await dependencies.managed(profile)
            let usable = await dependencies.vaultUsable()
            let keptBy = BackendSessionSwitchKeptLogin.keptBy(profile, managed: managed, usable: usable)
            if let held = try await kept(profile, provider: provider, keptBy: keptBy, usable: usable) { return held }
            // TS readSignIn: an account the app keeps whose store is not open here is never probed.
            if let unavailable = BackendSessionSwitchKeptLogin.unavailable(keptBy) { return unknown(profile, provider: provider, detail: unavailable) }
            if profile.promised, !profile.system, !(await dependencies.managed(profile)) { return unknown(profile, provider: provider, detail: "The app-kept login is unavailable because its account directory is outside this app's managed accounts.") }
            let key = "\(provider):\(profile.id):\(profile.configDir)", now = clock.now().timeIntervalSince1970 * 1000
            if !refresh, let held = cache[key], now - held.checkedAt < Double(BackendAppAccountSignInParsing.cacheMilliseconds) { return held }
            if provider == "gemini" {
                let local = await gemini()
                let result = BackendAppAccountSignInReport(profileId: profile.id, provider: provider, state: local.signedIn ? "signed-in" : "signed-out", account: local.account, plan: local.method, detail: local.description, command: "", checkedAt: now)
                cache[key] = result; return result
            }
            guard let args = BackendAccountStrategies.strategy(provider)?.statusArgs else {
                return .init(profileId: profile.id, provider: provider, state: "unsupported", account: nil, plan: nil, detail: BackendAppAccountSignInParsing.unsupportedReason(provider), command: "", checkedAt: now)
            }
            let path = try await dependencies.loginPath(), binary = await dependencies.binary(provider, path: path, refresh: refresh)
            let command = BackendAccountStrategies.bin(provider) + " " + args.joined(separator: " ")
            guard let runnable = binary.runnable else {
                let result = unknown(profile, provider: provider, detail: Self.binaryProblem(binary), command: command); cache[key] = result; return result
            }
            let env = try await probeEnvironment(profile, provider: provider, path: path)
            let probe = await executor.run(runnable, arguments: args, environment: env, cwd: configuration.homeDirectory.path, timeoutMilliseconds: 10_000, maximumBytes: 256 * 1024)
            let result = BackendAppAccountSignInParsing.report(profileID: profile.id, provider: provider, command: command, probe: probe, now: clock.now().timeIntervalSince1970 * 1000)
            cache[key] = result; return result
        } catch { return unknown(profile, provider: provider, detail: error.localizedDescription) }
    }
    public nonisolated static func binaryProblem(_ binary: BackendNativeProviders.Binary) -> String {
        let label = BackendAccountProfile.providerLabel(binary.id)
        let installs = ["claude": "npm install -g @anthropic-ai/claude-code", "codex": "npm install -g @openai/codex", "gemini": "npm install -g @google/gemini-cli"]
        let install = installs[binary.id]
        if !binary.broken { return install.map { "\(label) is not installed. Install it with `\($0)`, then check again." } ?? "\(label) is not installed on this machine." }
        let whereText = binary.onPath.map { " at \($0)" } ?? ""
        return install.map { "\(label) is installed\(whereText) but will not start. Reinstalling usually fixes it: `\($0)`." } ?? "\(label) is installed\(whereText) but will not start."
    }
    private func probeEnvironment(_ profile: BackendAccountProfile, provider: String, path: String) async throws -> [String: String] {
        try await dependencies.probeEnvironment(profile, provider: provider, path: path)
    }
    public func signOut(_ id: String) async -> NativeRPCValue {
        func result(_ ok: Bool, _ message: String) -> NativeRPCValue { .object([.init("ok", .bool(ok)), .init("message", .string(message)), .init("session", .null)]) }
        do {
            guard let profile = try await dependencies.find(id) else { return result(false, "There is no such login on this computer any more.") }
            let provider = profile.provider, label = BackendAccountProfile.providerLabel(provider)
            guard let signOutArgs = BackendAccountStrategies.strategy(provider)?.signOutArgs else { return result(false, BackendAccountStrategies.strategy(provider)?.signOutNote ?? "This agent has no command to sign it out from here.") }
            let path = try await dependencies.loginPath(), binary = await dependencies.binary(provider, path: path, refresh: false)
            guard let runnable = binary.runnable else { return result(false, Self.binaryProblem(binary)) }
            let env = try await probeEnvironment(profile, provider: provider, path: path)
            _ = await executor.run(runnable, arguments: signOutArgs, environment: env, cwd: configuration.homeDirectory.path, timeoutMilliseconds: 10_000, maximumBytes: 256 * 1024)
            if provider == "codex", await dependencies.managed(profile) { try await dependencies.recheck(profile) }
            resetCache(); let after = await read(profile, refresh: true)
            if after.state == "signed-out" { return result(true, "\(label) is signed out on this computer.") }
            return result(false, after.state == "signed-in" ? "\(label) is still signed in on this computer." : "\(label) could not be confirmed signed out. \(after.detail)")
        } catch { return result(false, error.localizedDescription) }
    }
    public func invoke(_ channel: String, args: [NativeRPCValue], context: NativeRPCContext) async throws -> NativeRPCValue {
        let id = args.first?.string ?? ""
        switch channel {
        case "profiles:signin":
            try authorizeRead(context)
            guard !id.isEmpty else { throw BackendAppSessionError("a profile id is required") }
            guard let profile = try await dependencies.find(id) else { throw BackendAppSessionError("no profile with id \(id)") }
            let options = args.count > 1 ? args[1] : .null
            let provider = options["provider"].string.flatMap { ["claude", "codex", "gemini", "shell"].contains($0) ? $0 : nil }
            return await read(profile, provider: provider, refresh: options["refresh"].bool == true).wireValue
        case "profiles:signout":
            try authorize(context)
            guard !id.isEmpty else { return .object([.init("ok", .bool(false)), .init("message", .string("That is not an account.")), .init("session", .null)]) }
            return await signOut(id)
        default: throw BackendAppSessionError("The native sign-in facade does not handle this channel.")
        }
    }
}
