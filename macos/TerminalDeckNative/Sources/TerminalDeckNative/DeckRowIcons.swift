import AppKit
import SwiftUI
import TerminalDeckNativeCore

// Asad 11 Oct: "everywhere we have a list of projects or any kind of list who has a profile
// photo, icon, logo it should come there". One helper per kind of thing, for every menu,
// picker and dropdown row: the same picture the thing has everywhere else, at 16 pt beside
// its name. Menus only draw images, so each picture is made into an NSImage once and kept.

@MainActor
enum DeckRowIcon {
    static let side: CGFloat = 16
    /// U143 (#647): one picture per thing (a project, an agent), kept with the look it was drawn for; a rename,
    /// a new logo or a new colour replaces it, so the old pictures are not kept until the app quits.
    private(set) static var cache: [String: (look: String, image: NSImage)] = [:]

    private static func cached(_ slot: String, look: String = "", _ make: () -> NSImage) -> NSImage {
        if let hit = cache[slot], hit.look == look { return hit.image }
        let image = make()
        cache[slot] = (look, image)
        return image
    }

    /// Any small SwiftUI picture as a menu image.
    private static func render<V: View>(_ view: V, template: Bool = false) -> NSImage {
        let renderer = ImageRenderer(content: view.frame(width: side, height: side))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: side, height: side))
        image.size = NSSize(width: side, height: side)
        image.isTemplate = template
        return image
    }

    private static func symbol(_ name: String) -> NSImage {
        cached("symbol:" + name) {
            let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
                ?? NSImage(size: NSSize(width: side, height: side))
            image.isTemplate = true
            return image
        }
    }

    // MARK: Projects

    /// The project's logo, or its letter tile.
    static func project(_ project: PROJProject?, name: String? = nil) -> NSImage {
        let title = project?.name ?? name ?? "?"
        return cached("project:" + (project?.id ?? "name:" + title), look: "\(project?.logo ?? ""):\(title)") {
            ProjectLogos.menuImage(project, name: title)
        }
    }
    /// "All projects" and "Independent": neutral marks, so the column lines up.
    static var allProjects: NSImage { symbol("square.grid.2x2") }
    static var independent: NSImage { symbol("circle.dashed") }

    /// By an open folder: the registry project that owns it (never registers anything).
    static func project(folder: String) -> NSImage {
        let registry = SIDEBARProjectStore.shared.projects
        let id = PROJProjects.resolve(projectID: nil, folder: folder, projects: registry)
        let found = id == PROJProjects.independentID ? nil : registry.first { $0.id == id }
        return project(found, name: found?.name ?? (folder as NSString).lastPathComponent)
    }

    /// By registry id (nil = All projects).
    static func project(id: String?, in projects: [PROJProject]) -> NSImage {
        guard let id else { return allProjects }
        if id == PROJProjects.independentID { return independent }
        return project(projects.first { $0.id == id }, name: id)
    }

    // MARK: Agents and Hoot

    static var hoot: NSImage { cached("hoot") { NSImage.hootMark(size: side) } }

    /// An agent's avatar from its stored icon string (`sf:star@pink`, an emoji…).
    static func agent(id: String, icon: String?, hoot isHoot: Bool = false) -> NSImage {
        if isHoot || id == "@hoot" || id == "hoot" { return hoot }
        return cached("agent-icon:" + id, look: icon ?? "") { render(AgentAvatar(id: id, iconRaw: icon, size: side)) }
    }

    /// By id alone: looked up in the app's agents (profile id or agent id).
    static func agent(id: String) -> NSImage {
        if id == "@hoot" || id == "hoot" { return hoot }
        if let found = agentsThisTurn()[id] { return agent(found) }
        return agent(id: id, icon: nil)
    }

    /// The app's agents by id and profile id, built once per main run-loop turn. `AGTAgentsStore.agents`
    /// rebuilds the whole directory on every read; a Tasks list asked it once per assignee choice per row,
    /// which held the main thread for seconds whenever a task opened (12 Oct, his own 9 tasks).
    private static var turnAgents: [String: AGTAgent]?
    static func agentsThisTurn() -> [String: AGTAgent] {
        if let turnAgents { return turnAgents }
        var byID: [String: AGTAgent] = [:]
        for agent in AGTAgentsStore.shared.agents {
            if byID[agent.id] == nil { byID[agent.id] = agent }
            if let profile = agent.profileID, byID[profile] == nil { byID[profile] = agent }
        }
        turnAgents = byID
        Task { @MainActor in turnAgents = nil }
        return byID
    }

    /// A task's assignee: you (or nobody) as a person mark, an agent as its avatar.
    static func assignee(_ id: String) -> NSImage {
        ["", "me", "none", "unassigned", "you"].contains(id.lowercased()) ? symbol("person.crop.circle") : agent(id: id)
    }

    static func agent(_ agent: AGTAgent) -> NSImage {
        if agent.isHoot { return hoot }
        return cached("agent:" + (agent.profileID ?? agent.id), look: "\(agent.icon.raw):\(agent.iconColour ?? "")") {
            render(AgentAvatar(agent: agent, size: side))
        }
    }

    // MARK: Coding AIs

    /// "claude" / "codex" / "gemini" / "shell" from an id or a label ("Claude Code", "codex-cli"…).
    static func providerID(_ text: String?) -> String? {
        guard let text = text?.lowercased() else { return nil }
        if text.contains("claude") || text.contains("anthropic") { return "claude" }
        if text.contains("codex") || text.contains("openai") || text.contains("chatgpt") { return "codex" }
        if text.contains("gemini") || text.contains("google") { return "gemini" }
        if text.contains("shell") || text.contains("terminal") { return "shell" }
        return nil
    }

    /// The AI's own mark (the one the Coding AIs page draws), or a neutral mark for anything else.
    static func provider(_ text: String?) -> NSImage {
        guard let id = providerID(text) else { return symbol("sparkle") }
        return cached("provider:" + id) {
            render(NativeCodingAIProviderMark(provider: id, size: 14).foregroundStyle(.black), template: true)
        }
    }

    // MARK: Machines and apps

    static var server: NSImage { symbol("server.rack") }
    static var thisMac: NSImage { symbol("laptopcomputer") }
    static var session: NSImage { symbol("terminal") }
    static func session(id: String) -> NSImage {
        // Leave room for the corner badge inside a menu's fixed image box.
        render(NativeSessionRowIdentity(id: id).picture(size: side / 1.4, surface: .clear))
    }
    static func device(kind: String?) -> NSImage {
        let text = kind?.lowercased() ?? ""
        if text.contains("ipad") || text.contains("tablet") { return symbol("ipad") }
        if text.contains("mac") || text.contains("computer") { return symbol("laptopcomputer") }
        return symbol("iphone")
    }
    static func symbolIcon(_ name: String) -> NSImage { symbol(name) }
}

/// A menu / picker row: the thing's picture, then its name.
struct DeckRowLabel: View {
    let title: String
    let image: NSImage

    init(_ title: String, image: NSImage) { self.title = title; self.image = image }

    var body: some View {
        // macOS 27 hides the pictures in menus unless a row says its own picture matters. For a
        // SwiftUI row that is the explicit title-and-icon style ON THE ROW (measured 11 Oct on 27.2:
        // without it the menu item is left on "automatic" and the logo is not drawn; the same
        // style on the enclosing Menu does not reach its rows). In a picker nothing changes.
        Label { Text(title) } icon: { Image(nsImage: image) }.labelStyle(.titleAndIcon)
    }
}

extension NSMenuItem {
    /// macOS 27 hides a menu item's picture unless the item asks to keep it
    /// (`preferredImageVisibility = .visible`). A row's picture (a project's logo, an agent's
    /// avatar, an AI's mark) is how the row is recognised, so every native menu row that sets one
    /// calls this. Set by name so the same source builds with an SDK that predates the property;
    /// an older system always draws the picture and skips this.
    func deckKeepsPicture() {
        guard responds(to: Selector(("setPreferredImageVisibility:"))) else { return }
        setValue(1, forKey: "preferredImageVisibility") // 1 = visible
    }
    /// Whether the picture is drawn whatever the system would choose by itself.
    var deckPictureKept: Bool {
        guard image != nil else { return false }
        guard responds(to: Selector(("preferredImageVisibility"))) else { return true }
        return (value(forKey: "preferredImageVisibility") as? Int) == 1
    }
}

extension DeckRowLabel {
    @MainActor static var allProjects: DeckRowLabel { DeckRowLabel("All projects", image: DeckRowIcon.allProjects) }
    @MainActor static var independent: DeckRowLabel { DeckRowLabel("Independent", image: DeckRowIcon.independent) }
    @MainActor static func project(_ project: PROJProject) -> DeckRowLabel {
        if project.id == PROJProjects.independentID { return independent }
        return DeckRowLabel(project.name, image: DeckRowIcon.project(project))
    }
    @MainActor static func agent(id: String, name: String, icon: String?) -> DeckRowLabel {
        DeckRowLabel(name, image: DeckRowIcon.agent(id: id, icon: icon))
    }
    @MainActor static func provider(_ label: String, id: String? = nil) -> DeckRowLabel {
        DeckRowLabel(label, image: DeckRowIcon.provider(id ?? label))
    }
}
