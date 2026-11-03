import Foundation
import TerminalDeckNativeCore

/// Deck Memory, the Agents side: which SEAT a terminal session sits in (MEMORY-SPEC §3a).
/// Memory belongs to the seat, never to the hire. L8 HOST asks `owner` for every session; M2 FLOW
/// and L6 HOOT can ask the same for a session that already runs. Pure rules in `resolve`; the
/// instance only reads the project registry (who leads) and the agent profiles (which role).
public struct BackendAGTMemoryOwners: Sendable {
    public typealias Projects = @Sendable () async -> [PROJProject]
    public typealias Agents = @Sendable () async -> [NativeRPCValue]
    /// The agent profile id a task is assigned to (nil when the task is unknown).
    public typealias TaskAgent = @Sendable (_ taskID: String) async -> String?

    /// Set once by the app's composition (NativeCompositionAGTMemory). Other lanes ask it:
    /// `await BackendAGTMemoryOwners.shared?.owner(input, session: meta)`.
    nonisolated(unsafe) private static var current: BackendAGTMemoryOwners?
    private static let lock = NSLock()
    public static var shared: BackendAGTMemoryOwners? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    private let projects: Projects
    private let agents: Agents
    private let taskAgent: TaskAgent
    /// A task that runs on a short-lived helper seat names that seat's role (`BackendAGTHandsService.taskSeatField`).
    private let taskSeat: @Sendable (_ taskID: String) async -> String?

    public init(projects: @escaping Projects, agents: @escaping Agents, taskAgent: @escaping TaskAgent,
                taskSeat: @escaping @Sendable (String) async -> String? = { _ in nil }) {
        self.projects = projects; self.agents = agents; self.taskAgent = taskAgent; self.taskSeat = taskSeat
    }

    /// The seam `DeckMemorySessionServices.owner` expects: decided before the session exists.
    public func owner(_ input: BackendCreateSessionInput, provider: String) async -> DeckMemorySessionOwner {
        await owner(input, sessionID: nil, sessionTitle: nil, provider: provider)
    }
    /// The same answer once the session exists: its id and title also find a session that
    /// leads a project (a lead is usually a session the person started himself).
    public func owner(_ input: BackendCreateSessionInput, session: BackendSessionMeta) async -> DeckMemorySessionOwner {
        await owner(input, sessionID: session.id, sessionTitle: session.title, provider: session.provider,
                    origin: input.origin ?? session.origin, routine: input.originRoutineId ?? session.originRoutineId)
    }
    public func owner(_ input: BackendCreateSessionInput, sessionID: String?, sessionTitle: String?, provider: String? = nil,
                      origin: BackendSessionOrigin? = nil, routine: String? = nil) async -> DeckMemorySessionOwner {
        var assigned: String?, helperRole: String?
        if let task = input.taskID { assigned = await taskAgent(task); helperRole = await taskSeat(task) }
        let opened = Self.openedByThePerson(input, provider: provider ?? input.provider ?? "", origin: origin ?? input.origin,
                                            routine: routine ?? input.originRoutineId)
        return Self.resolve(profileID: assigned ?? input.agentProfileID ?? input.agentInstructions, claudeAgent: input.claudeAgent, seatOverride: helperRole,
                            projectID: input.projectId, folder: input.taskProject ?? input.cwd,
                            sessionID: sessionID, sessionTitle: sessionTitle,
                            projects: await projects(), agents: await agents(), worksAsTheLead: opened)
    }
    /// The seat a saved agent sits in, as its key ("lead:<project>" when a project names it as lead, else
    /// "role:<project>/<role>"): what a role's account is chosen on. Nil for a row with no id.
    public func seatKey(agent: NativeRPCValue) async -> String? {
        guard let id = agent["id"].string, !id.isEmpty else { return nil }
        let owner = Self.resolve(profileID: id, claudeAgent: nil, projectID: nil, folder: nil, sessionID: nil, sessionTitle: nil,
                                 projects: await projects(), agents: [agent])
        return Self.seat(owner)?.key
    }
    /// The seat behind a session owner (nil for a plain session).
    public static func seat(_ owner: DeckMemorySessionOwner) -> AGTSeat? {
        switch owner.kind {
        case .lead:
            let project = owner.project ?? owner.id
            return project.isEmpty ? nil : .lead(projectID: project)
        case .agent, .temporary: return owner.id.isEmpty ? nil : .role(projectID: owner.project, role: owner.id)
        case .hoot, .plain: return nil
        }
    }
    /// The same seat in M1's owner spelling (nil for a plain session). The one mapping other lanes use.
    public static func memoryOwner(_ owner: DeckMemorySessionOwner) -> DeckMemoryOwner? { seat(owner)?.owner }

    /// A lead seat, a role seat, or a plain session. Three categories only; nothing per agent.
    /// - A saved agent a project names as its lead → `.lead`: id = project = the project id (`projects/<project>/lead`).
    /// - A saved agent → `.agent`: id = its ROLE (the profile's `seat`, its own id when unset), project = its
    ///   project id or nil (`projects/<project>/roles/<role>` or `roles/<role>`). `name` is the hire, a detail only.
    /// - A session with no agent that its project names as lead (by id, or by its saved name) → `.lead`.
    /// - `worksAsTheLead` (a session the person opened himself, with no agent picked, no task, on an AI): opened in
    ///   the folder of a project whose lead is a saved agent → that lead's seat (`AGTSeats.folderLead`).
    /// - Everything else → `.plain` (diary and board only).
    /// - `seatOverride`: the helper seat's role when the job runs on a short-lived helper seat under the agent's own.
    public static func resolve(profileID: String?, claudeAgent: String?, seatOverride: String? = nil, projectID: String?, folder: String?,
                               sessionID: String?, sessionTitle: String?,
                               projects: [PROJProject], agents: [NativeRPCValue], worksAsTheLead: Bool = false) -> DeckMemorySessionOwner {
        let sessionProject = PROJProjects.resolve(projectID: projectID, folder: folder, projects: projects)
        let row: NativeRPCValue? = {
            if let profileID, let exact = agents.first(where: { $0["id"].string == profileID }) { return exact }
            guard let claudeAgent, !claudeAgent.isEmpty else { return nil }
            // A session started as a Claude Code agent: the saved agent with that name in the same project.
            let named = agents.filter { $0["claudeAgent"].string == claudeAgent || $0["id"].string == claudeAgent || $0["name"].string == claudeAgent }
            return named.first { project(of: $0, projects: projects) == sessionProject } ?? (named.count == 1 ? named.first : nil)
        }()
        if let row, let id = row["id"].string {
            let name = row["name"].string ?? id
            let helper = seatOverride.flatMap { AGTSeats.isValidRole($0) ? $0 : nil }
            if helper == nil, let led = AGTSeats.ledProject(agentID: id, projects: projects) {
                return .init(kind: .lead, id: led.id, name: name, project: led.id, memoryOn: true)
            }
            let home = project(of: row, projects: projects)
            let role = AGTSeats.roleSeat(agentID: id, seat: helper ?? row["seat"].string, projectID: home)
            return .init(kind: .agent, id: role.role ?? id, name: name, project: role.projectID, memoryOn: true)
        }
        if let led = AGTSeats.ledProject(sessionID: sessionID ?? "", sessionName: sessionTitle, sessionProjectID: sessionProject, projects: projects),
           let lead = AGTSeats.lead(of: led) {
            return .init(kind: .lead, id: led.id, name: lead.name, project: led.id, memoryOn: true)
        }
        // A session the person opened in a project led by a saved agent, with no agent picked, IS that lead:
        // the project's own instructions (its CLAUDE.md, "You are Commander") make it so (13 Oct).
        if worksAsTheLead, profileID == nil, (claudeAgent ?? "").isEmpty,
           let led = AGTSeats.folderLead(sessionProjectID: sessionProject, projects: projects), let lead = AGTSeats.lead(of: led) {
            // The lead's card and memory. The app never types into it (nor into any other session).
            return .init(kind: .lead, id: led.id, name: lead.name, project: led.id, memoryOn: true)
        }
        // A plain session still belongs to its project for the diary and the board.
        return .init(kind: .plain, project: sessionProject == PROJProjects.independentID ? nil : sessionProject)
    }

    /// A session the person opened himself on an AI, with no agent and no task: one that may work as its project's
    /// lead. Hoot's sessions, routines' runs, task sessions and shell tabs never do.
    public static func openedByThePerson(_ input: BackendCreateSessionInput, provider: String, origin: BackendSessionOrigin?, routine: String?) -> Bool {
        guard AGTShellAgents.providers.contains(provider.lowercased()) else { return false }
        guard input.taskID == nil, input.agentProfileID == nil, (input.agentInstructions ?? "").isEmpty, (input.claudeAgent ?? "").isEmpty else { return false }
        guard origin == nil || origin == .user, (routine ?? "").isEmpty else { return false }
        return true
    }

    private static func project(of row: NativeRPCValue, projects: [PROJProject]) -> String {
        let explicit = row["projectIdInferred"].bool == true ? nil : row["projectId"].string
        return PROJProjects.resolve(projectID: explicit, folder: row["sourceDirectory"].string ?? row["sourceFile"].string ?? row["defaultProject"].string, projects: projects)
    }

    /// The category word for labels and tools: lead / agent / plain.
    public static func categoryWord(_ owner: DeckMemorySessionOwner) -> String {
        switch owner.kind { case .lead: "lead"; case .agent, .temporary: "agent"; case .hoot: "orchestrator"; case .plain: "plain" }
    }
}
