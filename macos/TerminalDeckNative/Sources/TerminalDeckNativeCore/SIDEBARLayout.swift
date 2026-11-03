import Foundation

/// Presentation only: engine identities and actions remain unchanged.
public enum SIDEBARLayout {
    public static let main = ["hoot", "agents-all", "tasks", "artifacts"]
    /// Simulators left the side panel (Asad 10 Oct): phones live in each session's and Hoot's phone panel.
    public static let machines = ["servers", "devices"]
    public static let integrations = ["receiver", "mcp", "store"]
    public static let palette = ["#0A84FF", "#8E5CF7", "#E8508A", "#F08A24", "#D9B200", "#34A853", "#1AA6B7", "#8E8E93"]

    public static func selected(_ id: String?) -> String? {
        ["agents-all", "agents-org", "agents-watch", "agents-routines", "agents-skills"].contains(id ?? "") ? "agents-all" : id
    }

    public static func running(_ state: SidebarState, liveIDs: Set<String>? = nil, started: [String: Double] = [:]) -> [SidebarItem] {
        var seen = Set<String>()
        return state.allItems.filter {
            $0.kind == .session && !$0.isHeld && seen.insert($0.id).inserted &&
            (liveIDs?.contains($0.id) ?? (StatusMeaning($0.status) != .exited && StatusMeaning($0.status) != .failed))
        }.sorted {
            let a = started[$0.id] ?? 0, b = started[$1.id] ?? 0
            return a == b ? $0.id > $1.id : a > b
        }
    }

    public static func project(for session: String, in state: SidebarState) -> SidebarProject? {
        state.projects.first { $0.id.hasPrefix("/") && $0.sessions.contains { $0.id == session } }
    }

    /// The rows under Projects: the open folders inside a registered project, then every registered project
    /// (never Independent) that none of them belongs to, by its first folder and its registered name. The page's
    /// folder list can lag (a folder opened by a tool shows only when the page next reloads), so a registered
    /// project never depends on it to be listed (Asad, 11 Oct: "Terminal Deck" was missing).
    public static func projectRows(open: [SidebarProject], registry: [PROJProject]) -> [SidebarProject] {
        let inProjects = open.filter { $0.id.hasPrefix("/") && PROJOpenFolders.isProject($0.id, registry: registry) }
        let covered = Set(inProjects.map { PROJProjects.resolve(projectID: nil, folder: $0.id, projects: registry) })
        let missing = registry.filter { $0.id != PROJProjects.independentID && !covered.contains($0.id) }.compactMap { project -> SidebarProject? in
            guard let folder = project.folders.first(where: { $0.hasPrefix("/") }) else { return nil }
            return SidebarProject(id: folder, title: project.name, expanded: false, sessions: [])
        }
        return inProjects + missing
    }

    public static func colour(path: String?, projects: [SidebarProject], registry: [PROJProject]) -> String {
        guard let path else { return palette[7] }
        let id = PROJProjects.resolve(projectID: nil, folder: path, projects: registry)
        let registered = registry.filter { $0.id != PROJProjects.independentID }
        if let colour = registered.first(where: { $0.id == id })?.colour,
           colour.hasPrefix("#"), colour.count == 7 { return colour }
        let names = ["blue", "purple", "pink", "orange", "yellow", "green", "teal", "graphite"]
        if let colour = registered.first(where: { $0.id == id })?.colour,
           let index = names.firstIndex(of: colour) { return palette[index] }
        let index = registered.firstIndex { $0.id == id } ?? projects.filter { $0.id.hasPrefix("/") }.firstIndex { $0.id == path } ?? 0
        return palette[index % palette.count]
    }

    public static func status(_ item: SidebarItem) -> String {
        switch StatusMeaning(item.status) {
        case .working: "Working"
        case .needsInput: "Waiting for you"
        case .ready, .completed: "At a prompt"
        case .exited: "Stopped"
        case .failed: "Failed"
        }
    }
}
