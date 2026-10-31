import SwiftUI
import TerminalDeckNativeCore

/// Reads the same backend marker as every chat window; no separate inbox acknowledgement.
@MainActor @Observable final class NativeChatUnreadCounts {
    static let shared = NativeChatUnreadCounts()
    private(set) var counts: [String: Int] = [:]
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private var requested: Set<String> = []
    func accept(_ value: NativeRPCValue, id: String) {
        guard let count = value["unread"]["count"].number else { return }
        counts[id] = Int(count)
    }
    func start() {
        guard subscriptions.isEmpty, EngineBridge.shared.isReady else { return }
        subscriptions.append(EngineBridge.shared.on("hoot:chat:changed") { [weak self] args in
            if let raw = args.first, let value = try? NativeRPCValue.fromFoundation(raw) { self?.accept(value, id: "hoot") }
        })
        subscriptions.append(EngineBridge.shared.on("session:chat:changed") { [weak self] args in
            guard args.count >= 2, let id = args[0] as? String, let value = try? NativeRPCValue.fromFoundation(args[1]) else { return }
            self?.accept(value, id: id)
        })
        subscriptions.append(EngineBridge.shared.on("session:created") { [weak self] args in
            guard let raw = args.first, let value = try? NativeRPCValue.fromFoundation(raw), value["chat"].bool == true, let id = value["id"].string else { return }
            self?.request(id)
        })
        request("hoot")
        Task {
            guard let raw = try? await EngineBridge.shared.invoke("session:list"),
                  let value = try? NativeRPCValue.fromFoundation(raw) else { return }
            for row in value.elements ?? value["sessions"].elements ?? [] where row["chat"].bool == true {
                if let id = row["id"].string { request(id) }
            }
        }
    }
    func request(_ id: String) {
        guard requested.insert(id).inserted else { return }
        Task {
            do {
                let raw = try await EngineBridge.shared.invoke(id == "hoot" ? "hoot:chat:read" : "session:chat:read",
                    id == "hoot" ? [NSNull(), 1] : [id, NSNull(), 1])
                accept(try NativeRPCValue.fromFoundation(raw), id: id)
            } catch { requested.remove(id) }
        }
    }
    func decorate(_ state: SidebarState) -> SidebarState {
        start()
        func row(_ row: SidebarItem) -> SidebarItem {
            // Only known chats replace a terminal's own attention state.
            guard let count = counts[row.id] else { return row }
            return .init(id: row.id, title: row.title, symbol: row.symbol, kind: row.kind, unread: count > 0,
                status: row.status, subtitle: count > 0 ? "\(count) new messages" : row.subtitle, help: row.help,
                turn: row.turn, promoted: row.promoted, promoteBlocked: row.promoteBlocked)
        }
        return .init(groups: state.groups.map { .init(id: $0.id, title: $0.title, items: $0.items.map(row)) },
            projects: state.projects.map { .init(id: $0.id, title: $0.title, expanded: $0.expanded, sessions: $0.sessions.map(row)) },
            selectedId: state.selectedId, project: state.project, openFile: state.openFile, focus: state.focus)
    }
}
