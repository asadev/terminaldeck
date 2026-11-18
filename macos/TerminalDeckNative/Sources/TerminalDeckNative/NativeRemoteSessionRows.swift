import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// The keeper's live ids describe this Mac only. An opened viewer has its own row until this window retires it;
/// losing the other Mac's session list during a handover must not remove that row or change its name to Session.
enum NativeRemoteSessionRows {
    static func running(_ state: SidebarState, localIDs: Set<String>, links: MachinesSnapshot,
                        liveRefs: [String: String], moves: [String: BackendCloudSessionMoveEntry],
                        started: [String: Double]) -> [SidebarItem] {
        let remote = state.allItems.compactMap { row -> String? in
            if case .machine = SessionTarget(tabId: row.id) { return row.id }
            return nil
        }
        return SIDEBARLayout.running(state, liveIDs: localIDs.union(remote), started: started).map { row in
            guard case .machine(let machine, let id) = SessionTarget(tabId: row.id) else { return row }
            let facts = links.links[machine]?.session(id)
            var title = facts?.title.isEmpty == false ? facts!.title : row.title
            var status = facts?.status ?? row.status
            if let ref = liveRefs[row.id], let move = moves[ref], move.role == .taker, move.step != .done, move.step != .cancelled {
                title = move.source?.name ?? title
                if !move.finished { status = "working" }
            }
            return SidebarItem(id: row.id, title: title, symbol: row.symbol, kind: row.kind, unread: row.unread, status: status,
                subtitle: row.subtitle, help: row.help, turn: row.turn, promoted: row.promoted, promoteBlocked: row.promoteBlocked)
        }
    }

    static func chat(_ tabId: String, links: MachinesSnapshot) -> Bool {
        guard case .machine(let machine, let id) = SessionTarget(tabId: tabId) else { return false }
        return links.links[machine]?.session(id)?.chat == true
    }
}
