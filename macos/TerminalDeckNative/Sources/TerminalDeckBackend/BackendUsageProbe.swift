import Foundation
import Darwin
import TerminalDeckNativeCore

#if TD_HOST_ACCOUNT_BRIDGE
public typealias BackendHOSTUsageProviderAlias = any BackendHOSTUsageProvider
#else
public typealias BackendHOSTUsageProviderAlias = BackendNativeProviders
#endif

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
    private let providers: BackendHOSTUsageProviderAlias
    private let ask: Ask
    public init(accounts: BackendAccountLaunchAdapter, providers: BackendHOSTUsageProviderAlias, ask: Ask? = nil) {
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
            let path = try await providers.loginPath(), binary = await providers.resolveBinary("claude", path: path, refresh: false)
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

/// Stdio pipes through the standard child runner (`NativeChild`): its own process group, so the
/// deadline, cancellation or a passed budget ends descendants too; stderr is discarded, never retained.
/// Everything here runs on `queue`, which is also the child's callback queue.
private final class BackendUsageControlProcess: @unchecked Sendable {
    struct Answer: Sendable { let usage: NativeRPCValue?; let error: String? }
    private let queue = DispatchQueue(label: "native.usage.control")
    private var child: NativeChild?
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
            // Its output arrives on `queue` and its end only after the last byte, so an answer printed just before it
            // exits is still read. The exit is an answer only when the protocol has not already finished.
            child = try NativeChild.start(.init(command, arguments, environment: environment, cwd: cwd, input: .pipe, output: .pipe, errors: .discard), queue: queue,
                output: { [self] data in drain(data) },
                exit: { [self] end in finish(Answer(usage: nil, error: end.timedOut ? "Claude Code did not answer within 15 seconds." : nil)) })
            // Claude Code may be renewing its sign-in just after it answers: its stop waits for that, asks it
            // alone first and gives it 3 s (a group SIGTERM 250 ms after the answer could cut the renewal).
            child?.claudeFolder = NativeSignInRenewal.folder(environment: environment)
            child?.endAfter(.seconds(15), grace: .seconds(3))
            self.cancellation = cancellation; observer = cancellation?.observe { [self] in queue.async { self.finish(Answer(usage: nil, error: "The usage request was cancelled.")) } }
            send(BackendUsageIO.object([("type", .string("control_request")), ("request_id", .string("init")), ("request", BackendUsageIO.object([("subtype", .string("initialize"))]))]))
        } catch { finish(Answer(usage: nil, error: error is CancellationError ? "The usage request was cancelled." : error.localizedDescription)) }
    }
    /// The runner makes a CLI that closed its stdin an EPIPE here, never SIGPIPE for the app.
    private func send(_ value: NativeRPCValue) {
        do {
            guard let child else { throw CancellationError() }
            try child.write(Data((value.compact + "\n").utf8))
        } catch { finish(Answer(usage: nil, error: "The usage control request could not be delivered.")) }
    }
    private func drain(_ data: Data) {
        guard !finished else { return }
        observedBytes += data.count
        guard observedBytes <= 4 * 1024 * 1024 else { finish(Answer(usage: nil, error: "The usage control response exceeded its read budget.")); return }
        buffer.append(data)
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
    private func finish(_ answer: Answer) {
        guard !finished else { return }; finished = true
        if let observer { cancellation?.removeObserver(observer) }; cancellation = nil
        // End of input, then Claude Code's own stop (`NativeChild.claudeFolder`: never during a sign-in renewal,
        // Claude Code first, its group after 3 s only if it hangs); the runner reaps exactly this child. Dropping
        // it here also lets go of its callbacks (and so of this object) once it has ended.
        child?.closeInput(); child?.terminate(grace: .seconds(3)); child = nil
        continuation?.resume(returning: answer); continuation = nil
    }
}
