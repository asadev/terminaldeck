import AppKit
import SwiftUI
import Observation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Deck Memory on the Agents side (MEMORY-SPEC §3a): three categories (Orchestrator, Lead, Agent)
/// and seats. Memory belongs to the seat; an agent is hired into one. This file answers, for the
/// screens: which seat an agent sits in, who leads a project, which seats are vacant but still
/// hold memory, and the Hoot → leads → agents tree. Rules are in Core (`AGTSeats`).
@MainActor enum AGTLeads {
    static var projects: [PROJProject] { NativePROJLabels.shared.projects }
    private static var store: AGTAgentsStore { .shared }
    static var placeholderPrefix: String { AGTDirectory.leadPlaceholderPrefix }
    static var vacantPrefix: String { AGTDirectory.vacantSeatPrefix }
    /// Set by "Hire into this seat…"; the New agent page takes it once.
    static var pendingHire: AGTSeat?

    static func projectID(_ agent: AGTAgent) -> String {
        PROJProjects.resolve(projectID: agent.projectID, folder: agent.project, projects: projects)
    }
    /// The project's name as the person registered it ("Memory Test"), "Every project" for Hoot, else "Independent".
    static func projectName(_ agent: AGTAgent?) -> String {
        guard let agent else { return "Independent" }
        if agent.isHoot { return "Every project" }
        let id = projectID(agent)
        if id == PROJProjects.independentID { return "Independent" }
        return projects.first { $0.id == id }?.name ?? AGTDirectory.projectName(agent.project)
    }
    static func project(_ agent: AGTAgent) -> PROJProject? {
        let id = projectID(agent)
        return projects.first { $0.id == id }
    }
    /// The id a session lead is saved under.
    static func sessionID(_ agent: AGTAgent) -> String {
        agent.sessionID ?? (agent.id.hasPrefix(AGTDirectory.sessionPrefix) ? String(agent.id.dropFirst(AGTDirectory.sessionPrefix.count)) : agent.id)
    }
    static func isVacant(_ agent: AGTAgent) -> Bool { agent.id.hasPrefix(vacantPrefix) }
    static func vacantSeat(_ agent: AGTAgent) -> AGTSeat? {
        isVacant(agent) ? AGTSeat(key: String(agent.id.dropFirst(vacantPrefix.count))) : nil
    }

    /// The project this agent or session leads, if any: the one it was made the lead of, else the one whose
    /// lead it works as (a session opened in that project's folder with no agent picked).
    static func ledProject(_ agent: AGTAgent) -> PROJProject? { madeLead(agent) ?? worksAsLead(agent) }
    /// The project this agent or session was MADE the lead of (named on the project).
    static func madeLead(_ agent: AGTAgent) -> PROJProject? {
        if agent.isHoot || isVacant(agent) { return nil }
        if agent.id.hasPrefix(placeholderPrefix) {
            let id = String(agent.id.dropFirst(placeholderPrefix.count))
            return projects.first { $0.id == id && AGTSeats.lead(of: $0) != nil }
        }
        if let profile = agent.profileID { return AGTSeats.ledProject(agentID: profile, projects: projects) }
        guard agent.kind == .session, !agent.id.hasPrefix(AGTDirectory.handPrefix) else { return nil }
        if let exact = AGTSeats.ledProject(sessionID: sessionID(agent), sessionName: nil, sessionProjectID: nil, projects: projects) { return exact }
        if let exact = AGTSeats.ledProject(sessionID: String(agent.id.dropFirst(AGTDirectory.sessionPrefix.count)), sessionName: nil, sessionProjectID: nil, projects: projects) { return exact }
        return AGTSeats.ledProject(sessionID: "", sessionName: agent.sessionTitle ?? agent.name, sessionProjectID: projectID(agent), projects: projects)
    }
    /// The project whose lead this session WORKS AS: the app seated it in that lead's seat (it was opened in the
    /// project's folder with no agent picked, or started as the lead agent), without it being made the lead
    /// itself. What the session holds is the app's own answer (its hand on the seat), never guessed here.
    static func worksAsLead(_ agent: AGTAgent) -> PROJProject? {
        guard agent.kind == .session, !agent.isHoot, !isVacant(agent), !agent.id.hasPrefix(placeholderPrefix),
              !agent.id.hasPrefix(AGTDirectory.handPrefix), let key = agent.sitsIn,
              case .lead(let id)? = AGTSeat(key: key), madeLead(agent) == nil else { return nil }
        return projects.first { $0.id == id && AGTSeats.lead(of: $0) != nil }
    }
    static func isLead(_ agent: AGTAgent) -> Bool { ledProject(agent) != nil }

    /// Orchestrator, Lead or Agent. There is no fourth.
    static func category(_ agent: AGTAgent) -> AGTCategory {
        if agent.isHoot { return .orchestrator }
        if let seat = vacantSeat(agent) { return seat.category }
        return isLead(agent) ? .lead : .agent
    }
    /// The seat an agent sits in (nil for a plain session that is nobody's hire).
    static func seat(_ agent: AGTAgent) -> AGTSeat? {
        if agent.isHoot { return .orchestrator }
        if let seat = vacantSeat(agent) { return seat }
        if let project = ledProject(agent) { return .lead(projectID: project.id) }
        guard let profile = agent.profileID else {
            // A session started as a saved agent sits in that agent's role (the app's own answer, its hand on the seat).
            guard agent.kind == .session, let key = agent.sitsIn, let seat = AGTSeat(key: key), case .role = seat else { return nil }
            return seat
        }
        return AGTSeats.roleSeat(agentID: profile, seat: agent.seat, projectID: projectID(agent))
    }
    /// The role seat a saved agent holds (it keeps it while it leads).
    static func roleSeat(_ agent: AGTAgent) -> AGTSeat? {
        agent.profileID.map { AGTSeats.roleSeat(agentID: $0, seat: agent.seat, projectID: projectID(agent)) }
    }
    /// Where this agent's memory lives: its seat, in M1's spelling.
    static func owner(_ agent: AGTAgent) -> DeckMemoryOwner? { seat(agent)?.owner }

    /// "iOS engineer on iMatch", "Lead of CRM", "Orchestrator".
    static func seatTitle(_ seat: AGTSeat) -> String {
        switch seat {
        case .orchestrator: return "Orchestrator"
        case .lead(let project): return "Lead of " + NativePROJLabels.shared.name(for: project)
        case .role(let project, let role):
            let title = AGTSeatsStore.shared.title(for: seat) ?? AGTSeats.title(forRole: role)
            // A seat title saved with its project already in it is not given the project twice.
            return project.map { let suffix = " on " + NativePROJLabels.shared.name(for: $0); return title.hasSuffix(suffix) ? title : title + suffix } ?? title
        }
    }

    /// The agent (or running session) that leads a project; a quiet row when the lead session
    /// is not running, so the tree still shows who leads.
    static func leadAgent(of project: PROJProject, in agents: [AGTAgent]) -> AGTAgent? {
        guard let lead = AGTSeats.lead(of: project) else { return nil }
        if lead.kind == .agent {
            return agents.first { $0.profileID == lead.id && $0.status != "archived" }
        }
        // The very session made lead first; else one that works as the lead in its folder.
        if let running = agents.first(where: { $0.kind == .session && !isVacant($0) && madeLead($0)?.id == project.id }) { return running }
        if let working = agents.first(where: { worksAsLead($0)?.id == project.id }) { return working }
        return AGTDirectory.leadPlaceholder(project: project, lead: lead)
    }

    /// Seats that still hold memory and have nobody in them, as quiet rows.
    static func vacantRows(_ agents: [AGTAgent]) -> [AGTAgent] {
        let taken = Set(agents.filter { $0.kind == .profile && $0.status != "archived" }.compactMap { roleSeat($0)?.key })
        return AGTSeatsStore.shared.withMemory.compactMap { info -> AGTAgent? in
            guard let seat = AGTSeat(owner: info.owner) else { return nil }
            switch seat {
            case .orchestrator: return nil
            case .lead(let id):
                guard let project = projects.first(where: { $0.id == id }), AGTSeats.lead(of: project) == nil else { return nil }
                return AGTDirectory.vacantSeat(seat, title: "Lead of " + project.name, project: project)
            case .role(let id, let role):
                guard !taken.contains(seat.key) else { return nil }
                return AGTDirectory.vacantSeat(seat, title: info.name.isEmpty ? AGTSeats.title(forRole: role) : info.name,
                                               project: id.flatMap { id in projects.first { $0.id == id } })
            }
        }
    }

    /// The rows the org chart draws: every agent, a row for a lead that is not running, and
    /// a row for every vacant seat that still holds memory.
    static func orgAgents(_ agents: [AGTAgent]) -> [AGTAgent] {
        var rows = agents
        for project in projects {
            guard let lead = leadAgent(of: project, in: agents), !rows.contains(where: { $0.id == lead.id }) else { continue }
            rows.append(lead)
        }
        for vacant in vacantRows(agents) where !rows.contains(where: { $0.id == vacant.id }) { rows.append(vacant) }
        return rows
    }
    /// Who a row hangs under: a lead (or a vacant lead seat) under Hoot; an explicit manager
    /// wins; otherwise its project's lead; otherwise nobody (Hoot assigns it directly).
    static func manager(of agent: AGTAgent, in agents: [AGTAgent]) -> String? {
        if agent.isHoot { return nil }
        if let seat = vacantSeat(agent) {
            guard case .role(let id, _) = seat, let id, let project = projects.first(where: { $0.id == id }),
                  let lead = leadAgent(of: project, in: agents) else { return AGTDirectory.hootID }
            return lead.id
        }
        // A session that works as the lead hangs under the lead it works as (one seat, several hands).
        if let project = worksAsLead(agent), let lead = leadAgent(of: project, in: agents), lead.id != agent.id { return lead.id }
        if isLead(agent) { return AGTDirectory.hootID }
        if let boss = agent.reportsTo, !boss.isEmpty { return boss }
        guard agent.kind == .profile, let project = project(agent), let lead = leadAgent(of: project, in: agents), lead.id != agent.id else { return nil }
        return lead.id
    }

    // MARK: Saves

    /// Put this agent or session in a project's lead seat, or empty the seat (`nil`).
    @discardableResult
    static func setLead(_ agent: AGTAgent?, of project: PROJProject) async -> Bool {
        let raw: String?, name: String?
        if let agent {
            raw = agent.profileID.map { "agent:" + $0 } ?? "session:" + sessionID(agent)
            name = agent.name
        } else { raw = nil; name = nil }
        guard store.fixture == nil else {
            let labels = NativePROJLabels.shared
            for index in labels.projects.indices {
                if let raw, labels.projects[index].lead == raw, labels.projects[index].id != project.id { labels.projects[index].lead = ""; labels.projects[index].leadName = "" }
                if labels.projects[index].id == project.id { labels.projects[index].lead = raw ?? ""; labels.projects[index].leadName = name ?? "" }
            }
            return true
        }
        do {
            _ = try await EngineBridge.shared.invoke("project-registry:set-lead",
                [["projectId": project.id, "lead": raw.map { $0 as Any } ?? NSNull(), "leadName": name ?? ""] as [String: Any]])
            store.message = nil
            // The lead seat's folder (card, playbook) exists from the moment it is filled.
            if agent != nil { _ = try? await DeckMemory.store.ensureOwner(.lead(project.id), name: "Lead of " + project.name) }
            return true
        } catch {
            store.message = "The lead was not saved. " + error.localizedDescription
            return false
        }
    }
    /// "Make Commander the lead": the project's folder says who its AI is (its CLAUDE.md: "You are **Commander**"),
    /// so that name becomes the project's lead: the saved agent with that name in this project, else a new agent
    /// saved for it (on the AI whose file said so, the project's home folder as its folder). Then every session the
    /// person opens in the project without picking an agent works as that lead, with the lead seat's memory.
    @discardableResult
    static func makeDeclaredLead(_ declared: AGTDeclaredLead.Found, of project: PROJProject) async -> Bool {
        let name = declared.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, project.id != PROJProjects.independentID else { return false }
        let profiles = store.profiles.filter { $0.status != .archived }
        let agent: AGTAgent
        if let existing = profiles.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
           let row = store.agent(existing.id) {
            guard projectID(row) == project.id else {
                store.message = "There is already an agent called \(existing.name) in \(projectName(row)). Move it to \(project.name), or rename one of them, then make it the lead."
                return false
            }
            agent = row
        } else {
            var draft = AgentDraft(nil)
            draft.name = name
            draft.role = "Lead of " + project.name
            draft.provider = declared.provider
            draft.projectID = project.id
            draft.defaultProject = project.folders.first ?? ""
            switch AgentForm.payload(draft, agents: store.profiles) {
            case .failure(let refusal): store.message = "\(name) was not saved: " + refusal.message; return false
            case .success(let profile):
                guard await store.save(profile) else { return false }
                guard let saved = store.agent(profile.id)
                        ?? AGTDirectory.build(profiles: [AGTProfileInput(profile)], live: [], tasks: []).first(where: { $0.profileID == profile.id }) else { return false }
                agent = saved
            }
        }
        return await setLead(agent, of: project)
    }

    /// Why this agent cannot lead; nil when it can.
    static func leadRefusal(_ agent: AGTAgent) -> String? {
        if agent.isHoot { return "Hoot is the orchestrator." }
        return projectID(agent) == PROJProjects.independentID ? "Give it a project first. A lead leads one project." : nil
    }

    /// Move a saved agent into a role seat of its project (`nil` = the seat named after it).
    /// Memory does not move: it stays with the seat the agent leaves.
    @discardableResult
    static func setRole(_ role: String?, title: String?, for agent: AGTAgent) async -> Bool {
        guard var profile = store.profile(agent) else { store.message = "Save this agent first to give it a role."; return false }
        if let role, !AGTSeats.isValidRole(role) { store.message = AGTSeats.roleProblem(role); return false }
        guard profile.seat != role else { return true }
        profile.seat = role
        guard await store.save(profile) else { return false }
        if store.fixture == nil {
            let seat = AGTSeats.roleSeat(agentID: profile.id, seat: role, projectID: projectID(agent))
            _ = try? await DeckMemory.store.ensureOwner(seat.owner, name: title ?? AGTSeatsStore.shared.title(for: seat) ?? AGTSeats.title(forRole: seat.role ?? profile.id))
            await AGTSeatsStore.shared.refresh()
        }
        return true
    }
}

/// One seat and who fills it: the read-only row for any list outside the Agents page (the @
/// picker, Hoot's profile). `AGTLeads.roster()` builds them; it reads only observable stores.
struct AGTSeatRow: Identifiable {
    let seat: AGTSeat
    /// "iOS engineer", "Lead of CRM", "Orchestrator".
    let title: String
    let project: PROJProject?
    /// The agents (or the lead session) in the seat now. Empty = vacant.
    let filledBy: [AGTAgent]
    /// Sessions working in the seat right now (0 or 1 is the usual; 3 shows as "×3").
    let hands: Int
    /// "12 notes · 2 topics" when the seat holds memory.
    let memory: String?
    var id: String { seat.key }
    var isVacant: Bool { filledBy.isEmpty }
    /// A vacant seat that still holds memory: offered greyed as "Vacant, has memory".
    var isVacantWithMemory: Bool { filledBy.isEmpty && memory != nil }
}

extension AGTLeads {
    /// Call once when a list that shows seats opens. Safe to call again and again from anywhere on
    /// the main actor: each store starts once, listens to pushes and never polls.
    static func startSeatReads() {
        AGTAgentsStore.shared.start(); NativePROJLabels.shared.start()
        if AGTAgentsStore.shared.fixture == nil { AGTSeatsStore.shared.start(); AGTHandsStore.shared.start() }
    }

    /// Every seat with who fills it: Hoot's, each project's lead seat (filled, or vacant with
    /// memory), every role an agent holds, and every vacant role that still holds memory.
    /// Reads observable stores only, so a SwiftUI view that calls it redraws when anything changes.
    static func roster() -> [AGTSeatRow] {
        let agents = AGTAgentsStore.shared.agents.filter { $0.status != "archived" }
        let seats = AGTSeatsStore.shared, hands = AGTHandsStore.shared
        var rows: [AGTSeatRow] = []
        if let hoot = agents.first(where: \.isHoot) {
            rows.append(.init(seat: .orchestrator, title: "Orchestrator", project: nil, filledBy: [hoot], hands: 1, memory: seats.summary(for: .orchestrator)))
        }
        for project in projects where project.id != PROJProjects.independentID {
            let seat = AGTSeat.lead(projectID: project.id)
            let lead = leadAgent(of: project, in: agents)
            guard lead != nil || seats.summary(for: seat) != nil else { continue }
            rows.append(.init(seat: seat, title: "Lead of " + project.name, project: project, filledBy: lead.map { [$0] } ?? [],
                              hands: hands.hands(on: seat.owner).count, memory: seats.summary(for: seat)))
        }
        var byRole: [String: (seat: AGTSeat, agents: [AGTAgent])] = [:]
        for agent in agents where agent.kind == .profile {
            guard let seat = roleSeat(agent) else { continue }
            byRole[seat.key, default: (seat, [])].agents.append(agent)
        }
        for info in seats.withMemory {
            guard let seat = AGTSeat(owner: info.owner), case .role = seat, byRole[seat.key] == nil else { continue }
            byRole[seat.key] = (seat, [])
        }
        for entry in byRole.values.sorted(by: { $0.seat.key < $1.seat.key }) {
            let project = entry.seat.projectID.flatMap { id in projects.first { $0.id == id } }
            rows.append(.init(seat: entry.seat, title: seats.title(for: entry.seat) ?? AGTSeats.title(forRole: entry.seat.role ?? ""), project: project,
                              filledBy: entry.agents, hands: hands.hands(on: entry.seat.owner).count, memory: seats.summary(for: entry.seat)))
        }
        return rows
    }

    /// A vacant seat was mentioned: ask its project's lead (Hoot where there is no lead) to fill it.
    /// Returns who was asked ("Commander", "Hoot"), or nil with the reason in `AGTAgentsStore.shared.message`.
    @discardableResult
    static func askToFill(_ seat: AGTSeat, note: String = "") async -> String? {
        guard let service = BackendAGTHandsService.shared else { AGTAgentsStore.shared.message = "Agents are still starting. Try again in a moment."; return nil }
        do {
            let reply = try await service.requestFill(seat: seat.owner, note: note, by: "You")
            return reply["name"].string ?? "Hoot"
        } catch { AGTAgentsStore.shared.message = "The request was not sent. " + error.localizedDescription; return nil }
    }
}

/// The seats that have a memory folder (from M1's store): what makes a deleted agent's seat
/// stay visible as "vacant, has memory". Event-driven: one read, then M1's change stream.
@MainActor @Observable final class AGTSeatsStore {
    static let shared = AGTSeatsStore()
    private(set) var infos: [DeckMemoryOwnerInfo] = []
    private(set) var loaded = false
    /// Set by offscreen fixtures instead of reading the real store.
    var fixture: [DeckMemoryOwnerInfo]?
    @ObservationIgnored private var watching: Task<Void, Never>?
    private init() {}

    private var rows: [DeckMemoryOwnerInfo] { fixture ?? infos }
    /// Seats holding something worth inheriting: notes, topics or diary (a starter card alone is not memory).
    var withMemory: [DeckMemoryOwnerInfo] { rows.filter(\.hasMemory) }
    func info(for seat: AGTSeat) -> DeckMemoryOwnerInfo? { rows.first { $0.owner == seat.owner } }
    func title(for seat: AGTSeat) -> String? { info(for: seat).flatMap { $0.name.isEmpty ? nil : $0.name } }
    /// "12 notes · 2 topics", or nil when the seat holds nothing yet.
    func summary(for seat: AGTSeat) -> String? {
        guard let info = info(for: seat), info.notes > 0 || info.topics > 0 else { return nil }
        var words: [String] = []
        if info.notes > 0 { words.append("\(info.notes) note" + (info.notes == 1 ? "" : "s")) }
        if info.topics > 0 { words.append("\(info.topics) topic" + (info.topics == 1 ? "" : "s")) }
        return words.joined(separator: " · ")
    }

    func start() {
        guard fixture == nil, watching == nil else { return }
        watching = Task { [weak self] in
            let memory = await DeckMemory.ready()
            await self?.refresh()
            for await change in memory.changes() {
                guard [.folder, .notes, .topics, .card, .index].contains(change.area) else { continue }
                await self?.refresh()
            }
        }
    }
    func refresh() async {
        guard fixture == nil else { return }
        if let rows = try? await DeckMemory.store.owners() { infos = rows; loaded = true }
    }
}

/// A small word beside a name: "Lead". Agents are the quiet default; a vacant seat says so.
struct AGTSeatBadge: View {
    let agent: AGTAgent
    var body: some View {
        if AGTLeads.isVacant(agent) {
            word("Vacant", tint: .secondary, help: "Nobody is in this seat. Its memory is kept for the next hire.")
        } else if AGTLeads.isLead(agent) {
            word("Lead", tint: DeckTokens.accent, help: AGTCategory.lead.explanation)
        }
    }
    private func word(_ text: String, tint: Color, help: String) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
            .padding(.horizontal, 6).frame(height: 18)
            .background(tint.opacity(0.12), in: Capsule())
            .help(help).accessibilityLabel(text)
    }
}

// MARK: The role's memory moves with the agent (11 Oct)

extension AGTLeads {
    /// The agent moves from `oldProject` to `newProject`. When its old role seat holds memory and nobody else sits
    /// in it, it asks "Bring this role's memory along?": Move it brings the notes and topics (each keeps its id and
    /// history, labelled where it came from) and the card into the role in the new project; the diary stays with the
    /// old seat as history. Leave it keeps everything with the old role, for whoever is hired there next.
    static func offerToMoveMemory(_ agent: AGTAgent, from oldProject: String?, to newProject: String?) {
        guard agent.kind == .profile, let profileID = agent.profileID, !isLead(agent) else { return }
        let old = AGTSeats.roleSeat(agentID: profileID, seat: agent.seat, projectID: oldProject)
        let new = AGTSeats.roleSeat(agentID: profileID, seat: agent.seat, projectID: newProject)
        guard old != new, AGTSeatsStore.shared.summary(for: old) != nil else { return }
        let others = AGTAgentsStore.shared.agents.filter { $0.kind == .profile && $0.profileID != profileID && $0.status != "archived" && roleSeat($0) == old }
        guard others.isEmpty else { return }
        let title = AGTSeatsStore.shared.title(for: old) ?? AGTSeats.title(forRole: old.role ?? "")
        let alert = NSAlert()
        alert.messageText = "Bring this role's memory along?"
        alert.informativeText = "\(title) has memory (\(AGTSeatsStore.shared.summary(for: old) ?? "notes")) in \(NativePROJLabels.shared.name(for: oldProject ?? PROJProjects.independentID)). "
            + "Move it brings its notes, topics and card to the role in \(NativePROJLabels.shared.name(for: newProject ?? PROJProjects.independentID)); the diary stays with the old role as history. "
            + "Leave it keeps everything with the old role, for whoever is hired there next."
        alert.addButton(withTitle: "Move it"); alert.addButton(withTitle: "Leave it with the old role")
        let move: () -> Void = { Task { await moveRoleMemory(from: old, to: new, title: title) } }
        if NativeFront.personActing {
            if alert.runModal() == .alertFirstButtonReturn { move() } // front-ok: the person's own project change
        } else if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { move() } }
        }
    }

    /// Moves one role seat's memory into another through the memory store: the notes and topics with their ids and
    /// history (M1's fold), and the card (added to the new seat's own card when it already has one).
    @discardableResult
    static func moveRoleMemory(from old: AGTSeat, to new: AGTSeat, title: String) async -> Bool {
        do {
            let store = DeckMemory.store
            _ = try await store.ensureOwner(new.owner, name: title, parent: nil)
            let oldCard = try await store.card(old.owner).text.trimmingCharacters(in: .whitespacesAndNewlines)
            let newCard = try await store.card(new.owner).text.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await store.foldBack(old.owner, into: new.owner)
            if !oldCard.isEmpty, oldCard != newCard {
                _ = try await store.saveCard(new.owner, text: newCard.isEmpty ? oldCard : newCard + "\n\n" + oldCard)
            }
            await AGTSeatsStore.shared.refresh()
            return true
        } catch {
            AGTAgentsStore.shared.message = "The role's memory could not be moved: " + error.localizedDescription + " It is still with the old role."
            return false
        }
    }
}

// MARK: Lead seats in Tasks (11 Oct): a lead that is a session can be given a task and @asked

extension AGTLeads {
    /// The address Tasks uses for a project's lead seat ("lead:<project id>"); the backend sends it to
    /// whoever fills the seat, so it survives a restart of the lead's session.
    static func seatAddress(_ project: PROJProject) -> String { AGTSeat.lead(projectID: project.id).key }

    /// One row per project whose lead is a SESSION, shaped like an agent so every Tasks list that offers
    /// agents (assign to, the @ list in comments, names on rows) offers the lead too. A lead that is a
    /// saved agent is already in the list as that agent.
    static func sessionLeadSeats(_ projects: [PROJProject] = projects) -> [AgentProfile] {
        projects.compactMap { project in
            guard project.id != PROJProjects.independentID, let lead = AGTSeats.lead(of: project), lead.kind == .session else { return nil }
            let name = lead.name.isEmpty ? "Lead of " + project.name : lead.name
            return AgentProfile(id: seatAddress(project), name: name, role: "Lead of " + project.name, defaultProject: project.folders.first, projectID: project.id)
        }
    }
    /// The agents Tasks offers, with each session lead's seat added after them.
    static func withLeadSeats(_ agents: [AgentProfile]) -> [AgentProfile] {
        // The project list loads once and then follows pushes; a Tasks screen may be the first to need it.
        if !AppModel.shared.isUITestFixture { NativePROJLabels.shared.start() }
        let seats = sessionLeadSeats().filter { seat in !agents.contains { $0.id == seat.id } }
        return seats.isEmpty ? agents : agents + seats
    }
    /// The project whose lead seat this address names, and whether the session that fills it runs now.
    static func sessionLead(address: String) -> (project: PROJProject, name: String, running: AGTAgent?)? {
        guard let seat = AGTSeat(key: address), case .lead(let id) = seat, let project = projects.first(where: { $0.id == id }),
              let lead = AGTSeats.lead(of: project), lead.kind == .session else { return nil }
        let running = AGTAgentsStore.shared.agents.first { $0.kind == .session && !isVacant($0) && ledProject($0)?.id == project.id }
        return (project, lead.name.isEmpty ? "Lead of " + project.name : lead.name, running)
    }
}
