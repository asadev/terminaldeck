import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TerminalDeckNativeCore

struct SidebarView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var renamed: SidebarItem?
    @State private var renameText = ""
    private let store = SIDEBARProjectStore.shared
    private let names = NativeSessionNames.shared
    private let pagePins = Sidebar21Store.shared

    var body: some View {
        SIDEBARPanel(state: model.visibleSidebar ?? .init(groups: [], projects: [], selectedId: nil),
                     selected: model.listSelection, store: store,
                     // A session chosen here comes to this Mac from a phone that had it (28 Oct).
                     choose: { id in NativeTerminalSessions.shared.chooser.choosing(in: .sessionList) { model.select(id) } },
                     openProject: model.openProject,
                     newSession: model.newSession, closeProject: model.closeProject,
                     openWindow: { item in let open = openWindow, ref = ScreenRef.forSidebarItem(item); NativeFront.whenPersonActs("sidebar-window") { open(value: ref) } },
                     rename: { renamed = $0; renameText = $0.title },
                     close: model.closeSession,
                     stop: { id in SIDEBARCalls.run("session:kill", [id], failure: "That session could not be stopped.") },
                     startSession: model.newSession,
                     renameInPlace: { item, typed in NativeSessionRailContinuity.shared.renamed(item.id, title: typed); _ = names.rename(tabId: item.id, typed: typed) }) {
            SidebarSettingsLine(model: model)
        } hostFailure: {
            NativeHOSTNoticeSlot(model: model)
        }
        .task(id: model.visibleSidebar != nil) {
            guard let state = model.visibleSidebar else { return }
            pagePins.initialize(existingUser: Sidebar21Store.isUpgrade(defaults: .standard,
                dataRoot: model.engine.configuration.engineDataDirectory, state: state), pages: Sidebar21Pages.catalogue(state))
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 264, max: 340)
        .onChange(of: model.visibleSidebar?.projects.map(\.id)) { _, _ in if model.canRun { store.refresh() } }
        .task(id: model.canRun) {
            names.start()
            if model.canRun {
                store.start(); AGTAgentsStore.shared.start(); TasksStore.shared.start()
                await AGTTeamChatHistory.shared.start()
            }
        }
        // The row comes with the button (`presenting`): SwiftUI clears `renamed` before a button's action runs, which
        // is why "Rename" did nothing (Asad, 12 Oct). The name goes straight to the engine, never through the page.
        .alert("Rename session", isPresented: Binding(get: { renamed != nil }, set: { if !$0 { renamed = nil } }), presenting: renamed) { row in
            TextField("Name", text: Binding(get: { renameText }, set: { renameText = String($0.prefix(SessionTitleRules.maxLength)) }))
            Button("Cancel", role: .cancel) {}
            Button("Rename") { _ = names.rename(tabId: row.id, typed: renameText) }
        }
        .alert("Rename session", isPresented: Binding(get: { names.problem != nil }, set: { if !$0 { names.problem = nil } })) {
            Button("OK") { names.problem = nil }
        } message: { Text(names.problem ?? "") }
        .alert("Project colours", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}

/// The exact product rail, also used by isolated render fixtures.
struct SIDEBARPanel<Footer: View, HostFailure: View>: View {
    let state: SidebarState
    let selected: String?
    let store: SIDEBARProjectStore
    let choose: (String?) -> Void
    let openProject: () -> Void
    let newSession: (String) -> Void
    let closeProject: (String) -> Void
    let openWindow: (SidebarItem) -> Void
    let rename: (SidebarItem) -> Void
    let close: (String) -> Void
    let stop: (String) -> Void
    /// The first row, "New session": the app's own new-session action (⌘T).
    var startSession: () -> Void = {}
    /// A session's name typed in its row (double-click or F2 on it, as the web rail had it; Asad, 12 Oct: "before I was
    /// able to change the name by double clicking in the side panel on the name"). Nil: no renaming in place.
    var renameInPlace: ((SidebarItem, String) -> Void)? = nil
    var sessionPins: SIDEBARPins = .shared
    var pagePins: Sidebar21Store = .shared
    @ViewBuilder let footer: () -> Footer
    @ViewBuilder let hostFailure: () -> HostFailure
    /// Blue selection while the window is in front, grey behind (Apple's sidebar).
    @Environment(\.appearsActive) private var appearsActive
    /// The session row showing its name field, if one is.
    @State private var renamingID: String?
    @State private var moreOpen = false
    private var pages: [Sidebar21Page] { Sidebar21Pages.catalogue(state) }
    private var pinnedPages: [Sidebar21Page] { pagePins.ids.compactMap { id in pages.first { $0.id == id } } }

    private var folderProjects: [SidebarProject] { state.projects.filter { $0.id.hasPrefix("/") } }
    /// Asad 11 Oct: an open folder is a project only when it lies in a registered project (made through
    /// the guide); every other open folder is a plain session folder, listed under Independent.
    /// Open folders inside a registered project, then every registered project the page's folder list does not
    /// have (yet): Hoot's projects_add or the team import open a folder without the page hearing of it until it next
    /// reloads, which is why "Terminal Deck" (~/Deck Dev) was missing from his Projects (Asad, 11 Oct).
    private var projectFolders: [SidebarProject] {
        SIDEBARLayout.projectRows(open: folderProjects, registry: registry).filter { !store.folderIsRemoved($0.id) }
    }
    /// The registered project a session belongs to (its own project id, else its folder), or nil for Independent.
    private func sessionProject(_ id: String) -> PROJProject? {
        let saved = store.sessionProjects[id]
        let folder = saved?.cwd ?? SIDEBARLayout.project(for: id, in: state)?.id
        let project = PROJProjects.resolve(projectID: saved?.projectID, folder: folder, projects: registry)
        guard project != PROJProjects.independentID else { return nil }
        return registry.first { $0.id == project }
    }
    /// The registered projects: this store's copy once read, else the list the app published at start.
    private var registry: [PROJProject] { store.projects.isEmpty ? PROJProjects.defaults : store.projects }
    private var running: [SidebarItem] {
        NativeSessionRailContinuity.shared.project(SIDEBARLayout.running(state, liveIDs: store.liveIDs ?? [],
                                                                         started: NativeSessionRailContinuity.shared.started(store.started))).filter { !NativeChatArchives.shared.contains($0.id) }
    }
    private func item(_ id: String) -> SidebarItem {
        let existing = state.item(id: id)
        let titles = ["hoot": "Hoot", "agents-all": "Agents", "tasks": "Tasks", "artifacts": "Artifacts", "servers": "Servers", "devices": "Devices", "simulators": "Simulators", "receiver": "Receiver", "mcp": "MCP servers", "store": "Store"]
        let symbols = ["agents-all": "person.3", "tasks": "list.bullet", "artifacts": "doc.richtext", "servers": "server.rack", "devices": "laptopcomputer.and.iphone", "simulators": "iphone", "receiver": "antenna.radiowaves.left.and.right", "mcp": "puzzlepiece.extension", "store": "bag"]
        return .init(id: id, title: titles[id] ?? id, symbol: symbols[id] ?? existing?.symbol,
                     kind: id == "hoot" ? .hoot : .panel, unread: existing?.unread ?? false,
                     status: existing?.status, subtitle: nil, help: existing?.help)
    }
    var body: some View {
        let sessionAgents = SIDEBARSessionAgents.all()
        let sessions = visibleRunning
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    newSessionRow
                    row(item("hoot"))
                    ForEach(pinnedPages.filter { $0.id != Sidebar21Pages.projectsID }) { page in
                        row(pageItem(page)).draggable("sidebar-page:" + page.id)
                            .dropDestination(for: String.self) { values, _ in reorder(values, to: page.id) }
                    }
                    Button { moreOpen.toggle() } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.right").foregroundStyle(.secondary).frame(width: 18)
                            Text("More"); Spacer(minLength: 0)
                        }.padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: DeckSidebar.rowHeight, alignment: .leading)
                            .contentShape(.rect)
                    }.buttonStyle(DeckSidebarRowStyle())
                        .accessibilityLabel("More pages")
                        .popover(isPresented: $moreOpen, arrowEdge: .trailing) {
                            Sidebar21More(pages: pages, pins: pagePins, choose: { choose($0) }, dismiss: { moreOpen = false })
                                .padding(4)
                        }
                    if pinnedPages.contains(where: { $0.id == Sidebar21Pages.projectsID }) { projectsSection }
                    if !sessions.isEmpty || hostFailed {
                        header("Running")
                        ForEach(NativeSessionRailContinuity.shared.identified(sessions)) { row in
                            sessionRow(row.item, agents: sessionAgents)
                        }
                    }
                NativeChatArchivedRows(state: state, open: choose)
                hostFailure()
                }
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 8)
            }
            .frame(minHeight: 0)
            DeploySidebarPill()   // DEPLOY-PIPELINE: only while something deploys
            NativeUpdateCard()    // release 27: a newer GitHub release, just above Settings; only while there is one
            footer().frame(height: 44).padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
        }
        .font(.system(size: 13))
        // ⌃⌘↑ / ⌃⌘↓: previous / next row (SHELL-SPEC §4).
        .background {
            Group {
                Button("Previous row") { step(-1) }.keyboardShortcut(.upArrow, modifiers: [.control, .command])
                Button("Next row") { step(1) }.keyboardShortcut(.downArrow, modifiers: [.control, .command])
            }
            .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true).allowsHitTesting(false)
        }
        .frame(minWidth: DeckTokens.Metrics.sidebarMin, idealWidth: DeckTokens.Metrics.sidebarIdeal,
               maxWidth: DeckTokens.Metrics.sidebarMax, minHeight: 0, maxHeight: .infinity)
        // The toolbar and this panel use the same material, with no overlapping root blur.
        .background(DeckSidebarMaterial().ignoresSafeArea())
    }
    private var newSessionRow: some View {
        Button(action: startSession) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil").foregroundStyle(.secondary).frame(width: 18)
                Text("New session")
                Spacer(minLength: 0)
            }.padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: DeckSidebar.rowHeight, alignment: .leading)
                .contentShape(.rect)
        }.buttonStyle(DeckSidebarRowStyle()).help("New session (⌘T)")
    }
    @ViewBuilder private var projectsSection: some View {
        header("Projects", add: newProject)
            .draggable("sidebar-page:" + Sidebar21Pages.projectsID)
            .dropDestination(for: String.self) { values, _ in reorder(values, to: Sidebar21Pages.projectsID) }
        if projectFolders.isEmpty {
            Button(action: newProject) {
                Text("New project…").foregroundStyle(.secondary).padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: DeckSidebar.rowHeight, alignment: .leading).contentShape(.rect)
            }.buttonStyle(DeckSidebarRowStyle())
        }
        ForEach(projectFolders) { project in projectRow(project) }
    }
    private func pageItem(_ page: Sidebar21Page) -> SidebarItem {
        let existing = state.item(id: page.id)
        return .init(id: page.id, title: page.title, symbol: page.symbol, kind: .panel,
                     unread: existing?.unread ?? false, status: existing?.status, help: existing?.help)
    }
    private func reorder(_ values: [String], to target: String) -> Bool {
        guard let value = values.first, value.hasPrefix("sidebar-page:") else { return false }
        return pagePins.move(String(value.dropFirst("sidebar-page:".count)), to: target)
    }
    /// Every row in drawn order, for keyboard stepping.
    private var pins: SIDEBARPins { sessionPins }
    /// The Running section and keyboard navigation share this exact order.
    private var visibleRunning: [SidebarItem] {
        let sessions = running
        return sessions.filter { pins.isPinned($0.id) } + sessions.filter { !pins.isPinned($0.id) }
    }
    /// Running sessions that are not pinned (a pinned session shows only under Pinned).
    private var unpinnedRunning: [SidebarItem] { running.filter { !pins.isPinned($0.id) } }

    /// A session as the phone's side panel draws it (Asad, 29 Oct): who works in it with its project's badge, its own
    /// name, "Agent · AI" under it; the status dot at the end, ⋯ (and right-click) for the same menu.
    private func sessionRow(_ session: SidebarItem, agents: [String: AGTAgent]) -> some View {
        let title = SIDEBARSessionLine.title(session, store: store)
        return SIDEBARSessionRow(session: session, title: title,
                          provider: store.sessionProviders[session.id] ?? (session.id.hasPrefix("server ") ? "shell" : nil),
                          chat: store.sessionChats.contains(session.id),
                          project: sessionProject(session.id),
                          highlighted: Sidebar21Pages.selection(selected) == session.id,
                          onAccent: isSelected(session.id),
                          selection: AnyView(selection(session.id)),
                          open: { choose(session.id) },
                          editing: renamingID == session.id,
                          beginRename: renamesInPlace(session) ? { renamingID = session.id } : nil,
                          endRename: { typed in
                              if renamingID == session.id { renamingID = nil }
                              if let typed { renameInPlace?(session, typed) }
                          },
                          // Keep an assigned agent's profile icon in every Mac session list.
                          agent: NativeSessionRowIdentity(id: session.id).agent) {
            sessionMenu(session)
        }
        .driveAnchor(DriveAnchor.sessionRow(sessionId: session.id).id)
        .nativePaneDrag(.tab(tabId: session.id), title: title)
        .contextMenu { sessionMenu(session) }
    }

    /// Sessions on this Mac or a paired one; not a shell on a server (it shows the server's name), not a held row.
    private func renamesInPlace(_ session: SidebarItem) -> Bool {
        guard renameInPlace != nil, !session.isHeld, let target = SessionTarget(tabId: session.id) else { return false }
        if case .server = target { return false }
        return true
    }

    /// The one session menu, for right-click and ⋯ alike.
    @ViewBuilder private func sessionMenu(_ session: SidebarItem) -> some View {
        Button(pins.isPinned(session.id) ? "Unpin" : "Pin") { pins.toggle(session.id) }
        Divider()
        Button("Open in new window") { openWindow(session) }
        Button("Rename…") { rename(session) }
        NativeConnectBrowserMenu(tabId: session.id)
        Divider()
        if running.contains(where: { $0.id == session.id }) { Button("Stop") { stop(session.id) } }
        Button("Delete", role: .destructive) { close(session.id) } // the app's own close, with its confirmation
    }

    var rowIDs: [String] {
        SIDEBARVisibleRows.ids(pages: pinnedPages.map(\.id), projects: projectFolders.map(\.id),
                               sessions: visibleRunning.map(\.id))
    }
    private func step(_ delta: Int) {
        let ids = rowIDs
        guard !ids.isEmpty else { return }
        let current = Sidebar21Pages.selection(selected).flatMap { ids.firstIndex(of: $0) }
        let next = current.map { min(max($0 + delta, 0), ids.count - 1) } ?? (delta > 0 ? 0 : ids.count - 1)
        choose(ids[next])
    }
    // A failed host contributes its one-line row even with no running sessions.
    private var hostFailed: Bool {
        guard let host = NativeCompositionINT2HOSTCore.current else { return false }
        return NativeHOSTNotice.shows(host.notice, dismissed: NativeHOSTNoticeDismissals.shared.dismissedReason)
    }
    private func projectName(_ project: SidebarProject?) -> String {
        guard let project else { return "Independent" }
        return project.id.hasPrefix("/") ? URL(fileURLWithPath: project.id).lastPathComponent : project.title
    }
    private func colour(_ path: String?) -> String {
        SIDEBARLayout.colour(path: path, projects: folderProjects, registry: store.projects)
    }
    private func isSelected(_ id: String) -> Bool { Sidebar21Pages.selection(selected) == id && appearsActive }
    private func selection(_ id: String) -> some View {
        RoundedRectangle(cornerRadius: DeckSidebar.rowRadius)
            .fill(Sidebar21Pages.selection(selected) == id ? DeckSidebar.selectionFill(active: appearsActive) : .clear)
    }
    private func header(_ title: String, add: (() -> Void)? = nil) -> some View {
        HStack(spacing: 0) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            if let add {
                Button(action: add) { Image(systemName: "plus").frame(width: 28, height: 28).contentShape(.rect) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("New project…").accessibilityLabel("New project")
            }
        }.frame(height: 28).padding(.top, 12).padding(.horizontal, 8)
    }
    private func row(_ item: SidebarItem) -> some View {
        let on = isSelected(item.id)
        return Button { choose(item.id) } label: {
            HStack(spacing: 8) {
                Group {
                    if item.isHoot { AgentAvatar(icon: .symbol("bird"), size: 18, hoot: true) }
                    else { Image(systemName: item.symbol).foregroundStyle(on ? Color.white : Color.secondary) }
                }.frame(width: 18)
                Text(item.title).lineLimit(1).foregroundStyle(on ? Color.white : Color.primary)
                Spacer(minLength: 0)
                if item.id == "agents-all", AGTAgentsStore.shared.counts.working > 0 {
                    Text("\(AGTAgentsStore.shared.counts.working) working").font(.system(size: 11)).foregroundStyle(on ? Color.white.opacity(0.85) : Color.secondary)
                } else if item.id == "tasks", let tasks = TasksStore.shared.state?.tasks {
                    let count = tasks.filter { $0.archivedAt == nil && $0.deletedAt == nil && $0.crmStatus != "Done" }.count
                    if count > 0 { Text("\(count)").monospacedDigit().foregroundStyle(on ? Color.white.opacity(0.85) : Color.secondary) }
                } else if item.unread || (item.id == "servers" && NativeServersModel.shared.states.values.contains { $0.link == .failed || NativeMACHINESServersDashboard.stopped($0) > 0 }) {
                    Circle().fill(Color.orange).frame(width: 6, height: 6).accessibilityLabel("Needs a look")
                }
            }
            .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: DeckSidebar.rowHeight, alignment: .leading)
            .background(selection(item.id)).contentShape(.rect)
        }
        .buttonStyle(DeckSidebarRowStyle())
        .contextMenu {
            Button("Open") { choose(item.id) }
            if item.id == "servers" { Button("Add a server…") { choose("servers:add") } }
            if item.id == "devices" { Button("Pair a device…") { choose("devices:pair") } }
        }
        .accessibilityAddTraits(Sidebar21Pages.selection(selected) == item.id ? .isSelected : [])
    }
    private func projectRow(_ project: SidebarProject) -> some View {
        let id = "project:" + project.id
        let projectID = PROJProjects.resolve(projectID: nil, folder: project.id, projects: registry)
        let count = unpinnedRunning.filter {
            sessionProject($0.id)?.id == projectID
        }.count
        let on = isSelected(id)
        let listed = folderProjects.contains { $0.id == project.id }
        return Button {
            if !listed { SIDEBARCalls.run("projects:add", [project.id], failure: "That folder could not be added to the recent list.") }
            choose(id)
        } label: {
            HStack(spacing: 8) {
                Group {
                    ProjectLogoView(project: registry.first { $0.id == projectID } ?? SHELLRoutes.project(forPath: project.id), name: project.title, size: 16, onAccent: on)
                }.frame(width: 18)
                Text(projectName(project)).lineLimit(1).foregroundStyle(on ? Color.white : Color.primary)
                Spacer(minLength: 0)
                if count > 0 { Text("\(count)").monospacedDigit().foregroundStyle(on ? Color.white.opacity(0.85) : Color.secondary) }
            }.padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: DeckSidebar.rowHeight, alignment: .leading)
                .background(selection(id)).contentShape(.rect)
        }
        .buttonStyle(DeckSidebarRowStyle())
        .help(project.id)
        .contextMenu {
            Button("New session here") { newSession(project.id) }
            Button("Project settings…") { choose(id + ":settings") }
            Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.id) }
            Button("Choose logo…") { chooseLogo(registry.first { $0.id == projectID } ?? SHELLRoutes.project(forPath: project.id)) }
            Divider()
            Button("Remove from sidebar") { closeProject(project.id) }
        }
    }
    private func newProject() { PROJGuideWindow.open() }
    /// The image picker itself, as on the project's page (it used to open the settings window instead).
    private func chooseLogo(_ project: PROJProject) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .svg, .icns, .ico]
        panel.begin { response in
            MainActor.assumeIsolated { if response == .OK, let url = panel.url { store.changeLogo(url, project: project) } }
        }
    }
}

/// Side-panel engine calls whose refusal the person must see (a failed Stop used to show nothing).
@MainActor
enum SIDEBARCalls {
    static func run(_ channel: String, _ args: [Any?], failure: String) {
        Task {
            do {
                if try await EngineBridge.shared.invoke(channel, args) as? Bool == false { AppModel.shared.buttonActions.problem = failure }
            } catch {
                AppModel.shared.buttonActions.problem = failure + ((error as? NativeRPCError).map { " " + $0.message } ?? "")
            }
        }
    }
}

struct SidebarSettingsLine: View {
    let model: AppModel
    var body: some View {
        HStack(spacing: 8) {
            Button(action: model.requestSettings) {
                Label("Settings", systemImage: "gearshape").frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(.rect)
            }.buttonStyle(DeckSidebarRowStyle()).help("Open Settings (⌘,)").disabled(!model.canRun)
            // Compact, at the right end of the row where the bell was (no in-app notifications now).
            Button { model.requestDevicesWindow() } label: {
                Image(systemName: "laptopcomputer.and.iphone").frame(width: 28, height: 28).contentShape(.rect)
            }.buttonStyle(DeckSidebarIconStyle()).fixedSize().help("Devices").accessibilityLabel("Devices")
        }.foregroundStyle(.secondary)
    }
}

struct SidebarRow: View {
    static let leadingShift: CGFloat = 0
    let item: SidebarItem
    var selected = false
    var body: some View {
        HStack(spacing: 8) {
            if item.kind == .session { NativeSessionRowIdentity(id: item.id).picture(surface: DeckTokens.frame) }
            else if item.isHoot { AgentAvatar(icon: .symbol("bird"), size: 18, hoot: true).frame(width: 18) }
            else { Image(systemName: SymbolName.resolve(item.symbol, fallback: item.kind.defaultSymbol)).foregroundStyle(.secondary).frame(width: 18) }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1)
                if let subtitle = item.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
            StatusMark(status: item.status)
        }.font(.system(size: 13)).frame(maxWidth: .infinity, minHeight: item.kind == .session ? 40 : 28, alignment: .leading).contentShape(.rect)
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
            case .working: ProgressView().controlSize(.mini)
            case .needsInput: Image(systemName: "hand.raised.fill").font(.caption).foregroundStyle(.orange)
            case .completed: Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            case .exited: Image(systemName: "stop.circle").font(.caption).foregroundStyle(.secondary)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
            case .ready: EmptyView()
            }
        }.help(meaning == .ready && status == nil ? "" : meaning.label).accessibilityLabel(meaning.label)
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

/// Pinned sessions, kept across restarts (Asad 10 Oct: "pin … on the top regardless of their folder").
@MainActor @Observable
final class SIDEBARPins {
    static let shared = SIDEBARPins()
    static let key = "sidebar.pinnedSessions"
    static let stableKey = "sidebar.pinnedTabs.v2"
    private var keys: [String]
    private var sessionKeys: [String: String] = [:]
    private var currentSessions: [String: String] = [:]
    var ids: [String] { keys.map { currentSessions[$0] ?? $0 } }
    @ObservationIgnored private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keys = defaults.stringArray(forKey: Self.stableKey) ?? defaults.stringArray(forKey: Self.key) ?? []
    }
    /// tabKey survives a keeper restart. A process id does not. Unknown old pins stay saved without guessing.
    func observe(_ row: [String: Any]) {
        guard let id = row["id"] as? String, let key = row["tabKey"] as? String, !key.isEmpty else { return }
        sessionKeys[id] = key
        currentSessions[key] = id
        if keys.contains(id), id != key {
            keys = unique(keys.map { $0 == id ? key : $0 }); save()
        }
    }
    func isPinned(_ id: String) -> Bool { keys.contains(sessionKeys[id] ?? id) }
    func replaced(_ old: String, with next: String) {
        NativeChatArchives.shared.replaced(old, with: next)
        let previous = sessionKeys[old] ?? old
        let key = sessionKeys[next] ?? sessionKeys[old] ?? next
        sessionKeys[next] = key
        currentSessions[key] = next
        guard keys.contains(previous) else { return }
        keys = unique(keys.map { $0 == previous ? key : $0 }); save()
    }
    func toggle(_ id: String) {
        let key = sessionKeys[id] ?? id
        if let index = keys.firstIndex(of: key) { keys.remove(at: index) } else { keys.append(key) }
        save()
    }
    private func save() { defaults.set(keys, forKey: Self.stableKey) }
    private func unique(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        return ids.filter { seen.insert($0).inserted }
    }
}

/// A session row, as the phone's side panel draws it (Asad, 29 Oct: "do the same for the Mac app too, they are too
/// separate"): one picture (the agent, or a plain chat/shell glyph, with the project's badge on its
/// corner), the session's own name and "Agent · AI" under it in one tight block; at the end its status dot (blue
/// working, grey idle; orange/red keep their meaning), which gives way to ⋯ while the pointer is on the row.
private struct SIDEBARSessionRow<MenuItems: View>: View {
    let session: SidebarItem
    /// The name the phones show for it (`SIDEBARSessionLine.title`).
    let title: String
    /// The session's AI ("claude", "codex"…), for the grey line under its title.
    var provider: String?
    var chat = false
    /// The session's project: its logo is the badge on the picture's corner. Nil for Independent sessions.
    var project: PROJProject?
    let highlighted: Bool
    let onAccent: Bool
    let selection: AnyView
    let open: () -> Void
    /// The row as its name field (double-click or F2 opened it).
    var editing = false
    /// Opens the field; nil: this row cannot be renamed in place.
    var beginRename: (() -> Void)? = nil
    /// The field closed: the new name, or nil (Escape, or left untouched).
    var endRename: (String?) -> Void = { _ in }
    /// The agent the session was started as or works as (its picture, and its name on the second line). Nil: the
    /// AI's own session, shown with a plain chat/shell glyph and its AI's name.
    var agent: AGTAgent? = nil
    @ViewBuilder let menu: () -> MenuItems
    @State private var hovering = false

    static var pictureSize: CGFloat { 26 }
    static var minHeight: CGFloat { 40 }

    private var subtitle: String? { SIDEBARSessionLine.subtitle(agent: agent?.name, ai: SIDEBARSessionLine.aiName(provider)) }

    var body: some View {
        if editing {
            // The picture stays, so the name does not jump sideways when the field opens.
            HStack(spacing: 10) {
                picture
                SIDEBARRenameField(title: title, end: endRename)
            }
            .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: Self.minHeight, alignment: .leading)
        } else {
            row
        }
    }

    private var picture: some View {
        SIDEBARSessionPicture(agent: agent, provider: provider, project: project, onAccent: onAccent, size: Self.pictureSize, chat: chat, mutedSelected: highlighted && !onAccent)
    }

    private var row: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                picture
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).fontWeight(.medium).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(onAccent ? Color.white : Color.primary)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                            .foregroundStyle(onAccent ? Color.white.opacity(0.85) : Color.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 4)
                Color.clear.frame(width: 22, height: 1) // the dot, or ⋯
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: Self.minHeight, alignment: .leading)
            .background(selection).contentShape(.rect)
        }
        .buttonStyle(DeckSidebarRowStyle())
        .help(subtitle.map { title + " — " + $0 } ?? title)
        .overlay(alignment: .trailing) {
            ZStack {
                // One shared dot: it pulses slowly while the session works (SessionStatusDot).
                SessionStatusDot(status: chat && NativeHootChatModel.queueOwner(session.id)?.workingState.active == true
                    && NativeHootChatModel.queueOwner(session.id)?.pending.isEmpty == true ? "working" : session.status, onAccent: onAccent)
                    .opacity(hovering ? 0 : 1)
                Menu { menu() } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                        .frame(width: 22, height: 22).contentShape(.rect)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(onAccent ? Color.white : Color.secondary)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
                .help("Pin, rename, stop or delete")
                .accessibilityLabel("More for " + title)
            }
            .frame(width: 22, height: 22)
            .padding(.trailing, 6)
        }
        .onHover { hovering = $0 }
        // Double-click the name to rename it in place; the single click still opens the session first.
        .simultaneousGesture(TapGesture(count: 2).onEnded { beginRename?() })
        // F2 from the keyboard (Return on a row opens it).
        .onKeyPress(keys: [KeyEquivalent(Character(UnicodeScalar(0xF705)!))]) { _ in
            guard let beginRename else { return .ignored }
            beginRename(); return .handled
        }
        .accessibilityAction(named: "Rename") { beginRename?() }
    }
}

/// Which agent each session row names on its second line: a saved agent the session was started as (its live rows),
/// or the lead a session works as (lead adoption: opened by the person in a project led by a saved agent).
@MainActor
enum SIDEBARSessionAgents {
    static func all() -> [String: AGTAgent] {
        let store = AGTAgentsStore.shared
        let rows = store.live.filter { $0.sessionID != nil }
        let agents = store.agents
        var result: [String: AGTAgent] = [:]
        for session in AGTTeamChatHistory.shared.explicitOwners.keys {
            if let agent = store.sender(of: session) { result[session] = agent }
        }
        for row in rows {
            guard let session = row.sessionID, result[session] == nil else { continue }
            if let saved = agents.first(where: { $0.kind == .profile && $0.liveIDs.contains(row.id) }) { result[session] = saved; continue }
            guard let seated = agents.first(where: { $0.kind == .session && $0.sitsIn != nil && $0.liveIDs.contains(row.id) }) else { continue }
            // Works as the lead: the lead's own profile (its picture), else the seat as the Agents page names it.
            if let project = AGTLeads.worksAsLead(seated), let lead = AGTSeats.lead(of: project), lead.kind == .agent,
               let profile = agents.first(where: { $0.kind == .profile && $0.profileID == lead.id }) {
                result[session] = profile
            } else if seated.name != seated.sessionTitle {
                result[session] = seated
            }
        }
        return result
    }
}

/// A session's name as a field in its row (the web rail's rename, `Sidebar.tsx`): Return or a click anywhere else
/// keeps the name, Escape keeps the old one, an untouched field writes nothing, at most 40 characters (the rule
/// every title follows). The terminal of a session just opened takes the keyboard a moment after the field
/// appears; a focus loss nobody caused is taken back rather than read as "clicked away".
private struct SIDEBARRenameField: View {
    let title: String
    let end: (String?) -> Void
    @State private var draft: String
    @State private var watch = SIDEBARRenameWatch()
    @FocusState private var focused: Bool

    init(title: String, end: @escaping (String?) -> Void) {
        self.title = title
        self.end = end
        _draft = State(initialValue: title)
    }

    var body: some View {
        TextField("", text: Binding(get: { draft }, set: { draft = String($0.prefix(SessionTitleRules.maxLength)) }))
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .accessibilityLabel("New name for \(title)")
            .onSubmit { finish(save: true) }
            .onExitCommand { finish(save: false) }
            .onChange(of: focused) { _, now in
                guard !now, !watch.closed else { return }
                if watch.acted { finish(save: true) } else { Task { @MainActor in focused = true } }
            }
            .onAppear {
                watch.start(clickedAway: { finish(save: true) })
                Task { @MainActor in focused = true }
            }
            .onDisappear { watch.stop() }
    }

    private func finish(save: Bool) {
        guard !watch.closed else { return }
        watch.closed = true
        watch.stop()
        end(save && draft != title ? draft : nil)
    }
}

/// What the person does while a row's name field is open: any key or click counts as theirs (the web rail's
/// `userActed`), and a click outside the field closes it keeping the name, as Finder's sidebar does.
@MainActor
private final class SIDEBARRenameWatch {
    var acted = false
    var closed = false
    private var monitor: Any?

    func start(clickedAway: @escaping @MainActor () -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            self.acted = true
            if event.type != .keyDown, !Self.insideField(event) { Task { @MainActor in clickedAway() } }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// A click on the field being edited (its text, its border), not elsewhere.
    private static func insideField(_ event: NSEvent) -> Bool {
        guard let window = event.window, let content = window.contentView,
              let editor = window.firstResponder as? NSTextView, let field = editor.delegate as? NSView else { return false }
        // hitTest takes a point in the view's superview's coordinates.
        let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        guard let hit = content.hitTest(point) else { return false }
        return hit === field || hit === editor || hit.isDescendant(of: field)
    }
}

/// Selectable rows in the same section order used by SIDEBARPanel.
enum SIDEBARVisibleRows {
    static func ids(pages: [String], projects: [String], sessions: [String]) -> [String] {
        ["hoot"] + pages.filter { $0 != Sidebar21Pages.projectsID }
            + (pages.contains(Sidebar21Pages.projectsID) ? projects.map { "project:" + $0 } : [])
            + sessions
    }
}
