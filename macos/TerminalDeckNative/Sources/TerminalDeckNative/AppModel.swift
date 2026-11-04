import AppKit
import Observation
import TerminalDeckNativeCore
import TerminalDeckBackend

/// The one model behind every window: the engine process, the main page
/// (sidebar, tabs and title come from it), the Settings page, and the pages of
/// screens opened in their own windows.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    #if DEBUG
    private static var uiTestConfiguration: EngineConfiguration?
    private static var initialized = false

    @ObservationIgnored private(set) var receiverForUITests: NativeRCVModel?

    /// The same real Receiver model stays mounted while the UI test changes sections.
    func installReceiverForUITests(_ receiver: NativeRCVModel) throws {
        guard isUITestFixture, ProcessInfo.processInfo.environment[NativeLaunchSwitches.uiTest] == "1" else {
            throw NSError(domain: "TerminalDeckUITests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Only an isolated UI fixture may inject its Receiver model."])
        }
        receiverForUITests = receiver
    }

    /// XCTest owns a private, inert engine. Never discover the installed app for it.
    static func prepareForUITests(configuration: EngineConfiguration) throws {
        let env = ProcessInfo.processInfo.environment
        guard !initialized, env[NativeLaunchSwitches.uiTest] == "1",
              let data = env[NativeLaunchSwitches.dataFolder], let home = env["CFFIXED_USER_HOME"],
              data.hasPrefix("/private/tmp/td-glitch-"), home.hasPrefix("/private/tmp/td-glitch-"),
              URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path == URL(fileURLWithPath: home).resolvingSymlinksInPath().path,
              configuration.dataRoot.standardizedFileURL == URL(fileURLWithPath: data).standardizedFileURL,
              case .nativeOnly = configuration.source else {
            throw NSError(domain: "TerminalDeckUITests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "UI fixtures require private home/data and an inert native engine before AppModel is created."])
        }
        uiTestConfiguration = configuration
    }
    #endif

    var isUITestFixture: Bool {
        #if DEBUG
        Self.uiTestConfiguration != nil
        #else
        false
        #endif
    }

    let engine: EngineController
    @ObservationIgnored lazy var buttonActions = NativeButtonActions(effects: .init(
        invoke: { try await EngineBridge.shared.invoke($0, $1) },
        presentSession: { try NativeButtonPresentation.session(folder: $0) },
        confirm: { await NativeButtonPresentation.confirm($0) },
        changed: { [weak self] in self?.applyButtonState() },
        forgotten: { NativeTerminalSessions.shared.forget($0) },
        captureShell: { NativeButtonShellCapture() },
        shellOpened: { tabID, text in
            let session = NativeTerminalSessions.shared.session(for: tabID)
            if !text.isEmpty { session.terminal.feed(text: text) }
        }, remember: { UserDefaults.standard.set($0, forKey: NativeButtonActions.memoryKey) },
        openTabs: { [weak self] in self?.headerTabsForClosing },
        browserTabs: { BrowserTabsHook.provider?.browserTabs.map(\.id) ?? [] },
        shownBrowser: { [weak self] in self?.shownBrowserTab }),
        remembered: UserDefaults.standard.data(forKey: NativeButtonActions.memoryKey))

    @ObservationIgnored private var buttonSelectionRevision = 0

    func applyButtonState() {
        sidebar = named(buttonActions.sidebar)
        if buttonActions.selectionRevision != buttonSelectionRevision {
            buttonSelectionRevision = buttonActions.selectionRevision
            sidebarSelection = sidebar?.selectedId
            // A real choice replaces the page left behind by a popout. Closing
            // the last tab has no new choice, so it keeps any existing fallback.
            if sidebarSelection != nil { pageAfterMove = nil }
            activeBrowserTab = nil
            NativeFIXESDeviceTabs.shared.selectedID = nil
            if sidebarSelection == "hoot", HootReadyDefaults.enabled() {
                nativeHootOpen = true; nativeHootSelected = true
            } else {
                deactivateHoot(selecting: buttonActions.tabs.activeID)
                if let id = sidebarSelection, isBrowserTab(id) {
                    activeBrowserTab = id; BrowserTabsHook.provider?.selectBrowserTab(id)
                } else if let id = sidebarSelection, NativeFIXESDeviceTabs.shared.has(id) {
                    NativeFIXESDeviceTabs.shared.selectedID = id
                }
            }
        }
        tabs = named(preservingHoot(in: buttonActions.tabs))
    }

    @discardableResult func runButton(_ command: PageCommand) -> Task<Bool, Never> {
        guard NativeButtonActions.names.contains(command.name) else {
            return Task {
                guard canRun else { buttonActions.problem = "The page is still loading. Please try again."; return false }
                let accepted = await web.ask(command)
                if !accepted { buttonActions.problem = "That page could not make the change. Please try again." }
                return accepted
            }
        }
        buttonActions.start()
        // Include tabs kept by the native Hoot/browser owners when an action first takes over.
        if let tabs { buttonActions.ingest(tabs) }
        if let sidebar { buttonActions.ingest(sidebar) }
        return buttonActions.run(command)
    }
    func runButtonForTool(_ command: PageCommand) -> Task<NativeButtonActions.Outcome, Never> {
        guard NativeButtonActions.names.contains(command.name) else {
            return Task {
                guard canRun else { return .refused("The page is still loading. Please try again.") }
                return await web.ask(command) ? .completed : .refused("That page could not make the change. Please try again.")
            }
        }
        buttonActions.start()
        if let tabs { buttonActions.ingest(tabs) }
        if let sidebar { buttonActions.ingest(sidebar) }
        return buttonActions.runForTool(command)
    }

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
    /// The rail exactly as the page sent it; `sidebar` is it with the names given here laid over (NativeSessionNames).
    @ObservationIgnored private var pageSidebar: SidebarState?
    private(set) var sidebarSelection: String?
    /// nil until the page's first `tabs` message.
    private(set) var tabs: TabsState?
    private var nativeHootOpen = false
    private var nativeHootSelected = false
    /// The native browser tab on show, when one is (the page knows nothing of these).
    private(set) var activeBrowserTab: String?
    /// Browser tabs shown in windows of their own (they leave the strip meanwhile).
    private(set) var poppedBrowserTabs: Set<String> = []
    @ObservationIgnored private var lastPageSelectedId: String?
    /// The page has sent its rail since it last loaded (its first one is the page's memory).
    @ObservationIgnored private var pageSidebarArrived = false
    @ObservationIgnored private var lastActiveTabId: String?

    // Settings page
    private(set) var settingsSections: [SettingsSection] = []
    private(set) var settingsSelection: String?
    private(set) var settingsReady = false
    private(set) var settingsModalOpen = false
    private(set) var settingsFailure: String?
    /// Bumped to ask the main window to open (or focus) the Settings window.
    private(set) var settingsWindowRequest = 0
    /// Bumped to open (or focus) the one Devices window; `devicesPairOnOpen` starts it on the pairing sheet.
    private(set) var devicesWindowRequest = 0
    private(set) var devicesPairOnOpen = false
    func requestDevicesWindow(pair: Bool = false) { devicesPairOnOpen = pair; devicesWindowRequest += 1 }
    /// Bumped when screens are waiting to be opened in windows of their own.
    private(set) var screenWindowRequest = 0
    private var pageAfterMove: String?
    @ObservationIgnored private var pendingScreens: [ScreenRef] = []
    /// Names the page gave screens it popped out, until their own page names them.
    @ObservationIgnored private var screenTitles: [ScreenRef: String] = [:]

    @ObservationIgnored private var engineURL: URL?
    private(set) var preparingSavedData = false
    private(set) var websiteMigrationNotice: String?
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var appearancePreferences: NativeAppearancePreferences?

    // Screens in their own windows (one per ScreenRef), remembered across launches.
    @ObservationIgnored private var screens: [ScreenRef: ScreenModel] = [:]
    @ObservationIgnored private var openScreenOrder: [ScreenRef] = []
    @ObservationIgnored private var screensToRestore: [ScreenRef]
    /// Set when the app starts quitting, so windows closing on the way out stay remembered.
    @ObservationIgnored var isTerminating = false
    private static let openScreensKey = "openScreenWindows"

    private init() {
        #if DEBUG
        let fixture = Self.uiTestConfiguration
        Self.initialized = true
        #else
        let fixture: EngineConfiguration? = nil
        #endif
        // Last launch's theme, before any window is drawn (the page confirms it shortly).
        defer { if fixture == nil { restoreAppearance() } }
        // This app's own pages and in-process backend (D14).
        engine = EngineController(configuration: fixture ?? InstalledTerminalDeck.configuration())
        if fixture == nil { NativeOSBridge.connect() }
        BrowserTabsHook.connect()
        NativeFIXESDeviceTabs.installPresenter() // #108: simulators_open shows devices in this window
        screensToRestore = ScreenRef.decodeList(UserDefaults.standard.data(forKey: Self.openScreensKey))
        web = WebBridge(log: engine.log)
        settingsWeb = WebBridge(log: engine.log, revealOnLoad: true)
        NativePageFocus.install(on: web.webView) // SETTINGS-TRUTH row 59: the hidden page is told when the app is in front

        // A tab the browser opened itself (⌘T inside it, a link in a new tab) comes forward.
        BrowserTabsHook.provider?.onBrowserSelect { [weak self] id in
            guard let self else { return }
            self.poppedBrowserTabs.remove(id)
            // With the split on it lands in the focused pane, like a session tab chosen then.
            if self.splitTakesBrowsers { self.runButton(.selectTab(id)) } else { self.activeBrowserTab = id }
        }
        // However a browser tab closes, a pane of the split that showed it lets it go.
        BrowserTabsHook.provider?.onBrowserClose { [weak self] id in self?.browserClosing(id) }

        engine.onReady = { [weak self] url in
            guard let self else { return }
            self.automaticStarts = 0
            if self.engineHasBeenUp { DeckReconnect.shared.back("the engine is up again") }
            self.engineHasBeenUp = true
            self.engineURL = url
            EngineBridge.shared.configure(engineURL: url)
            Task { await NativeHootChatModel.restoreOutboxes() }
            Task { await self.appearancePreferencesReady() }
            self.web.load(url)
            for screen in self.screens.values { self.loadScreen(screen) }
        }

        web.onReady = { [weak self] in
            Task { await NativeCompositionRoot.shared.mainPageReady() }
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

        settingsWeb.onReady = { [weak self] in
            self?.settingsReady = true
            // The Settings page stops drawing the sections native draws (`settings:<id>`).
            self?.settingsWeb.run(.nativeScreens(NativeScreens.registered))
        }
        settingsWeb.onMessage = { [weak self] message in self?.handleSettingsPage(message) }
        settingsWeb.onReloading = { [weak self] in
            self?.settingsReady = false
            self?.settingsModalOpen = false
        }
        settingsWeb.onLoadFailed = { [weak self] message in
            self?.settingsReady = false
            self?.settingsFailure = message
        }
        appearancePreferences = NativeAppearancePreferences(bridge: .shared) { [weak self] in self?.applyAppearance($0) }
        appearancePreferences?.start()
    }

    // MARK: Messages from the pages

    private func handleMainPage(_ message: PageMessage) {
        switch message {
        case .title(let title, let subtitle):
            pageTitle = title
            pageSubtitle = subtitle
        case .sidebar(let state):
            var filtered = UIGMemoryVisibility.sidebar(state)
            if let selected = state.selectedId, let original = state.item(id: selected),
               !UIGMemoryVisibility.showsSidebarItem(original) {
                let rows = filtered.groups.flatMap(\.items) + filtered.projects.flatMap(\.sessions)
                let replacement = rows.first { $0.kind.name == "panel" && $0.id == "tasks" }
                    ?? rows.first { $0.kind.name == "session" }
                    ?? rows.first { $0.kind.name == "panel" }
                filtered.selectedId = replacement?.id
                if let replacement { send(.select(replacement.id)) }
            }
            // The page moved its own selection: follow it, away from a browser tab.
            let pageSelectionChanged = filtered.selectedId != lastPageSelectedId
            // The page's first rail after it loads is its memory, not a choice made now.
            let fromPageMemory = !pageSidebarArrived
            pageSidebarArrived = true
            // The retired Simulators page (page shortcuts, deep links): the phone panel instead. Remembered at
            // launch it opens nothing: the phone panel would open Hoot's page, and Hoot stays closed until the
            // person opens it (Asad, 3 Nov).
            if pageSelectionChanged, filtered.selectedId == SHELLRoutes.retiredSimulators {
                lastPageSelectedId = filtered.selectedId
                pageSidebar = NativeRCVNavigation.sidebar(NativeINT2Navigation.sidebar(filtered))
                sidebar = pageSidebar.map { named($0) }
                if canRun, !fromPageMemory { SHELLRoutes.openPhonePanel() }
                return
            }
            if pageSelectionChanged && !buttonActions.ownsSelection { activeBrowserTab = nil }
            lastPageSelectedId = filtered.selectedId
            pageSidebar = NativeRCVNavigation.sidebar(NativeINT2Navigation.sidebar(filtered)) // RCV
            if let pageSidebar { buttonActions.ingest(pageSidebar) }
            sidebar = named(buttonActions.sidebar)
            if !nativeHootSelected, pageSelectionChanged || !Self.nativeOnly(sidebarSelection) /* AGT, RCV, SHELL native-only places */,
               filtered.selectedId != SHELLRoutes.retiredSimulators /* never adopt the retired page */ {
                sidebarSelection = sidebar?.selectedId
            }
        case .tabs(let state):
            let filtered = UIGMemoryVisibility.tabs(state)
            let active = filtered.activeID
            if active != lastActiveTabId, active != nil, !buttonActions.ownsSelection { activeBrowserTab = nil }
            lastActiveTabId = active
            buttonActions.ingest(filtered)
            tabs = named(preservingHoot(in: buttonActions.tabs))
        case .openSettings(let url, let section):
            showSettings(url, section: section)
        case .openWindow(let ref, let title):
            openScreenWindow(ref, title: title)
        case .appearance(let appearance):
            applyAppearance(appearance)
        case .dialog(let request):
            receiveDialog(request, from: web)
        case .pageModal(let open):
            pageModalOpen = open
        case .ready, .settingsSections:
            break
        }
    }

    /// Names given to sessions here (NativeSessionNames), over the page's rail and strip, so a rename shows at once
    /// in every row, tab, session bar and window, whether or not the page repaints it (Asad, 12 Oct).
    private func named(_ state: SidebarState) -> SidebarState { SessionNames.applied(NativeSessionNames.shared.names, to: state) }
    private func named(_ state: TabsState) -> TabsState { SessionNames.applied(NativeSessionNames.shared.names, to: state) }
    func sessionNamesChanged() {
        if pageSidebar != nil { sidebar = named(buttonActions.sidebar) }
        if let tabs { self.tabs = named(tabs) }
    }

    private func handleSettingsPage(_ message: PageMessage) {
        switch message {
        case .settingsSections(let sections, let selected):
            // Hoot first, as in the main side panel (Asad, 2026-10-07); the rest keep their order.
            settingsSections = sections.filter(\.isHoot) + sections.filter { !$0.isHoot }
            settingsSelection = selected
        case .openSettings(let url, let section):
            showSettings(url, section: section)
        case .openWindow(let ref, let title):
            openScreenWindow(ref, title: title)
        case .appearance(let appearance):
            applyAppearance(appearance)
        case .dialog(let request):
            receiveDialog(request, from: settingsWeb)
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
        case .dialog(let request):
            receiveDialog(request, from: screen.web)
        case .pageModal(let open):
            screen.modalOpen = open
        case .ready, .sidebar, .tabs, .settingsSections:
            break
        }
    }

    // MARK: The page's dialogs, drawn natively

    /// Open dialogs by name, each with the page that asked (the answer goes back to it).
    private(set) var dialogs: [String: DialogRequest] = [:]
    @ObservationIgnored private var dialogSources: [String: WebBridge] = [:]

    private func receiveDialog(_ request: DialogRequest, from source: WebBridge) {
        if let current = dialogs[request.name], current.seq > request.seq { return } // an older opening, late
        if request.open, request.name == NativeDialogName.copilotSetup,
           source === web, let answer = HootSetupMemory.answer(toOffer: .standard) {
            source.run(DialogCommand(request.name, answer))
            return
        }
        if request.open {
            dialogs[request.name] = request
            dialogSources[request.name] = source
        } else if dialogs[request.name] != nil {
            dialogs[request.name] = nil
            dialogSources[request.name] = nil
        }
    }

    /// Answer a dialog: the page runs the same code its own dialog would. Closing
    /// answers close it here at once (the page confirms with `open: false`).
    /// `byPerson` is false for the app's own answers, which are never remembered.
    func answerDialog(_ name: String, _ action: String, argument: [String: Any]? = nil, closes: Bool = true, byPerson: Bool = true) {
        if name == NativeDialogName.copilotConsent, action == "allow-kind", let id = argument?["id"] as? String,
           argument?["approved"] as? Bool == true, argument?["allowKindMinutes"] as? Int == 10 {
            // The bool-only page action cannot represent a remembered kind.
            // Use the same authenticated owner channel and its settled push.
            Task {
                do {
                    _ = try await EngineBridge.shared.invoke("deck-control:consent-respond",
                        [id, ["approved": true, "allowKindMinutes": 10] as [String: Any]])
                } catch {
                    engine.log.note("The profile-kind approval did not settle; the question remains waiting.")
                }
            }
            return
        }
        if name == NativeDialogName.onboarding, action == "open-project" {
            PROJGuideWindow.open()
            return
        }
        if name == NativeDialogName.copilotSetup {
            HootSetupMemory.answered(closing: closes, byPerson: byPerson)
        }
        (dialogSources[name] ?? web).run(DialogCommand(name, action, argument: argument))
        if closes {
            dialogs[name] = nil
            dialogSources[name] = nil
        }
    }

    /// The shortcuts sheet over the Settings window (NativeSettingsShortcuts.present).
    var settingsShortcuts: Set<String>?
    func showSettingsShortcuts(hidden: Set<String>) { settingsShortcuts = hidden }

    // MARK: Appearance

    private static let appearanceKey = "appAppearance"

    func appearancePreferencesReady() async {
        await appearancePreferences?.synchronize()
    }

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
        guard UIGMemoryVisibility.showsScreen(ref) else {
            engine.log.note("screen window open: \(ref.screenKind)/\(ref.id) refused by visibility")
            return
        }
        if let title { screenTitles[ref] = title }
        if !pendingScreens.contains(ref) { pendingScreens.append(ref) }
        screenWindowRequest += 1
        engine.log.note("screen window open: \(ref.screenKind)/\(ref.id) queued; "
                       + (NativeFront.personActing ? "person acting" : "background request"))
    }

    /// Move a whole page, keeping its shared stores and leaving a usable page in main.
    func movePageToWindow(_ ref: ScreenRef, bringForward: Bool = true) {
        if ref.id == SHELLRoutes.devices { requestDevicesWindow(); return } // Devices is its own window, never a page
        let page = NativePageWindows.page(kind: ref.screenKind, id: ref.id) ?? ref
        guard UIGMemoryVisibility.showsScreen(page) else { return }
        if NativePageWindows.shared.savedFrame(page) == nil, let frame = web.webView.window?.frame {
            NativePageWindows.shared.saveFrame(page, frame: frame)
        }
        let current = currentScreen
        if page.id.hasPrefix("settings:"), "settings:" + NativeSettingsNavigation.shown(settingsSelection) == page.id,
           let next = NativeSettingsNavigation.items.first(where: { "settings:" + $0.id != page.id }) {
            selectSettingsSection(next.id)
        }
        NativePageWindows.shared.requested(page, bringForward: bringForward)
        if let current, NativePageWindows.page(kind: current.kind, id: current.id) == page {
            let next = NativePageWindows.shared.fallback()
            if next != NativePageWindows.emptyMainID { select(next) }
            pageAfterMove = next
        }
        if !NativePageWindows.shared.focus(page, bringForward: bringForward) { openScreenWindow(page, title: page.isHoot ? "Hoot" : knownTitle(for: page)) }
    }

    /// Keep the screen in its pop-out until a deferred return can open main.
    func returnScreenToMain(_ ref: ScreenRef, from window: NSWindow?,
                            openMain: @escaping @MainActor () -> Void,
                            closeWindow: @escaping @MainActor () -> Void) {
        engine.log.note("screen window return: \(ref.screenKind)/\(ref.id); "
                       + (NativeFront.personActing ? "person acting" : "kept behind until the app is active"))
        NativeFront.whenPersonActs("return-screen:\(ref.kind.rawValue):\(ref.id)") { [weak self, weak window] in
            guard let self else { return }
            NativePageWindows.shared.closed(ref)
            self.detachScreen(ref)
            if ref.kind == .session { NativePoppedSessions.shared.gone(ref.id, from: window) }
            openMain()
            if ref.kind == .panel { self.select(NativePageWindows.returnPageID(ref)) } else { self.selectTab(ref.id) }
            closeWindow()
        }
    }

    /// The screens waiting for a window — handed out once.
    func takePendingScreens() -> [ScreenRef] {
        defer { pendingScreens = [] }
        return UIGMemoryVisibility.restoredScreens(pendingScreens)
    }

    // MARK: Screens in their own windows

    /// The window for `ref` appeared: give it a page (one per screen).
    func attachScreen(_ ref: ScreenRef) -> ScreenModel {
        if let existing = screens[ref] { return existing }
        if ref.kind == .panel {
            let current = currentScreen
            NativePageWindows.shared.attached(ref)
            if let current, NativePageWindows.page(kind: current.kind, id: current.id) == NativePageWindows.page(kind: ref.screenKind, id: ref.id) { pageAfterMove = NativePageWindows.shared.fallback() }
        }
        let screen = ScreenModel(ref: ref, log: engine.log)
        screen.web.onReady = { [weak screen] in
            screen?.ready = true
            screen?.web.run(.nativeScreens(NativeScreens.registered))
            if let screen, NativePageWindows.needsWebFocus(screen.ref) { screen.web.focus() }
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
        // U143 (#586): the name given to the closed window goes with it, so a later pop-out never shows an old one.
        screenTitles[ref] = nil
        guard let screen = screens.removeValue(forKey: ref) else { return }
        screen.web.reset()
        NativePageWindows.shared.closed(ref)
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
        // Only pages that really reopen count as moved: a memory page while memory is off opens no window.
        // Hoot's own window is never reopened by itself, even from a list saved before 3 Nov (isRemembered).
        let restored = UIGMemoryVisibility.restoredScreens(screensToRestore.filter(\.isRemembered))
        screensToRestore = []
        for ref in restored where ref.kind == .panel { NativePageWindows.shared.requested(ref) }
        if restored.contains(where: { $0.kind == .panel }) { pageAfterMove = NativePageWindows.shared.fallback() }
        return restored
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
    /// Settings on one section, opened by the app itself rather than by a page command that can be dropped
    /// (the account chip's Add account and Manage sign-ins, 12 Oct). `section` is the live id ("agents").
    func openSettings(section: String) { showSettings("/?settings=1&section=" + section, section: section) }

    private func showSettings(_ relative: String, section: String?) {
        // Hoot's settings and profile live on the Hoot page now, not in Settings.
        if section == "copilot" || section == "hoot" { HootProfileRoute.open(tab: "brain"); return }
        guard let engineURL, let url = SettingsLocation.resolve(relative, engineURL: engineURL) else {
            engine.log.note("refused open-settings for \(EngineLineParser.redacted(relative)) (not on the engine's origin)")
            buttonActions.problem = "Settings could not be opened. Please try again after the app has started."
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

    var visibleSidebar: SidebarState? {
        guard failure == nil, let sidebar else { return nil }
        let hidden = AGTAgentsStore.shared.ownedSessionIDs
        var result = sidebar
        // No in-app notifications (Asad, 30 Oct): the retired Alerts row never shows.
        result.groups = result.groups.map { .init(id: $0.id, title: $0.title, items: $0.items.filter { !hidden.contains($0.id) && $0.id != "alerts" }) }
        result.projects = result.projects.map { .init(id: $0.id, title: $0.title, expanded: $0.expanded, sessions: $0.sessions.filter { !hidden.contains($0.id) }) }
        return result
    }

    /// What the sidebar list shows as selected (nothing while a browser tab is on show).
    var listSelection: String? { shownBrowserTab == nil && NativeFIXESDeviceTabs.shared.selectedID == nil ? sidebarSelection : nil }

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
        guard engineIsUp, failure == nil else { return nil }
        var page = tabs ?? TabsState(tabs: [], canNewTerminal: false, canNewBrowser: false)
        let owned = AGTAgentsStore.shared.ownedSessionIDs, jobs = AGTTeamChatHistory.shared.jobSessionIDs
        // 21 Oct (Asad): a task a lead or an outside AI gave to the team is not a tab of its own; it is on the
        // bar only while the person has it open (active, or chosen in the sidebar / Agents page).
        page.tabs.removeAll { owned.contains($0.id) || (jobs.contains($0.id) && !$0.active && $0.id != sidebarSelection) }
        let browserSelected = shownBrowserTab
        // GLITCH #92 / SHELL-SPEC §4.1: only the tab actually on show is selected; a native-only
        // page (Receiver, Servers, a project…) selects none. Prefer the page's active row.
        let actual = currentScreen
        let selectedIndex = actual.flatMap { screen in
            page.tabs.firstIndex { $0.active && $0.id == screen.id && $0.kind == screen.kind }
                ?? page.tabs.firstIndex { $0.id == screen.id && $0.kind == screen.kind }
        }
        let merged = page.tabs.indices.map { index in
            page.tabs[index].with(active: browserSelected == nil && index == selectedIndex)
        }
            + stripBrowserTabs.map { tab in
                TabItem(id: tab.id, title: tab.title, symbol: "globe", kind: "browser",
                        active: tab.id == browserSelected, status: tab.loading ? "loading" : nil, closable: true)
            }
            + NativeFIXESDeviceTabs.shared.tabs.map { $0.with(active: browserSelected == nil && $0.id == NativeFIXESDeviceTabs.shared.selectedID) }
        let state = TabsState(tabs: merged, canNewTerminal: page.canNewTerminal,
                              canNewBrowser: BrowserTabsHook.provider != nil || page.canNewBrowser,
                              layout: page.layout, accountSwitch: page.accountSwitch)
        guard !state.tabs.isEmpty || state.canNewTerminal || state.canNewBrowser else { return nil }
        return state
    }

    /// Favicons for the native browser's tabs, by tab id.
    var stripFavicons: [String: NSImage] {
        Dictionary(stripBrowserTabs.compactMap { tab in tab.favicon.map { (tab.id, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    private var headerTabsForClosing: [TabItem] {
        let open = stripTabs?.tabs ?? []
        return NativePaneArrangement.shared.arrangedTabs(open.map(\.id)).compactMap { id in open.first { $0.id == id } }
    }

    private func isBrowserTab(_ id: String) -> Bool {
        BrowserTabsHook.provider?.browserTabs.contains { $0.id == id } ?? false
    }

    // MARK: Browser tabs in the split (Asad, 28 Oct: "browser in other side too, not just 2 sessions only")

    /// With the split on (not swarm), a browser tab chosen goes into a pane like a session tab.
    var splitTakesBrowsers: Bool { tabs?.layout.map { $0.splitting && !$0.swarm } ?? false }

    /// A pane of the split holds this native browser tab (open, or held when it closed): never a session's terminal.
    func paneHoldsBrowser(_ id: String) -> Bool { isBrowserTab(id) || buttonActions.browserPanes.contains(id) }

    /// The tab strip's "Open in Split View": sessions and browser tabs not on show and not in a pane already.
    func offersSplit(_ tab: TabItem) -> Bool {
        guard !tab.active, !tab.isHoot, !NativeFIXESDeviceTabs.shared.has(tab.id),
              isBrowserTab(tab.id) || (tab.kind == "session" && SessionTarget(tabId: tab.id) != nil) else { return false }
        return !(splitTakesBrowsers && tabs?.layout?.root?.leaves.contains(where: { $0.tabId == tab.id }) == true)
    }

    /// "Open in Split View": the tab beside the one on show (the split turns on when it is off).
    func openTabInSplit(_ tab: TabItem) {
        pageAfterMove = nil
        if isBrowserTab(tab.id) {
            deactivateHoot(selecting: nil)
            NativeFIXESDeviceTabs.shared.selectedID = nil
        } else {
            NativeTerminalSessions.shared.chosenHere(tab.id)
        }
        runButton(.splitWith(tab.id))
    }

    /// The split's own commands from the menu, the keys and the palette (pane.split, pane.focusLeft/Right,
    /// pane.close). The page no longer draws the panes, so they act on the native arrangement, browser panes included.
    @discardableResult func runPaneCommand(_ id: String) -> Bool {
        switch id {
        case "pane.split":
            runButton(.setMode("split")); return true
        case "pane.close":
            guard splitTakesBrowsers, let focus = tabs?.layout?.focusedPaneId else { return false }
            runButton(.closePane(focus)); return true
        case "pane.focusLeft", "pane.focusRight":
            guard splitTakesBrowsers, let layout = tabs?.layout, let root = layout.root else { return false }
            let order = NativePaneArrangement.shownOrder(root)
            guard let at = order.firstIndex(of: layout.focusedPaneId ?? "") else { return false }
            let to = at + (id == "pane.focusLeft" ? -1 : 1)
            guard order.indices.contains(to) else { return true }
            runButton(.focusPane(order[to])); return true
        default:
            return false
        }
    }

    /// The browser tab beside this one in the strip (the right one, else the left), as Safari picks.
    private func browserNeighbour(of id: String) -> String? {
        let ids = stripBrowserTabs.map(\.id)
        return ids.firstIndex(of: id).flatMap { i in i + 1 < ids.count ? ids[i + 1] : (i > 0 ? ids[i - 1] : nil) }
    }

    private func paneHoldsBrowserNow(_ id: String) -> Bool { tabs?.layout?.root?.leaves.contains { $0.tabId == id } == true }

    /// A browser tab is closing (told just before it goes). In a pane of the split, its neighbour takes that pane
    /// when it was the one on show, else the pane empties; the split itself stays.
    private func browserClosing(_ id: String) {
        guard paneHoldsBrowserNow(id) || buttonActions.browserPanes.contains(id) else { return }
        let shown = activeBrowserTab == id
        let next = shown ? browserNeighbour(of: id) : nil
        if shown { activeBrowserTab = nil }
        buttonActions.start()
        if let tabs { buttonActions.ingest(tabs) }
        if let sidebar { buttonActions.ingest(sidebar) }
        buttonActions.browserClosed(id, next: next)
    }

    /// The screen on show in the main window: a native browser tab, else the page's
    /// active tab (it marks none while a panel covers the tabs), else the sidebar's selection.
    var currentScreen: (kind: String, id: String)? {
        if HootReadyDefaults.enabled(), nativeHootSelected,
           !NativePageWindows.shared.contains(ScreenRef(kind: .panel, id: "hoot", isHoot: true)) {
            return ("hoot", HootReadyDefaults.mainTabID)
        }
        if let pageAfterMove { return ("panel", pageAfterMove) }
        if let id = sidebarSelection, let page = NativePageWindows.page(kind: nativeHootSelected ? "hoot" : "panel", id: id), NativePageWindows.shared.contains(page) {
            return ("panel", NativePageWindows.shared.fallback())
        }
        if let shownBrowserTab { return ("browser", shownBrowserTab) }
        if let device = NativeFIXESDeviceTabs.shared.selectedID { return ("panel", device) } // #108 device tab
        if HootReadyDefaults.enabled(), nativeHootSelected { return ("hoot", tabs?.tabs.first(where: { $0.kind == "hoot" })?.id ?? HootReadyDefaults.mainTabID) }
        // Native-only places (Agents views, Receiver, Servers, Devices, a project's page) win over the tab.
        if let id = sidebarSelection, Self.nativeOnly(id) { return ("panel", id) }
        let hiddenSessions = AGTAgentsStore.shared.ownedSessionIDs
        if let tab = visibleTabs?.tabs.first(where: { $0.active && !hiddenSessions.contains($0.id) }) { return (tab.kind, tab.id) }
        if let id = sidebarSelection, let item = sidebar?.item(id: id) {
            // A session without a tab on show (closed, finished or hidden) shows the empty pane, never Hoot:
            // Hoot stays closed until the person opens it (Asad, 3 Nov). Native Hoot shows only while its tab is
            // open (`openHootPage`), never because a rail selection or the page's memory points at it.
            if item.kind == .session, visibleTabs?.tabs.contains(where: { $0.id == id && !hiddenSessions.contains(id) }) != true {
                return nil
            }
            if item.kind == .hoot, HootReadyDefaults.enabled(), !nativeHootOpen { return nil }
            return (item.kind.name, id)
        }
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
        guard engineIsUp, failure == nil, let tabs, !tabs.tabs.isEmpty || tabs.canNewTerminal || tabs.canNewBrowser else { return nil }
        return tabs
    }

    var engineIsUp: Bool {
        if case .ready = engine.phase { return true }
        return false
    }

    var windowTitle: String {
        guard canRun else { return "Terminal Deck" }
        if let screen = currentScreen, screen.kind == "session",
           let title = buttonActions.tabs.tabs.first(where: { $0.id == screen.id })?.title ?? sidebar?.item(id: screen.id)?.title,
           !title.isEmpty { return title }
        if let heading = nativeHeading { return heading.title }
        guard let pageTitle, !pageTitle.isEmpty else { return "Terminal Deck" }
        return pageTitle
    }

    /// A sidebar view drawn natively names itself. The page's heading is the page's own
    /// view, and it does not always follow the native selection — Hoot not set up yet
    /// leaves the page on whatever it showed before ("Simulators" over the Hoot screen).
    /// Tabs (sessions, browsers) keep the page's heading: the page owns that selection.
    private var nativeHeading: (title: String, subtitle: String)? {
        if currentScreen?.kind == "hoot" { return (hootTitle, "") }
        guard let screen = currentScreen, screen.kind != "session", screen.kind != "browser",
              let item = sidebar?.item(id: screen.id), !item.title.isEmpty,
              NativeScreens.detail(kind: screen.kind, id: screen.id) != nil else { return nil }
        // The page agrees: its subtitle is the right one.
        if item.title == pageTitle { return (item.title, pageSubtitle ?? "") }
        // Hoot is not about a project (the page sends no folder for the copilot).
        if item.isHoot { return (item.title, "") }
        // A view is about the project the page's views are about (`activeProjectPath`).
        guard let path = sidebar?.project else { return (item.title, "") }
        let name = sidebar?.projects.first { $0.id == path }?.title ?? URL(fileURLWithPath: path).lastPathComponent
        return (item.title, name == item.title ? "" : name)
    }

    /// Real state only: engine progress, else the page's own subtitle (or nothing).
    var windowSubtitle: String {
        if failure != nil { return "Not running" }
        switch engine.phase {
        case .idle, .starting: return "Starting…"
        case .ready: return pageReady ? (nativeHeading?.subtitle ?? pageSubtitle ?? "") : "Loading…"
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

    // MARK: Native button actions

    private func send(_ command: PageCommand) {
        guard UIGMemoryVisibility.showsPageCommand(command) else { buttonActions.problem = "That page is not available here."; return }
        if NativeButtonActions.names.contains(command.name) { runButton(command); return }
        guard canRun else { buttonActions.problem = "The page is still loading. Please try again."; return }
        Task { if !(await web.ask(command)) { buttonActions.problem = "That page could not make the change. Please try again." } }
    }

    private var hootTitle: String {
        let name = sidebar?.allItems.first(where: { $0.kind == .hoot })?.title ?? ""
        return name.isEmpty ? "Hoot" : name
    }
    private func preservingHoot(in state: TabsState) -> TabsState {
        guard HootReadyDefaults.enabled(), nativeHootOpen else { return state }
        let merged = HootReadyDefaults.open(in: state, title: hootTitle)
        if nativeHootSelected { return merged }
        return TabsState(tabs: merged.tabs.map { $0.with(active: $0.kind != "hoot" && $0.id == state.activeID) },
            canNewTerminal: state.canNewTerminal, canNewBrowser: state.canNewBrowser,
            layout: state.layout, accountSwitch: state.accountSwitch)
    }
    private func deactivateHoot(selecting id: String?) {
        nativeHootSelected = false
        guard nativeHootOpen, let state = tabs else { return }
        tabs = TabsState(tabs: state.tabs.map { tab in
            tab.with(active: tab.kind == "hoot" ? false : id.map { tab.id == $0 } ?? tab.active)
        }, canNewTerminal: state.canNewTerminal, canNewBrowser: state.canNewBrowser,
            layout: state.layout, accountSwitch: state.accountSwitch)
    }
    /// Hoot's tab opens only when the person opens Hoot: the sidebar row, its tab, ⌘-shortcut, a button that
    /// says Hoot, or an "open Hoot" they asked for. Launch never lands on Hoot any more (Asad, 3 Nov: "It should
    /// not be always open until we open the Hoot" — replaces 10 Oct "it should always land on Hoot").
    private func openHootPage() {
        let page = ScreenRef(kind: .panel, id: "hoot", isHoot: true)
        if NativePageWindows.shared.contains(page) { movePageToWindow(page); return }
        guard engineIsUp else { buttonActions.problem = "The app is still starting. Please try again."; return }
        nativeHootOpen = true; nativeHootSelected = true
        pageAfterMove = nil; activeBrowserTab = nil
        buttonActions.followNativeSelection("hoot")
        buttonSelectionRevision = buttonActions.selectionRevision
        NativeFIXESDeviceTabs.shared.selectedID = nil
        sidebarSelection = sidebar?.allItems.first(where: { $0.kind == .hoot })?.id ?? "hoot"
        tabs = HootReadyDefaults.open(in: tabs ?? TabsState(tabs: [], canNewTerminal: true, canNewBrowser: true), title: hootTitle)
        engine.log.note("Hoot sidebar: native full-page tab selected; no legacy setup-dependent page command")
    }

    func newSession() { send(.newSession) }
    /// Asad, 11 Oct: a project is made only through the New project guide; a folder alone is a plain session.
    /// Every "New project…" button lands here. `openFolder()` is the folder-only door (a normal session).
    func openProject() { PROJGuideWindow.open() }
    func openFolder() {
        Task {
            do {
                guard let path = try await EngineBridge.shared.invoke("project:pick") as? String, !path.isEmpty else { return }
                _ = try await EngineBridge.shared.invoke("projects:add", [path])
                try NativeButtonPresentation.session(folder: path)
            } catch { buttonActions.problem = "That folder could not be opened. Please try again." }
        }
    }
    func requestSettings() { showSettings("/?settings=1", section: nil) }
    func closeSession(_ id: String) { send(.closeSession(id)) }
    func newSession(in projectPath: String) { send(.newSessionIn(projectPath)) }
    func closeProject(_ projectPath: String) { send(.closeProject(projectPath)) }
    func selectTab(_ id: String) {
        if let tab = tabs?.tabs.first(where: { $0.id == id }), let page = NativePageWindows.page(kind: tab.kind, id: tab.id), NativePageWindows.shared.contains(page) { movePageToWindow(page); return }
        pageAfterMove = nil
        if NativeFIXESDeviceTabs.shared.has(id) { // #108 device tab
            deactivateHoot(selecting: id)
            activeBrowserTab = nil
            NativeFIXESDeviceTabs.shared.selectedID = id
            return
        }
        if HootReadyDefaults.enabled(), tabs?.tabs.contains(where: { $0.id == id && $0.kind == "hoot" }) == true { openHootPage(); return }
        if let provider = BrowserTabsHook.provider, isBrowserTab(id) {
            deactivateHoot(selecting: nil)
            NativeFIXESDeviceTabs.shared.selectedID = nil
            // With the split on, a browser tab takes the focused pane as a session tab does (Asad, 28 Oct).
            if splitTakesBrowsers { runButton(.selectTab(id)); return }
            activeBrowserTab = id; provider.selectBrowserTab(id); return
        }
        selectTabLocally(id)
        send(.selectTab(id))
    }

    private func selectTabLocally(_ id: String) {
        // The session comes to this Mac when he chose it in the session list, tab strip or with ⌘-number (28 Oct).
        NativeTerminalSessions.shared.chosenHere(id)
        guard var state = tabs else { sidebarSelection = id; return }
        if !state.tabs.contains(where: { $0.id == id }),
           let row = sidebar?.item(id: id), row.kind.name == "session" {
            state.tabs.append(TabItem(id: id, title: row.title, symbol: row.symbol,
                                      kind: "session", status: row.status, closable: true))
        }
        guard state.tabs.contains(where: { $0.id == id }) else { sidebarSelection = id; return }
        nativeHootSelected = false
        activeBrowserTab = nil
        NativeFIXESDeviceTabs.shared.selectedID = nil
        state.tabs = state.tabs.map { $0.with(active: $0.id == id) }
        tabs = state
        sidebarSelection = id
        buttonActions.followNativeSelection(id)
        buttonSelectionRevision = buttonActions.selectionRevision
    }

    func closeTabForTool(_ id: String) -> Task<NativeButtonActions.Outcome, Never> {
        if NativeFIXESDeviceTabs.shared.has(id) || isBrowserTab(id) || tabs?.tabs.first(where: { $0.id == id })?.isHoot == true {
            closeTab(id); return Task { .completed }
        }
        return runButtonForTool(.closeTab(id))
    }

    func closeTab(_ id: String) {
        if NativeFIXESDeviceTabs.shared.has(id) { NativeFIXESDeviceTabs.shared.close(id); return } // #108
        if HootReadyDefaults.enabled(), let state = tabs, state.tabs.contains(where: { $0.id == id && $0.kind == "hoot" }) {
            let closed = HootReadyDefaults.close(in: state)
            nativeHootOpen = false; nativeHootSelected = false; tabs = closed
            if let neighbour = closed.activeID { selectTab(neighbour) }
            else { sidebarSelection = sidebar?.groups.flatMap(\.items).first(where: { $0.kind == .panel })?.id }
            return
        }
        if let provider = BrowserTabsHook.provider, isBrowserTab(id) {
            // Closing the tab on show: its neighbour among the browser tabs comes forward
            // (the right one, else the left), as in Safari; the last one hands back to the page.
            // In a pane of the split, `browserClosing` tidies the pane as it goes.
            if activeBrowserTab == id, !paneHoldsBrowserNow(id) {
                let next = browserNeighbour(of: id)
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
        if NativeFIXESDeviceTabs.shared.has(tab.id) { // #108: the device moves into its own window
            NativeFIXESDeviceTabs.shared.close(tab.id)
            openScreenWindow(ScreenRef(kind: .panel, id: tab.id), title: tab.title)
            return
        }
        if isBrowserTab(tab.id) {
            if activeBrowserTab == tab.id { activeBrowserTab = nil }
            openScreenWindow(ScreenRef(kind: .browser, id: tab.id), title: tab.title)
        } else {
            if tab.kind == "panel" || tab.isHoot { movePageToWindow(ScreenRef.forTab(tab)) }
            else { openScreenWindow(ScreenRef.forTab(tab), title: tab.title) }
        }
    }
    func newTerminalTab() { NativeFIXESDeviceTabs.shared.selectedID = nil; send(.newTerminalTab) }
    /// A new native browser tab, selected — or, in a build without the native browser,
    /// the page's own (the engine's browser window).
    func newBrowserTab() {
        deactivateHoot(selecting: nil)
        guard engineIsUp else { buttonActions.problem = "The app is still starting. Please try again."; return }
        NativeFIXESDeviceTabs.shared.selectedID = nil
        if let provider = BrowserTabsHook.provider {
            // Its own onSelect shows it: in the focused pane while the split is on.
            let id = provider.newBrowserTab()
            if !splitTakesBrowsers { activeBrowserTab = id }
        } else {
            send(.newBrowserTab)
        }
    }

    func select(_ id: String?) {
        if let id, let page = NativePageWindows.page(kind: "panel", id: id), NativePageWindows.shared.contains(page) {
            movePageToWindow(page); return
        }
        pageAfterMove = nil
        guard let raw = id, let id = SHELLRoutes.resolve(raw) else { return }
        if id == SHELLRoutes.retiredSimulators { SHELLRoutes.openPhonePanel(); return }
        if HootReadyDefaults.enabled(), id == "hoot" || sidebar?.item(id: id)?.kind == .hoot { openHootPage(); return }
        guard UIGMemoryVisibility.showsScreen(kind: sidebar?.item(id: id)?.kind.name ?? "panel", id: id) else { return }
        if Self.nativeOnly(id) {
            deactivateHoot(selecting: nil); activeBrowserTab = nil
            NativeFIXESDeviceTabs.shared.selectedID = nil; sidebarSelection = id
            buttonActions.followNativeSelection(id)
            buttonSelectionRevision = buttonActions.selectionRevision
            return
        }
        if sidebar?.item(id: id)?.kind.name == "session" || tabs?.tabs.contains(where: { $0.id == id }) == true {
            selectTabLocally(id)
        }
        send(.select(id))
    }

    /// Places drawn only natively: the page keeps its own selection underneath.
    static func nativeOnly(_ id: String?) -> Bool {
        NativeINT2Navigation.owns(id) || id == NativeRCVNavigation.id || SHELLRoutes.owns(id)
    }

    /// Flip it here at once (no flicker), then let the page confirm with its next `sidebar`.
    func setExpanded(_ projectPath: String, _ expanded: Bool) {
        guard let index = sidebar?.projects.firstIndex(where: { $0.id == projectPath }),
              sidebar?.projects[index].expanded != expanded else { return }
        send(.toggleProject(projectPath))
    }

    func selectSettingsSection(_ id: String?) {
        guard let id, id != settingsSelection else { return }
        settingsSelection = id
        settingsWeb.run(.settingsSection(id))
    }

    // MARK: Engine

    func startEngine() {
        guard bootstrapTask == nil else { return }
        let standalone = Bundle.main.object(forInfoDictionaryKey: "TDNativeStandalone") as? Bool == true
        // D14: the standalone app is Node-free. Its backend is assembled in
        // process and its pages come from the native bridge; nothing is spawned.
        guard standalone, case .nativeOnly(let assets) = engine.configuration.source else {
            engine.start()
            return
        }
        engine.nativeStarter = {
            guard let root = NativeCompositionRoot.shared.backend else {
                throw NativeRPCError(code: "unavailable", message: "The native backend is not assembled.")
            }
            return try await NativeNodelessBridge.shared.start(assets: assets, root: root)
        }
        let configuration = NativeCompositionRoot.pinned(engine.configuration)
        if configuration != engine.configuration { engine.reconfigure(configuration) }
        let primary = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("terminaldeck", isDirectory: true)
        if configuration.engineDataDirectory.standardizedFileURL == primary.standardizedFileURL,
           NSWorkspace.shared.runningApplications.contains(where: {
               $0.bundleIdentifier == EngineConfiguration.appBundleID && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
           }) {
            engine.reconfigure(EngineConfiguration(source: .unavailable(.bundledEngine(
                "Another copy is already using your data. Quit it, then try again.")), dataRoot: configuration.dataRoot))
            engine.start()
            return
        }
        preparingSavedData = true
        bootstrapTask = Task { [weak self] in
            do {
                try await NativeCompositionRoot.shared.start(configuration: configuration)
                guard let self, !Task.isCancelled else { return }
            } catch {
                guard let self, !Task.isCancelled else { return }
                // The session host or another line not being up yet goes away by itself: start again
                // after a short pause, twice, before the person is shown a failure page at all.
                let message = error.localizedDescription
                if DeckRetryRules.isTransient(message), let pause = DeckRetryRules.pause(beforeAutomaticTry: self.automaticStarts) {
                    self.automaticStarts += 1
                    self.engine.log.note("start failed (" + message + "); starting again by itself (\(self.automaticStarts))")
                    try? await Task.sleep(for: .seconds(pause))
                    guard !Task.isCancelled else { return }
                    self.bootstrapTask = nil
                    self.startEngine()
                    return
                }
                self.preparingSavedData = false
                self.bootstrapTask = nil
                self.engine.reconfigure(EngineConfiguration(source: .unavailable(.bundledEngine(message)), dataRoot: configuration.dataRoot))
                self.engine.start()
                return
            }
            let report = await NativeBrowserCookieMigration.shared.run(dataRoot: configuration.engineDataDirectory)
            guard let self, !Task.isCancelled else { return }
            self.websiteMigrationNotice = report.complete ? nil : report.summary
            self.preparingSavedData = false
            self.bootstrapTask = nil
            self.engine.start()
        }
    }

    func retryWebsiteMigration() {
        guard !preparingSavedData else { return }
        preparingSavedData = true
        Task { [weak self] in
            guard let self else { return }
            let report = await NativeBrowserCookieMigration.shared.run(dataRoot: self.engine.configuration.engineDataDirectory, retry: true)
            self.websiteMigrationNotice = report.summary
            self.preparingSavedData = false
        }
    }

    /// A quit that could not finish left the engine stopped. Nobody should come back to a retry
    /// page for that: the next time the app is opened or its lines are back, it starts again by itself.
    @ObservationIgnored private var heldQuit = false
    /// The first "engine ready" of a launch is not a reconnect; every later one is.
    @ObservationIgnored private var engineHasBeenUp = false
    /// Automatic starts already spent on the failure that is showing (DeckRetryRules.pauses).
    @ObservationIgnored private var automaticStarts = 0
    /// The last time a whole-window failure was retried without the person, so one signal is one try.
    @ObservationIgnored private var lastSelfRetry = Date.distantPast

    /// DeckReconnect: the Mac woke, the person is back after a long gap, another copy quit, or the
    /// engine/host is up again. A whole-window failure page presses its own Try Again once.
    func linesAreBack(_ reason: String) {
        guard !isTerminating, failure != nil, bootstrapTask == nil else { return }
        guard Date().timeIntervalSince(lastSelfRetry) >= 5 else { return }
        engine.log.note("failure page: trying again by itself (" + reason + ")")
        tryAgain(byPerson: false)
    }

    /// The window was reopened (Dock click, Spotlight): a held quit must not greet the person.
    func reopened() {
        if heldQuit, !isTerminating {
            engine.log.note("reopened after a held quit; starting again by itself")
            tryAgain(byPerson: false)
        }
    }

    func tryAgain() { tryAgain(byPerson: true) }

    private func tryAgain(byPerson: Bool) {
        heldQuit = false
        if byPerson { automaticStarts = 0 } else { lastSelfRetry = Date() }
        pageModalOpen = false
        settingsModalOpen = false
        dialogs = [:]
        dialogSources = [:]
        pageReady = false
        pageTitle = nil
        pageSubtitle = nil
        pageFailure = nil
        sidebar = nil
        pageSidebar = nil
        sidebarSelection = nil
        activeBrowserTab = nil
        lastPageSelectedId = nil
        pageSidebarArrived = false
        lastActiveTabId = nil
        tabs = nil
        nativeHootOpen = false; nativeHootSelected = false
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
        if Bundle.main.object(forInfoDictionaryKey: "TDNativeStandalone") as? Bool == true {
            bootstrapTask?.cancel()
            bootstrapTask = nil
            bootstrapTask = Task { [weak self] in
                guard let self else { return }
                await self.engine.stopAndWait()
                guard !Task.isCancelled else { return }
                self.bootstrapTask = nil
                self.startEngine()
            }
        } else { engine.restart() }
    }

    func showLog() {
        engine.log.flush()
        NSWorkspace.shared.activateFileViewerSelecting([engine.configuration.logFile])
    }

    /// Quit / last window closed / SIGTERM: the engine goes with us.
    func prepareShutdown() async -> Bool {
        let trace: @Sendable (String) -> Void = { NativeCompositionRoot.note("quit: " + $0) }
        trace("prepare shutdown")
        #if TD_HOST_ACCOUNT_BRIDGE && TD_HOST_INTEGRATED
        // Drain only the app's account sign-in commands, while their original
        // UI authority and helper relay still exist. Kept sessions are untouched.
        if let managed = NativeCompositionINT2HOSTManaged.current {
            do { try await managed.stopAppAccountSignIns() }
            catch {
                trace("account sign-in is still closing; the quit was held")
                pageFailure = EngineFailure(title: "Sign-in is still closing", message: error.localizedDescription, detail: nil)
                heldQuit = true; isTerminating = false
                return false
            }
        }
        #endif
        #if TD_HOST_INTEGRATED
        // QUIT (9 Oct): only the explicit Stop Everything may end kept sessions. Every other
        // close (Cmd+Q, Apple-event quit, signals, logout, update, window close) detaches them;
        // the session graph's own shutdown re-checks this and detaches before stopping anything.
        if NativeSVResident.shared.explicitStop { await NativeCompositionRoot.shared.sessionsArea?.authorizeHostedStop() }
        #endif
        #if TD_HOST_ACCOUNT_BRIDGE && TD_HOST_INTEGRATED
        // With no in-app session left, detach through the helper's readiness handshake. In-app
        // sessions (deferred owners) end with the app, so the graph detaches the kept ones before
        // stopping those. A cached quit preference is never a request to kill kept sessions.
        if !NativeSVResident.shared.explicitStop,
           let managed = NativeCompositionINT2HOSTManaged.current,
           managed.coreBridge?.anyHostLost != true, // HOSTLOST: no handshake with a host that is gone
           (NativeCompositionRoot.shared.sessionsArea?.manager.localSessionCount() ?? 0) == 0 {
            // RETRY (11 Oct, Asad: "if the app is not used for long time it goes to retry page"): this
            // handshake failing used to CANCEL the person's quit and leave a whole-window "could not
            // detach yet / Try Again" page behind. He had only closed the window; the app stayed
            // running with none, and his next Dock click, much later, opened onto that page. Now the
            // handshake is tried again by itself with a short pause, and if it still fails the close
            // goes on exactly as a signal, logout or scripted quit already does: the graph detaches
            // (as if the app had crashed; kept sessions survive that) and never stops them.
            _ = await DeckQuitDetach.run(unattended: NativeSVResident.shared.unattended,
                handshake: { try await managed.keepForExit() },
                pause: { seconds in try? await Task.sleep(for: .seconds(seconds)) },
                trace: { trace($0) })
        }
        #endif
        NativeCompositionINT2HOSTCore.current?.prepareShutdown()
        bootstrapTask?.cancel()
        bootstrapTask = nil
        await BackendCompositionRoot.traced("engine", trace) { await engine.stopAndWait() }
        await BackendCompositionRoot.traced("page bridge", trace) { await NativeNodelessBridge.shared.stop() }
        do { try await NativeCompositionRoot.shared.stop() }
        catch {
            trace("could not stop yet (" + error.localizedDescription + "); the quit was held and the app starts again by itself when it is next opened")
            pageFailure = EngineFailure(title: "Terminal Deck could not stop yet", message: error.localizedDescription, detail: nil)
            heldQuit = true
            isTerminating = false
            return false
        }
        NativeOSBridge.shared.stop()
        return true
    }

    func shutdown() {
        bootstrapTask?.cancel()
        bootstrapTask = nil
        engine.stopNow()
        NativeOSBridge.shared.stop()
    }
}

// The view layer supplies the live screen actions. Composition and its fixtures
// never need to find the app model or create a web view themselves.
extension NativeCompositionRoot.Runtime {
    static var application: Self {
        var runtime = Self()
        runtime.window = { NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) }
        runtime.showProject = { path in await MainActor.run { AppModel.shared.select(path); return true } }
        runtime.whereWindow = { try await AppModel.shared.compositionWhereWindow() }
        runtime.appearanceReady = { await AppModel.shared.appearancePreferencesReady() }
        runtime.report = { text in
            NSLog("[native graph] %@", text)
            Task { @MainActor in AppModel.shared.engine.log.note("graph: " + text) }
        }
        return runtime
    }
}

private extension AppModel {
    func compositionWhereWindow() async throws -> NativeRPCValue {
        // Native Drive owns this description when the page has no DriveHost.
        if NativeScreens.registered.contains("drive") {
            guard sidebar != nil, NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return .null }
            return try NativeRPCValue.fromFoundation(DriveHost.shared.whereView())
        }
        let value = try await web.webView.callAsyncJavaScript(
            BackendDeckCoreCatalogueWhere.sourceWindowCall, arguments: [:], in: nil, contentWorld: .defaultClient)
        return try NativeRPCValue.fromFoundation(value)
    }
}
