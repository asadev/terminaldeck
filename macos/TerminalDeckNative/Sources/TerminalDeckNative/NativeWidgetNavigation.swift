import AppKit
import TerminalDeckNativeCore

@MainActor
enum NativeWidgetNavigation {
    static func open(_ url: URL) {
        if isPairingLink(url) { openPairing(); return }
        if isServerAddressLink(url) { openServerAddress(); return }
        guard url.scheme == "terminaldeck", url.host == "session" || url.host == "widget" else { return }
        let path = String(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath.dropFirst() ?? "")
            .removingPercentEncoding ?? ""
        guard !path.isEmpty else { return }
        NativeLaunchWindow.ensureShown(front: true)
        if url.host == "session" {
            // A widget can launch a closed window. Wait for the app's session list before selecting the actual session.
            select(session: path)
        } else if path == "tasks" {
            TKTasksProjectScope.shared.choose(nil)
            let work = MyWorkModel.shared
            work.selectTab(.table); work.view.filters = ListFilters(); work.view.filters.due = .throughToday
            work.view.showClosed = false; work.trashOpen = false
            UserDefaults.standard.set(UIGTasksSection.work.rawValue, forKey: "page.tasks.section21")
            AppModel.shared.select("tasks")
        }
        else if path == "week", let source = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "session" })?.value
                    ?? DeckWidgetStore.read().usageSessionId {
            // The weekly ring belongs to a session; its usage ring sits in that session's toolbar.
            select(session: source)
        } else {
            // Machine and Needs you have no separate page on the Mac: Overview is the existing place for both.
            AppModel.shared.select("overview")
        }
    }
    static func isPairingLink(_ url: URL) -> Bool { url.scheme == "terminaldeck" && url.host == "pair" }
    static func isServerAddressLink(_ url: URL) -> Bool { url.scheme == "terminaldeck" && url.host == "server" }
    /// A server's address link (`terminaldeck://server?r=…&h=…&k=…`) clicked on this Mac. It is what a phone pastes
    /// under Add a server; this Mac adds servers with a sign-in, so it opens Servers with one line saying where the
    /// address goes. Nothing from the link is read or kept. Arrival is checked like the pairing link's: the main
    /// window up with Servers chosen, asked again every 2 s if a cold launch from the link missed it.
    private static func openServerAddress() {
        NativeLaunchWindow.ensureShown(front: true)
        AppModel.shared.select(SHELLRoutes.serverAddressAction)
        Task {
            for attempt in 1...40 {
                try? await Task.sleep(for: .milliseconds(250))
                if NativeLaunchWindow.mainWindow()?.isVisible == true, AppModel.shared.sidebarSelection == SHELLRoutes.servers { return }
                if attempt % 8 == 0 { NativeLaunchWindow.ensureShown(front: true); AppModel.shared.select(SHELLRoutes.serverAddressAction) }
            }
            AppModel.shared.engine.log.note("server address link: Servers did not open")
        }
    }
    /// A phone's pairing link (`terminaldeck://pair?…`) clicked on this Mac (review install-24 S5). This Mac owns the
    /// scheme now, so the link lands here; a Mac pairs from Devices › Pair a device, whose sheet says what to do on
    /// the phone. Nothing from the link is used: the Mac shows its own fresh code. The main window opens the Devices
    /// window, so after a cold launch from the link that ask is repeated until the Devices window is actually up.
    private static func openPairing() {
        NativeLaunchWindow.ensureShown(front: true)
        AppModel.shared.requestDevicesWindow(pair: true)
        Task {
            for attempt in 1...40 {
                try? await Task.sleep(for: .milliseconds(250))
                if let devices = NSApp.windows.first(where: { $0.identifier?.rawValue == DevicesWindow.sceneID && $0.isVisible }) {
                    AppModel.shared.engine.log.note("pairing link: the Devices window opened" + (devices.attachedSheet != nil ? " with Pair a device" : ""))
                    return
                }
                if attempt % 8 == 0 { AppModel.shared.requestDevicesWindow(pair: true) }
            }
            AppModel.shared.engine.log.note("pairing link: the Devices window did not open")
        }
    }
    private static func select(session id: String) {
        Task {
            for _ in 0..<40 {
                if AppModel.shared.sidebar?.item(id: id) != nil { AppModel.shared.selectTab(id); return }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}
