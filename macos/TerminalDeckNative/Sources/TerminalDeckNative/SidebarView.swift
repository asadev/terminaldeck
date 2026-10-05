import SwiftUI
import AppKit
import TerminalDeckNativeCore

/// The native sidebar, drawn entirely from the page's `sidebar` message.
/// System sidebar material only — no glass on rows.
struct SidebarView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        List(selection: Binding(get: { model.listSelection }, set: { model.select($0) })) {
            if let state = model.visibleSidebar {
                ForEach(state.groups) { group in
                    Section {
                        ForEach(group.items) { item in
                            SidebarRow(item: item)
                                .tag(item.id as String?)
                                .modifier(ItemMenu(item: item, model: model, projectPath: nil, openWindow: openWindow))
                        }
                    } header: {
                        if let title = group.title { Text(title) }
                    }
                }

                Section("Open") {
                    ForEach(state.projects) { project in
                        DisclosureGroup(isExpanded: Binding(
                            get: { model.isExpanded(project.id) },
                            set: { model.setExpanded(project.id, $0) })
                        ) {
                            ForEach(project.sessions) { session in
                                SidebarRow(item: session)
                                    .tag(session.id as String?)
                                    .modifier(ItemMenu(item: session, model: model, projectPath: project.id, openWindow: openWindow))
                            }
                        } label: {
                            Label(project.title, systemImage: "folder")
                                .lineLimit(1)
                                .help(project.id)
                                .contextMenu {
                                    Button("New Session Here") { model.newSession(in: project.id) }
                                    Divider()
                                    Button("Close Project") { model.closeProject(project.id) }
                                }
                        }
                    }

                    Button(action: model.openProject) {
                        Label("Open Project…", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Open a project folder (⌘O)")
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// Every row: Open in New Window. Session rows also: Close Session
/// (and New Session Here, inside a project).
private struct ItemMenu: ViewModifier {
    let item: SidebarItem
    let model: AppModel
    let projectPath: String?
    let openWindow: OpenWindowAction

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Open in New Window") { openWindow(value: ScreenRef.forSidebarItem(item)) }
            if item.kind == .session {
                Divider()
                Button("Close Session") { model.closeSession(item.id) }
                if let projectPath {
                    Button("New Session Here") { model.newSession(in: projectPath) }
                }
            }
        }
    }
}

struct SidebarRow: View {
    let item: SidebarItem

    var body: some View {
        Label {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                StatusMark(status: item.status)
                if item.unread {
                    Circle()
                        .fill(.tint)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("Unread")
                }
            }
        } icon: {
            if item.isHoot {
                HootMark(size: 16)
            } else {
                Image(systemName: SymbolName.resolve(item.symbol, fallback: item.kind.defaultSymbol))
            }
        }
        .help(helpText)
    }

    private var helpText: String {
        [item.title, item.subtitle, item.status].compactMap { $0 }.joined(separator: " — ")
    }
}

/// A small mark for the states that need attention; nothing for calm ones.
/// The raw status is always in the row's (or tab's) tooltip.
struct StatusMark: View {
    let status: String?

    var body: some View {
        switch status?.lowercased() {
        case "working", "running", "busy", "thinking", "loading":
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("Working")
        case "input", "waiting", "needs-input", "attention", "blocked", "approval":
            Image(systemName: "hand.raised.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityLabel("Needs you")
        case "error", "failed", "fail", "crashed":
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityLabel("Error")
        default:
            EmptyView()
        }
    }
}

/// The page names SF Symbols; a name this macOS doesn't have would draw nothing.
@MainActor
enum SymbolName {
    private static var known: [String: Bool] = [:]

    static func resolve(_ name: String, fallback: String) -> String {
        if let ok = known[name] { return ok ? name : fallback }
        let ok = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        known[name] = ok
        return ok ? name : fallback
    }
}
