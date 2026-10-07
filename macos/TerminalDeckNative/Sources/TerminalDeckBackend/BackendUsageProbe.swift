import Foundation
import Darwin
import TerminalDeckNativeCore

/// An explicit get_usage control-protocol request. It sends no user message,
/// opens no interactive panel and does not touch any existing terminal.
public actor BackendUsageProbe {
    public struct Outcome: Sendable {
        public let kind: String, detail: String
        public let readings: [BackendUsageReading]
        public let spawned: Bool
        public let elapsedMilliseconds: Double
        public var wireValue: NativeRPCValue { BackendUsageIO.object([("ok", .bool(kind == "ok" || kind == "cached")), ("outcome", .string(kind)), ("detail", .string(detail)), ("elapsedMs", .number(elapsedMilliseconds)), ("spawned", .bool(spawned))]) }
    }
    /// The one control-process exchange (command, arguments, environment, cwd, cancellation) -> usage
    /// or error. Injectable so a test can prove what is (or is not) asked; production is the real process.
    public typealias Ask = @Sendable (String, [String], [String: String], String, BackendMCPCancellation?) async throws -> (usage: NativeRPCValue?, error: String?)
    private let accounts: BackendAccountLaunchAdapter
    private let providers: BackendNativeProviders
    private let ask: Ask
    public init(accounts: BackendAccountLaunchAdapter, providers: BackendNativeProviders, ask: Ask? = nil) {
        self.accounts = accounts; self.providers = providers
        self.ask = ask ?? { command, arguments, environment, cwd, cancellation in
            let answer = try await BackendUsageControlProcess.ask(command: command, arguments: arguments, environment: environment, cwd: cwd, cancellation: cancellation)
            return (answer.usage, answer.error)
        }
    }
    public static let arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--setting-sources", "", "--strict-mcp-config", "--no-session-persistence", "--disable-slash-commands"]
    public func run(account: BackendUsageAccount, cancellation: BackendMCPCancellation? = nil) async -> Outcome {
        let start = BackendUsageIO.now()
        func done(_ kind: String, _ detail: String, readings: [BackendUsageReading] = [], spawned: Bool = false) -> Outcome {
            Outcome(kind: kind, detail: detail, readings: readings, spawned: spawned, elapsedMilliseconds: BackendUsageIO.now() - start)
        }
        var spawned = false
        do {
            guard account.provider == "claude", let directory = account.configDirectory,
                  let profile = try await accounts.profiles.list(provider: "claude").first(where: { $0.id == account.id || NativeTranscriptPaths.canonical($0.configDir) == NativeTranscriptPaths.canonical(directory) }) else {
                return done("unreadable", "The session's Claude login has not been established, so another account will not be probed.")
            }
            // TS usage-probe.ts:840 keptUnavailable(profile): an app-kept login with no usable vault asks nothing.
            let managed = await accounts.profiles.managed(profile)
            let usable = await accounts.vault.openState() == .ready
            if let unavailable = BackendSessionSwitchKeptLogin.unavailable(BackendSessionSwitchKeptLogin.keptBy(profile, managed: managed, usable: usable)) {
                return done("unreadable", unavailable)
            }
            try Task.checkCancellation(); if cancellation?.isCancelled == true { throw CancellationError() }
            let path = try await providers.loginPath(), binary = await providers.resolveBinary("claude", path: path)
            guard let executable = binary.runnable else { return done("no-binary", "Claude Code is not runnable on this computer, so its usage cannot be read.") }
            let configuration = accounts.profiles.configuration
            var environment = configuration.inheritedEnvironment
            for key in configuration.vaultVariables { environment[key] = nil }
            for key in Array(environment.keys) where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") { environment[key] = nil }
            environment["PATH"] = path
            if !profile.system { environment["CLAUDE_CONFIG_DIR"] = profile.configDir }
            if managed {
                guard try await accounts.broker.readyToServe(accountID: profile.id) else { return done("signed-out", "That account has no held Claude login to serve.") }
                let probe = try await accounts.broker.allocateAccount(profile)
                environment.merge(probe.environment) { _, new in new }
                environment["PATH"] = accounts.broker.shimDirectory + ":" + path
                // Source account probe seats live for the broker's lifetime and
                // are shared by usage/sign-in; they are never session-retargeted.
            }
            spawned = true
            let answer = try await ask(executable, Self.arguments, environment, configuration.homeDirectory.path, cancellation)
            guard let usage = answer.usage else { return done("unreadable", answer.error.map { "Claude Code could not report usage: " + String($0.prefix(160)) } ?? "Claude Code did not return a readable usage answer before the deadline.", spawned: true) }
            let subscription = usage["subscription_type"].string
            guard usage["rate_limits_available"].bool == true else {
                return done(subscription == nil ? "signed-out" : "no-limits", subscription == nil ? "That account is not signed in to Claude Code, so it has no plan limits to report." : "This login has no subscription limits — Claude Code reports none for it.", spawned: true)
            }
            let now = BackendUsageIO.now()
            let readings = BackendUsagePlanParser.utilization(usage["rate_limits"], subscription: subscription).map { $0.reading(account: account, observedAt: now, reportedAt: now, source: "claude-usage-api", apiReset: true) }
            return done(readings.isEmpty ? "no-limits" : "ok", readings.isEmpty ? "Claude Code reports no plan limits for this login." : "Read from Claude Code in the app's own process; no session was touched.", readings: readings, spawned: true)
        } catch is CancellationError { return done("unreadable", "The usage request was cancelled.", spawned: spawned) }
        catch { return done("unreadable", error.localizedDescription, spawned: spawned) }
    }
}

/// Stdio pipes and a separate owned process group. Timeout/cancellation kills
/// descendants, drains stderr without retaining it, and reaps the exact child.
private final class BackendUsageControlProcess: @unchecked Sendable {
    struct Answer: Sendable { let usage: NativeRPCValue?; let error: String? }
    private let queue = DispatchQueue(label: "native.usage.control")
    private var child: Int32 = -1, input: Int32 = -1, output: Int32 = -1, errorPipe: Int32 = -1
    private var sources: [DispatchSourceRead] = []
    private var processSource: DispatchSourceProcess?
    private var deadline: DispatchWorkItem?
    private var continuation: CheckedContinuation<Answer, any Error>?
    private var buffer = Data(), observedBytes = 0, asked = false, finished = false
    private var cancellation: BackendMCPCancellation?, observer: UUID?
    static func ask(command: String, arguments: [String], environment: [String: String], cwd: String,
                    cancellation: BackendMCPCancellation?) async throws -> Answer {
        let running = BackendUsageControlProcess()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                running.queue.async { running.begin(command: command, arguments: arguments, environment: environment, cwd: cwd, cancellation: cancellation, continuation: continuation) }
            }
        } onCancel: { running.queue.async { running.finish(Answer(usage: nil, error: "The usage request was cancelled.")) } }
    }
    private func begin(command: String, arguments: [String], environment: [String: String], cwd: String,
                       cancellation: BackendMCPCancellation?, continuation: CheckedContinuation<Answer, any Error>) {
        if finished { continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        do {
            guard !finished, command.hasPrefix("/"), cwd.hasPrefix("/"), !command.contains("\0"), !cwd.contains("\0"),
                  arguments.allSatisfy({ !$0.contains("\0") }), environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }) else { throw NativeRPCError.invalidArguments("The usage probe launch specification is invalid.") }
            if cancellation?.isCancelled == true { throw CancellationError() }
            var inPair: [Int32] = [-1, -1], outPair: [Int32] = [-1, -1], errPair: [Int32] = [-1, -1]
            guard pipe(&inPair) == 0 else { throw POSIXError(.EIO) }
            defer { inPair.filter { $0 >= 0 }.forEach { Darwin.close($0) }; outPair.filter { $0 >= 0 }.forEach { Darwin.close($0) }; errPair.filter { $0 >= 0 }.forEach { Darwin.close($0) } }
            guard pipe(&outPair) == 0, pipe(&errPair) == 0 else { throw POSIXError(.EIO) }
            for fd in inPair + outPair + errPair { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            var actions: posix_spawn_file_actions_t?, attrs: posix_spawnattr_t?
            guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attrs) == 0 else { throw POSIXError(.ENOMEM) }
            defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attrs) }
            guard posix_spawn_file_actions_adddup2(&actions, inPair[0], STDIN_FILENO) == 0,
                  posix_spawn_file_actions_adddup2(&actions, outPair[1], STDOUT_FILENO) == 0,
                  posix_spawn_file_actions_adddup2(&actions, errPair[1], STDERR_FILENO) == 0,
                  posix_spawn_file_actions_addchdir_np(&actions, cwd) == 0,
                  posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
                  posix_spawnattr_setpgroup(&attrs, 0) == 0 else { throw POSIXError(.EINVAL) }
            let argv = ([command] + arguments).map { strdup($0) }; let env = environment.keys.sorted().map { strdup("\($0)=\(environment[$0]!)") }
            defer { argv.forEach { free($0) }; env.forEach { free($0) } }
            guard argv.allSatisfy({ $0 != nil }), env.allSatisfy({ $0 != nil }) else { throw POSIXError(.ENOMEM) }
            var argvPointers = argv + [nil], envPointers = env + [nil]
            let code = posix_spawn(&child, command, &actions, &attrs, &argvPointers, &envPointers)
            guard code == 0 else { child = -1; throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            input = inPair[1]; inPair[1] = -1; output = outPair[0]; outPair[0] = -1; errorPipe = errPair[0]; errPair[0] = -1
            // Avoid SIGPIPE terminating the app when the CLI closes stdin.
            _ = fcntl(input, F_SETNOSIGPIPE, 1)
            for fd in [output, errorPipe] {
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler { [self] in drain(fd) }; sources.append(source); source.resume()
            }
            let process = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: queue)
            process.setEventHandler { [self] in drain(output); finish(Answer(usage: nil, error: nil)) }; processSource = process; process.resume()
            let timer = DispatchWorkItem { [self] in finish(Answer(usage: nil, error: "Claude Code did not answer within 15 seconds.")) }; deadline = timer; queue.asyncAfter(deadline: .now() + .seconds(15), execute: timer)
            self.cancellation = cancellation; observer = cancellation?.observe { [self] in queue.async { self.finish(Answer(usage: nil, error: "The usage request was cancelled.")) } }
            send(BackendUsageIO.object([("type", .string("control_request")), ("request_id", .string("init")), ("request", BackendUsageIO.object([("subtype", .string("initialize"))]))]))
        } catch { finish(Answer(usage: nil, error: error is CancellationError ? "The usage request was cancelled." : error.localizedDescription)) }
    }
    private func send(_ value: NativeRPCValue) {
        let bytes = Array((value.compact + "\n").utf8)
        let count = bytes.withUnsafeBytes { Darwin.write(input, $0.baseAddress, $0.count) }
        if count != bytes.count { finish(Answer(usage: nil, error: "The usage control request could not be delivered.")) }
    }
    private func drain(_ fd: Int32) {
        guard fd >= 0, !finished else { return }
        var bytes = [UInt8](repeating: 0, count: 32_768)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count <= 0 { if count < 0, errno == EINTR { continue }; return }
            guard fd == output else { continue }
            observedBytes += count
            guard observedBytes <= 4 * 1024 * 1024 else { finish(Answer(usage: nil, error: "The usage control response exceeded its read budget.")); return }
            buffer.append(contentsOf: bytes.prefix(count))
            while let cut = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<cut]); buffer.removeSubrange(...cut)
                guard let message = try? NativeRPCValue.parseJSON(line, maximumBytes: 1_048_576), message["type"].string == "control_response" else { continue }
                let response = message["response"]
                if response["request_id"].string == "init", !asked {
                    guard response["subtype"].string == "success" else { finish(Answer(usage: nil, error: response["error"].string)); return }
                    asked = true; send(BackendUsageIO.object([("type", .string("control_request")), ("request_id", .string("usage")), ("request", BackendUsageIO.object([("subtype", .string("get_usage"))]))]))
                } else if response["request_id"].string == "usage" {
                    finish(Answer(usage: response["subtype"].string == "success" && response["response"].fields != nil ? response["response"] : nil, error: response["error"].string)); return
                }
            }
            if buffer.count > 1_048_576 { finish(Answer(usage: nil, error: "The usage control response line was too large.")); return }
        }
    }
    private func finish(_ answer: Answer) {
        guard !finished else { return }; finished = true; deadline?.cancel()
        if let observer { cancellation?.removeObserver(observer) }; cancellation = nil
        sources.forEach { $0.cancel() }; sources.removeAll(); processSource?.cancel(); processSource = nil
        for fd in [input, output, errorPipe] where fd >= 0 { Darwin.close(fd) }; input = -1; output = -1; errorPipe = -1
        if child > 0 {
            let pid = child; _ = Darwin.kill(-pid, SIGTERM)
            // Reap only this owned child. The escalator retains no credentials.
            queue.asyncAfter(deadline: .now() + .milliseconds(250)) { _ = Darwin.kill(-pid, SIGKILL); var status: Int32 = 0; while waitpid(pid, &status, 0) < 0 && errno == EINTR {} }
            child = -1
        }
        continuation?.resume(returning: answer); continuation = nil
    }
}
