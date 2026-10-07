import Foundation
import Darwin
import TerminalDeckNativeCore

/// Source provider/catalog semantics for macOS. The GUI login PATH is measured
/// only on demand, successful answers are cached, and failed fallback answers
/// never poison Retry. No process is launched when this adapter is constructed.
public actor BackendNativeProviders: BackendProviderLaunchResolver {
    public nonisolated let readiness: BackendLaunchReadiness = .ready
    private let store: NativeStateStore
    private let dataRoot: URL
    private let environment: [String: String]
    private let home: String
    private let runner: BackendCommandRunner
    private var cachedPath: String?
    private struct PathAnswer: Sendable { let path: String; let measured: Bool }
    private var probingPath: Task<PathAnswer, Never>?
    private var binaryCache: [String: Binary] = [:]
    /// S1i: a process-free login PATH (tests only); production leaves it nil and measures the login shell.
    private let loginPathOverride: (@Sendable () async throws -> String)?

    public struct Binary: Sendable {
        public let id: String
        public let onPath: String?
        public let runnable: String?
        public let version: String?
        public let broken: Bool
        public let said: String?
        public let usedAlternate: Bool
        public let checkedAt: Date
    }

    public init(store: NativeStateStore, dataRoot: URL, inheritedEnvironment: [String: String], home: String,
                runner: BackendCommandRunner, loginPath loginPathOverride: (@Sendable () async throws -> String)? = nil) throws {
        guard dataRoot.isFileURL, dataRoot.path.hasPrefix("/"), home.hasPrefix("/"),
              !home.contains("\0") else { throw BackendSessionFailure.invalidInput("Provider resolution needs the app's own data root and absolute user home.") }
        self.store = store; self.dataRoot = dataRoot.standardizedFileURL
        environment = BackendSessionEnvironment.stripInherited(inheritedEnvironment)
        self.home = home; self.runner = runner; self.loginPathOverride = loginPathOverride
    }

    public func resetCaches() {
        cachedPath = nil; probingPath = nil; binaryCache.removeAll()
    }

    /// What is spawned to ask for the person's real PATH (lookup.ts `loginPathSpec`, macOS half): their login
    /// shell, or zsh when the environment names none. The marker form keeps a shell greeting from passing as PATH.
    static func loginPathSpec(environment: [String: String]) -> (command: String, arguments: [String]) {
        let shell = environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
        return (shell, ["-lic", #"printf '\000%s\000' "$PATH""#])
    }

    public func loginPath() async throws -> String {
        if let loginPathOverride { return try await loginPathOverride() }
        if let cachedPath { return cachedPath }
        if let probingPath { return await probingPath.value.path }
        let spec = Self.loginPathSpec(environment: environment)
        let env = environment, runner = runner, home = home
        let fallback = env["PATH"] ?? ""
        // A fixed marker prevents a .zshrc greeting from being mistaken for
        // PATH. No untrusted name or value is interpolated into shell source.
        let task = Task<PathAnswer, Never> {
            do {
                let answer = try await runner.run(command: spec.command,
                    arguments: spec.arguments, environment: env,
                    cwd: home, timeoutMilliseconds: 5_000)
                guard answer.succeeded else { return PathAnswer(path: fallback, measured: false) }
                let parts = answer.output.components(separatedBy: "\0")
                guard parts.count >= 3, !parts[1].isEmpty, !parts[1].contains(where: { $0.isNewline }) else { return PathAnswer(path: fallback, measured: false) }
                return PathAnswer(path: parts[1], measured: true)
            } catch { return PathAnswer(path: fallback, measured: false) }
        }
        probingPath = task
        let answer = await task.value
        probingPath = nil
        if answer.measured { cachedPath = answer.path }
        return answer.path
    }

    public func resolve(_ input: BackendCreateSessionInput, loginPath: String) async throws -> BackendProviderSpec {
        let preferences = await store.getPreferences()
        let requested = input.provider ?? preferences["defaultProvider"].string ?? "claude"
        if requested == "shell" {
            let shell = environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
            guard Self.lookup(shell, path: loginPath) != nil else {
                throw BackendSessionFailure.unsupported("The configured login shell is not executable.")
            }
            return BackendProviderSpec(id: "shell", command: shell, args: ["-l"], resumeArgs: [])
        }
        if requested.hasPrefix("custom:") {
            guard let custom = try customAgents().first(where: { $0.id == requested }),
                  let command = Self.lookup(custom.command, path: loginPath) else {
                throw BackendSessionFailure.unsupported("\(requested) could not be found on this machine, so it was not started. No substitute shell was started.")
            }
            return BackendProviderSpec(id: custom.id, command: command, args: custom.args, resumeArgs: custom.resumeArgs)
        }
        guard ["claude", "codex", "gemini"].contains(requested) else { throw BackendSessionFailure.providerMismatch }
        let binary = await resolveBinary(requested, path: loginPath)
        guard let command = binary.runnable else {
            throw BackendSessionFailure.unsupported(binary.broken
                ? "\(requested) is installed but its launcher will not run. Repair that CLI or choose another agent."
                : "\(requested) could not be found on the login shell's PATH. Install it or choose another agent.")
        }
        return BackendProviderSpec(id: requested, command: command, args: [],
            resumeArgs: requested == "claude" ? ["--continue"] : requested == "codex" ? ["resume", "--last"] : [])
    }

    public func resolveBinary(_ id: String, path: String, refresh: Bool = false) async -> Binary {
        let key = id + ":" + path
        let now = Date()
        if !refresh, let cached = binaryCache[key], now.timeIntervalSince(cached.checkedAt) < 20 { return cached }
        let onPath = ["claude", "codex", "gemini"].contains(id) ? Self.lookup(id, path: path) : nil
        var env = environment
        env["PATH"] = path
        var said: String?
        if let onPath {
            let probe = await versionProbe(onPath, environment: env)
            if probe.ok {
                let result = Binary(id: id, onPath: onPath, runnable: onPath, version: probe.line,
                    broken: false, said: nil, usedAlternate: false, checkedAt: now)
                binaryCache[key] = result
                return result
            }
            said = probe.line
        }
        if id == "codex" {
            let alternate = URL(fileURLWithPath: home).appendingPathComponent(".codex/plugins/.plugin-appserver/codex").path
            if Self.lookup(alternate, path: path) != nil {
                let probe = await versionProbe(alternate, environment: env)
                if probe.ok {
                    let result = Binary(id: id, onPath: onPath, runnable: alternate, version: probe.line,
                        broken: false, said: said, usedAlternate: true, checkedAt: now)
                    binaryCache[key] = result
                    return result
                }
            }
        }
        let result = Binary(id: id, onPath: onPath, runnable: nil, version: nil,
            broken: onPath != nil, said: said, usedAlternate: false, checkedAt: now)
        binaryCache[key] = result
        return result
    }

    private func versionProbe(_ command: String, environment: [String: String]) async -> (ok: Bool, line: String?) {
        do {
            let result = try await runner.run(command: command, arguments: ["--version"], environment: environment,
                cwd: home, timeoutMilliseconds: 6_000)
            let spawnFailure = result.output.range(of: #"\bENOENT\b"#, options: .regularExpression) != nil &&
                result.output.range(of: #"\bspawn\b"#, options: [.regularExpression, .caseInsensitive]) != nil
            let clean = result.output.replacingOccurrences(of: #"\x1b\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"#, with: "", options: .regularExpression)
            let line = clean.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.hasPrefix("at ") }.map { String($0.prefix(200)) }
            return (result.succeeded && !spawnFailure, line)
        } catch { return (false, nil) }
    }

    private struct CustomAgent {
        let id: String
        let command: String
        let args: [String]
        let resumeArgs: [String]
    }

    private func customAgents() throws -> [CustomAgent] {
        let file = dataRoot.appendingPathComponent("custom-agents.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let values = try file.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? Int.max) <= 256 * 1024 else { throw BackendSessionFailure.invalidInput("The custom-agent catalog exceeds its supported size.") }
        let data = try Data(contentsOf: file)
        guard data.count <= 256 * 1024, let state = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = state["agents"] as? [[String: Any]], records.count <= 32 else {
            throw BackendSessionFailure.invalidInput("The custom-agent catalog is invalid.")
        }
        var seen: Set<String> = []
        return records.compactMap { record in
            guard let id = record["id"] as? String, id.hasPrefix("custom:"), id.count > 7, !seen.contains(id),
                  let rawCommand = record["command"] as? String else { return nil }
            let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            let args = (record["args"] as? [Any] ?? []).compactMap { $0 as? String }
            let resume = (record["resumeArgs"] as? [Any] ?? []).compactMap { $0 as? String }
            let meta = CharacterSet(charactersIn: "&|;<>^\"'`$()%!").union(.controlCharacters)
            guard !command.isEmpty, command.count <= 512, command.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  command.rangeOfCharacter(from: meta) == nil,
                  command.hasPrefix("/") || command.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil,
                  args.count <= 24, resume.count <= 24, (args + resume).allSatisfy({ $0.rangeOfCharacter(from: meta) == nil }) else { return nil }
            seen.insert(id)
            return CustomAgent(id: id, command: command, args: args, resumeArgs: resume)
        }
    }

    public nonisolated static func lookup(_ command: String, path: String) -> String? {
        guard !command.isEmpty, !command.contains("\0"), !path.contains("\0") else { return nil }
        let candidates = command.hasPrefix("/") ? [command] : path.components(separatedBy: ":")
            .filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0).appendingPathComponent(command).path }
        for candidate in candidates {
            var info = stat()
            if access(candidate, X_OK) == 0, stat(candidate, &info) == 0, info.st_mode & S_IFMT == S_IFREG { return candidate }
        }
        return nil
    }
}
