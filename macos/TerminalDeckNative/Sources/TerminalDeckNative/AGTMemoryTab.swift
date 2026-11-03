import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Deck Memory on an agent's or lead's profile (MEMORY-SPEC §3a, §4): which seat it sits in, then
/// the ONE shared Memory area (L5 PROFILE's `NativeMemoryArea`) for that SEAT. Nothing about
/// memory is set per agent and nothing is drawn twice: this file only says whose seat it is.
struct AGTMemoryTab: View {
    let agent: AGTAgent

    var body: some View {
        let seat = AGTLeads.seat(agent)
        VStack(alignment: .leading, spacing: 12) {
            AGTSeatHeader(agent: agent)
            if let seat {
                // L5's one shared Memory area, for this SEAT. Its parts come from the category template.
                NativeMemoryArea(owner: seat.owner, name: AGTLeads.seatTitle(seat), filledBy: AGTLeads.isVacant(agent) ? nil : agent.name)
                    .frame(minWidth: 640, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity, alignment: .topLeading)
                    .id(seat.key)
            } else if let project = AGTLeads.project(agent), project.id != PROJProjects.independentID, AGTSeats.lead(of: project) == nil,
                      let declared = AGTDeclaredLeads.shared.declared(project) {
                // The project's folder already says who its AI is: offer that name as the lead, not a second guess.
                DeckEmpty(title: "\(project.name) has no lead yet",
                          message: "Its \(declared.file) says its AI is \(declared.name). Make \(declared.name) the lead, and every session you open in \(project.name) without picking an agent works as \(declared.name), with the lead's memory. Until then this session keeps no memory of its own; its work is still in the shared diary.",
                          symbol: "person.crop.circle.badge.questionmark")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DeckEmpty(title: "This session is nobody's hire",
                          message: "Its work is still in the shared diary. Make it the lead of its project, or save it as an agent, and it gets a seat with memory.",
                          symbol: "tray")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, DeckTokens.Metrics.pageHorizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: seat?.key) {
            if seat == nil, AGTAgentsStore.shared.fixture == nil { await AGTDeclaredLeads.shared.refresh(AGTLeads.projects) }
            // The seat's folder exists as soon as its page is opened: there is no memory setup step.
            guard let seat, AGTAgentsStore.shared.fixture == nil else { return }
            _ = try? await DeckMemory.store.ensureOwner(seat.owner, name: AGTLeads.seatTitle(seat))
            AGTSeatsStore.shared.start()
        }
    }
}

/// Whose seat this is, in one card: the category, the seat, and that the memory stays with the
/// seat. A lead can be changed here; nothing else is set per agent.
struct AGTSeatHeader: View {
    let agent: AGTAgent
    @State private var busy = false

    var body: some View {
        let category = AGTLeads.category(agent)
        let seat = AGTLeads.seat(agent)
        DeckCard {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(category.title).font(.system(size: 13, weight: .semibold))
                        if let seat { Text(AGTLeads.seatTitle(seat)).font(.system(size: 13)).foregroundStyle(.secondary) }
                    }
                    Text(line(category, seat: seat)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                // A lead that worked before Deck Memory brings its old memory folders in here (L5's control, M1's copy-only import).
                if case .lead(let project)? = seat, AGTAgentsStore.shared.fixture == nil {
                    NativeMemoryImportButton(owner: .lead(project))
                        .help("Copy an existing Claude Code or Codex memory folder into this lead seat's notes. The original is not changed.")
                }
                if !agent.isHoot, !AGTLeads.isVacant(agent) { leadButton }
                if busy { ProgressView().controlSize(.small) }
            }
        }
    }

    private func line(_ category: AGTCategory, seat: AGTSeat?) -> String {
        guard seat != nil else { return "A session with no seat keeps no memory of its own." }
        if let project = AGTLeads.worksAsLead(agent) {
            let lead = AGTSeats.lead(of: project)?.name ?? "the lead"
            return "This session works as \(lead), the lead of \(project.name): it was opened in \(project.name) without picking another agent. "
                + "The memory belongs to the lead seat; whoever leads \(project.name) next inherits all of it."
        }
        switch category {
        case .orchestrator: return "Hoot's memory. Every Orchestrator setting comes from the Orchestrator template."
        case .lead: return "This memory belongs to the lead seat, not to \(agent.name). Whoever leads this project next inherits all of it. What a lead gets comes from the Lead template."
        case .agent: return "This memory belongs to the role, not to \(agent.name). Delete \(agent.name) and hire someone new into this role, on any AI, and they inherit all of it. What an agent gets comes from the Agent template."
        }
    }

    @ViewBuilder private var leadButton: some View {
        if let project = AGTLeads.worksAsLead(agent) {
            // It sits in the lead's seat because of where it was opened; who leads is changed on the lead itself.
            if let lead = AGTLeads.leadAgent(of: project, in: AGTAgentsStore.shared.agents), lead.id != agent.id, lead.kind == .profile {
                Button("Open \(lead.name)") { AGTAgentsStore.shared.openProfile = lead.id }
                    .help("The lead of \(project.name). Change who leads \(project.name) there.")
            }
        } else if let led = AGTLeads.ledProject(agent) {
            Button("Stop leading \(led.name)") { run { await AGTLeads.setLead(nil, of: led) } }
                .help("\(agent.name) leaves the lead seat. The seat keeps its memory.")
                .disabled(busy)
        } else if let project = AGTLeads.project(agent), project.id != PROJProjects.independentID, AGTSeats.lead(of: project) == nil,
                  agent.kind == .session, let declared = AGTDeclaredLeads.shared.declared(project) {
            Button("Make \(declared.name) the lead of \(project.name)") {
                AgentMenu.confirmChange(title: "Make \(declared.name) the lead of \(project.name)?",
                    detail: AGTDeclaredLeads.confirmDetail(declared, project: project), button: "Make lead") {
                    run { await AGTLeads.makeDeclaredLead(declared, of: project) }
                }
            }
            .buttonStyle(.borderedProminent)
            .help("\(project.name)'s \(declared.file) says its AI is \(declared.name).")
            .disabled(busy)
        } else if let project = AGTLeads.project(agent), project.id != PROJProjects.independentID {
            let current = AGTSeats.lead(of: project)
            Button(current == nil ? "Make it the lead of \(project.name)" : "Make it the lead instead of \(current!.name)") {
                AgentMenu.confirmChange(title: "Make \(agent.name) the lead of \(project.name)?",
                    detail: (current.map { "\($0.name) leads \(project.name) now and will stop leading. " } ?? "")
                        + "Hoot gives \(agent.name) goals for \(project.name); it runs that project's agents. It takes over the lead seat's memory.",
                    button: "Make lead") { run { await AGTLeads.setLead(agent, of: project) } }
            }
            .help("A project has one lead. Hoot gives the lead goals; with no lead Hoot assigns agents directly.")
            .disabled(busy)
        }
    }
    private func run(_ work: @escaping () async -> Bool) {
        busy = true
        Task { _ = await work(); busy = false }
    }
}
