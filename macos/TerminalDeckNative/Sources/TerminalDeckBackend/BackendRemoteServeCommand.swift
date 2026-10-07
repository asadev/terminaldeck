import Foundation
import Darwin

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
    private final class Run: @unchecked Sendable {
        private let queue = DispatchQueue(label: "dev.terminaldeck.native.remote-command")
        private let process = Process(), out = Pipe(), err = Pipe()
        private let timeout: Int, limit: Int
        private let stopWhen: (@Sendable (String, String) -> Bool)?
        private var stdout = Data(), stderr = Data()
        private var continuation: CheckedContinuation<BackendRemoteServeCommandResult, Never>?
        private var deadline: DispatchWorkItem?
        private var done = false, cancelled = false
        private var ended = 0, status: Int?
        init(executable: String, arguments: [String], environment: [String: String], timeout: Int, limit: Int,
             stopWhen: (@Sendable (String, String) -> Bool)?) {
            self.timeout = timeout; self.limit = limit; self.stopWhen = stopWhen
            process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.environment = environment; process.currentDirectoryURL = URL(fileURLWithPath: "/")
            process.standardOutput = out; process.standardError = err; process.standardInput = FileHandle.nullDevice
        }
        func start(_ pending: CheckedContinuation<BackendRemoteServeCommandResult, Never>) {
            queue.async { [self] in
                continuation = pending
                if cancelled { finish(code: -1); return }
                process.terminationHandler = { [self] child in queue.async { [self] in status = Int(child.terminationStatus); completeIfDrained() } }
                do { try process.run() }
                catch {
                    let missing = !FileManager.default.fileExists(atPath: process.executableURL!.path)
                    stderr = Data(error.localizedDescription.utf8)
                    finish(code: -1, spawnError: missing ? "ENOENT" : "SPAWN"); return
                }
                try? out.fileHandleForWriting.close(); try? err.fileHandleForWriting.close()
                reader(out.fileHandleForReading, isError: false); reader(err.fileHandleForReading, isError: true)
                let timer = DispatchWorkItem { [self] in finish(code: -1) }; deadline = timer
                queue.asyncAfter(deadline: .now() + .milliseconds(timeout), execute: timer)
            }
        }
        func cancel() { queue.async { [self] in cancelled = true; if continuation != nil { finish(code: -1) } } }
        private func reader(_ handle: FileHandle, isError: Bool) {
            DispatchQueue.global(qos: .utility).async { [self] in
                while true {
                    let bytes: Data
                    do { bytes = try handle.read(upToCount: 4096) ?? Data() } catch { break }
                    if bytes.isEmpty { break }
                    queue.async { [self] in
                        guard !done else { return }
                        let room = max(0, limit - stdout.count - stderr.count)
                        if isError { stderr.append(bytes.prefix(room)) } else { stdout.append(bytes.prefix(room)) }
                        if bytes.count > room { finish(code: -1); return }
                        if stopWhen?(String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self)) == true { finish(code: 0) }
                    }
                }
                queue.async { [self] in ended += 1; completeIfDrained() }
            }
        }
        private func completeIfDrained() { if ended == 2, let status { finish(code: status) } }
        private func finish(code: Int, spawnError: String? = nil) {
            guard !done else { return }; done = true; deadline?.cancel(); deadline = nil
            if process.isRunning { process.terminate(); _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            process.terminationHandler = nil
            try? out.fileHandleForWriting.close(); try? err.fileHandleForWriting.close()
            let result = BackendRemoteServeCommandResult(stdout: String(decoding: stdout, as: UTF8.self),
                stderr: String(decoding: stderr, as: UTF8.self), code: code, spawnError: spawnError)
            let pending = continuation; continuation = nil; pending?.resume(returning: result)
        }
    }
}
