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

/// Git and the readiness/package jobs (`BackendDevProcessExecutor`) run through the standard child
/// runner (`NativeChild`): their own process group, killed whole on the deadline, the output cap or
/// cancellation. Both streams together count toward the cap; passing it reads as timed out.
final class BackendGitPipeExecutor: @unchecked Sendable {
    func run(_ plan: BackendGitExecutionPlan, timeout: Int, maximum: Int) async throws -> BackendGitOutcome {
        guard plan.command.hasPrefix("/"), plan.cwd.hasPrefix("/"), (1...600_000).contains(timeout), (1...32 * 1024 * 1024).contains(maximum) else {
            throw NativeRPCError.invalidArguments("The Git execution plan or limits are invalid")
        }
        let outcome: NativeChild.Outcome
        do {
            outcome = try await NativeChild.run(.init(plan.command, plan.arguments, environment: plan.environment, cwd: plan.cwd),
                                                timeoutMilliseconds: timeout, outputLimit: maximum)
        } catch let error as NativeRPCError where ["missing", "process"].contains(error.code) {
            throw NativeRPCError(code: "process", message: error.message)
        }
        let limited = outcome.timedOut || outcome.outputLimited
        return BackendGitOutcome(ok: outcome.code == 0 && !limited, stdout: outcome.outputText,
            stderr: outcome.errorsText.trimmingCharacters(in: .whitespacesAndNewlines), missing: false, exitCode: Int(outcome.code), timedOut: limited)
    }
}
