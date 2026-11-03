import Foundation

// AGT: the Agents page's one view of every agent — task-agent profiles (TAG's
// store, the only profile store), imported Claude Code agents (TAG profiles with
// a source file), Hoot, and agents running in live sessions. Pure presentation
// and validation: no store, no I/O. The app and the MCP tools both use it.

/// An agent's picture: a monoline SF Symbol (`sf:<name>`) or an emoji (`emoji:<text>`).
public enum AGTIcon: Equatable, Sendable, Hashable {
    case symbol(String)
    case emoji(String)

    /// The glyph colours an agent can have. An icon string may end in `@<name>`
    /// (`sf:star@pink`); without one, the agent gets a stable colour from its id.
    public static let colourNames = ["blue", "purple", "pink", "red", "orange", "green", "teal", "indigo", "mint", "brown"]
    /// The chosen colour in an icon string, if any.
    public static func colour(_ raw: String?) -> String? {
        guard let raw, let at = raw.lastIndex(of: "@") else { return nil }
        let name = String(raw[raw.index(after: at)...])
        return colourNames.contains(name) ? name : nil
    }
    /// The same colour for the same agent id on every screen and every launch (FNV-1a, not hashValue).
    public static func stableColour(id: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return colourNames[Int(hash % UInt64(colourNames.count))]
    }
    /// The icon string with a chosen colour (nil keeps the automatic one).
    public static func raw(_ icon: AGTIcon, colour: String?) -> String {
        guard let colour, colourNames.contains(colour) else { return icon.raw }
        return icon.raw + "@" + colour
    }

    public static func parse(_ raw: String?) -> AGTIcon? {
        guard var raw, !raw.isEmpty else { return nil }
        if colour(raw) != nil, let at = raw.lastIndex(of: "@") { raw = String(raw[..<at]) }
        if raw.hasPrefix("sf:") {
            let name = String(raw.dropFirst(3))
            return name.range(of: #"^[a-z0-9]+(\.[a-z0-9]+)*$"#, options: .regularExpression) != nil && name.count <= 60 ? .symbol(name) : nil
        }
        if raw.hasPrefix("emoji:") {
            let text = String(raw.dropFirst(6))
            return isEmoji(text) ? .emoji(text) : nil
        }
        return nil
    }
    public var raw: String {
        switch self {
        case .symbol(let name): "sf:" + name
        case .emoji(let text): "emoji:" + text
        }
    }
    /// One emoji (a grapheme made of emoji scalars, joiners and variation selectors).
    public static func isEmoji(_ text: String) -> Bool {
        guard text.count == 1, text.utf16.count <= 16 else { return false }
        let scalars = text.unicodeScalars
        guard scalars.contains(where: { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0xFF) }) else { return false }
        return scalars.allSatisfy { $0.properties.isEmoji || $0.value == 0x200D || $0.value == 0xFE0F || (0x1F3FB...0x1F3FF).contains($0.value) || (0xE0020...0xE007F).contains($0.value) }
    }
    /// The sentence a refusal shows; nil when the value is acceptable (nil/empty clears).
    public static func problem(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return parse(raw) == nil ? "The icon has to be one SF Symbol name (sf:name) or one emoji (emoji:🙂)." : nil
    }
}

/// What an agent is.
public enum AGTKind: String, Equatable, Sendable, CaseIterable {
    /// A task-agent profile (TAG), possibly imported from a Claude Code agent file.
    case profile
    /// The built-in assistant.
    case hoot
    /// A coding agent running in a session that has no profile.
    case session
}

/// A profile as AGT reads it, from the app's `AgentProfile` or the backend's stored row.
public struct AGTProfileInput: Equatable, Sendable {
    public var id: String, name: String, role: String
    public var icon: String?, reportsTo: String?
    public var project: String?, provider: String?, model: String?, effort: String?
    public var projectID: String?
    public var status: String
    public var claudeAgent: String?, sourceFile: String?, syncStatus: String?, syncedAt: Double?
    public var permissionMode: String?, reviewer: String?
    /// Deck Memory: the role (seat) slug saved on the profile (nil = the seat named after its id).
    public var seat: String? = nil
    public init(id: String, name: String, role: String = "general", icon: String? = nil, reportsTo: String? = nil,
                project: String? = nil, provider: String? = nil, model: String? = nil, effort: String? = nil,
                status: String = "active", claudeAgent: String? = nil, sourceFile: String? = nil,
                syncStatus: String? = nil, syncedAt: Double? = nil, permissionMode: String? = nil, reviewer: String? = nil, projectID: String? = nil) {
        self.id = id; self.name = name; self.role = role; self.icon = icon; self.reportsTo = reportsTo
        self.project = project; self.provider = provider; self.model = model; self.effort = effort; self.status = status
        self.claudeAgent = claudeAgent; self.sourceFile = sourceFile; self.syncStatus = syncStatus; self.syncedAt = syncedAt
        self.permissionMode = permissionMode; self.reviewer = reviewer; self.projectID = projectID
    }
    public init(_ profile: AgentProfile) {
        self.init(id: profile.id, name: profile.name, role: profile.role, icon: profile.icon, reportsTo: profile.reportsTo,
                  project: profile.defaultProject, provider: profile.provider, model: profile.model, effort: profile.effort,
                  status: profile.status.rawValue, claudeAgent: profile.claudeAgent, sourceFile: profile.sourceFile,
                  syncStatus: profile.syncStatus, syncedAt: profile.syncedAt, permissionMode: profile.permissionMode,
                  reviewer: profile.reviewerAgent, projectID: profile.hasExplicitProjectID ? profile.projectID : nil)
        seat = profile.seat
    }
    public init?(_ row: NativeRPCValue) {
        guard let id = row["id"].string, let name = row["name"].string else { return nil }
        self.init(id: id, name: name, role: row["role"].string ?? "general", icon: row["icon"].string, reportsTo: row["reportsTo"].string,
                  project: row["defaultProject"].string, provider: row["provider"].string, model: row["model"].string,
                  effort: row["effort"].string, status: row["status"].string ?? "active", claudeAgent: row["claudeAgent"].string,
                  sourceFile: row["sourceFile"].string, syncStatus: row["syncStatus"].string, syncedAt: row["syncedAt"].number,
                  permissionMode: row["permissionMode"].string, reviewer: row["reviewerAgent"].string, projectID: row["projectIdInferred"].bool == true ? nil : row["projectId"].string)
        seat = row["seat"].string
    }
}

/// A task as AGT reads it: who has it, and what it is.
public struct AGTTaskInput: Equatable, Sendable {
    public var id: String, title: String, assignee: String, agentName: String
    public var state: String, updatedAt: Double, project: String
    public init(id: String, title: String, assignee: String, agentName: String, state: String, updatedAt: Double, project: String = "") {
        self.id = id; self.title = title; self.assignee = assignee; self.agentName = agentName
        self.state = state; self.updatedAt = updatedAt; self.project = project
    }
    public init(_ row: TaskRow) {
        self.init(id: row.id, title: row.title, assignee: row.assignee, agentName: row.agent,
                  state: row.completedAt != nil ? "done" : row.local ? row.crmStatus : row.process.rawValue,
                  updatedAt: row.updatedAt, project: row.project)
    }
    public init?(_ row: NativeRPCValue) {
        guard let id = row["id"].string else { return nil }
        let assignee = row["assignee"].string ?? row["assignee"]["agentId"].string ?? "none"
        self.init(id: id, title: row["title"].string ?? "Task", assignee: assignee, agentName: row["agent"].string ?? "",
                  state: row["status"].string ?? row["process"].string ?? "", updatedAt: row["updatedAt"].number ?? 0,
                  project: row["project"].string ?? "")
    }
}

/// One agent on the Agents page.
public struct AGTAgent: Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: AGTKind
    /// The TAG profile id (nil for Hoot and live sessions without one).
    public var profileID: String?
    public var name: String
    public var role: String
    public var icon: AGTIcon
    /// The project folder: a profile's default project, or a session's folder.
    public var project: String
    public var provider: String
    public var model: String?
    /// active, paused or archived for profiles; "live" otherwise.
    public var status: String
    /// The live state, when it is running somewhere.
    public var live: AWWatchState?
    /// What it is doing right now, in plain words.
    public var activity: String
    public var taskTitle: String?
    /// A profile id, `AGTDirectory.hootID`, or nil (independent).
    public var reportsTo: String?
    /// Milliseconds since 1970.
    public var lastActivity: Double?
    public var machineName: String
    /// Live rows this agent stands for (a profile can run several tasks at once).
    public var liveIDs: [String]
    public var sessionID: String?
    public var claudeAgent: String?
    public var sourceFile: String?
    public var syncStatus: String?
    public var projectID: String? = nil
    /// The glyph colour chosen in the profile (`AGTIcon.colourNames`); nil means the stable automatic one.
    public var iconColour: String? = nil
    /// Deck Memory: the role (seat) slug on its profile; nil = the seat named after its id.
    /// Its seat and category come from `AGTSeats.seat(agentID:seat:projectID:projects:)`.
    public var seat: String? = nil
    /// A session's own title ("ClaudeiMatch"), kept when the row shows the lead's name instead.
    public var sessionTitle: String? = nil
    /// The seat key the app put this session in (its hand on the seat: "lead:imatch", "role:imatch/matchmaker"); nil
    /// for a session that sits in no seat. Filled from the app's hands registry, never guessed.
    public var sitsIn: String? = nil
    /// The live sessions working AS this agent (its task runs, a session started as it, one that works as the lead it
    /// is): shown on its one card ("1 session", "3 sessions"), never as cards of their own (13 Oct).
    public var sessionIDs: [String] = []
    public var resolvedProjectID: String { PROJProjects.resolve(projectID: projectID, folder: project) }

    public var isHoot: Bool { kind == .hoot || id == AGTDirectory.hootID }
    public var isImported: Bool { sourceFile != nil }
    public var kindLabel: String {
        switch kind {
        case .hoot: "Built-in assistant"
        case .session: "Live session"
        case .profile: isImported ? "Claude Code agent" : "Task agent"
        }
    }
    public var statusLabel: String {
        if kind == .profile, live == .idle { return "Ready" }
        if let live, live != .finished, live != .offline { return live.label }
        switch status {
        case "paused": return "Paused"
        case "archived": return "Archived"
        case "live": return live?.label ?? "Idle"
        default: return "Ready"
        }
    }
    public var projectName: String {
        if projectID != nil || resolvedProjectID != PROJProjects.independentID { return PROJProjects.name(for: resolvedProjectID) }
        return AGTDirectory.projectName(project)
    }

    public var wireValue: NativeRPCValue {
        func text(_ value: String?) -> NativeRPCValue { value.map(NativeRPCValue.string) ?? .null }
        return .object([.init("id", .string(id)), .init("kind", .string(kind.rawValue)), .init("profileId", text(profileID)),
            .init("name", .string(name)), .init("role", .string(role)), .init("icon", .string(icon.raw)),
            // The glyph colour chosen in its profile (nil: the stable one from its id), so a reader draws the same picture.
            .init("iconColour", text(iconColour)),
            .init("project", .string(project)), .init("projectId", .string(resolvedProjectID)),
            .init("projectIdInferred", .bool(projectID == nil && resolvedProjectID == PROJProjects.independentID)),
            .init("projectName", .string(projectName)), .init("provider", .string(provider)),
            .init("model", text(model)), .init("status", .string(status)), .init("statusLabel", .string(statusLabel)),
            .init("live", text(live?.rawValue)), .init("activity", .string(activity)), .init("taskTitle", text(taskTitle)),
            .init("reportsTo", text(reportsTo)), .init("independent", .bool(reportsTo == nil)),
            .init("lastActivity", lastActivity.map(NativeRPCValue.number) ?? .null), .init("machine", .string(machineName)),
            .init("sessionId", text(sessionID)), .init("claudeAgent", text(claudeAgent)), .init("sourceFile", text(sourceFile)),
            .init("syncStatus", text(syncStatus)),
            // Deck Memory: the role (seat) it was hired into; a LEAD is named on its project (project_registry.list → lead).
            .init("seat", text(kind == .profile ? AGTSeats.roleSeat(agentID: id, seat: seat, projectID: projectID ?? resolvedProjectID).role : nil)),
            // A session: the seat the app put it in ("lead:<project>" when it works as that project's lead), and its own title.
            .init("sitsIn", text(sitsIn)), .init("sessionTitle", text(sessionTitle)),
            // The live sessions working as this agent (shown on its card, never as agents of their own).
            .init("sessions", .array(sessionIDs.map(NativeRPCValue.string)))])
    }
}

public enum AGTDirectory {
    /// Hoot's id on the page, and the value `reportsTo` takes for Hoot. A profile id
    /// can never start with "@", so it cannot collide with an agent called "hoot".
    public static let hootID = "@hoot"
    public static let sessionPrefix = "session:"

    /// Every agent: profiles first-class, live rows folded into the profile they
    /// run for, Hoot always present, and sessions without a profile as their own.
    /// `sessionSeats`: session id → the seat key the app put that session in (its hands registry). A session in a
    /// project's lead seat that still has its default title (its folder's name) shows under the lead's name, from
    /// `projects`: "Commander", not "ClaudeiMatch".
    public static func build(profiles: [AGTProfileInput], live: [AWWatchAgent], tasks: [AGTTaskInput],
                             hootIcon: AGTIcon = .symbol("bird"), now: Double? = nil,
                             sessionSeats: [String: String] = [:], projects: [PROJProject] = []) -> [AGTAgent] {
        var agents: [AGTAgent] = profiles.map { profile in
            AGTAgent(id: profile.id, kind: .profile, profileID: profile.id, name: profile.name, role: profile.role,
                     icon: AGTIcon.parse(profile.icon) ?? AGTIconCatalog.defaultIcon(name: profile.name, role: profile.role, provider: profile.provider),
                     project: profile.project ?? "", provider: profile.provider ?? "claude", model: profile.model,
                     status: profile.status, live: nil, activity: profile.status == "paused" ? "Paused" : profile.status == "archived" ? "Archived" : "Ready for work",
                     taskTitle: nil, reportsTo: profile.reportsTo, lastActivity: nil, machineName: "This Mac", liveIDs: [],
                     sessionID: nil, claudeAgent: profile.claudeAgent, sourceFile: profile.sourceFile, syncStatus: profile.syncStatus, projectID: profile.projectID,
                     iconColour: AGTIcon.colour(profile.icon), seat: profile.seat)
        }
        func profileIndex(forTask taskID: String?, name: String) -> Int? {
            if let taskID, let task = tasks.first(where: { $0.id == taskID }) {
                if let index = agents.firstIndex(where: { $0.profileID == task.assignee }) { return index }
                if let index = agents.firstIndex(where: { $0.kind == .profile && $0.name == task.agentName }) { return index }
            }
            return taskID == nil ? nil : agents.firstIndex { $0.kind == .profile && $0.name == name }
        }
        // Recent work, from the task list, for profiles that are not running now.
        for index in agents.indices {
            let mine = tasks.filter { $0.assignee == agents[index].profileID || (!agents[index].name.isEmpty && $0.agentName == agents[index].name) }
            if let latest = mine.max(by: { $0.updatedAt < $1.updatedAt }) {
                agents[index].lastActivity = latest.updatedAt > 0 ? latest.updatedAt : nil
                agents[index].taskTitle = latest.title
            }
        }
        var hoot = AGTAgent(id: hootID, kind: .hoot, profileID: nil, name: "Hoot", role: "The built-in assistant. Plans work, hands tasks to agents and checks results.",
                            icon: hootIcon, project: "", provider: "claude", model: nil, status: "live", live: nil, activity: "Idle",
                            taskTitle: nil, reportsTo: nil, lastActivity: nil, machineName: "This Mac", liveIDs: [], sessionID: nil,
                            claudeAgent: nil, sourceFile: nil, syncStatus: nil)
        var sessions: [AGTAgent] = []
        for row in AWWatchProjection.sorted(live) {
            if row.kind == "hoot" {
                if hoot.live == nil || rank(row.state) < rank(hoot.live!) { hoot.live = row.state; hoot.activity = row.action }
                hoot.liveIDs.append(row.id); hoot.lastActivity = max(hoot.lastActivity ?? 0, row.updatedAt ?? row.since ?? 0)
                if hoot.lastActivity == 0 { hoot.lastActivity = nil }
                continue
            }
            let seated = row.machineID.isEmpty ? row.sessionID.flatMap { sessionSeats[$0] } : nil
            if let index = profileIndex(forTask: row.taskID, name: row.name) ?? seated.flatMap({ seatHolder($0, agents: agents, projects: projects) }) {
                var agent = agents[index]
                if agent.live == nil || rank(row.state) < rank(agent.live!) {
                    agent.live = row.state
                    agent.activity = row.action
                    if let title = row.taskTitle { agent.taskTitle = title }
                    agent.machineName = row.machineName
                    agent.sessionID = row.sessionID ?? agent.sessionID
                }
                agent.liveIDs.append(row.id)
                if let id = row.sessionID, row.state != .finished, row.state != .offline, !agent.sessionIDs.contains(id) { agent.sessionIDs.append(id) }
                let at = row.updatedAt ?? row.since
                if let at, at > (agent.lastActivity ?? 0) { agent.lastActivity = at }
                agents[index] = agent
                continue
            }
            // A session the task engine started is named by its inner id ("crm-<id>"): show the task's title instead.
            let shown = (row.name.isEmpty || row.name.hasPrefix("crm-")) ? (row.taskTitle.flatMap { $0.isEmpty ? nil : $0 } ?? row.name) : row.name
            let sitsIn = seated
            var session = AGTAgent(id: sessionPrefix + row.id, kind: .session, profileID: nil, name: leadName(title: shown, sitsIn: sitsIn, folder: row.project, projects: projects) ?? shown,
                                     role: row.provider.isEmpty ? "Coding agent" : AGTDirectory.providerLabel(row.provider) + " session",
                                     icon: AGTIconCatalog.defaultIcon(name: row.name, role: "", provider: row.provider, session: true),
                                     project: row.project, provider: row.provider, model: nil, status: "live", live: row.state,
                                     activity: row.action, taskTitle: row.taskTitle, reportsTo: nil, lastActivity: row.updatedAt ?? row.since,
                                     machineName: row.machineName, liveIDs: [row.id], sessionID: row.sessionID,
                                     claudeAgent: nil, sourceFile: nil, syncStatus: nil)
            session.sessionTitle = shown
            session.sitsIn = sitsIn
            sessions.append(session)
        }
        for index in agents.indices where agents[index].live != nil {
            if agents[index].live == .finished || agents[index].live == .offline { agents[index].activity = agents[index].live!.label }
        }
        return sorted([hoot] + agents + sessions)
    }

    /// The saved agent that holds a seat, for a session the app seated there: the agent a project names as its lead
    /// (`lead:<project>`), or the agent whose role is that seat (`role:<project>/<role>`). Nil when no saved agent does
    /// (a lead that is a session, a vacant seat): the session then stays a row of its own.
    static func seatHolder(_ key: String, agents: [AGTAgent], projects: [PROJProject]) -> Int? {
        guard let seat = AGTSeat(key: key) else { return nil }
        switch seat {
        case .orchestrator: return nil
        case .lead(let id):
            guard let project = projects.first(where: { $0.id == id }), let lead = AGTSeats.lead(of: project), lead.kind == .agent else { return nil }
            return agents.firstIndex { $0.kind == .profile && $0.profileID == lead.id && $0.status != "archived" }
        case .role:
            return agents.firstIndex { agent in
                guard agent.kind == .profile, agent.status != "archived", let id = agent.profileID else { return false }
                let project = PROJProjects.resolve(projectID: agent.projectID, folder: agent.project, projects: projects)
                return AGTSeats.roleSeat(agentID: id, seat: agent.seat, projectID: project) == seat
            }
        }
    }

    /// The lead's name for a session that sits in a project's lead seat and still has its default title (empty, or
    /// its folder's name or path, or the project's name). A title the person gave it is kept.
    public static func leadName(title: String, sitsIn: String?, folder: String, projects: [PROJProject]) -> String? {
        guard let key = sitsIn, case .lead(let id)? = AGTSeat(key: key), let project = projects.first(where: { $0.id == id }),
              let lead = AGTSeats.lead(of: project), !lead.name.isEmpty else { return nil }
        let given = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaults = [projectName(folder), folder, project.name].filter { !$0.isEmpty }
        guard given.isEmpty || defaults.contains(where: { $0.caseInsensitiveCompare(given) == .orderedSame }) else { return nil }
        return lead.name
    }

    static func rank(_ state: AWWatchState) -> Int {
        switch state { case .working: 0; case .waiting: 1; case .queued: 2; case .idle: 3; case .unknown: 4; case .offline: 5; case .finished: 6 }
    }

    /// Hoot first, then by name. Archived profiles go last.
    public static func sorted(_ agents: [AGTAgent]) -> [AGTAgent] {
        agents.sorted { a, b in
            func tier(_ x: AGTAgent) -> Int { x.kind == .hoot ? 0 : x.status == "archived" ? 3 : x.kind == .session ? 2 : 1 }
            if tier(a) != tier(b) { return tier(a) < tier(b) }
            let order = a.name.localizedCaseInsensitiveCompare(b.name)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
    }

    public static func providerLabel(_ provider: String) -> String {
        switch provider.lowercased() {
        case "claude", "": "Claude Code"
        case "codex": "Codex"
        case "gemini": "Gemini"
        default: provider.capitalized
        }
    }

    public static func projectName(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? "" : (trimmed.components(separatedBy: "/").last ?? trimmed)
    }

    public static func filtered(_ agents: [AGTAgent], query: String) -> [AGTAgent] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return agents }
        return agents.filter { agent in
            [agent.name, agent.role, agent.project, agent.projectName, agent.resolvedProjectID, agent.provider, agent.model ?? "", agent.activity, agent.taskTitle ?? "",
             agent.kindLabel, agent.machineName, agent.claudeAgent ?? ""].joined(separator: " ").localizedCaseInsensitiveContains(words)
        }
    }

    public enum Grouping: String, CaseIterable, Sendable { case project, reportsTo }

    public struct Group: Identifiable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var subtitle: String?
        public var agents: [AGTAgent]
    }

    /// Project groups: one per project folder, alphabetical; Hoot (works everywhere)
    /// first; agents with no folder last. Reports-to groups: one per manager, then Independent.
    public static func groups(_ agents: [AGTAgent], by grouping: Grouping, projects suppliedProjects: [PROJProject]? = nil) -> [Group] {
        let projects = suppliedProjects ?? PROJProjects.defaults
        switch grouping {
        case .project:
            var byProject: [String: [AGTAgent]] = [:]
            var everywhere: [AGTAgent] = [], none: [AGTAgent] = []
            for agent in agents {
                let projectID = PROJProjects.resolve(projectID: agent.projectID, folder: agent.project, projects: projects)
                if agent.kind == .hoot { everywhere.append(agent) }
                else if suppliedProjects != nil || agent.projectID != nil || projectID != PROJProjects.independentID { byProject[projectID, default: []].append(agent) }
                else if agent.project.isEmpty { none.append(agent) }
                else { byProject[agent.project, default: []].append(agent) }
            }
            var groups: [Group] = []
            if !everywhere.isEmpty { groups.append(Group(id: "everywhere", title: "Every project", subtitle: nil, agents: everywhere)) }
            func legacy(_ key: String) -> Bool { byProject[key]?.allSatisfy { $0.projectID == nil } == true && !projects.contains { $0.id == key } }
            func title(_ key: String) -> String { legacy(key) ? projectName(key) : PROJProjects.name(for: key, projects: projects) }
            let keys = byProject.keys.sorted { title($0).localizedCaseInsensitiveCompare(title($1)) == .orderedAscending || (title($0) == title($1) && $0 < $1) }
            for key in keys { groups.append(Group(id: "project:" + key, title: title(key), subtitle: legacy(key) ? key : nil, agents: sorted(byProject[key]!))) }
            if !none.isEmpty { groups.append(Group(id: "no-project", title: "No project", subtitle: nil, agents: sorted(none))) }
            return groups
        case .reportsTo:
            let ids = Set(agents.map(\.id))
            var byManager: [String: [AGTAgent]] = [:], independent: [AGTAgent] = []
            for agent in agents {
                if let manager = agent.reportsTo, ids.contains(manager), manager != agent.id { byManager[manager, default: []].append(agent) }
                else { independent.append(agent) }
            }
            let managers = sorted(agents.filter { byManager[$0.id] != nil })
            var groups = managers.map { manager in
                Group(id: "reports:" + manager.id, title: "Reports to \(manager.name)", subtitle: manager.role, agents: sorted(byManager[manager.id]!))
            }
            if !independent.isEmpty { groups.append(Group(id: "independent", title: "Independent", subtitle: "Reports to no one", agents: sorted(independent))) }
            return groups
        }
    }

    /// Counts for the sidebar's "At work" row.
    public static func counts(_ live: [AWWatchAgent]) -> (working: Int, waiting: Int) {
        (live.filter { $0.state == .working }.count, live.filter { $0.state == .waiting }.count)
    }
}

/// Who reports to whom.
public enum AGTOrgChart {
    public struct Node: Identifiable, Equatable, Sendable {
        public var id: String { agent.id }
        public var agent: AGTAgent
        public var reports: [Node]
        public var size: Int { 1 + reports.reduce(0) { $0 + $1.size } }
    }

    /// Trees (managers at the top, Hoot first) and the independent agents: no
    /// manager and no one reporting to them. A broken or looping link reads as
    /// independent, so a bad stored value can never hide an agent.
    public static func chart(_ agents: [AGTAgent]) -> (trees: [Node], independent: [AGTAgent]) {
        let visible = agents.filter { $0.status != "archived" }
        let ids = Set(visible.map(\.id))
        var manager: [String: String] = [:]
        for agent in visible {
            if let boss = agent.reportsTo, ids.contains(boss), boss != agent.id, agent.kind == .profile { manager[agent.id] = boss }
        }
        // Drop links that loop (A → B → A) so every agent is reachable exactly once.
        let looping = manager.keys.filter { loops(from: $0, manager) }
        for id in looping { manager[id] = nil }
        var reports: [String: [AGTAgent]] = [:]
        for agent in visible { if let boss = manager[agent.id] { reports[boss, default: []].append(agent) } }
        func node(_ agent: AGTAgent) -> Node {
            Node(agent: agent, reports: AGTDirectory.sorted(reports[agent.id] ?? []).map(node))
        }
        let roots = AGTDirectory.sorted(visible.filter { manager[$0.id] == nil && reports[$0.id] != nil })
        let independent = AGTDirectory.sorted(visible.filter { manager[$0.id] == nil && reports[$0.id] == nil })
        return (roots.map(node), independent)
    }

    private static func loops(from id: String, _ manager: [String: String]) -> Bool {
        var seen: Set<String> = [id], current = manager[id]
        while let next = current {
            if seen.contains(next) { return true }
            seen.insert(next); current = manager[next]
        }
        return false
    }

    /// Why `id` cannot report to `boss`, in plain words; nil when it can.
    /// `managers` maps every profile id to its current manager. Nil `boss` = independent.
    public static func refusal(id: String, reportsTo boss: String?, managers: [String: String?], names: [String: String] = [:]) -> String? {
        guard let boss else { return nil }
        func name(_ x: String) -> String { x == AGTDirectory.hootID ? "Hoot" : names[x] ?? x }
        if boss == id { return "An agent cannot report to itself." }
        if boss == AGTDirectory.hootID { return nil }
        guard managers.keys.contains(boss) else { return "There is no agent called \(boss) to report to." }
        var seen: Set<String> = [boss], current: String? = boss
        while let next = current.flatMap({ managers[$0] ?? nil }) {
            if next == id { return "\(name(boss)) already reports to \(name(id)), so \(name(id)) cannot report to \(name(boss))." }
            if seen.contains(next) { break }
            seen.insert(next); current = next
        }
        return nil
    }

    /// Everyone below `id` (for pickers: an agent cannot report to its own reports).
    public static func below(_ id: String, managers: [String: String?]) -> Set<String> {
        var out: Set<String> = [], frontier = [id]
        while let next = frontier.popLast() {
            for (agent, boss) in managers where boss == next && !out.contains(agent) && agent != id { out.insert(agent); frontier.append(agent) }
        }
        return out
    }

    public static func wireValue(_ chart: (trees: [Node], independent: [AGTAgent])) -> NativeRPCValue {
        func node(_ n: Node) -> NativeRPCValue {
            .object([.init("id", .string(n.agent.id)), .init("name", .string(n.agent.name)), .init("role", .string(n.agent.role)),
                     .init("icon", .string(n.agent.icon.raw)), .init("status", .string(n.agent.statusLabel)),
                     .init("reports", .array(n.reports.map(node)))])
        }
        return .object([.init("trees", .array(chart.trees.map(node))),
                        .init("independent", .array(chart.independent.map { .object([.init("id", .string($0.id)), .init("name", .string($0.name)),
                            .init("kind", .string($0.kind.rawValue)), .init("icon", .string($0.icon.raw))]) }))])
    }
}
