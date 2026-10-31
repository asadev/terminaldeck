import Foundation
import Darwin
import TerminalDeckNativeCore

// CONNECT-SKILLS (Asad "go", 11 Oct): one-click install of the coding AIs, for strangers. Before this a missing
// Claude Code, Codex or Gemini only showed a terminal command (`npm install -g …`), which also needed Node.js.
// Now an Install button runs the AI's OWN official route, shows where it stands, checks it works, and the screen
// goes on to sign-in. Routes (checked against the vendors' pages on 11 Oct 2026):
//  - Claude Code: Anthropic's native installer, `curl -fsSL https://claude.ai/install.sh | bash`. Needs no Node.js;
//    puts `claude` in ~/.local/bin and does not touch PATH (the app adds ~/.local/bin to its own lookup).
//  - Codex: OpenAI's standalone installer, `curl -fsSL https://chatgpt.com/codex/install.sh | sh` (no Node.js,
//    ~/.local/bin); then Homebrew (`brew install --cask codex`) or npm (`npm install -g @openai/codex`) only if present.
//  - Gemini CLI: Homebrew (`brew install gemini-cli`), else npm (`npm install -g @google/gemini-cli`). Google ships no
//    standalone installer, so with neither the person is told plainly what to get (Node.js) and where.
// Never with admin rights: no sudo, no askpass, no terminal to type a password into (stdin is empty), so anything
// that wants the Mac password fails and says so instead of asking silently.

/// What to run for one AI, decided from what this Mac has. Pure: tests read it directly.
public enum BackendAIToolInstallPlan {
    public static let tools = ["claude", "codex", "gemini"]
    public static let claudeScript = "https://claude.ai/install.sh"
    public static let codexScript = "https://chatgpt.com/codex/install.sh"
    public static let nodeDownload = "https://nodejs.org/en/download"
    public static let pages = ["claude": "https://code.claude.com/docs/en/setup", "codex": "https://github.com/openai/codex",
                               "gemini": "https://github.com/google-gemini/gemini-cli"]

    public enum Kind: String, Sendable { case script, homebrew, npm }
    public struct Attempt: Equatable, Sendable {
        public let kind: Kind
        /// Said on screen: "the official installer", "Homebrew", "npm".
        public let label: String
        /// `.script`: the vendor's installer address and the shell that runs it.
        public let scriptURL: String?
        public let shell: String?
        /// `.homebrew` / `.npm`: the resolved program and its arguments.
        public let command: String?
        public let arguments: [String]
        public let environment: [String: String]
        public var argv: [String] { (command ?? shell).map { [$0] + arguments } ?? arguments }
    }
    public enum Plan: Equatable, Sendable {
        case attempts([Attempt])
        /// Nothing on this Mac can install it: what to get, in plain words, and where.
        case needs(message: String, helpURL: String)
    }

    static func script(_ url: String, shell: String, environment: [String: String] = [:]) -> Attempt {
        Attempt(kind: .script, label: "the official installer", scriptURL: url, shell: shell, command: nil, arguments: [], environment: environment)
    }
    static func brew(_ brew: String, _ arguments: [String]) -> Attempt {
        Attempt(kind: .homebrew, label: "Homebrew", scriptURL: nil, shell: nil, command: brew, arguments: arguments,
                environment: ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1", "CI": "1"])
    }
    static func npm(_ npm: String, _ package: String) -> Attempt {
        Attempt(kind: .npm, label: "npm", scriptURL: nil, shell: nil, command: npm, arguments: ["install", "-g", package],
                environment: ["CI": "1", "npm_config_yes": "true", "npm_config_fund": "false", "npm_config_audit": "false"])
    }

    public static func plan(_ tool: String, brew: String?, npm: String?) -> Plan {
        switch tool {
        case "claude":
            return .attempts([script(claudeScript, shell: "/bin/bash")])
        case "codex":
            var attempts = [script(codexScript, shell: "/bin/sh", environment: ["CODEX_NON_INTERACTIVE": "1"])]
            if let brew { attempts.append(Self.brew(brew, ["install", "--cask", "codex"])) }
            if let npm { attempts.append(Self.npm(npm, "@openai/codex")) }
            return .attempts(attempts)
        case "gemini":
            var attempts: [Attempt] = []
            if let brew { attempts.append(Self.brew(brew, ["install", "gemini-cli"])) }
            if let npm { attempts.append(Self.npm(npm, "@google/gemini-cli")) }
            guard attempts.isEmpty else { return .attempts(attempts) }
            return .needs(message: "Gemini CLI runs on Node.js, and this Mac has neither Node.js nor Homebrew yet. Get Node.js from nodejs.org (the macOS installer; it asks for your Mac password itself), then press Install again.", helpURL: nodeDownload)
        default:
            return .needs(message: "Terminal Deck installs Claude Code, Codex and Gemini CLI. This one is set up by hand.", helpURL: "")
        }
    }

    /// FINAL-CONNECT (row 36): Settings › Coding AI › Updates "Upgrade it" did nothing. An upgrade goes through the route
    /// that put the AI there: Homebrew's copy with Homebrew, npm's with npm, anything else with the vendor's installer.
    public static func upgradePlan(_ tool: String, installedAt runnable: String?, brew: String?, npm: String?) -> Plan {
        let real = runnable.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } ?? ""
        let byBrew = real.contains("/Cellar/") || real.contains("/Caskroom/") || real.hasPrefix("/opt/homebrew/")
        let packages = ["claude": "@anthropic-ai/claude-code", "codex": "@openai/codex", "gemini": "@google/gemini-cli"]
        if byBrew, let brew {
            let formula: [String] = tool == "gemini" ? ["upgrade", "gemini-cli"] : ["upgrade", "--cask", tool == "claude" ? "claude-code" : "codex"]
            return .attempts([Self.brew(brew, formula)])
        }
        if real.contains("/node_modules/"), let npm, let package = packages[tool] { return .attempts([Self.npm(npm, package + "@latest")]) }
        if tool == "gemini" {
            if let npm { return .attempts([Self.npm(npm, "@google/gemini-cli@latest")]) }
            return .needs(message: "This Gemini CLI was not installed with Homebrew or npm, so Terminal Deck cannot tell how to update it. Update it the way it was installed.", helpURL: pages["gemini"] ?? "")
        }
        return plan(tool, brew: nil, npm: nil)
    }

    /// The installer's environment: the app's own minus anything that could act as another account or ask for an
    /// admin password, with a PATH that always has the system folders. stdin is empty, so nothing can prompt.
    public static func environment(inherited: [String: String], path: String, home: String, extra: [String: String]) -> [String: String] {
        var env = BackendSessionEnvironment.stripInherited(inherited)
        for key in ["SUDO_ASKPASS", "SSH_ASKPASS", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "GEMINI_CLI_HOME"] { env[key] = nil }
        var parts = path.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        for system in ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] where !parts.contains(system) { parts.append(system) }
        env["PATH"] = parts.joined(separator: ":")
        env["HOME"] = home
        env["NONINTERACTIVE"] = "1"
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        env.merge(extra) { _, new in new }
        return env
    }

    /// Homebrew outside the login PATH still counts (a fresh Mac's shell may not load it yet).
    public static func findBrew(path: String, lookup: (String, String) -> String?) -> String? {
        lookup("brew", path) ?? ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { lookup($0, path) != nil }
    }
}

/// The person-facing sentence for a missing or broken AI. One wording everywhere (11 Oct: three screens each said
/// "Install it with `npm install -g …`", which a stranger cannot act on and which also needed Node.js).
public enum BackendAIToolInstallText {
    public static let marker = "is not installed on this Mac"
    /// `button`: the screen shows an Install button beside the line.
    public static func missing(_ label: String, button: Bool = true) -> String {
        button ? "\(label) \(marker) yet. Press Install and Terminal Deck sets it up for you."
               : "\(label) \(marker) yet. Settings › Coding AI installs it with one click."
    }
    public static func broken(_ label: String, at path: String?) -> String {
        "\(label) is installed\(path.map { " at \($0)" } ?? "") but will not start. Press Install to put a fresh copy in place."
    }
    /// Which AI a sentence says is missing (so a screen can offer Install beside an error from the sign-in).
    public static func missingTool(in text: String) -> String? {
        guard text.contains(marker) || text.contains("but will not start") else { return nil }
        return BackendAIToolInstallPlan.tools.first { text.hasPrefix(CodingAICatalog.label($0) + " ") }
    }
}

/// Runs one program and hands each output line over as it comes. Tests supply their own.
public protocol BackendAIToolInstallRunning: Sendable {
    func run(_ argv: [String], environment: [String: String], cwd: String, timeoutMilliseconds: Int,
             line: @escaping @Sendable (String) -> Void) async -> (ok: Bool, output: String)
}

public struct BackendAIToolInstallProcessRunner: BackendAIToolInstallRunning {
    public init() {}
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock(); private var pending = Data(); private var tail = ""
        let line: @Sendable (String) -> Void
        init(line: @escaping @Sendable (String) -> Void) { self.line = line }
        func add(_ data: Data) {
            var lines: [String] = []
            lock.withLock {
                pending.append(data)
                while let cut = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                    let text = String(decoding: pending[pending.startIndex..<cut], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...cut)
                    if !text.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(text) }
                }
                tail = String((tail + String(decoding: data, as: UTF8.self)).suffix(16_384))
            }
            for each in lines { line(BackendAIToolInstaller.clean(each)) }
        }
        var text: String { lock.withLock { tail } }
    }
    public func run(_ argv: [String], environment: [String: String], cwd: String, timeoutMilliseconds: Int,
                    line: @escaping @Sendable (String) -> Void) async -> (ok: Bool, output: String) {
        guard let program = argv.first, program.hasPrefix("/"), !(argv + [cwd]).contains(where: { $0.contains("\0") }) else { return (false, "No program to run.") }
        let collector = Collector(line: line)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.runBlocking(argv, environment: environment, cwd: cwd, timeoutMilliseconds: timeoutMilliseconds, collector: collector))
            }
        }
    }

    /// The standard runner (`NativeChild`): its own process group, output and errors on one pipe, stdin empty,
    /// reaped by its own pid (11 Oct: Foundation's Process.waitUntilExit never returned after a real Claude install
    /// had finished). On timeout the whole group gets SIGTERM, then SIGKILL 5 s later, the installer's own downloads
    /// included; when the installer ends, a helper it left in its group goes too, so nothing holds the pipe open.
    private static func runBlocking(_ argv: [String], environment: [String: String], cwd: String, timeoutMilliseconds: Int,
                                    collector: Collector) -> (ok: Bool, output: String) {
        let child: NativeChild
        do {
            child = try NativeChild.start(.init(argv[0], Array(argv.dropFirst()), environment: environment, cwd: cwd, errors: .merged),
                                          output: { collector.add($0) })
        } catch { return (false, error.localizedDescription) }   // "<program> could not be started (POSIX status N)."
        child.endAfter(.milliseconds(timeoutMilliseconds), grace: .seconds(5))
        let end = child.waitUntilExit()
        let said = end.timedOut ? collector.text + "\n(stopped: it took longer than \(timeoutMilliseconds / 60_000) minutes)" : collector.text
        return (!end.timedOut && end.code == 0, said)
    }
}

/// One install per AI at a time; where each stands, for the screens (event `ai-tools:install-progress`) and for
/// the AIs (tools ai_tools_install / ai_tools_status).
public actor BackendAIToolInstaller {
    public static let progressEvent = "ai-tools:install-progress"
    public static let channels = ["ai-tools:install", "ai-tools:install-state"]

    public struct Status: Equatable, Sendable {
        /// idle | running | installed | failed | needs
        public var state: String = "idle"
        public var tool: String
        /// What it is doing now, in plain words.
        public var step: String = ""
        /// The installer's last line of output (shown small, for the curious).
        public var line: String = ""
        public var message: String = ""
        public var route: String?
        public var version: String?
        public var helpURL: String?
        public var startedAt: Double?
        public var finishedAt: Double?
        public init(tool: String) { self.tool = tool }
        public var label: String { CodingAICatalog.label(tool) }
        public var wire: NativeRPCValue {
            func text(_ value: String?) -> NativeRPCValue { value.map(NativeRPCValue.string) ?? .null }
            return .object([.init("tool", .string(tool)), .init("label", .string(label)), .init("state", .string(state)),
                            .init("step", .string(step)), .init("line", .string(line)), .init("message", .string(message)),
                            .init("route", text(route)), .init("version", text(version)), .init("helpURL", text(helpURL)),
                            .init("startedAt", startedAt.map(NativeRPCValue.number) ?? .null),
                            .init("finishedAt", finishedAt.map(NativeRPCValue.number) ?? .null)])
        }
    }

    public struct Dependencies: Sendable {
        public let runner: any BackendAIToolInstallRunning
        public let loginPath: @Sendable () async throws -> String
        public let lookup: @Sendable (String, String) -> String?
        /// (tool, refresh) → the runnable program and its version line, as session launch would find it.
        public let installed: @Sendable (String, Bool) async -> (runnable: String?, version: String?)
        public let resetCaches: @Sendable () async -> Void
        public let publish: @Sendable (NativeRPCValue) async -> Void
        /// Where installer scripts are downloaded (inside the app's data folder), removed after each run.
        public let scratch: URL
        public let home: String
        public let environment: [String: String]
        public let now: @Sendable () -> Double
        public init(runner: any BackendAIToolInstallRunning = BackendAIToolInstallProcessRunner(),
                    loginPath: @escaping @Sendable () async throws -> String,
                    lookup: @escaping @Sendable (String, String) -> String? = { BackendNativeProviders.lookup($0, path: $1) },
                    installed: @escaping @Sendable (String, Bool) async -> (runnable: String?, version: String?),
                    resetCaches: @escaping @Sendable () async -> Void, publish: @escaping @Sendable (NativeRPCValue) async -> Void,
                    scratch: URL, home: String, environment: [String: String],
                    now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
            self.runner = runner; self.loginPath = loginPath; self.lookup = lookup; self.installed = installed
            self.resetCaches = resetCaches; self.publish = publish; self.scratch = scratch; self.home = home
            self.environment = environment; self.now = now
        }
    }

    public static let downloadTimeout = 120_000, installTimeout = 900_000
    private let dependencies: Dependencies
    private var statuses: [String: Status] = [:]
    private var jobs: [String: Task<Status, Never>] = [:]
    private var lastLineSent: [String: Double] = [:]
    public init(dependencies: Dependencies) { self.dependencies = dependencies }

    static func clean(_ raw: String) -> String {
        let plain = raw.replacingOccurrences(of: #"\x1b\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(plain.prefix(240))
    }

    private static func require(_ tool: String) throws {
        guard BackendAIToolInstallPlan.tools.contains(tool) else {
            throw NativeRPCError.invalidArguments("Terminal Deck installs claude, codex or gemini.")
        }
    }

    public func status(_ tool: String) throws -> Status {
        try Self.require(tool)
        return statuses[tool] ?? Status(tool: tool)
    }
    public func all() -> [Status] { BackendAIToolInstallPlan.tools.map { statuses[$0] ?? Status(tool: $0) } }

    /// Starts the install (or joins the one running) and answers at once. `upgrade`: also when it is already there.
    public func start(_ tool: String, upgrade: Bool = false) throws -> Status {
        try Self.require(tool)
        if jobs[tool] != nil, let running = statuses[tool] { return running }
        var status = Status(tool: tool)
        status.state = "running"; status.step = "Checking this Mac"; status.startedAt = dependencies.now()
        statuses[tool] = status
        jobs[tool] = Task { [weak self] in
            guard let self else { return Status(tool: tool) }
            let finished = await self.perform(tool, upgrade: upgrade)
            await self.done(tool)
            return finished
        }
        return status
    }

    /// Starts (or joins) and waits for the end. For the AI tools.
    public func install(_ tool: String, upgrade: Bool = false) async throws -> Status {
        _ = try start(tool, upgrade: upgrade)
        guard let job = jobs[tool] else { return try status(tool) }
        return await job.value
    }

    private func done(_ tool: String) { jobs[tool] = nil }

    private func update(_ tool: String, publish: Bool = true, _ change: (inout Status) -> Void) async {
        var status = statuses[tool] ?? Status(tool: tool)
        change(&status)
        statuses[tool] = status
        if publish { await dependencies.publish(status.wire) }
    }

    private func heard(_ tool: String, _ line: String) async {
        guard !line.isEmpty, statuses[tool]?.state == "running" else { return }
        // Lines come fast from a package manager: the screen gets at most two a second.
        let now = dependencies.now(), send = now - (lastLineSent[tool] ?? 0) >= 500
        if send { lastLineSent[tool] = now }
        await update(tool, publish: send) { $0.line = line }
    }

    private func finish(_ tool: String, state: String, message: String, version: String? = nil, helpURL: String? = nil) async -> Status {
        await update(tool) {
            $0.state = state; $0.message = message; $0.version = version; $0.helpURL = helpURL
            $0.step = state == "installed" ? "Installed" : state == "needs" ? "Needs something first" : "Stopped"
            $0.finishedAt = dependencies.now()
        }
        return statuses[tool] ?? Status(tool: tool)
    }

    private func perform(_ tool: String, upgrade: Bool = false) async -> Status {
        let label = CodingAICatalog.label(tool)
        await update(tool) { _ in }
        let before = await dependencies.installed(tool, true)
        if before.runnable != nil, !upgrade {
            return await finish(tool, state: "installed", message: "\(label) is already installed\(before.version.map { " (\($0))" } ?? "").", version: before.version)
        }
        let path: String
        do { path = try await dependencies.loginPath() } catch { path = dependencies.environment["PATH"] ?? "/usr/bin:/bin" }
        let lookup = dependencies.lookup
        let brew = BackendAIToolInstallPlan.findBrew(path: path, lookup: lookup), npm = lookup("npm", path)
        let plan = upgrade && before.runnable != nil ? BackendAIToolInstallPlan.upgradePlan(tool, installedAt: before.runnable, brew: brew, npm: npm)
                                                     : BackendAIToolInstallPlan.plan(tool, brew: brew, npm: npm)
        guard case .attempts(let attempts) = plan else {
            if case .needs(let message, let help) = plan { return await finish(tool, state: "needs", message: message, helpURL: help.isEmpty ? nil : help) }
            return await finish(tool, state: "failed", message: "\(label) cannot be installed from here.")
        }
        var reasons: [String] = []
        for attempt in attempts {
            guard !Task.isCancelled else { break }
            await update(tool) { $0.route = attempt.label; $0.line = "" }
            let env = BackendAIToolInstallPlan.environment(inherited: dependencies.environment, path: path, home: dependencies.home, extra: attempt.environment)
            let result: (ok: Bool, output: String)
            switch attempt.kind {
            case .script:
                result = await runScript(tool, attempt, environment: env)
            case .homebrew, .npm:
                await update(tool) { $0.step = "Installing \(label) with \(attempt.label)" }
                result = await dependencies.runner.run(attempt.argv, environment: env, cwd: dependencies.home, timeoutMilliseconds: Self.installTimeout) { [weak self] line in
                    Task { await self?.heard(tool, line) }
                }
            }
            if result.ok {
                await update(tool) { $0.step = "Checking \(label) starts" }
                await dependencies.resetCaches()
                let after = await dependencies.installed(tool, true)
                if after.runnable != nil {
                    if upgrade, before.runnable != nil {
                        let same = after.version == before.version
                        return await finish(tool, state: "installed", message: same ? "\(label) is already the newest version\(after.version.map { " (\($0))" } ?? "")."
                                                                                : "\(label) is updated\(after.version.map { " to \($0)" } ?? ""). New sessions use it.", version: after.version)
                    }
                    return await finish(tool, state: "installed", message: "\(label) is installed\(after.version.map { " (\($0))" } ?? ""). Next: sign in.", version: after.version)
                }
                reasons.append("\(attempt.label) finished, but \(label) does not start yet")
                continue
            }
            reasons.append(Self.reason(result.output, route: attempt.label))
        }
        let why = reasons.last ?? "the installer stopped"
        let page = BackendAIToolInstallPlan.pages[tool]
        return await finish(tool, state: "failed", message: "\(label) was not installed: \(why). Press Install to try again\(page == nil ? "." : ", or open its page for other ways.")", helpURL: page)
    }

    private func runScript(_ tool: String, _ attempt: BackendAIToolInstallPlan.Attempt, environment: [String: String]) async -> (ok: Bool, output: String) {
        guard let address = attempt.scriptURL, let shell = attempt.shell else { return (false, "no installer address") }
        let label = CodingAICatalog.label(tool)
        let file = dependencies.scratch.appendingPathComponent("install-\(tool)-\(UUID().uuidString.prefix(8)).sh")
        defer { try? FileManager.default.removeItem(at: file) }
        do { try FileManager.default.createDirectory(at: dependencies.scratch, withIntermediateDirectories: true) }
        catch { return (false, "Terminal Deck could not make its download folder: " + error.localizedDescription) }
        await update(tool) { $0.step = "Downloading \(label)’s official installer" }
        let fetched = await dependencies.runner.run(["/usr/bin/curl", "-fsSL", "--proto", "=https", "--tlsv1.2", "--retry", "2", "-o", file.path, address],
                                                    environment: environment, cwd: dependencies.home, timeoutMilliseconds: Self.downloadTimeout) { _ in }
        guard fetched.ok else { return (false, "download: " + fetched.output) }
        await update(tool) { $0.step = "Installing \(label) (this can take a few minutes)" }
        return await dependencies.runner.run([shell, file.path], environment: environment, cwd: dependencies.home, timeoutMilliseconds: Self.installTimeout) { [weak self] line in
            Task { await self?.heard(tool, line) }
        }
    }

    /// The plain reason an attempt stopped.
    static func reason(_ output: String, route: String) -> String {
        let lower = output.lowercased()
        if lower.contains("could not resolve host") || lower.contains("failed to connect") || lower.contains("network is unreachable") || lower.contains("timed out") && lower.contains("curl") {
            return "this Mac could not reach the download (check the internet connection)"
        }
        if lower.contains("eacces") || lower.contains("permission denied") || lower.contains("operation not permitted") || lower.contains("sudo") || lower.contains("password") {
            return "\(route) needs your Mac password for that folder, and Terminal Deck never uses admin rights for you"
        }
        if lower.contains("no space left") { return "the Mac's disk is full" }
        if lower.contains("stopped: it took longer") { return "it took too long and was stopped" }
        let last = output.components(separatedBy: .newlines).map(clean).last { !$0.isEmpty }
        return last.map { "\(route) said: \($0)" } ?? "\(route) stopped without saying why"
    }

    /// The UI's channels: start, and read where it stands. Progress arrives as `ai-tools:install-progress`.
    public static func register(registry: NativeChannelRegistry, ownerID: String, installer: BackendAIToolInstaller,
                                policy: @escaping NativeChannelRegistry.Policy) async throws -> (invokes: [String], sends: [String], events: [String]) {
        try await registry.register("ai-tools:install", ownerID: ownerID, policy: policy) { context, args in
            try await installer.start(context.argument(0, in: args).string ?? "", upgrade: context.argument(1, in: args)["upgrade"].bool == true).wire
        }
        try await registry.register("ai-tools:install-state", ownerID: ownerID, policy: policy) { context, args in
            if let tool = context.argument(0, in: args).string { return try await installer.status(tool).wire }
            return .array(await installer.all().map(\.wire))
        }
        return (channels, [], [progressEvent])
    }
}
