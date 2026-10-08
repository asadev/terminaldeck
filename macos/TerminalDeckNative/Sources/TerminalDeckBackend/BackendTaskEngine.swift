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
    private var pumpWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopped = true, pumping = false, starting = Set<String>(), closing = Set<String>()
    private var checks: [String: Task<(ok: Bool, output: String), any Error>] = [:]
    private var quiet: [String: Double] = [:], timer: BackendTaskTimer?, jobs: [String: Task<Void, any Error>] = [:]
    public init(store: BackendTaskStore, configuration: BackendTaskConfiguration, goals: BackendGoalStore, access: BackendTaskSessionAccess,
                workspace: @escaping @Sendable (BackendTaskRecord) async throws -> String,
                knowledge: (@Sendable (BackendTaskRecord) async throws -> String)? = nil,
                knowledgeAdapter: BackendTaskKnowledgeAdapter? = nil,
                outgoing: (@Sendable (BackendTaskRecord, NativeRPCValue) async throws -> Void)? = nil,
                notifications: (@Sendable (BackendTaskRecord, NativeRPCValue) async throws -> Void)? = nil,
                problem: @escaping @Sendable (String) async -> Void) throws {
        guard access.readiness == .ready else { throw BackendSessionFailure.missingCapability("task execution through the actual session/grant/delivery owner") }
        self.store = store; config = configuration; self.goals = goals; self.access = access
        self.workspace = workspace; self.knowledge = knowledge; self.knowledgeAdapter = knowledgeAdapter; self.outgoing = outgoing; self.notifications = notifications; self.problem = problem
    }
    public func start() async throws {
        guard stopped else { return }; try await store.requireWritableOwnership(); try await store.start(); try await config.start(); try await goals.start(); stopped = false
        let live = Set(await access.sessions().filter { $0.exitCode == nil }.map(\.id))
        for task in try await store.all() {
            if let id = task.sessionID, !live.contains(id) {
                try await store.release(task.id)
                if task.value["result"].isNullish && task.value["stopped"].bool != true { try await block(task.id, text: "Terminal Deck restarted while this was running. Reply on this task to continue where it left off.") }
            }
        }; try await pump(); await arm()
    }
    public func accept(_ id: String) async throws {
        try active(); let task = try await record(id); try requireOutgoing(task)
        guard ["human", "none", "hoot", "agent"].contains(task.assigneeKind) else { throw NativeRPCError.malformed("The saved task's assignee is unknown; it was not started or reassigned.") }
        switch task.assigneeKind {
        case "human", "none": _ = try await store.update(id, patch: fields([("process", .string("idle"))]))
        case "hoot":
            _ = try await store.update(id, patch: fields([("process", .string("running")), ("runStartedAt", .number(BackendTaskValues.time()))]))
            try await setLifecycleStatus(id, key: "onStarted")
            await notify(id, type: "task.started", body: "Hoot started on this.")
            try await tellHoot(id, try await hootBrief(try await record(id)))
        default: _ = try await store.update(id, patch: fields([("process", .string("queued"))])); try await pump()
        }; await arm()
    }
    public func pump() async throws {
        guard !stopped else { return }; await acquirePump(); defer { releasePump() }; guard !stopped else { return }
        let queued = try await store.all().filter { $0.process == "queued" && $0.value["stopped"].bool != true && $0.assigneeKind == "agent" }.sorted { ($0.value["createdAt"].number ?? 0) < ($1.value["createdAt"].number ?? 0) }
        for task in queued {
            guard !stopped, !starting.contains(task.id), BackendGoalStore.blockers(task, all: try await store.all()).isEmpty else { continue }
            guard let agent = try await config.agent(task.agentID) else { try await block(task.id, text: "The agent this task was assigned to no longer exists in Terminal Deck."); continue }
            guard try await working(task.agentID) < Int(agent["maxConcurrent"].number ?? 1) else { continue }
            let folder: String
            do { folder = try await workspace(task) } catch { try await block(task.id, text: "Could not prepare the folder \(agent["name"].string ?? "this agent") works in: " + error.localizedDescription); continue }
            guard try await makeRoom(folder) else {
                if task.value["reviewOfTaskId"].string != nil, task.value["reviewWaitingForFolder"].bool != true {
                    _ = try await store.update(task.id, patch: fields([("reviewWaitingForFolder", .bool(true))]))
                    try await comment(task.id, kind: "blocker", text: "The reviewer is waiting for the worker's folder. A separate workspace could not be used. Close the finished worker's session to let the review start.")
                }
                continue
            }
            if task.value["reviewWaitingForFolder"].bool == true { _ = try await store.update(task.id, patch: fields([("reviewWaitingForFolder", .bool(false))])) }
            try await begin(task.id, agent: agent, reply: nil)
        }; await arm()
    }
    /// The part of task-engine.ts `start` that guards the launch and says why one failed.
    private func begin(_ id: String, agent: NativeRPCValue, reply: String?) async throws {
        guard !starting.contains(id) else { return }
        let agentID = agent["id"].string ?? id
        starting.insert(id); let job = Task { try await self.launch(id, agent: agent, reply: reply) }; jobs[id] = job
        defer { jobs[id] = nil; starting.remove(id) }
            do { try await job.value } catch is CancellationError { if !stopped { try await block(id, text: "This task launch was cancelled.") } }
            catch {
                let message = error.localizedDescription
                if message.contains("already have a session running in") || message.contains("sessions running, which is the limit") {
                    _ = try await store.update(id, patch: fields([("process", .string("queued"))]))
                    if message.contains("sessions running, which is the limit"), let oldest = try await store.all().filter({ $0.sessionID != nil && $0.value["keepOpenUntil"].number != nil && $0.value["keepAliveUntilClose"].bool != true }).min(by: { ($0.value["keepOpenUntil"].number ?? 0) < ($1.value["keepOpenUntil"].number ?? 0) }) { try await close(oldest.id) }
                } else if !stopped { try await block(id, text: "Could not start \(agent["name"].string ?? agentID): \(message).") }
            }
                }
    private func acquirePump() async { if !pumping { pumping = true; return }; await withCheckedContinuation { pumpWaiters.append($0) } }
    private func releasePump() { if pumpWaiters.isEmpty { pumping = false } else { pumpWaiters.removeFirst().resume() } }
    /// task-engine.ts `working`: sessions an agent has open and is not keeping idle.
    private func working(_ agentID: String) async throws -> Int {
        let ids = Set(await access.sessions().filter { $0.exitCode == nil }.map(\.id))
        return try await store.all().filter { $0.agentID == agentID && (starting.contains($0.id) || ($0.sessionID.map(ids.contains) == true && $0.value["keepOpenUntil"].isNullish && $0.value["keepAliveUntilClose"].bool != true)) }.count
    }
    /// task-engine.ts `makeRoom`: one session per folder; a kept-open holder is closed so the next task can use it.
    private func makeRoom(_ folder: String) async throws -> Bool {
        let ids = Set(await access.sessions().filter { $0.exitCode == nil && $0.cwd == folder }.map(\.id))
        guard let holder = try await store.all().first(where: { $0.sessionID.map(ids.contains) == true }) else { return true }
        if !holder.value["keepOpenUntil"].isNullish, holder.value["keepAliveUntilClose"].bool != true { try await close(holder.id) }; return false
    }
    public func nudge() { guard !stopped else { return }; Task { do { try await self.pump() } catch { await self.problem(error.localizedDescription) } } }
    public func reply(_ id: String, text: String) async throws {
        try active(); var task = try await record(id); try requireOutgoing(task)
        _ = try await store.update(id, patch: fields([("questionOpen", .bool(false))]))
        if task.isLocal, !["agent", "hoot"].contains(task.assigneeKind) {
            guard let back = task.value["handedFrom"].string, let handed = try await config.agent(back) else { return }
            let identity = handed["id"].string ?? back
            task = try await store.update(id, patch: fields([("assignee", BackendTaskLocalService.assignment(identity, kind: "agent")), ("mainAssignee", .string(identity)), ("handedFrom", .null)]))
            try await store.note(id, by: "me", kind: "reply", text: text)
        }
        if task.assigneeKind == "hoot" { try await tellHoot(id, "Reply on CRM task \(task.id) (\"\(head(task.value["title"].string ?? "", 80))\"): \(flatten(text))"); return }
        if let session = task.sessionID, await alive(session) {
            var sent = true
            do { try await access.send(session, flatten(text)) } catch { sent = false }
            if sent {
                _ = try await store.update(id, patch: fields([("keepOpenUntil", .null), ("keepAliveUntilClose", .bool(false)), ("runStartedAt", .number(BackendTaskValues.time())), ("result", .null), ("stalled", .null)])); quiet[session] = BackendTaskValues.time()
                try await setLifecycleStatus(id, key: "onStarted"); await notify(id, type: "task.started", body: "The agent is continuing with your reply."); await arm(); return
            }
        }
        guard let agent = try await config.agent(task.agentID) else { try await block(id, text: "The agent this task was assigned to no longer exists in Terminal Deck."); return }
        _ = try await store.update(id, patch: fields([("process", .string("queued")), ("result", .null), ("stalled", .null)]))
        guard try await working(agent["id"].string ?? task.agentID) < Int(agent["maxConcurrent"].number ?? 1) else { return }
        let folder = try await workspace(task)
        guard try await makeRoom(folder) else { return }
        try await begin(id, agent: agent, reply: text); await arm()
    }
    public func cancel(_ id: String, reason: String) async throws {
        let task = try await record(id); try requireOutgoing(task); jobs[id]?.cancel(); checks[id]?.cancel()
        _ = try await store.update(id, patch: fields([("stopped", .bool(true)), ("questionOpen", .bool(false))]))
        if task.sessionID != nil { try await close(id) } else { try await store.release(id) }
        try await comment(id, kind: "progress", text: "Stopped: " + reason); try await pump(); await arm()
    }
    public func reassign(_ id: String, assignee: NativeRPCValue) async throws {
        checks[id]?.cancel()
        let task = try await record(id); if task.sessionID != nil { try await close(id) }
        _ = try await store.update(id, patch: fields([("assignee", assignee), ("mainAssignee", assignee["identity"]), ("sessionId", .null), ("conversationId", .null), ("result", .null), ("lastTurn", .null), ("stopped", .bool(false)), ("keepOpenUntil", .null), ("stalled", .null), ("retry", .null)]))
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
        let identity = agent["id"].string ?? agentID, said = note.trimmingCharacters(in: .whitespacesAndNewlines)
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
    public func noteNeedsInput(sessionID: String, screen: String) async throws {
        guard !stopped, let task = try await store.bySession(sessionID), task.value["questionOpen"].bool != true else { return }
        _ = try await store.update(task.id, patch: fields([("questionOpen", .bool(true))]))
        try await comment(task.id, kind: "question", text: "The agent is asking something. Reply on this task to answer.\n\n" + tail(screen, 1_200))
        await notify(task.id, type: "task.blocked", body: "The agent is waiting for an answer.")
        if !task.isLocal { await notify(task.id, type: "task.needs-reply", body: "Reply on this task to answer the agent's question.") }
        try await setLifecycleStatus(task.id, key: "onBlocked"); try await handToHuman(task.id); await arm()
    }
    public func noteFinishedTurn(sessionID: String, turnID: String, answer: String) async throws {
        guard !stopped, let task = try await store.bySession(sessionID), task.value["stopped"].bool != true, task.value["lastTurn"].string != turnID else { return }
        let session = await access.sessions().first { $0.id == sessionID }
        _ = try await store.update(task.id, patch: fields([("lastTurn", .string(turnID)), ("questionOpen", .bool(false)), ("conversationId", session?.agentSessionId.map(NativeRPCValue.string) ?? task.value["conversationId"])]))
        let agent = try await config.agent(agentIdOf(task) ?? ""), who = agent?["name"].string ?? "An agent", title = head(task.value["title"].string ?? "", 80), told = head(answer, 3_000)
        await knowledgeAdapter?.note(task, kind: "finished", summary: told)
        if let parentID = task.value["reviewOfTaskId"].string {
            try await finishReviewer(task, parentID: parentID, answer: answer)
        } else if let reviewerID = agent?["reviewerAgent"].string, !reviewerID.isEmpty {
            _ = try await store.update(task.id, patch: fields([("result", fields([("at", .number(BackendTaskValues.time())), ("verified", .bool(false)), ("answer", .string(answer)), ("check", .null)]))]))
            try await startReviewer(task.id, reviewerID: reviewerID, turnID: turnID, workspace: session?.cwd ?? task.project)
        } else if let command = agent?["verifyCommand"].string, !command.isEmpty {
            let cwd = session?.cwd ?? task.project, job = Task { [access] in try await access.check(command, cwd) }; checks[task.id] = job
            defer { checks[task.id] = nil }
            let check = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }, output = String(check.output.suffix(1_500))
            _ = try await store.update(task.id, patch: fields([("result", fields([("at", .number(BackendTaskValues.time())), ("verified", .bool(check.ok)), ("answer", .string(answer)), ("check", check.ok ? .null : .string(output))]))]))
            if check.ok { try await comment(task.id, kind: "completion", text: "Finished, and the check passed.\n\n" + told); try await setLifecycleStatus(task.id, key: "onVerified") }
            else { try await block(task.id, text: "Finished, but the check failed:\n\n" + output) }
            await knowledgeAdapter?.note(try await record(task.id), kind: check.ok ? "verified" : "rejected", summary: check.ok ? "The check passed: " + command : output, evidence: ["check: " + command])
        } else {
            _ = try await store.update(task.id, patch: fields([("result", fields([("at", .number(BackendTaskValues.time())), ("verified", .bool(false)), ("answer", .string(answer)), ("check", .null)]))]))
            if task.isLocal && task.value["requestedBy"].string == "hoot" {
                try await comment(task.id, kind: "completion", text: "Finished. Hoot is reviewing it.\n\n" + told)
                try await tellHoot(task.id, "\(who) finished task \(task.id) (\"\(title)\"). Look at what it did, then call tasks_review with pass and the evidence you checked, or fail with what is wrong.")
            } else if task.isLocal { try await comment(task.id, kind: "completion", text: "Finished. Check it and mark it Done.\n\n" + told); try await handToHuman(task.id) }
            else {
                try await comment(task.id, kind: "completion", text: "Finished. Hoot is checking it.\n\n" + told)
                try await tellHoot(task.id, "\(who) finished CRM task \(task.id) (\"\(title)\"). Read its result with tasks_get, then call tasks_verify with verified true if it is right, or false with what is missing.")
            }
        }
        let minutes = agent?["keepAliveMinutes"].number ?? 0
        if agent?["keepAliveUntilClose"].bool == true { _ = try await store.update(task.id, patch: fields([("keepOpenUntil", .null), ("keepAliveUntilClose", .bool(true)), ("runStartedAt", .null)])) }
        else if minutes > 0 { _ = try await store.update(task.id, patch: fields([("keepOpenUntil", .number(BackendTaskValues.time() + minutes * 60_000)), ("keepAliveUntilClose", .bool(false)), ("runStartedAt", .null)])) }
        else { try await close(task.id) }; nudge(); await arm()
        try await tellFinishedChildren(task)
    }
    public func noteExit(sessionID: String, exitCode: Int) async throws {
        quiet[sessionID] = nil
        let deliberate = closing.remove(sessionID) != nil
        guard !stopped, let task = try await store.bySession(sessionID) else { nudge(); return }
        try await store.release(task.id)
        if !deliberate && task.value["result"].isNullish && task.value["stopped"].bool != true {
            let why = "The session ended\(exitCode == 0 ? "" : " with exit code \(exitCode)") before the work was finished."
            try await block(task.id, text: why + " Reply on this task to continue.")
            try await stall(task.id, reason: "exited", text: why, say: false)
        }; nudge(); await arm()
    }
    public func stop() async throws {
        stopped = true; timer?.cancel(); timer = nil; let running = Array(jobs.values); running.forEach { $0.cancel() }; jobs.removeAll(); quiet.removeAll()
        let runningChecks = Array(checks.values); runningChecks.forEach { $0.cancel() }; checks.removeAll()
        for job in running { _ = try? await job.value }; for job in runningChecks { _ = try? await job.value }
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
            let candidates = [task.value["assignee"]["identity"].string, connection?["hootIdentity"].string].compactMap { $0 }
            let authorized = [task.value["mainAssignee"].string, task.value["creator"].string].compactMap { $0 }
            guard let by = candidates.first(where: authorized.contains) else { if strict { throw NativeRPCError(code: "access-denied", message: "None of Terminal Deck’s identities is this task’s main assignee or creator.") }; return }
            try requireOutgoing(task); actor = by
            try await outgoing!(task, fields([("type", .string("task.status")), ("status", .string(status)), ("actor", .string(by))]))
        } else { try await store.note(task.id, by: actor, kind: "status", text: "Status: " + status) }
        _ = try await store.update(task.id, patch: task.isLocal ? fields([("crmStatus", .string(status)), ("completedAt", status == "Done" ? .number(BackendTaskValues.time()) : .null)]) : fields([("crmStatus", .string(status))]))
        if task.isLocal { await localStatusObserver?(task.id, BackendTaskActor.current) }
    }
    private func launch(_ id: String, agent: NativeRPCValue, reply: String?) async throws {
        let task = try await record(id); try requireOutgoing(task)
        let name = agent["name"].string ?? task.agentID
        if reply == nil, let refusal = Self.delegationRefusal(agent) { try await block(id, text: refusal); return }
        let brief: String
        if reply == nil || task.value["conversationId"].isNullish {
            brief = try await agentBrief(task, agent: agent) + (reply.map { "\n\n## Reply on the task\n\n" + $0 } ?? "")
        } else { brief = "A reply came in on CRM task \(task.value["externalTaskId"].string ?? task.id) (\"\(task.value["title"].string ?? "")\"):\n\n\(reply ?? "")" + BackendTaskBriefComposition.stack(agent) }
        let cwd: String
        do { cwd = try await workspace(task) } catch { try await block(id, text: "Could not prepare the folder \(name) works in: \(error.localizedDescription)"); return }
        let session = try await access.start(task, agent, cwd, brief, reply == nil ? nil : task.value["conversationId"].string)
        let current = try await record(id)
        guard !stopped, current.value["stopped"].bool != true, current.agentID == task.agentID else { try await access.stop(session.id); return }
        let liveIDs = Set(await access.sessions().filter { $0.exitCode == nil }.map(\.id))
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
        _ = try await store.update(id, patch: fields([("runStartedAt", .number(BackendTaskValues.time())), ("keepOpenUntil", .null), ("keepAliveUntilClose", .bool(false)), ("questionOpen", .bool(false)), ("stalled", .null), ("conversationId", session.agentSessionId.map(NativeRPCValue.string) ?? task.value["conversationId"])]))
        quiet[session.id] = BackendTaskValues.time()
        for key in ["model", "effort"] { if let value = agent[key].string { do { try await access.setControl(session.id, key, value) } catch { try await comment(id, kind: "progress", text: "Could not set \(key) \(value): \(error.localizedDescription).") } } }
        try await setLifecycleStatus(id, key: "onStarted")
        await notify(id, type: "task.started", body: "\(name) \(reply == nil ? "started on this." : "is continuing with the reply.")")
        try await comment(id, kind: "progress", text: "\(name) \(reply == nil ? "started on this." : "is continuing with the reply.")")
        if reply == nil { await knowledgeAdapter?.note(try await record(id), kind: "delegated", summary: head(task.value["instructions"].string ?? "", 500)) }
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
        return "# \(task.value["title"].string ?? "")\n\nThis is CRM task \(task.value["externalTaskId"].string ?? task.id). Terminal Deck reports your progress and your final answer back to the CRM for you. End with a short summary of what you did and anything left." +
            BackendTaskBriefComposition.stack(agent) + BackendTaskBriefComposition.goals(chain) + "\n\n## The task\n\n" + (task.value["instructions"].string ?? "") +
            BackendTaskBriefComposition.context(task, all: try await store.all(), names: names) + BackendTaskBriefComposition.retry(task) + known
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
        return "CRM task \(task.id) (\"\(head(task.value["title"].string ?? "", 80))\") is assigned to you. It is CRM task \(task.value["externalTaskId"].string ?? task.id), in \(task.project).\(BackendTaskBriefComposition.goals(chain))\n\n\(task.value["instructions"].string ?? "")\n\n" +
            "Hand parts to your agents with tasks_delegate (\(agents.isEmpty ? "none are set up yet" : agents.joined(separator: ", "))), post updates with tasks_comment, and when it is done and right, call tasks_verify."
    }
    private func close(_ id: String) async throws {
        let task = try await record(id); guard let session = task.sessionID, !closing.contains(session) else { return }; closing.insert(session)
        if let meta = await access.sessions().first(where: { $0.id == session }), let conversation = meta.agentSessionId { _ = try await store.update(id, patch: fields([("conversationId", .string(conversation))])) }
        do { try await access.stop(session); try await store.release(id); _ = try await store.update(id, patch: fields([("keepAliveUntilClose", .bool(false))])); quiet[session] = nil }
        catch { closing.remove(session); throw error }
    }
    private func block(_ id: String, text: String, by: String? = nil) async throws {
        try await comment(id, kind: "blocker", text: text, by: by); try await setLifecycleStatus(id, key: "onBlocked"); try await handToHuman(id)
        let task = try await record(id); if task.sessionID == nil { _ = try await store.update(id, patch: fields([("process", .string("exited"))])) }
    }
    public func comment(_ id: String, kind: String, text: String, by: String? = nil) async throws {
        let task = try await record(id), body = head(text, 8_000)
        if task.isLocal { try await store.note(id, by: by ?? task.value["assignee"]["identity"].string ?? "hoot", kind: kind, text: body) }
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
            var next: Double?
            for task in try await store.all() {
                var due = task.value["keepOpenUntil"].number
                let agent = try await config.agent(task.agentID)
                if due == nil, task.sessionID != nil, let started = task.value["runStartedAt"].number, let minutes = agent?["maxRunMinutes"].number, minutes > 0 { due = started + minutes * 60_000 }
                if let since = try await quietSince(task) { due = min(due ?? .infinity, since + 15 * 60_000) }
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
            for task in try await store.all() where task.sessionID != nil {
                if task.value["keepAliveUntilClose"].bool == true { continue }
                if let until = task.value["keepOpenUntil"].number, until <= now { _ = try await store.update(task.id, patch: fields([("keepOpenUntil", .null)])); try await close(task.id); continue }
                let agent = try await config.agent(task.agentID)
                if let started = task.value["runStartedAt"].number, let minutes = agent?["maxRunMinutes"].number, minutes > 0, started + minutes * 60_000 <= now {
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
            try await tellHoot(id, "Task \(task.id) (\"\(head(task.value["title"].string ?? "", 80))\") has stalled: \(text) \(next)")
        }
    }
    private func tellHoot(_ id: String, _ message: String) async throws {
        do { try await access.tellHoot(message.replacingOccurrences(of: #"\s*\n\s*"#, with: " ", options: .regularExpression)) }
        catch { try await block(id, text: "Hoot is not running on this Mac, so this task is waiting for it.", by: try await reviewer(try await record(id))) }
    }
    /// task-engine.ts quietOf: when a live, unanswered worker went quiet, or nil when it is not waiting on anything.
    private func quietSince(_ task: BackendTaskRecord) async throws -> Double? {
        guard let session = task.sessionID, task.value["stalled"].isNullish, task.assigneeKind == "agent", task.value["stopped"].bool != true, task.value["questionOpen"].bool != true,
              task.value["result"].isNullish, task.value["keepOpenUntil"].isNullish, await alive(session) else { return nil }
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
        guard task.value["reviewOfTaskId"].isNullish, let parentExternal = task.value["parentExternalTaskId"].string, let key = task.value["keyId"].string,
              let parent = try await store.byID(task.value["parentTaskId"].string ?? key + ":" + parentExternal) else { return }
        let children = try await store.all().filter { $0.value["reviewOfTaskId"].isNullish && ($0.value["parentTaskId"].string == parent.id || $0.value["keyId"].string == key && $0.value["parentExternalTaskId"].string == parentExternal) }
        guard !children.contains(where: { $0.value["result"].isNullish && $0.value["stopped"].bool != true }) else { return }
        let digest = children.map { "\($0.value["externalTaskId"].string ?? ""):\($0.value["stopped"].bool == true ? "stopped" : $0.value["result"]["verified"].bool == true ? "true" : "false")" }.sorted().joined(separator: ",")
        guard parent.value["childrenTold"].string != digest else { return }
        _ = try await store.update(parent.id, patch: fields([("childrenTold", .string(digest))]))
        let lines = children.map { child in let state = child.value["stopped"].bool == true ? "stopped" : child.value["result"]["verified"].bool == true ? "verified" : "finished, not verified"; return "\(child.value["externalTaskId"].string ?? child.id) (\(state)): \(head(child.value["result"]["answer"].string ?? "", 300).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression))" }
        let message = "Every task you handed on for CRM task \(parent.id) has finished. " + lines.joined(separator: " | ")
        if parent.assigneeKind == "hoot" { try await tellHoot(parent.id, message) }
        else if agentIdOf(parent) != nil, let session = parent.sessionID, await alive(session) { try await access.send(session, flatten(message)); await notify(parent.id, type: "task.progress", body: message) }
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
    private func record(_ id: String) async throws -> BackendTaskRecord { guard let task = try await store.byID(id) else { throw NativeRPCError.invalidArguments("That task no longer exists.") }; return task }
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
