import TerminalDeckNativeCore

/// Native-only panels share the existing sidebar metadata and row rendering.
/// AGT: the sidebar's own "Agents" section — Hoot, All agents, Org chart, At work.
/// The three Agents rows open one page (AGTAgentsScreen) on that view.
enum NativeINT2Navigation {
    static let watchID = "agents-watch"
    static let allID = "agents-all"
    static let orgID = "agents-org"
    /// The Agents page's views, in the order the switcher shows them.
    static let routinesID = "agents-routines"
    static let skillsID = "agents-skills"
    static let ids = [allID, orgID, watchID, routinesID, skillsID]
    static func owns(_ id: String?) -> Bool { id.map(ids.contains) ?? false }

    static func sidebar(_ state: SidebarState) -> SidebarState {
        var result = state
        var hoot: SidebarItem?
        // Hoot (and any older Agents row) move out of the untitled top group into the section.
        result.groups = state.groups.compactMap { group in
            var items = group.items
            if hoot == nil, let index = items.firstIndex(where: { $0.kind == .hoot || $0.id == "hoot" }) {
                hoot = items.remove(at: index)
            }
            items.removeAll { owns($0.id) }
            if items.isEmpty && !group.items.isEmpty { return nil }
            return .init(id: group.id, title: group.title, items: items)
        }
        let rows = [hoot].compactMap { $0 } + [
            SidebarItem(id: allID, title: "Agents", symbol: "person.3", kind: .panel),
        ]
        result.groups.insert(.init(id: "native-agents", title: nil, items: rows), at: 0)
        return result
    }
}
