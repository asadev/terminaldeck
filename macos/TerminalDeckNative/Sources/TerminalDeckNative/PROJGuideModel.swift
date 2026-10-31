import AppKit
import Foundation
import Observation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// The New project guide's state and what Create does (Asad, 11 Oct: "to setup a project you will have to go
/// through necessary flow of creating a project ... it will ask them to set a lead agent, sub agents so user
/// knows what exists and how a project setup looks like"). Only the name and the home folder are required.
/// Every write goes through the same calls the app's own screens use (project registry, open folders,
/// project settings, tasks:agent-save, tasks:agents-import, skills:assign, Deck Memory's card).
@MainActor @Observable
final class PROJGuideModel {
    enum Mode: Equatable { case create, edit(String) }
    enum LeadChoice: Equatable { case unset, keep, hire, existing(String), hoot }

    /// A new agent made by the guide: the New agent form's essential pieces.
    struct NewAgent: Equatable {
        var name = ""
        var provider = ""
        var role = ""
        var icon: AGTIcon?
    }
    /// One role (seat) on the team, with its agent: a new one or an existing one.
    struct Seat: Identifiable, Equatable {
        let id = UUID()
        var title = ""
        var existing: String?
        var agent = NewAgent()
        var key: String { existing.map { "agent:" + $0 } ?? "seat:" + id.uuidString }
    }
    /// An agent file found in a folder's .claude/agents.
    struct Found: Identifiable, Equatable {
        var id: String { file }
        let file: String
        let folder: String
        let name: String
        let alreadyImported: Bool
        var selected: Bool
    }
    /// A skill the project can use, and which of the plan's agents get it (keys, see `planAgents`).
    struct Skill: Identifiable, Equatable {
        let id: String
        let name: String
        let summary: String
        let source: String
        var agents: Set<String>
        var original: Set<String>
    }

    var mode: Mode
    var step: PROJGuideStep
    var visited: Set<PROJGuideStep> = []
    var skipped: Set<PROJGuideStep> = []
    // 1 Name and look
    var name = ""
    var about = ""
    var colour = ""
    var logoFile: URL?
    var existingLogo = ""
    var removeLogo = false
    // 2 Folders
    var home: String?
    var extraFolders: [String] = []
    // 3 Lead
    var lead: LeadChoice = .unset
    var leadHire = NewAgent()
    var currentLead = ""
    var currentLeadName = ""
    // 4 Team
    var seats: [Seat] = []
    var found: [Found] = []
    var scanning = false
    // 5 Skills
    var skills: [Skill] = []
    // 6 Card
    var card = ""
    var cardEdited = false
    var savedCard = ""
    // 7 Connections
    var repo = ""
    var taskSystem = ""
    var servers: Set<String> = []
    /// GitHub's own sign-in and the folder's repository, as the GitHub page reads them (GUIDE-CONNECT).
    let github = GitHubScreenModel()
    // Saved values in edit mode, to send only what changed.
    @ObservationIgnored private var savedSettings = NativeRPCValue.object([])
    @ObservationIgnored private var original: PROJProject?
    // Work
    var busy = false
    var problem: String?
    var notes: [String] = []
    /// Offscreen pictures and tests: nothing is read or written.
    let fixture: Bool

    init(mode: Mode = .create, step: PROJGuideStep = .name, folder: String? = nil, fixture: Bool = false) {
        self.mode = mode; self.step = step; self.fixture = fixture
        if let folder {
            home = PROJProjects.normalize(folder)
            name = (folder as NSString).lastPathComponent
        }
        visited.insert(step)
    }

    var creating: Bool { mode == .create }
    var projectID: String? { if case .edit(let id) = mode { return id } else { return nil } }

    // MARK: Reading

    private var store: AGTAgentsStore { .shared }
    private var registry: [PROJProject] { SHELLRoutes.registry }
    private var profiles: [AgentProfile] { store.profiles }

    /// Agents a step may pick: not archived, not leading another project, and in no other project.
    var eligibleAgents: [AgentProfile] {
        profiles.filter { profile in
            guard profile.status != .archived else { return false }
            let project = profile.projectID
            guard project == PROJProjects.independentID || project == projectID else { return false }
            let led = AGTSeats.ledProject(agentID: profile.id, projects: registry)
            return led == nil || led?.id == projectID
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    /// The project's agents already saved (edit mode), the lead not counted.
    var existingTeam: [AgentProfile] {
        guard let projectID else { return [] }
        let leadAgent = currentLead.hasPrefix("agent:") ? String(currentLead.dropFirst(6)) : nil
        return profiles.filter { $0.projectID == projectID && $0.status != .archived && $0.id != leadAgent }
    }
    func agentName(_ id: String) -> String { profiles.first { $0.id == id }?.name ?? id }

    /// One agent of the plan: its key (`lead`, `seat:<id>`, `import:<file>` or `agent:<saved id>`), name and picture.
    struct PlanAgent: Identifiable, Equatable {
        let key: String
        let name: String
        let icon: String?
        var id: String { key }
    }
    /// Every agent the plan will have: the lead, the roles, the imports and the saved team.
    var planAgents: [PlanAgent] {
        var rows: [PlanAgent] = []
        switch lead {
        case .hire: rows.append(.init(key: "lead", name: leadHire.name.isEmpty ? "New lead" : leadHire.name, icon: leadHire.icon?.raw))
        case .existing(let id): rows.append(.init(key: "agent:" + id, name: agentName(id), icon: profiles.first { $0.id == id }?.icon))
        case .keep where currentLead.hasPrefix("agent:"):
            let id = String(currentLead.dropFirst(6)); rows.append(.init(key: "agent:" + id, name: agentName(id), icon: profiles.first { $0.id == id }?.icon))
        default: break
        }
        for agent in existingTeam { rows.append(.init(key: "agent:" + agent.id, name: agent.name, icon: agent.icon)) }
        for seat in seats where seat.existing != nil || !seatAgentName(seat).isEmpty {
            rows.append(.init(key: seat.key, name: seat.existing.map(agentName) ?? seatAgentName(seat),
                              icon: seat.existing.flatMap { id in profiles.first { $0.id == id }?.icon } ?? seat.agent.icon?.raw))
        }
        for row in found where row.selected && !row.alreadyImported { rows.append(.init(key: "import:" + row.file, name: row.name, icon: nil)) }
        var seen = Set<String>()
        return rows.filter { seen.insert($0.key).inserted }
    }
    func seatAgentName(_ seat: Seat) -> String {
        let name = seat.agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? seat.title.trimmingCharacters(in: .whitespacesAndNewlines) : name
    }

    /// Edit mode: everything the project already has, so each page starts from today's values.
    func load() async {
        guard !fixture else { return }
        store.start()
        ConnectedTasksStore.shared.start()
        NativeServersModel.shared.start()
        if let projectID, let project = registry.first(where: { $0.id == projectID }) {
            original = project
            name = project.name; colour = project.colour; existingLogo = project.logo
            home = project.folders.first; extraFolders = Array(project.folders.dropFirst())
            currentLead = project.lead; currentLeadName = project.leadName
            if let settings = try? NativeRPCValue.fromFoundation(try await EngineBridge.shared.invoke("project-settings:get", [["projectId": projectID]])) {
                savedSettings = settings["values"]
                about = savedSettings[PROJSetup.aboutKey].string ?? ""
                repo = savedSettings[PROJSetup.repoKey].string ?? ""
                taskSystem = savedSettings[PROJSetup.taskSystemKey].string ?? ""
                servers = Set((savedSettings[PROJSetup.serversKey].string ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
                if savedSettings[PROJSetup.hootLeadsKey].bool == true, project.lead.isEmpty { lead = .hoot }
            }
            if !project.lead.isEmpty { lead = .keep }
            let text = (try? await DeckMemory.store.card(.lead(projectID)).text) ?? ""
            savedCard = text
            card = PROJSetup.cardIsFilled(text) ? text : PROJSetup.cardText(name: name, about: about, folder: home)
            cardEdited = PROJSetup.cardIsFilled(text)
        } else {
            card = PROJSetup.cardText(name: name, about: about, folder: home)
        }
        if repo.isEmpty, let home { repo = Self.gitHubRepo(folder: home) ?? "" }
        await loadSkills()
        if let home, found.isEmpty { await scan(folder: home) }
    }

    /// The project's own skills and the ones every project shares (built-in ones are left out).
    func loadSkills() async {
        guard !fixture else { return }
        var rows: [Skill] = []
        if let value = try? NativeRPCValue.fromFoundation(try await EngineBridge.shared.invoke("skills:list", [["installed": true]])) {
            for skill in (value["skills"].elements ?? []).compactMap(ROUTINESSkill.decode) where !skill.builtIn {
                guard skill.projectID == nil || (projectID != nil && skill.projectID == projectID) else { continue }
                rows.append(.init(id: skill.id, name: skill.name, summary: skill.summary, source: skill.projectID == nil ? "Every project" : "This project", agents: [], original: []))
            }
        }
        // A new project's folder is not registered yet: read its .claude/skills the way the Skills page will.
        for folder in [home].compactMap({ $0 }) + extraFolders where projectID == nil {
            for skill in Self.folderSkills(folder) where !rows.contains(where: { $0.id == skill.id }) { rows.append(skill) }
        }
        // Which of the plan's saved agents already have each skill (edit mode).
        for index in rows.indices {
            let name = rows[index].name
            let holders = Set(planAgents.compactMap { row -> String? in
                guard row.key.hasPrefix("agent:"), let profile = profiles.first(where: { "agent:" + $0.id == row.key }), profile.skills.contains(name) else { return nil }
                return row.key
            })
            rows[index].agents = holders; rows[index].original = holders
        }
        // Keep choices already made on this page.
        for index in rows.indices { if let kept = skills.first(where: { $0.id == rows[index].id }) { rows[index].agents = kept.agents } }
        skills = rows.sorted { ($0.source, $0.name.lowercased()) < ($1.source, $1.name.lowercased()) }
    }

    /// Agent files in the folder's .claude/agents, through the same scan the Import agents sheet uses.
    func scan(folder: String) async {
        guard !fixture, !scanning else { return }
        scanning = true; defer { scanning = false }
        guard let value = try? NativeRPCValue.fromFoundation(try await EngineBridge.shared.invoke("tasks:agents-scan", [["folders": [folder]]], timeout: 10)) else { return }
        let root = PROJProjects.normalize(folder)
        for batch in value["batches"].elements ?? [] {
            guard let batchFolder = batch["folder"].string, PROJProjects.normalize(batchFolder).hasPrefix(root) else { continue }
            for row in batch["agents"].elements ?? [] {
                guard let file = row["file"].string, let name = row["name"].string, !found.contains(where: { $0.file == file }) else { continue }
                let already = row["alreadyImported"].bool ?? false
                found.append(.init(file: file, folder: batchFolder, name: name, alreadyImported: already, selected: !already))
            }
        }
    }

    static func folderSkills(_ folder: String) -> [Skill] {
        let root = URL(fileURLWithPath: folder).standardizedFileURL.appendingPathComponent(".claude/skills", isDirectory: true)
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return dirs.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(200).compactMap { dir in
            let file = dir.appendingPathComponent("SKILL.md")
            guard let data = try? Data(contentsOf: file), data.count <= 262_144 else { return nil }
            let text = String(decoding: data, as: UTF8.self)
            return Skill(id: dir.standardizedFileURL.path, name: SkillCommandNames.headerName(text) ?? dir.lastPathComponent,
                         summary: frontMatter(text, "description") ?? "", source: "This project", agents: [], original: [])
        }
    }
    static func frontMatter(_ text: String, _ key: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard line.hasPrefix(key + ":") else { continue }
            let value = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }
    /// "owner/name" from the folder's git remote "origin", when it is on GitHub.
    static func gitHubRepo(folder: String) -> String? {
        guard let text = try? String(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent(".git/config"), encoding: .utf8) else { return nil }
        var inOrigin = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inOrigin = line == "[remote \"origin\"]"; continue }
            guard inOrigin, line.hasPrefix("url") , let equals = line.firstIndex(of: "=") else { continue }
            var url = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard let host = url.range(of: "github.com") else { return nil }
            url = String(url[host.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: ":/"))
            if url.hasSuffix(".git") { url.removeLast(4) }
            let parts = url.split(separator: "/")
            return parts.count >= 2 ? parts[0] + "/" + parts[1] : nil
        }
        return nil
    }

    /// A new home folder: the agent files and skills found follow it, and so does the card's prefill.
    func setHome(_ path: String) {
        let folder = PROJProjects.normalize(path)
        home = folder
        extraFolders.removeAll { PROJProjects.normalize($0) == folder }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { name = (folder as NSString).lastPathComponent }
        let kept = [folder] + extraFolders
        found.removeAll { row in !row.alreadyImported && !kept.contains { row.folder.hasPrefix($0) } }
        if !cardEdited { card = PROJSetup.cardText(name: name, about: about, folder: home) }
        if repo.isEmpty { repo = Self.gitHubRepo(folder: folder) ?? "" }
        problem = nil
        Task { await scan(folder: folder); await loadSkills() }
    }

    /// "Set up with Hoot": Hoot's box gets a starter message with what is known so far, and it is sent; Hoot then
    /// walks the same steps by chat with its built-in project-setup skill. A message Hoot cannot take yet stays in its box.
    func setUpWithHoot() {
        let text = PROJSetup.hootStarter(name: name, folder: home, about: about, projectID: projectID)
        guard !fixture else { return }
        let chat = NativeHootChatModel.shared
        chat.draft = text
        AppModel.shared.select("hoot")
        chat.send()
    }

    // MARK: Moving between pages

    /// Why this page cannot be left with Next yet; nil when it can.
    func blocker(_ step: PROJGuideStep) -> String? {
        switch step {
        case .name:
            return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Give the project a name." : nil
        case .folders:
            guard let home, !home.isEmpty else { return "Choose the home folder, or make a new one." }
            var isDirectory: ObjCBool = false
            if !fixture, !(FileManager.default.fileExists(atPath: home, isDirectory: &isDirectory) && isDirectory.boolValue) { return "That folder is not there any more. Choose it again." }
            if let other = registry.first(where: { $0.id != projectID && $0.id != PROJProjects.independentID && $0.folders.map(PROJProjects.normalize).contains(PROJProjects.normalize(home)) }) {
                return "This folder is already the project \(other.name)."
            }
            return nil
        case .lead:
            if lead == .hire, leadHire.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give the new lead a name." }
            return nil
        default: return nil
        }
    }
    var firstBlocker: (PROJGuideStep, String)? {
        for step in [PROJGuideStep.name, .folders, .lead] { if let why = blocker(step) { return (step, why) } }
        return nil
    }
    func go(_ next: PROJGuideStep) {
        problem = nil
        if !cardEdited { card = PROJSetup.cardText(name: name, about: about, folder: home) }
        if next == .skills, !fixture { Task { await loadSkills() } }
        step = next; visited.insert(next); skipped.remove(next)
    }
    func next() {
        if let why = blocker(step) { problem = why; return }
        guard let index = PROJGuideStep.allCases.firstIndex(of: step), index + 1 < PROJGuideStep.allCases.count else { return }
        go(PROJGuideStep.allCases[index + 1])
    }
    func back() {
        guard let index = PROJGuideStep.allCases.firstIndex(of: step), index > 0 else { return }
        go(PROJGuideStep.allCases[index - 1])
    }
    func skip() {
        guard !step.required, step != .review else { return }
        let here = step
        next()
        skipped.insert(here)
    }

    /// What a page has, for the step bar and the Review page.
    func isSet(_ step: PROJGuideStep) -> Bool {
        switch step {
        case .name: return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .folders: return home != nil
        case .lead: return lead != .unset
        case .team: return !existingTeam.isEmpty || seats.contains { $0.existing != nil || !seatAgentName($0).isEmpty } || found.contains { $0.selected && !$0.alreadyImported }
        case .skills: return skills.contains { !$0.agents.isEmpty }
        case .card: return !skipped.contains(.card) && PROJSetup.cardIsFilled(card) && (visited.contains(.card) || PROJSetup.cardIsFilled(savedCard))
        case .connections: return !repo.isEmpty || !taskSystem.isEmpty || !servers.isEmpty
        case .review: return false
        }
    }
    func summary(_ step: PROJGuideStep) -> String {
        switch step {
        case .name: return about.isEmpty ? name : name + " · " + about
        case .folders: return ([home].compactMap { $0 } + extraFolders).map(PROJPAGEStyle.shortPath).joined(separator: ", ")
        case .lead:
            switch lead {
            case .unset: return "No lead"
            case .keep: return currentLeadName.isEmpty ? currentLead : currentLeadName
            case .hire: return "New agent: " + (leadHire.name.isEmpty ? "unnamed" : leadHire.name)
            case .existing(let id): return agentName(id)
            case .hoot: return "Hoot leads for now"
            }
        case .team:
            let names = teamAgents.map(\.name)
            return names.isEmpty ? "No agents" : names.joined(separator: ", ")
        case .skills:
            let given = skills.filter { !$0.agents.isEmpty }.map(\.name)
            return given.isEmpty ? "No skills given" : given.joined(separator: ", ")
        case .card: return isSet(.card) ? "Goals, rules and key facts" : "Empty"
        case .connections:
            return [repo.isEmpty ? nil : repo, taskSystem.isEmpty ? nil : ConnectedTasksStore.shared.systems.first { $0.id == taskSystem }?.name ?? taskSystem,
                    servers.isEmpty ? nil : "\(servers.count) server\(servers.count == 1 ? "" : "s")"].compactMap { $0 }.joined(separator: " · ")
        case .review: return ""
        }
    }
    /// The plan key of the lead, when the lead is an agent.
    var leadKey: String? {
        switch lead {
        case .hire: return "lead"
        case .existing(let id): return "agent:" + id
        case .keep where currentLead.hasPrefix("agent:"): return "agent:" + currentLead.dropFirst(6)
        default: return nil
        }
    }
    /// The plan's agents other than the lead.
    var teamAgents: [PlanAgent] { planAgents.filter { $0.key != leadKey } }
    /// The score the project will have once this is saved.
    var expectedScore: PROJSetupScore {
        let leadRaw: String
        switch lead {
        case .keep: leadRaw = currentLead
        case .hire: leadRaw = "agent:new"
        case .existing(let id): leadRaw = "agent:" + id
        default: leadRaw = ""
        }
        let withSkills = Set(skills.flatMap(\.agents)).count
        let hasLogo = logoFile != nil || (!existingLogo.isEmpty && !removeLogo)
        return PROJSetup.score(.init(about: about, logo: hasLogo ? "logo" : "", lead: leadRaw, hootLeads: lead == .hoot,
                                     teamAgents: teamAgents.count, agentsWithSkills: withSkills, cardText: isSet(.card) ? card : savedCard))
    }

    // MARK: Create / Save

    /// Creates (or, for an existing project, saves) everything chosen. A step that fails is said in `notes`;
    /// once the project itself is saved, the guide switches to editing it, so trying again never makes a second one.
    func apply() async -> String? {
        if let blocked = firstBlocker { step = blocked.0; visited.insert(blocked.0); problem = blocked.1; return nil }
        guard !busy else { return nil }
        busy = true; problem = nil; notes = []
        defer { busy = false }
        guard !fixture else { return projectID ?? PROJSetup.projectID(for: name, taken: Set(registry.map(\.id))) }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = projectID ?? PROJSetup.projectID(for: cleanName, taken: Set(registry.map(\.id)))
        let home = PROJProjects.normalize(self.home ?? "")
        let folders = [home] + extraFolders.map(PROJProjects.normalize).filter { $0 != home }

        // 1-2. The project itself (registry), its logo, and its folders opened (the folders tools may touch).
        var project = original ?? PROJProject(id: id, name: cleanName, folders: folders, colour: colour)
        project.name = cleanName; project.folders = folders
        if !colour.isEmpty { project.colour = colour }
        var replacedLogo: String?
        if let logoFile {
            do { let made = try ProjectLogos.adopt(logoFile, projectID: id); replacedLogo = project.logo; project.logo = made }
            catch { notes.append("The logo could not be used: " + error.localizedDescription) }
        } else if removeLogo, !project.logo.isEmpty { replacedLogo = project.logo; project.logo = "" }
        if project != original {
            do { _ = try await EngineBridge.shared.invoke("project-registry:save", [project.wireValue.foundation]) }
            catch { problem = "The project was not saved. " + error.localizedDescription; return nil }
            if let replacedLogo, !replacedLogo.isEmpty, replacedLogo != project.logo { ProjectLogos.discard(replacedLogo) }
        }
        let wasCreating = creating
        mode = .edit(id); original = project
        for folder in folders where !(AppModel.shared.sidebar?.projects.contains { $0.id == folder } ?? false) {
            do { _ = try await EngineBridge.shared.invoke("projects:add", [folder]) }
            catch { notes.append("The folder \(PROJPAGEStyle.shortPath(folder)) could not be opened: " + error.localizedDescription) }
        }
        SIDEBARProjectStore.shared.refresh()

        // Project settings: the line on what it is, "Hoot leads for now", and the connections.
        var values: [String: Any] = [:]
        func put(_ key: String, _ value: String) {
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean != (savedSettings[key].string ?? "") { values[key] = clean.isEmpty ? NSNull() : clean }
        }
        put(PROJSetup.aboutKey, about)
        put(PROJSetup.repoKey, repo)
        put(PROJSetup.taskSystemKey, taskSystem)
        put(PROJSetup.serversKey, servers.sorted().joined(separator: ","))
        let hoot = lead == .hoot
        if hoot != (savedSettings[PROJSetup.hootLeadsKey].bool == true) {
            if hoot { values[PROJSetup.hootLeadsKey] = true } else { values[PROJSetup.hootLeadsKey] = NSNull() }
        }
        if !values.isEmpty {
            do { _ = try await EngineBridge.shared.invoke("project-settings:set", [["projectId": id, "values": values]]) }
            catch { notes.append("The project's line and connections were not saved: " + error.localizedDescription) }
        }
        // SETTINGS-TRUTH (12 Oct): "What it is" really reaches the agents and Hoot: it goes into the project's own
        // memory card, which every lead and agent seat of the project gets at the top of each clean desk, and Hoot's
        // desk lists each project's line.
        if values[PROJSetup.aboutKey] != nil {
            let line = about.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                let memory = await DeckMemory.ready()
                let card = try await memory.card(.project(id))
                let next = DeckMemoryCard.replacingSection(DeckMemoryCard.projectAboutHeading, with: line, in: card.text)
                if next != card.text { _ = try await memory.saveCard(.project(id), text: next) }
            } catch { notes.append("The project's line did not reach its memory card: " + error.localizedDescription) }
        }

        // 3. Lead.
        var ids: [String: String] = [:]   // plan key → saved agent id
        switch lead {
        case .hire:
            if let made = await hire(leadHire, project: project, home: home, seat: nil) {
                ids["lead"] = made
                await setLead(made, name: leadHire.name, project: project)
            }
        case .existing(let agentID):
            if let profile = profiles.first(where: { $0.id == agentID }), profile.projectID != id { await move(profile, to: id, seat: profile.seat) }
            await setLead(agentID, name: agentName(agentID), project: project)
        case .hoot where !currentLead.isEmpty, .unset where !currentLead.isEmpty && !wasCreating:
            await clearLead(project)
        default: break
        }

        // 4. Team: roles with their agents, and agent files from the folder.
        for seat in seats {
            let title = seat.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let role = AGTSeats.slug(title)
            if let existing = seat.existing, let profile = profiles.first(where: { $0.id == existing }) {
                await move(profile, to: id, seat: role.isEmpty ? profile.seat : role)
                await ensureSeat(AGTSeats.roleSeat(agentID: existing, seat: role.isEmpty ? profile.seat : role, projectID: id), title: title.isEmpty ? profile.name : title)
            } else if !seatAgentName(seat).isEmpty {
                var agent = seat.agent
                if agent.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { agent.name = title }
                if agent.role.isEmpty { agent.role = title }
                if let made = await hire(agent, project: project, home: home, seat: role.isEmpty ? nil : role) {
                    ids[seat.key] = made
                    await ensureSeat(AGTSeats.roleSeat(agentID: made, seat: role.isEmpty ? nil : role, projectID: id), title: title.isEmpty ? agent.name : title)
                }
            }
        }
        let chosen = found.filter { $0.selected && !$0.alreadyImported }
        if !chosen.isEmpty {
            let batches = Dictionary(grouping: chosen, by: \.folder).map { folder, rows in
                ["folder": folder, "projectId": id, "selectedFiles": rows.map(\.file)] as [String: Any]
            }
            let result = await TasksStore.shared.call("tasks:agents-import", [["batches": batches]])
            TasksStore.shared.adopt(result)
            if result.ok {
                for row in chosen {
                    if let saved = TasksStore.shared.state?.agents.first(where: { $0.sourceFile.map(PROJProjects.normalize) == PROJProjects.normalize(row.file) }) {
                        ids["import:" + row.file] = saved.id
                    }
                }
                for index in found.indices where chosen.contains(where: { $0.file == found[index].file }) {
                    found[index] = .init(file: found[index].file, folder: found[index].folder, name: found[index].name, alreadyImported: true, selected: false)
                }
            } else { notes.append("The agent files were not imported: " + (result.message ?? "the import was refused.")) }
        }

        // 5. Skills: give each skill to the agents chosen for it (and take it back where unticked).
        for skill in skills {
            let give = skill.agents.subtracting(skill.original).compactMap { savedID($0, ids) }
            let take = skill.original.subtracting(skill.agents).compactMap { savedID($0, ids) }
            for (channel, agents) in [("skills:assign", give), ("skills:unassign", take)] where !agents.isEmpty {
                var ok = await skillCall(channel, skill: skill.id, agents: agents)
                if !ok { ok = await skillCall(channel, skill: skill.name, agents: agents) }
                if !ok { notes.append("The skill \(skill.name) was not " + (channel == "skills:assign" ? "given." : "taken back.")) }
            }
        }

        // 6. Project card: the lead seat's own card.
        if isSet(.card), card != savedCard {
            do {
                _ = try await DeckMemory.store.ensureOwner(.lead(id), name: "Lead of " + cleanName)
                _ = try await DeckMemory.store.saveCard(.lead(id), text: card)
                savedCard = card
            } catch { notes.append("The project card was not saved: " + error.localizedDescription) }
        }

        TasksStore.shared.reload()
        await AGTSeatsStore.shared.refresh()
        NotificationCenter.default.post(name: .projSetupChanged, object: id)
        seats = []
        await loadSkills()
        return id
    }

    private func savedID(_ key: String, _ ids: [String: String]) -> String? {
        if key.hasPrefix("agent:") { return String(key.dropFirst(6)) }
        return ids[key]
    }
    private func skillCall(_ channel: String, skill: String, agents: [String]) async -> Bool {
        guard let raw = try? await EngineBridge.shared.invoke(channel, [["skill": skill, "agentIds": agents]]),
              let value = try? NativeRPCValue.fromFoundation(raw) else { return false }
        return value["ok"].bool == true
    }

    /// The New agent screen's save: the same form rules (AgentForm.payload) and the same call.
    private func hire(_ agent: NewAgent, project: PROJProject, home: String, seat: String?) async -> String? {
        var draft = AgentDraft(nil)
        draft.name = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.role = agent.role
        draft.provider = agent.provider
        draft.icon = agent.icon?.raw
        draft.projectID = project.id
        draft.defaultProject = home
        draft.seat = seat
        switch AgentForm.payload(draft, agents: TasksStore.shared.state?.agents ?? profiles) {
        case .failure(let refusal):
            notes.append("\(draft.name) was not made: " + refusal.message); return nil
        case .success(let profile):
            var payload = profile.wire
            if let seat { payload["seat"] = seat }
            let result = await TasksStore.shared.call("tasks:agent-save", [payload])
            TasksStore.shared.adopt(result)
            guard result.ok else { notes.append("\(draft.name) was not made: " + (result.message ?? "the save was refused.")); return nil }
            return profile.id
        }
    }
    /// Puts a saved agent into this project (and a role), the way its own settings would.
    private func move(_ profile: AgentProfile, to projectID: String, seat: String?) async {
        var next = profile
        next.projectID = projectID; next.hasExplicitProjectID = true; next.seat = seat
        guard next != profile else { return }
        if !(await store.save(next)) { notes.append("\(profile.name) could not join the project: " + (store.message ?? "the save was refused.")) }
    }
    private func setLead(_ agentID: String, name: String, project: PROJProject) async {
        do {
            _ = try await EngineBridge.shared.invoke("project-registry:set-lead", [["projectId": project.id, "lead": "agent:" + agentID, "leadName": name] as [String: Any]])
            _ = try? await DeckMemory.store.ensureOwner(.lead(project.id), name: "Lead of " + project.name)
            currentLead = "agent:" + agentID; currentLeadName = name; lead = .keep
        } catch { notes.append("The lead was not saved: " + error.localizedDescription) }
    }
    private func clearLead(_ project: PROJProject) async {
        do {
            _ = try await EngineBridge.shared.invoke("project-registry:set-lead", [["projectId": project.id, "lead": NSNull(), "leadName": ""] as [String: Any]])
            currentLead = ""; currentLeadName = ""
        } catch { notes.append("The old lead was not removed: " + error.localizedDescription) }
    }
    private func ensureSeat(_ seat: AGTSeat, title: String) async {
        _ = try? await DeckMemory.store.ensureOwner(seat.owner, name: title)
    }
}

extension Notification.Name {
    /// A project's setup changed through the guide (object: the project id).
    static let projSetupChanged = Notification.Name("dev.terminaldeck.project-setup.changed")
}
