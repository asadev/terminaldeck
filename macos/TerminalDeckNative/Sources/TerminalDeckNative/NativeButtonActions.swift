import Foundation
import Observation
import TerminalDeckNativeCore

/// Native window state for buttons formerly owned by tdNative.run in the hidden page.
/// Page snapshots still supply rows, but cannot undo a native choice or resurrect a closed tab.
@MainActor @Observable
final class NativeButtonActions {
    nonisolated enum Outcome: Equatable, Sendable {
        case completed, cancelled, refused(String)
        var succeeded: Bool { self == .completed }
        var message: String { if case .refused(let message) = self { return message }; return "That change was cancelled." }
    }
    struct Effects {
        var invoke: @MainActor (String, [Any?]) async throws -> Any
        var presentSession: @MainActor (String?) throws -> Void
        var confirm: @MainActor (CloseConfirmRequest) async -> Bool
        var changed: @MainActor () -> Void = {}
        var forgotten: @MainActor (String) -> Void = { _ in }
        var captureShell: @MainActor () -> NativeButtonShellCapture? = { nil }
        var shellOpened: @MainActor (String, String) -> Void = { _, _ in }
        var remember: @MainActor (Data) -> Void = { _ in }
        var openTabs: @MainActor () -> [TabItem]? = { nil }
        /// The native browser's tab ids. They are not page rows, yet a pane of the split can show one (Asad, 28 Oct).
        var browserTabs: @MainActor () -> [String] = { [] }
        /// The browser tab on show in the main window on its own, if one is.
        var shownBrowser: @MainActor () -> String? = { nil }
    }
    var problem: String?
    private(set) var sidebar = SidebarState(groups: [], projects: [], selectedId: nil)
    private(set) var tabs = TabsState(tabs: [], canNewTerminal: true, canNewBrowser: true)
    @ObservationIgnored private let effects: Effects
    @ObservationIgnored private var selectionOwned = false
    @ObservationIgnored private var layoutOwned = false
    @ObservationIgnored private var expanded: [String: Bool] = [:]
    @ObservationIgnored private var added: [TabItem] = []
    @ObservationIgnored private var folded: Set<String> = []
    @ObservationIgnored private var knownTabs: [String: TabItem] = [:]
    @ObservationIgnored private var closed: Set<String> = []
    @ObservationIgnored private var closedOrder: [String] = []
    static let closedKept = 500
    @ObservationIgnored private var finished: Set<String> = []
    @ObservationIgnored private var closedProjects: Set<String> = []
    @ObservationIgnored private var serverNames: [String: String] = [:]
    @ObservationIgnored private var serverStates: [String: (shell: String?, ended: Bool)] = [:]
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private var chain: Task<Bool, Never>?
    @ObservationIgnored private var initialSessions: Task<Void, Never>?
    /// The browser tabs the panes hold, kept with the layout: a browser tab's id looks like a session's (a UUID),
    /// so a pane must know which it holds even after the tab itself has gone.
    @ObservationIgnored private(set) var browserPanes: Set<String> = []

    static let memoryKey = "native.window.buttons.v1"
    init(effects: Effects, remembered: Data? = nil) {
        self.effects = effects
        if let remembered, let object = try? JSONSerialization.jsonObject(with: remembered) as? [String: Any] {
            expanded = object["expanded"] as? [String: Bool] ?? [:]
            folded = Set(object["folded"] as? [String] ?? [])
            browserPanes = Set(object["browserPanes"] as? [String] ?? [])
            if let raw = object["layout"], let data = try? JSONSerialization.data(withJSONObject: raw),
               let layout = try? JSONDecoder().decode(WindowLayout.self, from: data) {
                tabs.layout = layout; layoutOwned = true
            }
        }
    }
    func memory() -> Data? {
        var object: [String: Any] = ["expanded": expanded, "folded": Array(folded), "browserPanes": browserPanes.sorted()]
        if layoutOwned, let layout = tabs.layout {
            object["layout"] = ["mode": layout.mode, "swarm": layout.swarm, "root": layout.root.map { $0.wire() as Any } ?? NSNull(),
                "focusedPaneId": layout.focusedPaneId as Any? ?? NSNull(), "primaryPaneId": layout.primaryPaneId as Any? ?? NSNull(),
                "modeSwitch": layout.modeSwitch, "splitOffer": layout.splitOffer]
        }
        return try? JSONSerialization.data(withJSONObject: object)
    }

    static let names: Set<String> = ["select", "select-tab", "close-session", "close-tab", "new-session", "new-session-in",
        "new-terminal-tab", "close-project", "toggle-project", "set-mode", "resize-split", "focus-pane", "close-pane", "split-with",
        "open-server-session", "open-server-shell", "server-shell-opened", "server-shell-ended", "start-machine-session", "new-session-start", "new-session-cancel", "remove-project", "server-renamed", "open-file", "show-panel", "show-sessions"]

    func start() {
        guard subscriptions.isEmpty else { return }
        subscriptions.append(EngineBridge.shared.on("session:exit") { [weak self] args in
            if let id = args.first as? String { self?.finished.insert(id) }
        })
        subscriptions.append(EngineBridge.shared.on("session:created") { [weak self] args in
            if let row = args.first as? [String: Any] { self?.created(row) }
        })
        subscriptions.append(EngineBridge.shared.on("session:removed") { [weak self] args in
            if let id = args.first as? String, !NativeSessionRailContinuity.shared.isSwitching(id) { self?.remove(id); self?.effects.changed() }
        })
        subscriptions.append(EngineBridge.shared.on("session:switched") { [weak self] args in
            if let old = args.first as? String, args.count > 1, let row = args[1] as? [String: Any] {
                self?.replaced(old, with: row)
            }
        })
        // Hoot and tools can create sessions before the first window button is used.
        // Subscribe first, then replay the current list so those rows are reachable too.
        initialSessions = Task { [weak self] in
            guard let self, let rows = try? await effects.invoke("session:list", []) as? [[String: Any]] else { return }
            for row in rows {
                if Self.hasFinished(row) {
                    if let id = row["id"] as? String { finished.insert(id) }
                } else { created(row) }
            }
        }
    }

    func ingest(_ state: SidebarState) {
        let before = sidebar
        sidebar = state
        if selectionOwned { sidebar.selectedId = before.selectedId; sidebar.project = before.project; sidebar.openFile = before.openFile; sidebar.focus = before.focus }
        sidebar.projects = sidebar.projects.filter { !closedProjects.contains($0.id) }.map { group in
            let native = added.filter { belongs($0, to: group.id) }
            let rows = group.sessions.filter { !closed.contains($0.id) }.map { row in
                guard serverStates[row.id] != nil else { return row }
                let native = tabs.tabs.first { $0.id == row.id } ?? added.first { $0.id == row.id } ?? knownTabs[row.id]
                return native.map { Self.row(renamed($0)) } ?? row
            }
            return SidebarProject(id: group.id, title: group.title, expanded: expanded[group.id] ?? group.expanded,
                sessions: rows + native.filter { tab in !rows.contains { $0.id == tab.id } }.map(Self.row))
        }
        // Native server tabs and newly-created local tabs also need a rail row when the page has none.
        for tab in added where !closed.contains(tab.id) && sidebar.item(id: tab.id) == nil {
            let groupID = group(for: tab)
            if let index = sidebar.projects.firstIndex(where: { $0.id == groupID }) {
                let old = sidebar.projects[index]
                sidebar.projects[index] = SidebarProject(id: old.id, title: old.title, expanded: expanded[old.id] ?? true, sessions: old.sessions + [Self.row(tab)])
            } else if !closedProjects.contains(groupID) {
                sidebar.projects.append(SidebarProject(id: groupID, title: tab.server?.serverName ?? URL(fileURLWithPath: groupID).lastPathComponent,
                    expanded: expanded[groupID] ?? true, sessions: [Self.row(tab)]))
            }
        }
        sidebar.groups = sidebar.groups.map { SidebarGroup(id: $0.id, title: $0.title, items: $0.items.filter { !closed.contains($0.id) }) }
    }

    func ingest(_ state: TabsState) {
        let before = tabs
        for tab in state.tabs { knownTabs[tab.id] = tab }
        tabs = state
        tabs.tabs = state.tabs.filter { !closed.contains($0.id) && !folded.contains($0.id) }.map(renamed)
        for tab in added where !closed.contains(tab.id) && !folded.contains(tab.id) && !tabs.tabs.contains(where: { $0.id == tab.id }) { tabs.tabs.append(renamed(tab)) }
        if selectionOwned { tabs.tabs = tabs.tabs.map { $0.with(active: $0.id == before.activeID) } }
        if layoutOwned, let saved = before.layout {
            tabs.layout = WindowLayout(mode: saved.mode, swarm: saved.swarm, root: saved.root, focusedPaneId: saved.focusedPaneId,
                primaryPaneId: saved.primaryPaneId, modeSwitch: saved.modeSwitch, splitOffer: saved.splitOffer,
                swarmSessions: state.layout?.swarmSessions ?? saved.swarmSessions)
        }
    }

    /// Ordered changes: a quick Select after Open, or successive divider positions, cannot overtake each other.
    @discardableResult func run(_ command: PageCommand) -> Task<Bool, Never> {
        let task = enqueue(command, presentErrors: true)
        return Task { await task.value.succeeded }
    }
    /// Tool errors belong to that request's reply, never the native alert binding.
    func runForTool(_ command: PageCommand) -> Task<Outcome, Never> {
        enqueue(command, presentErrors: false)
    }
    private func enqueue(_ command: PageCommand, presentErrors: Bool) -> Task<Outcome, Never> {
        let previous = chain
        let selectionWhenQueued = nativeSelectionRevision
        let task = Task<Outcome, Never> {
            _ = await previous?.value
            if presentErrors { problem = nil }
            await initialSessions?.value
            if ["select", "select-tab"].contains(command.name), nativeSelectionRevision != selectionWhenQueued { return .completed }
            do { try await perform(command); if let saved = memory() { effects.remember(saved) }; effects.changed(); return .completed }
            catch is ButtonCancelled { return .cancelled }
            catch {
                let message = (error as? ButtonFailure)?.message ?? (error as? NativeRPCError)?.message ?? "That change could not be made. Please try again."
                if presentErrors { problem = message }
                return .refused(message)
            }
        }
        chain = Task { await task.value.succeeded }
        return task
    }

    private struct ButtonCancelled: Error {}
    private struct ButtonFailure: Error { let message: String }
    private func refuse(_ message: String) throws -> Never { throw ButtonFailure(message: message) }
    /// #93: the engine's own reason follows the sentence, so a refusal says why, not only what failed.
    private func call(_ channel: String, _ args: [Any?], failure: String) async throws -> Any {
        let answer: Any
        do { answer = try await effects.invoke(channel, args) } catch { try refuse(Self.because(failure, Self.reason(error))) }
        if (answer as? Bool) == false { try refuse(failure) }
        if let row = answer as? [String: Any], ["ok", "renamed", "closed"].contains(where: { (row[$0] as? Bool) == false }) {
            try refuse(Self.because(failure, (row["message"] as? String) ?? (row["error"] as? String) ?? ""))
        }
        return answer
    }
    private static func reason(_ error: Error) -> String {
        if case .refused(let why)? = error as? EngineWireError { return ArtifactRules.readFailure(why) }
        return (error as? NativeRPCError)?.message ?? ""
    }
    static func because(_ failure: String, _ reason: String) -> String {
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty || reason == failure ? failure : failure + " " + reason
    }

    private func perform(_ command: PageCommand) async throws {
        let id = command.argument ?? command.list?.first ?? ""
        switch command.name {
        case "select", "select-tab": try await select(id)
        case "show-panel":
            guard sidebar.item(id: id) != nil else { try refuse("That page is not available in this window.") }
            showPanel(id, focus: command.list?.dropFirst().first)
        case "open-file":
            guard !id.isEmpty, sidebar.project != nil else { try refuse("Open a folder before opening a file.") }
            sidebar.openFile = id; showPanel("files", focus: nil)
        case "new-session", "new-terminal-tab":
            do { try effects.presentSession(nil) } catch { try refuse("The new session form could not be opened. Open the main window and try again.") }
        case "new-session-in":
            if id.hasPrefix("machine:") {
                do { try effects.presentSession(id) } catch { try refuse("The other Mac’s new-session form could not be opened. Please try again.") }
            }
            else if id.hasPrefix("server:") { try await openServer(String(id.dropFirst(7)), name: sidebar.projects.first { $0.id == id }?.title ?? "Server", folder: nil) }
            else { guard sidebar.projects.contains(where: { $0.id == id }) else { try refuse("That folder is no longer open.") }; do { try effects.presentSession(id) } catch { try refuse("The new session form could not be opened. Please try again.") } }
        case "close-tab":
            // The top bar is a set of views: its X folds a session back into the side panel.
            // Delete on the side panel is the separate action that ends the process.
            guard let tab = tabs.tabs.first(where: { $0.id == id }) else { try refuse("That tab is no longer on the top bar.") }
            knownTabs[id] = tab; folded.insert(id)
            let next = neighbourAfterClosing(id)
            let active = tabs.activeID == id
            tabs.tabs.removeAll { $0.id == id }
            if active {
                if let root = tabs.layout?.root, let pane = tabs.layout?.focusedPaneId {
                    layout(root: root.showing(next, in: pane))
                }
                activate(next)
            }
        case "close-session":
            let tab = tabs.tabs.first { $0.id == id }, row = sidebar.item(id: id)
            let subject: CloseSubject = id.hasPrefix("machine ") ? .machine : id.hasPrefix("server ") ? .server : .session
            guard await effects.confirm(CloseConfirmRequest(title: tab?.title ?? row?.title ?? "this session", status: tab?.status ?? row?.status ?? "idle", subject: subject)) else { throw ButtonCancelled() }
            try await close(id)
        case "close-project":
            if hideRemovedFolder(id) { return }
            guard let group = sidebar.projects.first(where: { $0.id == id }) else { try refuse("That folder is no longer open.") }
            let subject: CloseSubject = id.hasPrefix("machine:") ? .machine : id.hasPrefix("server:") ? .server : .project
            guard await effects.confirm(CloseConfirmRequest(title: group.title,
                status: group.sessions.first(where: { $0.status == "working" || $0.status == "input" })?.status ?? "idle", count: group.sessions.count, subject: subject)) else { throw ButtonCancelled() }
            // A partial refusal keeps the remaining rows. A folder is removed only after every close succeeds.
            for row in group.sessions { try await close(row.id); effects.changed() }
            if id.hasPrefix("/") { _ = try await call("projects:remove", [id], failure: "That folder could not be closed.") }
            SIDEBARProjectStore.shared.hideFolder(id)
            selectionOwned = true
            closedProjects.insert(id); sidebar.projects.removeAll { $0.id == id }
            if sidebar.project == id { sidebar.project = sidebar.projects.first(where: { $0.id.hasPrefix("/") })?.id }
        case "toggle-project":
            guard let index = sidebar.projects.firstIndex(where: { $0.id == id }) else { try refuse("That folder is no longer open.") }
            sidebar.projects[index].expanded.toggle(); expanded[id] = sidebar.projects[index].expanded
        case "set-mode": try setMode(id)
        case "split-with": try splitWith(id)
        case "resize-split":
            guard let root = tabs.layout?.root, let text = command.list?.dropFirst().first, let ratio = Double(text), ratio.isFinite,
                  root.hasSplit(id) else { try refuse("That divider is no longer available.") }
            layout(root: root.resized(id, PaneRules.clamp(ratio)))
        case "focus-pane":
            guard let root = tabs.layout?.root, let leaf = root.leaves.first(where: { $0.id == id }) else { try refuse("That pane is no longer open.") }
            layout(root: root, focus: id); activate(leaf.tabId)
        case "close-pane":
            guard let root = tabs.layout?.root, root.leaves.contains(where: { $0.id == id }) else { try refuse("That pane is no longer open.") }
            let next = root.removing(id), leaves = next?.leaves ?? []
            let focus = leaves.contains(where: { $0.id == tabs.layout?.focusedPaneId }) ? tabs.layout?.focusedPaneId : leaves.first?.id
            let survivor = leaves.first { $0.id == focus }?.tabId
            layout(root: leaves.count > 1 ? next : nil, focus: focus, mode: leaves.count > 1 ? "split" : "terminal")
            activate(survivor)
        case "open-server-session":
            guard let values = command.list, values.count >= 2 else { try refuse("Choose a server first.") }
            try await openServer(id, name: values[1], folder: values.count > 2 && !values[2].isEmpty ? values[2] : nil)
        case "open-server-shell":
            let name = tabs.tabs.first { $0.server?.serverId == id }?.server?.serverName
                ?? sidebar.projects.first { $0.id == "server:" + id }?.title
            guard let name else { try refuse("Open that server before starting an agent there.") }
            try await openServer(id, name: name, folder: nil, run: command.list?.dropFirst().first)
        case "server-shell-opened":
            guard let shell = command.list?.dropFirst().first else { try refuse("That server terminal is not connected.") }
            try serverOpened(id, shell: shell)
        case "server-shell-ended": try serverEnded(id)
        case "start-machine-session":
            guard let values = command.list, values.count == 3, !values[1].isEmpty, !values[2].isEmpty else { try refuse("Choose a folder and an AI on the other Mac first.") }
            let session = try await NativeMachineSessionStart.create(machine: id, folder: values[1], provider: values[2], invoke: effects.invoke, created: { row in
                self.machineCreated(machine: id, session: row.id, title: row.title)
            })
            machineCreated(machine: id, session: session)
        case "new-session-start": try await NativeNewSession.submitForTool()
        case "new-session-cancel": try NativeNewSession.cancelForTool()
        case "remove-project":
            if hideRemovedFolder(id) { return }
            let ids = try await NativeNewSessionModel.removeFolder(id, invoke: effects.invoke)
            projectRemoved(id, sessions: ids)
        case "server-renamed":
            guard let name = command.list?.dropFirst().first, !name.trimmingCharacters(in: .whitespaces).isEmpty else { try refuse("Give the server a name first.") }
            let answer = try await call("servers:rename", [id, name], failure: "The server’s new name could not be saved.")
            guard (answer as? [String: Any])?["renamed"] as? Bool == true || (answer as? Bool) == true else { try refuse("The server’s new name could not be saved.") }
            serverNames[id] = name; tabs.tabs = tabs.tabs.map(renamed); added = added.map(renamed)
            sidebar.projects = sidebar.projects.map { $0.id == "server:" + id ? SidebarProject(id: $0.id, title: name, expanded: $0.expanded, sessions: $0.sessions.map { row in tabs.tabs.first(where: { $0.id == row.id }).map(Self.row) ?? row }) : $0 }
        case "show-sessions":
            let old = tabs.layout ?? WindowLayout()
            tabs.layout = WindowLayout(mode: old.mode, swarm: true, root: old.root, focusedPaneId: old.focusedPaneId, primaryPaneId: old.primaryPaneId,
                modeSwitch: old.modeSwitch, splitOffer: old.splitOffer, swarmSessions: swarmRows())
            layoutOwned = true
        default: try refuse("That button is not available here yet.")
        }
    }

    private func select(_ id: String) async throws {
        let selectionAtStart = selectionRevision
        // A native browser tab: with the split on it takes a pane, as a session tab does; either way it is what shows.
        if effects.browserTabs().contains(id) {
            if let root = tabs.layout?.root, tabs.layout?.splitting == true, tabs.layout?.swarm != true, let focus = tabs.layout?.focusedPaneId {
                if let pane = root.leaves.first(where: { $0.tabId == id }) { layout(root: root, focus: pane.id) }
                else { layout(root: root.showing(id, in: focus)) }
            }
            activate(id); return
        }
        if SIDEBARLayout.main.contains(id), id != "hoot" {
            showPanel(id, focus: nil); return
        }
        if id.hasPrefix("held:") {
            _ = try await call("session:held-retry", [String(id.dropFirst(5))], failure: "That saved session could not be reopened."); return
        }
        if case .machine(let machine, let session) = SessionTarget(tabId: id) {
            let snapshot = MachinesSnapshot.decode(try await call("machines:list", [], failure: "The other Mac is not answering."))
            guard selectionRevision == selectionAtStart else { return }
            guard let link = snapshot?.links[machine], link.state == .online, let row = link.session(session) else { try refuse("That session on the other Mac is not available. Check its connection and try again.") }
            if !tabs.tabs.contains(where: { $0.id == id }) {
                added.append(TabItem(id: id, title: row.title, kind: "session", status: row.status, closable: true)); ingest(tabs); ingest(sidebar)
            }
        }
        bringToBar(id)
        guard tabs.tabs.contains(where: { $0.id == id }) || sidebar.item(id: id) != nil else { try refuse("That session or page is no longer open.") }
        if tabs.tabs.contains(where: { $0.id == id }) {
            if let root = tabs.layout?.root, tabs.layout?.splitting == true, let focus = tabs.layout?.focusedPaneId {
                // A tab already in a pane gets focus; another tab fills the focused pane.
                if let pane = root.leaves.first(where: { $0.tabId == id }) { layout(root: root, focus: pane.id) }
                else { layout(root: root.showing(id, in: focus)) }
            }
            activate(id)
            if let group = sidebar.projects.first(where: { $0.sessions.contains { $0.id == id } }), group.id.hasPrefix("/") { sidebar.project = group.id }
        } else { showPanel(id, focus: nil) }
    }

    /// A session row the bar does not show (folded back, or never opened here) comes back onto it.
    private func bringToBar(_ id: String) {
        guard !tabs.tabs.contains(where: { $0.id == id }), let row = sidebar.item(id: id), row.kind == .session else { return }
        folded.remove(id)
        let tab = knownTabs[id] ?? TabItem(id: id, title: row.title, kind: "session", status: row.status, closable: true)
        if !added.contains(where: { $0.id == id }) { added.append(tab) }
        ingest(tabs)
    }

    // Explicit native selections supersede queued work. Selections made by an
    // earlier queued command must not discard later commands in the same queue.
    @ObservationIgnored private var nativeSelectionRevision = 0
    private(set) var selectionRevision = 0
    var ownsSelection: Bool { selectionOwned }
    func followNativeSelection(_ id: String) {
        nativeSelectionRevision += 1
        if tabs.tabs.contains(where: { $0.id == id }) { activate(id) } else { showPanel(id, focus: nil) }
    }

    private func showPanel(_ id: String, focus: String?) {
        selectionRevision += 1
        selectionOwned = true; sidebar.selectedId = id; sidebar.focus = focus?.isEmpty == false ? focus : nil
        tabs.tabs = tabs.tabs.map { $0.with(active: false) }
    }
    private func activate(_ id: String?) {
        selectionRevision += 1
        selectionOwned = true; sidebar.selectedId = id; sidebar.focus = nil
        tabs.tabs = tabs.tabs.map { $0.with(active: $0.id == id) }
    }
    private func close(_ id: String) async throws {
        if id.hasPrefix("held:") { _ = try await call("session:held-forget", [String(id.dropFirst(5))], failure: "That saved session could not be removed.") }
        else {
            guard let target = SessionTarget(tabId: id), tabs.tabs.contains(where: { $0.id == id }) || sidebar.item(id: id) != nil else { try refuse("That session is no longer open.") }
            switch target {
            case .local: _ = try await call("session:kill", [id], failure: "That session could not be deleted.")
            case .machine(let machine, let session): _ = try await call("machines:close", [machine, session], failure: "The other Mac could not close that session.")
            case .server:
                if serverStates[id]?.ended == true { break }
                guard let shell = NativeServerShells.shellId(forTab: id) ?? tabs.tabs.first(where: { $0.id == id })?.server?.shellId else { try refuse("That server terminal is no longer connected.") }
                _ = try await call("servers:shell:close", [shell], failure: "That server terminal could not be closed.")
            }
        }
        remove(id); effects.forgotten(id)
    }
    private func remove(_ id: String) {
        NativeSessionRailContinuity.shared.removed(id); NativeSessionControlsState.forget(id)
        let wasActive = tabs.activeID == id || sidebar.selectedId == id
        let next = wasActive ? neighbourAfterClosing(id) : nil
        // U143 (#611): a removed session leaves no folded, finished, tab or folder note behind; only its
        // "closed" mark stays (so a late event cannot bring it back), and only for the latest `closedKept`.
        folded.remove(id); finished.remove(id); knownTabs[id] = nil; folders[id] = nil
        closedOrder.removeAll { $0 == id }; closedOrder.append(id)
        if closedOrder.count > Self.closedKept { closed.remove(closedOrder.removeFirst()) }
        closed.insert(id); added.removeAll { $0.id == id }
        tabs.tabs.removeAll { $0.id == id }
        if let root = tabs.layout?.root { layout(root: root.clearing(id)) }
        ingest(sidebar)
        if wasActive { activate(next) }
    }
    /// The tab beside the closed one (right, else left), like a browser. With none left, nothing:
    /// the empty pane shows, never Hoot (Asad, 3 Nov: Hoot stays closed until the person opens it).
    private func neighbourAfterClosing(_ id: String) -> String? {
        let open = (effects.openTabs() ?? tabs.tabs).filter { tab in
            if tab.id == id { return true }
            if finished.contains(tab.id) { return false }
            switch StatusMeaning(tab.status) {
            case .completed, .exited, .failed: return false
            default: return true
            }
        }
        guard let index = open.firstIndex(where: { $0.id == id }) else { return nil }
        if index + 1 < open.count { return open[index + 1].id }
        if index > 0 { return open[index - 1].id }
        return nil
    }
    private func openServer(_ id: String, name: String, folder: String?, run: String? = nil) async throws {
        guard !id.isEmpty else { try refuse("Choose a server first.") }
        let capture = effects.captureShell()
        defer { capture?.stop() }
        let result = try await call("servers:shell:open", [id, 80, 24, folder], failure: "That server could not open a terminal. Check its connection and try again.") as? [String: Any]
        guard let shell = result?["shellId"] as? String, result?["ok"] as? Bool == true else { try refuse("That server could not open a terminal. Check its connection and try again.") }
        guard capture?.ended.contains(shell) != true else { try refuse("That server terminal ended while it was opening. Please try again.") }
        if let run, !run.isEmpty {
            do { _ = try await call("servers:shell:write", [shell, run + "\r"], failure: "The terminal opened, but the agent could not be started.") }
            catch { _ = try? await effects.invoke("servers:shell:close", [shell]); throw error }
        }
        let tabID = adoptServer(id, name: name, shell: shell, folder: folder)
        effects.shellOpened(tabID, capture?.take(shell) ?? "")
    }

    @discardableResult func adoptServer(_ id: String, name: String, shell: String, folder: String?) -> String {
        let key = UUID().uuidString, tabID = SessionTarget.server(serverId: id, shellKey: key).tabId
        let info = ServerTabInfo(serverId: id, serverName: name, shellKey: key, startIn: folder, run: nil, shellId: shell)
        added.append(TabItem(id: tabID, title: name, kind: "session", status: "idle", closable: true, server: info))
        serverStates[tabID] = (shell, false)
        NativeServerShells.opened(tabId: tabID, shellId: shell)
        ingest(tabs); ingest(sidebar)
        if let root = tabs.layout?.root, tabs.layout?.splitting == true, let focus = tabs.layout?.focusedPaneId {
            layout(root: root.showing(tabID, in: focus))
        }
        activate(tabID); effects.changed()
        return tabID
    }

    func serverOpened(_ id: String, shell: String) throws {
        guard !shell.isEmpty, (tabs.tabs + added + Array(knownTabs.values)).contains(where: { $0.id == id && $0.server != nil }), !closed.contains(id) else {
            try refuse("That server terminal is no longer open.")
        }
        serverStates[id] = (shell, false)
        NativeServerShells.opened(tabId: id, shellId: shell)
        ingest(tabs); ingest(sidebar); effects.changed()
    }
    func serverEnded(_ id: String) throws {
        guard (tabs.tabs + added + Array(knownTabs.values)).contains(where: { $0.id == id && $0.server != nil }) else { try refuse("That server terminal is no longer open.") }
        serverStates[id] = (nil, true)
        NativeServerShells.closed(tabId: id)
        ingest(tabs); ingest(sidebar); effects.changed()
    }
    func machineCreated(machine: String, session: String, title: String = "Remote session") {
        let id = SessionTarget.machine(machineId: machine, sessionId: session).tabId
        if !tabs.tabs.contains(where: { $0.id == id }) {
            added.append(TabItem(id: id, title: title, kind: "session", status: "idle", closable: true))
        }
        ingest(tabs); ingest(sidebar)
        if let root = tabs.layout?.root, tabs.layout?.splitting == true, let focus = tabs.layout?.focusedPaneId {
            layout(root: root.showing(id, in: focus))
        }
        activate(id); effects.changed()
    }
    func projectRemoved(_ path: String, sessions: [String]) {
        SIDEBARProjectStore.shared.hideFolder(path)
        for id in sessions { remove(id); effects.forgotten(id) }
        closedProjects.insert(path); sidebar.projects.removeAll { $0.id == path }
        if sidebar.project == path { sidebar.project = sidebar.projects.first { $0.id.hasPrefix("/") }?.id }
        effects.changed()
    }
    private func hideRemovedFolder(_ path: String) -> Bool {
        let store = SIDEBARProjectStore.shared
        guard path.hasPrefix("/"), store.openFolders?.contains(PROJProjects.normalize(path)) == false else { return false }
        let registry = store.projects.isEmpty ? PROJProjects.defaults : store.projects
        let group = sidebar.projects.first { $0.id == path }
            ?? SIDEBARLayout.projectRows(open: sidebar.projects, registry: registry).first { $0.id == path }
        guard let group, !group.sessions.contains(where: { store.liveIDs?.contains($0.id) == true }) else { return false }
        projectRemoved(path, sessions: group.sessions.map(\.id))
        return true
    }
    func created(_ row: [String: Any]) {
        guard let id = row["id"] as? String, UUID(uuidString: id) != nil, !closed.contains(id) else { return }
        if Self.hasFinished(row) { finished.insert(id) } else { finished.remove(id) }
        if let profile = row["agentProfileID"] as? String, !profile.isEmpty {
            AGTTeamChatHistory.shared.explicitOwners[id] = profile
        }
        let path = row["projectPath"] as? String ?? row["cwd"] as? String ?? ""
        folders[id] = path
        if !added.contains(where: { $0.id == id }) { added.append(TabItem(id: id, title: row["title"] as? String ?? URL(fileURLWithPath: path).lastPathComponent, kind: "session", status: "idle", closable: true)) }
        ingest(tabs); ingest(sidebar); effects.changed()
    }
    /// #160 (Asad, 18 Oct): a session an AI started through the app's tools opens as a quiet tab in its
    /// own project, listed and in the tab bar, but never selected and no window is raised.
    static func openQuietly(_ session: NativeRPCValue) {
        if let row = session.foundation as? [String: Any] { AppModel.shared.buttonActions.created(row) }
    }
    private static func hasFinished(_ row: [String: Any]) -> Bool {
        (row["exitCode"] != nil && !(row["exitCode"] is NSNull)) ||
            ["exited", "completed", "finished", "failed"].contains(row["status"] as? String ?? "")
    }
    /// Only an explicit successful history-open revives a previously closed tab.
    /// Ordinary created events and stale page snapshots keep their tombstone rule.
    func openedHistory(_ row: [String: Any]) {
        guard let id = row["id"] as? String, UUID(uuidString: id) != nil,
              row["chat"] as? Bool == true,
              let exitCode = (row["exitCode"] as? Double) ?? (row["exitCode"] as? Int).map({ Double($0) }),
              exitCode.isFinite, exitCode.rounded(.towardZero) == exitCode else { return }
        closed.remove(id); folded.remove(id)
        created(row)
    }
    static func replacementMetadata(_ incoming: [String: Any], knownChat: Bool) -> [String: Any] {
        var row = incoming
        if knownChat, row["chat"] == nil || row["chat"] is NSNull { row["chat"] = true }
        return row
    }
    func replaced(_ old: String, with incoming: [String: Any]) {
        let previous = NativeTerminalSessions.shared.retainedSession(old)
        let display = NativeSessionRailContinuity.shared.heldChat(old) ?? (previous?.isChat == true ? previous?.chatModel() : nil)
            ?? NativeHootChatModel.queueOwner(old)
        let row = Self.replacementMetadata(incoming, knownChat: display != nil)
        guard let next = row["id"] as? String, UUID(uuidString: next) != nil else { return }
        if next == old {
            NativeTerminalSessions.shared.retainedSession(old)?.adoptSessionMetadata(row)
            created(row)
            return
        }
        if row["chat"] as? Bool == true, let display {
            let replacement = NativeTerminalSessions.shared.session(for: next)
            replacement.adoptSessionMetadata(row)
            replacement.chatModel().carryDisplay(from: display)
        }
        let selected = sidebar.selectedId == old || tabs.activeID == old
        NativeSessionRailContinuity.shared.replaced(old, with: row)
        created(row)
        if let title = NativeSessionRailContinuity.shared.title(next) { _ = NativeSessionNames.shared.rename(tabId: next, typed: title) }
        if let root = tabs.layout?.root {
            let swapped = root.leaves.filter { $0.tabId == old }.reduce(root) { $0.showing(next, in: $1.id) }
            layout(root: swapped)
        }
        remove(old)
        if selected { activate(next) }
        effects.changed()
    }
    @ObservationIgnored private var folders: [String: String] = [:]
    private func group(for tab: TabItem) -> String {
        if let server = tab.server { return "server:" + server.serverId }
        if let machine = SessionTarget(tabId: tab.id)?.machineId { return "machine:" + machine }
        return folders[tab.id] ?? sidebar.projects.first { $0.sessions.contains { $0.id == tab.id } }?.id ?? ""
    }
    private func belongs(_ tab: TabItem, to group: String) -> Bool { self.group(for: tab) == group }
    private static func row(_ tab: TabItem) -> SidebarItem { SidebarItem(id: tab.id, title: tab.title, kind: .session, status: tab.status) }
    private func renamed(_ original: TabItem) -> TabItem {
        var tab = original
        if let info = tab.server, let state = serverStates[tab.id] {
            tab = TabItem(id: tab.id, title: tab.title, symbol: tab.symbol, kind: tab.kind, active: tab.active, unread: tab.unread,
                status: state.ended ? "exited" : "idle", closable: tab.closable,
                server: ServerTabInfo(serverId: info.serverId, serverName: info.serverName, shellKey: info.shellKey, startIn: info.startIn, run: info.run, shellId: state.shell))
        }
        guard let info = tab.server, let name = serverNames[info.serverId] else { return tab }
        return TabItem(id: tab.id, title: name, symbol: tab.symbol, kind: tab.kind, active: tab.active, unread: tab.unread, status: tab.status, closable: tab.closable,
            server: ServerTabInfo(serverId: info.serverId, serverName: name, shellKey: info.shellKey, startIn: info.startIn, run: info.run, shellId: info.shellId))
    }
    private func swarmRows() -> [SwarmSession] {
        let rows: [[String: Any]] = sidebar.allItems.filter { UUID(uuidString: $0.id) != nil }.map {
            ["id": $0.id, "title": $0.title, "status": $0.status as Any? ?? NSNull()]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows) else { return [] }
        return (try? JSONDecoder().decode([SwarmSession].self, from: data)) ?? []
    }
    private func setMode(_ mode: String) throws {
        guard mode == "terminal" || mode == "split" else { try refuse("Choose Terminal or Split.") }
        if mode == "terminal" {
            let shown = tabs.layout?.root?.leaves.first { $0.id == tabs.layout?.focusedPaneId }?.tabId ?? tabs.activeID
            layout(root: nil, focus: nil, mode: mode); activate(shown); return
        }
        // An empty pane made here takes the focus, so the next session or browser tab chosen lands in it.
        if let root = tabs.layout?.root, tabs.layout?.splitting == true, let focus = tabs.layout?.focusedPaneId {
            let next = root.splitting(focus)
            let made = next.leaves.first { leaf in !root.leaves.contains { $0.id == leaf.id } }?.id
            layout(root: next, focus: made ?? focus, mode: mode)
        } else {
            let first = "pane-" + UUID().uuidString, second = "pane-" + UUID().uuidString
            // What is on show goes first: a session, or a browser tab on its own (28 Oct). Beside it the next
            // session, else a browser tab, else nothing yet.
            let active = effects.shownBrowser() ?? tabs.activeID
            let next = tabs.tabs.first { $0.id != active && !$0.isHoot }?.id ?? effects.browserTabs().first { $0 != active }
            layout(root: .split(id: "split-" + UUID().uuidString, horizontal: true, ratio: 0.5,
                first: .leaf(id: first, tabId: active), second: .leaf(id: second, tabId: next)), focus: next == nil ? second : first, mode: mode)
            activate(active ?? next)
        }
    }
    // MARK: Browser tabs in the split (Asad, 28 Oct: "browser in other side too, not just 2 sessions")

    /// Whether a pane's tab is a native browser tab (open now, or held by a pane when it closed).
    func isBrowser(_ id: String) -> Bool { browserPanes.contains(id) || effects.browserTabs().contains(id) }

    /// A browser tab's page can be in one place only: shown twice, the copy outside the focused pane is cleared.
    private func onePlacePerBrowser(_ root: PaneNode, keeping focus: String?) -> PaneNode {
        var keeper: [String: String] = [:]
        for leaf in root.leaves {
            if let tab = leaf.tabId, isBrowser(tab), keeper[tab] == nil || leaf.id == focus { keeper[tab] = leaf.id }
        }
        return root.mapLeaves { id, tab in
            guard let tab, let pane = keeper[tab], pane != id else { return .leaf(id: id, tabId: tab) }
            return .leaf(id: id, tabId: nil)
        }
    }

    /// A tab's "Open in Split View" (and the tools' split-with): that session or browser tab beside the one on show.
    /// With the split on it goes into the pane beside the focused one; already in a pane, that pane only takes the focus.
    private func splitWith(_ id: String) throws {
        let browser = effects.browserTabs().contains(id)
        if !browser { bringToBar(id) }
        guard !id.isEmpty, browser || tabs.tabs.contains(where: { $0.id == id && !$0.isHoot }) else {
            try refuse("That session or browser tab is no longer open.")
        }
        if let root = tabs.layout?.root, tabs.layout?.splitting == true, tabs.layout?.swarm != true, root.leaves.count > 1 {
            if let pane = root.leaves.first(where: { $0.tabId == id }) { layout(root: root, focus: pane.id); activate(id); return }
            let leaves = root.leaves, at = leaves.firstIndex { $0.id == tabs.layout?.focusedPaneId } ?? 0
            let beside = leaves[(at + 1)...].first ?? leaves[..<at].last ?? leaves[at]
            layout(root: root.showing(id, in: beside.id), focus: beside.id, mode: "split")
        } else {
            let shown = effects.shownBrowser() ?? tabs.activeID
            let host = shown != id ? shown : tabs.tabs.first { $0.id != id && !$0.isHoot }?.id
            let first = "pane-" + UUID().uuidString, second = "pane-" + UUID().uuidString
            layout(root: .split(id: "split-" + UUID().uuidString, horizontal: true, ratio: 0.5,
                first: .leaf(id: first, tabId: host), second: .leaf(id: second, tabId: id)), focus: second, mode: "split")
        }
        activate(id)
    }

    /// A native browser tab closed (its strip ✕, ⌘W inside it, a tool, its profile going). A pane that showed it shows
    /// `next` when that is not in a pane already, else it is left empty; the selection follows when it was on show.
    func browserClosed(_ id: String, next: String? = nil) {
        guard let root = tabs.layout?.root, root.leaves.contains(where: { $0.tabId == id }) else { browserPanes.remove(id); return }
        let wasSelected = sidebar.selectedId == id
        let shown = next.flatMap { next in root.leaves.contains { $0.tabId == next } ? nil : next }
        layout(root: root.leaves.filter { $0.tabId == id }.reduce(root) { $0.showing(shown, in: $1.id) })
        browserPanes.remove(id)
        if wasSelected { activate(shown) }
        if let saved = memory() { effects.remember(saved) }
        effects.changed()
    }

    /// What the window shows, for the tools: whether it is split, and each pane left to right in the tree
    /// (its id, the session or browser tab in it, and which one has the focus).
    func paneSummary() -> [String: Any] {
        let layout = tabs.layout
        let panes: [[String: Any]] = (layout?.splitting == true && layout?.swarm != true ? layout?.root?.leaves ?? [] : []).map { leaf in
            let kind = leaf.tabId.map { held in isBrowser(held) ? "browser" : (tabs.tabs.first { $0.id == held }?.kind ?? "session") } ?? "empty"
            return ["pane": leaf.id, "tab": leaf.tabId as Any? ?? NSNull(), "kind": kind, "focused": leaf.id == layout?.focusedPaneId]
        }
        return ["split": !panes.isEmpty, "panes": panes]
    }

    private func layout(root: PaneNode?, focus: String? = nil, mode: String? = nil) {
        let old = tabs.layout ?? WindowLayout()
        let focused = focus ?? old.focusedPaneId ?? root?.leaves.first?.id
        let root = root.map { onePlacePerBrowser($0, keeping: focused) }
        browserPanes = Set((root?.leaves ?? []).compactMap(\.tabId).filter(isBrowser))
        tabs.layout = WindowLayout(mode: mode ?? old.mode, root: root, focusedPaneId: root == nil ? nil : focused,
            primaryPaneId: root?.leaves.contains(where: { $0.id == old.primaryPaneId }) == true ? old.primaryPaneId : root?.leaves.first?.id,
            modeSwitch: true, splitOffer: false, swarmSessions: old.swarmSessions)
        layoutOwned = true
    }
}

private extension PaneNode {
    func wire() -> [String: Any] {
        switch self {
        case .leaf(let id, let tab): return ["type": "leaf", "id": id, "tabId": tab as Any? ?? NSNull()]
        case .split(let id, let horizontal, let ratio, let a, let b):
            return ["type": "split", "id": id, "direction": horizontal ? "horizontal" : "vertical", "ratio": ratio, "children": [a.wire(), b.wire()]]
        }
    }

    func hasSplit(_ target: String) -> Bool {
        if case .split(let id, _, _, let a, let b) = self { return id == target || a.hasSplit(target) || b.hasSplit(target) }; return false
    }
    func mapLeaves(_ change: (String, String?) -> PaneNode) -> PaneNode {
        switch self {
        case .leaf(let id, let tab): return change(id, tab)
        case .split(let id, let horizontal, let ratio, let a, let b): return .split(id: id, horizontal: horizontal, ratio: ratio, first: a.mapLeaves(change), second: b.mapLeaves(change))
        }
    }
    func showing(_ tab: String?, in pane: String) -> PaneNode { mapLeaves { .leaf(id: $0, tabId: $0 == pane ? tab : $1) } }
    func clearing(_ tab: String) -> PaneNode { mapLeaves { .leaf(id: $0, tabId: $1 == tab ? nil : $1) } }
    func splitting(_ pane: String) -> PaneNode {
        mapLeaves { id, tab in id == pane ? .split(id: "split-" + UUID().uuidString, horizontal: true, ratio: 0.5,
            first: .leaf(id: id, tabId: tab), second: .leaf(id: "pane-" + UUID().uuidString, tabId: nil)) : .leaf(id: id, tabId: tab) }
    }
    func resized(_ target: String, _ value: Double) -> PaneNode {
        switch self {
        case .leaf: return self
        case .split(let id, let horizontal, let ratio, let a, let b): return .split(id: id, horizontal: horizontal, ratio: id == target ? value : ratio, first: a.resized(target, value), second: b.resized(target, value))
        }
    }
    func removing(_ target: String) -> PaneNode? {
        switch self {
        case .leaf(let id, _): return id == target ? nil : self
        case .split(let id, let horizontal, let ratio, let a, let b):
            guard let first = a.removing(target) else { return b }
            guard let second = b.removing(target) else { return a }
            return .split(id: id, horizontal: horizontal, ratio: ratio, first: first, second: second)
        }
    }
}
