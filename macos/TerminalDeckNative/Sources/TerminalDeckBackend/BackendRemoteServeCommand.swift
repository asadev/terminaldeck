import Foundation
import TerminalDeckNativeCore

public struct BackendRemoteServeCommandResult: Equatable, Sendable {
    public var stdout: String; public var stderr: String; public var code: Int
    public var spawnError: String?
    public init(stdout: String = "", stderr: String = "", code: Int = 0, spawnError: String? = nil) {
        self.stdout = stdout; self.stderr = stderr; self.code = code; self.spawnError = spawnError
    }
}
public protocol BackendRemoteServeCommandExecuting: Sendable {
    /// stdout/stderr must remain separate. stopWhen is checked as output arrives;
    /// true terminates the child before returning the current output snapshot.
    func run(executable: String, arguments: [String], environment: [String: String], timeoutMilliseconds: Int,
             maximumBytes: Int, stopWhen: (@Sendable (String, String) -> Bool)?) async -> BackendRemoteServeCommandResult
}
/// Bounded non-PTY process for status JSON and prompt-aware Tailscale Serve.
/// Existing BackendCommandRunner merges stderr into its PTY and cannot parse
/// status JSON correctly when Tailscale prints a version warning on stderr.
public struct BackendRemoteServeCommand: BackendRemoteServeCommandExecuting {
    public init() {}
    public func run(executable: String, arguments: [String], environment: [String: String], timeoutMilliseconds: Int,
                    maximumBytes: Int, stopWhen: (@Sendable (String, String) -> Bool)? = nil) async -> BackendRemoteServeCommandResult {
        let state = Run(executable: executable, arguments: arguments, environment: environment,
                        timeout: max(1, timeoutMilliseconds), limit: max(1, maximumBytes), stopWhen: stopWhen)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { state.start($0) }
        } onCancel: { state.cancel() }
    }
    /// The standard runner (`NativeChild.start`) with this file's own collection, since `stopWhen`
    /// reads the output as it arrives (`NativeChild.run` only answers at the end). The deadline,
    /// the byte cap, `stopWhen` or cancellation answer at once and kill the whole group.
    private final class Run: @unchecked Sendable {
        /// Serial: the child reports both streams and its end here too.
        private let queue = DispatchQueue(label: "dev.terminaldeck.native.remote-command")
        private let spec: NativeChild.Spec
        private let timeout: Int, limit: Int
        private let stopWhen: (@Sendable (String, String) -> Bool)?
        private var child: NativeChild?
        private var stdout = Data(), stderr = Data()
        private var continuation: CheckedContinuation<BackendRemoteServeCommandResult, Never>?
        private var deadline: DispatchWorkItem?
        private var done = false, cancelled = false
        init(executable: String, arguments: [String], environment: [String: String], timeout: Int, limit: Int,
             stopWhen: (@Sendable (String, String) -> Bool)?) {
            self.timeout = timeout; self.limit = limit; self.stopWhen = stopWhen
            // stdin is /dev/null (input .none); stdout and stderr stay separate pipes.
            spec = .init(URL(fileURLWithPath: executable).path, arguments, environment: environment, cwd: "/")
        }
        func start(_ pending: CheckedContinuation<BackendRemoteServeCommandResult, Never>) {
            queue.async { [self] in
                continuation = pending
                if cancelled { finish(code: -1); return }
                do {
                    // The end comes after its last byte; a signal reads as its number, as Process said.
                    child = try NativeChild.start(spec, queue: queue, output: { [self] in take($0, isError: false) },
                                                  errors: { [self] in take($0, isError: true) },
                                                  exit: { [self] end in finish(code: end.signal.map { Int($0) } ?? Int(end.code)) })
                } catch {
                    let missing = !FileManager.default.fileExists(atPath: spec.command)
                    stderr = Data(error.localizedDescription.utf8)
                    finish(code: -1, spawnError: missing ? "ENOENT" : "SPAWN"); return
                }
                let timer = DispatchWorkItem { [self] in finish(code: -1) }; deadline = timer
                queue.asyncAfter(deadline: .now() + .milliseconds(timeout), execute: timer)
            }
        }
        func cancel() { queue.async { [self] in cancelled = true; if continuation != nil { finish(code: -1) } } }
        private func take(_ bytes: Data, isError: Bool) {
            guard !done else { return }
            let room = max(0, limit - stdout.count - stderr.count)
            if isError { stderr.append(bytes.prefix(room)) } else { stdout.append(bytes.prefix(room)) }
            if bytes.count > room { finish(code: -1); return }
            if stopWhen?(String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self)) == true { finish(code: 0) }
        }
        private func finish(code: Int, spawnError: String? = nil) {
            guard !done else { return }; done = true; deadline?.cancel(); deadline = nil
            // Kills the group if it still runs; letting go of the handle ends the cycle through its callbacks.
            child?.kill(); child = nil
            let result = BackendRemoteServeCommandResult(stdout: String(decoding: stdout, as: UTF8.self),
                stderr: String(decoding: stderr, as: UTF8.self), code: code, spawnError: spawnError)
            let pending = continuation; continuation = nil; pending?.resume(returning: result)
        }
    }
}
