import Foundation

// Siri / Shortcuts (lane R): answering within Siri's time.
//
// Siri waits a few seconds, not minutes. Every intent runs against a budget:
// work that finishes inside it is the answer; work that does not keeps running
// (it is never cancelled for being slow) and the intent says so instead.

public enum IntentDeadline {
    public enum Outcome<Value: Sendable>: Sendable {
        case finished(Value)
        case timedOut
    }

    /// Siri's whole answer, engine start included, for an ask that waits on an agent.
    public static let askBudget: Duration = .seconds(22)
    /// A read (what needs me, a goal, a picker's list).
    public static let readBudget: Duration = .seconds(15)
    /// The engine starting from cold before anything can be asked.
    public static let engineStart: Duration = .seconds(14)

    /// Waits for `task` up to `limit`. On time: its value. Late: `.timedOut`, and
    /// the task carries on untouched — the caller can still await it.
    public static func wait<Value: Sendable>(for task: Task<Value, Never>, upTo limit: Duration) async -> Outcome<Value> {
        let gate = OnceGate<Outcome<Value>>()
        return await withCheckedContinuation { continuation in
            gate.arm(continuation)
            let timer = Task {
                try? await Task.sleep(for: limit)
                gate.resume(.timedOut)
            }
            gate.onResolve { timer.cancel() }
            Task {
                let value = await task.value
                gate.resume(.finished(value))
            }
        }
    }

    /// Checks `condition` every `step` until it holds (true) or `limit` passes (false).
    /// For in-process state that has no event of its own; never for the network.
    public static func until(_ limit: Duration, every step: Duration = .milliseconds(100),
                             _ condition: @Sendable () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: limit)
        while true {
            if await condition() { return true }
            if clock.now >= end || Task.isCancelled { return false }
            try? await Task.sleep(for: min(step, end - clock.now))
        }
    }
}

/// A time allowance shared by the steps of one intent.
public struct IntentBudget: Sendable {
    private let end: ContinuousClock.Instant

    public init(_ total: Duration) {
        end = ContinuousClock().now.advanced(by: total)
    }

    /// What is left (never negative), or `cap` if that is less.
    public func remaining(cap: Duration? = nil) -> Duration {
        let left = max(.zero, end - ContinuousClock().now)
        if let cap { return min(cap, left) }
        return left
    }

    public var isSpent: Bool { remaining() == .zero }
}

/// Resumes a continuation exactly once, whichever side gets there first.
private final class OnceGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var pending: Value?
    private var resolved = false
    private var cleanup: (() -> Void)?

    func arm(_ continuation: CheckedContinuation<Value, Never>) {
        lock.lock()
        if let pending {
            self.pending = nil
            lock.unlock()
            continuation.resume(returning: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func onResolve(_ action: @escaping () -> Void) {
        lock.lock()
        if resolved { lock.unlock(); action(); return }
        cleanup = action
        lock.unlock()
    }

    func resume(_ value: Value) {
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        resolved = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil { pending = value }
        let action = cleanup
        cleanup = nil
        lock.unlock()
        continuation?.resume(returning: value)
        action?()
    }
}
