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
        VStack(spacing: 8) {
            if model.visibleSidebar != nil {
                NativeHooksOffer()
                NativeUpdateBanner(model: model)
            }
            SidebarSettingsLine(model: model)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    /// Own selection fill: neutral panel rows, matching terminal paper for sessions.
    private var sidebarList: some View {
        List {
            if let state = model.visibleSidebar {
                groups(state)
                projects(state)
            }
        }
    }

    private func choose(_ id: String) {
        // lane B: the Hoot row brings its folded panel back instead (NativeCopilotEntry.swift).
        if id == "hoot" { NativeCopilotEntry.press { model.select(id) } } else { model.select(id) }
    }

    private func groups(_ state: SidebarState) -> some View {
                ForEach(state.groups) { group in
                    Section {
                        // Alerts is the bell at the foot (SidebarSettingsLine), not a row.
                        ForEach(group.items.filter { $0.id != SidebarSettingsLine.alertsID }) { item in
                            SidebarRow(item: item, selected: model.listSelection == item.id)
                                .padding(.leading, SidebarRow.leadingShift)
                                .modifier(SidebarPick(selected: model.listSelection == item.id, session: item.kind == .session) { choose(item.id) })
                                .modifier(SessionRowAnchor(item: item))
                                .modifier(ItemMenu(item: item, model: model, projectPath: nil, openWindow: openWindow))
                        }
                    } header: {
                        if let title = group.title { Text(title) }
                    }
                }
    }

    /// Projects without DisclosureGroup: one expandable row makes the sidebar's outline
    /// reserve a disclosure column on EVERY row, which pushed all items far in from their
    /// section titles (Asad, 2026-10-07). The project row draws its own chevron instead,
    /// and its sessions sit one step in beneath it.
    private func projects(_ state: SidebarState) -> some View {
                Section("Open") {
                    ForEach(state.projects) { project in
                        ProjectRow(title: project.title, path: project.id, expanded: model.isExpanded(project.id)) {
                            model.setExpanded(project.id, !model.isExpanded(project.id))
                        }
                        .padding(.leading, SidebarRow.leadingShift)
                        .contextMenu {
                            Button("New Session Here") { model.newSession(in: project.id) }
                            Divider()
                            Button("Close Project") { model.closeProject(project.id) }
                        }
                        if model.isExpanded(project.id) {
                            ForEach(project.sessions) { session in
                                // Same left edge as its folder (Asad, 2026-10-07: "same placement").
                                SidebarRow(item: session, selected: model.listSelection == session.id)
                                    .padding(.leading, SidebarRow.leadingShift)
                                    .modifier(SidebarPick(selected: model.listSelection == session.id, session: true) { choose(session.id) })
                                    .modifier(SessionRowAnchor(item: session))
                                    .modifier(ItemMenu(item: session, model: model, projectPath: project.id, openWindow: openWindow))
                            }
                        }
                    }

                    Button(action: model.openProject) {
                        Label {
                            Text("Open Project…").foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "folder.badge.plus").foregroundStyle(.secondary).imageScale(.small)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, SidebarRow.leadingShift)
                    .help("Open a project folder (⌘O)")
                }
    }
}

/// A project in the "Open" section: grey folder and name, a chevron just after the name
/// that turns when its sessions show. The whole row toggles them.
private struct ProjectRow: View {
    let title: String
    let path: String
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                Label {
                    Text(title).foregroundStyle(.secondary).lineLimit(1)
                } icon: {
                    // A filled folder: the outline one read as the terminal icon (Asad, 2026-10-07).
                    Image(systemName: "folder.fill").foregroundStyle(.secondary).imageScale(.small)
                }
                // Right after the name, not at the row's end (Asad, 2026-10-07).
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .animation(.easeOut(duration: 0.15), value: expanded)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(path)
        .accessibilityLabel(title)
        .accessibilityValue(expanded ? "expanded" : "collapsed")
    }
}

/// The rail's last line, as in the old app (Sidebar.tsx `sidebar-settings`): Settings at
/// the left, the alerts bell at the end of the line with a dot while alerts wait. Both put
/// a sheet or window over the work and leave it where it was, so neither is ever drawn as
/// the current row (Asad, 2026-10-07: "same as before, bottom of side panel").
struct SidebarSettingsLine: View {
    static let alertsID = "alerts"
    let model: AppModel
    @State private var overSettings = false
    @State private var overBell = false

    var body: some View {
        HStack(spacing: 2) {
            Button(action: model.requestSettings) {
                Label("Settings", systemImage: "gearshape")
                    .imageScale(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(overSettings ? 0.06 : 0)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .onHover { overSettings = $0 }
            .help("Open Settings (⌘,)")
            .disabled(!model.canRun)

            if let alerts = model.visibleSidebar?.item(id: Self.alertsID) {
                let count = Self.waiting(alerts)
                Button { model.select(Self.alertsID) } label: {
                    Image(systemName: "bell")
                        .imageScale(.small)
                        .overlay(alignment: .topTrailing) {
                            if count > 0 {
                                Circle().fill(Color.accentColor).frame(width: 6, height: 6).offset(x: 3, y: -2)
                            }
                        }
                        .frame(width: 28, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(overBell ? 0.06 : 0)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .onHover { overBell = $0 }
                .help("Alerts")
                .accessibilityLabel(count > 0 ? "Alerts (\(count))" : "Alerts")
            }
        }
    }

    /// How many alerts wait: the row's subtitle leads with the number (IntentWork reads it
    /// the same way); a bare unread mark counts as one.
    static func waiting(_ item: SidebarItem) -> Int {
        Int((item.subtitle ?? "").prefix { $0.isNumber }) ?? (item.unread ? 1 : 0)
    }
}

/// A sidebar row's own selection (the List has none, so it never paints accent blue):
/// a click picks it. Sessions share their paper with the selected top tab.
private struct SidebarPick: ViewModifier {
    let selected: Bool
    var session = false
    let pick: () -> Void

    func body(content: Content) -> some View {
        content
            // Drawn behind the row's own content, grown out to the row's edges: a sidebar
            // List ignores listRowBackground (render check, 2026-10-07).
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected && session ? NativeSessionChrome.ground : Color.primary.opacity(selected ? 0.1 : 0))
                    .padding(.horizontal, -8)
                    .padding(.vertical, -4)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: pick)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { pick() }
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
                openWindow(value: ScreenRef.forSidebarItem(item)) // front-ok: the person's own menu choice
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
    /// Rows sit just inside their section title, not far in (Asad, 2026-10-07).
    static let leadingShift: CGFloat = -7
    let item: SidebarItem
    var selected = false

    var body: some View {
        Label {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .foregroundStyle(selected && item.kind == .session ? NativeSessionChrome.ink : (selected ? Color.primary : Color.secondary))
                        .lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(selected && item.kind == .session ? NativeSessionChrome.secondaryInk : Color(nsColor: .tertiaryLabelColor))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if item.isHoot { NativeCopilotEntryChevron() } // lane B
                StatusMark(status: item.status)
                NativeBRBindChips(kind: item.kind.name, id: item.id, server: AppModel.shared.tabs?.tabs.first { $0.id == item.id }?.server, name: item.title) // lane BR: B1 chips (Sidebar.tsx)
                if item.unread {
                    Circle()
                        .fill(.tint)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("Unread")
                }
            }
        } icon: {
            if item.isHoot {
                HootMark(size: 14) // a step smaller, matching the other side-panel icons
            } else {
                // Grey, not the sidebar's default accent blue (Asad, 2026-10-07). Same symbols.
                Image(systemName: SymbolName.resolve(item.symbol, fallback: item.kind.defaultSymbol))
                    // .primary on a sidebar icon turns into the accent blue; name the colour itself.
                    .foregroundStyle(selected && item.kind == .session ? NativeSessionChrome.accent : (selected ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor)))
                    .imageScale(.small) // a step smaller than the sidebar default (Asad, 2026-10-07)
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
