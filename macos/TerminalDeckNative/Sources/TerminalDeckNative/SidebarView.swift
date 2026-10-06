import SwiftUI
import AppKit
import TerminalDeckNativeCore

/// The native sidebar, drawn entirely from the page's `sidebar` message.
/// System sidebar material only — no glass on rows.
struct SidebarView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        rail
            // The rail's foot, as the page drew it: the session-updates offer (lane V),
            // then the update banner (lane S). It stays put while Hoot's panel shows.
            .safeAreaInset(edge: .bottom, spacing: 0) { foot }
    }

    /// While Hoot drives a page, its panel takes the list's place (Sidebar.tsx's
    /// `railPanel.state === 'panel'`), drawn instead of the list, not over it (lane T).
    @ViewBuilder private var rail: some View {
        if NativeCopilotRailPanel.shown {
            NativeCopilotRailPanel()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            sidebarList
                .listStyle(.sidebar)
        }
    }

    @ViewBuilder private var foot: some View {
        if model.visibleSidebar != nil {
            VStack(spacing: 8) {
                NativeHooksOffer()
                NativeUpdateBanner(model: model)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
    }

    private var sidebarList: some View {
        List(selection: Binding(get: { model.listSelection }, set: { id in
            // lane B: the Hoot row brings its folded panel back instead (NativeCopilotEntry.swift).
            if id == "hoot" { NativeCopilotEntry.press { model.select(id) } } else { model.select(id) }
        })) {
            if let state = model.visibleSidebar {
                groups(state)
                projects(state)
            }
        }
    }

    private func groups(_ state: SidebarState) -> some View {
                ForEach(state.groups) { group in
                    Section {
                        ForEach(group.items) { item in
                            SidebarRow(item: item)
                                .modifier(SessionRowAnchor(item: item))
                                .tag(item.id as String?)
                                .modifier(ItemMenu(item: item, model: model, projectPath: nil, openWindow: openWindow))
                        }
                    } header: {
                        if let title = group.title { Text(title) }
                    }
                }
    }

    private func projects(_ state: SidebarState) -> some View {
                Section("Open") {
                    ForEach(state.projects) { project in
                        DisclosureGroup(isExpanded: Binding(
                            get: { model.isExpanded(project.id) },
                            set: { model.setExpanded(project.id, $0) })
                        ) {
                            ForEach(project.sessions) { session in
                                SidebarRow(item: session)
                                    .modifier(SessionRowAnchor(item: session))
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

/// Every row: Open in New Window. Session rows also: Close Session
/// (and New Session Here, inside a project).
private struct ItemMenu: ViewModifier {
    let item: SidebarItem
    let model: AppModel
    let projectPath: String?
    let openWindow: OpenWindowAction

    /// Session rows: the web row menu (session-row-menu.ts), in its order and words —
    /// Show at the top / Fold back into the sidebar, Move to New Window, Started by
    /// Hoot — open that turn, Delete — plus New Session Here inside a project.
    func body(content: Content) -> some View {
        content.task { NativeBindMenuStore.shared.start() } // lane E2: Connect browser's rows, ready before the menu opens
        .contextMenu {
            if item.isHeld {
                // A held row has only its ✕ on the rail: "Stop keeping this session".
                Button("Stop keeping this session") { model.closeSession(item.id) }
            } else {
                menu
            }
        }
    }

    @ViewBuilder private var menu: some View {
            if item.kind == .session {
                Button(item.promoted ? "Fold back into the sidebar" : "Show at the top") {
                    model.answerDialog("session-row", "promote", argument: ["id": item.id], closes: false)
                }
                .disabled(!item.promoted && item.promoteBlocked != nil)
                .help(item.promoted ? "" : item.promoteBlocked ?? "")
                if !item.promoted, let blocked = item.promoteBlocked {
                    Text(blocked)
                }
            }
            Button(item.kind == .session ? "Move to New Window" : "Open in New Window") {
                openWindow(value: ScreenRef.forSidebarItem(item))
            }
            if let turn = item.turn {
                Button("Started by Hoot — open that turn") { NativeHootModel.shared.show(turn: turn) }
            }
            if item.kind == .session {
                Divider()
                NativeConnectBrowserMenu(tabId: item.id) // lane E2: Connect browser ▸ (the engine's bind menu)
            }
            if item.kind == .session {
                Divider()
                Button("Delete") { model.closeSession(item.id) }
                if let projectPath {
                    Button("New Session Here") { model.newSession(in: projectPath) }
                }
            }
    }
}

/// Session rows are where Hoot's tours point (lane A's drive anchors).
private struct SessionRowAnchor: ViewModifier {
    let item: SidebarItem

    func body(content: Content) -> some View {
        if case .session = item.kind {
            content.driveAnchor(DriveAnchor.sessionRow(sessionId: item.id).id)
        } else {
            content
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
                if item.isHoot { NativeCopilotEntryChevron() } // lane B
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
        if item.isHoot { return NativeCopilotEntry.help(name: item.title) } // lane B: CopilotEntry's hover sentence
        if let help = item.help { return help }
        return [item.title, item.subtitle, item.status.map { StatusMeaning($0).label }].compactMap { $0 }.joined(separator: " — ")
    }
}

/// A small mark for the states worth a glance; nothing for "Ready" (idle / waiting),
/// matching the web's StatusDot. The web's word is in the tooltip and for VoiceOver.
struct StatusMark: View {
    let status: String?

    var body: some View {
        let meaning = StatusMeaning(status)
        Group {
            switch meaning {
            case .working:
                ProgressView().controlSize(.mini)
            case .needsInput:
                Image(systemName: "hand.raised.fill").font(.caption).foregroundStyle(.orange)
            case .completed:
                Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            case .exited:
                Image(systemName: "stop.circle").font(.caption).foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
            case .ready:
                EmptyView()
            }
        }
        .help(meaning == .ready && status == nil ? "" : meaning.label)
        .accessibilityLabel(meaning.label)
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
