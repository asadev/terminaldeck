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
        if id == servers || id == Sidebar21Pages.projectsID { return true }
        return id.hasPrefix(projectPrefix) && !id.hasSuffix(settingsSuffix) && id.count > projectPrefix.count
    }

    /// An id that opens a place with an action (or a project's settings window).
    static func isAction(_ id: String) -> Bool {
        id == "servers:add" || id == serverAddressAction || id == "devices:pair"
            || (id.hasPrefix(projectPrefix) && id.hasSuffix(settingsSuffix))
    }

    /// The action carried into the place's draws (Add a server…, Pair a device…) until another place is chosen.
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
        case "devices:pair":
            AppModel.shared.requestDevicesWindow(pair: true)
            return nil
        case devices:
            AppModel.shared.requestDevicesWindow()
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
        case Sidebar21Pages.projectsID:
            return AnyView(Sidebar21ProjectsScreen())
        case servers:
            let add = asked("servers:add")
            return AnyView(NativeMachinesScreen(initialRoute: add ? .add : .list).id("servers-\(actionNonce)"))
        case devices:
            let pair = asked("devices:pair")
            return AnyView(MACHINESDevicesScreen(pairOnOpen: pair).id("devices-\(actionNonce)"))
        default:
            let path = String(id.dropFirst(projectPrefix.count))
            let project = project(forPath: path)
            return AnyView(ProjectPage(project: project).id(project.id))
        }
    }
}
