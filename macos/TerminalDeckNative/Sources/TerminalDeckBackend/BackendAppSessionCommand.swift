import Foundation
import Dispatch
import Darwin

/// Noninteractive pipe execution for source probes and SimView commands. Unlike
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
        func append(_ data: Data, limit: Int) {
            lock.lock(); defer { lock.unlock() }
            let left = max(0, limit - bytes.count)
            bytes.append(data.prefix(left)); if data.count > left { exceeded = true }
        }
        func isExceeded() -> Bool { lock.lock(); defer { lock.unlock() }; return exceeded }
        func value() -> (String, Bool) { lock.lock(); defer { lock.unlock() }; return (String(decoding: bytes, as: UTF8.self), exceeded) }
    }
    private final class RunState: @unchecked Sendable {
        let lock = NSLock()
        var killed = false
        var cancelled = false
        var process: Process?
        func cancel() { lock.lock(); cancelled = true; killed = true; let child = process; lock.unlock(); if let child, child.isRunning { child.terminate(); DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) } } } }
        func markKilled() { lock.lock(); killed = true; lock.unlock() }
        func install(_ child: Process) -> Bool { lock.lock(); defer { lock.unlock() }; process = child; return !cancelled }
        func isKilled() -> Bool { lock.lock(); defer { lock.unlock() }; return killed }
    }
    public func run(_ command: String, arguments: [String], environment: [String: String], cwd: String,
                    timeoutMilliseconds: Int, maximumBytes: Int = 256 * 1024) async -> BackendAppSessionCommandResult {
        let state = RunState()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .utility) {
                guard timeoutMilliseconds > 0, maximumBytes > 0,
                      let executable = BackendNativeProviders.lookup(command, path: environment["PATH"] ?? "/usr/bin:/bin"),
                      !(arguments + [cwd]).contains(where: { $0.contains("\0") }) else {
                    return BackendAppSessionCommandResult(stderr: "The command could not be started.")
                }
                let child = Process(), output = Pipe(), errors = Pipe(), input = Pipe()
                child.executableURL = URL(fileURLWithPath: executable); child.arguments = arguments
                child.environment = environment; child.currentDirectoryURL = URL(fileURLWithPath: cwd)
                child.standardOutput = output; child.standardError = errors; child.standardInput = input
                guard state.install(child) else { return BackendAppSessionCommandResult(killed: true) }
                do { try child.run(); try input.fileHandleForWriting.close() }
                catch { return BackendAppSessionCommandResult(stderr: error.localizedDescription) }
                let stdout = Capture(), stderr = Capture(), group = DispatchGroup()
                for (handle, capture) in [(output.fileHandleForReading, stdout), (errors.fileHandleForReading, stderr)] {
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        defer { group.leave(); try? handle.close() }
                        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                            capture.append(chunk, limit: maximumBytes)
                            if capture.isExceeded() { state.markKilled(); if child.isRunning { child.terminate() } }
                        }
                    }
                }
                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                timer.schedule(deadline: .now() + .milliseconds(timeoutMilliseconds))
                timer.setEventHandler {
                    state.markKilled()
                    if child.isRunning { child.terminate() }
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                        if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
                    }
                }
                timer.resume(); child.waitUntilExit(); timer.cancel(); backendAppSessionDrain(group)
                let out = stdout.value(), err = stderr.value()
                return BackendAppSessionCommandResult(stdout: out.0, stderr: err.0,
                    exitCode: child.terminationReason == .exit ? Int(child.terminationStatus) : nil,
                    killed: state.isKilled() || out.1 || err.1 || child.terminationReason != .exit)
            }.value
        } onCancel: { state.cancel() }
    }
    public func detach(_ command: String, arguments: [String], environment: [String: String], cwd: String) async throws {
        guard let executable = BackendNativeProviders.lookup(command, path: environment["PATH"] ?? "/usr/bin:/bin") else {
            throw BackendAppSessionError("The command could not be started.")
        }
        // /usr/bin/nohup ignores SIGHUP; Foundation's child outlives this call.
        // All streams are /dev/null, matching spawn(detached, stdio: ignore).
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        child.arguments = [executable] + arguments; child.environment = environment
        child.currentDirectoryURL = URL(fileURLWithPath: cwd)
        child.standardInput = FileHandle.nullDevice; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run()
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

/// The detached runner deliberately blocks its own thread until both pipe
/// readers finish (DispatchGroup.wait cannot be called from async code directly).
private func backendAppSessionDrain(_ group: DispatchGroup) { group.wait() }
