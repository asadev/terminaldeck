import Foundation
import Observation
import TerminalDeckNativeCore

/// Tasks, for every native screen that shows them (the Tasks page, its popup,
/// Overview's CRM tasks, Settings → Tasks): one read of `tasks:state`, read again
/// whenever the engine says `tasks:changed`, and every change sent on the same
/// channels the page uses (`tasks:*`), answered with the new state or a sentence.
@MainActor
@Observable
final class TasksStore {
    static let shared = TasksStore()

    enum Phase: Equatable {
        /// Before the first read answers.
        case loading
        /// The engine did not answer.
        case failed
        case ready(TasksState)
    }

    private(set) var phase: Phase = .loading
    /// A change is on its way.
    private(set) var busy = false
    /// The last refusal, shown as written; nil after a change that went through.
    var problem: String?
    /// A reminder for a task was clicked (`tasks:open`): its id, and when it was asked.
    private(set) var openRequest: (id: String, at: Date)?

    @ObservationIgnored private var started = false
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private var loading: Task<Void, Never>?

    var state: TasksState? {
        if case .ready(let state) = phase { return state }
        return nil
    }

    private init() {}

    /// Listen once for the engine's pushes, and read now.
    func start() {
        if !started {
            started = true
            let bridge = EngineBridge.shared
            subscriptions.append(bridge.on("tasks:changed") { _ in
                Task { @MainActor in TasksStore.shared.reload() }
            })
            subscriptions.append(bridge.on("tasks:open") { args in
                guard let id = args.first as? String, !id.isEmpty else { return }
                Task { @MainActor in
                    // Lane TK: a task in another project moves the window to that project first.
                    TKTasksProjectScope.shared.reveal(id, in: TasksStore.shared.state)
                    TasksStore.shared.openRequest = (id, Date())
                }
            })
        }
        reload()
    }

    func reload() {
        loading?.cancel()
        loading = Task { [weak self] in
            do {
                let raw = try await EngineBridge.shared.invoke("tasks:state")
                guard !Task.isCancelled else { return }
                if let state = TasksDecode.state(raw) { self?.phase = .ready(state) } else { self?.phase = .failed }
            } catch {
                guard !Task.isCancelled else { return }
                // Not up yet: stay loading and read again when it is; up but no answer: say so.
                if EngineBridge.shared.isReady { self?.phase = .failed }
            }
        }
    }

    /// An answer's new state redraws everything that shows tasks.
    func adopt(_ result: TasksResult) {
        if let state = result.state { phase = .ready(state) }
    }

    func clearOpenRequest() { openRequest = nil }

    /// Linked tasks can live in another project; reveal that project before opening.
    func openTask(_ id: String) {
        TKTasksProjectScope.shared.reveal(id, in: state)
        openRequest = (id, Date())
    }

    // MARK: Calls

    /// One call on a `tasks:*` channel, as a result: never a throw.
    func call(_ channel: String, _ args: [Any?] = [], refusal: String = "This build cannot change tasks.") async -> TasksResult {
        guard EngineBridge.shared.isReady else { return .refused(refusal) }
        do {
            return TasksDecode.result(try await EngineBridge.shared.invoke(channel, args))
        } catch {
            return .refused(error.localizedDescription)
        }
    }

    /// Run one change: busy while it runs; the new state redraws the page; a refusal
    /// is kept to be shown as written. True when it went through.
    @discardableResult
    func run(_ work: () async -> TasksResult) async -> Bool {
        busy = true
        defer { busy = false }
        let result = await work()
        adopt(result)
        problem = result.ok ? nil : (result.message ?? "That did not save.")
        return result.ok
    }

    // MARK: Your tasks (TasksPage's `tasksActions`)

    /// A new task: the form's defaults, then what was given; checked here first.
    func create(_ input: [String: Any]) async -> TasksResult {
        // Lane TK: a task made here belongs to the current project unless it names one.
        var draft: [String: Any] = ["title": "", "instructions": "", "project": TKTasksProjectScope.shared.newTaskProject, "assignee": "none", "status": "To-Do"]
        draft.merge(input) { _, new in new }
        var local = LocalDraft(nil, statuses: [])
        local.title = draft["title"] as? String ?? ""
        local.instructions = draft["instructions"] as? String ?? ""
        local.project = draft["project"] as? String ?? ""
        local.assignee = draft["assignee"] as? String ?? "none"
        local.status = draft["status"] as? String ?? "To-Do"
        local.goalId = draft["goalId"] as? String ?? ""
        switch local.payload(agents: state?.agents ?? []) {
        case .failure(let problem):
            return .refused(problem.message)
        case .success(var payload):
            if input["goalId"] == nil { payload.removeValue(forKey: "goalId") }
            draft.merge(payload) { _, new in new }
            return await call("tasks:local-create", [draft])
        }
    }

    func update(_ id: String, _ patch: [String: Any]) async -> TasksResult { await call("tasks:local-update", [id, patch]) }
    func remove(_ id: String) async -> TasksResult { await call("tasks:local-delete", [id]) }
    func restore(_ id: String) async -> TasksResult { await call("tasks:local-restore", [id]) }

    func reply(_ id: String, _ text: String) async -> TasksResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .refused("Write a reply first.") }
        return await call("tasks:local-reply", [id, trimmed])
    }

    func closeSession(_ id: String) async -> TasksResult { await call("tasks:close-session", [id]) }

    // MARK: Goals

    func saveGoal(_ input: [String: Any]) async -> TasksResult {
        await call("tasks:goal-save", [input], refusal: "This build cannot change goals.")
    }

    func removeGoal(_ id: String) async -> TasksResult {
        await call("tasks:goal-remove", [id], refusal: "This build cannot change goals.")
    }
}
