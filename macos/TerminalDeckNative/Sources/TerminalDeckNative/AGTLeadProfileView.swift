import SwiftUI
import TerminalDeckNativeCore

/// A session's page on Agents. Leads are usually sessions the person started himself (Commander,
/// Alex), with no agent profile, so this is where a session lead's seat and memory show:
/// the lead seat of its project and the shared Memory area for that seat.
struct AGTLeadProfileView: View {
    let agent: AGTAgent
    private var store: AGTAgentsStore { .shared }

    var body: some View {
        DeckPage(title: agent.name, subtitle: subtitle, scrolls: false) {
            HStack(spacing: 10) {
                Button { store.openProfile = nil } label: {
                    HStack(spacing: 3) { Image(systemName: "chevron.left"); Text("Agents") }
                        .font(.callout).foregroundStyle(.secondary).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Back to Agents").keyboardShortcut("[", modifiers: .command)
                AgentAvatar(agent: agent, size: 38)
            }
        } switcher: {
            EmptyView()
        } actions: {
            HStack(spacing: 8) {
                if running {
                    Button { store.openSession(agent) } label: { Label("Open session", systemImage: "terminal") }
                        .help("Show this session")
                    // A session that already sits in a seat (it works as the lead) needs no profile of its own.
                    if AGTLeads.seat(agent) == nil {
                        Button { Task { if let id = await store.saveAsAgent(agent) { store.openProfile = id } } } label: {
                            Label("Save as an agent", systemImage: "person.badge.plus")
                        }
                        .help("Give it a profile, so it can be a permanent agent")
                        .disabled(store.busy)
                    }
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if let message = store.message { AGTMessageLine(text: message) }
                if !running {
                    HStack(spacing: 8) {
                        Image(systemName: "moon.zzz").foregroundStyle(.secondary)
                        Text("\(agent.name) is not running now. Its memory stays with the project; a session with this name in the same project takes it up again.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, DeckTokens.Metrics.pageHorizontal)
                }
                AGTMemoryTab(agent: agent)
            }
            .padding(.top, DeckTokens.Metrics.pageTop).padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var running: Bool { !agent.id.hasPrefix(AGTLeads.placeholderPrefix) }
    private var subtitle: String {
        let project = NativePROJLabels.shared.name(for: AGTLeads.projectID(agent))
        let role = AGTLeads.worksAsLead(agent) != nil ? "Works as the lead" : AGTLeads.isLead(agent) ? "Lead" : "Session"
        let title = agent.sessionTitle.flatMap { $0 != agent.name && !$0.isEmpty ? " · session “\($0)”" : nil } ?? ""
        return project + " · " + role + title + (running ? "" : " · not running")
    }
}
