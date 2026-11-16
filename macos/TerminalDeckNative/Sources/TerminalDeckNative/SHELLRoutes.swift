import SwiftUI
import TerminalDeckNativeCore

/// The new side panel's native-only places (SHELL-SPEC §4): a project's own page,
/// Servers and Devices. Like the Agents views and Receiver, the web page never hears
/// about them; AppModel keeps them as its selection and PageDetailView draws them.
/// Action ids ("servers:add", "devices:pair", "project:<path>:settings") open the
/// place with that action, or the project's settings window, and are never a selection.
@MainActor
enum SHELLRoutes {
    static let servers = "servers"
    static let devices = "devices"
    static let projectPrefix = "project:"
    static let settingsSuffix = ":settings"

    /// The old full Simulators page (kept in code, reachable from nowhere): every way in opens
    /// the phone panel instead (Asad 10 Oct, "retire full page of simulators").
    static let retiredSimulators = "simulators"

    /// The retired Overview page (Owner, 15 Nov: "we don't need overview page in any application anymore"). It only
    /// ever drew the current project's page, which stays under Projects. Every old way in (a saved pin, the hidden
    /// page's ⌘⇧D "Project dashboard", a tool's select, an old link) opens the current project's page, or the New
    /// session page when no project is open. Never a selection, never drawn.
    static let retiredOverview = "overview"
    static func overviewStandIn(current: String? = DeckProject.current) -> String {
        guard let current, isProject(path: current) else { return NativeLanding.pageID }
        return projectPrefix + current
    }

    /// The phone panel of the session on show (its window comes forward if popped out); on Hoot's page (only when the
    /// person opened Hoot) Hoot's own panel there; anywhere else the panel in its own phone window. With no device chosen
    /// it opens "Choose a device". 3 Nov (Asad: Hoot "should not be always open until we open the Hoot"): opening the
    /// phone panel never opens Hoot's page by itself any more.
    static func openPhonePanel(deviceID: String? = nil) {
        let app = AppModel.shared
        if let screen = app.currentScreen, NativeTerminalScreen.handles(screen.id) {
            _ = NativeUIGPhonePanel.open(session: NativeTerminalSessions.shared.session(for: screen.id), deviceID: deviceID)
            return
        }
        _ = NativeUIGPhonePanel.open(session: nil, deviceID: deviceID, ownWindow: !onHootsPage(app.currentScreen?.kind))
    }

    /// Hoot's page is what the main window shows now (the person opened it).
    static func onHootsPage(_ kind: String?) -> Bool { kind == "hoot" }

    /// A place this file draws (kept as the sidebar selection).
    static func owns(_ id: String?) -> Bool {
        guard let id else { return false }
        if id == servers || id == NativeLanding.pageID || id == Sidebar21Pages.projectsID || id == Sidebar21Pages.codeID || id == Sidebar21Pages.cloudID { return true }
        // Sessions in the Cloud: another machine's session (read-only) and a project's Earlier chats.
        if id.hasPrefix(SIDEBARCloudRows.sessionPrefix) || id.hasPrefix(SIDEBARCloudRows.earlierPrefix) { return true }
        return id.hasPrefix(projectPrefix) && !id.hasSuffix(settingsSuffix) && id.count > projectPrefix.count
    }

    /// An id that opens a place with an action (or a project's settings window).
    static func isAction(_ id: String) -> Bool {
        id == "servers:add" || id == serverAddressAction || id == "devices:pair"
            || (id.hasPrefix(projectPrefix) && id.hasSuffix(settingsSuffix))
    }

    /// The action carried into the place's draws (Add a server…) until another place is chosen.
    /// Read, never taken: the detail is built several times per pass and only the last build is drawn.
    private static var pendingAction: String?
    /// Changes when an action is asked for again on a page already on show, so it opens fresh.
    private(set) static var actionNonce = 0

    /// Turns an action id into the place it belongs to; nil when the id was handled here
    /// without changing the selection (a project's settings window).
    static func resolve(_ id: String) -> String? {
        switch id {
        case "servers:add", serverAddressAction:
            pendingAction = id; actionNonce &+= 1
            return servers
        case "devices:pair", devices:
            // Owner, 14 Nov: Devices is a page of Settings (an old action id, a saved shortcut or a phone link opens it).
            AppModel.shared.openDevices()
            return nil
        default:
            // Another place ends the action; its own place (chosen again, or echoed back by the page) keeps it.
            if let pending = pendingAction, id != (pending.hasPrefix("servers:") ? servers : devices) { pendingAction = nil }
            if id.hasPrefix(projectPrefix), id.hasSuffix(settingsSuffix) {
                let path = String(id.dropFirst(projectPrefix.count).dropLast(settingsSuffix.count))
                // A plain folder has no project settings yet: it opens the guide to make it one.
                if !path.isEmpty {
                    if isProject(path: path) { ProjectPage.openSettings(project(forPath: path)) }
                    else { PROJGuideWindow.open(folder: path) }
                }
                return nil
            }
            return id
        }
    }

    /// A phone's server address link (`terminaldeck://server?…`) clicked on this Mac (review install-24 follow-up):
    /// Servers opens with one line saying the address is for the phone. The Mac adds servers with a sign-in.
    static let serverAddressAction = "servers:address"
    static let serverAddressLine = "That link is a server address for Terminal Deck on your phone: there, choose Add a server and paste it."

    static func asked(_ action: String) -> Bool {
        pendingAction == action
    }

    /// The project an open folder belongs to. Asad, 11 Oct: opening a folder is a plain session, not a project;
    /// a project is made through the New project guide. So a folder outside every registered project is NOT
    /// registered here any more: it gets a stand-in (never saved) with the folder's name, and its sessions stay
    /// under Independent. The open-folder list itself (which folders tools may touch) is unchanged.
    static func project(forPath path: String) -> PROJProject {
        let registry = self.registry
        let id = PROJProjects.resolve(projectID: nil, folder: path, projects: registry)
        if id != PROJProjects.independentID, let found = registry.first(where: { $0.id == id }) { return found }
        let name = (path as NSString).lastPathComponent
        return PROJProject(id: PROJSetup.projectID(for: name, taken: Set(registry.map(\.id))), name: name.isEmpty ? path : name, folders: [path])
    }

    /// True when the folder lies inside a registered project (not a plain folder under Independent).
    static func isProject(path: String) -> Bool {
        PROJOpenFolders.isProject(path, registry: registry)
    }
    /// The registered projects: the side panel's copy once read, else the list the app published at start.
    static var registry: [PROJProject] {
        let read = SIDEBARProjectStore.shared.projects
        return read.isEmpty ? PROJProjects.defaults : read
    }

    static func detail(kind: String, id: String) -> AnyView? {
        guard kind == "panel", owns(id) else { return nil }
        switch id {
        case NativeLanding.pageID:
            // Owner, 14 Nov: the app opens here; nothing is made until he sends his first message.
            return AnyView(NativeLandingPage(model: NativeLanding.model))
        case Sidebar21Pages.projectsID:
            return AnyView(Sidebar21ProjectsScreen())
        case Sidebar21Pages.codeID:
            return AnyView(NativeCodeBackupPage())
        case servers:
            let add = asked("servers:add")
            return AnyView(NativeMachinesScreen(initialRoute: add ? .add : .list).id("servers-\(actionNonce)"))
        case Sidebar21Pages.cloudID:
            // Owner, 14 Nov: what is in his Cloud is a page of the main window, no longer a separate grey window.
            return AnyView(NativeCloudContentsPage())
        case _ where id.hasPrefix(SIDEBARCloudRows.sessionPrefix):
            let ref = String(id.dropFirst(SIDEBARCloudRows.sessionPrefix.count))
            return AnyView(NativeCloudChatPage(ref: ref).id(id))
        case _ where id.hasPrefix(SIDEBARCloudRows.earlierPrefix):
            return AnyView(NativeCloudEarlierChatsPage(project: String(id.dropFirst(SIDEBARCloudRows.earlierPrefix.count))).id(id))
        default:
            let path = String(id.dropFirst(projectPrefix.count))
            let project = project(forPath: path)
            return AnyView(ProjectPage(project: project).id(project.id))
        }
    }
}
