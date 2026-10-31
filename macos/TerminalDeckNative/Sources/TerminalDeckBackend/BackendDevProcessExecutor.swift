import Foundation

/// Shared actual pipe/process-group primitive for readiness/package-manager
/// jobs. Privileged callers supply argv/env/cwd directly; no shell string is
/// assembled, no command is inferred, and initialization starts no process.
public final class BackendDevProcessExecutor: Sendable {
    private let executor = BackendGitPipeExecutor()
    public init() {}
    public func run(command: String, arguments: [String], environment: [String: String], cwd: String,
                    timeoutMilliseconds: Int, maximumBytes: Int = 16 * 1024 * 1024) async throws -> BackendGitOutcome {
        try await executor.run(BackendGitExecutionPlan(command: command, arguments: arguments, environment: environment, cwd: cwd),
            timeout: timeoutMilliseconds, maximum: maximumBytes)
    }
}
