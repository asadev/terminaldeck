import Foundation
import Testing
@testable import TerminalDeckBackend

/// Test clock that records and fires callbacks; the task tests' settles wait on
/// their supplied callbacks, never a sleep.
final class BackendCrmTaskClockParityVirtualClock: BackendDeckCoreEventsClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time: Double = 1_000_000
    private var timers: [UUID: (Double, @Sendable () -> Void)] = [:]
    private var timerWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var readStep = 0.0
    func now() -> Double { lock.withLock { time += readStep; return time } }
    func schedule(after milliseconds: Double, _ run: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            timers[id] = (time + milliseconds, run)
            let ready = timerWaiters.filter { $0.0 == timers.count }.map(\.1)
            timerWaiters.removeAll { $0.0 == timers.count }; return ready
        }
        for continuation in ready { continuation.resume() }; return id
    }
    func cancel(_ id: UUID) { _ = lock.withLock { timers.removeValue(forKey: id) } }
    func set(_ value: Double) { lock.withLock { time = value } }
    func setReadStep(_ value: Double) { lock.withLock { readStep = value } }
    func awaitTimers(_ count: Int) async {
        await withTaskCancellationHandler { await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if timers.count == count { return true }; timerWaiters.append((count, continuation)); return false
            }
            if ready { continuation.resume() }
        } } onCancel: {
            let pending = self.lock.withLock { let all = self.timerWaiters.map(\.1); self.timerWaiters = []; return all }
            for c in pending { c.resume() }
        }
    }
    var deadlines: [Double] { lock.withLock { timers.values.map(\.0).sorted() } }
    func fireNext(until: Double) -> Bool {
        let callback: (@Sendable () -> Void)? = lock.withLock {
            guard let next = timers.min(by: { $0.value.0 < $1.value.0 }), next.value.0 <= until else { time = until; return nil }
            timers[next.key] = nil; time = next.value.0; return next.value.1
        }
        callback?(); return callback != nil
    }
}
