import AppKit
import SwiftUI
import TerminalDeckNativeCore
import TerminalDeckBackend

/// The island's drop-down. Hoot: his small chat, as before. The other "Shows" choices (15 Nov, item 47): the smallest
/// list of what the capsule counts; a click opens that thing in the app and the island settles. An approval waiting
/// always comes first, whatever the island shows.
struct NativeIslandContent: View {
    static var isNative: Bool { NativeScreens.registered.contains("island") }
    let expanded: Bool
    var shows: NativeIslandShows = .hoot
    var facts = NativeIslandFacts()
    var chatTopInset: CGFloat = 0
    /// Pictures: draw without opening anything.
    var fixture = false
    @State private var desk = NativePermissionDesk.shared

    var body: some View {
        if expanded {
            VStack(spacing: 8) {
                if let request = desk.current {
                    NativePermissionCard(item: request, more: max(0, desk.visible.count - 1))
                        .padding(.horizontal, 8).padding(.top, max(8, chatTopInset))
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                switch shows {
                case .hoot:
                    NativeHootChat(compact: true)
                        .contentMargins(.top, desk.current == nil ? chatTopInset : 0, for: .scrollContent)
                case .sessions:
                    NativeIslandList(rows: facts.running.reversed().map { session in
                        NativeIslandList.Row(id: session.id, title: NativeIslandFace.shown(session.name, or: "Session"),
                              state: Self.state(session.status), attention: session.needsYou)
                    }, empty: "No sessions running") { id in open(session: id) }
                case .tasks:
                    NativeIslandList(rows: facts.tasks.map { task in
                        NativeIslandList.Row(id: task.id, title: NativeIslandFace.shown(task.title, or: "Task"), state: Self.when(task), attention: false)
                    }, empty: "No open tasks") { id in open(task: id) }
                case .needsMe:
                    // Approvals already have their card above; the rest are sessions asking a question.
                    let carded = Set(desk.visible.map(\.id))
                    NativeIslandList(rows: facts.waiting.filter { wait in wait.sessionID != nil && !carded.contains(wait.id) }.map { wait in
                        NativeIslandList.Row(id: wait.sessionID ?? wait.id, title: NativeIslandFace.shown(wait.asker, or: "Session"),
                            state: "Asking", attention: true)
                    }, empty: desk.current == nil ? "Nothing needs you" : nil) { id in open(session: id) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .foregroundStyle(.primary)
        }
    }

    static func state(_ status: String) -> String {
        switch status {
        case "working": "Working"
        case "input": "Asking"
        case "waiting": "Waiting"
        default: "Open"
        }
    }

    /// A date, never an id: the due date when it has one, else when it last changed.
    static func when(_ task: NativeIslandTaskFact) -> String {
        if let due = task.due, !due.isEmpty {
            let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX"); parser.dateFormat = "yyyy-MM-dd"
            if let date = parser.date(from: String(due.prefix(10))) { return "Due " + date.formatted(.dateTime.day().month(.abbreviated)) }
        }
        guard task.updatedAt > 0 else { return "" }
        let seconds = task.updatedAt > 10_000_000_000 ? task.updatedAt / 1000 : task.updatedAt
        return Date(timeIntervalSince1970: seconds).formatted(.dateTime.day().month(.abbreviated))
    }

    private func open(session id: String) {
        guard !fixture else { return }
        NativeFront.onlyForPerson("Island open-session") { AppModel.shared.selectTab(id); NSApp.activate(ignoringOtherApps: true) }
        IslandController.shared.collapse()
    }

    private func open(task id: String) {
        guard !fixture else { return }
        NativeFront.onlyForPerson("Island open-task") {
            TasksStore.shared.openTask(id); AppModel.shared.select("tasks"); NSApp.activate(ignoringOtherApps: true)
        }
        IslandController.shared.collapse()
    }
}

/// The drop-down's one list: a name, one short state at the right, the whole row a click. Nothing changes on hover.
struct NativeIslandList: View {
    struct Row: Identifiable, Equatable {
        let id: String
        let title: String
        let state: String
        let attention: Bool
    }
    let rows: [Row]
    let empty: String?
    let open: (String) -> Void

    var body: some View {
        if rows.isEmpty {
            if let empty {
                Text(empty).font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        Button { open(row.id) } label: {
                            HStack(spacing: 8) {
                                Text(row.title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                                Spacer(minLength: 8)
                                Text(row.state).font(.system(size: 12))
                                    .foregroundStyle(row.attention ? Color.orange : Color.secondary).lineLimit(1)
                            }
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
