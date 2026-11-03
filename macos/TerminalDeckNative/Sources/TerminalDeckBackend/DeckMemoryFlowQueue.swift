import Foundation
import TerminalDeckNativeCore

/// What a job's run came to.
public enum DeckMemoryFlowJobResult: Sendable, Equatable {
    case done
    /// There is more to read for the same subject: run again after this many milliseconds.
    case again(afterMilliseconds: Double)
    /// Nothing is lost (the diary has it). The queue tries again later and keeps the reason.
    case failed(String)
}

/// The helper's waiting line. It only decides WHEN a job runs: one job per session, pushed
/// back while new turns keep ending (debounce), at most one or two running at once, kept
/// on disk through `persist` so a restart loses nothing. One one-shot timer is armed for
/// the next due job; nothing scans on a schedule.
public actor DeckMemoryFlowQueue {
    public typealias Run = @Sendable (DeckMemoryFlowJob) async -> DeckMemoryFlowJobResult
    /// Waits between tries after a failure; after the last one the job rests until the next
    /// signal for its subject, "Run now", or the next launch.
    public static let retryDelays: [Double] = [60_000, 300_000, 1_800_000, 7_200_000, 7_200_000]

    private var jobs: [DeckMemoryFlowJob]
    private var running: [String: DeckMemoryFlowJob] = [:]
    private var rerun: [String: Double] = [:]
    private var timer: UUID?
    private var timerDue: Double?
    private var parallel: Int
    private var started = false
    private let clock: any BackendDeckCoreEventsClock
    private let run: Run
    private let persist: @Sendable ([DeckMemoryFlowJob]) async -> Void
    private let changed: @Sendable () -> Void
    private let hops = DeckMemoryFlowHops()

    public init(jobs: [DeckMemoryFlowJob] = [], clock: any BackendDeckCoreEventsClock, parallel: Int = 1, run: @escaping Run,
                persist: @escaping @Sendable ([DeckMemoryFlowJob]) async -> Void = { _ in },
                changed: @escaping @Sendable () -> Void = {}) {
        self.jobs = jobs; self.clock = clock; self.parallel = min(2, max(1, parallel)); self.run = run
        self.persist = persist; self.changed = changed
    }

    /// Jobs left from before a restart run again after `pause`; a job that was resting is revived.
    public func start(revivingAfter pause: Double) async {
        guard !started else { return }
        started = true
        let now = clock.now()
        for index in jobs.indices where jobs[index].dueAt == nil || (jobs[index].dueAt ?? 0) < now + pause {
            jobs[index].dueAt = now + pause
        }
        await save(); arm()
    }
    public func stop() {
        started = false
        if let timer { clock.cancel(timer) }
        timer = nil; timerDue = nil
    }
    public func setParallel(_ count: Int) { parallel = min(2, max(1, count)); pump() }

    /// A turn ended (or a tidy-up is due). The same subject asked again pushes its job back:
    /// the helper reads once, after things have gone quiet.
    public func submit(_ job: DeckMemoryFlowJob, after pause: Double) async {
        let due = clock.now() + max(0, pause)
        if running[job.id] != nil { rerun[job.id] = due; return }
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index].dueAt = due
            if !job.title.isEmpty { jobs[index].title = job.title }
        } else {
            var fresh = job; fresh.dueAt = due; jobs.append(fresh)
        }
        await save(); arm()
    }
    /// The session is working again: its job waits for the next turn end, but never without a
    /// due time. If that turn end never comes (the sign of work was a stray one after the last
    /// turn, or the turn died), the job runs when `wait` is over. Only ever later, never sooner.
    public func hold(_ id: String, atMost wait: Double) async {
        guard let index = jobs.firstIndex(where: { $0.id == id }), running[id] == nil else { return }
        // A job that gave up after its last retry rests; a new turn end or "Run now" revives it.
        if jobs[index].dueAt == nil, jobs[index].attempts > 0 { return }
        let due = clock.now() + max(0, wait)
        if let current = jobs[index].dueAt, current >= due { return }
        jobs[index].dueAt = due
        await save(); arm()
    }
    /// The session went quiet again with no turn end told (it stopped to ask, went idle, or the
    /// sign of work was a stray one): a held job runs after the usual pause, not after its long
    /// wait. Only ever sooner. A job waiting for its next try after a failure keeps that wait.
    public func release(_ id: String, after pause: Double) async {
        guard let index = jobs.firstIndex(where: { $0.id == id }), running[id] == nil, jobs[index].attempts == 0 else { return }
        let due = clock.now() + max(0, pause)
        if let current = jobs[index].dueAt, current <= due { return }
        jobs[index].dueAt = due
        await save(); arm()
    }
    /// "Run now": due at once, and a resting or failed job gets a fresh start.
    public func runNow(_ id: String) async {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].dueAt = clock.now(); jobs[index].attempts = 0
        await save(); arm()
    }
    /// Jobs that gave up after their last retry (the nightly pass, or "Run now", gives them a fresh start).
    public func reviveResting() async {
        var revived = false
        for index in jobs.indices where jobs[index].dueAt == nil && jobs[index].attempts > 0 && running[jobs[index].id] == nil {
            jobs[index].dueAt = clock.now(); jobs[index].attempts = 0; revived = true
        }
        if revived { await save(); arm() }
    }
    public func remove(_ id: String) async {
        jobs.removeAll { $0.id == id && running[id] == nil }
        await save(); arm()
    }
    public func waiting() -> [DeckMemoryFlowJob] { jobs.filter { running[$0.id] == nil } }
    public func runningJobs() -> [DeckMemoryFlowJob] { Array(running.values).sorted { $0.id < $1.id } }
    public func contains(_ id: String) -> Bool { jobs.contains { $0.id == id } }
    public var isBusy: Bool { !running.isEmpty }

    /// For checks: every timer hop and every running job has finished.
    public func settle() async {
        while true {
            let pending = hops.take()
            if pending.isEmpty { return }
            for task in pending { await task.value }
        }
    }

    private func arm() {
        guard started else { return }
        pump()
        let next = jobs.filter { running[$0.id] == nil }.compactMap(\.dueAt).min()
        guard let next, running.count < parallel else {
            if let timer { clock.cancel(timer) }
            timer = nil; timerDue = nil; return
        }
        if timerDue == next, timer != nil { return }
        if let timer { clock.cancel(timer) }
        timerDue = next
        let hops = hops
        timer = clock.schedule(after: max(0, next - clock.now())) { [weak self] in
            hops.add { [weak self] in await self?.fired() }
        }
    }
    private func fired() { timer = nil; timerDue = nil; arm() }

    private func pump() {
        guard started else { return }
        let now = clock.now()
        while running.count < parallel,
              let next = jobs.filter({ running[$0.id] == nil && ($0.dueAt ?? .infinity) <= now }).min(by: { ($0.dueAt ?? 0, $0.createdAt) < ($1.dueAt ?? 0, $1.createdAt) }) {
            running[next.id] = next
            changed()
            let run = run
            hops.add { [weak self] in
                let result = await run(next)
                await self?.finished(next.id, result)
            }
        }
    }

    private func finished(_ id: String, _ result: DeckMemoryFlowJobResult) async {
        running[id] = nil
        let again = rerun.removeValue(forKey: id)
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            switch result {
            case .done:
                if let again { jobs[index].dueAt = again; jobs[index].attempts = 0; jobs[index].lastError = nil }
                else { jobs.remove(at: index) }
            case .again(let after):
                jobs[index].dueAt = max(again ?? 0, clock.now() + max(0, after)); jobs[index].attempts = 0; jobs[index].lastError = nil
            case .failed(let reason):
                jobs[index].attempts += 1; jobs[index].lastError = reason
                let tries = jobs[index].attempts
                jobs[index].dueAt = tries <= Self.retryDelays.count ? clock.now() + Self.retryDelays[tries - 1] : nil
            }
        }
        await save(); changed(); arm()
    }

    private func save() async { await persist(jobs) }
}

/// Tasks started from outside the actor (a timer firing, a job running), kept so a check
/// can wait for the real work instead of sleeping and hoping.
final class DeckMemoryFlowHops: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    var count: Int { lock.withLock { tasks.count } }
    func add(_ work: @escaping @Sendable () async -> Void) {
        let id = UUID()
        // Register while locked: even a task that finishes immediately cannot remove itself first.
        lock.withLock {
            tasks[id] = Task {
                await work()
                self.lock.withLock { _ = self.tasks.removeValue(forKey: id) }
            }
        }
    }
    func take() -> [Task<Void, Never>] { lock.withLock { Array(tasks.values) } }
}
