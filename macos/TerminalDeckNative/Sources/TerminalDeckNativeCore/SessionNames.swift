import Foundation

/// Names given to sessions, laid over what the page's rail and tab strip say.
///
/// Asad, 12 Oct (install 18): "I can't rename sessions like before. If I edit and apply, it does not work."
/// Both renames (the side panel's "Rename…" and the session bar's title) went through the hidden page, which
/// dropped them without a word. A rename now goes straight to the engine (`session:rename`: the session, the
/// helper that runs it, its saved launch). These overrides make the new name show at once in every native
/// place that reads the page's rail or strip (rows, the session bar, pop-out windows, panes), before the page
/// repaints it, and whether or not it ever does.
public enum SessionNames {
    /// The rail with each named session's row (in a project or a group) showing its name.
    public static func applied(_ names: [String: String], to state: SidebarState) -> SidebarState {
        guard !names.isEmpty else { return state }
        var next = state
        next.groups = state.groups.map { group in
            SidebarGroup(id: group.id, title: group.title, items: group.items.map { named($0, names) })
        }
        next.projects = state.projects.map { project in
            SidebarProject(id: project.id, title: project.title, expanded: project.expanded,
                           sessions: project.sessions.map { named($0, names) })
        }
        return next
    }

    /// The tab strip with each named session's tab showing its name.
    public static func applied(_ names: [String: String], to state: TabsState) -> TabsState {
        guard !names.isEmpty else { return state }
        var next = state
        next.tabs = state.tabs.map { tab in
            guard let name = usable(names[tab.id]), name != tab.title, tab.kind != "browser", !tab.isHoot else { return tab }
            return TabItem(id: tab.id, title: name, symbol: tab.symbol, kind: tab.kind, active: tab.active,
                           unread: tab.unread, status: tab.status, closable: tab.closable, server: tab.server)
        }
        return next
    }

    static func named(_ item: SidebarItem, _ names: [String: String]) -> SidebarItem {
        guard item.kind == .session, let name = usable(names[item.id]), name != item.title else { return item }
        return SidebarItem(id: item.id, title: name, symbol: item.symbol, kind: item.kind, unread: item.unread,
                           status: item.status, subtitle: item.subtitle, help: item.help, turn: item.turn,
                           promoted: item.promoted, promoteBlocked: item.promoteBlocked)
    }

    private static func usable(_ name: String?) -> String? {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return name
    }
}
