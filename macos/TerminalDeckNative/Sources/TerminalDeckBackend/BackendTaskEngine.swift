import Foundation
import TerminalDeckNativeCore

public actor BackendTaskEngine: BackendTaskExecuting {
    public let store: BackendTaskStore
    private let config: BackendTaskConfiguration, goals: BackendGoalStore, access: BackendTaskSessionAccess
    private let workspace: @Sendable (BackendTaskRecord) async throws -> String
    private let knowledge: (@Sendable (BackendTaskRecord) async throws -> String)?
    private let knowledgeAdapter: BackendTaskKnowledgeAdapter?
    private var localStatusObserver: (@Sendable (String, String) async -> Void)?
    private var notifications: (@Sendable (BackendTaskRecord, NativeRPCValue) async throws -> Void)?
    /// Actual CRM outbox adapter must be supplied for mirrored task effects.
    private let outgoing: (@Sendable (BackendTaskRecord, NativeRPCValue) async throws -> Void)?
    private let problem: @Sendable (String) async -> Void
    private let settings: (@Sendable (NativeRPCValue) async throws -> AGSAgentSettings)?
    private let profileID: (@Sendable (NativeRPCValue, String) async throws -> String?)?
    private let usageBaseline: (@Sendable (BackendSessionMeta) async throws -> Double?)?
    private let runtimeAccess: BackendAGOPTAgentRuntimeAccess, runCalendar: Calendar
    private var observedStatus: [String: BackendSessionStatus] = [:]
    private var pumpWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopped = true, pumping = false, starting = Set<String>(), closing = Set<String>()
    /// U70: the folder each launch in progress will hold (by task id), so the queue can go on while it starts.
    private var launchFolders: [String: String] = [:]
    /// Only tasks this engine start actually interrupted. Kept until Hoot wakes, without a time limit.
    private var restartTasks: [String: BackendTaskRecord] = [:]
    private var checks: [String: Task<(ok: Bool, output: String), any Error>] = [:], checkGenerations: [String: UUID] = [:]
    private var quiet: [String: Double] = [:], timer: BackendTaskTimer?, jobs: [String: Task<Void, any Error>] = [:]
    // FORK-TASKS (11 Oct): a task given to Hoot is worked as a "task turn" in Hoot's chat (no user bubble
    // there) and Hoot's words come back here to be posted as ITS comments on the task. nil = no such chat
    // is bound (tests, an older wiring): Hoot is told in one line through `access.tellHoot`, as before.
    public typealias HootTaskTurns = @Sendable (BackendHootTaskTurn, @escaping @Sendable (BackendHootTaskProgress) async -> Void) async throws -> BackendHootTaskResult
    enum HootTurnKind: Sendable { case assigned, comment, notice }
    private struct HootLive: Sendable { let token: UUID; var startedAt: Double?; var step: String?; var said: [String] = [] }
    private var hootTurns: HootTaskTurns?, hootChain: Task<Void, Never>?, hootJobs: [UUID: Task<Void, Never>] = [:], hootLive: [String: HootLive] = [:], hootWaiting: [String: Int] = [:]
    private var projectName: (@Sendable (BackendTaskRecord) async -> String?)?
    /// SETTINGS-TRUTH rows 42/46: lines about the task's project the holder should know (its linked servers).
    private var projectNote: (@Sendable (BackendTaskRecord) async -> String?)?
    /// PLAYBOOK-SEATS: the playbook row for a task's job, and an agent's own profile before the app defaults.
    private var playbookRow: (@Sendable (BackendTaskRecord) async -> DeckMemoryPlaybookRow?)?
    private var ownSettings: (@Sendable (NativeRPCValue) async throws -> AGSAgentSettings?)?
    /// PARALLEL-JOBS: an agent's jobs at once, each in its own copy (BackendParallelJobs). Nil: as before.
    private var parallel: BackendParallelJobs?
    /// Stops Hoot's background turn for a task id (L6 cancelBackgroundTurn); each stop also moves the task's
    /// epoch on, so a turn queued for it before the stop is never started.
    private var hootStop: (@Sendable (String) async -> Void)?, hootEpoch: [String: Int] = [:]
    /// True once the app has begun to close (T19). A turn the close cut short keeps the task's mark, so the
    /// next start says what happened and the app goes on with it, instead of "Hoot was stopped … ask it again".
    private var hootClosing: (@Sendable () async -> Bool)?
    private func appClosing() async -> Bool { await hootClosing?() ?? false }
    /// Starts that were waiting on Claude Code's own setup screen and are being tried now (by task id).
    private var setupStarts: [String: Task<Void, Never>] = [:]
    /// For orderly callers and tests: every such start that was being tried has ended.
    public func settleSetupStarts() async { for job in Array(setupStarts.values) { await job.value }; setupStarts.removeAll() }
    public init(store: BackendTaskStore, configuration: BackendTaskConfiguration, goals: BackendGoalStore, access: BackendTaskSessionAccess,
                workspace: @escaping @Sendable (BackendTaskRecord) async throws -> String,
                knowledge: (@Sendable (BackendTaskRecord) async throws -> String)? = nil,
                knowledgeAdapter: BackendTaskKnowledgeAdapter? = nil,
                outgoing: (@Sendable (BackendTaskRecord, NativeRPCValue) async throws -> Void)? = nil,
                notifications: (@Sendable (BackendTaskRecord, NativeRPCValue) async throws -> Void)? = nil,
                settings: (@Sendable (NativeRPCValue) async throws -> AGSAgentSettings)? = nil,
                profileID: (@Sendable (NativeRPCValue, String) async throws -> String?)? = nil,
                usageBaseline: (@Sendable (BackendSessionMeta) async throws -> Double?)? = nil,
                runtime: BackendAGOPTAgentRuntimeAccess = .init(), calendar: Calendar = .current,
                problem: @escaping @Sendable (String) async -> Void) throws {
        guard access.readiness == .ready else { throw BackendSessionFailure.missingCapability("task execution through the actual session/grant/delivery owner") }
        self.store = store; config = configuration; self.goals = goals; self.access = access
        self.workspace = workspace; self.knowledge = knowledge; self.knowledgeAdapter = knowledgeAdapter; self.outgoing = outgoing; self.notifications = notifications; self.problem = problem; self.settings = settings; self.profileID = profileID; self.usageBaseline = usageBaseline; self.runtimeAccess = runtime; self.runCalendar = calendar
    }
    private var hostedTaskChats: @Sendable () async -> Set<String> = { [] }
    private var businessDecision: (@Sendable (BackendTaskRecord) async -> String?)?
    /// Release tokens already used, by task (U140 #362: dropped when the task is deleted or can no longer start).
    private var decisionNudges: [String: Set<String>] = [:]
    private var decisionSafeHoot = false, decisionSafeLead = false
    public func setBusinessDecision(_ check: @escaping @Sendable (BackendTaskRecord) async -> String?) { businessDecision = check }
    public func setDecisionExecutionOwners(hoot: Bool, lead: Bool) { decisionSafeHoot = hoot; decisionSafeLead = lead }
    public func decisionReason(_ id: String, sending: Bool = false) async -> String? {
        guard let task = try? await store.byID(id) else { return "This task no longer exists." }
        guard PCDecisions.requires(task.value) else { return await businessDecision?(task) }
        guard !stopped else { return "Task execution stopped while this decision was waiting. Work is held." }
        guard PCDecisions.eligible(task.value) else { return "This required decision is attached to an unsupported connected/CRM task; work is held." }
        if task.value["stopped"].bool == true || !task.value["archivedAt"].isNullish || !task.value["completedAt"].isNullish || !task.value["result"].isNullish { return "This task is stopped, archived or finished. Approval does not reopen it." }
        guard let businessDecision else { return "Required decision storage is unavailable; work is held." }
        let fingerprint = BackendPCDecisionMarker.fingerprint(task)
        if let reason = await businessDecision(task) { return reason }
        guard let current = try? await store.byID(id), BackendPCDecisionMarker.fingerprint(current) == fingerprint else { return "The task changed while its decision was checked." }
        guard !stopped, PCDecisions.requires(current.value), PCDecisions.eligible(current.value), current.value["stopped"].bool != true,
              current.value["archivedAt"].isNullish, current.value["completedAt"].isNullish, current.value["result"].isNullish else {
            return "This task stopped, finished or changed its decision eligibility during validation. Work is held."
        }
        let capable = current.assigneeKind == "agent" ? (sending ? access.decisionSafeSend : access.decisionSafeStart)
            : current.assigneeKind == "hoot" ? decisionSafeHoot : current.assigneeKind == "seat" ? decisionSafeLead : false
        guard capable else {
            return "Approved but held: final execution validation unavailable for this task owner. NEEDS-HELPER."
        }
        return nil
    }
    public func decisionAllowed(_ id: String, sending: Bool = false) async -> Bool {
        let reason = await decisionReason(id, sending: sending)
        if let task = try? await store.byID(id), PCDecisions.requires(task.value), task.value["decisionHold"].string != reason {
            _ = try? await store.update(id, patch: .object([.init("decisionHold", reason.map(NativeRPCValue.string) ?? .null)]))
        }
        return reason == nil
    }
    private func requireDecision(_ id: String, expected: BackendTaskRecord? = nil, sending: Bool = false) async throws {
        if let expected, PCDecisions.requires(expected.value) {
            guard let current = try await store.byID(id), BackendPCDecisionMarker.fingerprint(current) == BackendPCDecisionMarker.fingerprint(expected) else { throw NativeRPCError(code: "decision-held", message: "The approved task changed before delivery. The old brief was held.") }
        }
        guard await decisionAllowed(id, sending: sending) else { throw NativeRPCError(code: "decision-held", message: await decisionReason(id, sending: sending) ?? "The business decision is held.") }
    }
    private func decisionValidation(_ task: BackendTaskRecord, sending: Bool = false, hoot: Bool = false) -> @Sendable () async throws -> Void {
        {
            try await self.requireDecision(task.id, expected: task, sending: sending)
            if hoot, PCDecisions.requires(task.value), !(await self.decisionHootAvailable()) {
                throw NativeRPCError(code: "decision-held", message: "Hoot's final decision validation owner is unavailable.")
            }
        }
    }
    private func decisionHootAvailable() -> Bool { decisionSafeHoot }
    public func releaseDecision(_ id: String, token: String) async throws -> Bool {
        // A deleted task, or one stopped, finished or archived (approval never reopens it), needs its tokens no more.
        for other in Array(decisionNudges.keys) where other != id {
            let row = try? await store.byID(other)
            if row.map({ $0.value["stopped"].bool == true || !$0.value["result"].isNullish || !$0.value["archivedAt"].isNullish || !$0.value["completedAt"].isNullish }) ?? true { decisionNudges[other] = nil }
        }
        guard decisionNudges[id]?.contains(token) != true, let task = try await store.byID(id), task.sessionID == nil, task.value["stopped"].bool != true, !["running", "setup"].contains(task.process), await decisionAllowed(id) else { return false }
        decisionNudges[id, default: []].insert(token)
        try await accept(id)
        let current = try await store.byID(id)
        return current?.sessionID != nil || current?.process == "running"
    }
    public func setHostedTaskChats(_ read: @escaping @Sendable () async -> Set<String>) { hostedTaskChats = read }
    public func start() async throws {
        guard stopped else { return }; try await store.requireWritableOwnership(); try await store.start(); try await config.start(); try await goals.start(); stopped = false
        await store.setRunCalendar(runCalendar)
        let live = Set(await access.sessions().filter { $0.exitCode == nil }.map(\.id))
        for task in try await store.all() {
            if let id = task.sessionID, !live.contains(id), !(await hostedTaskChats()).contains(id) {
                try await store.release(task.id)
                if task.value["result"].isNullish && task.value["stopped"].bool != true {
                    try await block(task.id, text: "Terminal Deck restarted while this was running. Reply on this task to continue where it left off.")
                    restartTasks[task.id] = try await record(task.id)
                }
            } else { await clearStaleWorkingMark(task) }
        }; try await pump(); await arm()
    }
    /// FORK-TASKS (11 Oct, real-app test T19). At start nobody is working a task that has no live session
    /// behind it, and no turn of Hoot's can be running. A "working" or "waiting to start" mark left on such a
    /// task is cleared whatever version wrote it (two tasks given to Hoot on 8 Oct still said "working" three
    /// days and several restarts later: the older build set the mark and nothing ever took it off), with one
    /// plain line on the task. The engine starts nothing again here; the app's restart continuation (L8)
    /// then goes on with what this start interrupted, so the line no longer tells the person to ask again
    /// (T19: it said "Reply on this task to ask Hoot again" and then Hoot did the task by itself).
    /// Kept to the task's own record (no CRM call) so a start can never fail or wait on it.
    private func clearStaleWorkingMark(_ task: BackendTaskRecord) async {
        if let id = task.sessionID, (await hostedTaskChats()).contains(id) { return }
        let hoots = task.assigneeKind == "hoot" && (["running", "queued"].contains(task.process) || task.value["hootTurnOpen"].bool == true)
        // An agent's mark with no session at all (a dead session is released just above, as before).
        let agents = task.assigneeKind == "agent" && task.sessionID == nil && task.process == "running"
        guard hoots || agents else { return }
        do {
            var patch: [(String, NativeRPCValue)] = [("process", .string(hoots ? "idle" : "exited")), ("runStartedAt", .null)]
            if hoots { patch.append(("hootTurnOpen", .bool(false))) }
            _ = try await store.update(task.id, patch: fields(patch))
            // Finished, stopped, done or archived already: only the mark was stale, there is nothing to say.
            guard task.value["result"].isNullish, task.value["stopped"].bool != true, task.value["archivedAt"].isNullish,
                  task.value["completedAt"].isNullish, task.value["crmStatus"].string != "Done" else { return }
            // Given to Hoot but not yet started by it when the app closed: said as that.
            let waiting = hoots && task.process != "running"
            try await store.note(task.id, by: hoots ? "hoot" : task.agentID, kind: "progress",
                text: waiting ? "Stopped: the app was closed before Hoot started on this. Reply on this task if it does not start by itself."
                              : "Stopped: the app was closed while this was being worked on. Reply on this task if it does not go on by itself.")
            // The list must not go on saying "Working on it" either (the same "Stuck" an interrupted agent task gets).
            if task.isLocal, task.value["crmStatus"].string == "Working on it" { try await setLifecycleStatus(task.id, key: "onBlocked") }
            restartTasks[task.id] = try await record(task.id)
        } catch { await problem("A task's stale working mark could not be cleared at start: " + error.localizedDescription) }
    }
    public func interruptedTaskIDs() async -> [String] {
        let tasks = (try? await store.all()) ?? []
        return tasks.filter { restartTasks[$0.id] != nil }.map(\.id)
    }
    /// Uses the same reply path as the task page and MCP. Rechecks the task after every slow wake;
    /// a reply, reassignment, stop, completion or a second continuation cannot restart it twice.
    @discardableResult public func continueInterruptedTask(_ id: String, text: String) async throws -> Bool {
        guard let expected = restartTasks[id] else { return false }
        do { try await reply(id, text: text, restart: expected); return true }
        catch let error as NativeRPCError where error.code == "restart-already-handled" { return false }
    }
    private static func stillInterrupted(_ task: BackendTaskRecord, expected: BackendTaskRecord) -> Bool {
        guard task.sessionID == nil, !["running", "queued", "setup"].contains(task.process),
              task.value["hootTurnOpen"].bool != true, task.value["questionOpen"].bool != true, task.value["stopped"].bool != true,
              task.value["result"].isNullish, task.value["archivedAt"].isNullish,
              task.value["completedAt"].isNullish, task.value["crmStatus"].string != "Done",
              ["agent", "hoot"].contains(task.assigneeKind) || task.value["handedFrom"].string != nil else { return false }
        // Editing the title or adding a note while Hoot wakes does not discard pending work.
        return ["assignee", "handedFrom", "runStartedAt", "lastTurn", "agoptRunID"].allSatisfy { task.value[$0] == expected.value[$0] }
    }
    /// Bind Hoot's chat: tasks given to Hoot become task turns there and its answers are posted on the task.
    /// `stop` ends Hoot's turn on a task id: called when that task is stopped, deleted or given to someone else.
    /// `closing` answers whether the app has begun to close.
    public func setHootTaskTurns(_ turns: HootTaskTurns?, stop: (@Sendable (String) async -> Void)? = nil, closing: (@Sendable () async -> Bool)? = nil) { hootTurns = turns; hootStop = stop; hootClosing = closing }
    /// The project's own name for a brief ("iMatch"); nil when the task belongs to no project.
    public func setProjectNames(_ lookup: (@Sendable (BackendTaskRecord) async -> String?)?) { projectName = lookup }
    public func setProjectNotes(_ lookup: (@Sendable (BackendTaskRecord) async -> String?)?) { projectNote = lookup }
    public func setPlaybookSeats(playbook: (@Sendable (BackendTaskRecord) async -> DeckMemoryPlaybookRow?)?,
                                 own: (@Sendable (NativeRPCValue) async throws -> AGSAgentSettings?)?) { playbookRow = playbook; ownSettings = own }
    /// PLAYBOOK-SEATS: the agent row a task's launch uses (the playbook row's AI first) and the settings over it
    /// (the row's model, effort and permission first, then the agent's own, then the app defaults).
    nonisolated public static func playbookAgent(_ task: BackendTaskRecord, _ agent: NativeRPCValue) -> NativeRPCValue {
        BackendPlaybookLayer(wire: task.value["playbook"])?.agentRow(agent) ?? agent
    }
    nonisolated static func playbookOwner(_ task: BackendTaskRecord, _ owner: AGSAgentSettings) -> AGSAgentSettings {
        BackendPlaybookLayer(wire: task.value["playbook"])?.apply(to: owner) ?? owner
    }
    /// Decided once per agent task and stored, so every later launch, reply and reuse check of it agrees.
    private func decidePlaybook(_ task: BackendTaskRecord) async throws -> BackendTaskRecord {
        guard task.value["playbook"] == .missing, task.assigneeKind == "agent", let playbookRow else { return task }
        let row = await playbookRow(task)
        return try await store.update(task.id, patch: fields([("playbook", row.map { BackendPlaybookLayer(row: $0).wireValue } ?? .null)]))
    }
    public func setParallelJobs(_ jobs: BackendParallelJobs?) { parallel = jobs }
    /// "Tasks at once": 0 (or none saved on a new agent) is no limit.
    private func roomFor(_ agent: NativeRPCValue, _ agentID: String) async throws -> Bool {
        let limit = Int(agent["maxConcurrent"].number ?? 0)
        if limit <= 0 { return true }
        return try await working(agentID) < limit
    }
    public func accept(_ id: String) async throws {
        try active(); let task = try await record(id); try requireOutgoing(task)
        guard await decisionAllowed(id) else { return }
        restartTasks[id] = nil
        guard ["human", "none", "hoot", "agent", BackendAGTLeadSeats.kind].contains(task.assigneeKind) else { throw NativeRPCError.malformed("The saved task's assignee is unknown; it was not started or reassigned.") }
        switch task.assigneeKind {
        case "human", "none": _ = try await store.update(id, patch: fields([("process", .string("idle"))]))
        case BackendAGTLeadSeats.kind:
            // L4-AGENTS: held by a project's lead SEAT that a session fills. Nothing is started here: it waits
            // ("Queued") until the session filling the seat has been told, now or when one is open again.
            _ = try await store.update(id, patch: fields([("process", .string("queued")), ("runStartedAt", .null), ("seatSession", .null), ("seatToldAt", .null)]))
            await BackendAGTLeadSeats.shared?.assigned(id)
        case "hoot":
            if hootTurns == nil {
                _ = try await store.update(id, patch: fields([("process", .string("running")), ("runStartedAt", .number(BackendTaskValues.time()))]))
                try await setLifecycleStatus(id, key: "onStarted")
                await notify(id, type: "task.started", body: "Hoot started on this.")
            } else {
                // Waiting for Hoot to take it ("Queued"); it turns to "Running" when Hoot's turn on it starts.
                _ = try await store.update(id, patch: fields([("process", .string("queued")), ("runStartedAt", .null)]))
            }
            try await tellHoot(id, try await hootBrief(try await record(id)), kind: .assigned)
        default: _ = try await store.update(id, patch: fields([("process", .string("queued"))])); try await pump()
        }; await arm()
    }
    public func pump() async throws {
        try await BackendAGOPTCompletionFence.$current.withValue(nil) { try await self.pumpQueue() }
    }
    private func pumpQueue(onlyAgent: String? = nil) async throws {
        guard !stopped else { return }
        // U70 (18 Oct): a launch (session, brief, typing: many seconds) no longer holds the queue. Each one runs on
        // its own; the queue is free for the next task, and this pump waits only for the launches it started.
        var launches: [(id: String, job: Task<Void, any Error>, agent: NativeRPCValue)] = [], cancelled = false
        do {
        await acquirePump(); defer { releasePump() }; guard !stopped else { return }
        let queued = try await store.all().filter { $0.process == "queued" && $0.value["stopped"].bool != true && $0.assigneeKind == "agent" && (onlyAgent == nil || $0.agentID == onlyAgent) }.sorted { ($0.value["createdAt"].number ?? 0) < ($1.value["createdAt"].number ?? 0) }
        for task in queued {
          // HOOTFIX: one task that cannot start yet (or whose folder holder cannot be closed)
          // must never stop the rest of the queue; before, its error escaped and every queued
          // task behind it, for every agent, waited forever.
          do {
            guard !stopped, !starting.contains(task.id), await decisionAllowed(task.id), BackendGoalStore.blockers(task, all: try await store.all()).isEmpty else { continue }
            guard let agent = try await config.agent(task.agentID) else { try await block(task.id, text: "The agent this task was assigned to no longer exists in Terminal Deck."); continue }
            guard agent["status"].string == "active" else { continue }
            guard try await canStartMonthly(agent) else { continue }
            guard try await roomFor(agent, task.agentID) else { continue }
            // PARALLEL-JOBS: a job that starts while the same agent has a live job gets its own copy (a git worktree
            // from the project's current head); never two jobs in one checkout. No git: one at a time.
            var task = task
            if parallel != nil, task.value["agtHand"].bool != true, task.value["reviewOfTaskId"].string == nil, try await working(task.agentID) > 0, task.value["useWorkspace"].bool != true {
                _ = try await store.update(task.id, patch: fields([("useWorkspace", .bool(true)), ("parallelJob", .bool(true))])); task = try await record(task.id)
            }
            let folder: String
            do { folder = try await workspace(task) } catch { try await block(task.id, text: "Could not prepare the folder \(agent["name"].string ?? "this agent") works in: " + error.localizedDescription); continue }
            // L4-AGENTS: hands on one seat work side by side (the person added them), so a hand never waits for,
            // or closes, another session in the same folder.
            if BackendParallelJobs.mustWait(parallelJob: task.value["parallelJob"].bool == true, folder: folder, project: task.project, siblingsLive: try await working(task.agentID)) {
                if task.value["parallelWaiting"].bool != true {
                    _ = try await store.update(task.id, patch: fields([("parallelWaiting", .bool(true))]))
                    try await store.note(task.id, by: task.agentID, kind: "progress", text: "Waiting: this project folder has no git, so this agent's jobs here run one at a time.")
                }
                continue
            }
            // A launch still starting in this folder holds it, as its session will.
            if task.value["agtHand"].bool != true, launchFolders.contains(where: { $0.key != task.id && $0.value == folder }) { continue }
            let roomy = task.value["agtHand"].bool == true ? true : try await makeRoom(folder, task: task, agent: agent)
            guard roomy else {
                if task.value["reviewOfTaskId"].string != nil, task.value["reviewWaitingForFolder"].bool != true {
                    _ = try await store.update(task.id, patch: fields([("reviewWaitingForFolder", .bool(true))]))
                    try await comment(task.id, kind: "blocker", text: "The reviewer is waiting for the worker's folder. A separate workspace could not be used. Close the finished worker's session to let the review start.")
                }
                continue
            }
            if task.value["reviewWaitingForFolder"].bool == true { _ = try await store.update(task.id, patch: fields([("reviewWaitingForFolder", .bool(false))])) }
            if task.value["agoptWaitingForSession"].bool == true { _ = try await store.update(task.id, patch: fields([("agoptWaitingForSession", .bool(false))])) }
            if let job = await claimLaunch(task.id, agent: agent, reply: nil, folder: folder) { launches.append((task.id, job, agent)) }
          } catch is CancellationError { throw CancellationError() }
          catch { await problem("Task \(task.id) could not start yet: " + error.localizedDescription) }
        }
        } catch is CancellationError { cancelled = true }
        // Every claimed launch is settled, even after a cancel, so none stays "starting".
        for launch in launches {
            do { try await settleLaunch(launch.id, job: launch.job, agent: launch.agent) }
            catch is CancellationError { cancelled = true }
            catch { await problem("Task \(launch.id) could not start yet: " + error.localizedDescription) }
        }
        if cancelled { throw CancellationError() }; await arm()
    }
    /// The part of task-engine.ts `start` that guards the launch and says why one failed.
    private func begin(_ id: String, agent: NativeRPCValue, reply: String?, replyBy: String? = nil, folder: String? = nil) async throws {
        guard let job = await claimLaunch(id, agent: agent, reply: reply, replyBy: replyBy, folder: folder) else { return }
        try await settleLaunch(id, job: job, agent: agent)
    }
    /// Starts the launch on its own task; from here the task counts as starting (and holds `folder`).
    private func claimLaunch(_ id: String, agent: NativeRPCValue, reply: String?, replyBy: String? = nil, folder: String? = nil) async -> Task<Void, any Error>? {
        guard !starting.contains(id), await decisionAllowed(id), !starting.contains(id) else { return nil }
        // L8 (10 Oct): a launch is the engine's own action (the task gate authorizes it). It must not inherit
        // the request context of whoever woke the queue: under Hoot's tasks_plan the new worker's project
        // checks ran against HOOT's folder grant and every launch failed "outside this caller's grant".
        starting.insert(id); launchFolders[id] = folder
        let job = Task { try await BackendAGOPTCompletionFence.$current.withValue(nil) { try await self.launchWithoutCallerContext(id, agent: agent, reply: reply, replyBy: replyBy) } }; jobs[id] = job
        return job
    }
    /// Waits for a claimed launch and says why it failed.
    private func settleLaunch(_ id: String, job: Task<Void, any Error>, agent: NativeRPCValue) async throws {
        let agentID = agent["id"].string ?? id
        defer { jobs[id] = nil; starting.remove(id); launchFolders[id] = nil }
            do { try await job.value } catch is CancellationError { if !stopped { try await block(id, text: "This task launch was cancelled.") } }
            catch {
                let message = error.localizedDescription
                if message.contains("already have a session running in") || message.contains("sessions running, which is the limit") {
                    _ = try await store.update(id, patch: fields([("process", .string("queued"))]))
                    if message.contains("sessions running, which is the limit"), let oldest = try await store.all().filter({ $0.sessionID != nil && $0.value["keepOpenUntil"].number != nil && $0.value["keepAliveUntilClose"].bool != true }).min(by: { ($0.value["keepOpenUntil"].number ?? 0) < ($1.value["keepOpenUntil"].number ?? 0) }) { try await close(oldest.id) }
                } else if !stopped, let setup = error as? NativeRPCError, setup.code == "setup-needed", let file = setup.details["briefFile"].string, try await record(id).sessionID != nil {
                    // FORK-TASKS (c): Claude Code's own first-run, sign-in or folder-trust screen. Nothing is typed into
                    // it and the task is not failed: it waits, and starts by itself once the session shows its prompt.
                    _ = try await store.update(id, patch: fields([("awaitingSetup", .bool(true)), ("briefFile", .string(file)), ("process", .string("setup")), ("runStartedAt", .null)]))
                    try await comment(id, kind: "blocker", text: "\(agent["name"].string ?? agentID) cannot start yet: \(setup.message) The task will start by itself.")
                } else if !stopped {
                    try await block(id, text: "Could not start \(agent["name"].string ?? agentID): " + message + (message.last.map { ".!?".contains($0) } == true ? "" : "."))
                    // (b) A session left open by a start that failed must not hold its folder or its agent's queue.
                    if try await store.byID(id)?.sessionID != nil { _ = try await store.update(id, patch: fields([("startFailed", .bool(true))])) }
                }
            }
                }
    private func launchWithoutCallerContext(_ id: String, agent: NativeRPCValue, reply: String?, replyBy: String? = nil) async throws {
        #if TD_HOST_ACCOUNT_BRIDGE
        try await BackendHOSTProfileScope.$context.withValue(nil) { try await NativeCompositionCallContext.$rpc.withValue(nil) { try await self.launch(id, agent: agent, reply: reply, replyBy: replyBy) } }
        #else
        try await NativeCompositionCallContext.$rpc.withValue(nil) { try await self.launch(id, agent: agent, reply: reply, replyBy: replyBy) }
        #endif
    }
    private func acquirePump() async { if !pumping { pumping = true; return }; await withCheckedContinuation { pumpWaiters.append($0) } }
    private func releasePump() { if pumpWaiters.isEmpty { pumping = false } else { pumpWaiters.removeFirst().resume() } }
    /// task-engine.ts `working`: sessions an agent has open and is not keeping idle.
    private func working(_ agentID: String) async throws -> Int {
        let ids = Set(await access.sessions().filter { $0.exitCode == nil }.map(\.id))
        return try await store.all().filter { $0.agentID == agentID && (starting.contains($0.id) || ($0.sessionID.map(ids.contains) == true && $0.value["keepOpenUntil"].isNullish && $0.value["keepAliveUntilClose"].bool != true && $0.value["startFailed"].bool != true)) }.count
    }
    /// FORK-TASKS (11 Oct, real app: one task whose brief never arrived left its session open and every task
    /// for that folder, whoever's, sat at "waiting to start" for 16 minutes). Why a session that holds a folder
    /// is not really working its task, or nil when it is. Such a session is closed for a task that waits (its
    /// conversation is kept, so a reply continues it). Never one the owner asked to keep open, and never one
    /// waiting on Claude Code's own setup screen (a new session would only land on the same screen).
    static let idleHoldMilliseconds = 5.0 * 60_000
    private func deadEnd(_ holder: BackendTaskRecord) -> String? {
        guard let session = holder.sessionID, holder.value["keepAliveUntilClose"].bool != true, holder.value["awaitingSetup"].bool != true else { return nil }
        if holder.value["startFailed"].bool == true { return "its brief never reached it" }
        if holder.value["stopped"].bool == true || (holder.isLocal && (!holder.value["completedAt"].isNullish || holder.value["crmStatus"].string == "Done")) { return "its task was over" }
        if !holder.value["stalled"].isNullish { return "it had stalled" }
        if observedStatus[session] != .working, let since = quiet[session] ?? holder.value["runStartedAt"].number, BackendTaskValues.time() - since >= Self.idleHoldMilliseconds {
            return "it had not worked for \(Int(Self.idleHoldMilliseconds / 60_000)) minutes"
        }
        return nil
    }
    /// task-engine.ts `makeRoom`: one session per folder; a kept-open holder is closed so the next task can use it.
    private var calmSessions: Set<String> { Set(observedStatus.filter { [.idle, .waiting, .completed].contains($0.value) }.map(\.key)) }
    private func liveHolder(_ task: BackendTaskRecord, agent: NativeRPCValue, cwd: String, settings: AGSAgentSettings) async throws -> (task: BackendTaskRecord, session: BackendSessionMeta)? {
        let identity = try await profileID?(agent, cwd)
        let generation = try await store.agentRuntime(agent["id"].string ?? task.agentID)["reuse_generation"].number ?? 0
        let records = try await store.all().filter { ($0.value["agoptReuseGeneration"].number ?? 0) == generation }
        return BackendAGOPTTaskPolicy.liveHolder(for: task, agent: agent, cwd: cwd, settings: settings, profileID: identity,
            records: records, sessions: await access.sessions(), calm: calmSessions)
    }
    private func makeRoom(_ folder: String, task: BackendTaskRecord? = nil, agent: NativeRPCValue? = nil) async throws -> Bool {
        if let settings, let pending = task, let given = agent {
            let task = try await decidePlaybook(pending)
            let agent = Self.playbookAgent(task, given)
            let owner = Self.playbookOwner(task, try await settings(agent))
            let effective = try BackendAGOPTTaskPolicy.applying(task, to: owner)
            if try await liveHolder(task, agent: agent, cwd: folder, settings: effective) != nil { return true }
        }
        let ids = Set(await access.sessions().filter { $0.exitCode == nil && $0.cwd == folder }.map(\.id))
        guard let holder = try await store.all().first(where: { $0.sessionID.map(ids.contains) == true }) else { return true }
        if holder.value["keepAliveUntilClose"].bool == true, let task, settings != nil, task.value["agoptWaitingForSession"].bool != true {
            _ = try await store.update(task.id, patch: fields([("agoptWaitingForSession", .bool(true))]))
            try await comment(task.id, kind: "progress", text: "Waiting for a kept-open session in this folder to close. Its account or settings differ from this task.")
        }
        if !holder.value["keepOpenUntil"].isNullish, holder.value["keepAliveUntilClose"].bool != true { try await close(holder.id) }
        else if let task, holder.id != task.id, let why = deadEnd(holder) {
            try await close(holder.id)
            _ = try await store.update(holder.id, patch: fields([("startFailed", .null)]))
            try await store.note(holder.id, by: agentIdOf(holder) ?? holder.agentID, kind: "progress",
                text: "Its session was closed (\(why)) so that “\(head(task.value["title"].string ?? "", 80))” could start in the same folder. Reply on this task to continue it.")
        }
        return false
    }
    public func nudge() { guard !stopped else { return }; Task { await BackendAGOPTCompletionFence.$current.withValue(nil) { do { try await self.pump() } catch { await self.problem(error.localizedDescription) } } } }
    public func reply(_ id: String, text: String) async throws {
        try await reply(id, text: text, restart: nil)
    }
    private func reply(_ id: String, text: String, restart: BackendTaskRecord?) async throws {
        try active(); var task = try await record(id); try requireOutgoing(task)
        try await requireDecision(id, sending: true)
        if let restart {
            guard restartTasks[id] == restart, Self.stillInterrupted(task, expected: restart) else {
                if restartTasks[id] == restart { restartTasks[id] = nil }
                throw NativeRPCError(code: "restart-already-handled", message: "This task has already been handled since the app started.")
            }
        }
        restartTasks[id] = nil
        checks[id]?.cancel()
        _ = try await store.update(id, patch: fields([("questionOpen", .bool(false))]))
        if task.assigneeKind == BackendAGTLeadSeats.kind {
            // L4-AGENTS: the seat's session is told (or the task waits for it); never started from here.
            let comment = BackendTaskCommentReceipt.enveloped(text)
            let author: String? = comment == nil ? nil : await personName(BackendTaskCommentAuthor.current)
            try await BackendAGTLeadSeats.shared?.said(id, text: comment ?? text, by: author); return
        }
        if task.isLocal, !["agent", "hoot"].contains(task.assigneeKind) {
            guard let back = task.value["handedFrom"].string, let handed = try await config.agent(back) else { return }
            let identity = handed["id"].string ?? back
            task = try await store.update(id, patch: fields([("assignee", BackendTaskLocalService.assignment(identity, kind: "agent")), ("mainAssignee", .string(identity)), ("handedFrom", .null)]))
            try await store.note(id, by: "me", kind: "reply", text: text)
        }
        // FORK-TASKS: a comment arrives in an envelope from the task's thread. Take the marker off and word
        // it for whoever holds the task. A plain reply (typed as the answer to a question) goes as written.
        let comment = BackendTaskCommentReceipt.enveloped(text), said = comment ?? text
        let author: String? = comment == nil ? nil : await personName(BackendTaskCommentAuthor.current)
        let title = task.value["title"].string ?? ""
        if task.assigneeKind == "hoot" { try await tellHoot(id, BackendTaskBriefComposition.hootComment(title: title, taskID: task.id, text: said, by: author), kind: .comment); return }
        let typed = comment == nil ? text : BackendTaskBriefComposition.agentLine(title: title, text: said, by: author,
            tools: (try await config.agent(task.agentID)).map(BackendTaskBriefComposition.hasTaskTools) ?? false)
        if let session = task.sessionID, await alive(session) {
            if let settings, let agent = try await config.agent(task.agentID).map({ Self.playbookAgent(task, $0) }),
               let meta = await access.sessions().first(where: { $0.id == session }) {
                let runtime = try await store.agentRuntime(task.agentID)
                if runtime["fresh_pending"].bool == true && (task.value["agoptReuseGeneration"].number ?? 0) != (runtime["reuse_generation"].number ?? 0) { throw NativeRPCError(code: "unavailable", message: "Fresh context is waiting for the retained session to close. This provider has no supported live reset control.") }
                if let total = try await usageBaseline?(meta) {
                    let captured = task
                    try await noteTokenUsage(sessionID: session, totalTokens: total,
                        expectedTaskID: captured.id, expectedAssignee: captured.value["assignee"], expectedRunID: captured.value["agoptRunID"].string)
                    task = try await record(id)
                    guard task.sessionID == session, task.value["assignee"] == captured.value["assignee"], task.value["agoptRunID"] == captured.value["agoptRunID"] else { throw CancellationError() }
                }
                let owner = Self.playbookOwner(task, try await settings(agent)), identity = try await profileID?(agent, meta.cwd)
                let effective = try BackendAGOPTTaskPolicy.applying(task, to: owner)
                let scopeMatches = BackendAGOPTTaskPolicy.sameScope(task, agent: agent, cwd: meta.cwd, settings: effective, profileID: identity)
                if !scopeMatches || !BackendAGOPTTaskPolicy.sameControls(task, settings: effective) {
                    // A changed task choice must be selected before the next
                    // reply. Scope changes start fresh; model/effort changes
                    // carry only the same account's exact recorded conversation.
                    try await close(id)
                    task = try await record(id)
                    if !scopeMatches { task = try await store.update(id, patch: fields([("conversationId", .null)])) }
                } else {
                    task = try await store.update(id, patch: BackendAGOPTTaskPolicy.snapshot(agent: agent, cwd: meta.cwd, settings: effective, profileID: identity)
                        .setting("tokenUsageByAgent", BackendAGOPTTaskPolicy.usageByAgent(task))
                        .setting("agoptRunID", .string(UUID().uuidString.lowercased())).setting("agoptRunRetired", .bool(false)).setting("agoptUsageMeasured", .bool(false))
                        .setting("agoptReuseGeneration", runtime["reuse_generation"].number.map(NativeRPCValue.number) ?? .number(0))
                        .setting("agoptTaskTokenBudget", .number(Double(effective.efficiency?.taskTokenBudget ?? 0)))
                        .setting("agoptAgentTokenBudget", .number(Double(effective.efficiency?.agentTokenBudget ?? 0)))
                        .setting("agoptWarningPercent", .number(Double(effective.efficiency?.warningPercent ?? 80))))
                }
            }
            if await alive(session) {
            var sent = true
            let delta = BackendPCContextDelta.make(task)
            do {
                try await requireDecision(id, expected: task, sending: true)
                try await BackendPCDecisionDelivery.$required.withValue(PCDecisions.requires(task.value)) {
                    try await BackendPCDecisionDelivery.$hostedReference.withValue(PCDecisions.requires(task.value) ? BackendPCDecisionMarker.executionReference(task) : nil) {
                        try await BackendPCDecisionDelivery.$validate.withValue(decisionValidation(task, sending: true)) { try await access.send(session, flatten(typed) + delta.text) }
                    }
                }
                await noteTyped(session, flatten(typed), task: task)
            } catch { sent = false }
            if sent {
                try await store.acknowledgeContext(id, packet: delta, expected: task)
                _ = try await store.update(id, patch: fields([("keepOpenUntil", .null), ("keepAliveUntilClose", .bool(false)), ("runStartedAt", .number(BackendTaskValues.time())), ("result", .null), ("stalled", .null)])); quiet[session] = BackendTaskValues.time()
                try await setLifecycleStatus(id, key: "onStarted"); await notify(id, type: "task.started", body: "The agent is continuing with your reply."); await arm(); return
            }
            }
        }
        guard let agent = try await config.agent(task.agentID) else { try await block(id, text: "The agent this task was assigned to no longer exists in Terminal Deck."); return }
        _ = try await store.update(id, patch: fields([("process", .string("queued")), ("result", .null), ("stalled", .null)]))
        guard try await roomFor(agent, agent["id"].string ?? task.agentID) else { return }
        let folder = try await workspace(task)
        guard !launchFolders.contains(where: { $0.key != id && $0.value == folder }), try await makeRoom(folder, task: task, agent: agent) else { return }
        try await begin(id, agent: agent, reply: said, replyBy: author, folder: folder); await arm()
    }
    public func cancel(_ id: String, reason: String) async throws {
        let task = try await record(id); try requireOutgoing(task); restartTasks[id] = nil
        jobs[id]?.cancel(); checks[id]?.cancel(); await stopHootTurn(id)
        _ = try await store.update(id, patch: fields([("stopped", .bool(true)), ("questionOpen", .bool(false)), ("hootTurnOpen", .bool(false))]))
        if task.sessionID != nil { try await close(id) } else { try await store.release(id) }
        try await comment(id, kind: "progress", text: "Stopped: " + reason); try await pump(); await arm()
    }
    public func reassign(_ id: String, assignee: NativeRPCValue) async throws {
        restartTasks[id] = nil
        checks[id]?.cancel()
        let task = try await record(id)
        // FORK-TASKS: taken away from Hoot while it worked. Its turn is stopped NOW (it used to run to the
        // end), and the task says it was stopped: what Hoot had done is never shown as a finished answer.
        if await stopHootTurn(id), task.assigneeKind == "hoot", assignee["kind"].string != "hoot" {
            let kind = assignee["kind"].string ?? "none"
            let to: String
            if kind == "human" { to = "you" } else if kind == "none" { to = "" } else { to = await workerName(assignee["agentId"].string ?? "") }
            await sayAsHoot(id, kind: "progress", text: "Hoot was stopped before it finished: this task was " + (to.isEmpty ? "taken away from it." : "given to \(to)."))
        }
        _ = try await store.update(id, patch: fields([("agoptRunID", .string(UUID().uuidString.lowercased())), ("agoptRunRetired", .bool(true)), ("agoptRunEndReason", .string("reassigned"))]))
        if task.sessionID != nil { try await close(id) }
        _ = try await store.update(id, patch: fields([("hootTurnOpen", .bool(false)), ("assignee", assignee), ("mainAssignee", assignee["identity"]), ("sessionId", .null), ("conversationId", .null), ("result", .null), ("lastTurn", .null), ("stopped", .bool(false)), ("keepOpenUntil", .null), ("stalled", .null), ("retry", .null)]))
        let before = agentIdOf(task) ?? (task.assigneeKind == "hoot" ? "hoot" : nil), worker = ["agent", "hoot"].contains(assignee["kind"].string ?? ""), after = assignee["agentId"].string
        if worker, let before, before != after { await knowledgeAdapter?.note(try await record(id), kind: "reassigned", summary: "From \(await workerName(before)) to \(await workerName(after ?? "")).") }
        try await accept(id)
    }
    public func closeSession(_ id: String) async throws {
        guard try await record(id).sessionID != nil else { throw NativeRPCError.invalidArguments("That task has no open session.") }; try await close(id); nudge(); await arm()
    }
    public func retry(_ id: String, note: String) async throws {
        checks[id]?.cancel()
        let task = try await record(id); guard task.isLocal else { throw NativeRPCError.invalidArguments("That is a CRM task: the CRM decides who runs it again.") }
        guard let agentID = agentIdOf(task), let agent = try await config.agent(agentID) else { throw NativeRPCError.invalidArguments("No task agent has worked on this task yet. Give it to one with tasks_reassign.") }
        restartTasks[id] = nil
        let identity = agent["id"].string ?? agentID, said = note.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await store.update(id, patch: fields([("agoptRunID", .string(UUID().uuidString.lowercased())), ("agoptRunRetired", .bool(true)), ("agoptRunEndReason", .string("reassigned"))]))
        if task.sessionID != nil { try await close(id) }
        _ = try await store.update(id, patch: fields([("assignee", BackendTaskLocalService.assignment(identity, kind: "agent")), ("mainAssignee", .string(identity)), ("handedFrom", .null), ("sessionId", .null), ("conversationId", .null), ("result", .null), ("lastTurn", .null), ("stopped", .bool(false)), ("keepOpenUntil", .null), ("questionOpen", .bool(false)), ("stalled", .null), ("retry", fields([("note", .string(said)), ("at", .number(BackendTaskValues.time())), ("count", .number((task.value["retry"]["count"].number ?? 0) + 1))]))]))
        try await store.note(id, by: BackendTaskActor.current, kind: "progress", text: "Tried again with \(agent["name"].string ?? identity)\(said.isEmpty ? "." : ": " + said)"); try await accept(id)
    }
    public func review(_ id: String, pass: Bool, evidence: [String], reasons: String) async throws {
        let task = try await record(id)
        try await requireReviewer(task)
        guard task.isLocal else { throw NativeRPCError.invalidArguments("That is a CRM task: use tasks_verify for it.") }
        guard !task.value["result"].isNullish || task.value["crmStatus"].string == "Done" else { throw NativeRPCError.invalidArguments("It has not finished yet. Review it once its worker says it is done.") }
        let evidence = evidence.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }, reasons = reasons.trimmingCharacters(in: .whitespacesAndNewlines)
        if pass { guard !evidence.isEmpty else { throw NativeRPCError.invalidArguments("A pass has to name its evidence: the files, commands or output that show it is done.") }; try await verify(id, verified: true, note: "Reviewed and verified. Evidence: " + evidence.joined(separator: "; "), evidence: evidence); return }
        guard !reasons.isEmpty else { throw NativeRPCError.invalidArguments("A fail has to say what is wrong, so the worker can fix it.") }
        try await recordReviewVerdict(task, pass: false, evidence: evidence, reasons: reasons)
        let seen = try await record(id), result = seen.value["result"].isNullish ? fields([("at", .number(BackendTaskValues.time())), ("answer", .null), ("check", .null)]) : seen.value["result"]
        _ = try await store.update(id, patch: fields([("result", result.setting("verified", .bool(false)))]))
        try await comment(id, kind: "blocker", text: "Reviewed: not done yet. " + reasons, by: try await reviewer(task))
        await knowledgeAdapter?.note(try await record(id), kind: "rejected", summary: reasons, evidence: evidence)
        guard let agentID = agentIdOf(task), let agent = try await config.agent(agentID) else { _ = try await store.update(id, patch: fields([("result", .null)])); try await setStatus(id, status: "To-Do"); return }
        let identity = agent["id"].string ?? agentID
        _ = try await store.update(id, patch: fields([("assignee", BackendTaskLocalService.assignment(identity, kind: "agent")), ("mainAssignee", .string(identity)), ("handedFrom", .null)]))
        let looked = evidence.isEmpty ? "" : " What was looked at: \(evidence.joined(separator: "; "))."
        try await reply(id, text: "A review found this is not done yet: \(reasons)\(looked) Fix it, then finish with a short summary of what changed.")
    }
    public func verify(_ id: String, verified: Bool, note: String, evidence: [String] = []) async throws {
        let task = try await record(id)
        try await requireReviewer(task)
        if verified, BackendTaskActor.current.hasPrefix("taskagent:"), note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && evidence.isEmpty { throw NativeRPCError.invalidArguments("A reviewer pass has to name the evidence it checked.") }
        if !verified, BackendTaskActor.current.hasPrefix("taskagent:"), note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw NativeRPCError.invalidArguments("A reviewer fail has to say what is missing.") }
        let actor = try await reviewer(task)
        try await recordReviewVerdict(task, pass: verified, evidence: evidence, reasons: note)
        let result = task.value["result"].isNullish ? fields([("at", .number(BackendTaskValues.time())), ("answer", .null), ("check", .null)]) : task.value["result"]
        _ = try await store.update(id, patch: fields([("result", result.setting("verified", .bool(verified)))]))
        if verified {
            try await comment(id, kind: "completion", text: note.isEmpty ? "Checked and complete." : note, by: actor); try await setLifecycleStatus(id, key: "onVerified")
            if task.assigneeKind == "hoot" { _ = try await store.update(id, patch: fields([("process", .string("exited")), ("runStartedAt", .null)])) }
        }
        else { try await block(id, text: note.isEmpty ? "Checked: not complete yet." : note, by: actor) }
        await knowledgeAdapter?.note(try await record(id), kind: verified ? "verified" : "rejected", summary: note, evidence: evidence); nudge()
    }
    public func noteStatus(sessionID: String, status: BackendSessionStatus) async throws {
        guard !stopped, let task = try await store.bySession(sessionID) else { return }
        // (c) Waiting on Claude Code's setup screen: nothing else applies until the brief is in. An empty
        // prompt means the setup is done, so the brief goes in now.
        if task.value["awaitingSetup"].bool == true {
            if status == .waiting { let id = task.id; setupStarts[id] = Task { [weak self] in await self?.startAfterSetup(id) } }
            return
        }
        observedStatus[sessionID] = status
        if status == .working, !task.value["keepOpenUntil"].isNullish || task.value["keepAliveUntilClose"].bool == true { _ = try await store.update(task.id, patch: fields([("keepOpenUntil", .null), ("keepAliveUntilClose", .bool(false)), ("runStartedAt", .number(BackendTaskValues.time()))])) }
        if status == .working {
            quiet[sessionID] = nil
            if task.value["stalled"]["reason"].string == "quiet" {
                _ = try await store.update(task.id, patch: fields([("stalled", .null)])); try await store.note(task.id, by: task.agentID, kind: "progress", text: "Working again."); try await setLifecycleStatus(task.id, key: "onStarted")
                await notify(task.id, type: "task.progress", body: "Working again.")
            }
        } else if status != .exited, quiet[sessionID] == nil { quiet[sessionID] = BackendTaskValues.time() }
        // Turn completion is deliberately a separate observed notification.
        // A calm terminal alone is not evidence that a task finished.
        await arm()
    }
    /// Accepted transcript/status events report the exact conversation's cumulative
    /// total. Persist only deltas so parked/resumed conversations are not billed twice.
    public func noteTokenUsage(sessionID: String, totalTokens: Double, expectedTaskID: String? = nil,
                               expectedAssignee: NativeRPCValue? = nil, expectedRunID: String? = nil) async throws {
        guard !stopped, totalTokens.isFinite, totalTokens >= 0, totalTokens <= 1e15,
              let task = try await store.bySession(sessionID), task.value["agoptEfficiencyApplied"].bool == true else { return }
        guard expectedTaskID == nil || task.id == expectedTaskID,
              expectedAssignee == nil || task.value["assignee"] == expectedAssignee,
              expectedRunID == nil || task.value["agoptRunID"].string == expectedRunID else { return }
        guard let accepted = try await store.noteTokenUsage(sessionID: sessionID, totalTokens: totalTokens,
            expectedTaskID: task.id, expectedAssignee: task.value["assignee"], expectedRunID: task.value["agoptRunID"].string) else { return }
        let finish: @Sendable () async throws -> Void = {
            if accepted.warned {
                let used = accepted.task.value["tokenUsage"].number ?? 0, cap = accepted.task.value["agoptTaskTokenBudget"].number ?? 0
                try await self.comment(task.id, kind: "progress", text: "Token budget warning: this task has used \(String(format: "%.0f", used)) of \(Int(cap)) tokens.")
            }
            try await self.checkMonthlyBudget(task.value["agoptAgentID"].string ?? task.agentID, task: task.id)
        }
        if let runID = accepted.task.value["agoptRunID"].string {
            try await BackendAGOPTCompletionFence.$current.withValue(.init(taskID: task.id, runID: runID), operation: finish)
        } else { try await finish() }
    }
    public func noteNeedsInput(sessionID: String, screen: String) async throws {
        guard !stopped, let task = try await store.bySession(sessionID), task.value["questionOpen"].bool != true, task.value["awaitingSetup"].bool != true else { return }
        _ = try await store.update(task.id, patch: fields([("questionOpen", .bool(true))]))
        try await comment(task.id, kind: "question", text: "The agent is asking something. Reply on this task to answer.\n\n" + tail(screen, 1_200))
        await notify(task.id, type: "task.blocked", body: "The agent is waiting for an answer.")
        if !task.isLocal { await notify(task.id, type: "task.needs-reply", body: "Reply on this task to answer the agent's question.") }
        try await setLifecycleStatus(task.id, key: "onBlocked"); try await handToHuman(task.id); await arm()
    }
    public func noteFinishedTurn(sessionID: String, turnID: String, answer: String,
                                 expectedTaskID: String? = nil, expectedAssignee: NativeRPCValue? = nil, expectedRunID: String? = nil) async throws {
        if let expectedTaskID, let expectedRunID {
            try await BackendAGOPTCompletionFence.$current.withValue(.init(taskID: expectedTaskID, runID: expectedRunID)) {
                try await self.finishObservedTurn(sessionID: sessionID, turnID: turnID, answer: answer,
                    expectedTaskID: expectedTaskID, expectedAssignee: expectedAssignee, expectedRunID: expectedRunID)
            }
        } else {
            try await finishObservedTurn(sessionID: sessionID, turnID: turnID, answer: answer,
                expectedTaskID: expectedTaskID, expectedAssignee: expectedAssignee, expectedRunID: expectedRunID)
        }
    }
    private func finishObservedTurn(sessionID: String, turnID: String, answer: String,
                                    expectedTaskID: String?, expectedAssignee: NativeRPCValue?, expectedRunID: String?) async throws {
        guard !stopped, let task = try await store.bySession(sessionID), task.value["stopped"].bool != true, task.value["lastTurn"].string != turnID else { return }
        guard expectedTaskID == nil || task.id == expectedTaskID,
              expectedAssignee == nil || task.value["assignee"] == expectedAssignee,
              expectedRunID == nil || task.value["agoptRunID"].string == expectedRunID else { return }
        let session = await access.sessions().first { $0.id == sessionID }
        if let expectedRunID {
            guard let current = try await store.bySession(sessionID), current.id == task.id,
                  current.value["agoptRunID"].string == expectedRunID, current.value["assignee"] == task.value["assignee"] else { return }
        }
        observedStatus[sessionID] = .completed
        await BackendAGOPTCoordinator.shared.releaseSession(sessionID: sessionID)
        _ = try await store.update(task.id, patch: fields([("lastTurn", .string(turnID)), ("questionOpen", .bool(false)), ("conversationId", session?.agentSessionId.map(NativeRPCValue.string) ?? task.value["conversationId"])]))
        let agent = try await config.agent(agentIdOf(task) ?? ""), who = agent?["name"].string ?? "An agent", title = head(task.value["title"].string ?? "", 80), told = head(answer, 3_000)
        if let prior = task.value["reusedFromTask"].string, let before = try await store.byID(prior, includeTrash: true)?.value["result"]["answer"].string,
           !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, before.trimmingCharacters(in: .whitespacesAndNewlines) == answer.trimmingCharacters(in: .whitespacesAndNewlines) {
            // FORK-TASKS (a): the session was reused and it said again exactly what it said for the task before:
            // this task's brief did not reach it. The task is not closed with an answer that is not its own.
            _ = try await store.update(task.id, patch: fields([("reusedFromTask", .null)]))
            try await block(task.id, text: "\(who) answered with the answer of its previous task (“\(head(answer, 200))”), so this task's brief did not reach it. Nothing was closed with that answer. Reply on this task with what it should do, or give it to the agent again.")
            return
        }
        await knowledgeAdapter?.note(task, kind: "finished", summary: told)
        var landedHere = task.value["parallelLanded"].bool == true
        if task.value["parallelJob"].bool == true, !landedHere, task.value["askedFromTask"].string == nil, task.value["reviewOfTaskId"].string == nil, let parallel {
            let attempt = Int(task.value["landingAttempts"].number ?? 0)
            switch await parallel.land(taskID: task.id, title: task.value["title"].string ?? "Task", verifyCommand: agent?["verifyCommand"].string, attempt: attempt, check: access.check) {
            case .landed(let line):
                landedHere = true
                _ = try await store.update(task.id, patch: fields([("parallelLanded", .bool(true)), ("landing", .string(line))]))
                try await store.note(task.id, by: task.agentID, kind: "progress", text: line)
            case .retry(let ask):
                _ = try await store.update(task.id, patch: fields([("landingAttempts", .number(Double(attempt + 1))), ("landing", .string(ask))]))
                try await reply(task.id, text: ask); return
            case .stuck(let why):
                _ = try await store.update(task.id, patch: fields([("landingAttempts", .number(Double(attempt + 1))), ("landing", .string(why))]))
                try await block(task.id, text: why)
                try? await tellHoot(task.id, BackendTaskBriefComposition.hootNotice("\(who)'s parallel job \"\(title)\" could not be landed.", taskID: task.id, next: why + " Decide with its lead what to keep; nothing was forced."))
                return
            case .notParallel: break
            }
        }
        if task.value["askedFromTask"].string != nil {
            // FORK-TASKS: a question asked from another task's comments is finished once it is answered. The
            // answer goes on as the agent's own words (they show in the asking task's thread); nobody has to
            // review a question or mark it Done.
            _ = try await store.update(task.id, patch: fields([("result", fields([("at", .number(BackendTaskValues.time())), ("verified", .bool(true)), ("answer", .string(answer)), ("check", .null)]))]))
            try await comment(task.id, kind: "completion", text: told.isEmpty ? "(It finished without an answer.)" : told)
            try await setLifecycleStatus(task.id, key: "onVerified")
        } else if let parentID = task.value["reviewOfTaskId"].string {
            try await finishReviewer(task, parentID: parentID, answer: answer)
        } else if let reviewerID = agent?["reviewerAgent"].string, !reviewerID.isEmpty {
            _ = try await store.update(task.id, patch: fields([("result", fields([("at", .number(BackendTaskValues.time())), ("verified", .bool(false)), ("answer", .string(answer)), ("check", .null)]))]))
            try await startReviewer(task.id, reviewerID: reviewerID, turnID: turnID, workspace: session?.cwd ?? task.project)
        } else if let agent, agent["verifyCommand"].string?.isEmpty == false, !landedHere, !BackendTaskSessionGate.mayRunCommands(agent) {
            // #24: never run a shell command for an agent that may not run commands; the person checks it instead.
            _ = try await store.update(task.id, patch: fields([("result", fields([("at", .number(BackendTaskValues.time())), ("verified", .bool(false)), ("answer", .string(answer)), ("check", .string(BackendTaskSessionGate.commandsBlocked))]))]))
            try await block(task.id, text: "Finished, but its check command was not run: this agent is blocked from running commands. Check it yourself and mark it Done.\n\n" + told)
        } else if let command = agent?["verifyCommand"].string, !command.isEmpty, !landedHere {
            let generation = UUID(), cwd = session?.cwd ?? task.project, job = Task { [access] in
                if task.value["agoptSerializeHeavyJobs"].bool == true {
                    return try await BackendAGOPTCoordinator.shared.withLease(owner: "task:" + task.id + ":check:" + generation.uuidString.lowercased()) {
                        try await access.check(command, cwd)
                    }
                }
                return try await access.check(command, cwd)
            }; checks[task.id] = job; checkGenerations[task.id] = generation
            defer { if checkGenerations[task.id] == generation { checks[task.id] = nil; checkGenerations[task.id] = nil } }
            let check = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }, output = String(check.output.suffix(1_500))
            _ = try await store.update(task.id, patch: fields([("result", fields([("at", .number(BackendTaskValues.time())), ("verified", .bool(check.ok)), ("answer", .string(answer)), ("check", check.ok ? .null : .string(output))]))]))
            if check.ok { try await comment(task.id, kind: "completion", text: "Finished, and the check passed.\n\n" + told); try await setLifecycleStatus(task.id, key: "onVerified") }
            else { try await block(task.id, text: "Finished, but the check failed:\n\n" + output) }
            await knowledgeAdapter?.note(try await record(task.id), kind: check.ok ? "verified" : "rejected", summary: check.ok ? "The check passed: " + command : output, evidence: ["check: " + command])
        } else {
            _ = try await store.update(task.id, patch: fields([("result", fields([("at", .number(BackendTaskValues.time())), ("verified", .bool(false)), ("answer", .string(answer)), ("check", .null)]))]))
            if task.isLocal && task.value["requestedBy"].string == "hoot" {
                try await comment(task.id, kind: "completion", text: "Finished. Hoot is reviewing it.\n\n" + told)
                try await tellHoot(task.id, BackendTaskBriefComposition.hootNotice("\(who) finished the task \"\(title)\" that you asked for.", taskID: task.id,
                    next: "Look at what it did, then call tasks_review with pass and the evidence you checked, or fail with what is wrong."))
            } else if task.isLocal { try await comment(task.id, kind: "completion", text: "Finished. Check it and mark it Done.\n\n" + told); try await handToHuman(task.id) }
            else {
                try await comment(task.id, kind: "completion", text: "Finished. Hoot is checking it.\n\n" + told)
                try await tellHoot(task.id, BackendTaskBriefComposition.hootNotice("\(who) finished the CRM task \"\(title)\".", taskID: task.id,
                    next: "Read its result with tasks_get, then call tasks_verify with verified true if it is right, or false with what is missing."))
            }
        }
        if let agentID = task.value["agoptAgentID"].string { try await checkMonthlyBudget(agentID, task: task.id) }
        if let completion = task.value["agoptCompletion"].string {
            try await close(task.id)
            if completion == "stop" { _ = try await store.update(task.id, patch: fields([("conversationId", .null)])) }
            nudge(); await arm(); try await tellFinishedChildren(task); return
        }
        if access.freshJobChats {
            try await close(task.id); nudge(); await arm(); try await tellFinishedChildren(task); return
        }
        let minutes = agent?["keepAliveMinutes"].number ?? 0
        if agent?["keepAliveUntilClose"].bool == true { _ = try await store.update(task.id, patch: fields([("keepOpenUntil", .null), ("keepAliveUntilClose", .bool(true)), ("runStartedAt", .null)])) }
        else if minutes > 0 { _ = try await store.update(task.id, patch: fields([("keepOpenUntil", .number(BackendTaskValues.time() + minutes * 60_000)), ("keepAliveUntilClose", .bool(false)), ("runStartedAt", .null)])) }
        else { try await close(task.id) }; nudge(); await arm()
        try await tellFinishedChildren(task)
    }
    public func noteExit(sessionID: String, exitCode: Int) async throws {
        await BackendAGOPTCoordinator.shared.releaseSession(sessionID: sessionID)
        quiet[sessionID] = nil; observedStatus[sessionID] = nil; BackendTaskTypedBriefs.forget(sessionID: sessionID)
        let deliberate = closing.remove(sessionID) != nil
        guard !stopped, let task = try await store.bySession(sessionID) else { nudge(); return }
        try await store.release(task.id)
        if task.value["awaitingSetup"].bool == true || task.value["startFailed"].bool == true { _ = try await store.update(task.id, patch: fields([("awaitingSetup", .null), ("briefFile", .null), ("startFailed", .null)])) }
        if !deliberate && task.value["result"].isNullish && task.value["stopped"].bool != true {
            let why = "The session ended\(exitCode == 0 ? "" : " with exit code \(exitCode)") before the work was finished."
            try await block(task.id, text: why + " Reply on this task to continue.")
            try await stall(task.id, reason: "exited", text: why, say: false)
        }; nudge(); await arm()
    }
    public func stop() async throws {
        restartTasks.removeAll()
        stopped = true; hootJobs.values.forEach { $0.cancel() }; hootJobs.removeAll(); hootChain = nil; hootLive.removeAll(); hootWaiting.removeAll(); timer?.cancel(); timer = nil; let running = Array(jobs.values); running.forEach { $0.cancel() }; jobs.removeAll(); quiet.removeAll(); observedStatus.removeAll()
        let runningChecks = Array(checks.values); runningChecks.forEach { $0.cancel() }; checks.removeAll(); checkGenerations.removeAll()
        for job in running { _ = try? await job.value }; for job in runningChecks { _ = try? await job.value }
        for task in try await store.all() { if let session = task.sessionID { await BackendAGOPTCoordinator.shared.releaseSession(sessionID: session) } }
        try await store.stop(); try await config.stop(); try await goals.stop()
        // Session shutdown belongs to the one lifecycle owner, not this engine.
    }
    public func setStatus(_ id: String, status: String) async throws { try await applyStatus(try await record(id), status: status, strict: true) }
    /// task-engine.ts `setStatus`: a lifecycle change is silent when the connection does not know the status or
    /// none of our identities may speak for the task; `setTaskStatus` (strict) says why.
    private func applyStatus(_ task: BackendTaskRecord, status: String, strict: Bool) async throws {
        let connection = task.isLocal ? nil : try await config.connection(task.value["keyId"].string ?? "")
        if strict, !task.isLocal, connection == nil { throw NativeRPCError.invalidArguments("The CRM connection is gone.") }
        if task.value["crmStatus"].string == status { return }
        let allowed = task.isLocal ? BackendTaskLocalService.statuses : connection?["statuses"]["statuses"].elements?.compactMap(\.string) ?? []
        guard allowed.contains(status) else { if strict { throw NativeRPCError.invalidArguments("\(status) is not one of: \(allowed.joined(separator: ", ")).") }; return }
        var actor = task.value["assignee"]["identity"].string ?? "hoot"
        if !task.isLocal {
            // CRM-LINK: a task a person holds speaks as the CRM profile that gave it (user:<uuid>, echoed, never made up).
            let candidates = [task.value["assignee"]["identity"].string, connection?["hootIdentity"].string].compactMap { $0 } + (["human", "none"].contains(task.assigneeKind) ? [task.value["requestedBy"].string].compactMap { $0 } : [])
            let authorized = [task.value["mainAssignee"].string, task.value["creator"].string].compactMap { $0 }
            guard let by = candidates.first(where: authorized.contains) else { if strict { throw NativeRPCError(code: "access-denied", message: "None of Terminal Deck’s identities is this task’s main assignee or creator.") }; return }
            try requireOutgoing(task); actor = by
            try await outgoing!(task, fields([("type", .string("task.status")), ("status", .string(status)), ("actor", .string(by))]))
        } else { try await store.note(task.id, by: actor, kind: "status", text: "Status: " + status) }
        _ = try await store.update(task.id, patch: task.isLocal ? fields([("crmStatus", .string(status)), ("completedAt", status == "Done" ? .number(BackendTaskValues.time()) : .null)]) : fields([("crmStatus", .string(status))]))
        if task.isLocal { await localStatusObserver?(task.id, BackendTaskActor.current) }
    }
    private func launch(_ id: String, agent given: NativeRPCValue, reply: String?, replyBy: String? = nil) async throws {
        let task = try await decidePlaybook(try await record(id)); try requireOutgoing(task)
        let agent = Self.playbookAgent(task, given)
        let name = agent["name"].string ?? task.agentID
        if reply == nil, let refusal = Self.delegationRefusal(agent) { try await block(id, text: refusal); return }
        let contextDelta = BackendPCContextDelta.make(task)
        let brief: String
        if reply == nil || task.value["conversationId"].isNullish {
            brief = try await agentBrief(task, agent: agent) + (reply.map { "\n\n## \(replyBy.map { "What \($0) wrote on the task" } ?? "Reply on the task")\n\n" + BackendTaskBriefComposition.quoted($0, maximum: 20_000) } ?? "")
        } else { brief = BackendTaskBriefComposition.agentReply(title: task.value["title"].string ?? "", taskID: task.id, text: reply ?? "", by: replyBy) + contextDelta.text + BackendTaskBriefComposition.stack(agent) }
        let cwd: String
        do { cwd = try await workspace(task) } catch { try await block(id, text: "Could not prepare the folder \(name) works in: \(error.localizedDescription)"); return }
        var launchAgent = agent
        var resume = reply == nil ? nil : task.value["conversationId"].string
        var launchBrief = brief
        if let extra = agent["extraTaskInstructions"].string, !extra.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            launchBrief += "\n\n## Extra instructions for every task\n\n" + extra
        }
        // Deck Memory (L4 AGENTS, MEMORY-SPEC §3): a lead or permanent agent with a memory starts a NEW job on a
        // clean desk: a fresh conversation whose brief carries the notes that fit the job. Nil = as before.
        let memoryStart = reply == nil ? await BackendAGTJobStart.shared?.plan(agent: agent,
            title: task.value["title"].string ?? "", details: task.value["instructions"].string ?? "") : nil
        // A hand added on a seat starts on a clean desk too: its own new session, never another hand's.
        let handTask = task.value["agtHand"].bool == true
        let cleanDesk = access.freshJobChats || memoryStart?.cleanDesk == true || handTask
        if cleanDesk { resume = nil }
        if let memoryStart { launchBrief += memoryStart.brief }
        if task.value["parallelJob"].bool == true, let parallel, let copy = await parallel.copy(of: task.id) {
            launchBrief += BackendParallelJobs.brief(branch: copy.branch, folder: copy.path)
            if reply == nil { try await store.note(id, by: task.agentID, kind: "progress", text: "Running beside this agent's other jobs, in its own copy: branch \(copy.branch).") }
        }
        var reusedSession: BackendSessionMeta?, reusedFrom: String?
        var resolvedProfile: String?
        if let settings {
            let owner = Self.playbookOwner(task, try await settings(agent))
            let effective = try BackendAGOPTTaskPolicy.applying(task, to: owner)
            resolvedProfile = try await profileID?(agent, cwd)
            let own = try await ownSettings?(agent).map { BackendPlaybookLayer.carried($0, to: effective.provider) }
            let sources = BackendPlaybookLayer.sources(layer: BackendPlaybookLayer(wire: task.value["playbook"]), own: own, launched: effective, task: task.value)
            let holder = handTask ? nil : try await liveHolder(task, agent: agent, cwd: cwd, settings: effective)
            launchAgent = launchAgent.setting("agoptSettings", try BackendAGSCodec.value(owner))
                .setting("model", effective.model.map(NativeRPCValue.string) ?? .null)
                .setting("effort", effective.effort.map(NativeRPCValue.string) ?? .null)
            // The playbook chose another AI than the agent's own: the session signs in with that AI's account for this
            // seat/project (the one answer profileID gives), never the agent's account for its own AI.
            if agent["provider"] != given["provider"], let resolvedProfile { launchAgent = launchAgent.setting("account", .string(resolvedProfile)) }
            let runtime = try await store.agentRuntime(agent["id"].string ?? task.agentID)
            let generation = runtime["reuse_generation"].number ?? 0
            if resume == nil, !cleanDesk {
                resume = BackendAGOPTTaskPolicy.parkedConversation(for: task, agent: agent, cwd: cwd,
                    settings: effective, records: try await store.all().filter { ($0.value["agoptReuseGeneration"].number ?? 0) == generation }, profileID: resolvedProfile)
            }
            let rows = try await store.all()
            if let chosen = resume, runtime["fresh_pending"].bool == true { resume = nil; _ = chosen }
            let baseline = resume.flatMap { conversation in
                rows.filter { row in row.value["conversationId"].string == conversation && row.value["keyId"] == task.value["keyId"] &&
                    row.value["notificationKeyId"] == task.value["notificationKeyId"] && row.project == task.project && row.value["projectId"] == task.value["projectId"] &&
                    BackendAGOPTTaskPolicy.sameScope(row, agent: agent, cwd: cwd, settings: effective, profileID: resolvedProfile) }
                    .compactMap { $0.value["agoptUsageTotal"].number }.max()
            } ?? 0
            let prior = resume.flatMap { conversation in
                rows.filter { row in
                    row.value["conversationId"].string == conversation && row.value["keyId"] == task.value["keyId"] &&
                    row.value["notificationKeyId"] == task.value["notificationKeyId"] && row.project == task.project && row.value["projectId"] == task.value["projectId"] &&
                    BackendAGOPTTaskPolicy.sameScope(row, agent: agent, cwd: cwd, settings: effective, profileID: resolvedProfile)
                }.sorted { ($0.value["result"]["at"].number ?? 0) > ($1.value["result"]["at"].number ?? 0) }
                    .compactMap { $0.value["lastTurn"].string ?? $0.value["agoptPriorTurn"].string }.first
            }
            _ = try await store.update(id, patch: BackendAGOPTTaskPolicy.snapshot(agent: agent, cwd: cwd, settings: effective, profileID: resolvedProfile)
                .setting("tokenUsageByAgent", BackendAGOPTTaskPolicy.usageByAgent(task))
                .setting("agoptReuseGeneration", .number(generation))
                .setting("agoptRunID", .string(UUID().uuidString.lowercased())).setting("agoptRunRetired", .bool(false)).setting("agoptUsageMeasured", .bool(false))
                .setting("agoptPriorTurn", prior.map(NativeRPCValue.string) ?? .null)
                .setting("agoptTaskTokenBudget", .number(Double(effective.efficiency?.taskTokenBudget ?? 0)))
                .setting("agoptAgentTokenBudget", .number(Double(effective.efficiency?.agentTokenBudget ?? 0)))
                .setting("agoptWarningPercent", .number(Double(effective.efficiency?.warningPercent ?? 80)))
                .setting("agoptUsageTotal", .number(baseline))
                .setting("agoptSources", sources).setting("agoptPermission", effective.permissionMode.map(NativeRPCValue.string) ?? .null))
            launchBrief += BackendAGOPTTaskPolicy.instructions(effective, profileID: agent["id"].string ?? task.agentID, retained: BackendAGOPTTaskPolicy.retainsSession(agent))
            if let holder {
                if let total = try await usageBaseline?(holder.session) { try await noteTokenUsage(sessionID: holder.session.id, totalTokens: total,
                    expectedTaskID: holder.task.id, expectedAssignee: holder.task.value["assignee"], expectedRunID: holder.task.value["agoptRunID"].string) }
                guard let currentHolder = try await store.bySession(holder.session.id), currentHolder.id == holder.task.id,
                      currentHolder.value["assignee"] == holder.task.value["assignee"], currentHolder.value["agoptRunID"] == holder.task.value["agoptRunID"] else { throw CancellationError() }
                if !cleanDesk, effective.efficiency?.reuseContext != false, BackendAGOPTTaskPolicy.sameControls(holder.task, settings: effective) {
                    let live = Set(await access.sessions().filter { $0.exitCode == nil }.map(\.id))
                    guard try await store.transferSession(from: holder.task.id, to: id, expectedAssignee: task.value["assignee"], liveSessionIDs: live, expectedChoices: task.value) else {
                        throw NativeRPCError(code: "task-reuse-changed", message: "The existing task session changed before it could be reused. This task was not sent.")
                    }
                    reusedSession = holder.session; reusedFrom = holder.task.id
                    do {
                        // (a) The brief goes in a file and one short line points at it (the driver does that for
                        // any long text): a brief typed whole into a session's prompt arrived as its tail only.
                        try await requireDecision(id, expected: task, sending: true)
                        try await BackendPCDecisionDelivery.$required.withValue(PCDecisions.requires(task.value)) {
                            try await BackendPCDecisionDelivery.$hostedReference.withValue(PCDecisions.requires(task.value) ? BackendPCDecisionMarker.executionReference(task) : nil) {
                                try await BackendPCDecisionDelivery.$validate.withValue(decisionValidation(task, sending: true)) { try await access.send(holder.session.id, BackendTaskTypedBriefs.reusedLine + "\n\n" + launchBrief) }
                            }
                        }
                        await noteTyped(holder.session.id, BackendTaskTypedBriefs.reusedLine + "\n\n" + launchBrief, task: task)
                    }
                    catch {
                        // L8 (10 Oct): leave the session open; a delivery doubt never kills a worker.
                        throw NativeRPCError(code: "brief-not-delivered", message: "The new task brief was not delivered to the reused session, which was left open: " + error.localizedDescription)
                    }
                } else {
                    let conversation = holder.session.agentSessionId ?? holder.task.value["conversationId"].string
                    try await close(holder.task.id)
                    if !cleanDesk, effective.efficiency?.reuseContext != false {
                        _ = try await store.update(holder.task.id, patch: fields([("agoptCompletion", .string("park")), ("agoptReuseContext", .bool(true))]))
                        resume = conversation
                        _ = try await store.update(id, patch: fields([("agoptUsageTotal", (try await record(holder.task.id)).value["agoptUsageTotal"].isNullish ? .number(0) : (try await record(holder.task.id)).value["agoptUsageTotal"]),
                            ("agoptPriorTurn", holder.task.value["lastTurn"].isNullish ? holder.task.value["agoptPriorTurn"] : holder.task.value["lastTurn"])]))
                    }
                }
            }
        }
        // If account/reset policy removed the resume target, restore the full brief.
        if reply != nil, resume == nil, reusedSession == nil, !task.value["conversationId"].isNullish {
            let full = try await agentBrief(task, agent: agent) + "\n\n## Reply on the task\n\n" + BackendTaskBriefComposition.quoted(reply ?? "", maximum: 20_000)
            launchBrief = full + String(launchBrief.dropFirst(brief.count))
        }
        let session: BackendSessionMeta
        if let reusedSession { session = reusedSession }
        else {
            try await requireDecision(id, expected: task)
            session = try await BackendPCDecisionDelivery.$required.withValue(PCDecisions.requires(task.value)) {
                try await BackendPCDecisionDelivery.$hostedReference.withValue(PCDecisions.requires(task.value) ? BackendPCDecisionMarker.executionReference(task) : nil) {
                    try await BackendPCDecisionDelivery.$validate.withValue(decisionValidation(task)) { try await access.start(task, launchAgent, cwd, launchBrief, resume) }
                }
            }
            await noteTyped(session.id, BackendTaskTypedBriefs.firstLine, task: task)
        }
        let current = try await record(id)
        guard !stopped, current.value["stopped"].bool != true, current.agentID == task.agentID else { try await access.stop(session.id); return }
        var liveIDs = Set(await access.sessions().filter { $0.exitCode == nil }.map(\.id))
        if access.freshJobChats { liveIDs.insert(session.id) }
        do {
            guard try await store.claim(id, sessionID: session.id, liveSessionIDs: liveIDs, expectedAssignee: task.value["assignee"]) else { closing.insert(session.id); try await access.stop(session.id); return }
        } catch {
            closing.insert(session.id); try? await access.stop(session.id)
            // A changed assignment belongs to its new run; do not block it
            // because the previous launch lost its claim.
            let latest = try await record(id)
            if latest.value["assignee"] != task.value["assignee"] || latest.value["stopped"].bool == true { return }
            throw error
        }
        _ = try await store.update(id, patch: fields([("reusedFromTask", reusedFrom.map(NativeRPCValue.string) ?? .null), ("startFailed", .null), ("awaitingSetup", .null), ("briefFile", .null),
            ("runStartedAt", .number(BackendTaskValues.time())), ("keepOpenUntil", .null), ("keepAliveUntilClose", .bool(false)), ("questionOpen", .bool(false)), ("stalled", .null), ("conversationId", session.agentSessionId.map(NativeRPCValue.string) ?? task.value["conversationId"]), ("agoptProfileID", (session.profileId ?? resolvedProfile).map(NativeRPCValue.string) ?? .null), ("agoptSessionName", .string(session.title))]))
        if reply != nil, resume != nil {
            let delivered = try BackendTaskRecord(current.value.setting("sessionId", .string(session.id)))
            try await store.acknowledgeContext(id, packet: contextDelta, expected: delivered)
        }
        let runtime = try await store.agentRuntime(agent["id"].string ?? task.agentID)
        if runtime["resume_once_pending"].bool == true, let run = (try await record(id)).value["agoptRunID"].string {
            try await store.updateAgentRuntime(agent["id"].string ?? task.agentID, patch: fields([("resume_once_pending", .bool(false)), ("resume_once_run", .string(run))]))
        }
        quiet[session.id] = BackendTaskValues.time()
        if settings == nil { for key in ["model", "effort"] { if let value = agent[key].string { do { try await access.setControl(session.id, key, value) } catch { try await comment(id, kind: "progress", text: "Could not set \(key) \(value): \(error.localizedDescription).") } } } }
        try await setLifecycleStatus(id, key: "onStarted")
        await notify(id, type: "task.started", body: "\(name) \(reply == nil ? "started on this." : "is continuing with the reply.")")
        try await comment(id, kind: "progress", text: "\(name) \(reply == nil ? "started on this." : "is continuing with the reply.")")
        if reply == nil { await knowledgeAdapter?.note(try await record(id), kind: "delegated", summary: head(task.value["instructions"].string ?? "", 500)) }
        await access.activate(session.id)
    }
    /// agent-lifecycle.ts delegationRefusal.
    nonisolated static func delegationRefusal(_ agent: NativeRPCValue) -> String? {
        let name = agent["name"].string ?? "This agent"
        if agent["status"].string == "paused" { return "\(name) is paused, so it is not taking new work. Resume it in Settings → Tasks, or give this to another agent." }
        if agent["status"].string == "archived" { return "\(name) is archived, so it is not taking work. Restore it in Settings → Tasks, or give this to another agent." }
        return nil
    }
    /// task-engine.ts agentBrief: what a freshly started worker is told.
    private func agentBrief(_ task: BackendTaskRecord, agent: NativeRPCValue) async throws -> String {
        let agents = try await config.allAgents(), names = Dictionary(uniqueKeysWithValues: agents.compactMap { row in row["id"].string.map { ($0, row["name"].string ?? $0) } }).merging(["me": "You", "hoot": "Hoot", "none": "Nobody"], uniquingKeysWith: { _, new in new })
        let known = try await knowledgeFor(task), chain = try await task.value["goalId"].string.asyncMap { try await self.goals.chain($0) } ?? []
        // FORK-TASKS: the same wording rules as Hoot's brief (title once, the id the tools take once, the
        // project by name, the task's own words quoted), and no talk of task tools to an AI that has none.
        let title = task.value["title"].string ?? "", body = task.value["instructions"].string ?? ""
        return BackendTaskBriefComposition.agentHeader(title: title, taskID: task.id, project: await projectLine(task), givenBy: await givenBy(task),
                local: task.isLocal, tools: BackendTaskBriefComposition.hasTaskTools(agent)) +
            BackendTaskBriefComposition.stack(agent) + BackendTaskBriefComposition.goals(chain) + BackendTaskBriefComposition.agentTask(title: title, body: body) +
            BackendTaskBriefComposition.context(task, all: try await store.all(), names: names) + BackendTaskBriefComposition.retry(task) + known
    }
    /// "Project: iMatch (folder …)": the project's own name when the app knows it.
    private func projectLine(_ task: BackendTaskRecord) async -> String {
        var name = await projectName?(task)
        if name == nil {
            let id = PROJProjects.resolve(projectID: task.value["projectId"].string, folder: task.project)
            if id != PROJProjects.independentID { name = PROJProjects.name(for: id) }
        }
        let line = BackendTaskBriefComposition.projectLine(name: name, folder: task.project)
        guard let note = await projectNote?(task), !note.isEmpty else { return line }
        return line + "\n" + note
    }
    /// "Servers linked to this project: a, b." from the project's saved "Linked servers" (comma-separated names).
    public nonisolated static func linkedServersLine(_ raw: String?) -> String? {
        let names = (raw ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        return "Servers linked to this project: " + names.joined(separator: ", ") + " (reach them with the servers tools, such as servers_look)."
    }
    /// Who gave the task to its present holder: the last "assigned" line on a local task, the CRM's requester otherwise.
    private func givenBy(_ task: BackendTaskRecord) async -> String { await giver(task).name }
    /// Who gave the task, as a kind and a name: the person, Hoot, an agent, an AI app, the CRM, or the app itself.
    private func giver(_ task: BackendTaskRecord) async -> (kind: BackendTaskTypedBrief.Giver, name: String) {
        if !task.isLocal { return (.crm, task.value["requestedBy"].string.map { "\($0), through the CRM" } ?? "the CRM") }
        let line = (task.value["notes"].elements ?? []).last { $0["kind"].string == "assigned" || ($0["text"].string ?? "").hasPrefix("Created, assigned to") }
        let id = line?["by"].string ?? task.value["requestedBy"].string
        guard let id, !id.isEmpty, id != "me" else { return (.person, BackendTaskBriefComposition.person(nil)) }
        if id == "hoot" { return (.hoot, "Hoot") }
        // A review the engine itself started for another task's result.
        if id.hasPrefix("reviewer:") { return (.app, BackendSharedBrand.name + " (a review of another task)") }
        // The person's own phone or tablet: the person, named by the device.
        if let device = BackendTaskActor.deviceActorName(id) { return (.person, device) }
        if BackendTaskActor.appActorName(id) != nil { return (.app, BackendTaskBriefComposition.person(id)) }
        return (.agent, (try? await config.agent(id))?["name"].string ?? id)
    }
    private func personName(_ id: String?) async -> String {
        guard let id, !["me", "hoot"].contains(id), BackendTaskActor.outsideActorName(id) == nil else { return BackendTaskBriefComposition.person(id) }
        return (try? await config.agent(id))?["name"].string ?? id
    }
    /// FORK-TASKS (11 Oct, real-app test row 113): what the engine types into an agent's session for a task
    /// is the APP's, written for whoever gave the task. Told to the memory flow right after the write, so the
    /// diary row no longer reads as Hoot's.
    private func noteTyped(_ sessionID: String, _ text: String, task: BackendTaskRecord) async {
        let who = await giver(task)
        // Long text is not typed: the driver puts it in a file and types the line that points at it.
        let typed = flatten(text).utf16.count > BackendTaskTypedBriefs.inlineLimit ? BackendTaskTypedBriefs.pointerTail : text
        BackendTaskTypedBriefs.note(.init(sessionID: sessionID, taskID: task.id, text: typed, givenByKind: who.kind, givenBy: who.name, at: BackendTaskValues.time()))
    }
    /// (c) The session that was on Claude Code's setup screen shows its prompt now: the brief goes in (the same
    /// first line a new worker is typed) and the task starts, as if nothing had been in the way.
    private func startAfterSetup(_ id: String) async {
        guard !stopped, !starting.contains(id) else { return }
        starting.insert(id); defer { starting.remove(id) }
        do {
            guard let task = try await store.byID(id), task.value["awaitingSetup"].bool == true, task.value["stopped"].bool != true,
                  let session = task.sessionID, await alive(session), let file = task.value["briefFile"].string else { return }
            try await requireDecision(id, expected: task, sending: true)
            try await BackendPCDecisionDelivery.$required.withValue(PCDecisions.requires(task.value)) {
                try await BackendPCDecisionDelivery.$hostedReference.withValue(PCDecisions.requires(task.value) ? BackendPCDecisionMarker.executionReference(task) : nil) {
                    try await BackendPCDecisionDelivery.$validate.withValue(decisionValidation(task, sending: true)) { try await NativeCompositionCallContext.$rpc.withValue(nil) { try await self.access.send(session, BackendDeckCoreBrief.deliveryLine(file)) } }
                }
            }
            _ = try await store.update(id, patch: fields([("awaitingSetup", .null), ("briefFile", .null), ("process", .string("running")), ("runStartedAt", .number(BackendTaskValues.time()))]))
            quiet[session] = BackendTaskValues.time()
            await noteTyped(session, BackendTaskTypedBriefs.firstLine, task: task)
            let name = (try await config.agent(task.agentID))?["name"].string ?? task.agentID
            try await setLifecycleStatus(id, key: "onStarted")
            await notify(id, type: "task.started", body: "\(name) started on this.")
            try await comment(id, kind: "progress", text: "\(name) started on this.")
        } catch {
            // Still not at its prompt (the setup is not finished): it goes on waiting; the next empty prompt tries again.
        }
    }
    private func knowledgeFor(_ task: BackendTaskRecord) async throws -> String {
        guard !task.project.isEmpty else { return "" }
        var text = ""
        if let knowledge { do { text = try await knowledge(task) } catch { await problem("Project knowledge was unavailable for this brief: " + error.localizedDescription) } }
        else if let knowledgeAdapter { text = await knowledgeAdapter.brief(task) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "" : "\n\n## What is known about this project\n\n" + head(text, 4_000)
    }
    /// The brief a coordinating Hoot is told about a task assigned to it.
    private func hootBrief(_ task: BackendTaskRecord) async throws -> String {
        let agents = try await config.allAgents().filter { $0["status"].string != "archived" }.map { "\($0["name"].string ?? "") (\($0["role"].string ?? "")\($0["status"].string == "paused" ? ", paused" : ""))" }
        let chain = try await task.value["goalId"].string.asyncMap { try await self.goals.chain($0) } ?? []
        return BackendTaskBriefComposition.hootAssigned(title: task.value["title"].string ?? "", taskID: task.id, body: task.value["instructions"].string ?? "",
            project: await projectLine(task), givenBy: await givenBy(task), agents: agents, goals: BackendTaskBriefComposition.goals(chain), local: task.isLocal)
    }
    private func close(_ id: String) async throws {
        let task = try await record(id); guard let session = task.sessionID, !closing.contains(session) else { return }; closing.insert(session)
        if let meta = await access.sessions().first(where: { $0.id == session }), let conversation = meta.agentSessionId { _ = try await store.update(id, patch: fields([("conversationId", .string(conversation))])) }
        do { try await access.stop(session); await BackendAGOPTCoordinator.shared.releaseSession(sessionID: session); try await store.release(id); _ = try await store.update(id, patch: fields([("keepAliveUntilClose", .bool(false))])); quiet[session] = nil; observedStatus[session] = nil }
        catch { closing.remove(session); throw error }
    }
    private func block(_ id: String, text: String, by: String? = nil) async throws {
        try await comment(id, kind: "blocker", text: text, by: by); try await setLifecycleStatus(id, key: "onBlocked"); try await handToHuman(id)
        let task = try await record(id); if task.sessionID == nil { _ = try await store.update(id, patch: fields([("process", .string("exited"))])) }
    }
    public func comment(_ id: String, kind: String, text: String, by: String? = nil) async throws {
        // FORK-TASKS: what Hoot posts itself during its task turn is remembered, so its closing answer is
        // not posted a second time when it says the same thing.
        if hootLive[id] != nil, let by, let task = try await store.byID(id), by == (try await hootIdentity(task)) { hootLive[id]?.said.append(text) }
        try await post(id, kind: kind, text: text, by: by)
    }
    public func progressOnce(_ id: String, text: String, by: String, eventID: String) async throws -> Bool {
        guard text.count <= 8_000 else { throw NativeRPCError.invalidArguments("A receipt-backed progress report must fit in 8,000 characters") }
        let created = try await store.progressOnce(id, by: by, text: text, eventID: eventID)
        if created {
            if hootLive[id] != nil, let task = try await store.byID(id), by == (try await hootIdentity(task)) { hootLive[id]?.said.append(text) }
            await notify(id, type: "task.progress", body: head(text, 8_000))
        }
        return created
    }
    // MARK: Lead seats (L4-AGENTS, 11 Oct): a task held by a project's lead seat that a session fills.
    /// `BackendAGTLeadSeats` typed the task into the seat's session (`session`), or nobody fills the seat
    /// right now (nil: it waits). Only the task's own state is kept here.
    public func seatTold(_ id: String, session: String?) async throws {
        guard let task = try await store.byID(id), task.assigneeKind == BackendAGTLeadSeats.kind, task.value["result"].isNullish, task.value["stopped"].bool != true else { return }
        guard let session else {
            if task.process != "queued" || !task.value["seatSession"].isNullish { _ = try await store.update(id, patch: fields([("process", .string("queued")), ("runStartedAt", .null), ("seatSession", .null)])) }
            return
        }
        _ = try await store.update(id, patch: fields([("process", .string("running")), ("runStartedAt", .number(BackendTaskValues.time())), ("seatSession", .string(session)), ("seatToldAt", .number(BackendTaskValues.time()))]))
        try await setLifecycleStatus(id, key: "onStarted")
    }
    /// The seat's session wrote on its own task (tasks_comment). A question asked from another task's
    /// comments is finished once it is answered; any other task is finished when the lead says so
    /// (kind completion), and the owner then checks it and marks it Done.
    public func seatSpoke(_ id: String, kind: String, text: String) async throws {
        guard let task = try await store.byID(id), task.assigneeKind == BackendAGTLeadSeats.kind, task.value["result"].isNullish else { return }
        let asked = task.value["askedFromTask"].string != nil
        guard asked ? kind != "question" : kind == "completion" else { return }
        _ = try await store.update(id, patch: fields([("result", fields([("at", .number(BackendTaskValues.time())), ("verified", .bool(asked)), ("answer", .string(head(text, 3_000))), ("check", .null)])),
                                                      ("process", .string("exited")), ("runStartedAt", .null)]))
        if asked { try await setLifecycleStatus(id, key: "onVerified") }
        else { await notify(id, type: "task.finished", body: head(text, 300)) }
        try await tellFinishedChildren(try await record(id))
    }
    private func post(_ id: String, kind: String, text: String, by: String? = nil) async throws {
        let task = try await record(id), body = head(text, 8_000)
        if task.isLocal { try await store.note(id, by: by ?? task.value["assignee"]["identity"].string ?? "hoot", kind: kind, text: body)
            // CRM-LINK: an agent Hoot asked from a CRM task answers in that task's thread under its own name; Hoot hears what it finished, asked or hit.
            if let thread = task.value["crmThreadOf"].string, by == nil || by == task.agentID, let parent = try await store.byID(thread), let outgoing {
                let connection = try await config.connection(parent.value["keyId"].string ?? "")
                let actor = connection.map { BackendCrmLink.identity(ofAgent: task.agentID, connection: $0) } ?? "agent:" + task.agentID
                try? await outgoing(parent, fields([("type", .string("task.comment")), ("actor", .string(actor)), ("comment", fields([("kind", .string(kind == "completion" ? "note" : kind)), ("body", .string(body)), ("inReplyTo", .null)]))]))
                if ["completion", "question", "blocker"].contains(kind), parent.assigneeKind == "hoot" {
                    let name = (try? await config.agent(task.agentID))?["name"].string ?? task.agentID
                    try? await reply(thread, text: "\(name) (\(kind)) on the part you asked for: \(body)")
                }
            }
        }
        else { try requireOutgoing(task); try await outgoing!(task, fields([("type", .string("task.comment")), ("actor", by.map(NativeRPCValue.string) ?? task.value["assignee"]["identity"]), ("comment", fields([("kind", .string(kind)), ("body", .string(body)), ("inReplyTo", .null)]))])) }
        if let type = ["progress": "task.progress", "question": "task.question", "blocker": "task.blocked", "completion": task.value["result"].isNullish ? "task.progress" : "task.finished"][kind] { await notify(id, type: type, body: body) }
    }
    private func handToHuman(_ id: String) async throws {
        let task = try await record(id); guard task.isLocal, task.assigneeKind != "human" else { return }
        let from = task.assigneeKind == "agent" ? task.agentID : task.value["handedFrom"].string
        _ = try await store.update(id, patch: fields([("assignee", BackendTaskLocalService.assignment("me", kind: "human")), ("mainAssignee", .string("me")), ("handedFrom", from.map(NativeRPCValue.string) ?? .null)]))
        try await store.note(id, by: from ?? "hoot", kind: "assigned", text: "Handed to you.")
        await notify(id, type: "task.needs-reply", body: "This task needs your reply.", agentID: from)
    }
    private func arm() async {
        timer?.cancel(); timer = nil; guard !stopped else { return }
        do {
            // U140 (#194): this runs after almost every action. Only a task with a session can fall due (runDue looks at
            // no other), so only those are looked at, with one list of live sessions and one look per agent per pass.
            var next: Double?, agents: [String: NativeRPCValue?] = [:]
            let held = try await store.all().filter { $0.sessionID != nil }
            let live = held.isEmpty ? [] : Set(await access.sessions().filter { $0.exitCode == nil }.map(\.id))
            for task in held {
                var due = task.value["keepOpenUntil"].number
                if due == nil, let started = task.value["runStartedAt"].number {
                    if agents[task.agentID] == nil { agents[task.agentID] = .some(try await config.agent(task.agentID)) }
                    if let minutes = agents[task.agentID]??["maxRunMinutes"].number, minutes > 0 { due = started + minutes * 60_000 }
                }
                if let since = try await quietSince(task, live: live) { due = min(due ?? .infinity, since + 15 * 60_000) }
                if let due { next = min(next ?? .infinity, due) }
            }
            if let next { let wait = Int(min(max(0, next - BackendTaskValues.time()), 3_600_000)); timer = BackendTaskTimers.schedule(milliseconds: Double(wait)) { [weak self] in await self?.runDue() } }
        } catch { await problem(error.localizedDescription) }
    }
    public func wake() async { await runDue() }
    private func runDue() async {
        guard !stopped else { return }
        do {
            let now = BackendTaskValues.time()
            var agents: [String: NativeRPCValue?] = [:]
            for task in try await store.all() where task.sessionID != nil {
                if task.value["keepAliveUntilClose"].bool == true { continue }
                // HOOTFIX: close first; the keep-open mark is cleared only once the worker is
                // really gone (a failed close used to leave an unmarked worker holding the folder).
                if let until = task.value["keepOpenUntil"].number, until <= now {
                    do { try await close(task.id); _ = try await store.update(task.id, patch: fields([("keepOpenUntil", .null)])) }
                    catch { await problem("A kept-open task worker could not be closed: " + error.localizedDescription) }
                    continue
                }
                if agents[task.agentID] == nil { agents[task.agentID] = .some(try await config.agent(task.agentID)) }
                if let started = task.value["runStartedAt"].number, let minutes = agents[task.agentID]??["maxRunMinutes"].number, minutes > 0, started + minutes * 60_000 <= now {
                    _ = try await store.update(task.id, patch: fields([("runStartedAt", .null)])); try await close(task.id); try await block(task.id, text: "Stopped after \(Int(minutes)) minutes, the longest this agent may run. Reply on this task to continue."); continue
                }
                if let since = try await quietSince(task), since + 15 * 60_000 <= now { try await stall(task.id, reason: "quiet", text: "No sign of work for 15 minutes, and it has neither finished nor asked anything.", say: true) }
            }; try await pump()
        } catch { await problem(error.localizedDescription) }; await arm()
    }
    private func setLifecycleStatus(_ id: String, key: String) async throws {
        let task = try await record(id)
        let status: String? = task.isLocal ? ["onStarted": "Working on it", "onVerified": "Done", "onBlocked": "Stuck"][key] : try await config.connection(task.value["keyId"].string ?? "")?["statuses"][key].string
        if let status { try await applyStatus(task, status: status, strict: false) }
    }
    private func stall(_ id: String, reason: String, text: String, say: Bool) async throws {
        _ = try await store.update(id, patch: fields([("stalled", fields([("at", .number(BackendTaskValues.time())), ("reason", .string(reason)), ("text", .string(text))]))]))
        if say { try await comment(id, kind: "blocker", text: "Stalled: " + text); try await setLifecycleStatus(id, key: "onBlocked") }
        let task = try await record(id)
        await knowledgeAdapter?.note(task, kind: "stalled", summary: text)
        if try await coordinated(task) {
            let next = task.isLocal ? "Look at it with tasks_progress, then try it again with tasks_retry or give it to another agent with tasks_reassign." : "Its CRM task is marked as stuck; post what happens next with tasks_comment."
            try await tellHoot(id, BackendTaskBriefComposition.hootNotice("The task \"\(head(task.value["title"].string ?? "", 80))\" has stalled: \(text)", taskID: task.id, next: next))
        }
    }
    private func tellHoot(_ id: String, _ message: String, kind: HootTurnKind = .notice) async throws {
        try await requireDecision(id)
        // FORK-TASKS: with Hoot's chat bound, the task goes there as a task turn (no user bubble) and Hoot's
        // answer comes back to be posted on the task. It is queued and this returns at once: Hoot may be busy.
        if hootTurns != nil, let task = try await store.byID(id) {
            if task.assigneeKind == "hoot" { _ = try await store.update(id, patch: fields([("hootTurnOpen", .bool(true))])) }
            enqueueHootTurn(BackendHootTaskTurn(taskID: task.id, title: head(task.value["title"].string ?? "", 200),
                body: task.value["instructions"].string ?? "", brief: message, projectID: task.value["projectId"].string,
                decisionScope: PCDecisions.requires(task.value) ? BackendPCDecisionMarker.fingerprint(task) : nil), kind: kind)
            return
        }
        _ = try await tellHootInChat(id, message)
    }
    /// One at a time and in the order they were asked, whatever task they are about.
    private func enqueueHootTurn(_ turn: BackendHootTaskTurn, kind: HootTurnKind) {
        let previous = hootChain, token = UUID(), epoch = hootEpoch[turn.taskID] ?? 0
        hootWaiting[turn.taskID, default: 0] += 1
        // Detached: a turn can last minutes and must not inherit the caller's request or completion fence.
        // The task clock is carried over (as the engine's timers do); nothing else is.
        let clock = BackendTaskClockContext.clock
        let job = Task.detached { [weak self] in
            await previous?.value
            guard let engine = self else { return }
            await BackendTaskClockContext.withClock(clock) { await engine.runHootTurn(turn, kind: kind, token: token, epoch: epoch) }
            await engine.hootJobEnded(token)
        }
        hootJobs[token] = job; hootChain = job
    }
    private func hootJobEnded(_ token: UUID) { hootJobs[token] = nil }
    /// The task was stopped, deleted or given to someone else: Hoot's work on it stops now. A turn that is
    /// running is interrupted in Hoot's chat, one still waiting is never started, and whatever comes back
    /// from it is not posted as an answer. True when Hoot had really started on it.
    @discardableResult private func stopHootTurn(_ id: String) async -> Bool {
        guard (hootWaiting[id] ?? 0) > 0 else { return false }
        hootEpoch[id, default: 0] += 1
        let working = hootLive[id]?.startedAt != nil
        if let live = hootLive[id] { hootJobs[live.token]?.cancel() }
        await hootStop?(id)
        return working
    }
    /// The task is being deleted. Hoot's turn on it is stopped, and so is a session that was only just being
    /// started for it (a session that already holds it is stopped by `cancel`, as before).
    public func taskRemoved(_ id: String) async {
        restartTasks[id] = nil; decisionNudges[id] = nil
        jobs[id]?.cancel(); checks[id]?.cancel()
        guard (hootWaiting[id] ?? 0) > 0 else { return }
        await stopHootTurn(id)
        if let task = try? await store.byID(id), task.assigneeKind == "hoot" {
            _ = try? await store.update(id, patch: fields([("hootTurnOpen", .bool(false)), ("process", .string("idle")), ("runStartedAt", .null)]))
        }
    }
    private func runHootTurn(_ turn: BackendHootTaskTurn, kind: HootTurnKind, token: UUID, epoch: Int) async {
        let id = turn.taskID
        defer {
            if let left = hootWaiting[id] { hootWaiting[id] = left > 1 ? left - 1 : nil }
            if hootLive[id]?.token == token { hootLive[id] = nil }
            // U140 (#362): the epoch only tells queued turns apart from a stop. With none left for the task, a new turn
            // starts from 0 again, so the count is dropped instead of kept for every task ever stopped.
            if hootWaiting[id] == nil { hootEpoch[id] = nil }
        }
        guard !stopped, let hootTurns else { return }
        // T19: the app is closing. Nothing new goes to Hoot; the task keeps its mark for the next start.
        if await appClosing() { return }
        do {
            // Given to someone else, stopped or deleted while it waited its turn: there is nothing to hand over.
            guard (hootEpoch[id] ?? 0) == epoch, let task = try await store.byID(id), task.value["stopped"].bool != true, kind == .notice || task.assigneeKind == "hoot" else { return }
            try await requireDecision(id)
            if PCDecisions.requires(task.value) {
                guard decisionSafeHoot, turn.decisionScope == BackendPCDecisionMarker.fingerprint(task) else {
                    throw NativeRPCError(code: "decision-held", message: "Hoot's queued brief or final execution owner no longer matches the approved task.")
                }
            }
            let since = BackendTaskValues.time()
            hootLive[id] = HootLive(token: token)
            let result: BackendHootTaskResult
            do {
                result = try await BackendPCDecisionDelivery.$required.withValue(PCDecisions.requires(task.value)) {
                    try await BackendPCDecisionDelivery.$hostedReference.withValue(PCDecisions.requires(task.value) ? BackendPCDecisionMarker.executionReference(task) : nil) {
                        try await BackendPCDecisionDelivery.$validate.withValue(decisionValidation(task, hoot: true)) {
                            try await hootTurns(turn) { [weak self] progress in await self?.noteHootProgress(id, token: token, kind: kind, progress) }
                        }
                    }
                }
            } catch let refusal as NativeRPCError where refusal.code == "unavailable" && hootLive[id]?.startedAt == nil {
                // Hoot's chat cannot take a task turn (this build has none yet, or Hoot could not start): the
                // one-line way is tried, and if that fails too the task says why.
                hootLive[id] = nil
                if await appClosing() { return }
                let told = try await tellHootInChat(id, turn.brief)
                if try await store.byID(id) != nil { _ = try await store.update(id, patch: fields([("hootTurnOpen", .bool(false))])) }
                if told, kind == .assigned, try await store.byID(id)?.assigneeKind == "hoot" {
                    _ = try await store.update(id, patch: fields([("process", .string("running")), ("runStartedAt", .number(BackendTaskValues.time()))]))
                    try await setLifecycleStatus(id, key: "onStarted")
                    await notify(id, type: "task.started", body: "Hoot started on this.")
                }
                return
            }
            // Stopped by the engine itself (the task was stopped or given to someone else): the task already says so.
            guard !stopped, !Task.isCancelled else { return }
            // T19: an unfinished turn while the app closes was cut by the close, not by Hoot.
            var cut = false
            if !result.finished { cut = await appClosing() }
            try await finishHootTurn(id, kind: kind, since: since, said: hootLive[id]?.token == token ? hootLive[id]?.said ?? [] : [], result: result, cut: cut)
        } catch is CancellationError {
        } catch {
            guard !stopped else { return }
            if await appClosing() { return }
            await sayAsHoot(id, kind: "blocker", text: "Hoot could not work on this: " + error.localizedDescription + " Reply on this task to ask it again.")
            if kind != .notice { await moveHootStatus(id, stuck: true) }
            await settleHootTurn(id)
        }
    }
    private func noteHootProgress(_ id: String, token: UUID, kind: HootTurnKind, _ progress: BackendHootTaskProgress) async {
        guard !stopped, hootLive[id]?.token == token else { return }
        switch progress {
        case .started:
            guard hootLive[id]?.startedAt == nil else { return }
            hootLive[id]?.startedAt = BackendTaskValues.time()
            do {
                guard let task = try await store.byID(id), task.assigneeKind == "hoot" else { return }
                // The working signal every assignee gets: "Running" from the moment it really starts.
                _ = try await store.update(id, patch: fields([("process", .string("running")), ("runStartedAt", .number(BackendTaskValues.time()))]))
                if kind == .assigned {
                    try await setLifecycleStatus(id, key: "onStarted")
                    await notify(id, type: "task.started", body: "Hoot started on this.")
                    await sayAsHoot(id, kind: "progress", text: "Hoot started on this.")
                } else if kind == .comment { await moveHootStatus(id, stuck: false) }
            } catch { await problem("Hoot started on a task, but that could not be shown on it: " + error.localizedDescription) }
        case .step(let line): hootLive[id]?.step = head(line, 200)
        case .text: break   // the answer so far; the whole answer is posted when the turn ends
        }
    }
    /// Hoot's closing words go on the task as its comment; a turn that stopped early or said nothing says so there.
    private func finishHootTurn(_ id: String, kind: HootTurnKind, since: Double, said posted: [String], result: BackendHootTaskResult, cut: Bool = false) async throws {
        guard let task = try await store.byID(id) else { return }
        let answer = result.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        // What Hoot already wrote on the task itself during this turn (tasks_comment, a comment in the thread).
        let own = (task.value["detail"]["comments"].elements ?? []).filter { $0["authorUserId"].string == "hoot" && ($0["at"].number ?? 0) >= since }.compactMap { $0["body"].string }
        let said = posted + own
        func same(_ a: String, _ b: String) -> Bool { a.trimmingCharacters(in: .whitespacesAndNewlines) == b.trimmingCharacters(in: .whitespacesAndNewlines) }
        let done = task.value["result"]["verified"].bool == true
        if !answer.isEmpty, !said.contains(where: { same($0, answer) }) {
            await sayAsHoot(id, kind: result.finished && done ? "completion" : "progress", text: answer)
        }
        // The app closing cut this turn (T19): what Hoot had written is kept above and the task keeps its
        // working mark. The next start says what happened and the app goes on with it by itself.
        if cut { return }
        // A reply on the task reaches Hoot only while the task is Hoot's.
        let again = task.assigneeKind == "hoot" ? " Reply on this task to ask it again." : ""
        if !result.finished {
            let why = (result.problem ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            await sayAsHoot(id, kind: "blocker", text: (why.isEmpty ? "Hoot stopped before it finished." : why.hasPrefix("Hoot") ? why : "Hoot stopped before it finished: " + why) + again)
            if kind != .notice { await moveHootStatus(id, stuck: true) }
        } else if answer.isEmpty, said.isEmpty {
            await sayAsHoot(id, kind: "blocker", text: (kind == .notice ? "Hoot was told about this and ended its turn without an answer." : "Hoot finished its turn without an answer.") + again)
            if kind != .notice { await moveHootStatus(id, stuck: true) }
        }
        if result.finished, !(answer.isEmpty && said.isEmpty), let now = try await store.byID(id), now.assigneeKind == "hoot", now.value["askedFromTask"].string != nil, now.value["result"].isNullish {
            // A question asked from another task's comments is finished once Hoot has answered it.
            _ = try await store.update(id, patch: fields([("result", fields([("at", .number(BackendTaskValues.time())), ("verified", .bool(true)), ("answer", .string(answer)), ("check", .null)]))]))
            try await setLifecycleStatus(id, key: "onVerified")
            _ = try await store.update(id, patch: fields([("process", .string("exited")), ("runStartedAt", .null)]))
        }
        await settleHootTurn(id)
    }
    /// T19: the status follows what Hoot is really doing on a task it holds. A turn that ends without a
    /// finished answer takes it from "Working on it" to "Stuck" (it went on saying "Working on it" after
    /// "Hoot was stopped before it finished"); starting on a reply takes it back to "Working on it".
    private func moveHootStatus(_ id: String, stuck: Bool) async {
        do {
            guard let task = try await store.byID(id), task.assigneeKind == "hoot", task.value["result"].isNullish, task.value["archivedAt"].isNullish else { return }
            let connection = task.isLocal ? nil : try await config.connection(task.value["keyId"].string ?? "")
            let started = task.isLocal ? "Working on it" : connection?["statuses"]["onStarted"].string
            let blocked = task.isLocal ? "Stuck" : connection?["statuses"]["onBlocked"].string
            guard let now = task.value["crmStatus"].string else { return }
            if stuck { guard now == started else { return } }
            else { guard now == blocked || (task.isLocal && now == "To-Do") else { return } }
            try await setLifecycleStatus(id, key: stuck ? "onBlocked" : "onStarted")
        } catch { await problem("A task's status could not follow Hoot's turn: " + error.localizedDescription) }
    }
    /// The turn is over: the task stops saying "Running" unless another turn on it is already waiting.
    private func settleHootTurn(_ id: String) async {
        do {
            guard let task = try await store.byID(id), task.assigneeKind == "hoot", (hootWaiting[id] ?? 0) <= 1 else { return }
            var patch = [("hootTurnOpen", NativeRPCValue.bool(false))]
            if ["running", "queued"].contains(task.process) { patch += [("process", .string("idle")), ("runStartedAt", .null)] }
            _ = try await store.update(id, patch: fields(patch))
        } catch { await problem("A task Hoot finished working on could not be updated: " + error.localizedDescription) }
    }
    /// Hoot's words on the task. If they cannot be posted, the task keeps them and says why: never dropped.
    private func sayAsHoot(_ id: String, kind: String, text: String) async {
        do {
            guard let task = try await store.byID(id) else { return }
            try await post(id, kind: kind, text: text, by: try await hootIdentity(task))
        } catch is CancellationError {
        } catch {
            let reason = error.localizedDescription
            do { try await store.note(id, by: "hoot", kind: "blocker", text: "Hoot's answer could not be posted on this task: \(reason)\n\nWhat Hoot said:\n\n" + head(text, 6_000)) }
            catch { await problem("Hoot's answer on a task could not be saved (\(reason)). It said: " + head(text, 1_500)) }
            if (try? await store.byID(id))?.isLocal == false { await problem("Hoot's answer on a CRM task could not be sent to the CRM: " + reason) }
        }
    }
    private func hootIdentity(_ task: BackendTaskRecord) async throws -> String {
        if task.isLocal { return "hoot" }
        return try await config.connection(task.value["keyId"].string ?? "")?["hootIdentity"].string ?? task.value["assignee"]["identity"].string ?? "hoot"
    }
    /// For the task's thread: Hoot's turn on this task, while it is running ("Hoot is writing…").
    public func hootWriting(_ id: String) -> NativeRPCValue? {
        guard let live = hootLive[id], live.startedAt != nil else { return nil }
        return fields([("busy", .bool(true)), ("taskID", .string(id)), ("agentID", .string("hoot")), ("turnID", .string(live.token.uuidString.lowercased())),
            ("name", .string("Hoot")), ("step", live.step.map(NativeRPCValue.string) ?? .null)])
    }
    /// For orderly callers and tests: every task turn handed to Hoot so far has ended.
    public func settleHootTurns() async { while let chain = hootChain { await chain.value; if chain == hootChain { break } } }
    /// The old way, for a build whose Hoot has no task turns: one line typed into Hoot's chat.
    /// False when Hoot could not be told (the task then says why).
    private func tellHootInChat(_ id: String, _ message: String) async throws -> Bool {
        do {
            let task = try await record(id)
            try await requireDecision(id, expected: task)
            if PCDecisions.requires(task.value), !decisionSafeHoot { throw NativeRPCError(code: "decision-held", message: "Hoot's final execution owner is unavailable.") }
            try await BackendPCDecisionDelivery.$required.withValue(PCDecisions.requires(task.value)) {
                try await BackendPCDecisionDelivery.$hostedReference.withValue(PCDecisions.requires(task.value) ? BackendPCDecisionMarker.executionReference(task) : nil) {
                    try await BackendPCDecisionDelivery.$validate.withValue(decisionValidation(task, hoot: true)) {
                        try await access.tellHoot(BackendTaskBriefComposition.chatWording(message).replacingOccurrences(of: #"\s*\n\s*"#, with: " ", options: .regularExpression))
                    }
                }
            }
            return true
        }
        // L8 (10 Oct): only say "not running" when that is the reason. A busy Hoot, or any other refusal,
        // used to be reported as "Hoot is not running on this Mac" while Hoot was open and answering.
        catch {
            let reason = error.localizedDescription
            let text = reason.hasPrefix("Hoot is not running") ? reason : "Hoot could not be told about this task: " + reason
            try await block(id, text: text, by: try await reviewer(try await record(id)))
            return false
        }
    }
    /// task-engine.ts quietOf: when a live, unanswered worker went quiet, or nil when it is not waiting on anything.
    /// `live`: the live session ids one pass already read (U140); nil asks the session list now.
    private func quietSince(_ task: BackendTaskRecord, live: Set<String>? = nil) async throws -> Double? {
        guard let session = task.sessionID, task.value["stalled"].isNullish, task.assigneeKind == "agent", task.value["stopped"].bool != true, task.value["questionOpen"].bool != true,
              task.value["result"].isNullish, task.value["keepOpenUntil"].isNullish else { return nil }
        if let live { guard live.contains(session) else { return nil } } else { guard await alive(session) else { return nil } }
        return quiet[session]
    }
    private func alive(_ session: String) async -> Bool { await access.sessions().contains { $0.id == session && $0.exitCode == nil } }
    private func agentIdOf(_ task: BackendTaskRecord) -> String? { task.assigneeKind == "agent" ? task.agentID : task.value["handedFrom"].string }
    private func workerName(_ id: String) async -> String {
        if id == "hoot" { return "Hoot" }; if id == "me" { return "You" }; if id == "none" { return "Nobody" }
        return (try? await config.agent(id))?["name"].string ?? id
    }
    private func head(_ text: String, _ maximum: Int) -> String { let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines); return trimmed.utf16.count <= maximum ? trimmed : BackendTaskBriefComposition.utf16Prefix(trimmed, maximum) + "…" }
    private func tail(_ text: String, _ maximum: Int) -> String { let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines); return trimmed.utf16.count <= maximum ? trimmed : "…" + String(decoding: Array(trimmed.utf16.suffix(maximum)), as: UTF16.self) }
    private func flatten(_ text: String) -> String { text.replacingOccurrences(of: #"\s*\n\s*"#, with: " ", options: .regularExpression).replacingOccurrences(of: #"[\x00-\x1f\x7f]"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
    private func tellFinishedChildren(_ task: BackendTaskRecord) async throws {
        // FORK-TASKS: a question asked from the task's comments (or an agent put on the task) is not a part its
        // holder handed on. Its end is never reported to the holder as "every task you handed on has finished":
        // on a task Hoot holds that made Hoot answer in the thread after the agent that was asked.
        guard task.value["reviewOfTaskId"].isNullish, task.value["askedFromTask"].isNullish, let parentExternal = task.value["parentExternalTaskId"].string, let key = task.value["keyId"].string,
              let parent = try await store.byID(task.value["parentTaskId"].string ?? key + ":" + parentExternal) else { return }
        let children = try await store.all().filter { $0.value["reviewOfTaskId"].isNullish && $0.value["askedFromTask"].isNullish && ($0.value["parentTaskId"].string == parent.id || $0.value["keyId"].string == key && $0.value["parentExternalTaskId"].string == parentExternal) }
        guard !children.contains(where: { $0.value["result"].isNullish && $0.value["stopped"].bool != true }) else { return }
        let digest = children.map { "\($0.value["externalTaskId"].string ?? ""):\($0.value["stopped"].bool == true ? "stopped" : $0.value["result"]["verified"].bool == true ? "true" : "false")" }.sorted().joined(separator: ",")
        guard parent.value["childrenTold"].string != digest else { return }
        // Review paperclip #8: a held decision-required parent is not told to carry on (it is told once allowed again).
        let toAgent = parent.assigneeKind != "hoot" && parent.assigneeKind != BackendAGTLeadSeats.kind && agentIdOf(parent) != nil
        if toAgent, PCDecisions.requires(parent.value), !(await decisionAllowed(parent.id, sending: true)) { return }
        _ = try await store.update(parent.id, patch: fields([("childrenTold", .string(digest))]))
        let lines = children.map { child in let state = child.value["stopped"].bool == true ? "stopped" : child.value["result"]["verified"].bool == true ? "verified" : "finished, not verified"; return "\(child.value["externalTaskId"].string ?? child.id) (\(state)): \(head(child.value["result"]["answer"].string ?? "", 300).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression))" }
        let message = BackendTaskBriefComposition.hootNotice("Every task you handed on for \"\(head(parent.value["title"].string ?? "", 80))\" has finished.", taskID: parent.id, next: lines.joined(separator: "\n"))
        if parent.assigneeKind == "hoot" { try await tellHoot(parent.id, message) }
        else if parent.assigneeKind == BackendAGTLeadSeats.kind { await BackendAGTLeadSeats.shared?.notice(parent.id, line: message) }
        else if agentIdOf(parent) != nil, let session = parent.sessionID, await alive(session) {
            try await requireDecision(parent.id, expected: parent, sending: true)
            try await BackendPCDecisionDelivery.$required.withValue(PCDecisions.requires(parent.value)) {
                try await BackendPCDecisionDelivery.$hostedReference.withValue(PCDecisions.requires(parent.value) ? BackendPCDecisionMarker.executionReference(parent) : nil) {
                    try await BackendPCDecisionDelivery.$validate.withValue(decisionValidation(parent, sending: true)) { try await access.send(session, flatten(message)) }
                }
            }
            await noteTyped(session, flatten(message), task: parent); await notify(parent.id, type: "task.progress", body: message) }
    }
    private func requireOutgoing(_ task: BackendTaskRecord) throws { if !task.isLocal, outgoing == nil { throw BackendSessionFailure.missingCapability("the authenticated CRM task outbox; mirrored tasks were kept unchanged") } }
    private func coordinated(_ task: BackendTaskRecord) async throws -> Bool {
        if task.value["requestedBy"].string == "hoot" { return true }
        guard let parent = task.value["parentExternalTaskId"].string, let key = task.value["keyId"].string else { return false }
        return try await store.byID(key + ":" + parent)?.assigneeKind == "hoot"
    }
    private func reviewer(_ task: BackendTaskRecord) async throws -> String {
        if BackendTaskActor.current.hasPrefix("taskagent:") {
            let agent = String(BackendTaskActor.current.dropFirst("taskagent:".count))
            if task.isLocal { return agent }
            if let connection = try await config.connection(task.value["keyId"].string ?? ""), let identity = connection["identities"].fields?.first(where: { $0.value.string == agent })?.key { return identity }
        }
        if task.isLocal { return "hoot" }
        let connection = try await config.connection(task.value["keyId"].string ?? "")
        return connection?["hootIdentity"].string ?? task.value["assignee"]["identity"].string ?? "hoot"
    }
    private func record(_ id: String) async throws -> BackendTaskRecord {
        try await store.requireCompletionFence()
        guard let task = try await store.byID(id) else { throw NativeRPCError.invalidArguments("That task no longer exists.") }
        try await store.requireCompletionFence(); return task
    }
    private func requireReviewer(_ task: BackendTaskRecord) async throws {
        let actor = BackendTaskActor.current
        guard actor.hasPrefix("taskagent:") else { return }
        let id = String(actor.dropFirst("taskagent:".count))
        guard let childID = task.value["reviewerTaskId"].string, let child = try await store.byID(childID),
              child.value["reviewOfTaskId"].string == task.id, child.value["reviewTurnId"] == task.value["lastTurn"],
              child.assigneeKind == "agent", child.agentID == id, child.value["stopped"].bool != true,
              task.value["stopped"].bool != true, !task.value["result"].isNullish else { throw NativeRPCError(code: "not-permitted", message: "Only this task's assigned reviewer may verify its current result.") }
    }
    private func recordReviewVerdict(_ task: BackendTaskRecord, pass: Bool, evidence: [String], reasons: String) async throws {
        guard BackendTaskActor.current.hasPrefix("taskagent:"), let childID = task.value["reviewerTaskId"].string else { return }
        _ = try await store.update(task.id, patch: fields([("reviewVerdict", fields([("reviewerTaskId", .string(childID)), ("turnId", task.value["lastTurn"]), ("pass", .bool(pass)), ("evidence", .array(evidence.map(NativeRPCValue.string))), ("reasons", .string(reasons)), ("at", .number(BackendTaskValues.time()))]))]))
    }
    private func startReviewer(_ id: String, reviewerID: String, turnID: String, workspace: String) async throws {
        let task = try await record(id)
        guard let agent = try await config.agent(reviewerID), Self.delegationRefusal(agent) == nil, reviewerID != agentIdOf(task) else { try await block(id, text: "The configured reviewer is missing, paused, archived or is the worker itself. Choose another reviewer in Settings → Task agents."); return }
        let maximum = task.isLocal ? 3 : Int(try await config.connection(task.value["keyId"].string ?? "")?["maxHops"].number ?? 3)
        guard (task.value["hops"].number ?? 0) < Double(maximum) else { try await block(id, text: "The reviewer cannot start: this task tree has reached its hand-off limit of \(maximum)."); return }
        if let childID = task.value["reviewerTaskId"].string, let child = try await store.byID(childID), child.value["reviewTurnId"].string == turnID { return }
        let child = try BackendTAGTaskReviewer.child(parent: task, reviewer: agent, turnID: turnID, workspace: workspace)
        _ = try await store.put(child.value)
        _ = try await store.update(id, patch: fields([("reviewerTaskId", .string(child.id)), ("reviewVerdict", .null)]))
        try await store.note(child.id, by: task.agentID, kind: "assigned", text: "Assigned to review \(task.id).")
        try await comment(id, kind: "completion", text: "Finished. \(agent["name"].string ?? reviewerID) is reviewing it.\n\n" + head(task.value["result"]["answer"].string ?? "", 3_000))
        // The parent worker's keep-open state is installed later in this turn.
        // The final nudge starts the reviewer through the ordinary queue.
    }
    private func finishReviewer(_ task: BackendTaskRecord, parentID: String, answer: String) async throws {
        guard let parent = try await store.byID(parentID), parent.value["reviewerTaskId"].string == task.id, parent.value["reviewVerdict"]["reviewerTaskId"].string == task.id, parent.value["reviewVerdict"]["turnId"] == task.value["reviewTurnId"] else {
            _ = try await store.update(task.id, patch: fields([("result", fields([("at", .number(BackendTaskValues.time())), ("verified", .bool(false)), ("answer", .string(answer)), ("check", .string("The reviewer did not record a verdict."))]))]))
            try await block(task.id, text: "The reviewer finished without recording a verdict. Use tasks_review or tasks_verify with the evidence checked.")
            if let parent = try await store.byID(parentID), parent.value["reviewerTaskId"].string == task.id, parent.value["stopped"].bool != true { try await block(parent.id, text: "The reviewer finished without recording a verdict. The worker's result remains unverified.") }
            return
        }
        _ = try await store.update(task.id, patch: fields([("result", fields([("at", .number(BackendTaskValues.time())), ("verified", .bool(true)), ("answer", .string(answer)), ("check", .null)]))]))
        try await comment(task.id, kind: "completion", text: "Review recorded.\n\n" + head(answer, 3_000))
        try await setLifecycleStatus(task.id, key: "onVerified")
    }
    /// Retained ROUTINES/CLI producer only: exact attributed structured result.
    /// This is not registered as a caller-supplied cost-writing MCP tool.
    public func recordAttributedRunResult(_ report: NativeRPCValue) async throws -> NativeRPCValue {
        let id = try report["id"].requireString("actual run id", nonempty: true)
        let agentID = try report["agent_id"].requireString("exact agent id", nonempty: true)
        guard let agent = try await config.agent(agentID), report["provider"].string == agent["provider"].string,
              report["account_id"].string != nil, report["session_id"].string != nil || report["conversation_id"].string != nil,
              let started = report["started_at"].number, let ended = report["ended_at"].number,
              started.isFinite, ended.isFinite, ended >= started,
              let source = report["source"].string, !source.isEmpty else {
            throw NativeRPCError(code: "usage-unavailable", message: "The result needs its actual configured agent, account, provider, run and recorded conversation.")
        }
        if let existing = try await store.agentRun(id) {
            guard ["agent_id", "account_id", "provider", "session_id", "conversation_id", "task_id"].allSatisfy({ existing[$0] == report[$0] }) else {
                throw NativeRPCError(code: "run-conflict", message: "That run id already belongs to another exact attribution.")
            }
            if existing["ended_at"].number != nil { return existing }
        }
        let billing = try await cachedBilling(agentID, accountID: report["account_id"].string)
        let kind = billing["kind"].string ?? "unknown", cost = report["cost_usd"].number
        if cost != nil, kind != "api" || report["confirmed_api"].bool != true {
            throw NativeRPCError(code: "usage-unavailable", message: "Reported money needs confirmed API billing. Plan money is not recorded.")
        }
        let allowed = Set(["id", "agent_id", "task_id", "session_id", "conversation_id", "session_name", "provider", "account_id", "cwd", "project_id", "started_at", "outcome", "requested_model", "requested_effort"])
        var run = NativeRPCValue.object((report.fields ?? []).filter { allowed.contains($0.key) })
            .setting("ended_at", .null).setting("billing_kind", .string(kind)).setting("tokens", .null).setting("cost_usd", .null)
            .setting("usage_days", .object([])).setting("needed_help", .bool(report["needed_help"].bool == true))
        run = try BackendAGOPTRunHistory.addUsage(run, tokens: report["tokens"].number, reportedAPIUSD: cost,
            billingKind: kind, source: source, at: ended, calendar: runCalendar)
        run = try BackendAGOPTRunHistory.finish(run, outcome: report["outcome"].string ?? "completed", at: ended,
            summary: report["summary"].string, verified: report["verified"].bool)
        try await store.putAgentRun(run); try await checkMonthlyBudget(agentID, task: report["task_id"].string); return run
    }
    public func runs(profileID: String, days: Int? = nil) async throws -> [NativeRPCValue] {
        guard try await config.agent(profileID) != nil else { throw NativeRPCError.invalidArguments("That agent no longer exists.") }
        return try await store.agentRuns(profileID, days: days, now: BackendTaskValues.time())
    }
    private func cachedBilling(_ profileID: String, accountID: String?) async throws -> NativeRPCValue {
        guard let read = runtimeAccess.billing else { return fields([("kind", .string("unknown")), ("source", .string("not-reported"))]) }
        let value = try await read(profileID, accountID)
        guard ["api", "subscription", "unknown"].contains(value["kind"].string ?? "") else { throw NativeRPCError(code: "usage-unavailable", message: "The account has not reported its billing kind.") }
        return value
    }
    public func budget(profileID: String) async throws -> NativeRPCValue {
        guard let agent = try await config.agent(profileID) else { throw NativeRPCError.invalidArguments("That agent no longer exists.") }
        let settings = try await self.settings?(agent) ?? BackendAGSProfileProjection.settings(agent, defaultProvider: agent["provider"].string ?? "claude")
        let history = try await store.agentMonth(profileID, now: BackendTaskValues.time()), runtime = try await store.agentRuntime(profileID)
        let billing = try await cachedBilling(profileID, accountID: agent["account"].string), kind = billing["kind"].string ?? "unknown"
        let money = kind == "api", unit = money ? "usd" : "tokens"
        let spent = money ? history["cost_usd"] : history["tokens"]
        let limit = money ? settings.efficiency?.monthlyBudgetUSD ?? 0 : Double(settings.efficiency?.agentTokenBudget ?? 0)
        return history.setting("billing_kind", .string(kind)).setting("unit", .string(unit)).setting("spent", spent)
            .setting("monthly_budget", .number(limit)).setting("warning_percent", .number(Double(settings.efficiency?.warningPercent ?? 80)))
            .setting("on_exhaustion", .string(settings.efficiency?.onExhaustion ?? "warn"))
            .setting("cost_usd", money ? history["cost_usd"] : .null).setting("isAPIAccount", kind == "unknown" ? .null : .bool(money))
            .setting("source", billing["source"].isNullish ? .string("not-reported") : billing["source"])
            .setting("capability", .string(money && spent.isNullish ? "reported-api-cost-unavailable" : kind == "unknown" ? "billing-kind-unavailable-tokens-observed" : "observed"))
            .setting("paused_by_budget", .bool(agent["status"].string == "paused" && runtime["pause_reason"].string == "budget"))
    }
    public func dashboard(profileID: String) async throws -> NativeRPCValue {
        guard let agent = try await config.agent(profileID) else { throw NativeRPCError.invalidArguments("That agent no longer exists.") }
        let history = try await runs(profileID: profileID, days: 14), allTasks = try await store.all(), usage = try await budget(profileID: profileID)
        let ownedTasks = allTasks.filter { $0.value["agoptAgentID"].string == profileID || $0.agentID == profileID }
        let active = ownedTasks.first { $0.sessionID != nil && $0.value["result"].isNullish && $0.value["stopped"].bool != true }
        let queued = ownedTasks.filter { $0.process == "queued" && $0.value["stopped"].bool != true }.count
        let window = try await store.agentWindow(profileID, days: 14, now: BackendTaskValues.time())
        let activity = try await store.agentWindow(profileID, days: 30, now: BackendTaskValues.time())
        let status = agent["status"].string == "paused" ? "paused" : active?.value["questionOpen"].bool == true ? "waiting" : active != nil ? "working" : "ready"
        let runtime = fields([("status", .string(status)), ("queued", .number(Double(queued))), ("taskId", active.map { .string($0.id) } ?? .null),
            ("sessionId", active?.sessionID.map(NativeRPCValue.string) ?? .null), ("startedAt", active?.value["runStartedAt"] ?? .null),
            ("pausedByBudget", usage["paused_by_budget"]), ("lastFinishedRun", history.first { $0["ended_at"].number != nil } ?? .null)])
        let stats = fields([("runs14days", window["runs"]), ("tasksDone", window["tasks_done"]),
            ("finishedWithoutHelp", window["finished_without_help_percent"]),
            ("tokensThisMonth", usage["tokens"]), ("costUSD", usage["cost_usd"]), ("isAPIAccount", usage["isAPIAccount"]),
            ("coverage", usage["token_coverage"])])
        let taskRows = ownedTasks.sorted { ($0.value["updatedAt"].number ?? 0) > ($1.value["updatedAt"].number ?? 0) }.prefix(20).map {
            $0.value.setting("task_id", .string($0.id)).setting("session_id", $0.sessionID.map(NativeRPCValue.string) ?? .null)
                .setting("cwd", .string($0.value["agoptCwd"].string ?? $0.project)).setting("project_id", $0.value["projectId"])
        }
        return fields([("runtime", runtime), ("stats", stats), ("activity", activity), ("tasks", .array(taskRows))])
    }
    public func pauseAgent(_ profileID: String) async throws { try await pauseAgent(profileID, reason: "manual") }
    /// Existing configuration/AGS save relays call this. Reads do not emit
    /// changes; already-paused exhausted policy avoids a change-event loop.
    public func policyChanged(profileID: String) async throws {
        try await BackendAGOPTCompletionFence.$current.withValue(nil) {
            guard let agent = try await self.config.agent(profileID), agent["status"].string != "archived" else { return }
            try await self.checkMonthlyBudget(profileID)
            try await self.pumpQueue(onlyAgent: profileID)
        }
    }
    private func pauseAgent(_ profileID: String, reason: String) async throws {
        guard let agent = try await config.agent(profileID) else { throw NativeRPCError.invalidArguments("That agent no longer exists.") }
        guard agent["status"].string != "archived" else { throw NativeRPCError.invalidArguments("That agent is archived.") }
        if agent["status"].string != "paused" { _ = try await config.setStatus(profileID, action: "pause") }
        try await store.updateAgentRuntime(profileID, patch: fields([("pause_reason", .string(reason))]))
        for task in try await store.all() where task.value["agoptAgentID"].string == profileID && task.sessionID != nil && task.value["result"].isNullish {
            checks[task.id]?.cancel(); jobs[task.id]?.cancel()
            _ = try await store.update(task.id, patch: fields([("agoptRunEndReason", .string("paused"))]))
            try await close(task.id)
            _ = try await store.update(task.id, patch: fields([("process", .string("queued")), ("agoptRunID", .string(UUID().uuidString.lowercased())), ("agoptRunRetired", .bool(true)), ("runStartedAt", .null)]))
        }
        await arm()
    }
    public func resumeAgent(_ profileID: String, once: Bool = false) async throws {
        guard let agent = try await config.agent(profileID), agent["status"].string == "paused" else { throw NativeRPCError.invalidArguments("That agent is not paused.") }
        let value = try await budget(profileID: profileID)
        if !once, value["on_exhaustion"].string == "pause", let spent = value["spent"].number, let limit = value["monthly_budget"].number, limit > 0, spent >= limit {
            throw NativeRPCError(code: "budget-exhausted", message: "Raise the budget or choose Resume once.")
        }
        try await store.updateAgentRuntime(profileID, patch: fields([("resume_once_pending", .bool(once)), ("pause_reason", .null)]))
        _ = try await config.setStatus(profileID, action: "resume"); try await pumpQueue(onlyAgent: profileID)
    }
    public func resetAgentSessions(_ profileID: String) async throws -> NativeRPCValue {
        guard try await config.agent(profileID) != nil else { throw NativeRPCError.invalidArguments("That agent no longer exists.") }
        let state = try await store.agentRuntime(profileID), live = await access.sessions().filter { $0.exitCode == nil }
        let tasks = try await store.all().filter { $0.value["agoptAgentID"].string == profileID }
        let standalone = try await runtimeAccess.standaloneSessions?(profileID) ?? []
        let ids = Set(tasks.compactMap(\.sessionID)).intersection(Set(live.map(\.id))).union(standalone.filter { $0.exitCode == nil }.map(\.id))
        var deferred = false, cleared = 0, resetIDs: Set<String> = []
        for id in ids {
            if let reset = runtimeAccess.resetSession, try await reset(profileID, id) { cleared += 1; resetIDs.insert(id) } else { deferred = true }
        }
        let generation = (state["reuse_generation"].number ?? 0) + 1
        try await store.updateAgentRuntime(profileID, patch: fields([("reuse_generation", .number(generation)), ("fresh_pending", .bool(deferred))]))
        for task in tasks where task.sessionID == nil {
            _ = try await store.update(task.id, patch: fields([("conversationId", .null), ("agoptReuseContext", .bool(false))]))
        }
        for task in tasks where task.sessionID.map(resetIDs.contains) == true {
            _ = try await store.update(task.id, patch: fields([("conversationId", .null), ("agoptReuseGeneration", .number(generation)), ("agoptUsageMeasured", .bool(false))]))
        }
        return fields([("reset", .bool(true)), ("cleared", .number(Double(cleared))), ("deferred_until_close", .bool(deferred)),
            ("message", .string(deferred ? "Fresh context is waiting for retained sessions to close; they were kept open." : "The next task starts with fresh context."))])
    }
    public func stopAgent(_ profileID: String, reason: String) async throws -> NativeRPCValue {
        guard let agent = try await config.agent(profileID) else { throw NativeRPCError.invalidArguments("That agent no longer exists.") }
        if agent["status"].string == "active" { _ = try await config.setStatus(profileID, action: "pause") }
        try await store.updateAgentRuntime(profileID, patch: fields([("pause_reason", .string("manual"))]))
        var count = 0
        for task in try await store.all() where task.value["agoptAgentID"].string == profileID && task.sessionID != nil {
            try await cancel(task.id, reason: reason); count += 1
        }
        for session in try await runtimeAccess.standaloneSessions?(profileID) ?? [] where session.exitCode == nil {
            guard let stop = runtimeAccess.stopStandalone else { throw BackendSessionFailure.missingCapability("the exact ledger-owned standalone session closer") }
            try await stop(profileID, session.id); count += 1
        }
        return fields([("stopped", .number(Double(count)))])
    }
    public func wakeAgent(_ profileID: String) async throws -> NativeRPCValue {
        guard let agent = try await config.agent(profileID), agent["status"].string == "active" else { throw NativeRPCError(code: "unavailable", message: "Resume that agent before waking it.") }
        let queued = try await store.all().filter { $0.agentID == profileID && $0.process == "queued" && $0.value["stopped"].bool != true }
        if !queued.isEmpty { try await pumpQueue(onlyAgent: profileID); return fields([("queued", .number(Double(queued.count))), ("source", .string("task-queue"))]) }
        // Nothing queued and no standing check set up for this agent: say so plainly (11 Oct, the person
        // pressed Wake now and got no answer at all). Waking has nothing to start; a task given to it starts it.
        guard let standing = runtimeAccess.standingCheck else {
            let name = agent["name"].string.flatMap { $0.isEmpty ? nil : $0 } ?? "this agent"
            return fields([("queued", .number(0)), ("woke", .bool(false)),
                           ("message", .string("Nothing queued for \(name). It starts by itself when a task is given to it."))])
        }
        return try await standing(profileID)
    }
    private func canStartMonthly(_ agent: NativeRPCValue) async throws -> Bool {
        let id = agent["id"].string ?? "", state = try await store.agentRuntime(id)
        if state["resume_once_pending"].bool == true { return true }
        let value = try await budget(profileID: id)
        if value["on_exhaustion"].string == "pause", let spent = value["spent"].number, let limit = value["monthly_budget"].number, limit > 0, spent >= limit {
            // While the one "Resume once" run is still going, hold other work back without
            // pausing the agent (pausing would end that allowed run). checkMonthlyBudget pauses after it.
            if let allowed = state["resume_once_run"].string,
               try await store.all().contains(where: { $0.value["agoptRunID"].string == allowed && $0.sessionID != nil && $0.value["result"].isNullish }) { return false }
            try await pauseAgent(id, reason: "budget"); return false
        }
        return true
    }
    /// `task` is the task whose usage was just counted. #344: the warning goes on it, else on the agent's task
    /// that is working now; with neither, it waits for the next usage instead of landing on an old task.
    private func checkMonthlyBudget(_ profileID: String, task taskID: String? = nil) async throws {
        let value = try await budget(profileID: profileID), state = try await store.agentRuntime(profileID)
        guard let spent = value["spent"].number, let limit = value["monthly_budget"].number, limit > 0 else { return }
        let threshold = value["warning_percent"].number ?? 80, key = "\(value["month_key"].string ?? ""):\(value["unit"].string ?? ""):\(limit):\(threshold)"
        if spent >= limit * threshold / 100, state["warning_key"].string != key {
            let all = try await store.all()
            if let task = taskID.flatMap({ id in all.first { $0.id == id } })
                ?? all.first(where: { $0.value["agoptAgentID"].string == profileID && $0.sessionID != nil && $0.value["result"].isNullish && $0.value["archivedAt"].isNullish }) {
                try await store.updateAgentRuntime(profileID, patch: fields([("warning_key", .string(key))]))
                try await comment(task.id, kind: "progress", text: "Monthly budget warning: this agent has used \(String(format: "%.0f", spent)) of \(String(format: "%.0f", limit)) \(value["unit"].string ?? "tokens").")
            }
        }
        if spent >= limit, value["on_exhaustion"].string == "pause" {
            // "Resume once" lets exactly one run start; until it has started, do not re-pause.
            if state["resume_once_pending"].bool == true { return }
            if let allowed = state["resume_once_run"].string, try await store.all().contains(where: { $0.value["agoptRunID"].string == allowed && $0.sessionID != nil && $0.value["result"].isNullish }) { return }
            // Pausing retires the run itself; it is an agent-level change and must not be
            // fenced to the run whose usage report triggered it (that would cancel the pause).
            if value["paused_by_budget"].bool != true {
                try await BackendAGOPTCompletionFence.$current.withValue(nil) { try await self.pauseAgent(profileID, reason: "budget") }
            }
        }
    }
    public func setLocalStatusObserver(_ observer: (@Sendable (String, String) async -> Void)?) { localStatusObserver = observer }
    public func setNotificationObserver(_ observer: (@Sendable (BackendTaskRecord, NativeRPCValue) async throws -> Void)?) { notifications = observer }
    private func notify(_ id: String, type: String, body: String, agentID: String? = nil) async {
        guard let notifications else { return }
        do {
            let task = try await record(id)
            guard BackendTAGTaskNotifications.keyID(task) != nil else { return }
            try await notifications(task, BackendTAGTaskNotifications.event(task, type: type, body: body, agentID: agentID))
        } catch { await problem("Could not send the task notification: " + error.localizedDescription) }
    }
    private func active() throws { guard !stopped else { throw NativeRPCError(code: "not-started", message: "Tasks are not running on this computer right now.") } }
    private func fields(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendTaskValues.object(pairs) }
}
