import AppKit
import Observation
import TerminalDeckNativeCore

/// The one model behind every window: the engine process, the main page
/// (sidebar, tabs and title come from it), the Settings page, and the pages of
/// screens opened in their own windows.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let engine: EngineController
    @ObservationIgnored let web: WebBridge
    @ObservationIgnored let settingsWeb: WebBridge

    // Main page
    private(set) var pageReady = false
    /// The main page has a dialog open: it shows in front of any native screen.
    private(set) var pageModalOpen = false
    private(set) var pageTitle: String?
    private(set) var pageSubtitle: String?
    private(set) var pageFailure: EngineFailure?
    /// nil until the page's first `sidebar` message — the sidebar stays empty, never fake.
    private(set) var sidebar: SidebarState?
    private(set) var sidebarSelection: String?
    /// nil until the page's first `tabs` message.
    private(set) var tabs: TabsState?
    /// The native browser tab on show, when one is (the page knows nothing of these).
    private(set) var activeBrowserTab: String?
    /// Browser tabs shown in windows of their own (they leave the strip meanwhile).
    private(set) var poppedBrowserTabs: Set<String> = []
    @ObservationIgnored private var lastPageSelectedId: String?
    @ObservationIgnored private var lastActiveTabId: String?

    // Settings page
    private(set) var settingsSections: [SettingsSection] = []
    private(set) var settingsSelection: String?
    private(set) var settingsReady = false
    private(set) var settingsModalOpen = false
    private(set) var settingsFailure: String?
    /// Bumped to ask the main window to open (or focus) the Settings window.
    private(set) var settingsWindowRequest = 0
    /// Bumped when screens are waiting to be opened in windows of their own.
    private(set) var screenWindowRequest = 0
    @ObservationIgnored private var pendingScreens: [ScreenRef] = []
    /// Names the page gave screens it popped out, until their own page names them.
    @ObservationIgnored private var screenTitles: [ScreenRef: String] = [:]

    @ObservationIgnored private var engineURL: URL?

    // Screens in their own windows (one per ScreenRef), remembered across launches.
    @ObservationIgnored private var screens: [ScreenRef: ScreenModel] = [:]
    @ObservationIgnored private var openScreenOrder: [ScreenRef] = []
    @ObservationIgnored private var screensToRestore: [ScreenRef]
    /// Set when the app starts quitting, so windows closing on the way out stay remembered.
    @ObservationIgnored var isTerminating = false
    private static let openScreensKey = "openScreenWindows"

    private init() {
        // Last launch's theme, before any window is drawn (the page confirms it shortly).
        defer { restoreAppearance() }
        // The installed Terminal Deck (or a checkout, with TD_REPO) runs as the engine.
        engine = EngineController(configuration: InstalledTerminalDeck.configuration())
        BrowserTabsHook.connect()
        screensToRestore = ScreenRef.decodeList(UserDefaults.standard.data(forKey: Self.openScreensKey))
        web = WebBridge(log: engine.log)
        settingsWeb = WebBridge(log: engine.log, revealOnLoad: true)

        // A tab the browser opened itself (⌘T inside it, a link in a new tab) comes forward.
        BrowserTabsHook.provider?.onBrowserSelect { [weak self] id in
            guard let self else { return }
            self.poppedBrowserTabs.remove(id)
            self.activeBrowserTab = id
        }

        engine.onReady = { [weak self] url in
            guard let self else { return }
            self.engineURL = url
            EngineBridge.shared.configure(engineURL: url)
            self.web.load(url)
            for screen in self.screens.values { self.loadScreen(screen) }
        }

        web.onReady = { [weak self] in
            self?.pageReady = true
            self?.web.run(.nativeScreens(NativeScreens.registered))
            self?.web.focus()
        }
        web.onMessage = { [weak self] message in self?.handleMainPage(message) }
        web.onReloading = { [weak self] in
            self?.pageReady = false
            self?.pageModalOpen = false
        }
        web.onLoadFailed = { [weak self] message in
            self?.pageReady = false
            self?.pageFailure = EngineFailure(title: "Terminal Deck couldn't load", message: message, detail: nil)
        }

        settingsWeb.onReady = { [weak self] in self?.settingsReady = true }
        settingsWeb.onMessage = { [weak self] message in self?.handleSettingsPage(message) }
        settingsWeb.onReloading = { [weak self] in
            self?.settingsReady = false
            self?.settingsModalOpen = false
        }
        settingsWeb.onLoadFailed = { [weak self] message in
            self?.settingsReady = false
            self?.settingsFailure = message
        }
    }

    // MARK: Messages from the pages

    private func handleMainPage(_ message: PageMessage) {
        switch message {
        case .title(let title, let subtitle):
            pageTitle = title
            pageSubtitle = subtitle
        case .sidebar(let state):
            // The page moved its own selection: follow it, away from a browser tab.
            if state.selectedId != lastPageSelectedId { activeBrowserTab = nil }
            lastPageSelectedId = state.selectedId
            sidebar = state
            sidebarSelection = state.selectedId
        case .tabs(let state):
            let active = state.activeID
            if active != lastActiveTabId, active != nil { activeBrowserTab = nil }
            lastActiveTabId = active
            tabs = state
        case .openSettings(let url, let section):
            showSettings(url, section: section)
        case .openWindow(let ref, let title):
            openScreenWindow(ref, title: title)
        case .appearance(let appearance):
            applyAppearance(appearance)
        case .pageModal(let open):
            pageModalOpen = open
        case .ready, .settingsSections:
            break
        }
    }

    private func handleSettingsPage(_ message: PageMessage) {
        switch message {
        case .settingsSections(let sections, let selected):
            settingsSections = sections
            settingsSelection = selected
        case .openSettings(let url, let section):
            showSettings(url, section: section)
        case .openWindow(let ref, let title):
            openScreenWindow(ref, title: title)
        case .appearance(let appearance):
            applyAppearance(appearance)
        case .pageModal(let open):
            settingsModalOpen = open
        case .ready, .title, .sidebar, .tabs:
            break
        }
    }

    private func handleScreenPage(_ screen: ScreenModel, _ message: PageMessage) {
        switch message {
        case .title(let title, let subtitle):
            screen.title = title
            screen.subtitle = subtitle
        case .openSettings(let url, let section):
            showSettings(url, section: section)
        case .openWindow(let ref, let title):
            openScreenWindow(ref, title: title)
        case .appearance(let appearance):
            applyAppearance(appearance)
        case .pageModal(let open):
            screen.modalOpen = open
        case .ready, .sidebar, .tabs, .settingsSections:
            break
        }
    }

    // MARK: Appearance

    private static let appearanceKey = "appAppearance"

    /// Paint every native window in the app's theme, and remember it so the next
    /// launch starts in it rather than flashing the Mac's scheme first.
    func applyAppearance(_ appearance: AppAppearance) {
        UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearanceKey)
        let target: NSAppearance? = switch appearance {
        case .followMac: nil
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        }
        if NSApplication.shared.appearance?.name != target?.name {
            NSApplication.shared.appearance = target
        }
    }

    private func restoreAppearance() {
        if let raw = UserDefaults.standard.string(forKey: Self.appearanceKey), let saved = AppAppearance(rawValue: raw) {
            applyAppearance(saved)
        }
    }

    /// Ask whichever window is up to open (or focus) this screen's window.
    func openScreenWindow(_ ref: ScreenRef, title: String? = nil) {
        if let title { screenTitles[ref] = title }
        if !pendingScreens.contains(ref) { pendingScreens.append(ref) }
        screenWindowRequest += 1
    }

    /// The screens waiting for a window — handed out once.
    func takePendingScreens() -> [ScreenRef] {
        defer { pendingScreens = [] }
        return pendingScreens
    }

    // MARK: Screens in their own windows

    /// The window for `ref` appeared: give it a page (one per screen).
    func attachScreen(_ ref: ScreenRef) -> ScreenModel {
        if let existing = screens[ref] { return existing }
        let screen = ScreenModel(ref: ref, log: engine.log)
        screen.web.onReady = { [weak screen] in
            screen?.ready = true
            screen?.web.run(.nativeScreens(NativeScreens.registered))
            screen?.web.focus()
        }
        screen.web.onMessage = { [weak self, weak screen] message in
            guard let self, let screen else { return }
            self.handleScreenPage(screen, message)
        }
        screen.web.onReloading = { [weak screen] in
            screen?.ready = false
            screen?.modalOpen = false
        }
        screen.web.onLoadFailed = { [weak screen] message in
            screen?.ready = false
            screen?.failure = message
        }
        screens[ref] = screen
        if ref.kind == .browser { poppedBrowserTabs.insert(ref.id) }
        if !openScreenOrder.contains(ref) { openScreenOrder.append(ref) }
        rememberOpenScreens()
        loadScreen(screen)
        return screen
    }

    /// The window closed: drop its page. The session itself keeps running in the engine.
    func detachScreen(_ ref: ScreenRef) {
        guard let screen = screens.removeValue(forKey: ref) else { return }
        screen.web.reset()
        if ref.kind == .browser { poppedBrowserTabs.remove(ref.id) } // back into the strip
        guard !isTerminating else { return }
        openScreenOrder.removeAll { $0 == ref }
        rememberOpenScreens()
    }

    func reloadScreen(_ screen: ScreenModel) {
        screen.failure = nil
        loadScreen(screen)
    }

    private func loadScreen(_ screen: ScreenModel) {
        guard let engineURL, let url = screen.ref.url(engineURL: engineURL) else { return }
        screen.ready = false
        screen.modalOpen = false
        screen.failure = nil
        screen.web.load(url)
    }

    private func rememberOpenScreens() {
        UserDefaults.standard.set(ScreenRef.encodeList(openScreenOrder.filter(\.isRemembered)), forKey: Self.openScreensKey)
    }

    /// The screen windows that were open when the app last quit — handed out once.
    func takeScreensToRestore() -> [ScreenRef] {
        defer { screensToRestore = [] }
        return screensToRestore
    }

    /// The screen's symbol as the sidebar or tab strip shows it ("" if unknown).
    func knownSymbol(for ref: ScreenRef) -> String {
        let sidebarItems = (sidebar?.groups.flatMap(\.items) ?? []) + (sidebar?.projects.flatMap(\.sessions) ?? [])
        if let item = sidebarItems.first(where: { $0.id == ref.id }) { return item.symbol }
        if let tab = tabs?.tabs.first(where: { $0.id == ref.id }) { return tab.symbol }
        return ""
    }

    /// A real name for a screen window before its page has said one.
    func knownTitle(for ref: ScreenRef) -> String? {
        if ref.kind == .browser {
            return BrowserTabsHook.provider?.browserTabs.first { $0.id == ref.id }?.title ?? screenTitles[ref]
        }
        if let given = screenTitles[ref] { return given }
        let sidebarItems = (sidebar?.groups.flatMap(\.items) ?? []) + (sidebar?.projects.flatMap(\.sessions) ?? [])
        if let item = sidebarItems.first(where: { $0.id == ref.id }), !item.title.isEmpty { return item.title }
        if let tab = tabs?.tabs.first(where: { $0.id == ref.id }), !tab.title.isEmpty { return tab.title }
        return nil
    }

    /// Load (if new) and bring forward the one Settings window.
    private func showSettings(_ relative: String, section: String?) {
        guard let engineURL, let url = SettingsLocation.resolve(relative, engineURL: engineURL) else {
            engine.log.note("refused open-settings for \(EngineLineParser.redacted(relative)) (not on the engine's origin)")
            NSSound.beep()
            return
        }
        if url != settingsWeb.requestedURL || settingsFailure != nil {
            settingsReady = false
            settingsModalOpen = false
            settingsFailure = nil
            settingsSections = []
            settingsSelection = nil
            settingsWeb.load(url)
        } else if let section {
            settingsSelection = section
            settingsWeb.run(.settingsSection(section))
        }
        settingsWindowRequest += 1
    }

    // MARK: State for the windows

    /// Whatever stops the main page from being shown, if anything.
    var failure: EngineFailure? {
        if case .failed(let failure) = engine.phase { return failure }
        return pageFailure
    }

    /// The page is up and taking commands.
    var canRun: Bool {
        guard pageReady, failure == nil, case .ready = engine.phase else { return false }
        return true
    }

    var visibleSidebar: SidebarState? { failure == nil ? sidebar : nil }

    /// What the sidebar list shows as selected (nothing while a browser tab is on show).
    var listSelection: String? { shownBrowserTab == nil ? sidebarSelection : nil }

    /// The native browser's tabs that belong in the strip (not those in their own window).
    var stripBrowserTabs: [BrowserTabInfo] {
        (BrowserTabsHook.provider?.browserTabs ?? []).filter { !poppedBrowserTabs.contains($0.id) }
    }

    /// The selected browser tab, if it still exists and is in the strip.
    var shownBrowserTab: String? {
        guard let activeBrowserTab, stripBrowserTabs.contains(where: { $0.id == activeBrowserTab }) else { return nil }
        return activeBrowserTab
    }

    /// The strip in the toolbar: the page's tabs, then the native browser's, one selected.
    var stripTabs: TabsState? {
        guard canRun else { return nil }
        let page = tabs ?? TabsState(tabs: [], canNewTerminal: false, canNewBrowser: false)
        let browserSelected = shownBrowserTab
        let merged = page.tabs.map { $0.with(active: browserSelected == nil && $0.active) }
            + stripBrowserTabs.map { tab in
                TabItem(id: tab.id, title: tab.title, symbol: "globe", kind: "browser",
                        active: tab.id == browserSelected, status: tab.loading ? "loading" : nil, closable: true)
            }
        let state = TabsState(tabs: merged, canNewTerminal: page.canNewTerminal,
                              canNewBrowser: BrowserTabsHook.provider != nil || page.canNewBrowser)
        guard !state.tabs.isEmpty || state.canNewTerminal || state.canNewBrowser else { return nil }
        return state
    }

    /// Favicons for the native browser's tabs, by tab id.
    var stripFavicons: [String: NSImage] {
        Dictionary(stripBrowserTabs.compactMap { tab in tab.favicon.map { (tab.id, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    private func isBrowserTab(_ id: String) -> Bool {
        BrowserTabsHook.provider?.browserTabs.contains { $0.id == id } ?? false
    }

    /// The screen on show in the main window: a native browser tab, else the page's
    /// active tab (it marks none while a panel covers the tabs), else the sidebar's selection.
    var currentScreen: (kind: String, id: String)? {
        if let shownBrowserTab { return ("browser", shownBrowserTab) }
        if let tab = visibleTabs?.tabs.first(where: \.active) { return (tab.kind, tab.id) }
        if let id = sidebarSelection, let item = sidebar?.item(id: id) { return (item.kind.name, id) }
        return nil
    }

    /// Keyboard focus follows what is on show: out of the hidden page while a native
    /// screen shows (so typing never lands in it), back into the page after.
    func nativeScreenShown(_ shown: Bool) {
        nativeScreenShown(shown, page: web, pageReady: pageReady)
    }

    /// Same, for any window's page.
    func nativeScreenShown(_ shown: Bool, page: WebBridge, pageReady: Bool) {
        let webView = page.webView
        guard let window = webView.window else { return }
        if shown {
            if let responder = window.firstResponder as? NSView, responder === webView || responder.isDescendant(of: webView) {
                window.makeFirstResponder(nil)
            }
        } else if pageReady {
            page.focus()
        }
    }

    /// The strip shows while the page is up and has tabs — or offers a new one,
    /// so the new-terminal / new-browser buttons are there even before the first tab.
    var visibleTabs: TabsState? {
        guard canRun, let tabs, !tabs.tabs.isEmpty || tabs.canNewTerminal || tabs.canNewBrowser else { return nil }
        return tabs
    }

    var engineIsUp: Bool {
        if case .ready = engine.phase { return true }
        return false
    }

    var windowTitle: String {
        guard canRun, let pageTitle, !pageTitle.isEmpty else { return "Terminal Deck" }
        return pageTitle
    }

    /// Real state only: engine progress, else the page's own subtitle (or nothing).
    var windowSubtitle: String {
        if failure != nil { return "Not running" }
        switch engine.phase {
        case .idle, .starting: return "Starting…"
        case .ready: return pageReady ? (pageSubtitle ?? "") : "Loading…"
        case .failed: return "Not running"
        }
    }

    var loadingMessage: String {
        if case .ready = engine.phase { return "Loading Terminal Deck…" }
        return "Starting the engine…"
    }

    var settingsTitle: String {
        settingsSections.first(where: { $0.id == settingsSelection })?.title ?? "Settings"
    }

    func isExpanded(_ projectPath: String) -> Bool {
        sidebar?.projects.first(where: { $0.id == projectPath })?.expanded ?? false
    }

    // MARK: Actions → page

    private func send(_ command: PageCommand) {
        guard canRun else { NSSound.beep(); return }
        web.run(command)
    }

    func newSession() { send(.newSession) }
    func openProject() { send(.openProject) }
    func requestSettings() { send(.openSettings) }
    func closeSession(_ id: String) { send(.closeSession(id)) }
    func newSession(in projectPath: String) { send(.newSessionIn(projectPath)) }
    func closeProject(_ projectPath: String) { send(.closeProject(projectPath)) }
    func selectTab(_ id: String) {
        if let provider = BrowserTabsHook.provider, isBrowserTab(id) {
            activeBrowserTab = id
            provider.selectBrowserTab(id)
            return
        }
        activeBrowserTab = nil
        send(.selectTab(id))
    }

    func closeTab(_ id: String) {
        if let provider = BrowserTabsHook.provider, isBrowserTab(id) {
            // Closing the tab on show: its neighbour among the browser tabs comes forward
            // (the right one, else the left), as in Safari; the last one hands back to the page.
            if activeBrowserTab == id {
                let ids = stripBrowserTabs.map(\.id)
                let next = ids.firstIndex(of: id).flatMap { i in i + 1 < ids.count ? ids[i + 1] : (i > 0 ? ids[i - 1] : nil) }
                activeBrowserTab = next
                if let next { provider.selectBrowserTab(next) }
            }
            provider.closeBrowserTab(id)
            return
        }
        send(.closeTab(id))
    }

    /// A tab's "Open in New Window": a browser tab moves into a native window of its own.
    func openTabInWindow(_ tab: TabItem) {
        if isBrowserTab(tab.id) {
            if activeBrowserTab == tab.id { activeBrowserTab = nil }
            openScreenWindow(ScreenRef(kind: .browser, id: tab.id), title: tab.title)
        } else {
            openScreenWindow(ScreenRef.forTab(tab), title: tab.title)
        }
    }
    func newTerminalTab() { send(.newTerminalTab) }
    /// A new native browser tab, selected — or, in a build without the native browser,
    /// the page's own (the engine's browser window).
    func newBrowserTab() {
        guard canRun else { NSSound.beep(); return }
        if let provider = BrowserTabsHook.provider {
            activeBrowserTab = provider.newBrowserTab()
        } else {
            send(.newBrowserTab)
        }
    }

    func select(_ id: String?) {
        guard let id else { return }
        let wasBrowser = shownBrowserTab != nil
        activeBrowserTab = nil
        guard id != sidebarSelection || wasBrowser else { return }
        sidebarSelection = id
        send(.select(id))
    }

    /// Flip it here at once (no flicker), then let the page confirm with its next `sidebar`.
    func setExpanded(_ projectPath: String, _ expanded: Bool) {
        guard let index = sidebar?.projects.firstIndex(where: { $0.id == projectPath }),
              sidebar?.projects[index].expanded != expanded else { return }
        sidebar?.projects[index].expanded = expanded
        send(.toggleProject(projectPath))
    }

    func selectSettingsSection(_ id: String?) {
        guard let id, id != settingsSelection else { return }
        settingsSelection = id
        settingsWeb.run(.settingsSection(id))
    }

    // MARK: Engine

    func startEngine() {
        engine.start()
    }

    func tryAgain() {
        pageModalOpen = false
        settingsModalOpen = false
        pageReady = false
        pageTitle = nil
        pageSubtitle = nil
        pageFailure = nil
        sidebar = nil
        sidebarSelection = nil
        activeBrowserTab = nil
        lastPageSelectedId = nil
        lastActiveTabId = nil
        tabs = nil
        engineURL = nil
        EngineBridge.shared.reset()
        web.reset()
        for screen in screens.values {
            screen.ready = false
            screen.modalOpen = false
            screen.failure = nil
            screen.title = nil
            screen.subtitle = nil
            screen.web.reset()
        }
        settingsReady = false
        settingsFailure = nil
        settingsSections = []
        settingsSelection = nil
        settingsWeb.reset()
        engine.reconfigure(InstalledTerminalDeck.configuration()) // installed or updated meanwhile?
        engine.restart()
    }

    func showLog() {
        engine.log.flush()
        NSWorkspace.shared.activateFileViewerSelecting([engine.configuration.logFile])
    }

    /// Quit / last window closed / SIGTERM: the engine goes with us.
    func shutdown() {
        engine.stopNow()
    }
}
