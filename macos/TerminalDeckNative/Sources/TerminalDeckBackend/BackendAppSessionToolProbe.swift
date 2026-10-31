import Foundation
import TerminalDeckNativeCore

public struct BackendAppSessionProbeResult: Sendable, Equatable {
    public let command: String
    public let output: String
    public let exitCode: Int
    public let found: Bool
    public let line: String
    public var wireValue: NativeRPCValue {
        .object([.init("command", .string(command)), .init("output", .string(output)), .init("exitCode", .number(Double(exitCode))), .init("found", .bool(found)), .init("line", .string(line))])
    }
}
public struct BackendAppSessionToolProbe: Sendable {
    private let executor: any BackendAppSessionCommandExecuting
    private let environment: [String: String]
    private let home: String
    public init(executor: any BackendAppSessionCommandExecuting = BackendAppSessionCommandExecutor(),
                environment: [String: String], home: String) {
        self.executor = executor; self.environment = environment; self.home = home
    }
    public static func macLaunchSpec(_ bin: String, resolved: String? = nil) -> (command: String, shell: Bool) { (bin, false) }
    public static func safeBinary(_ bin: String) -> Bool { BackendSharedText.matches(bin, #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#) }
    public static func result(bin: String, command: String, stdout: String, stderr: String, exitCode: Int) -> BackendAppSessionProbeResult {
        let clean = (stdout + "\n" + stderr).components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.prefix(3).joined(separator: "\n")
        let output = String(decoding: Array(clean.utf16.prefix(240)), as: UTF16.self), found = exitCode == 0
        let status = exitCode < 0 ? "did not finish" : "exited \(exitCode)"
        return BackendAppSessionProbeResult(command: command, output: output, exitCode: exitCode, found: found,
            line: output.isEmpty ? (found ? "\(bin) is on your PATH." : "\(bin) not found (\(command) \(status)).") : output)
    }
    public func probe(_ bin: String, path: String, shell: String? = nil) async -> BackendAppSessionProbeResult {
        let command = "which " + bin
        guard Self.safeBinary(bin) else { return .init(command: command, output: "", exitCode: -1, found: false, line: "\(bin) is not a name this app is willing to run a probe for.") }
        var env = environment; env["PATH"] = path
        let answer = await executor.run(shell ?? environment["SHELL"] ?? "/bin/zsh", arguments: ["-c", command], environment: env, cwd: home, timeoutMilliseconds: 5_000, maximumBytes: 256 * 1024)
        return Self.result(bin: bin, command: command, stdout: answer.stdout, stderr: answer.stderr, exitCode: answer.killed ? -1 : answer.exitCode ?? -1)
    }
    public func version(_ bin: String, path: String, resolved: String? = nil) async -> String? {
        guard Self.safeBinary(bin) else { return nil }
        var env = environment; env["PATH"] = path
        let answer = await executor.run(Self.macLaunchSpec(bin, resolved: resolved).command, arguments: ["--version"], environment: env, cwd: home, timeoutMilliseconds: 5_000, maximumBytes: 256 * 1024)
        guard answer.ok, let first = answer.stdout.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first, !first.isEmpty else { return nil }
        return String(decoding: Array(first.utf16.prefix(60)), as: UTF16.self)
    }
}
