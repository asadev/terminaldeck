import SwiftUI
import TerminalDeckNativeCore

/// Who Hoot orchestrates, as a compact outline: Hoot → each project's lead → its agents, with
/// vacant seats that still hold memory ("Vacant") so they can be filled.
/// Projects with no lead list their agents straight under Hoot ("Hoot assigns directly").
/// One shared view: Hoot's profile (L5) and anything else that needs the tree embeds it.
struct AGTLeadTree: View {
    /// Open an agent's or lead's page (default: the Agents page profile).
    var open: (AGTAgent) -> Void = { agent in
        AGTAgentsStore.shared.openProfile = agent.id
        AppModel.shared.select(NativeINT2Navigation.allID)
    }
    private var store: AGTAgentsStore { .shared }

    var body: some View {
        let all = AGTLeads.orgAgents(store.agents).filter { !$0.isHoot && $0.status != "archived" }
        let projects = AGTLeads.projects.filter { $0.id != PROJProjects.independentID }
        VStack(alignment: .leading, spacing: 14) {
            ForEach(projects) { project in
                let members = all.filter { AGTLeads.projectID($0) == project.id }
                let lead = AGTLeads.leadAgent(of: project, in: all)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        ProjectLogoView(project: project, name: project.name, size: 14)
                        Text(project.name).font(.system(size: 13, weight: .semibold))
                        Text(lead == nil ? "No lead: Hoot assigns its agents directly" : "Hoot gives goals to the lead")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let lead { row(lead, indent: 1) }
                    let rest = members.filter { $0.id != lead?.id && ($0.kind == .profile || AGTLeads.isLead($0) || AGTLeads.isVacant($0)) }
                    ForEach(rest) { row($0, indent: lead == nil ? 1 : 2) }
                    if lead == nil && rest.isEmpty {
                        Text("No agents yet").font(.caption).foregroundStyle(.tertiary).padding(.leading, 22)
                    }
                }
            }
            if projects.isEmpty { Text("No projects yet").font(.callout).foregroundStyle(.secondary) }
        }
        .onAppear { store.start(); NativePROJLabels.shared.start(); if store.fixture == nil { AGTSeatsStore.shared.start() } }
    }

    private func row(_ agent: AGTAgent, indent: Int) -> some View {
        Button {
            // A vacant seat that still holds memory: hiring into it is how it is opened.
            if let seat = AGTLeads.vacantSeat(agent) { AGTLeads.pendingHire = seat; AGTAgentsStore.shared.openProfile = "new"; AppModel.shared.select(NativeINT2Navigation.allID) }
            else { open(agent) }
        } label: {
            HStack(spacing: 8) {
                AgentAvatar(agent: agent, size: 22)
                Text(agent.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                AGTSeatBadge(agent: agent)
                Text(agent.statusLabel).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(indent) * 22).padding(.trailing, 8)
        }
        .buttonStyle(DeckRowStyle())
        .help("Open \(agent.name)")
    }
}
