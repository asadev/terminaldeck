import Foundation
import Testing
@testable import TerminalDeckBackend

/// Test clock records/fires callbacks; BackendTaskClock is the system under
/// test. Every settle waits for its supplied nextDue callback, never a sleep.
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
actor BackendCrmTaskClockParityState {
    var due: Double?, reads = 0, runs: [Double] = []
    private var readers: [(Int, CheckedContinuation<Void, Never>)] = []
    private var gate: CheckedContinuation<Void, Never>?, began: [CheckedContinuation<Void, Never>] = []
    init(due: Double?) { self.due = due }
    func setDue(_ value: Double?) { due = value }
    func read() -> Double? {
        reads += 1
        let ready = readers.filter { $0.0 <= reads }; readers.removeAll { $0.0 <= reads }; for (_, c) in ready { c.resume() }
        return due
    }
    func awaitReads(_ count: Int) async {
        if reads >= count { return }
        await withTaskCancellationHandler { await withCheckedContinuation { readers.append((count, $0)) } } onCancel: { Task { await self.cancelReceipts() } }
    }
    func cancelReceipts() { for (_, c) in readers { c.resume() }; readers = []; for c in began { c.resume() }; began = [] }
    func run(_ now: Double, block: Bool = false) async {
        runs.append(now); for c in began { c.resume() }; began = []
        if block { await withCheckedContinuation { gate = $0 } } else { due = nil }
    }
    func awaitStarted() async { if !runs.isEmpty { return }; await withTaskCancellationHandler { await withCheckedContinuation { began.append($0) } } onCancel: { Task { await self.cancelReceipts() } } }
    func release() { due = nil; gate?.resume(); gate = nil }
}

@Suite("task-clock.test.ts direct production clock parity")
struct BackendCrmTaskClockParityTests {
    func advance(_ milliseconds: Double, clock: BackendCrmTaskClockParityVirtualClock, state: BackendCrmTaskClockParityState) async {
        let until = clock.now() + milliseconds
        // This is bounded fake-event simulation, not a CPU/polling wait.
        for _ in 0..<100 {
            let reads = await state.reads
            if !clock.fireNext(until: until) { return }
            await state.awaitReads(reads + 2) // fire's read and its subsequent aim.
            if await state.due != nil { await clock.awaitTimers(1) }
        }
        #expect(false, "Unexpected unbounded native clock rearming")
    }
    @Test func c01NoTimerWithoutDueAndExactNextMoment() async throws {
        let clock = BackendCrmTaskClockParityVirtualClock(), state = BackendCrmTaskClockParityState(due: nil)
        try await BackendTaskClockContext.withClock(clock) {
            let sut = BackendTaskClock(nextDueAt: { await state.read() }, runDue: { await state.run(clock.now()) }, now: { clock.now() }, problem: { #expect(false, "\($0)") })
            await sut.start(); await state.awaitReads(2); #expect(clock.deadlines.isEmpty)
            await state.setDue(clock.now() + 90_000); await sut.poke()
            #expect(clock.deadlines.map { $0 - clock.now() } == [90_000])
            await advance(89_999, clock: clock, state: state); #expect(await state.runs.isEmpty)
            await advance(1, clock: clock, state: state); #expect(await state.runs.count == 1)
            #expect(clock.deadlines.isEmpty); await sut.stop()
        }
    }
    @Test func c02FarMomentUsesAtMostHourChunks() async throws {
        let clock = BackendCrmTaskClockParityVirtualClock(), state = BackendCrmTaskClockParityState(due: 1_000_000 + 5 * 3_600_000 + 1000)
        try await BackendTaskClockContext.withClock(clock) {
            let sut = BackendTaskClock(nextDueAt: { await state.read() }, runDue: { await state.run(clock.now()) }, now: { clock.now() }, problem: { #expect(false, "\($0)") })
            await sut.start(); await clock.awaitTimers(1)
            #expect(clock.deadlines.map { $0 - clock.now() } == [3_600_000])
            await advance(5 * 3_600_000, clock: clock, state: state)
            #expect(await state.runs.isEmpty && clock.deadlines.count == 1)
            await advance(1000, clock: clock, state: state); #expect(await state.runs.count == 1); await sut.stop()
        }
    }
    @Test func c03WakeCatchesUpAndStoppedClockDoesNothing() async throws {
        let clock = BackendCrmTaskClockParityVirtualClock(), state = BackendCrmTaskClockParityState(due: nil)
        try await BackendTaskClockContext.withClock(clock) {
            let sut = BackendTaskClock(nextDueAt: { await state.read() }, runDue: { await state.run(clock.now()) }, now: { clock.now() }, problem: { #expect(false, "\($0)") })
            await sut.start(); await state.awaitReads(2); await state.setDue(clock.now() + 3_600_000); await sut.poke()
            let reads = await state.reads; clock.set(clock.now() + 8 * 3_600_000); await sut.wake(); await state.awaitReads(reads + 2)
            #expect(await state.runs.count == 1); await sut.stop(); await state.setDue(clock.now() + 1000)
            await sut.poke(); await sut.wake(); await advance(10_000, clock: clock, state: state)
            #expect(await state.runs.count == 1 && clock.deadlines.isEmpty)
        }
    }
    @Test func c04WakeDuringRunWaitsAndReaimsOnce() async throws {
        let clock = BackendCrmTaskClockParityVirtualClock(), state = BackendCrmTaskClockParityState(due: 0)
        clock.set(5000)
        try await BackendTaskClockContext.withClock(clock) {
            let sut = BackendTaskClock(nextDueAt: { await state.read() }, runDue: { await state.run(clock.now(), block: true) }, now: { clock.now() }, problem: { #expect(false, "\($0)") })
            await sut.start(); await state.awaitStarted(); await sut.wake(); await sut.poke()
            #expect(await state.runs.count == 1)
            await state.release(); await state.awaitReads(2)
            #expect(await state.runs.count == 1 && clock.deadlines.isEmpty); await sut.stop()
        }
    }
}
