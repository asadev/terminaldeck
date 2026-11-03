import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Shared content for both right-click and the ellipsis. Handlers are injectable:
/// a hidden render can exercise the same menu without calling the engine.
@MainActor
struct AgentMenu: View {
    enum Action: String, CaseIterable, Identifiable {
        case wake, pause, open, watch, assign, reports, copy, duplicate, file, reset, stop, archive
        var id: String { rawValue }
        var title: String {
            switch self {
            case .wake: "Wake now"
            case .pause: "Pause"
            case .open: "Open profile"
            case .watch: "Watch"
            case .assign: "Assign task…"
            case .reports: "Reports to"
            case .copy: "Copy agent ID"
            case .duplicate: "Duplicate"
            case .file: "Show its file"
            case .reset: "Reset sessions"
            case .stop: "Stop everything it is running"
            case .archive: "Archive agent…"
            }
        }
        var changes: Bool { ![.open, .watch, .copy, .file].contains(self) }
    }

    struct Manager: Identifiable {
        let id: String
        let name: String
    }

    struct Actions {
        var name: String
        var paused = false
        var managerID: String?
        var managers: [Manager] = []
        /// Nil means unavailable, never an inert control pretending to work.
        var perform: [Action: () -> Void] = [:]
        var reportsTo: ((String?) -> Void)?
        /// Deck Memory: put it in its project's lead seat, or take it out. Nil hides the item (Hoot).
        /// Deck Memory 3b: one more session on this agent's seat, with its own job. Nil hides the item.
        var addHand: (() -> Void)?
        var leadTitle: String?
        var setLead: (() -> Void)?
        var leadReason: String?
        /// An archived agent: the last item deletes it for good instead of archiving it.
        var archived = false
        var reasons: [Action: String] = [:]
        var busy = false
    }

    let actions: Actions
    init(actions: Actions) { self.actions = actions }
    init(agent: AGTAgent) { actions = Self.actions(for: agent) }

    /// Lanes can add a capability to the shared actions without rebuilding the menu.
    static func actions(for agent: AGTAgent) -> Actions { AgentMenuNative.actions(agent) }

    /// The same named confirmation used by built-in actions and injected writes.
    static func confirmChange(title: String, detail: String, button: String,
                              accepted: @escaping () -> Void) {
        AgentMenuNative.confirm(title, detail: detail, button: button, accepted: accepted)
    }

    var body: some View {
        item(.wake)
        item(.pause, title: actions.paused ? "Resume" : "Pause")
        Divider()
        item(.open)
        item(.watch)
        item(.assign)
        if let addHand = actions.addHand {
            Button("Add a hand…") { addHand() }
                .disabled(actions.busy)
                .help("Start one more session on this seat with its own job. The hands share the seat's memory.")
        }
        Divider()
        Menu("Reports to") {
            manager("Independent", id: nil)
            ForEach(actions.managers) { manager($0.name, id: $0.id) }
        }
        .disabled(actions.reportsTo == nil || actions.busy)
        .help(actions.reasons[.reports] ?? "Choose who this agent reports to")
        if let title = actions.leadTitle {
            Button(title) { actions.setLead?() }
                .disabled(actions.setLead == nil || actions.busy)
                .help(actions.leadReason ?? "A project has one lead. Hoot gives the lead goals; the lead runs the project's agents.")
        }
        item(.copy)
        item(.duplicate)
        item(.file)
        item(.reset)
        Divider()
        item(.stop, role: .destructive)
        item(.archive, title: actions.archived ? "Delete permanently…" : nil, role: .destructive)
    }

    private func item(_ action: Action, title: String? = nil, role: ButtonRole? = nil) -> some View {
        Button(title ?? action.title, role: role) { actions.perform[action]?() }
            .disabled(actions.perform[action] == nil || (actions.busy && action.changes))
            .help(actions.reasons[action] ?? title ?? action.title)
    }

    /// Each manager with its own picture (Hoot's owl, the agent's avatar); the current one is ticked.
    private func manager(_ title: String, id: String?) -> some View {
        Toggle(isOn: Binding(get: { actions.managerID == id }, set: { _ in actions.reportsTo?(id) })) {
            DeckRowLabel(title, image: id.map { DeckRowIcon.agent(id: $0) } ?? DeckRowIcon.independent)
        }
    }
}

struct AgentMenuButton: View {
    let actions: AgentMenu.Actions
    init(actions: AgentMenu.Actions) { self.actions = actions }
    init(agent: AGTAgent) { actions = AgentMenu.actions(for: agent) }
    var body: some View {
        Menu { AgentMenu(actions: actions) } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15)).foregroundStyle(.secondary)
                .frame(width: 28, height: 28).contentShape(.rect)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Actions for \(actions.name)")
        .accessibilityLabel("Actions for \(actions.name)")
    }
}

/// All writes ask first, then use the existing task/configuration channel.
/// Tools stay the existing tasks.agents, tasks.local_change, agents.set_reports_to,
/// sessions.stop and agents-watch read tools; no competing profile store.
@MainActor
private enum AgentMenuNative {
    static func actions(_ agent: AGTAgent) -> AgentMenu.Actions {
        let store = AGTAgentsStore.shared
        let profile = store.profile(agent)
        let rows = store.live.filter { agent.liveIDs.contains($0.id) && $0.state != .offline }
        let tasks = Array(Set(rows.filter { $0.sessionID != nil }.compactMap(\.taskID))).sorted()
        var value = AgentMenu.Actions(name: agent.name, paused: agent.status == "paused", managerID: agent.reportsTo)
        value.busy = store.busy || TasksStore.shared.busy
        value.perform[.open] = {
            // Hoot's profile lives on the Hoot page.
            if agent.kind == .hoot { HootProfileRoute.open(); return }
            store.openProfile = agent.id; AppModel.shared.select(NativeINT2Navigation.allID)
        }
        value.perform[.copy] = {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(agent.id, forType: .string)
        }
        value.perform[.watch] = { AgentMenuWindows.watch(agent) }
        if agent.kind == .profile, agent.status != "archived" { value.addHand = { AGTHandsStore.shared.adding = agent } }
        // A session that works as the lead (opened in its folder) is not the lead itself: who leads is changed on the lead.
        if agent.kind != .hoot, !AGTLeads.isVacant(agent), AGTLeads.worksAsLead(agent) == nil {
            if let led = AGTLeads.madeLead(agent) {
                value.leadTitle = "Stop leading \(led.name)"
                value.setLead = {
                    confirm("Stop \(agent.name) leading \(led.name)?", detail: "The lead seat keeps its memory for whoever leads next. With no lead, Hoot assigns \(led.name)'s agents directly.", button: "Stop leading") {
                        Task { await AGTLeads.setLead(nil, of: led) }
                    }
                }
            } else if let project = AGTLeads.project(agent), project.id != PROJProjects.independentID {
                let current = AGTSeats.lead(of: project)
                value.leadTitle = "Make lead of \(project.name)"
                value.setLead = {
                    confirm("Make \(agent.name) the lead of \(project.name)?",
                            detail: (current.map { "\($0.name) leads \(project.name) now and will stop leading. " } ?? "")
                                + "Hoot gives \(agent.name) goals for \(project.name); it runs that project's agents and takes over the lead seat's memory.",
                            button: "Make lead") { Task { await AGTLeads.setLead(agent, of: project) } }
                }
            } else {
                value.leadTitle = "Make lead of its project"
                value.leadReason = AGTLeads.leadRefusal(agent)
            }
        }
        if let path = agent.sourceFile ?? profile?.instructionsFile {
            value.perform[.file] = {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        } else { value.reasons[.file] = "This agent has no saved file." }

        if let profile {
            let blocked = AGTOrgChart.below(agent.id, managers: store.managers).union([agent.id])
            value.managers = [.init(id: AGTDirectory.hootID, name: "Hoot")] + store.agents
                .filter { $0.kind == .profile && !blocked.contains($0.id) && $0.status != "archived" }
                .map { .init(id: $0.id, name: $0.name) }
            let choices = value.managers
            value.reportsTo = { manager in
                let name = manager.flatMap { id in choices.first { $0.id == id }?.name } ?? "Independent"
                confirm("Change who \(agent.name) reports to?", detail: "Reports to: \(name).", button: "Change") {
                    Task { await store.setReportsTo(agent.id, manager) }
                }
            }
            if profile.status != .archived {
                value.perform[.wake] = {
                    confirm("Wake \(agent.name)?", detail: "It will take its queued work. This can start its coding AI.", button: "Wake now") {
                        Task { await wake(profile.id) }
                    }
                }
                value.perform[.pause] = {
                    let paused = profile.status == .paused
                    confirm("\(paused ? "Resume" : "Pause") \(agent.name)?",
                            detail: paused ? "It will take new work again." : "It takes no new work. Its current work carries on.",
                            button: paused ? "Resume" : "Pause") {
                        lifecycle(agent, action: paused ? "resume" : "pause")
                    }
                }
                value.perform[.assign] = { AgentMenuWindows.assign(agent) }
                value.perform[.archive] = {
                    confirm("Archive \(agent.name)?", detail: "Its profile is kept. It will no longer take new work. Current work carries on.", button: "Archive") {
                        lifecycle(agent, action: "archive")
                    }
                }
            } else {
                value.archived = true
                value.perform[.archive] = {
                    confirm("Delete \(agent.name) permanently?",
                            detail: "Its profile and its instructions are removed and cannot be restored. The memory of its role stays, so whoever is hired into that role next inherits it.",
                            button: "Delete") {
                        Task {
                            guard await change("tasks:agent-remove", [profile.id]) else { return }
                            // Gone at once: its page, its settings window and its cached profile view close now.
                            AGOPTProfileModel.owner(profile.id).closeGone()
                            if store.openProfile == profile.id { store.openProfile = nil }
                        }
                    }
                }
            }
            value.perform[.duplicate] = {
                confirm("Duplicate \(agent.name)?", detail: "Creates a paused copy with the same instructions and permissions.", button: "Duplicate") {
                    Task {
                        var copy = profile
                        copy.name = String((profile.name + " copy").prefix(60))
                        copy.id = AgentForm.slug(copy.name, taken: store.profiles.map(\.id))
                        copy.status = .paused; copy.statusAt = nil
                        copy.sourceFile = nil; copy.sourceDirectory = nil
                        copy.instructionsFile = nil; copy.syncedAt = nil
                        copy.syncStatus = nil; copy.syncError = nil
                        if await store.save(copy) { store.openProfile = copy.id }
                    }
                }
            }
            // close-session deliberately preserves conversationId. It is a stop,
            // never misrepresented as clearing the agent's saved conversation.
            value.reasons[.reset] = "This agent keeps its saved conversations; a fresh-session command is not available."
            if !tasks.isEmpty {
                value.perform[.stop] = {
                    confirm("Stop everything \(agent.name) is running?", detail: "Pauses this agent and closes \(tasks.count) task sessions. Task notes are kept.", button: "Stop") {
                        Task {
                            if profile.status == .active {
                                guard await change("tasks:agent-status", [profile.id, "pause"]) else { return }
                            }
                            for id in tasks { guard await change("tasks:close-session", [id]) else { return } }
                        }
                    }
                }
            } else { value.reasons[.stop] = "This agent has no running task sessions." }
        } else {
            value.reasons[.reports] = "Only saved agents can report to another agent."
            value.reasons[.pause] = "Only saved task agents can be paused."
            value.reasons[.archive] = "Only saved task agents can be archived."
            value.reasons[.duplicate] = "Save this agent before duplicating it."
            if agent.kind == .hoot {
                value.perform[.wake] = {
                    confirm("Wake Hoot?", detail: "Starts Hoot's configured coding AI.", button: "Wake now") { NativeHootModel.shared.ensure() }
                }
                value.perform[.assign] = { AgentMenuWindows.assign(agent) }
                value.perform[.stop] = {
                    confirm("Stop Hoot?", detail: "Stops Hoot's current conversation. Other agents' work carries on.", button: "Stop") {
                        Task {
                            do { _ = try await EngineBridge.shared.invoke("hoot:stop"); NativeHootModel.shared.refresh() }
                            catch { store.message = error.localizedDescription }
                        }
                    }
                }
            }
        }
        return value
    }

    static func wake(_ id: String) async {
        let store = AGTAgentsStore.shared
        guard store.fixture == nil else { store.message = "This preview cannot change real agents."; return }
        store.busy = true
        defer { store.busy = false }
        do {
            let answer = CodingAIJSON(try await EngineBridge.shared.invoke("agopt:profile-action", [["id": id, "action": "wake"]]))
            store.message = answer["message"].string ?? answer["result"]["message"].string
        } catch { store.message = error.localizedDescription }
    }

    static func lifecycle(_ agent: AGTAgent, action: String) {
        guard let id = agent.profileID else { return }
        Task { await change("tasks:agent-status", [id, action]) }
    }

    @discardableResult static func change(_ channel: String, _ args: [Any?]) async -> Bool {
        let store = AGTAgentsStore.shared
        guard store.fixture == nil else { store.message = "This preview cannot change real agents."; return false }
        store.busy = true
        defer { store.busy = false }
        let result = await TasksStore.shared.call(channel, args)
        TasksStore.shared.adopt(result)
        store.message = result.ok ? nil : result.message ?? "That change did not finish."
        return result.ok
    }

    static func confirm(_ title: String, detail: String, button: String, accepted: @escaping () -> Void) {
        guard AGTAgentsStore.shared.fixture == nil else { return }
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: button); alert.addButton(withTitle: "Cancel")
        if NativeFront.personActing {
            guard alert.runModal() == .alertFirstButtonReturn else { return } // front-ok: person's menu action
            accepted(); return
        }
        // The item was pressed while the app sits behind another one (a tool or an assistive app pressed
        // it). The app does not come forward for that. The question used to wait and then pop up, out
        // of context, the next time the app was opened, and meanwhile the press looked like it did
        // nothing. It is asked on the app's own window instead, at once, without taking the front.
        let window = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.orderedWindows.first { $0.isVisible && !$0.isSheet && $0.canBecomeMain }
        guard let window else {
            AGTAgentsStore.shared.message = "That needs your OK and no window was open to ask in. Open Terminal Deck and choose it again."
            return
        }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { accepted() }
        }
    }
}

@MainActor
private enum AgentMenuWindows {
    private static var windows: [String: NSPanel] = [:]
    private static var lifetimes: [String: AgentMenuWindowLifetime] = [:]
    static func watch(_ agent: AGTAgent) {
        guard AGTAgentsStore.shared.fixture == nil else { return }
        let model = AWAgentsWatchModel()
        model.source = .terminalDeck
        model.search = agent.name
        model.selectedID = agent.liveIDs.first
        show(key: "watch-" + agent.id, title: "Watch \(agent.name)", size: NSSize(width: 900, height: 600),
             view: AWAgentsWatchScreen(model: model), onClose: { model.stop() })
    }

    static func assign(_ agent: AGTAgent) {
        guard AGTAgentsStore.shared.fixture == nil else { return }
        show(key: "assign-" + agent.id, title: "Assign task to \(agent.name)", size: NSSize(width: 660, height: 400),
             view: AgentMenuAssignment(agent: agent) { close("assign-" + agent.id) }, asSheet: true)
    }

    private static func show<Content: View>(key: String, title: String, size: NSSize, view: Content,
                                          asSheet: Bool = false, onClose: @escaping @MainActor () -> Void = {}) {
        NativeFront.whenPersonActs("main") {
            if let existing = windows[key], existing.isVisible {
                if !asSheet { existing.makeKeyAndOrderFront(nil) } // front-ok: inside NativeFront.whenPersonActs above (the person's menu action)
                return
            }
            let parent = asSheet ? (NSApp.mainWindow ?? NSApp.keyWindow) : nil
            if asSheet && (parent == nil || parent?.attachedSheet != nil) {
                AGTAgentsStore.shared.message = "Close the current sheet, then assign this task from the main window."
                return
            }
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = title; panel.isReleasedWhenClosed = false
            panel.contentMinSize = size
            panel.contentView = NSHostingView(rootView: view)
            let lifetime = AgentMenuWindowLifetime {
                onClose()
                windows.removeValue(forKey: key)
                lifetimes.removeValue(forKey: key)
            }
            lifetimes[key] = lifetime; panel.delegate = lifetime
            panel.center(); windows[key] = panel
            if let parent { parent.beginSheet(panel) }
            else { panel.makeKeyAndOrderFront(nil) } // front-ok: inside NativeFront.whenPersonActs above (the person's menu action)
        }
    }

    private static func close(_ key: String) {
        guard let panel = windows[key] else { return }
        if let parent = panel.sheetParent { parent.endSheet(panel) }
        panel.close()
    }
}

/// The watch owns file/event subscriptions only while its window is open.
@MainActor
private final class AgentMenuWindowLifetime: NSObject, NSWindowDelegate {
    let closed: @MainActor () -> Void
    init(closed: @escaping @MainActor () -> Void) { self.closed = closed }
    func windowWillClose(_ notification: Notification) { closed() }
}

/// "Assign task": the one create card (NativeTaskPopupCreate), with this agent already chosen.
private struct AgentMenuAssignment: View {
    let agent: AGTAgent
    let close: () -> Void
    var body: some View {
        NativeTaskCreatePopup(preset: TaskCreateEntry.agent(id: agent.profileID ?? "hoot", name: agent.name, project: agent.project).preset,
                              onClose: close)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
