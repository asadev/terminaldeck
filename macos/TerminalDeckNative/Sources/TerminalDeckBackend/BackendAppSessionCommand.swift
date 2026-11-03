import Foundation
import Dispatch
import Darwin
import TerminalDeckNativeCore

/// Noninteractive pipe execution for source probes and device commands. Unlike
/// the PTY launcher this preserves stdout/stderr separately and closes stdin.
public struct BackendAppSessionCommandResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int?
    public let killed: Bool
    public init(stdout: String = "", stderr: String = "", exitCode: Int? = nil, killed: Bool = false) {
        self.stdout = stdout; self.stderr = stderr; self.exitCode = exitCode; self.killed = killed
    }
    public var ok: Bool { exitCode == 0 && !killed }
}
public protocol BackendAppSessionCommandExecuting: Sendable {
    func run(_ command: String, arguments: [String], environment: [String: String], cwd: String,
             timeoutMilliseconds: Int, maximumBytes: Int) async -> BackendAppSessionCommandResult
    func detach(_ command: String, arguments: [String], environment: [String: String], cwd: String) async throws
}
public final class BackendAppSessionCommandExecutor: BackendAppSessionCommandExecuting, @unchecked Sendable {
    public init() {}
    private final class Capture: @unchecked Sendable {
        let lock = NSLock()
        var bytes = Data()
        var exceeded = false
        /// False once the stream has passed `limit`.
        func append(_ data: Data, limit: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            let left = max(0, limit - bytes.count)
            bytes.append(data.prefix(left)); if data.count > left { exceeded = true }
            return !exceeded
        }
        func value() -> (String, Bool) { lock.lock(); defer { lock.unlock() }; return (String(decoding: bytes, as: UTF8.self), exceeded) }
    }
    /// One stop per run (a stream's cap or cancellation), even when it is asked for before the child has started.
    private final class RunState: @unchecked Sendable {
        let lock = NSLock()
        var killed = false
        var child: NativeChild?
        /// SIGTERM to the child's whole group, SIGKILL a second later. Only the first ask stops it: a child
        /// still printing past its cap would otherwise push the SIGKILL back with every chunk.
        func stop() { lock.lock(); let first = !killed; killed = true; let child = self.child; lock.unlock(); if first { child?.terminate(grace: .seconds(1)) } }
        func install(_ child: NativeChild) { lock.lock(); self.child = child; let asked = killed; lock.unlock(); if asked { child.terminate(grace: .seconds(1)) } }
        func isKilled() -> Bool { lock.lock(); defer { lock.unlock() }; return killed }
    }
    public func run(_ command: String, arguments: [String], environment: [String: String], cwd: String,
                    timeoutMilliseconds: Int, maximumBytes: Int = 256 * 1024) async -> BackendAppSessionCommandResult {
        let state = RunState()
        return await withTaskCancellationHandler {
            guard timeoutMilliseconds > 0, maximumBytes > 0,
                  let executable = BackendNativeProviders.lookup(command, path: environment["PATH"] ?? "/usr/bin:/bin"),
                  !(arguments + [cwd]).contains(where: { $0.contains("\0") }) else {
                return BackendAppSessionCommandResult(stderr: "The command could not be started.")
            }
            guard !state.isKilled() else { return BackendAppSessionCommandResult(killed: true) }
            // The standard child runner (`NativeChild`), started rather than run so each stream keeps its own
            // cap: its own process group, stopped whole on a cap, the deadline or cancellation, so a grandchild
            // holding a pipe no longer hangs the call. stdin is /dev/null. The exit is awaited through a
            // continuation, never by blocking a Swift concurrency thread: a slow adb, simctl or sign-in check
            // would take one from every actor (#64).
            return await withCheckedContinuation { (finished: CheckedContinuation<BackendAppSessionCommandResult, Never>) in
                let stdout = Capture(), stderr = Capture()
                do {
                    let child = try NativeChild.start(.init(executable, arguments, environment: environment, cwd: URL(fileURLWithPath: cwd).path),
                        output: { if !stdout.append($0, limit: maximumBytes) { state.stop() } },
                        errors: { if !stderr.append($0, limit: maximumBytes) { state.stop() } },
                        exit: { end in
                            let out = stdout.value(), err = stderr.value()
                            finished.resume(returning: BackendAppSessionCommandResult(stdout: out.0, stderr: err.0,
                                exitCode: end.signal == nil ? Int(end.code) : nil,
                                killed: state.isKilled() || end.timedOut || out.1 || err.1 || end.signal != nil))
                        })
                    // A `claude …` run (a sign-in check, a print): its stop never cuts a sign-in renewal (lane
                    // mac-signin-renewal "Left"; NativeChild waits for the renewal and asks Claude Code alone first).
                    child.claudeFolder = NativeSignInRenewal.folder(command: executable, arguments: arguments, environment: environment)
                    child.endAfter(.milliseconds(timeoutMilliseconds), grace: .seconds(1))
                    state.install(child)
                } catch { finished.resume(returning: BackendAppSessionCommandResult(stderr: error.localizedDescription)) }
            }
        } onCancel: { state.stop() }
    }
    public func detach(_ command: String, arguments: [String], environment: [String: String], cwd: String) async throws {
        guard let executable = BackendNativeProviders.lookup(command, path: environment["PATH"] ?? "/usr/bin:/bin") else {
            throw BackendAppSessionError("The command could not be started.")
        }
        // /usr/bin/nohup ignores SIGHUP; the runner's detached start gives it its own process group and
        // /dev/null on every stream (spawn(detached, stdio: ignore)), and nothing here keeps it.
        try NativeChild.launchDetached(.init("/usr/bin/nohup", [executable] + arguments, environment: environment, cwd: URL(fileURLWithPath: cwd).path,
                                             input: .none, output: .discard, errors: .discard))
    }
}
public struct BackendAppSessionError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The source timers' clock seam. Production uses the system clock; test ports
/// can advance a manual clock without running a timer or sleeping a thread.
public protocol BackendAppSessionClock: Sendable {
    func now() -> Date
    func sleep(milliseconds: Int) async throws
}
public struct BackendAppSessionSystemClock: BackendAppSessionClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(milliseconds: Int) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }
}
