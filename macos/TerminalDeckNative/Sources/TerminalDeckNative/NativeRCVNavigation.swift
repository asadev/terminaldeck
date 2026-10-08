import TerminalDeckNativeCore

/// RCV: the sidebar's Integrations → Receiver row. Native-only, injected the same
/// way as "Agents at work" (NativeINT2Navigation), with the same row rendering.
enum NativeRCVNavigation {
    static let id = "receiver"
    static func sidebar(_ state: SidebarState) -> SidebarState {
        guard state.item(id: id) == nil else { return state }
        var result = state
        let item = SidebarItem(id: id, title: "Receiver", symbol: "tray.and.arrow.down", kind: .panel)
        if let index = result.groups.firstIndex(where: { $0.title == "Integrations" }) {
            let group = result.groups[index]
            result.groups[index] = .init(id: group.id, title: group.title, items: group.items + [item])
        } else {
            result.groups.append(.init(id: "native-integrations", title: "Integrations", items: [item]))
        }
        return result
    }
}
