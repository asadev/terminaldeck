import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TerminalDeckBackend
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
                     renameInPlace: { item, typed in NativeSessionRailContinuity.shared.renamed(item.id, title: typed); _ = names.rename(tabId: item.id, typed: typed) },
                     cloudLine: true) {
            SidebarSettingsLine(model: model)
        } hostFailure: {
            NativeHOSTNoticeSlot(model: model)
        }
        .task(id: model.visibleSidebar != nil) {
            guard let state = model.visibleSidebar else { return }
            pagePins.initialize(existingUser: Sidebar21Store.isUpgrade(defaults: .standard,
                dataRoot: model.engine.configuration.engineDataDirectory, state: state), pages: Sidebar21Pages.catalogue(state, cloud: NativeCloudDisplayGate.shared.shows))
            if NativeCloudDisplayGate.shared.shows { pagePins.addCloudOnce() }
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 264, max: 340)
        // Cloud joins the side panel once, the first time this copy can use Cloud (a sign-in later counts too).
        .onChange(of: NativeCloudAccount.shared.snapshot.phase) { _, _ in
            if NativeCloudDisplayGate.shared.shows { pagePins.addCloudOnce() }
        }
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
    /// The one Cloud status line in the bottom bar (status-line lane, 14 Nov). Off in isolated fixtures.
    var cloudLine = false
    @ViewBuilder let footer: () -> Footer
    @ViewBuilder let hostFailure: () -> HostFailure
    /// Blue selection while the window is in front, grey behind (Apple's sidebar).
    @Environment(\.appearsActive) private var appearsActive
    /// The session row showing its name field, if one is.
    @State private var renamingID: String?
    @State private var moreOpen = false
    @State private var hootLineVisible = true
    /// A waiting page no session row and no group header shows (Hoot's, a Hoot task's, a background agent's).
    private var hootLinePage: String? {
        NativeWaitingPages.pageForHootLine(sessionRows: Set(running.map(\.id)).union(NativeChatArchives.shared.ids))
    }
    private var pages: [Sidebar21Page] { Sidebar21Pages.catalogue(state, cloud: NativeCloudDisplayGate.shared.shows) }
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
        let cloud = NativeCloudChats.shared
        return NativeSessionRailContinuity.shared.project(NativeRemoteSessionRows.running(state, localIDs: store.liveIDs ?? [],
            links: NativeMachineLinks.shared.snapshot, liveRefs: cloud.liveRefs, moves: cloud.moves,
            started: NativeSessionRailContinuity.shared.started(store.started))).filter { !NativeChatArchives.shared.contains($0.id) }
    }
    /// These exact rows are drawn below Running; their Retry uses the same key-only action as the renderer.
    var heldRows: [SIDEBARHeldSessionRow] {
        SIDEBARLayout.held(state).map { item in
            let project = SIDEBARLayout.project(for: item.id, in: state)
            let folder = project.map { URL(fileURLWithPath: $0.id).lastPathComponent }
            return SIDEBARHeldSessionRow(session: item, folder: folder, retry: { choose(item.id) })
        }
    }

    private func item(_ id: String) -> SidebarItem {
        let existing = state.item(id: id)
        let titles = ["hoot": "Hoot", "agents-all": "Agents", "tasks": "Tasks", "artifacts": "Artifacts", "servers": "Servers", "code": "Code", "devices": "Devices", "simulators": "Simulators", "receiver": "Receiver", "mcp": "MCP servers", "store": "Store"]
        let symbols = ["agents-all": "person.3", "tasks": "list.bullet", "artifacts": "doc.richtext", "servers": "server.rack", "code": "chevron.left.forwardslash.chevron.right", "devices": "laptopcomputer.and.iphone", "simulators": "iphone", "receiver": "antenna.radiowaves.left.and.right", "mcp": "puzzlepiece.extension", "store": "bag"]
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
                        // B1: Hoot's line out of sight moves its raised hand to the line below the list.
                        .onScrollVisibilityChange(threshold: 0.5) { hootLineVisible = $0 }
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
                    // Sessions in the Cloud (15 Nov): his other machines' sessions sit with this Mac's own, each beside
                    // the same project's. 18 Nov (Asad: "we don't need this earlier chats here"): no "Earlier chats" lines in
                    // this list; their page is opened from a session's or a project's menu.
                    let lines = runningLines(sessions)
                    if !lines.isEmpty || hostFailed {
                        header("Running")
                        ForEach(lines, id: \.id) { line in
                            switch line.entry {
                            case .own:
                                if let item = line.item { sessionRow(item, agents: sessionAgents, press: livePress(line)) }
                            case .other(let row):
                                SIDEBARCloudSessionRow(row: row, project: registry.first { $0.id == row.project?.cloudRef },
                                                       highlighted: Sidebar21Pages.selection(selected) == line.entry.id,
                                                       onAccent: isSelected(line.entry.id), selection: AnyView(selection(line.entry.id)),
                                                       open: { choose(line.entry.id) })
                            case .earlier:
                                EmptyView() // never listed (18 Nov); `runningLines` asks for none
                            }
                        }
                    }
                    if !heldRows.isEmpty {
                        header("Not reopened")
                        ForEach(heldRows) { row in row }
                    }
                NativeChatArchivedRows(state: state, open: choose,
                                       waiting: NativeWaitingPages.page(forSessions: Set(NativeChatArchives.shared.ids)))
                hostFailure()
                }
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 8)
            }
            .frame(minHeight: 0)
            if !hootLineVisible, let page = hootLinePage { SIDEBARWaitingLine(page: page) }
            DeploySidebarPill()   // DEPLOY-PIPELINE: only while something deploys
            NativeUpdateCard()    // release 27: a newer GitHub release, just above Settings; only while there is one
            // The bottom bar: his profile and the gear, unchanged. Owner, 15 Nov: "I don't want to have this big sentence
            // sitting in my side panel at all. Just keep it inside the settings": the Cloud line and its Sync now are at
            // the top of Settings › Cloud now. What kept the line current (and the Cloud item's small mark) still runs
            // here, drawing nothing.
            VStack(spacing: 0) {
                footer().frame(height: 44)
            }
            .background { if cloudLine { NativeCloudStatusWatch() } }
            .padding(.horizontal, 12)
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
        // The Cloud item's small mark is all the side panel says about Cloud: only when something really needs him.
        let cloudMark = cloudLine && page.id == Sidebar21Pages.cloudID ? NativeCloudStatusWatch.mark(NativeCloudStatusLineModel.shared.current()) : nil
        return .init(id: page.id, title: page.title, symbol: page.symbol, kind: .panel,
                     unread: existing?.unread ?? false, status: cloudMark?.status ?? existing?.status, help: cloudMark?.help ?? existing?.help)
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
    /// One line of the Running list: this Mac's own session (keeping its continuity identity, so a rename or a restart
    /// never redraws it as a new row), another machine's, or a project's "Earlier chats".
    struct RunningLine { let id: String; let entry: SIDEBARCloudRows.Entry; let item: SidebarItem?; var live = false }
    private func runningLines(_ sessions: [SidebarItem]) -> [RunningLine] {
        let identified = NativeSessionRailContinuity.shared.identified(sessions)
        let rows = Dictionary(identified.map { ($0.item.id, $0) }, uniquingKeysWith: { first, _ in first })
        let cloud = NativeCloudChats.shared
        // One row per session (15 Nov): a Cloud row whose live twin is open here already is not listed again.
        // 19 Nov free plan: a free account's other computers' sessions come live from its computers (below), never Cloud rows.
        let free = NativeCloudAccount.shared.snapshot.subscription.limitsRemoteToSessions
        let others = NativeCloudLiveChoice.shownOthers(NativeCloudOffers.shows(.otherComputerSessions) && !free ? cloud.others : [], ownIDs: Set(sessions.map(\.id)), links: NativeMachineLinks.shared.snapshot, liveRefs: cloud.liveRefs)
        let entries = SIDEBARCloudRows.merge(own: sessions.map { (id: $0.id, project: sessionProject($0.id)?.id) }, others: others,
                                              earlier: [])
        let lines: [RunningLine] = entries.map { entry in
            if case .own(let id) = entry, let row = rows[id] { return RunningLine(id: row.id, entry: entry, item: row.item) }
            return RunningLine(id: entry.id, entry: entry, item: nil)
        }
        guard free else { return lines }
        let live = NativeRemoteSessionRows.liveOthers(links: NativeMachineLinks.shared.snapshot, shown: Set(sessions.map(\.id)))
        return lines + live.map { RunningLine(id: $0.id, entry: .own($0.id), item: $0, live: true) }
    }
    /// A free account's live row of another computer opens that session there (its tab is made by the machine action).
    private func livePress(_ line: RunningLine) -> (() -> Void)? {
        guard line.live, let item = line.item else { return nil }
        return { NativeMachineSessionRoute.open(tabId: item.id) }
    }
    /// Running sessions that are not pinned (a pinned session shows only under Pinned).
    private var unpinnedRunning: [SidebarItem] { running.filter { !pins.isPinned($0.id) } }

    /// A session: its type icon and its own name (Asad, 15 Nov); the orange dot only while it needs him, ⋯ (and
    /// right-click) for the same menu.
    private func sessionRow(_ session: SidebarItem, agents: [String: AGTAgent], press: (() -> Void)? = nil) -> some View {
        let title = SIDEBARSessionLine.title(session, store: store)
        return SIDEBARSessionRow(session: session, title: title,
                          chat: store.sessionChats.contains(session.id) || NativeRemoteSessionRows.chat(session.id, links: NativeMachineLinks.shared.snapshot)
                            || NativeTerminalSessions.shared.isChat(session.id),
                          highlighted: Sidebar21Pages.selection(selected) == session.id,
                          onAccent: isSelected(session.id),
                          selection: AnyView(selection(session.id)),
                          // B2 (MAC-NEXT-13): the row opens the session as always; only the raised hand opens a waiting page.
                          open: press ?? { choose(session.id) },
                          editing: renamingID == session.id,
                          beginRename: renamesInPlace(session) ? { renamingID = session.id } : nil,
                          endRename: { typed in
                              if renamingID == session.id { renamingID = nil }
                              if let typed { renameInPlace?(session, typed) }
                          }) {
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
        // 18 Nov: the door to the kept chats of closed sessions, now that the list has no "Earlier chats" lines.
        if !NativeCloudChats.shared.earlier.isEmpty {
            Button(NativeCloudChats.earlierTitle) { choose(SIDEBARCloudRows.earlierPrefix + (sessionProject(session.id)?.id ?? "")) }
        }
        // WhatsApp (DESIGN-WHATSAPP section 3): in the menu only; the row itself shows nothing new.
        if case .local(let id)? = SessionTarget(tabId: session.id) {
            NativeWhatsAppSubmenu(here: .session(id: id, name: SIDEBARSessionLine.title(session, store: store)))
        }
        Divider()
        if running.contains(where: { $0.id == session.id }) { Button("Stop") { stop(session.id) } }
        Button("Delete", role: .destructive) { close(session.id) } // the app's own close, with its confirmation
    }

    var rowIDs: [String] {
        SIDEBARVisibleRows.ids(pages: pinnedPages.map(\.id), projects: projectFolders.map(\.id),
                               sessions: visibleRunning.map(\.id) + heldRows.map(\.id))
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
        // LANDING-FIX-4: a registered project's folder is named by the project ("CRM", not "ClaudeCRM"); display only.
        return project.id.hasPrefix("/") ? NativeProjectNames.folderRowName(project.id, registry: registry) : project.title
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
        // A page waiting for him that no session row shows (Hoot's, a Hoot task's, a background agent's): Hoot's line
        // carries the raised hand, and his click on it opens exactly that page (NativeWaitingPages).
        let waiting = item.isHoot ? hootLinePage : nil
        return Button { choose(item.id) } label: {
            HStack(spacing: 8) {
                Group {
                    if item.isHoot { AgentAvatar(icon: .symbol("bird"), size: 18, hoot: true) }
                    else { Image(systemName: item.symbol).foregroundStyle(on ? Color.white : Color.secondary) }
                }.frame(width: 18)
                Text(item.title).lineLimit(1).foregroundStyle(on ? Color.white : Color.primary)
                Spacer(minLength: 0)
                if let waiting {
                    SIDEBARWaitingHand(page: waiting)
                } else if item.id == "agents-all", AGTAgentsStore.shared.counts.working > 0 {
                    Text("\(AGTAgentsStore.shared.counts.working) working").font(.system(size: 11)).foregroundStyle(on ? Color.white.opacity(0.85) : Color.secondary)
                } else if item.id == "tasks", let tasks = TasksStore.shared.state?.tasks {
                    // 15 Nov: the same rule the Tasks page lists by in its widest view, never a second copy.
                    let count = TaskList.openInWidestView(tasks).count
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
            if !NativeCloudChats.shared.earlier.isEmpty {
                Button(NativeCloudChats.earlierTitle) {
                    choose(SIDEBARCloudRows.earlierPrefix + (projectID == PROJProjects.independentID ? "" : projectID))
                }
            }
            Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.id) }
            Button("Choose logo…") { chooseLogo(registry.first { $0.id == projectID } ?? SHELLRoutes.project(forPath: project.id)) }
            Divider()
            Button("Remove from sidebar") { closeProject(project.id) }
            // Delete rule J-4: this Mac only ("Not on this Mac", Bring back in Your Cloud). No question, no session
            // closed, no folder touched; the same route as the New Session list (`remove-project`).
            if projectID != PROJProjects.independentID {
                Button("Remove from this Mac") { AppModel.shared.buttonActions.run(.removeProject(project.id)) }
                    .help("Removed from this Mac only. Its folders and sessions are kept; Bring back is in Your Cloud.")
            }
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

/// The side panel's bottom bar (owner, 14 Nov, his mock "A  Asad · Ultra ⌄ … ⚙"): his profile on the left (picture or
/// initial and his name; "Name · Plan" once the account names a plan), only the gear on the right. The profile opens
/// Settings on Profile; the gear opens Settings on General. Signed out the left says "Sign in". A narrow panel shows the
/// picture and the gear only. No Devices button: his devices are Settings → Devices.
struct SidebarSettingsLine: View {
    let model: AppModel
    @State private var keys = AiAppsSettingsModel.shared
    var body: some View {
        // 18 Nov (Asad: "until somebody do not sign in, here it can stay and settings icon ... profile should not be
        // made like this big until somebody is already signed in"): nobody signed in = only Settings, with its word.
        let signedIn = NativeProfileFacts.current(NativeCloudAccount.shared).signedIn
        HStack(spacing: 8) {
            if signedIn {
                SidebarProfileButton(enabled: model.canRun) { model.openSettings(section: NativeSettingsNavigation.profileID) }
            } else {
                Button(action: model.requestSettings) {
                    HStack(spacing: 8) {
                        Image(systemName: "gearshape").foregroundStyle(.secondary).frame(width: 18)
                        Text("Settings").font(.system(size: 13)).foregroundStyle(.primary).lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .frame(minHeight: 28, alignment: .leading).contentShape(.rect)
                }
                .buttonStyle(DeckSidebarRowStyle()).help("Settings (⌘,)").accessibilityLabel("Settings")
                .disabled(!model.canRun)
            }
            Spacer(minLength: 0)
            // A key a tool made waits in Settings › AI apps (it never opens Settings by itself).
            if keys.made != nil {
                Image(systemName: "key.fill").font(.caption).foregroundStyle(.orange)
                    .help("A new AI app key is waiting in Settings › AI apps").accessibilityLabel("A new key is waiting in Settings")
            }
            if signedIn {
                Button(action: model.requestSettings) {
                    Image(systemName: "gearshape").frame(width: 28, height: 28).contentShape(.rect)
                }.buttonStyle(DeckSidebarIconStyle()).fixedSize().help("Settings (⌘,)").accessibilityLabel("Settings")
                    .disabled(!model.canRun)
            }
        }.foregroundStyle(.secondary)
    }
}

/// His picture and name; "Sign in" while nobody is signed in (absent where this copy cannot sign in at all).
struct SidebarProfileButton: View {
    let enabled: Bool
    var account = NativeCloudAccount.shared
    let openProfile: () -> Void
    /// The plan's name once the account service sends one (not yet: the name stands alone).
    static func label(name: String, plan: String?) -> String {
        guard let plan, !plan.isEmpty else { return name }
        return name + " · " + plan
    }
    /// "Name", "Name · Plan", "Sign in again" while the saved sign-in waits to be checked, "Sign in" signed out.
    static func text(_ facts: NativeProfileFacts) -> String {
        guard facts.signedIn else { return "Sign in" }
        return facts.needsSignInAgain ? "Sign in again" : label(name: facts.name ?? "", plan: nil)
    }
    var body: some View {
        let facts = NativeProfileFacts.current(account)
        if facts.signedIn || NativeCloudDisplayGate.shared.shows {
            Button {
                if !facts.signedIn, case .signedOut(waiting: false) = account.signInStage { account.pressSignIn() }
                else if facts.needsSignInAgain { account.pressCheckAgain() }
                else { openProfile() }
            } label: {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        NativeProfileAvatar(name: facts.name, picture: facts.picture, local: facts.localPicture, size: 22)
                        Text(Self.text(facts))
                            .font(.system(size: 13)).foregroundStyle(.primary).lineLimit(1).truncationMode(.tail)
                    }
                    NativeProfileAvatar(name: facts.name, picture: facts.picture, local: facts.localPicture, size: 22)
                }
                .frame(minHeight: 28, alignment: .leading).contentShape(.rect)
            }
            .buttonStyle(DeckSidebarRowStyle())
            .help(facts.signedIn ? "Your profile" : "Sign in")
            .accessibilityLabel(facts.signedIn ? "Profile, \(facts.name ?? "")" : "Sign in")
            .disabled(!enabled)
        }
    }
}

struct SidebarRow: View {
    static let leadingShift: CGFloat = 0
    let item: SidebarItem
    var selected = false
    var body: some View {
        HStack(spacing: 8) {
            if item.kind == .session { SIDEBARSessionTypeIcon(chat: SIDEBARProjectStore.shared.sessionChats.contains(item.id)) }
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
    @ObservationIgnored private var arrival: NSObjectProtocol?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keys = defaults.stringArray(forKey: Self.stableKey) ?? defaults.stringArray(forKey: Self.key) ?? []
        // Same everywhere (15 Nov): a session pinned on another device is pinned here too; one that is not on this
        // device yet stays saved (as unknown old pins always did) and shows pinned as soon as it is here.
        arrival = NotificationCenter.default.addObserver(forName: CloudSyncChoices.choicesArrived, object: nil, queue: .main) { [weak self] note in
            let keys = note.userInfo?["keys"] as? [String] ?? []
            MainActor.assumeIsolated {
                guard keys.contains(SIDEBARPins.stableKey), let self, let saved = self.defaults.stringArray(forKey: Self.stableKey), saved != self.keys else { return }
                self.keys = saved
            }
        }
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
/// The quiet marks a session's tools leave on its row (NativeBackgroundToolsPolicy): a phone, a browser, a raised hand
/// when a page waits for the person. Drawn as the row's other small marks (StatusMark): caption, secondary; the hand
/// orange. Nothing else changes: the person opens the session himself when he wants to look.
/// The raised hand for one waiting page: its own click target, so the row under it keeps opening what it always opens.
struct SIDEBARWaitingHand: View {
    let page: String
    var body: some View {
        Button { NativeWaitingPages.open(page) } label: {
            Image(systemName: NativeBackgroundToolsPolicy.Mark.handover.symbol).font(.caption).foregroundStyle(.orange)
                .frame(minWidth: 16, minHeight: 16).contentShape(.rect)
        }
        .buttonStyle(.plain).help(NativeWaitingPages.words).accessibilityLabel(NativeWaitingPages.words)
    }
}

/// B1: the side panel's always-visible line for a waiting page while Hoot's line is scrolled out of sight.
private struct SIDEBARWaitingLine: View {
    let page: String
    var body: some View {
        Button { NativeWaitingPages.open(page) } label: {
            HStack(spacing: 8) {
                Image(systemName: NativeBackgroundToolsPolicy.Mark.handover.symbol).font(.caption).foregroundStyle(.orange).frame(width: 18)
                Text("A page is waiting for you").lineLimit(1)
                Spacer(minLength: 0)
            }.padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: DeckSidebar.rowHeight, alignment: .leading).contentShape(.rect)
        }
        .buttonStyle(DeckSidebarRowStyle()).help(NativeWaitingPages.words).accessibilityLabel(NativeWaitingPages.words)
        .padding(.horizontal, 12).padding(.vertical, 4)
    }
}

/// The page a session's browser holds for him (a hand-over waiting), if any: the row's orange dot opens it (SR-6).
/// The simulator and browser marks themselves are gone from the row (Asad, 15 Nov: "remove ... simulator and browser
/// icon too if they are attached").
private struct SIDEBARSessionNeedsYou: View {
    let sessionID: String
    let status: String?
    let onAccent: Bool
    @State private var bindings = NativeBRBindings.shared
    @State private var browser = NativeBrowserTabs.shared

    var body: some View {
        let bound = bindings.view.sessions.first { $0.sessionId == sessionID && !$0.ended }?.windows.map(\.tabId) ?? []
        let waiting = bound.first { browser.tab($0)?.handoverPrompt != nil }
        SIDEBARNeedsYouDot(needsYou: SIDEBARNeedsYouDot.needsYou(status: status), waitingPage: waiting, onAccent: onAccent)
    }
}

/// A session row (Asad, 15 Nov; DESIGN-SESSION-ROWS SR-1 to SR-8): the type icon (chat or terminal) and the session's
/// name, one line. At its end only the orange dot while it needs him, which gives way to ⋯ while the pointer is on the
/// row. Who works in it, its project, its AI and its machine are on the session's own page when it is open.
private struct SIDEBARSessionRow<MenuItems: View>: View {
    let session: SidebarItem
    /// The name the phones show for it (`SIDEBARSessionLine.title`).
    let title: String
    /// A chat session (bubble icon); otherwise a terminal (an AI in a terminal or a shell).
    var chat = false
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
    @ViewBuilder let menu: () -> MenuItems
    @State private var hovering = false

    static var minHeight: CGFloat { DeckSidebar.rowHeight }

    var body: some View {
        if editing {
            // The icon stays, so the name does not jump sideways when the field opens.
            HStack(spacing: 8) {
                icon
                SIDEBARRenameField(title: title, end: endRename)
            }
            .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: Self.minHeight, alignment: .leading)
        } else {
            row
        }
    }

    private var icon: some View {
        SIDEBARSessionTypeIcon(chat: chat, onAccent: onAccent, working: SIDEBARSessionTypeIcon.working(status: session.status))
    }

    private var row: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                icon
                Text(title).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(onAccent ? Color.white : Color.primary)
                Spacer(minLength: 4)
                Color.clear.frame(width: 22, height: 1) // the dot, or ⋯
            }
            .accessibilityElement(children: .combine)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: Self.minHeight, alignment: .leading)
            .background(selection).contentShape(.rect)
        }
        .buttonStyle(DeckSidebarRowStyle())
        .help(title)
        .overlay(alignment: .trailing) {
            ZStack {
                SIDEBARSessionNeedsYou(sessionID: session.id, status: session.status, onAccent: onAccent)
                    .opacity(hovering ? 0 : 1)
                    .allowsHitTesting(!hovering)
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

/// Which agent works in each session (for the session lists that still show it; side-panel rows no longer do): a saved agent the session was started as (its live rows),
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

/// A session that was not reopened (18 Nov, Asad: "this reopen retry does not do anything, and why even does it comes
/// here"): ONE quiet line like any session row. Its reason is the tooltip; "Reopen" shows at the row's end while the
/// pointer is on it, in room that is always kept, so nothing moves. The whole row is the press: `retry`, the held
/// row's own route (`held:<key>`, `session:held-retry`), which the logic lane of 18 Nov makes really reopen it.
struct SIDEBARHeldSessionRow: View, Identifiable {
    let session: SidebarItem
    var folder: String?
    let retry: () -> Void
    nonisolated var id: String { session.id }
    @State private var hovering = false
    var title: String { folder.map { $0 + " · " + session.title } ?? session.title }
    var statusText: String {
        if let help = session.help {
            let prefix = session.title + " — "
            return help.hasPrefix(prefix) ? String(help.dropFirst(prefix.count)) : help
        }
        return session.subtitle ?? "Not reopened"
    }
    var body: some View {
        Button(action: retry) {
            HStack(spacing: 8) {
                SIDEBARSessionTypeIcon(chat: SIDEBARProjectStore.shared.sessionChats.contains(session.id)).opacity(0.55)
                Text(title).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Color.clear.frame(width: 46, height: 1) // Reopen's room
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: DeckSidebar.rowHeight, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(DeckSidebarRowStyle())
        // On the button itself, so it stays ONE pressable element for VoiceOver (its press is the row's press).
        .accessibilityLabel(title + ", not reopened")
        .accessibilityHint(statusText)
        .accessibilityIdentifier("restart-held-retry-" + id)
        .help(statusText)
        .overlay(alignment: .trailing) {
            Text("Reopen").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.accentColor)
                .padding(.trailing, 8)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onHover { hovering = $0 }
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
