import Foundation

/// Hidden, bounded command execution for the login PATH, known binary-version
/// probes and per-launch Seatbelt proof. Initialization does not run anything.
/// Uses the same owned POSIX process-group primitive as sessions, so timeout
/// cannot strand a probe's child process. Never log this result's output.
public final class BackendCommandRunner: @unchecked Sendable {
    public struct Result: Sendable {
        public let output: String
        public let exitCode: Int
        public let timedOut: Bool
        public let outputLimited: Bool
        public var succeeded: Bool { exitCode == 0 && !timedOut && !outputLimited }
    }
    private let queue = DispatchQueue(label: "dev.terminaldeck.native.launch-probes", qos: .utility)
    private var active: [UUID: Running] = [:]

    private final class Running: @unchecked Sendable {
        let process: BackendPTYProcess
        let continuation: CheckedContinuation<Result, any Error>
        let limit: Int
        var output = Data()
        var timedOut = false
        var outputLimited = false
        var deadline: DispatchWorkItem?
        init(process: BackendPTYProcess, continuation: CheckedContinuation<Result, any Error>, limit: Int) {
            self.process = process; self.continuation = continuation; self.limit = limit
        }
    }

    public init() {}

    public func run(command: String, arguments: [String], environment: [String: String], cwd: String,
                    timeoutMilliseconds: Int = 6_000, outputLimit: Int = 256 * 1024) async throws -> Result {
        let id = UUID(), cancellation = BackendMCPCancellation()
        return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    if cancellation.isCancelled { throw CancellationError() }
                    guard (1...60_000).contains(timeoutMilliseconds), (1...1_048_576).contains(outputLimit),
                          environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }) else {
                        throw BackendSessionFailure.invalidInput("The hidden launch command's limits or environment are invalid.")
                    }
                    let process = try BackendPTYProcess.spawn(command: command, args: arguments,
                        environment: environment, cwd: cwd, cols: 1_000, rows: 30, queue: queue)
                    let pending = Running(process: process, continuation: continuation, limit: outputLimit)
                    active[id] = pending
                    process.onData = { [weak self] bytes in
                        guard let self, let pending = self.active[id] else { return }
                        let remaining = pending.limit - pending.output.count
                        pending.output.append(bytes.prefix(max(remaining, 0)))
                        if bytes.count > remaining {
                            pending.outputLimited = true
                            pending.process.terminate()
                        }
                    }
                    process.onExit = { [weak self] code in
                        guard let pending = self?.active.removeValue(forKey: id) else { return }
                        pending.deadline?.cancel()
                        if cancellation.isCancelled { pending.continuation.resume(throwing: CancellationError()); return }
                        pending.continuation.resume(returning: Result(output: String(decoding: pending.output, as: UTF8.self),
                            exitCode: code, timedOut: pending.timedOut, outputLimited: pending.outputLimited))
                    }
                    let deadline = DispatchWorkItem { [weak self] in
                        guard let pending = self?.active[id] else { return }
                        pending.timedOut = true
                        pending.process.terminate()
                    }
                    pending.deadline = deadline
                    queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMilliseconds), execute: deadline)
                    process.start()
                } catch { continuation.resume(throwing: error) }
            }
        }
        } onCancel: {
            cancellation.cancel()
            self.queue.async { [self] in active[id]?.process.terminate() }
        }
    }
}
