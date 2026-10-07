import Foundation
import TerminalDeckNativeCore

/// Source setup orchestration consumes the SAME provider/hook owners used by
/// session launch. No account/state/cache/lifecycle owner lives in this layer.
public protocol BackendMacAppSetupDetection: Sendable {
    func loginPath() async throws -> String
    func binary(_ id: String, path: String) async throws -> BackendNativeProviders.Binary?
    func credentialFileSize() async throws -> Int?
    func keychainCredentialExists() async throws -> Bool
    func command(_ name: String, arguments: [String], path: String, timeoutMs: Int) async throws -> NativeRPCValue
    func detectCopilot(path: String) async throws -> NativeRPCValue
    func probeBinary(_ name: String, path: String) async throws -> NativeRPCValue
    func hookStatuses() async throws -> [NativeRPCValue]
    /// nil means not listening. Only socketPath may cross to Setup output.
    func hookEndpoint() async throws -> NativeRPCValue?
}
public extension BackendMacAppSetupDetection {
    func detectCopilot(path: String) async throws -> NativeRPCValue { throw NativeRPCError(code: "unavailable", message: "Native GitHub Copilot detection has not been supplied.") }
    func probeBinary(_ name: String, path: String) async throws -> NativeRPCValue { throw NativeRPCError(code: "unavailable", message: "Native lookup evidence has not been supplied.") }
    func hookEndpoint() async throws -> NativeRPCValue? { throw NativeRPCError(code: "unavailable", message: "The native hook listener state has not been supplied.") }
}
public struct BackendMacAppSetupNativeDetection: BackendMacAppSetupDetection, Sendable {
    private let providers: BackendNativeProviders, executor: BackendDevProcessExecutor, hooks: BackendSessionHookInstallation
    private let environment: [String: String], home: String
    private let copilot: @Sendable (String) async throws -> NativeRPCValue
    private let probe: @Sendable (String, String) async throws -> NativeRPCValue
    private let endpoint: @Sendable () async throws -> NativeRPCValue?
    public init(providers: BackendNativeProviders, executor: BackendDevProcessExecutor, hooks: BackendSessionHookInstallation,
                environment: [String: String], home: String,
                copilot: @escaping @Sendable (String) async throws -> NativeRPCValue,
                lookupProbe: @escaping @Sendable (String, String) async throws -> NativeRPCValue,
                endpoint: @escaping @Sendable () async throws -> NativeRPCValue?) {
        self.providers = providers; self.executor = executor; self.hooks = hooks; self.environment = environment; self.home = home
        self.copilot = copilot; probe = lookupProbe; self.endpoint = endpoint
    }
    public func loginPath() async throws -> String { try await providers.loginPath() }
    public func binary(_ id: String, path: String) async throws -> BackendNativeProviders.Binary? { await providers.resolveBinary(id, path: path) }
    public func credentialFileSize() async throws -> Int? {
        let file = URL(fileURLWithPath: home).appendingPathComponent(".claude/.credentials.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
    }
    public func keychainCredentialExists() async throws -> Bool {
        let result = try await executor.run(command: "/usr/bin/security", arguments: ["find-generic-password", "-s", "Claude Code-credentials"], environment: environment, cwd: home, timeoutMilliseconds: 3000, maximumBytes: 256 * 1024)
        return result.ok
    }
    public func command(_ name: String, arguments: [String], path: String, timeoutMs: Int) async throws -> NativeRPCValue {
        guard ["which", "git", "gh"].contains(name), arguments == ["git"] || arguments == ["gh"] || arguments == ["--version"] else { throw NativeRPCError.invalidArguments("Only the native prerequisite lookup/version probes are accepted.") }
        let executable = name == "which" ? "/usr/bin/which" : BackendNativeProviders.lookup(name, path: path)
        guard let executable else { return .object([.init("ok", .bool(false)), .init("stdout", .string(""))]) }
        var env = environment; env["PATH"] = path
        let result = try await executor.run(command: executable, arguments: arguments, environment: env, cwd: home, timeoutMilliseconds: timeoutMs, maximumBytes: 256 * 1024)
        return .object([.init("ok", .bool(result.ok)), .init("stdout", .string(result.stdout))])
    }
    public func detectCopilot(path: String) async throws -> NativeRPCValue { try await copilot(path) }
    public func probeBinary(_ name: String, path: String) async throws -> NativeRPCValue { try await probe(name, path) }
    public func hookStatuses() async throws -> [NativeRPCValue] { await hooks.allStatus().map(\.wireValue) }
    public func hookEndpoint() async throws -> NativeRPCValue? { try await endpoint() }
}
public enum BackendMacAppSetupPrerequisites {
    private static func o(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(pairs.map { .init($0.0, $0.1) }) }
    public static func binaryProblem(_ binary: BackendNativeProviders.Binary?, agent: CodingAIAgent) -> String? {
        if binary?.runnable != nil { return nil }
        if binary?.broken != true { return agent.install.map { "\(agent.label) is not installed. Install it with `\($0)`, then check again." } ?? "\(agent.label) is not installed on this machine." }
        let whereItIs = binary?.onPath.map { " at \($0)" } ?? ""
        return agent.install.map { "\(agent.label) is installed\(whereItIs) but will not start. Reinstalling usually fixes it: `\($0)`." } ?? "\(agent.label) is installed\(whereItIs) but will not start."
    }
    public static func binaryNote(_ binary: BackendNativeProviders.Binary, agent: CodingAIAgent) -> String? {
        guard let runnable = binary.runnable, binary.usedAlternate else { return nil }
        let fix = agent.install.map { " Reinstalling with `\($0)` would fix the one on your PATH." } ?? ""
        return "The `\(agent.bin ?? agent.id)` on your PATH will not start, so \(agent.label) runs from \(runnable) instead.\(fix)"
    }
    private static func isUnavailable(_ error: Error) -> Bool { (error as? NativeRPCError)?.code == "unavailable" }
    public static func authState(_ id: String, detection: any BackendMacAppSetupDetection) async throws -> String {
        guard id == "claude" else { return "ready" }
        do { if (try await detection.credentialFileSize() ?? 0) > 0 { return "ready" } }
        catch { if isUnavailable(error) { throw error }; return "unknown" }
        do { return try await detection.keychainCredentialExists() ? "ready" : "installed-not-authed" }
        catch { if isUnavailable(error) { throw error }; return "installed-not-authed" }
    }
    public static func check(_ detection: any BackendMacAppSetupDetection) async throws -> NativeRPCValue {
        let path = try await detection.loginPath()
        var tools: [NativeRPCValue] = []
        let purposes = ["claude": "Run Claude Code sessions", "codex": "Run OpenAI Codex sessions", "gemini": "Run Gemini CLI sessions"]
        for agent in CodingAICatalog.lookup {
            let binary = try await detection.binary(agent.id, path: path)
            var tool = o([("id", .string(agent.id)), ("label", .string(agent.label)), ("purpose", .string(purposes[agent.id] ?? agent.label)), ("url", agent.url.map(NativeRPCValue.string) ?? .missing), ("required", .bool(false))])
            if binary?.runnable == nil {
                tool = tool.setting("state", .string("missing")).setting("remedy", .string(binaryProblem(binary, agent: agent) ?? "Install \(agent.label), then reopen this window."))
                if let binary, binary.broken, let evidence = binary.said, !evidence.isEmpty { tool = tool.setting("evidence", .string(evidence)) }
            } else if let binary {
                let state = try await authState(agent.id, detection: detection)
                tool = tool.setting("state", .string(state))
                if let version = binary.version, !version.isEmpty { tool = tool.setting("version", .string(version)) }
                if let note = binaryNote(binary, agent: agent) { tool = tool.setting("note", .string(note)) }
                if state == "installed-not-authed" { tool = tool.setting("remedy", .string("Installed but not signed in. Start a session and run `\(agent.bin ?? agent.id)` — it will walk you through signing in.")) }
            }
            tools.append(tool)
        }
        for (bin, label, purpose, url) in [("git", "Git", "Branch and change tracking", "https://git-scm.com"), ("gh", "GitHub CLI", "Pull requests and issues", "https://cli.github.com")] {
            var found: String?
            do { let answer = try await detection.command("which", arguments: [bin], path: path, timeoutMs: 4000); if answer["ok"].bool == true { found = (answer["stdout"].string ?? "").components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.trimmingCharacters(in: .whitespacesAndNewlines) } }
            catch { if isUnavailable(error) { throw error } }
            var tool = o([("id", .string(bin)), ("label", .string(label)), ("state", .string(found == nil ? "missing" : "ready")), ("purpose", .string(purpose)), ("url", .string(url)), ("required", .bool(false))])
            if found != nil {
                do { let answer = try await detection.command(bin, arguments: ["--version"], path: path, timeoutMs: 4000); if answer["ok"].bool == true, let line = answer["stdout"].string?.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first, !line.isEmpty { tool = tool.setting("version", .string(String(decoding: line.utf16.prefix(60), as: UTF16.self))) } }
                catch { if isUnavailable(error) { throw error } }
            } else { tool = tool.setting("remedy", .string("Optional. Without it, the \(label) panel stays empty.")) }
            tools.append(tool)
        }
        let agents = tools.filter { CodingAICatalog.lookup.map(\.id).contains($0["id"].string ?? "") }, ready = agents.contains { $0["state"].string == "ready" }
        return o([("tools", .array(tools)), ("canRunSessions", .bool(ready)), ("needsLogin", .bool(!ready && agents.contains { $0["state"].string == "installed-not-authed" }))])
    }
}
public enum BackendMacAppSetupSnapshot {
    public static let toolIDs = CodingAICatalog.lookup.map(\.id) + ["copilot"]
    public static let copilotNote = "Detected only — this build does not start GitHub Copilot sessions, and GitHub Copilot has no session-hook configuration this app can write."
    public static let codexRequirement = "Codex needs `hooks = true` in ~/.codex/config.toml [features], then Trust all once when it asks."
    private static func o(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(pairs.map { .init($0.0, $0.1) }) }
    public static func compose(prerequisites: NativeRPCValue, copilot: NativeRPCValue, probes: NativeRPCValue, hooks: [NativeRPCValue], endpoint: NativeRPCValue?, now: Double) -> NativeRPCValue {
        let tools = toolIDs.map { id -> NativeRPCValue in
            var status: NativeRPCValue
            if id == "copilot" { status = o([("id", .string(id)), ("label", .string("GitHub Copilot")), ("state", copilot["state"]), ("version", copilot["version"]), ("purpose", .string("Run GitHub Copilot CLI on this machine")), ("remedy", copilot["remedy"]), ("url", .string("https://github.com/github/copilot-cli")), ("required", .bool(false))]) }
            else { status = prerequisites["tools"].elements?.first { $0["id"].string == id } ?? o([("id", .string(id)), ("label", .string(id)), ("state", .string("unknown")), ("purpose", .string("")), ("required", .bool(false))]) }
            let probe = id == "copilot" ? copilot["probe"] : probes[id]
            let evidence = status["evidence"].string
            let shown: NativeRPCValue
            if status["state"].string == "missing", let evidence, !evidence.isEmpty { shown = o([("command", .string("\(CodingAICatalog.agent(id)?.bin ?? id) --version")), ("line", .string(evidence))]) }
            else if status["state"].string == "missing", probe.fields != nil { shown = o([("command", probe["command"]), ("line", probe["line"])]) }
            else { shown = .null }
            status = status.setting("probe", shown).setting("note", id == "copilot" ? .string(copilotNote) : status["note"].isNullish ? .null : status["note"])
            return status
        }
        let hookBlocks = hooks.map { status in o([("id", status["id"]), ("label", status["label"]), ("state", status["state"]), ("unsupportedReason", .null), ("events", .array((BackendSessionHookInstallation.events[status["id"].string ?? ""] ?? []).map(NativeRPCValue.string))), ("installedEvents", status["installedEvents"]), ("staleEvents", status["staleEvents"]), ("missingEvents", status["missingEvents"]), ("file", status["file"]), ("fileExists", status["fileExists"]), ("foreignHooks", status["foreignHooks"]), ("foreignOwners", status["foreignOwners"]), ("message", status["message"]), ("requirement", status["id"].string == "codex" ? .string(codexRequirement) : .null)]) }
        return o([("tools", .array(tools)), ("canRunSessions", prerequisites["canRunSessions"]), ("needsLogin", prerequisites["needsLogin"]), ("hooks", .array(hookBlocks)), ("endpoint", o([("running", .bool(endpoint != nil)), ("address", endpoint?["socketPath"] ?? .null)])), ("checkedAt", .number(now))])
    }
    public static func read(_ detection: any BackendMacAppSetupDetection, now: @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) async throws -> NativeRPCValue {
        let path = try await detection.loginPath(), prerequisites = try await BackendMacAppSetupPrerequisites.check(detection)
        let missing = prerequisites["tools"].elements?.filter { $0["state"].string == "missing" && CodingAICatalog.agent($0["id"].string)?.bin != nil }.compactMap { $0["id"].string } ?? []
        async let copilot = detection.detectCopilot(path: path)
        let probed = try await withThrowingTaskGroup(of: (String, NativeRPCValue).self) { group in
            for id in missing { group.addTask { (id, try await detection.probeBinary(CodingAICatalog.agent(id)?.bin ?? id, path: path)) } }
            var values = NativeRPCValue.object([]); for try await (id, value) in group { values = values.setting(id, value) }; return values
        }
        return try await compose(prerequisites: prerequisites, copilot: copilot, probes: probed, hooks: detection.hookStatuses(), endpoint: detection.hookEndpoint(), now: now())
    }
    public static func register(_ registry: NativeChannelRegistry, detection: any BackendMacAppSetupDetection, ownerID: String, authorize: @escaping NativeChannelRegistry.Policy) async throws {
        try await registry.register("prereq:check", ownerID: ownerID, policy: authorize) { _, _ in try await BackendMacAppSetupPrerequisites.check(detection) }
        try await registry.register("setup:status", ownerID: ownerID, policy: authorize) { _, _ in try await read(detection) }
    }
}
