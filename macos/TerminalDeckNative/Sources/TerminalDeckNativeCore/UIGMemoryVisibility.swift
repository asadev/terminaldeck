import Foundation

/// Asad's round-two pause of the Memory page. This changes discovery and page
/// routing only; the memory models, files, channels and agent memory stay intact.
public enum UIGMemoryVisibility {
    public static let unavailableTitle = "Memory is not available right now"
    public static let unavailableMessage = "Your notes are still saved."

    public static func showsScreen(kind: String, id: String) -> Bool {
        !(kind == "panel" && id == "memory")
    }

    public static func showsScreen(_ ref: ScreenRef) -> Bool {
        showsScreen(kind: ref.screenKind, id: ref.id)
    }

    /// Identity, never a title match: a session named “Memory” is still a session.
    public static func showsSidebarItem(_ item: SidebarItem) -> Bool {
        showsScreen(kind: item.kind.name, id: item.id)
    }

    public static func sidebar(_ state: SidebarState) -> SidebarState {
        var next = state
        next.groups = state.groups.compactMap { group in
            let items = group.items.filter(showsSidebarItem)
            guard !items.isEmpty else { return nil }
            return SidebarGroup(id: group.id, title: group.title, items: items)
        }
        next.projects = state.projects.map { project in
            SidebarProject(id: project.id, title: project.title, expanded: project.expanded,
                sessions: project.sessions.filter(showsSidebarItem))
        }
        if let selected = state.selectedId,
           let item = state.item(id: selected), !showsSidebarItem(item) {
            next.selectedId = nil
            next.focus = nil
        }
        return next
    }

    public static func tabs(_ state: TabsState) -> TabsState {
        var next = state
        next.tabs = state.tabs.filter { showsScreen(kind: $0.kind, id: $0.id) }
        return next
    }

    public static func restoredScreens(_ refs: [ScreenRef]) -> [ScreenRef] {
        refs.filter(showsScreen)
    }

    /// Known page-command dialects. Do not search display text or hide unrelated
    /// commands such as Hoot's memory folder or machine memory readings.
    public static func showsCommand(_ id: String) -> Bool {
        !["memory", "open-memory", "view.memory", "panel.memory", "memory.open", "view:memory", "panel:memory"].contains(id)
    }

    public static func showsPageCommand(_ command: PageCommand) -> Bool {
        if command.name == "show-panel", let panel = command.list?.first {
            return showsScreen(kind: "panel", id: panel)
        }
        if command.name == "menu-command", let id = command.argument { return showsCommand(id) }
        return showsCommand(command.name)
    }

    public static func palette(_ commands: [PaletteCommand]) -> [PaletteCommand] {
        commands.filter { showsCommand($0.id) }
    }

    public static func showsMenuCommand(_ command: AppMenuCommand) -> Bool {
        guard case .page(let id) = command.action else { return true }
        return showsCommand(id)
    }

    /// The native feature family only. Hoot administration (hoot.memory),
    /// knowledge tools, and CPU/RAM readings are separate capabilities.
    public static func showsTool(id: String, wireName: String) -> Bool {
        !isMemoryToolName(id) && !isMemoryToolName(wireName)
    }

    public static func isMemoryToolName(_ name: String) -> Bool {
        name.hasPrefix("memory.") || name.hasPrefix("memory_")
    }
}
