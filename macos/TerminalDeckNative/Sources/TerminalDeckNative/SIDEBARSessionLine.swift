import AppKit
import SwiftUI
import TerminalDeckNativeCore

// A session row in the side panel, drawn as the phone's side panel draws it (Asad, 29 Oct, with both pictures: the
// phone's "this way profiles and titles look good", the Mac's "do the same for the Mac app too, they are too
// separate"): one picture (who works in it, with its project's badge on the corner), then the session's own name,
// and under it "Agent · AI". The Mac keeps its status dot and its "…", at the row's end.

/// What a session row says: the same title and line the paired phones show for it.
enum SIDEBARSessionLine {
    /// The session's own name, as the phones get it: a name given here (or announced), else the session's title
    /// from `session:list`, else the rail's; an empty one is its folder's name. Never the page's "Session 2", which
    /// stands in for a session still named after its folder.
    static func title(given: String?, own: String?, rail: String, folder: String?, retained: String? = nil) -> String {
        let retained = retained.flatMap { isPlaceholder($0) ? nil : $0 }
        for candidate in [given, retained, own] {
            let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty { return text }
        }
        let rail = rail.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholder = isPlaceholder(rail)
        if !rail.isEmpty && !placeholder { return rail }
        let name = folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        return name.isEmpty ? "Untitled session" : name
    }

    private static func isPlaceholder(_ title: String) -> Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).range(of: #"^Session [0-9]+$"#, options: .regularExpression) != nil
    }

    @MainActor
    static func title(_ session: SidebarItem, store: SIDEBARProjectStore) -> String {
        let given = NativeSessionNames.shared.names[session.id]
        return title(given: given, own: store.sessionTitles[session.id], rail: session.title, folder: store.sessionProjects[session.id]?.cwd ?? nil,
                     retained: NativeSessionRailContinuity.shared.title(session.id))
    }

    /// The AI or shell name, written in full beneath the session title.
    static func aiName(_ provider: String?) -> String? {
        let id = provider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !id.isEmpty else { return nil }
        return ["claude": "Claude Code", "codex": "Codex", "gemini": "Gemini", "shell": "Shell", "powershell": "PowerShell", "pwsh": "PowerShell"][id] ?? id.capitalized
    }

    /// "Decker · Claude Code"; no agent means just the AI or shell name.
    static func subtitle(agent: String?, ai: String?) -> String? {
        let agent = agent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ai = ai?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if agent.isEmpty { return ai.isEmpty ? nil : ai }
        return ai.isEmpty || ai == agent ? agent : agent + " · " + ai
    }
}

/// One session picture for sidebars, history, search, project cards and pickers.
struct SIDEBARSessionPicture: View {
    let agent: AGTAgent?
    let provider: String?
    let project: PROJProject?
    var onAccent = false
    var size: CGFloat = 26
    var chat = false
    var surface: Color = DeckTokens.frame
    var mutedSelected = false

    var body: some View {
        Group {
            if let agent {
                if agent.isHoot || AGTAgentsStore.shared.profiles.first(where: { $0.id == (agent.profileID ?? agent.id) })?.icon.flatMap(AGTIcon.parse) != nil {
                    AgentAvatar(agent: agent, size: size)
                } else {
                    let initials = String(agent.name.split(whereSeparator: { $0.isWhitespace }).prefix(2).compactMap(\.first)).uppercased()
                    Text(initials.isEmpty ? "?" : initials)
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(AgentColour.color(id: agent.profileID ?? agent.id, chosen: agent.iconColour, icon: agent.icon))
                        .frame(width: size, height: size)
                        .background(DeckTokens.avatarTile, in: .rect(cornerRadius: size * 0.28))
                }
            } else {
                Image(systemName: chat ? "bubble.left" : "terminal")
                    .font(.system(size: size * 0.58, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if let project, project.id != PROJProjects.independentID {
                let badge = (size * 0.52).rounded()
                ProjectLogoView(project: project, size: badge)
                    .padding(1.5)
                    .background {
                        let shape = RoundedRectangle(cornerRadius: max(3, badge * 0.25) + 1.5, style: .continuous)
                        shape.fill(onAccent ? Color.accentColor : surface)
                            .overlay { if mutedSelected { shape.fill(Color.primary.opacity(0.12)) } }
                    }
                    .offset(x: size * 0.2, y: size * 0.2)
                    .help(project.name)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Reads the same identities the phone receives. A missing owner stays a plain session.
@MainActor
struct NativeSessionRowIdentity {
    let agent: AGTAgent?
    let project: PROJProject?
    let provider: String?
    let chat: Bool
    private static var turnAgents: [String: AGTAgent]?

    private static func agentsThisTurn() -> [String: AGTAgent] {
        if let turnAgents { return turnAgents }
        let agents = SIDEBARSessionAgents.all()
        turnAgents = agents
        // Search can show a hundred hits; build the directory once for the whole view update.
        Task { @MainActor in turnAgents = nil }
        return agents
    }

    init(id: String, folder: String? = nil, provider: String? = nil, chat: Bool = false,
         agent: AGTAgent? = nil, project: PROJProject? = nil) {
        let store = SIDEBARProjectStore.shared
        self.agent = agent ?? AGTAgentsStore.shared.sender(of: id)
            ?? NativeSessionRailContinuity.shared.agent(id) ?? Self.agentsThisTurn()[id]
        self.provider = provider ?? store.sessionProviders[id]
        self.chat = chat || store.sessionChats.contains(id)
        let location = store.sessionProjects[id]
        let projectID = PROJProjects.resolve(projectID: project?.id ?? location?.projectID,
                                             folder: folder ?? location?.cwd, projects: store.projects)
        self.project = projectID == PROJProjects.independentID ? nil : project ?? store.projects.first { $0.id == projectID }
    }

    var subtitle: String? { SIDEBARSessionLine.subtitle(agent: agent?.name, ai: SIDEBARSessionLine.aiName(provider)) }

    func picture(size: CGFloat = 26, surface: Color = DeckTokens.card) -> some View {
        SIDEBARSessionPicture(agent: agent, provider: provider, project: project, size: size, chat: chat, surface: surface)
    }
}
