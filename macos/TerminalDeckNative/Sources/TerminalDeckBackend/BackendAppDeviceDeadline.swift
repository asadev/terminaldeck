import Foundation
import TerminalDeckNativeCore

/// Devices freeze (Asad, 26 Oct 2026: every devices_* tool timed out, devices_attached included, while the
/// phone picture kept moving). Cause, seen live: an `adb devices` the device list ran had exited, but the app
/// never reaped it (it stayed a zombie child of the app for hours), so the standard child runner never
/// reported its end. The device list waited for it forever, and every device tool and phone-panel call waits
/// for that one shared list, so one lost child froze them all until the app restarted.
///
/// Every device step now has an outer deadline of its own, kept here: past it the caller gets a plain
/// answer and goes on, the step is cancelled, and nothing it was waiting for can hold the next call. A
/// caller that is cancelled (its tool call timed out) stops waiting at once and cancels the step.
public enum BackendAppDeviceDeadline {
    /// A step that did not answer by its deadline. The words reach the AI or the panel as they are.
    public struct Expired: Error, LocalizedError, Sendable, Equatable {
        public let what: String
        public init(_ what: String) { self.what = what }
        public var errorDescription: String? { "\(what) did not answer in time, so Terminal Deck stopped waiting for it. Try again." }
    }

    /// How long past a command's own limit its caller still waits: the limit itself, then SIGTERM, a
    /// 1 s grace, SIGKILL and the exit report. Past this the command's end is lost, not late.
    public static let commandGraceMilliseconds = 3_000

    /// `work`'s answer, or `Expired` after `seconds`. Cancelling the caller cancels `work` and ends the
    /// wait at once; `work` that ignores cancellation is left to finish on its own, with nobody waiting.
    public static func run<T: Sendable>(within seconds: Double, _ what: String,
                                        _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let race = Race<T>()
        let job = Task { try await work() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (answer: CheckedContinuation<T, any Error>) in
                race.arm(answer)
                let timer = Task {
                    do { try await Task.sleep(for: .seconds(max(0, seconds))) } catch { return }
                    if race.finish(.failure(Expired(what))) { job.cancel() }
                }
                race.hold(timer)
                Task {
                    let result = await job.result
                    race.finish(result)
                }
            }
        } onCancel: {
            job.cancel()
            race.finish(.failure(CancellationError()))
        }
    }

    /// A device command through `executor`, never waited for past its own limit plus `graceMilliseconds`.
    /// A lost or late end answers as a killed run (not ok), the way a command past its limit always has.
    public static func command(_ executor: any BackendAppSessionCommandExecuting, _ command: String, arguments: [String],
                               environment: [String: String], cwd: String, timeoutMilliseconds: Int, maximumBytes: Int,
                               graceMilliseconds: Int = commandGraceMilliseconds) async -> BackendAppSessionCommandResult {
        let name = (command as NSString).lastPathComponent
        do {
            return try await run(within: Double(max(0, timeoutMilliseconds) + max(0, graceMilliseconds)) / 1_000, "The device command \(name)") {
                await executor.run(command, arguments: arguments, environment: environment, cwd: cwd,
                                   timeoutMilliseconds: timeoutMilliseconds, maximumBytes: maximumBytes)
            }
        } catch {
            return BackendAppSessionCommandResult(stderr: error.localizedDescription, killed: true)
        }
    }

    /// One answer, first come: the step, its deadline or the caller going away. Safe from any thread, and
    /// in any order: an answer that comes before the waiter is armed is kept for it.
    private final class Race<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var waiter: CheckedContinuation<T, any Error>?
        private var early: Result<T, any Error>?
        private var settled = false
        private var timer: Task<Void, Never>?

        func arm(_ continuation: CheckedContinuation<T, any Error>) {
            lock.lock()
            if let early { self.early = nil; lock.unlock(); continuation.resume(with: early); return }
            waiter = continuation
            lock.unlock()
        }

        func hold(_ timer: Task<Void, Never>) {
            lock.lock()
            let done = settled
            if !done { self.timer = timer }
            lock.unlock()
            if done { timer.cancel() }
        }

        /// True for the answer that won.
        @discardableResult
        func finish(_ result: Result<T, any Error>) -> Bool {
            lock.lock()
            guard !settled else { lock.unlock(); return false }
            settled = true
            let continuation = waiter, timer = self.timer
            waiter = nil; self.timer = nil
            if continuation == nil { early = result }
            lock.unlock()
            timer?.cancel()
            continuation?.resume(with: result)
            return true
        }
    }
}
