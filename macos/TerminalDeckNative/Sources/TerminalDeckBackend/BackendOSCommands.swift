import Foundation
import TerminalDeckNativeCore

/// The shared native pipe/process-group executor, with a narrow injectable
/// contract for OS parser/transition tests. It never delegates to Node.
public protocol BackendOSCommandRunning: Sendable {
    func run(command: String, arguments: [String], environment: [String: String], cwd: String,
             timeoutMilliseconds: Int, maximumBytes: Int) async throws -> BackendGitOutcome
}
extension BackendDevProcessExecutor: BackendOSCommandRunning {}
