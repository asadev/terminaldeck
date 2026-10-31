import Foundation

// Project setup (Asad, 11 Oct): "starting a project in the app should not be just simply choose a folder
// and start session ... to setup a project you will have to go through necessary flow of creating a project
// ... it may show project setup percentage and missing parts somewhere on project page once done it goes".
// A folder opened on its own is a plain session under Independent; a project is made through the guide.
// Pure rules shared by the guide window, the project page's "Setup N%" card and the app tools.

/// One page of the New project guide, in order. Only the name and the home folder are required.
public enum PROJGuideStep: String, CaseIterable, Codable, Sendable, Identifiable {
    case name, folders, lead, team, skills, card, connections, review

    public var id: String { rawValue }
    public var number: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }
    public var required: Bool { self == .name || self == .folders }

    /// The short label in the step bar.
    public var title: String {
        switch self {
        case .name: "Name"
        case .folders: "Folder"
        case .lead: "Lead"
        case .team: "Team"
        case .skills: "Skills"
        case .card: "Card"
        case .connections: "Connections"
        case .review: "Review"
        }
    }
    /// The page's own heading.
    public var heading: String {
        switch self {
        case .name: "Name and look"
        case .folders: "Home folder"
        case .lead: "Lead agent"
        case .team: "Team"
        case .skills: "Skills"
        case .card: "Project card"
        case .connections: "Connections"
        case .review: "Review"
        }
    }
    /// One plain sentence: why this step matters.
    public var why: String {
        switch self {
        case .name: "A clear name and one line on what it is help every agent and Hoot know what this project is for."
        case .folders: "The home folder is where the project's files live and where its sessions start. Tools may only work inside a project's folders."
        case .lead: "A lead runs this project's agents: Hoot gives it goals, and it hands out the work and reports back."
        case .team: "Each role is a seat with its own memory. Memory belongs to the seat, not to the agent, so a new agent in the same role keeps what the role learned."
        case .skills: "Skills are ready-made instructions an agent can use. Give each agent the ones its role needs."
        case .card: "The project card is what the lead reads first every time: the goals, the rules and the key facts."
        case .connections: "Link the project's code, task list and servers so agents can find them. All optional."
        case .review: "Check what is set and what was skipped. Anything skipped can be added later from the project page."
        }
    }
    /// A monoline symbol for the step.
    public var symbol: String {
        switch self {
        case .name: "textformat"
        case .folders: "folder"
        case .lead: "person.crop.circle.badge.checkmark"
        case .team: "person.3"
        case .skills: "wand.and.stars"
        case .card: "note.text"
        case .connections: "link"
        case .review: "checklist"
        }
    }
    /// For app tools: the tools that do this step by chat.
    public var tools: [String] {
        switch self {
        case .name: ["project_registry_save", "project_settings_set (values.about)", "projects_logo"]
        case .folders: ["projects_browse", "project_registry_save (folders)", "projects_add"]
        case .lead: ["project_registry_set_lead", "project_settings_set (values.\"setup.hootLeads\": true for Hoot leads for now)"]
        case .team: ["tasks_agents (save, with this project's id)", "agents_set_role"]
        case .skills: ["skills_list", "skills_assign"]
        case .card: ["memory_card_save (seat lead:<project id>)"]
        case .connections: ["github_state", "github_connect", "connected_tasks_systems", "connected_tasks_connect", "servers_look", "servers_manage",
                             "project_settings_set (values.githubRepo, values.taskSystem, values.linkedServers)"]
        case .review: ["project_setup_status"]
        }
    }
}

/// What the setup score counts. Connections do not count.
public enum PROJSetupPart: String, CaseIterable, Codable, Sendable, Identifiable {
    case description, logo, lead, team, skills, card

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .description: "What it is"
        case .logo: "Logo"
        case .lead: "Lead"
        case .team: "Team"
        case .skills: "Skills"
        case .card: "Project card"
        }
    }
    /// The plain line shown while it is missing.
    public var missingLine: String {
        switch self {
        case .description: "No line on what the project is"
        case .logo: "No logo"
        case .lead: "No lead"
        case .team: "No agents on the team"
        case .skills: "No agent has a skill"
        case .card: "The project card is empty"
        }
    }
    /// The button that fixes it.
    public var action: String {
        switch self {
        case .description: "Add a line"
        case .logo: "Add a logo"
        case .lead: "Choose a lead"
        case .team: "Add an agent"
        case .skills: "Give skills"
        case .card: "Write the card"
        }
    }
    /// The guide page that fixes it.
    public var step: PROJGuideStep {
        switch self {
        case .description, .logo: .name
        case .lead: .lead
        case .team: .team
        case .skills: .skills
        case .card: .card
        }
    }
}

/// One saved agent, as far as the setup score cares.
public struct PROJSetupAgent: Equatable, Sendable {
    public var id: String
    public var projectID: String
    public var skills: [String]
    public var archived: Bool
    public init(id: String, projectID: String, skills: [String] = [], archived: Bool = false) {
        self.id = id; self.projectID = projectID; self.skills = skills; self.archived = archived
    }
    public init(_ profile: AgentProfile) {
        self.init(id: profile.id, projectID: profile.projectID, skills: profile.skills, archived: profile.status == .archived)
    }
    /// A `tasks:state` agent row: its project the way a profile reads it (explicit id, else its folder).
    public init?(row: NativeRPCValue, projects: [PROJProject]) {
        guard let id = row["id"].string, !id.isEmpty else { return nil }
        let folder = row["sourceDirectory"].string ?? row["sourceFile"].string ?? row["defaultProject"].string
        self.init(id: id, projectID: PROJProjects.resolve(projectID: row["projectId"].string ?? row["projectID"].string, folder: folder, projects: projects),
                  skills: (row["skills"].elements ?? []).compactMap(\.string), archived: row["status"].string == AgentStatus.archived.rawValue)
    }
}

/// What is known about one project's setup.
public struct PROJSetupFacts: Equatable, Sendable {
    public var about: String
    public var logo: String
    public var lead: String
    /// The person chose "Hoot leads for now" in the guide.
    public var hootLeads: Bool
    /// Saved agents in the project, the lead agent not counted.
    public var teamAgents: Int
    /// Agents in the project (the lead included) that have at least one skill.
    public var agentsWithSkills: Int
    /// The lead seat's own card text.
    public var cardText: String
    public init(about: String = "", logo: String = "", lead: String = "", hootLeads: Bool = false,
                teamAgents: Int = 0, agentsWithSkills: Int = 0, cardText: String = "") {
        self.about = about; self.logo = logo; self.lead = lead; self.hootLeads = hootLeads
        self.teamAgents = teamAgents; self.agentsWithSkills = agentsWithSkills; self.cardText = cardText
    }
}

public struct PROJSetupScore: Equatable, Sendable {
    public var done: [PROJSetupPart]
    public var missing: [PROJSetupPart]
    public var percent: Int
    /// Every part is set: the project page shows no setup card.
    public var complete: Bool { missing.isEmpty }
}

public enum PROJSetup {
    /// Project settings keys the guide writes (the same per-project settings Project settings uses).
    public static let aboutKey = "about"
    public static let hootLeadsKey = "setup.hootLeads"
    public static let repoKey = "githubRepo"
    public static let taskSystemKey = "taskSystem"
    public static let serversKey = "linkedServers"

    public static func facts(project: PROJProject, settings: NativeRPCValue, agents: [PROJSetupAgent], card: String) -> PROJSetupFacts {
        let values = settings["values"].fields == nil ? settings : settings["values"]
        let leadAgent = project.lead.hasPrefix("agent:") ? String(project.lead.dropFirst("agent:".count)) : nil
        let mine = agents.filter { $0.projectID == project.id && !$0.archived }
        return .init(about: values[aboutKey].string ?? "", logo: project.logo, lead: project.lead,
                     hootLeads: values[hootLeadsKey].bool == true,
                     teamAgents: mine.filter { $0.id != leadAgent }.count,
                     agentsWithSkills: (mine + agents.filter { $0.id == leadAgent && $0.projectID != project.id && !$0.archived })
                        .filter { !$0.skills.isEmpty }.count,
                     cardText: card)
    }

    public static func score(_ facts: PROJSetupFacts) -> PROJSetupScore {
        var done: [PROJSetupPart] = [], missing: [PROJSetupPart] = []
        for part in PROJSetupPart.allCases {
            let set: Bool
            switch part {
            case .description: set = !facts.about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .logo: set = !facts.logo.isEmpty
            case .lead: set = !facts.lead.isEmpty || facts.hootLeads
            case .team: set = facts.teamAgents > 0
            case .skills: set = facts.agentsWithSkills > 0
            case .card: set = cardIsFilled(facts.cardText)
            }
            if set { done.append(part) } else { missing.append(part) }
        }
        let percent = Int((Double(done.count) * 100 / Double(PROJSetupPart.allCases.count)).rounded())
        return .init(done: done, missing: missing, percent: percent)
    }

    /// A card counts once it says something: a line that is not a heading and not an empty bullet.
    /// A seat's starter card (headings only) and the guide's untouched blanks do not count.
    public static func cardIsFilled(_ text: String) -> Bool {
        text.components(separatedBy: .newlines).contains { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return false }
            let body = line.trimmingCharacters(in: CharacterSet(charactersIn: "-*• ").union(.whitespaces))
            if body.isEmpty { return false }
            // "- What it is:" with nothing after the colon is still a blank.
            if body.hasSuffix(":"), !body.dropLast().contains(":") { return false }
            return true
        }
    }

    /// The lead seat's own card, prefilled from the guide's first page. Goals and rules stay for the person.
    public static func cardText(name: String, about: String, folder: String?, goals: [String] = [], rules: [String] = []) -> String {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        func list(_ items: [String]) -> String {
            let kept = items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return kept.isEmpty ? "- \n" : kept.map { "- " + $0 + "\n" }.joined()
        }
        var facts = ""
        let line = about.trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.isEmpty { facts += "- What it is: " + line + "\n" }
        if let folder, !folder.isEmpty { facts += "- Home folder: " + folder + "\n" }
        if facts.isEmpty { facts = "- \n" }
        return "# Lead of " + (title.isEmpty ? "this project" : title) + "\n\n## Goals\n" + list(goals) + "\n## Top rules\n" + list(rules) + "\n## Key facts\n" + facts
    }

    /// A registry id from the project's name: lowercase letters, digits and dashes, unique, never Independent's.
    public static func projectID(for name: String, taken: Set<String>) -> String {
        var base = "", dash = false
        for scalar in name.lowercased().decomposedStringWithCompatibilityMapping.unicodeScalars {
            if scalar.properties.generalCategory == .nonspacingMark { continue }   // "é" → "e"
            if (97...122).contains(scalar.value) || (48...57).contains(scalar.value) { base.unicodeScalars.append(scalar); dash = false }
            else if !base.isEmpty, !dash { base.append("-"); dash = true }
        }
        while base.hasSuffix("-") { base.removeLast() }
        base = String(base.prefix(60))
        while base.hasSuffix("-") { base.removeLast() }
        if base.isEmpty || !PROJProjects.isValidID(base) { base = "project" }
        var candidate = base, n = 2
        while taken.contains(candidate) || candidate == PROJProjects.independentID { candidate = base + "-" + String(n); n += 1 }
        return candidate
    }

    /// The built-in skill Hoot follows to set a project up by chat (macos/built-in-skills/project-setup).
    public static let hootSkill = "project-setup"

    /// The first message when the person picks "Set up with Hoot" in the guide: what is known so far, nothing more.
    public static func hootStarter(name: String, folder: String?, about: String, projectID: String? = nil) -> String {
        var lines: [String] = []
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAbout = about.trimmingCharacters(in: .whitespacesAndNewlines)
        if let projectID {
            lines.append("Help me finish setting up the project \(cleanName.isEmpty ? projectID : cleanName) (id \(projectID)). Use your \(hootSkill) skill: start from project_setup_status and do only what is missing.")
        } else {
            lines.append("Help me set up a new project, step by step. Use your \(hootSkill) skill: ask me only what is needed and explain each part in one sentence.")
            if !cleanName.isEmpty { lines.append("Name: " + cleanName) }
            if let folder, !folder.isEmpty { lines.append("Home folder: " + folder) }
            if !cleanAbout.isEmpty { lines.append("What it is: " + cleanAbout) }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: App tools

    /// One project's score as the read tool answers it.
    public static func statusWire(project: PROJProject, score: PROJSetupScore) -> NativeRPCValue {
        .object([
            .init("projectId", .string(project.id)), .init("name", .string(project.name)),
            .init("percent", .number(Double(score.percent))), .init("complete", .bool(score.complete)),
            .init("done", .array(score.done.map { .string($0.rawValue) })),
            .init("missing", .array(score.missing.map { part in
                .object([.init("part", .string(part.rawValue)), .init("title", .string(part.title)), .init("line", .string(part.missingLine)),
                         .init("step", .string(part.step.rawValue)), .init("how", .string(how(part, projectID: project.id)))])
            }))
        ])
    }

    /// The sentence Hoot follows to fix one missing part by chat.
    public static func how(_ part: PROJSetupPart, projectID: String) -> String {
        switch part {
        case .description: "Ask for one line on what the project is; save it with project_settings_set (projectId \(projectID), values {\"about\": line})."
        case .logo: "Ask for an image file; set it with projects_logo (project \(projectID), path)."
        case .lead: "Offer a new agent (tasks_agents save, then project_registry_set_lead with agent:<id>), an existing agent (project_registry_set_lead), or Hoot leads for now (project_settings_set values {\"setup.hootLeads\": true})."
        case .team: "Add roles: save an agent with this project's id (tasks_agents), then put it in its role with agents_set_role."
        case .skills: "List skills with skills_list and give the ones each role needs with skills_assign."
        case .card: "Write the goals, top rules and key facts; save them with memory_card_save on seat lead:\(projectID)."
        }
    }

    /// The guide's pages in order, so any AI can walk a person through the same steps by chat.
    public static func guideWire() -> NativeRPCValue {
        .object([
            .init("rule", .string("A folder opened on its own is a plain session under Independent. A project is made through these steps: only the name and the home folder are required; the rest can be skipped and added later. Create the project with project_registry_save (id, name, folders) and open its folders with projects_add, then do the other steps. project_setup_status shows what is still missing; project_setup_open shows the same guide on the person's screen.")),
            .init("steps", .array(PROJGuideStep.allCases.map { step in
                .object([.init("step", .string(step.rawValue)), .init("number", .number(Double(step.number))), .init("title", .string(step.heading)),
                         .init("why", .string(step.why)), .init("required", .bool(step.required)),
                         .init("tools", .array(step.tools.map(NativeRPCValue.string)))])
            })),
            .init("scoreCounts", .array(PROJSetupPart.allCases.map { .string($0.rawValue) })),
            .init("skill", .string(hootSkill))
        ])
    }
}

/// The side panel's open folders, split: folders inside a registered project, and plain folders
/// (sessions opened on a folder without the guide), which stay under Independent.
public enum PROJOpenFolders {
    public static func isProject(_ folder: String, registry: [PROJProject]) -> Bool {
        PROJProjects.resolve(projectID: nil, folder: folder, projects: registry) != PROJProjects.independentID
    }
    public static func split(_ folders: [String], registry: [PROJProject]) -> (projects: [String], plain: [String]) {
        var projects: [String] = [], plain: [String] = []
        for folder in folders where folder.hasPrefix("/") {
            if isProject(folder, registry: registry) { projects.append(folder) } else { plain.append(folder) }
        }
        return (projects, plain)
    }
}
