import Foundation
import Darwin
import TerminalDeckNativeCore

public struct BackendGitOutcome: Sendable {
    public let ok: Bool; public let stdout: String; public let stderr: String; public let missing: Bool
    public let exitCode: Int; public let timedOut: Bool
}
public struct BackendGitExecutionPlan: Sendable {
    public let command: String; public let arguments: [String]; public let environment: [String: String]; public let cwd: String
    public init(command: String, arguments: [String], environment: [String: String], cwd: String) {
        self.command = command; self.arguments = arguments; self.environment = environment; self.cwd = cwd
    }
}
public protocol BackendGitExecuting: Sendable {
    func run(cwd: String, arguments: [String], context: NativeRPCContext, writing: Bool,
             timeoutMilliseconds: Int, maximumBytes: Int) async throws -> BackendGitOutcome
}

/// True stdout/stderr pipes preserve NUL porcelain framing and diff line endings.
/// Repository-pointing inherited variables cannot retarget a workspace command.
/// Remote callers require an actual guest environment/confinement planner;
/// owner's inherited credentials are never a remote fallback.
public struct BackendGitRunner: BackendGitExecuting, Sendable {
    public typealias DevicePlanner = @Sendable (NativeRPCContext, BackendGitExecutionPlan) async throws -> BackendGitExecutionPlan
    private let inherited: [String: String]
    private let loginPath: @Sendable () async throws -> String
    private let devicePlanner: DevicePlanner?
    private let executor = BackendGitPipeExecutor()
    public init(inheritedEnvironment: [String: String], loginPath: @escaping @Sendable () async throws -> String,
                devicePlanner: DevicePlanner? = nil) {
        inherited = inheritedEnvironment; self.loginPath = loginPath; self.devicePlanner = devicePlanner
    }
    public func run(cwd: String, arguments: [String], context: NativeRPCContext, writing: Bool = false,
                    timeoutMilliseconds: Int = 8_000, maximumBytes: Int = 16 * 1024 * 1024) async throws -> BackendGitOutcome {
        try Task.checkCancellation()
        let path = try await loginPath()
        guard let executable = BackendNativeProviders.lookup("git", path: path) else {
            return BackendGitOutcome(ok: false, stdout: "", stderr: "git is not installed, or not on the login PATH", missing: true, exitCode: 127, timedOut: false)
        }
        var environment = BackendSessionEnvironment.stripInherited(inherited)
        for name in Self.repositoryVariables { environment[name] = nil }
        environment["PATH"] = path; environment["LC_ALL"] = "C"; environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"; environment["PAGER"] = "cat"
        if !writing { environment["GIT_OPTIONAL_LOCKS"] = "0" }
        var plan = BackendGitExecutionPlan(command: executable,
            arguments: ["--no-pager", "-c", "core.fsmonitor=false"] + arguments, environment: environment, cwd: cwd)
        if context.caller == .pairedDevice || context.caller == .page {
            guard let devicePlanner else { throw NativeRPCError(code: "missing-capability", message: "This caller's guest Git environment and enforced folder boundary are not connected") }
            plan = try await devicePlanner(context, plan)
        }
        try Task.checkCancellation()
        return try await executor.run(plan, timeout: timeoutMilliseconds, maximum: maximumBytes)
    }
    public static let repositoryVariables = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE", "GIT_PREFIX"]
}

final class BackendGitPipeExecutor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.terminaldeck.native.git", qos: .utility)
    private final class Running: @unchecked Sendable {
        let pid: pid_t; let continuation: CheckedContinuation<BackendGitOutcome, any Error>; let maximum: Int
        let stdoutFD: Int32; let stderrFD: Int32
        var stdout = Data(), stderr = Data(); var timedOut = false; var cancelled = false; var reaped = false
        var readers: [DispatchSourceRead] = []; var process: DispatchSourceProcess?; var deadline: DispatchWorkItem?
        init(pid: pid_t, stdout: Int32, stderr: Int32, maximum: Int, continuation: CheckedContinuation<BackendGitOutcome, any Error>) {
            self.pid = pid; stdoutFD = stdout; stderrFD = stderr; self.maximum = maximum; self.continuation = continuation
        }
    }
    private var running: [UUID: Running] = [:]

    func run(_ plan: BackendGitExecutionPlan, timeout: Int, maximum: Int) async throws -> BackendGitOutcome {
        let id = UUID()
        let cancellation = BackendMCPCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    do {
                        if cancellation.isCancelled { throw CancellationError() }
                        guard plan.command.hasPrefix("/"), plan.cwd.hasPrefix("/"), !plan.command.contains("\0"), !plan.cwd.contains("\0"),
                              plan.arguments.allSatisfy({ !$0.contains("\0") }), (1...600_000).contains(timeout), (1...32 * 1024 * 1024).contains(maximum),
                              plan.environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }) else {
                            throw NativeRPCError.invalidArguments("The Git execution plan or limits are invalid")
                        }
                        let process = try Self.spawn(plan)
                        let state = Running(pid: process.pid, stdout: process.stdout, stderr: process.stderr, maximum: maximum, continuation: continuation)
                        running[id] = state
                        for (fd, isError) in [(state.stdoutFD, false), (state.stderrFD, true)] {
                            let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                            reader.setEventHandler { [weak self] in self?.read(id, errorStream: isError) }
                            state.readers.append(reader); reader.resume()
                        }
                        let watcher = DispatchSource.makeProcessSource(identifier: state.pid, eventMask: .exit, queue: queue)
                        watcher.setEventHandler { [weak self] in self?.finish(id) }
                        state.process = watcher; watcher.resume()
                        let deadline = DispatchWorkItem { [weak self] in
                            guard let state = self?.running[id] else { return }
                            state.timedOut = true; Darwin.kill(-state.pid, SIGKILL); Darwin.kill(state.pid, SIGKILL)
                        }
                        state.deadline = deadline; queue.asyncAfter(deadline: .now() + .milliseconds(timeout), execute: deadline)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            cancellation.cancel()
            self.queue.async { [self] in
                if let state = running[id] { state.cancelled = true; Darwin.kill(-state.pid, SIGKILL); Darwin.kill(state.pid, SIGKILL) }
            }
        }
    }
    private func read(_ id: UUID, errorStream: Bool) {
        guard let state = running[id] else { return }
        let fd = errorStream ? state.stderrFD : state.stdoutFD
        var bytes = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            if state.stdout.count + state.stderr.count + count > state.maximum {
                state.timedOut = true; Darwin.kill(-state.pid, SIGKILL); Darwin.kill(state.pid, SIGKILL); return
            }
            if errorStream { state.stderr.append(contentsOf: bytes.prefix(count)) } else { state.stdout.append(contentsOf: bytes.prefix(count)) }
        }
    }
    private func finish(_ id: UUID) {
        guard let state = running[id], !state.reaped else { return }
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(state.pid, &status, WNOHANG) } while result == -1 && errno == EINTR
        if result == 0 {
            // NOTE_EXIT can precede waitability and fires once; retry instead of never finishing.
            queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in self?.finish(id) }
            return
        }
        guard result == state.pid || errno == ECHILD else { return }
        read(id, errorStream: false); read(id, errorStream: true)
        state.reaped = true; running[id] = nil
        state.deadline?.cancel(); state.process?.cancel(); state.readers.forEach { $0.cancel() }
        Darwin.close(state.stdoutFD); Darwin.close(state.stderrFD)
        if state.cancelled { state.continuation.resume(throwing: CancellationError()); return }
        let signal = status & 0x7f
        let code = result == state.pid ? (signal == 0 ? Int((status >> 8) & 0xff) : 128 + Int(signal)) : -1
        state.continuation.resume(returning: BackendGitOutcome(ok: code == 0 && !state.timedOut,
            stdout: String(decoding: state.stdout, as: UTF8.self), stderr: String(decoding: state.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            missing: false, exitCode: code, timedOut: state.timedOut))
    }
    private static func spawn(_ plan: BackendGitExecutionPlan) throws -> (pid: pid_t, stdout: Int32, stderr: Int32) {
        let argv = try Strings([plan.command] + plan.arguments)
        let env = try Strings(plan.environment.keys.sorted().map { "\($0)=\(plan.environment[$0]!)" })
        var out: [Int32] = [-1, -1], err: [Int32] = [-1, -1]
        guard pipe(&out) == 0 else { throw NativeRPCError(code: "process", message: "Git stdout pipe failed (POSIX status \(errno))") }
        guard pipe(&err) == 0 else { Darwin.close(out[0]); Darwin.close(out[1]); throw NativeRPCError(code: "process", message: "Git stderr pipe failed (POSIX status \(errno))") }
        var keepReaders = false
        defer {
            Darwin.close(out[1]); Darwin.close(err[1])
            if !keepReaders { Darwin.close(out[0]); Darwin.close(err[0]) }
        }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else { throw NativeRPCError(code: "process", message: "Git spawn attributes could not be prepared") }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO) == 0,
              posix_spawn_file_actions_addchdir(&actions, plan.cwd) == 0 else { throw NativeRPCError(code: "process", message: "Git file actions could not be prepared") }
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        var empty = sigset_t(), defaults = sigset_t(); sigemptyset(&empty); sigemptyset(&defaults)
        for signal in [SIGPIPE, SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGCHLD] { sigaddset(&defaults, signal) }
        guard posix_spawnattr_setflags(&attributes, flags) == 0, posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setsigmask(&attributes, &empty) == 0, posix_spawnattr_setsigdefault(&attributes, &defaults) == 0 else { throw NativeRPCError(code: "process", message: "Git signal/process-group settings could not be prepared") }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, plan.command, &actions, &attributes, argv.pointer, env.pointer)
        guard status == 0 else { throw NativeRPCError(code: "process", message: "Git could not be executed (POSIX status \(status))") }
        for fd in [out[0], err[0]] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK); _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        keepReaders = true
        return (pid, out[0], err[0])
    }
    private final class Strings {
        let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>; let count: Int
        init(_ strings: [String]) throws {
            let pointer = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
            pointer.initialize(repeating: nil, count: strings.count + 1)
            for (index, string) in strings.enumerated() {
                guard let item = strdup(string) else {
                    for i in 0..<index { free(pointer[i]) }; pointer.deinitialize(count: strings.count + 1); pointer.deallocate()
                    throw NativeRPCError(code: "process", message: "Git argv could not be allocated")
                }
                pointer[index] = item
            }
            self.pointer = pointer; count = strings.count
        }
        deinit { for i in 0..<count { free(pointer[i]) }; pointer.deinitialize(count: count + 1); pointer.deallocate() }
    }
}
