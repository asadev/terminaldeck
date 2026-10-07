import Foundation

/// task-clock.ts: one timer at the actual next due moment; changes and wake
/// events re-aim it. The runtime owner may combine task/detail deadlines here.
public actor BackendTaskClock {
    private let nextDue: @Sendable () async throws -> Double?
    private let runDue: @Sendable () async throws -> Void
    private let now: @Sendable () -> Double
    private let problem: @Sendable (String) async -> Void
    private var stopped = true, running = false, timer: BackendTaskTimer?, run: Task<Void, Never>?
    public init(nextDueAt: @escaping @Sendable () async throws -> Double?, runDue: @escaping @Sendable () async throws -> Void,
                now: @escaping @Sendable () -> Double = { BackendTaskClockContext.clock.now() }, problem: @escaping @Sendable (String) async -> Void) {
        nextDue = nextDueAt; self.runDue = runDue; self.now = now; self.problem = problem
    }
    public func start() { guard stopped else { return }; stopped = false; wake() }
    public func stop() async { stopped = true; timer?.cancel(); timer = nil; run?.cancel(); if let run { await run.value }; self.run = nil }
    public func poke() async { guard !stopped, !running else { return }; await aim() }
    public func wake() {
        guard !stopped, !running else { return }; running = true; timer?.cancel(); timer = nil
        run = Task { [weak self] in await self?.fire() }
    }
    private func fire() async {
        do { if !stopped, let next = try await nextDue(), next <= now() { try Task.checkCancellation(); try await runDue() } }
        catch is CancellationError {} catch { await problem("The task clock run failed: " + error.localizedDescription) }
        running = false; run = nil; await aim()
    }
    private func aim() async {
        timer?.cancel(); timer = nil; guard !stopped else { return }
        do {
            if let next = try await nextDue(), !stopped, !running {
                let delay = Int(min(max(0, next - now()), 3_600_000))
                timer = BackendTaskTimers.schedule(milliseconds: Double(delay)) { [weak self] in await self?.wake() }
            }
        } catch { await problem("The task clock could not read what is due: " + error.localizedDescription) }
    }
}
