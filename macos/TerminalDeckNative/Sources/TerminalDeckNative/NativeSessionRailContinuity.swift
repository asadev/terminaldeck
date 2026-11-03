import Foundation
import Observation
import TerminalDeckNativeCore

/// The conversation's rail identity outlives the AI process that happens to run it.
@MainActor @Observable final class NativeSessionRailContinuity {
    static let shared = NativeSessionRailContinuity()
    struct Row: Identifiable { let id: String; let item: SidebarItem }
    private struct Hold { let item: SidebarItem; let position: Int; let chat: NativeHootChatModel? }
    @ObservationIgnored private var switching: Set<String> = []
    private(set) var aliases: [String: String] = [:]
    private var holds: [String: Hold] = [:]
    @ObservationIgnored private(set) var titles: [String: String] = [:]
    @ObservationIgnored private(set) var headerPositions: [String: Int] = [:]
    @ObservationIgnored private(set) var agents: [String: AGTAgent] = [:]
    /// 18 Oct (#54): when the conversation's first session started. A session switched to another account sorts at
    /// that time among the others, so it keeps its place in the side list without being pinned to a row number
    /// (it was held at that row for the rest of the app run, whatever came and went).
    @ObservationIgnored private(set) var since: [String: Double] = [:]
    @ObservationIgnored private var releasing: Set<String> = []
    func identity(_ id: String) -> String { aliases[id] ?? id }
    func isSwitching(_ id: String) -> Bool { switching.contains(id) }
    func heldChat(_ id: String) -> NativeHootChatModel? { holds[identity(id)]?.chat }
    var toolState: NativeRPCValue {
        let model = AppModel.shared, store = SIDEBARProjectStore.shared
        let rows = model.visibleSidebar.map { project(SIDEBARLayout.running($0, liveIDs: store.liveIDs ?? [], started: started(store.started))) } ?? []
        let tabs = arrangedHeader(NativePaneArrangement.shared.arrangedTabs(model.stripTabs?.tabs.map(\.id) ?? []))
        let selected = model.currentScreen?.id
        let loading = selected.flatMap { NativeTerminalSessions.shared.retainedSession($0)?.chatLoading }
        return .object([.init("sidebarSlots", .array(rows.map { .string(identity($0.id)) })),
            .init("tabSlots", .array(tabs.map { .string(identity($0)) })),
            .init("selectedSlot", selected.map { .string(identity($0)) } ?? .null),
            .init("chatLoading", loading.map(NativeRPCValue.bool) ?? .null),
            .init("chats", NativeTerminalSessions.shared.chatDisplayStates)])
    }
    func arrangedHeader(_ ids: [String]) -> [String] {
        var result = ids
        for (key, position) in headerPositions.sorted(by: { $0.value < $1.value }) {
            if let index = result.firstIndex(where: { identity($0) == key }), !NativePaneArrangement.shared.tabOrder.contains(result[index]) {
                let item = result.remove(at: index); result.insert(item, at: min(position, result.count))
            }
        }
        return result
    }
    func begin(_ id: String) {
        guard let state = AppModel.shared.visibleSidebar, let item = state.item(id: id) else { return }
        let key = identity(id), store = SIDEBARProjectStore.shared
        if let tabs = AppModel.shared.stripTabs?.tabs {
            let order = arrangedHeader(NativePaneArrangement.shared.arrangedTabs(tabs.map(\.id)))
            if let index = order.firstIndex(of: id) { headerPositions[key] = index }
        }
        let rows = SIDEBARLayout.running(state, liveIDs: store.liveIDs ?? [], started: started(store.started))
        let position = rows.firstIndex(where: { $0.id == id }) ?? rows.count
        switching.insert(id)
        keepPlace(id, startedAt: store.started[id])
        let session = NativeTerminalSessions.shared.retainedSession(id)
        let chat = session?.isChat == true ? session?.chatModel() : NativeHootChatModel.queueOwner(id)
        holds[key] = .init(item: item, position: position, chat: chat); titles[key] = item.title
        if let agent = chat?.replyAgent ?? AGTAgentsStore.shared.sender(of: id) ?? SIDEBARSessionAgents.all()[id] { agents[key] = agent }
    }
    func replaced(_ old: String, with row: [String: Any]) {
        guard let next = row["id"] as? String else { return }
        carry(old, to: next)
        SIDEBARPins.shared.replaced(old, with: next)
    }
    /// The replacement answers to the conversation's identity and takes over its held row.
    func carry(_ old: String, to next: String) {
        let key = identity(old); aliases[next] = key; switching.remove(old)
        if let held = holds[key] {
            holds[key] = .init(item: copy(held.item, id: next, title: held.item.title), position: held.position, chat: held.chat)
        }
    }
    func failed(_ old: String) { holds[identity(old)] = nil; switching.remove(old) }
    func finishedInPlace(_ old: String) {
        switching.remove(old)
        if holds[identity(old)]?.item.id == old { holds[identity(old)] = nil }
    }
    func removed(_ id: String) {
        guard !switching.contains(id) else { return }
        let key = identity(id)
        if holds[key]?.item.id == id { holds[key] = nil }
        // 18 Oct (#434): the conversation's records go with its last session, never kept for the whole app run.
        if aliases[id] != nil { aliases[id] = nil }
        guard !aliases.values.contains(key), !switching.contains(key) else { return }
        titles[key] = nil; headerPositions[key] = nil; agents[key] = nil; since[key] = nil
    }
    /// The conversation keeps the start time of its first session (#54).
    func keepPlace(_ id: String, startedAt: Double?) {
        let key = identity(id)
        if since[key] == nil, let startedAt { since[key] = startedAt }
    }
    /// The start times the side list sorts by: a switched session's is its conversation's first (#54).
    func started(_ base: [String: Double]) -> [String: Double] {
        var result = base
        for (id, key) in aliases { if let at = since[key] { result[id] = at } }
        return result
    }
    func title(_ id: String) -> String? { titles[identity(id)] }
    func renamed(_ id: String, title: String) { titles[identity(id)] = title.isEmpty ? nil : title }
    func agent(_ id: String) -> AGTAgent? {
        guard let remembered = agents[identity(id)] else { return nil }
        return AGTAgentsStore.shared.agent(remembered.id) ?? remembered
    }
    func identified(_ rows: [SidebarItem]) -> [Row] { rows.map { .init(id: identity($0.id), item: $0) } }
    func project(_ current: [SidebarItem]) -> [SidebarItem] {
        var result: [SidebarItem] = [], indexes: [String: Int] = [:]
        for item in current {
            let key = identity(item.id)
            let rendered = copy(item, id: item.id, title: titles[key] ?? item.title)
            if let index = indexes[key] { if aliases[item.id] != nil { result[index] = rendered } }
            else { indexes[key] = result.count; result.append(rendered) }
        }
        for (key, hold) in holds {
            if !switching.contains(hold.item.id), current.contains(where: { $0.id == hold.item.id }) {
                if releasing.insert(key).inserted {
                    Task { @MainActor in
                        if self.holds[key]?.item.id == hold.item.id { self.holds[key] = nil }
                        self.releasing.remove(key)
                    }
                }
            } else if !result.contains(where: { identity($0.id) == key }) {
                result.insert(hold.item, at: min(hold.position, result.count))
            }
        }
        return result
    }
    private func copy(_ item: SidebarItem, id: String, title: String) -> SidebarItem {
        .init(id: id, title: title, symbol: item.symbol, kind: item.kind, unread: item.unread, status: item.status,
              subtitle: item.subtitle, help: item.help, turn: item.turn, promoted: item.promoted, promoteBlocked: item.promoteBlocked)
    }
}
