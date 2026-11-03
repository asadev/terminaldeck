import Foundation

public enum AGFRAMEStateFilter: String, CaseIterable, Sendable {
    case all, working, waiting, paused
    public func includes(_ agent: AGTAgent) -> Bool {
        switch self {
        case .all: true
        case .working: agent.live == .working
        case .waiting: agent.live == .waiting
        case .paused: agent.status == "paused"
        }
    }
}

public struct AGFRAMEAgentGroup: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let agents: [AGTAgent]
}

/// Presentation only. Explicit ownership always wins over an execution folder.
public enum AGFRAMEPresentation {
    public static func projectID(for agent: AGTAgent, projects: [PROJProject], agentProjectIDs: [String: String] = [:]) -> String {
        PROJProjects.resolve(projectID: agentProjectIDs[agent.id] ?? agent.projectID, folder: agent.project, projects: projects)
    }
    public static func scopedAgents(_ agents: [AGTAgent], projects: [PROJProject], projectID: String? = nil,
                                    agentProjectIDs: [String: String] = [:]) -> [AGTAgent] {
        agents.filter { !$0.isHoot && $0.status != "archived" &&
            (projectID == nil || self.projectID(for: $0, projects: projects, agentProjectIDs: agentProjectIDs) == projectID) }
    }
    public static func groups(agents: [AGTAgent], projects: [PROJProject], projectID: String? = nil,
                              search: String = "", state: AGFRAMEStateFilter = .all,
                              agentProjectIDs: [String: String] = [:]) -> [AGFRAMEAgentGroup] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = scopedAgents(agents, projects: projects, projectID: projectID, agentProjectIDs: agentProjectIDs).filter { agent in
            guard state.includes(agent) else { return false }
            let owner = self.projectID(for: agent, projects: projects, agentProjectIDs: agentProjectIDs)
            return needle.isEmpty || [agent.name, agent.role, agent.model ?? "", PROJProjects.name(for: owner, projects: projects)]
                .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
        let buckets = Dictionary(grouping: filtered) { self.projectID(for: $0, projects: projects, agentProjectIDs: agentProjectIDs) }
        let registered = projects.map(\.id).filter { $0 != PROJProjects.independentID }
        let unknown = buckets.keys.filter { !registered.contains($0) && $0 != PROJProjects.independentID }.sorted()
        var seen = Set<String>()
        return (registered + unknown + [PROJProjects.independentID]).compactMap { id in
            guard seen.insert(id).inserted, let rows = buckets[id], !rows.isEmpty else { return nil }
            return AGFRAMEAgentGroup(id: id, name: PROJProjects.name(for: id, projects: projects), agents: rows)
        }
    }
}

public struct AGFRAMEImportCandidate: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let alreadyImported: Bool
    public init(id: String, name: String, alreadyImported: Bool = false) {
        self.id = id; self.name = name; self.alreadyImported = alreadyImported
    }
}

/// One assignment per source folder. No files are moved and no backend writes occur here.
public struct AGFRAMEImportFolder: Identifiable, Equatable, Sendable {
    public var id: String { folder }
    public let folder: String
    public var projectID: String
    public let candidates: [AGFRAMEImportCandidate]
    public private(set) var selectedIDs: Set<String>
    public init(folder: String, candidates: [AGFRAMEImportCandidate], projectID: String? = nil, projects: [PROJProject]) {
        self.folder = PROJProjects.normalize(folder)
        self.projectID = PROJProjects.resolve(projectID: projectID, folder: folder, projects: projects)
        self.candidates = candidates
        selectedIDs = Set(candidates.map(\.id))
    }
    public mutating func setSelected(_ selected: Bool, id: String) {
        guard let row = candidates.first(where: { $0.id == id }), !row.alreadyImported else { return }
        if selected { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
    }
    public var pendingCandidates: [AGFRAMEImportCandidate] {
        candidates.filter { !$0.alreadyImported && selectedIDs.contains($0.id) }
    }
    /// A rescan keeps the person's choices: what was unticked stays unticked; files found for the first time come ticked.
    public mutating func keepChoices(of previous: AGFRAMEImportFolder) {
        projectID = previous.projectID
        let known = Set(previous.candidates.map(\.id))
        for row in candidates where known.contains(row.id) && !previous.selectedIDs.contains(row.id) { setSelected(false, id: row.id) }
    }
    /// The project folder an agents folder belongs to (…/foo/.claude/agents → …/foo).
    public var projectRoot: String {
        let url = URL(fileURLWithPath: folder)
        guard url.lastPathComponent == "agents", url.deletingLastPathComponent().lastPathComponent == ".claude" else { return folder }
        return url.deletingLastPathComponent().deletingLastPathComponent().path
    }
}
