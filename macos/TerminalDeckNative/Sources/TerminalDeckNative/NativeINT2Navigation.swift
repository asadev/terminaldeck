import TerminalDeckNativeCore

/// Native-only panels share the existing sidebar metadata and row rendering.
enum NativeINT2Navigation {
    static let watchID = "agents-watch"
    static func sidebar(_ state: SidebarState) -> SidebarState {
        guard state.item(id: watchID) == nil else { return state }
        var result = state
        let item = SidebarItem(id: watchID, title: "Agents at work", symbol: "person.2", kind: .panel)
        if let index = result.groups.firstIndex(where: { $0.items.contains { $0.kind == .hoot || $0.id == "hoot" } }) {
            let group = result.groups[index]
            var items = group.items
            let position = items.firstIndex { $0.kind == .hoot || $0.id == "hoot" }!
            items.insert(item, at: position + 1)
            result.groups[index] = .init(id: group.id, title: group.title, items: items)
        } else {
            result.groups.insert(.init(id: "native-agents", title: nil, items: [item]), at: 0)
        }
        return result
    }
}
