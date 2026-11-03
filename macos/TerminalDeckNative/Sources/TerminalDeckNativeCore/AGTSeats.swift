import Foundation

/// Deck Memory, the Agents side (MEMORY-SPEC §3a): three categories and seats.
/// - Exactly three categories: the Orchestrator (Hoot), a Lead, an Agent. Nothing is set per agent.
/// - Memory belongs to the SEAT (a role), never to the hire. An agent is hired INTO a seat;
///   deleting it leaves the seat and its memory; the next hire in that seat inherits all of it.
/// Pure rules, no storage: the lead seat's hire lives on the project (`PROJProject.lead`), a
/// role seat's hire is the agent profile whose `seat` names the role.
public typealias AGTCategory = DeckMemoryCategory
public extension DeckMemoryCategory {
    var explanation: String {
        switch self {
        case .orchestrator: "Hoot. Gives leads their goals and assigns agents in projects with no lead."
        case .lead: "Runs one project's agents. Hoot gives it goals and reads its reports."
        case .agent: "Does the work of one role. It starts each job from that role's memory."
        }
    }
}

public enum AGTLeadKind: String, Sendable, Equatable { case agent, session }

/// Who sits in a project's lead seat.
public struct AGTLead: Equatable, Sendable {
    public var kind: AGTLeadKind
    public var id: String
    public var name: String
    public var projectID: String
    public var raw: String { kind.rawValue + ":" + id }
    public init(kind: AGTLeadKind, id: String, name: String, projectID: String) {
        self.kind = kind; self.id = id; self.name = name; self.projectID = projectID
    }
}

/// A seat: the orchestrator's, a project's lead seat, or a role (inside a project or outside any).
public enum AGTSeat: Hashable, Sendable {
    case orchestrator
    case lead(projectID: String)
    /// `projectID` nil: a role outside any project (`roles/<role>/`).
    case role(projectID: String?, role: String)

    public var category: AGTCategory {
        switch self { case .orchestrator: .orchestrator; case .lead: .lead; case .role: .agent }
    }
    public var projectID: String? {
        switch self {
        case .orchestrator: nil
        case .lead(let project): project
        case .role(let project, _): project
        }
    }
    /// The role's slug (nil for the orchestrator and lead seats).
    public var role: String? { if case .role(_, let role) = self { return role } else { return nil } }

    /// Stable text for ids and menus: `orchestrator`, `lead:<project>`, `role:<project>/<role>`, `role:/<role>`.
    public var key: String {
        switch self {
        case .orchestrator: "orchestrator"
        case .lead(let project): "lead:" + project
        case .role(let project, let role): "role:" + (project ?? "") + "/" + role
        }
    }
    public init?(key: String) {
        if key == "orchestrator" { self = .orchestrator; return }
        if key.hasPrefix("lead:"), key.count > 5 { self = .lead(projectID: String(key.dropFirst(5))); return }
        guard key.hasPrefix("role:"), let slash = key.firstIndex(of: "/") else { return nil }
        let project = String(key[key.index(key.startIndex, offsetBy: 5)..<slash]), role = String(key[key.index(after: slash)...])
        guard AGTSeats.isValidRole(role) else { return nil }
        self = .role(projectID: project.isEmpty ? nil : project, role: role)
    }
    /// The folder inside the memory root (MEMORY-SPEC §3a.3).
    public var folder: String {
        switch self {
        case .orchestrator: "hoot"
        case .lead(let project): "projects/" + project + "/lead"
        case .role(let project, let role): (project.map { "projects/" + $0 + "/" } ?? "") + "roles/" + role
        }
    }
    /// The same seat in M1's owner spelling.
    public var owner: DeckMemoryOwner {
        switch self {
        case .orchestrator: .hoot
        case .lead(let project): .lead(project)
        case .role(let project, let role): .role(project: project, role: role)
        }
    }
}

public enum AGTSeats {
    /// A role's slug: lowercase letters, digits and dashes, at most 64.
    public static func isValidRole(_ role: String) -> Bool {
        role.range(of: #"^[a-z0-9][a-z0-9-]{0,63}$"#, options: .regularExpression) != nil
    }
    /// "iOS engineer" → "ios-engineer". Empty when nothing usable is left.
    public static func slug(_ title: String) -> String { TaskNames.slug(title) }
    /// "ios-engineer" → "Ios engineer": only for a seat nobody named yet.
    public static func title(forRole role: String) -> String {
        let words = role.replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
    /// The sentence a refusal shows; nil when acceptable (nil/empty = the seat named after the agent).
    public static func roleProblem(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return isValidRole(raw) ? nil : "A role is lowercase letters, numbers and dashes, at most 64 (for example ios-engineer)."
    }

    /// "" (none), `agent:<profile id>` or `session:<session id>`.
    public static func isValidLead(_ raw: String) -> Bool {
        if raw.isEmpty { return true }
        guard raw.utf8.count <= 200, !raw.contains("\0"), !raw.contains("\n") else { return false }
        for prefix in ["agent:", "session:"] where raw.hasPrefix(prefix) { return raw.count > prefix.count }
        return false
    }
    public static func lead(of project: PROJProject) -> AGTLead? {
        guard project.id != PROJProjects.independentID, !project.lead.isEmpty, isValidLead(project.lead),
              let colon = project.lead.firstIndex(of: ":"),
              let kind = AGTLeadKind(rawValue: String(project.lead[..<colon])) else { return nil }
        let id = String(project.lead[project.lead.index(after: colon)...])
        return .init(kind: kind, id: id, name: project.leadName.isEmpty ? id : project.leadName, projectID: project.id)
    }
    public static func leads(_ projects: [PROJProject]) -> [AGTLead] { projects.compactMap(lead(of:)) }

    /// The project an agent profile leads, if any.
    public static func ledProject(agentID: String, projects: [PROJProject]) -> PROJProject? {
        projects.first { lead(of: $0).map { $0.kind == .agent && $0.id == agentID } ?? false }
    }
    /// Only the session explicitly chosen as lead fills its seat; names are not unique.
    public static func ledProject(sessionID: String, sessionName: String?, sessionProjectID: String?, projects: [PROJProject]) -> PROJProject? {
        guard !sessionID.isEmpty else { return nil }
        return projects.first { lead(of: $0).map { $0.kind == .session && $0.id == sessionID } ?? false }
    }

    /// The project whose lead a session WORKS AS when the person opens it in that project's folder without picking
    /// an agent: a project whose lead is a saved agent (13 Oct, Asad: every session he opens in ClaudeiMatch is
    /// Commander; the folder's own CLAUDE.md makes it so). A lead that is a session is the session the person chose,
    /// so other sessions in its folder stay plain. Independent never has a lead.
    public static func folderLead(sessionProjectID: String?, projects: [PROJProject]) -> PROJProject? {
        guard let id = sessionProjectID, !id.isEmpty, id != PROJProjects.independentID else { return nil }
        return projects.first { $0.id == id && lead(of: $0)?.kind == .agent }
    }

    /// The seat an agent profile sits in: the lead seat of the project that names it, else the
    /// role seat `seat` (its own id when unset) in its project.
    public static func seat(agentID: String, seat: String?, projectID: String?, projects: [PROJProject]) -> AGTSeat {
        if let led = ledProject(agentID: agentID, projects: projects) { return .lead(projectID: led.id) }
        return roleSeat(agentID: agentID, seat: seat, projectID: projectID)
    }
    /// The role seat an agent holds (also while it leads: it gets it back when it stops leading).
    public static func roleSeat(agentID: String, seat: String?, projectID: String?) -> AGTSeat {
        let role = seat.flatMap { isValidRole($0) ? $0 : nil } ?? (isValidRole(agentID) ? agentID : slug(agentID))
        let project = projectID.flatMap { $0.isEmpty || $0 == PROJProjects.independentID ? nil : $0 }
        return .role(projectID: project, role: role.isEmpty ? "agent" : role)
    }
    public static func category(agentID: String, projects: [PROJProject]) -> AGTCategory {
        ledProject(agentID: agentID, projects: projects) != nil ? .lead : .agent
    }

    /// One line per project for Hoot (card / per-message lines): who to hand a goal to.
    public static func routingLines(_ projects: [PROJProject]) -> [String] {
        projects.filter { $0.id != PROJProjects.independentID }.map { project in
            if let lead = lead(of: project) {
                return "\(project.name): lead \(lead.name) (\(lead.kind == .agent ? "agent" : "session") \(lead.id)). Give goals to the lead; it runs \(project.name)'s agents and reports back."
            }
            return "\(project.name): no lead. Assign its agents directly."
        }
    }
}

public extension AGTDirectory {
    /// The id of the quiet row that stands for a lead session that is not running.
    static let leadPlaceholderPrefix = "lead:"
    /// The id of the row that stands for a seat nobody sits in.
    static let vacantSeatPrefix = "seat:"
    /// A lead session that is not running still shows in the tree, so the project's lead is never a blank.
    static func leadPlaceholder(project: PROJProject, lead: AGTLead) -> AGTAgent {
        AGTAgent(id: leadPlaceholderPrefix + project.id, kind: .session, profileID: nil, name: lead.name, role: "Leads " + project.name,
                 icon: .symbol("person.crop.circle.badge.checkmark"), project: project.folders.first ?? "", provider: "",
                 model: nil, status: "live", live: .offline, activity: "Not running", taskTitle: nil, reportsTo: nil,
                 lastActivity: nil, machineName: "This Mac", liveIDs: [], sessionID: lead.id, claudeAgent: nil,
                 sourceFile: nil, syncStatus: nil, projectID: project.id)
    }
    /// A seat that still holds memory and has nobody in it: shown so it can be filled.
    static func vacantSeat(_ seat: AGTSeat, title: String, project: PROJProject?) -> AGTAgent {
        AGTAgent(id: vacantSeatPrefix + seat.key, kind: .session, profileID: nil, name: title,
                 role: seat.category == .lead ? "Lead seat" : "Role",
                 icon: .symbol("person.crop.circle.dashed"), project: project?.folders.first ?? "", provider: "",
                 model: nil, status: "live", live: .offline, activity: "Vacant, has memory", taskTitle: nil, reportsTo: nil,
                 lastActivity: nil, machineName: "This Mac", liveIDs: [], sessionID: nil, claudeAgent: nil,
                 sourceFile: nil, syncStatus: nil, projectID: project?.id)
    }
}

public extension AGTSeat {
    /// From M1's owner (nil for a project's shared space, which is not a seat).
    init?(owner: DeckMemoryOwner) {
        switch owner {
        case .hoot: self = .orchestrator
        case .lead(let project): self = .lead(projectID: project)
        case .role(let project, let role): self = .role(projectID: project, role: role)
        case .project: return nil
        }
    }
}

public extension AGTDirectory {
    /// The id of a row that stands for one hand on a seat (its session id follows).
    static let handPrefix = "hand:"
    /// One hand on a seat that has several: its job in one line, listed under the seat.
    static func handRow(sessionID: String, number: Int, job: String, helper: Bool, state: AWWatchState?, project: PROJProject?, liveID: String?) -> AGTAgent {
        AGTAgent(id: handPrefix + sessionID, kind: .session, profileID: nil, name: (helper ? "Helper " : "Hand ") + String(number),
                 role: job, icon: .symbol(helper ? "person.crop.circle.badge.plus" : "hand.raised"), project: project?.folders.first ?? "", provider: "",
                 model: nil, status: "live", live: state ?? .idle, activity: job.isEmpty ? "No job named yet" : job, taskTitle: nil, reportsTo: nil,
                 lastActivity: nil, machineName: "This Mac", liveIDs: liveID.map { [$0] } ?? [], sessionID: sessionID, claudeAgent: nil,
                 sourceFile: nil, syncStatus: nil, projectID: project?.id)
    }
}
