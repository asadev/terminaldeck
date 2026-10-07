import AppKit
import Observation
import WebKit
import TerminalDeckNativeCore

/// The native browser's tabs — each one a tab in the main window's strip,
/// beside the session tabs, exactly like the Electron app. The strip (lane S)
/// draws them from here; the window shows `NativeBrowserScreen(tabId:)` for the
/// chosen one.
///
/// ## The API the strip uses
///
///     let store = NativeBrowserTabs.shared
///     store.tabs                      // [NativeBrowserTab], in strip order (observable)
///       tab.id                        // stable String id — the strip item's id, kind "browser"
///       tab.displayTitle              // page title, else host, else "New Tab"
///       tab.favicon                   // NSImage? (16 pt), nil until the site's icon loads
///       tab.url                       // URL? — nil while on "Open a page"
///       tab.isLoading                 // Bool
///       tab.isolated                  // Bool — own in-memory cookies (draw an accent)
///     store.create(url:after:)        // a new tab (nil url = "Open a page"); returns it
///     store.close(id)                 // stop it and drop it
///     store.select(id)                // the strip chose it (call when it is shown)
///     store.move(id, to: index)       // reorder (index among browser tabs, after the move)
///     store.selectedID                // the browser tab last chosen, if any
///     store.onSelect = { id in … }    // the browser asks the window to show a tab:
///                                     // ⌘T, a link opened in a new tab, a page's window.open
///
/// Closing never chooses a neighbour itself: the strip mixes sessions and
/// browser tabs, so the strip picks what to show next when `tabs` loses the
/// chosen one. Tabs are kept across relaunch (address, title, profile, Isolated).
@MainActor
@Observable
final class NativeBrowserTabs {
    static let shared = NativeBrowserTabs()

    /// Order and the chosen tab follow `BrowserTabList` (tested in Core).
    private(set) var list: BrowserTabList
    private var pages: [String: NativeBrowserTab] = [:]
    private var legacyDownloads: NativeBrowserDownloads?
    private var suppliedDownloads: (any NativeCompositionBrowserDownloadsPresentation)?
    var downloads: any NativeCompositionBrowserDownloadsPresentation {
        if let suppliedDownloads { return suppliedDownloads }
        if let legacyDownloads { return legacyDownloads }
        let legacy = NativeBrowserDownloads(); legacyDownloads = legacy; return legacy
    }
    @ObservationIgnored private(set) weak var browserComposition: NativeCompositionBrowser?

    /// The browser asks the window to show this tab.
    @ObservationIgnored var onSelect: ((String) -> Void)?

    /// The engine's browser profiles, and which one new tabs use.
    private(set) var profiles: [BrowserProfile] = []
    private(set) var activeProfileID = ""
    var downloadsShown = false
    /// A short confirmation at the bottom of the page ("Address copied").
    private(set) var notice: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var favicons: [URL: NSImage] = [:]
    @ObservationIgnored private var stores: [UUID: WKWebsiteDataStore] = [:]
    @ObservationIgnored private var profileSubscription: EngineSubscription?
    @ObservationIgnored private lazy var recordHandler = NativeBrowserRecordHandler { [weak self] webView, body in
        self?.tabs.first { $0.webView === webView }?.recorded(body)
    }

    private init() {
        list = BrowserTabsStore.decode(UserDefaults.standard.data(forKey: BrowserTabsStore.defaultsKey))
        profileSubscription = EngineBridge.shared.on("browser-profile:state") { [weak self] args in
            if let value = args.first { self?.applyProfiles(value) }
        }
        for record in list.tabs {
            pages[record.id] = NativeBrowserTab(record: record, owner: self)
        }
    }

    // MARK: Tabs

    var tabs: [NativeBrowserTab] { list.tabs.compactMap { pages[$0.id] } }
    var selectedID: String? { list.selectedID }
    func tab(_ id: String) -> NativeBrowserTab? { pages[id] }

    /// A new tab after `after` (default: the chosen browser tab). With no address
    /// it shows "Open a page". `show` asks the window to show it (`onSelect`).
    @discardableResult
    func create(url: URL? = nil, after: String? = nil, isolated: Bool = false, profile: String? = nil,
                show: Bool = true, configuration: WKWebViewConfiguration? = nil) -> NativeBrowserTab {
        let record = BrowserTabRecord(url: url?.absoluteString ?? "", title: "",
                                      profile: profile ?? activeProfileID, isolated: isolated)
        let tab = NativeBrowserTab(record: record, owner: self, configuration: configuration)
        pages[record.id] = tab
        list.insert(record, after: after ?? list.selectedID, select: show)
        // A page's own window, or a link opened in the background, loads at once.
        if show || configuration != nil || url != nil { tab.ensurePage() }
        if show && url == nil && configuration == nil { tab.focusAddress() }
        save()
        announce(tab)
        if show { onSelect?(record.id) }
        return tab
    }

    /// The strip chose this tab (or the window is showing it).
    func select(_ id: String) {
        guard let tab = pages[id] else { return }
        if list.selectedID != id {
            let previous = list.selectedID.flatMap { pages[$0] }
            list.select(id)
            save()
            if let previous { announce(previous) }
            announce(tab)
        }
        tab.ensurePage()
    }

    /// Bring a tab forward for something that needs it on screen (an agent's
    /// click, screenshot or handover). True once its page is in a window.
    func reveal(_ id: String) async -> Bool {
        guard let tab = pages[id] else { return false }
        select(id)
        onSelect?(id)
        for _ in 0..<20 {
            if tab.webView?.window != nil { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return tab.webView?.window != nil
    }

    func close(_ id: String) {
        guard let tab = pages[id] else { return }
        list.close(id)
        pages[id] = nil
        tab.tearDown()
        NativeBRMachines.windowClosed(id) // lane BR: its tunnels and its machine go with it (TS browser:window-closed)
        save()
    }

    func move(_ id: String, to index: Int) {
        list.move(id, to: index)
        save()
    }

    func duplicate(_ id: String) {
        guard let tab = pages[id] else { return }
        create(url: tab.url, after: id, isolated: tab.isolated, profile: tab.profile)
    }

    /// A page asked for a window (`window.open`, a target=_blank link, "Open Link
    /// in New Tab"): it becomes a tab, made with the page's own configuration so
    /// the opener link and the cookies are the page's.
    func adoptWindowRequest(configuration: WKWebViewConfiguration, from opener: NativeBrowserTab) -> WKWebView? {
        let tab = create(after: opener.id, isolated: opener.isolated, profile: opener.profile,
                         show: true, configuration: configuration)
        return tab.webView
    }

    /// Called by a tab when its address, title, profile or isolation changes.
    func tabChanged(_ tab: NativeBrowserTab) {
        list.update(tab.id, url: tab.url?.absoluteString ?? "", title: tab.title,
                    profile: tab.profile, isolated: tab.isolated)
        save()
        announce(tab)
    }

    private func save() {
        UserDefaults.standard.set(BrowserTabsStore.encode(list), forKey: BrowserTabsStore.defaultsKey)
    }

    // MARK: Page set-up

    /// The configuration a tab's web view is made with: its profile's store, or a
    /// fresh in-memory one when the tab is Isolated.
    func makeConfiguration(profile: String, isolated: Bool) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = isolated ? .nonPersistent() : store(for: profile)
        configuration.applicationNameForUserAgent = Self.safariUserAgentSuffix
        configuration.preferences.isElementFullscreenEnabled = true
        // Pop-ups only from a click, like Safari's default blocker.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Record: the page's recorder lives in WebKit's isolated world, and only it can post steps.
        configuration.userContentController.addUserScript(
            WKUserScript(source: BrowserDriverScripts.recorder, injectionTime: .atDocumentEnd,
                         forMainFrameOnly: true, in: .defaultClient))
        configuration.userContentController.add(recordHandler, contentWorld: .defaultClient,
                                                name: BrowserDriverScripts.recordHandler)
        Self.enableInspectElement(configuration.preferences)
        browserComposition?.prepareConfiguration(configuration)
        return configuration
    }

    /// One persistent store per profile, apart from the app's own engine pages.
    func store(for profile: String) -> WKWebsiteDataStore {
        let isDefault = profile.isEmpty || profile == "default" || profiles.first(where: { $0.id == profile })?.isDefault == true
        let identifier = BrowserProfile.storeIdentifier(for: isDefault ? "" : profile)
        if let existing = stores[identifier] { return existing }
        let store = WKWebsiteDataStore(forIdentifier: identifier)
        stores[identifier] = store
        return store
    }

    func evictStore(for profile: String) {
        stores[BrowserProfile.storeIdentifier(for: profile.isEmpty || profile == "default" ? "" : profile)] = nil
    }

    func retireLegacyBrowserOwners() async {
        if let legacyDownloads { await legacyDownloads.stop(); self.legacyDownloads = nil }
        await NativeBrowserHistoryStore.stopExistingWriter()
    }
    func installNativeBrowser(_ composition: NativeCompositionBrowser, downloads: NativeSafariDownloads) {
        browserComposition = composition; suppliedDownloads = downloads
    }
    func uninstallNativeBrowser(_ composition: NativeCompositionBrowser) {
        guard browserComposition === composition else { return }
        browserComposition = nil; suppliedDownloads = nil
    }
    private func announce(_ tab: NativeBrowserTab) { browserComposition?.note(tab) }
    func applyNativeProfiles(_ value: Any) { applyProfiles(value) }

    /// "Version/<Safari> Safari/605.1.15", so sites treat this as the Safari it is
    /// and do not serve a cut-down page to an unknown WebKit browser.
    private static let safariUserAgentSuffix: String = {
        let plist = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
        let version = (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String) ?? "26.0"
        return "Version/\(version) Safari/605.1.15"
    }()

    /// Adds "Inspect Element" to the page's right-click menu (Safari's Web
    /// Inspector, docked in the tab). Set only if this WebKit still has it.
    private static func enableInspectElement(_ preferences: WKPreferences) {
        if preferences.responds(to: NSSelectorFromString("_setDeveloperExtrasEnabled:")) {
            preferences.setValue(true, forKey: "developerExtrasEnabled")
        }
    }

    func cachedFavicon(_ url: URL) -> NSImage? { favicons[url] }
    func cacheFavicon(_ image: NSImage, for url: URL) { favicons[url] = image }

    // MARK: Profiles (the engine's list; the cookies are this browser's own)

    func refreshProfiles() async {
        guard EngineBridge.shared.isReady,
              let value = try? await EngineBridge.shared.invoke("browser-profile:list") else { return }
        applyProfiles(value)
    }

    private func applyProfiles(_ value: Any) {
        let state = BrowserProfile.read(value)
        let deleted = Set(profiles.map(\.id)).subtracting(state.profiles.map(\.id))
        profiles = state.profiles
        activeProfileID = state.activeID
        for id in deleted { stores[BrowserProfile.storeIdentifier(for: id)] = nil }
        for tab in tabs where deleted.contains(tab.profile) {
            tab.switchStore(profile: "default", isolated: tab.isolated)
        }
    }

    func profile(_ id: String) -> BrowserProfile? {
        if id.isEmpty { return profiles.first(where: \.isDefault) }
        return profiles.first { $0.id == id }
    }

    /// Use this profile for `tab` (it reloads in that profile's cookies) and for new tabs.
    func choose(profile id: String, for tab: NativeBrowserTab) {
        activeProfileID = id
        if EngineBridge.shared.isReady {
            Task { _ = try? await EngineBridge.shared.invoke("browser-profile:activate", [id]) }
        }
        tab.switchStore(profile: id, isolated: tab.isolated)
    }

    func createProfile(named name: String, for tab: NativeBrowserTab) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, EngineBridge.shared.isReady,
              let value = try? await EngineBridge.shared.invoke("browser-profile:create", [trimmed]) else { return }
        let state = BrowserProfile.read(value)
        profiles = state.profiles
        if let made = state.profiles.first(where: { $0.name == trimmed }) {
            choose(profile: made.id, for: tab)
        }
    }

    // MARK: Small confirmations

    func show(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}

/// Receives Record's steps from the pages, without WebKit keeping the store alive.
@MainActor
final class NativeBrowserRecordHandler: NSObject, WKScriptMessageHandler {
    private let deliver: (WKWebView?, Any) -> Void

    init(_ deliver: @escaping (WKWebView?, Any) -> Void) {
        self.deliver = deliver
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        deliver(message.webView, message.body)
    }
}

/// The pages this browser has visited, per profile, for the address field's
/// suggestions (`BrowserHistory` holds the rules). Kept in one file beside the
/// app's other data; written a moment after a change, not on every page.
@MainActor
final class NativeBrowserHistoryStore {
    private static var instance: NativeBrowserHistoryStore?
    static var shared: NativeBrowserHistoryStore {
        if let instance { return instance }
        let made = NativeBrowserHistoryStore(); instance = made; return made
    }
    static func stopExistingWriter() async { await instance?.stop() }

    private var visits: [BrowserVisit]
    private var writeTask: Task<Void, Never>?
    private let file: URL
    private var stopped = false

    private init() {
        file = AppModel.shared.engine.configuration.dataRoot.appendingPathComponent("browser-history.json")
        visits = BrowserHistory.decode(try? Data(contentsOf: file))
    }

    func note(profile: String, url: URL, title: String) {
        visits = BrowserHistory.note(visits, profileID: BrowserHistory.profileKey(profile), url: url.absoluteString,
                                     title: title, at: Date().timeIntervalSince1970 * 1000)
        scheduleWrite()
    }

    func retitle(profile: String, url: URL, title: String) {
        visits = BrowserHistory.retitle(visits, profileID: BrowserHistory.profileKey(profile), url: url.absoluteString, title: title)
        scheduleWrite()
    }

    func suggest(profile: String, typed: String) -> [BrowserVisit] {
        BrowserHistory.suggest(visits, profileID: BrowserHistory.profileKey(profile), typed: typed)
    }

    func forget(profile: String, url: String) {
        visits = BrowserHistory.forget(visits, profileID: BrowserHistory.profileKey(profile), url: url)
        scheduleWrite()
    }

    func clear(profile: String) {
        visits = BrowserHistory.clear(visits, profileID: BrowserHistory.profileKey(profile))
        scheduleWrite()
    }

    private func scheduleWrite() {
        guard !stopped else { return }
        writeTask?.cancel()
        writeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            let data = BrowserHistory.encode(self.visits)
            try? FileManager.default.createDirectory(at: self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: self.file, options: .atomic)
        }
    }
    private func stop() async {
        stopped = true
        let pending = writeTask; writeTask = nil; pending?.cancel(); await pending?.value
    }
}
