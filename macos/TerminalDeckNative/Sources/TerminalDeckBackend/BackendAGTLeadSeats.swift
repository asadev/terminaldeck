import Foundation
import TerminalDeckNativeCore

/// L4 AGENTS (11 Oct 2026): a project's LEAD SEAT as a task holder.
///
/// A project's lead is a saved agent or a plain session the person started himself (his own long-lived
/// lead). A saved agent already takes tasks. This file makes the SEAT the address, `lead:<project id>`
/// (`AGTSeat.key`), so a session lead can be given a task and asked from a task comment as well:
///  - the lead is a saved agent → the task simply becomes that agent's, the ordinary way;
///  - the lead is a session → the task's holder is the seat (assignee kind "seat"). The engine never
///    starts a session for it. Whoever fills the seat is told in its own session through the same
///    checked typing a task brief uses. Nobody there → the task waits and is told the moment a session
///    fills the seat again (a replacement must be explicitly selected as lead).
/// A question asked with @ in a task comment rides on `askAgent` exactly like an agent's: the question
/// task's holder is the seat, and the lead's answer shows in the asking thread.
public enum BackendAGTLeadSeatHolder: Sendable, Equatable {
    /// The lead is a saved agent: tasks go to that agent the ordinary way.
    case agent(id: String, name: String)
    /// The lead is a session and it is running now.
    case session(id: String, name: String, provider: String)
    /// The lead is a session that is not running now.
    case away(name: String)
    /// The project has no lead.
    case vacant(project: String)
    /// No such project.
    case gone
}

/// A running session, as much of it as the seat needs.
public struct BackendAGTLeadSeatSession: Sendable, Equatable {
    public var id: String, title: String, projectID: String, provider: String
    public init(id: String, title: String, projectID: String, provider: String) {
        self.id = id; self.title = title; self.projectID = projectID; self.provider = provider
    }
}

/// An open task a seat holds, as much of it as the seat needs.
public struct BackendAGTLeadSeatTask: Sendable, Equatable {
    public var id: String, title: String, details: String
    /// `lead:<project id>`.
    public var seat: String
    /// The session this task was last typed into (nil: nobody has been told yet).
    public var toldSession: String?
    /// "The owner", "Hoot", an agent's name.
    public var givenBy: String
    /// A session filling the seat was told this task before (so the next one is told it still holds it).
    public var toldBefore: Bool
    public var decisionRequired: Bool
    public var decisionScope: String?
    public var decisionReference: String?
    public init(id: String, title: String, details: String, seat: String, toldSession: String?, givenBy: String, toldBefore: Bool = false,
                decisionRequired: Bool = false, decisionScope: String? = nil, decisionReference: String? = nil) {
        self.id = id; self.title = title; self.details = details; self.seat = seat; self.toldSession = toldSession; self.givenBy = givenBy
        self.toldBefore = toldBefore || toldSession != nil
        self.decisionRequired = decisionRequired; self.decisionScope = decisionScope
        self.decisionReference = decisionReference
    }
}

public actor BackendAGTLeadSeats {
    /// The assignee kind of a task held by a seat.
    public nonisolated static let kind = "seat"
    /// Kinds that hold a task as a worker (they get its comments and answer in its thread).
    public nonisolated static let workerKinds = ["agent", "hoot", kind]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed: BackendAGTLeadSeats?
    nonisolated(unsafe) private static var names: [String: String] = [:]
    /// Installed by composition once Tasks exist.
    public static var shared: BackendAGTLeadSeats? {
        get { lock.withLock { installed } }
        set { lock.withLock { installed = newValue } }
    }
    /// The lead's name for a seat address, from the last look at the projects (for rows and names that
    /// cannot wait). Nil for anything that is not a seat with a session lead.
    public nonisolated static func name(of address: String) -> String? { lock.withLock { names[address] } }
    nonisolated static func remember(_ projects: [PROJProject]) {
        var next: [String: String] = [:]
        for project in projects { if let lead = AGTSeats.lead(of: project), lead.kind == .session { next[address(project.id)] = lead.name.isEmpty ? "Lead of " + project.name : lead.name } }
        lock.withLock { names = next }
    }

    public struct Dependencies: Sendable {
        public var projects: @Sendable () async -> [PROJProject]
        /// Sessions running now.
        public var sessions: @Sendable () async -> [BackendAGTLeadSeatSession]
        /// Types one line into a running session with the app's checked typing (it waits for a free prompt).
        public var tell: @Sendable (_ sessionID: String, _ line: String) async throws -> Void
        /// Every open task a seat holds (not stopped, not finished).
        public var tasks: @Sendable () async throws -> [BackendAGTLeadSeatTask]
        /// One such task; nil when it is gone, finished, stopped or no longer a seat's.
        public var task: @Sendable (_ taskID: String) async throws -> BackendAGTLeadSeatTask?
        /// The task's own state, kept by the engine: told in this session, or waiting (nil).
        public var told: @Sendable (_ taskID: String, _ sessionID: String?) async throws -> Void
        /// A line on the task itself, written by the app.
        public var note: @Sendable (_ taskID: String, _ kind: String, _ text: String) async throws -> Void
        /// A saved agent leads now: the task becomes that agent's.
        public var handToAgent: @Sendable (_ taskID: String, _ agentID: String) async throws -> Void
        /// SETTINGS-TRUTH row 48: the New project guide's "Hoot leads for now". While the project has no lead,
        /// work for its lead seat goes to Hoot.
        public var hootLeads: @Sendable (_ projectID: String) async -> Bool = { _ in false }
        public var validateDelivery: @Sendable (BackendAGTLeadSeatTask) async throws -> Void = { task in
            guard !task.decisionRequired else { throw NativeRPCError(code: "decision-held", message: "The lead's required decision validator is unavailable.") }
        }
        public init(projects: @escaping @Sendable () async -> [PROJProject], sessions: @escaping @Sendable () async -> [BackendAGTLeadSeatSession],
                    tell: @escaping @Sendable (String, String) async throws -> Void, tasks: @escaping @Sendable () async throws -> [BackendAGTLeadSeatTask],
                    task: @escaping @Sendable (String) async throws -> BackendAGTLeadSeatTask?, told: @escaping @Sendable (String, String?) async throws -> Void,
                    note: @escaping @Sendable (String, String, String) async throws -> Void, handToAgent: @escaping @Sendable (String, String) async throws -> Void) {
            self.projects = projects; self.sessions = sessions; self.tell = tell; self.tasks = tasks; self.task = task
            self.told = told; self.note = note; self.handToAgent = handToAgent
        }
    }
    private let deps: Dependencies
    /// One line at a time per seat, in the order they were asked for.
    private var chains: [String: Task<Void, Never>] = [:]
    /// Seats with an open task nobody has been told yet (the lead is away, or its prompt was busy).
    private var pending = Set<String>()
    /// Tasks whose "waiting" line is already written, so it is not written again and again.
    private var saidWaiting = Set<String>()
    private var feeds: [NativeRPCSubscription] = []
    public init(_ deps: Dependencies) { self.deps = deps }
    /// Keeps the pushed-event listeners alive (session status, session exit).
    public func retain(_ more: [NativeRPCSubscription]) { feeds += more }

    // MARK: The address

    public nonisolated static func address(_ projectID: String) -> String { AGTSeat.lead(projectID: projectID).key }
    /// The project of a seat address; nil for anything else (an agent id, a role seat, "hoot").
    public nonisolated static func projectID(_ address: String) -> String? {
        guard let seat = AGTSeat(key: address), case .lead(let project) = seat else { return nil }
        return project
    }
    public nonisolated static func isAddress(_ id: String) -> Bool { projectID(id) != nil }

    /// Who fills a lead seat right now.
    public nonisolated static func holder(_ address: String, projects: [PROJProject], running: [BackendAGTLeadSeatSession]) -> BackendAGTLeadSeatHolder {
        guard let projectID = projectID(address), let project = projects.first(where: { $0.id == projectID }) else { return .gone }
        guard let lead = AGTSeats.lead(of: project) else { return .vacant(project: project.name) }
        let name = lead.name.isEmpty ? "Lead of " + project.name : lead.name
        if lead.kind == .agent { return .agent(id: lead.id, name: name) }
        // A title is not identity. A replacement must be explicitly selected as lead.
        if let session = running.first(where: { $0.id == lead.id }) {
            return .session(id: session.id, name: name, provider: session.provider)
        }
        return .away(name: name)
    }
    /// The lead seat a running session fills, when its project's lead is a session (never for a saved agent).
    public nonisolated static func address(of session: BackendAGTLeadSeatSession, projects: [PROJProject]) -> String? {
        AGTSeats.ledProject(sessionID: session.id, sessionName: session.title, sessionProjectID: session.projectID, projects: projects).map { address($0.id) }
    }
    /// Whether a session of this AI is handed the app's tools (one rule for every AI: BackendSessionAppTools).
    public nonisolated static func hasTaskTools(provider: String) -> Bool { BackendSessionAppTools.handedTo(provider: provider) }

    // MARK: The words

    static func flat(_ text: String, _ maximum: Int) -> String {
        let one = text.replacingOccurrences(of: #"\s*\n\s*"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[\x00-\x1f\x7f]"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return one.count <= maximum ? one : String(one.prefix(maximum)) + "…"
    }
    static func how(taskID: String, tools: Bool) -> String {
        tools ? "Answer ON THE TASK with tasks_comment (task id \(taskID)): the owner reads it there, not in this session. Use kind completion when it is finished."
              : "This session has no task tools, so answer here; the owner reads it in this session."
    }
    /// The one line typed into the lead's session when its seat is given a task.
    public nonisolated static func brief(_ task: BackendAGTLeadSeatTask, project: String, tools: Bool, again: Bool) -> String {
        let opening = again ? "[Terminal Deck] You still hold this task as lead of \(project)" : "[Terminal Deck] A task for you as lead of \(project)"
        let details = flat(task.details, 2_400)
        return opening + ": \"\(flat(task.title, 200))\". Task id: \(task.id). Given by: \(task.givenBy)."
            + (details.isEmpty ? "" : " It says: “\(details)”")
            + (again && tools ? " It may have new comments: read it with tasks_get." : "")
            + " " + how(taskID: task.id, tools: tools)
    }
    /// The one line typed when someone comments on a task the seat holds.
    public nonisolated static func commentLine(title: String, taskID: String, text: String, by: String?, tools: Bool) -> String {
        let who = by.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Someone"
        return "[Terminal Deck] \(who) wrote on your task \"\(flat(title, 120))\": “\(flat(text, 2_400))” " + how(taskID: taskID, tools: tools)
    }

    // MARK: Reading

    private func snapshot() async -> (projects: [PROJProject], running: [BackendAGTLeadSeatSession]) {
        let projects = await deps.projects(); Self.remember(projects)
        return (projects, await deps.sessions())
    }
    public func holder(_ address: String) async -> BackendAGTLeadSeatHolder {
        let now = await snapshot(); return Self.holder(address, projects: now.projects, running: now.running)
    }
    /// Reads the projects again so `name(of:)` is current (after a lead was chosen or removed).
    public func refreshNames() async { Self.remember(await deps.projects()) }
    /// What a task saves as its assignee for this address.
    public func assignment(_ address: String) async throws -> NativeRPCValue {
        switch await holder(address) {
        case .agent(let id, _): return BackendTaskLocalService.assignment(id, kind: "agent")
        case .session, .away: return BackendTaskLocalService.assignment(address, kind: Self.kind)
        case .vacant(let project):
            if let id = Self.projectID(address), await deps.hootLeads(id) { return BackendTaskLocalService.assignment("hoot", kind: "hoot") }
            throw NativeRPCError.invalidArguments("\(project) has no lead yet. Choose its lead on the Agents page, then assign this again.")
        case .gone: throw NativeRPCError.invalidArguments("That project no longer exists.")
        }
    }
    /// Who an @mention of this address asks: the saved agent that leads, or the seat itself. Nil: nobody to ask.
    public func mentionTarget(_ address: String) async -> String? {
        switch await holder(address) {
        case .agent(let id, _): return id
        case .session, .away: return address
        case .vacant, .gone: return nil
        }
    }
    /// Session leads by name, for "@name" written in a comment without picking it from the list.
    public func named() async -> [(id: String, name: String)] {
        let projects = await deps.projects(); Self.remember(projects)
        return projects.compactMap { project in
            guard let lead = AGTSeats.lead(of: project), lead.kind == .session, !lead.name.isEmpty else { return nil }
            return (Self.address(project.id), lead.name)
        }
    }
    /// The first folder of the seat's project, for a task that was given no folder.
    public func folder(_ address: String) async -> String? {
        guard let id = Self.projectID(address) else { return nil }
        return await deps.projects().first { $0.id == id }?.folders.first
    }
    /// The lead seat this running session fills (nil for every other session).
    public func address(ofSession id: String?) async -> String? {
        guard let id, !id.isEmpty else { return nil }
        let now = await snapshot()
        guard let session = now.running.first(where: { $0.id == id }) else { return nil }
        return Self.address(of: session, projects: now.projects)
    }

    // MARK: Telling the seat

    private func enqueue(_ address: String, _ job: @escaping @Sendable () async -> Void) {
        let before = chains[address]
        chains[address] = Task { await before?.value; await job() }
    }
    /// For tests and orderly callers: everything queued so far has been typed (or has failed and said so).
    public func settle() async { for chain in Array(chains.values) { await chain.value } }

    /// The seat was given this task. Returns at once; the brief is typed in turn.
    public func assigned(_ taskID: String) async {
        guard let task = try? await deps.task(taskID) else { return }
        enqueue(task.seat) { [weak self] in await self?.deliver(taskID) }
    }
    /// Someone commented on (or replied to) a task the seat holds.
    public func said(_ taskID: String, text: String, by: String?) async throws {
        guard let task = try await deps.task(taskID) else { return }
        switch await holder(task.seat) {
        case .session(let session, let name, let provider) where task.toldSession == session:
            let line = Self.commentLine(title: task.title, taskID: task.id, text: text, by: by, tools: Self.hasTaskTools(provider: provider))
            enqueue(task.seat) { [deps] in
                do { try await Self.tell(deps: deps, task: task, session: session, line: line) }
                catch is CancellationError {}
                catch { try? await deps.note(taskID, "blocker", "That comment did not reach \(name)'s session: \(error.localizedDescription)") }
            }
        default:
            // Not told in the session that fills the seat now (it restarted, is away, or the brief is still
            // waiting its turn): the task itself is told again, and it says to read the comments.
            enqueue(task.seat) { [weak self] in await self?.deliver(taskID) }
        }
    }
    /// A plain line about a task the seat holds (every part it handed on has finished).
    public func notice(_ taskID: String, line: String) async {
        guard let task = try? await deps.task(taskID), case .session(let session, _, _) = await holder(task.seat), task.toldSession == session else { return }
        enqueue(task.seat) { [deps] in try? await Self.tell(deps: deps, task: task, session: session, line: "[Terminal Deck] " + Self.flat(line, 3_000)) }
    }

    private func deliver(_ taskID: String) async {
        var who = "The lead"
        do {
            guard let task = try await deps.task(taskID) else { return }
            let now = await snapshot()
            switch Self.holder(task.seat, projects: now.projects, running: now.running) {
            case .agent(let id, _):
                try await deps.validateDelivery(task)
                try await deps.handToAgent(taskID, id)
            case .session(let session, let name, let provider):
                who = name
                guard task.toldSession != session else { return }
                let project = Self.projectID(task.seat).flatMap { id in now.projects.first { $0.id == id }?.name } ?? "its project"
                try await Self.tell(deps: deps, task: task, session: session,
                    line: Self.brief(task, project: project, tools: Self.hasTaskTools(provider: provider), again: task.toldBefore))
                try await deps.told(taskID, session)
                saidWaiting.remove(taskID)
            case .away:
                pending.insert(task.seat)
                try await deps.told(taskID, nil)
                if saidWaiting.insert(taskID).inserted {
                    try await deps.note(taskID, "progress", "Not running right now. This waits here and is delivered as soon as the session is open again.")
                }
            case .vacant(let project):
                if let id = Self.projectID(task.seat), await deps.hootLeads(id) { try await deps.validateDelivery(task); try await deps.handToAgent(taskID, "hoot"); return }
                try await deps.told(taskID, nil)
                if saidWaiting.insert(taskID).inserted {
                    try await deps.note(taskID, "blocker", "\(project) has no lead any more. Choose a lead for it, or give this task to someone else.")
                }
            case .gone:
                try await deps.told(taskID, nil)
                if saidWaiting.insert(taskID).inserted { try await deps.note(taskID, "blocker", "The project this lead belonged to is gone. Give this task to someone else.") }
            }
        } catch is CancellationError {
        } catch {
            // Its prompt was busy, showing a choice, or held unsent text: tried again when the session is free.
            if let task = try? await deps.task(taskID) { pending.insert(task.seat) }
            if saidWaiting.insert(taskID).inserted {
                try? await deps.note(taskID, "progress", "\(who) could not be told yet: \(error.localizedDescription) It is tried again when that session is free.")
            }
        }
    }

    private static func tell(deps: Dependencies, task: BackendAGTLeadSeatTask, session: String, line: String) async throws {
        try await deps.validateDelivery(task)
        try await BackendPCDecisionDelivery.$required.withValue(task.decisionRequired) {
            try await BackendPCDecisionDelivery.$hostedReference.withValue(task.decisionReference) {
                try await BackendPCDecisionDelivery.$validate.withValue({ try await deps.validateDelivery(task) }) {
                    try await deps.tell(session, line)
                }
            }
        }
    }

    // MARK: When to look again (pushed events only, nothing polls)

    /// Every open seat task that the session filling its seat has not been told is told. At start, and
    /// after a lead was chosen, changed or removed.
    public func sweep() async {
        let now = await snapshot()   // also keeps `name(of:)` current after a lead was chosen or removed
        guard let tasks = try? await deps.tasks(), !tasks.isEmpty else { pending.removeAll(); return }
        pending = Set(tasks.map(\.seat))
        for task in tasks {
            if case .session(let session, _, _) = Self.holder(task.seat, projects: now.projects, running: now.running), task.toldSession == session { continue }
            enqueue(task.seat) { [weak self] in await self?.deliver(task.id) }
        }
        await settleQuietly()
    }
    /// A session went calm (idle, waiting, finished its turn). When it fills a seat that has something
    /// waiting, that is typed now.
    public func calm(sessionID: String) async {
        guard !pending.isEmpty, let address = await address(ofSession: sessionID), pending.contains(address) else { return }
        guard let tasks = try? await deps.tasks().filter({ $0.seat == address }) else { return }
        if tasks.allSatisfy({ $0.toldSession == sessionID }) { pending.remove(address); return }
        for task in tasks where task.toldSession != sessionID { enqueue(address) { [weak self] in await self?.deliver(task.id) } }
        await settleQuietly()
    }
    /// A session ended. The tasks it had been told wait for the seat's next session.
    public func ended(sessionID: String) async {
        guard let tasks = try? await deps.tasks().filter({ $0.toldSession == sessionID }), !tasks.isEmpty else { return }
        for task in tasks { enqueue(task.seat) { [weak self] in await self?.deliver(task.id) } }
    }
    /// After a round of deliveries: a seat whose tasks are all told is no longer waiting.
    private func settleQuietly() async {
        await settle()
        guard let tasks = try? await deps.tasks() else { return }
        let now = await snapshot()
        pending = Set(tasks.filter { task in
            if case .session(let session, _, _) = Self.holder(task.seat, projects: now.projects, running: now.running) { return task.toldSession != session }
            return true
        }.map(\.seat))
    }

    // MARK: What a seat's session may do with the task tools

    /// The seat's own task (or a part it handed on): the session filling the seat sees it.
    public nonisolated static func sees(_ address: String, _ task: BackendTaskRecord, parent: BackendTaskRecord?) -> Bool {
        if task.assigneeKind == kind, task.agentID == address { return true }
        if let parent, parent.assigneeKind == kind, parent.agentID == address { return true }
        return false
    }
    /// Being given a task is the owner's yes to answering on it and handing parts of it on (the same
    /// rule as `BackendTaskAssignmentConsent`, for the session that fills the seat).
    public func covers(tool: String, arguments: NativeRPCValue, sessionID: String?, task: @Sendable (String) async throws -> BackendTaskRecord?) async -> Bool {
        let name = tool.hasPrefix("tasks_") ? "tasks." + tool.dropFirst("tasks_".count) : tool
        guard ["tasks.comment", "tasks.delegate"].contains(name), let id = arguments["task"].string,
              let address = await address(ofSession: sessionID), let row = try? await task(id) else { return false }
        return row.assigneeKind == Self.kind && row.agentID == address && row.value["stopped"].bool != true
    }
}

public extension BackendTaskRecord {
    /// Held by a worker that gets its comments and answers in its thread: an agent, Hoot, or a lead seat.
    var isHeldByWorker: Bool { BackendAGTLeadSeats.workerKinds.contains(assigneeKind) }
}

public extension BackendAGTLeadSeats {
    /// An open task a seat holds, read from its record. Nil when it is not a seat's, or is finished,
    /// stopped, archived or in the Trash.
    static func view(_ task: BackendTaskRecord, configuration: BackendTaskConfiguration) async -> BackendAGTLeadSeatTask? {
        guard task.assigneeKind == kind, task.isLocal, task.value["result"].isNullish, task.value["stopped"].bool != true,
              task.value["archivedAt"].isNullish, task.value["deletedAt"].isNullish else { return nil }
        // Who gave it to the seat: the last "assigned" line, as the engine's own briefs read it.
        let line = (task.value["notes"].elements ?? []).last { $0["kind"].string == "assigned" || ($0["text"].string ?? "").hasPrefix("Created, assigned to") }
        let giver = line?["by"].string ?? task.value["requestedBy"].string
        var names: [String: String] = [:]
        if let giver, giver != "me", giver != "hoot" { names[giver] = (try? await configuration.agent(giver))?["name"].string ?? name(of: giver) ?? giver }
        return .init(id: task.id, title: task.value["title"].string ?? "", details: task.value["instructions"].string ?? "", seat: task.agentID,
                     toldSession: task.value["seatSession"].string, givenBy: BackendTaskBriefComposition.person(giver, names: names),
                     toldBefore: !task.value["seatToldAt"].isNullish, decisionRequired: PCDecisions.requires(task.value),
                     decisionScope: BackendPCDecisionMarker.fingerprint(task),
                     decisionReference: PCDecisions.requires(task.value) ? BackendPCDecisionMarker.executionReference(task) : nil)
    }
}

public extension BackendAGTLeadSeats.Dependencies {
    /// The real wiring: the task store and the engine keep the tasks; the caller supplies the projects,
    /// the running sessions and the checked typing.
    static func live(store: BackendTaskStore, engine: BackendTaskEngine, local: BackendTaskLocalService, configuration: BackendTaskConfiguration,
                     projects: @escaping @Sendable () async -> [PROJProject], sessions: @escaping @Sendable () async -> [BackendAGTLeadSeatSession],
                     tell: @escaping @Sendable (String, String) async throws -> Void) -> Self {
        var dependencies = Self(projects: projects, sessions: sessions, tell: tell,
              tasks: {
                  var rows: [BackendAGTLeadSeatTask] = []
                  for task in try await store.all() { if await engine.decisionAllowed(task.id), let row = await BackendAGTLeadSeats.view(task, configuration: configuration) { rows.append(row) } }
                  return rows
              },
              task: { id in
                  guard let task = try await store.byID(id), await engine.decisionAllowed(id) else { return nil }
                  return await BackendAGTLeadSeats.view(task, configuration: configuration)
              },
              told: { id, session in try await engine.seatTold(id, session: session) },
              note: { id, kind, text in try await engine.comment(id, kind: kind, text: text) },
              // The owner chose a saved agent as lead: the seat's open tasks become that agent's.
              handToAgent: { id, agent in _ = try await local.update(id, input: .object([.init("assignee", .string(agent))]), by: "me") })
        dependencies.validateDelivery = { expected in
            guard let task = try await store.byID(expected.id), expected.decisionScope == BackendPCDecisionMarker.fingerprint(task),
                  task.assigneeKind == BackendAGTLeadSeats.kind, task.value["stopped"].bool != true,
                  task.value["archivedAt"].isNullish, task.value["completedAt"].isNullish, task.value["result"].isNullish,
                  await engine.decisionAllowed(task.id) else {
                throw NativeRPCError(code: "decision-held", message: "The lead task changed or its current business decision does not permit delivery.")
            }
            guard let current = try await store.byID(expected.id), expected.decisionScope == BackendPCDecisionMarker.fingerprint(current),
                  current.value["result"].isNullish, current.value["stopped"].bool != true,
                  current.value["archivedAt"].isNullish, current.value["completedAt"].isNullish else {
                throw NativeRPCError(code: "decision-held", message: "The lead task changed during final decision validation.")
            }
        }
        return dependencies
    }
}
