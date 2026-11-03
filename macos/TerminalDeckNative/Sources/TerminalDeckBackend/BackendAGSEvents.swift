import Foundation
import TerminalDeckNativeCore

/// INT2 connects these methods to accepted backend events, never page/MCP input.
/// The hook payload intentionally carries identities only, without task text,
/// Receiver bodies, environment values, addresses or account credentials.
public actor BackendAGSEvents {
    private let store: BackendAGSStore, runner: BackendAGSHookRunner
    private let problem: @Sendable (String) async -> Void
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var stopped = false
    public init(store: BackendAGSStore, runner: BackendAGSHookRunner, problem: @escaping @Sendable (String) async -> Void = { _ in }) {
        self.store = store; self.runner = runner; self.problem = problem
    }
    public func session(_ event: BackendSessionLifecycleEvent) async {
        switch event {
        case .created(let session): await deliver(id: "session-started:" + session.id, event: "session.started", subject: session.id)
        case .replaced(_, let session, _): await deliver(id: "session-started:" + session.id, event: "session.started", subject: session.id)
        case .process(.exit(let id, _)), .process(.removed(let id, _)):
            await deliver(id: "session-finished:" + id, event: "session.finished", subject: id)
        default: break
        }
    }
    public func task(_ notification: NativeRPCValue) async {
        guard BackendTAGTaskNotifications.valid(notification), notification["type"].string == "task.finished",
              let id = notification["id"].string, let task = notification["taskId"].string else { return }
        await deliver(id: id, event: "task.finished", subject: task)
    }
    public func alert(id: String) async { await deliver(id: "alert:" + id, event: "alert.raised", subject: id) }
    public func receiver(id: String) async { await deliver(id: "receiver:" + id, event: "receiver.event", subject: id) }
    private func deliver(id: String, event: String, subject: String) async {
        guard !stopped else { return }
        guard jobs.count < 128 else { await problem("Terminal Deck hooks skipped an accepted event because their bounded queue is full."); return }
        let hooks: [AGSAppHook]
        do { hooks = try await store.defaults().hooks }
        catch { await problem("Terminal Deck hooks are unavailable because their private settings could not be read."); return }
        guard !stopped else { return }
        guard jobs.count < 128 else { await problem("Terminal Deck hooks skipped an accepted event because their bounded queue is full."); return }
        let token = UUID(), runner = self.runner
        jobs[token] = Task { [weak self] in
            _ = await runner.deliver(.init(id: id, event: event, subjectID: subject), hooks: hooks)
            await self?.finished(token)
        }
    }
    private func finished(_ token: UUID) { jobs[token] = nil }
    public func stop() async {
        stopped = true
        let pending = Array(jobs.values); jobs = [:]
        for job in pending { job.cancel() }
        await runner.stop()
        for job in pending { await job.value }
    }
}
