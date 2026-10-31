import SwiftUI
import WebKit
import TerminalDeckNativeCore

/// Main window: native sidebar | the page. The sidebar toggle is the system's own.
/// The session tabs live in the toolbar row itself; the title hides while they show.
struct ContentView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var anchor = StripAnchorBox()
    @State private var windowWidth: CGFloat = 0
    @State private var detailMinX: CGFloat = 0
    @State private var restored = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    private var launching: Bool {
        !model.pageReady && model.sidebar == nil && model.tabs == nil && model.failure == nil && !model.isUITestFixture && !model.preparingSavedData
    }

    var body: some View {
        let tabs = model.stripTabs
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: DeckTokens.Metrics.sidebarMin, ideal: DeckTokens.Metrics.sidebarIdeal, max: DeckTokens.Metrics.sidebarMax)
        } detail: {
            PageDetailView(model: model)
                // The page stops at the toolbar safe area; never mirror its white behind the glass.
                .backgroundExtensionEffect(isEnabled: false)
                .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minX }) { x in
                    detailMinX = x
                    anchor.remeasureSoon()
                }
                .toolbar {
                    if let tabs {
                        ToolbarItem(placement: .navigation) {
                            TabStrip(state: tabs,
                                     favicons: model.stripFavicons,
                                     width: TabStripLayout.width(windowWidth: windowWidth,
                                                                 detailMinX: detailMinX,
                                                                 anchorMinX: anchor.minX,
                                                                 leadingFloor: anchor.leadingFloor),
                                     anchor: anchor,
                                     // A session chosen here comes to this Mac from a phone that had it (28 Oct).
                                     select: { id in NativeTerminalSessions.shared.chooser.choosing(in: .tabStrip) { model.selectTab(id) } },
                                     close: model.closeTab,
                                     newTerminal: model.newTerminalTab,
                                     newBrowser: model.newBrowserTab,
                                     openInNewWindow: model.openTabInWindow,
                                     splitOffered: model.offersSplit,
                                     openInSplit: { tab in NativeTerminalSessions.shared.chooser.choosing(in: .tabStrip) { model.openTabInSplit(tab) } })
                        }
                        .sharedBackgroundVisibility(.hidden)
                    }
                }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
            windowWidth = width
            anchor.remeasureSoon()
        }
        .frame(minWidth: 820, minHeight: 500)
        // Keep the split view and its glass alive through launch; only the detail loads.
        .overlay {
            if launching { LoadingView(message: model.loadingMessage).allowsHitTesting(false).transition(.opacity) }
        }
        // Tab bar and side panel share the frame shade; only the selected tab and the page
        // are the page colour (Asad, 2026-10-08, Chrome-style). See NativeChrome.
        .modifier(NativeWindowChrome(paper: NativeChrome.paper(model.currentScreen)))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let screen = model.currentScreen,
                   let ref = NativePageWindows.page(kind: screen.kind, id: screen.id),
                   ref.id != "tasks", ref.id != "agents-all", !ref.isHoot {
                    NativePagePopoutButton(ref: ref)
                }
            }
        }
        .navigationTitle(model.windowTitle)
        .navigationSubtitle(model.windowSubtitle)
        // The tabs name what is on show; with none (only the new-tab buttons) the title does.
        .toolbar(removing: tabs?.tabs.isEmpty == false ? .title : nil)
        .modifier(NativeButtonProblems(actions: model.buttonActions))
        .nativeAppDialogs(model) // the page's dialogs, drawn natively (lane S)
        // Settings wait for the person; screen requests choose their own focus policy.
        .onChange(of: model.settingsWindowRequest) {
            let open = openWindow
            NativeFront.whenPersonActs("settings") { open(id: SettingsWindow.sceneID) }
        }
        .onChange(of: model.devicesWindowRequest) {
            let open = openWindow
            NativeFront.whenPersonActs("devices") { open(id: DevicesWindow.sceneID) }
        }
        .onChange(of: model.screenWindowRequest) {
            NativePageWindows.shared.openPendingScreens(from: model, using: openWindow)
        }
        .onChange(of: ObjectWindows.shared.request, initial: true) {
            // NSHostingView fixture captures must never open any scene.
            guard !model.isUITestFixture, ObjectWindows.shared.request > 0 else { return }
            let open = openWindow
            NativeFront.whenPersonActs("object-settings") {
                for ref in ObjectWindows.shared.takePendingObjects() { open(id: ObjectWindows.sceneID, value: ref) }
            }
        }
        .task {
            guard !model.isUITestFixture else { return }
            // Object settings windows remember their own frames (never in a UI fixture).
            ObjectWindows.configureFrameMemory(defaults: .standard)
            NativeKeyRouter.install(model) // keymap.ts shortcuts while a native view has the keyboard (lane S)
            // Screens that had their own windows when the app last quit.
            guard !restored else { return }
            restored = true
            for ref in model.takeScreensToRestore() { openWindow(value: ref) } // front-ok: launch restore, inside the launch the person started
        }
    }
}

// No toolbar buttons of its own (Asad, 2026-10-07): new sessions come from the strip's
// terminal and globe buttons (each with a small +), and Settings and the alerts bell
// sit at the foot of the sidebar, as in the old app. ⌘T and ⌘, stay in the menus.

// MARK: Main page

/// The page, or — when the screen on show has one — its native version on top.
/// The page stays alive underneath (hidden, never torn down), so switching back is
/// instant and it keeps its state; it still hears every `select` / `select-tab`.
struct PageDetailView: View {
    let model: AppModel
    @State private var lastScreen: (kind: String, id: String)?
    @State private var recentNativeScreens: [CachedNativeScreen] = []

    var body: some View {
        let showsPage = model.pageReady && model.failure == nil
        let requested = model.currentScreen
        let nativeSwitch = NativeAccountSwitcher.shared
        let nativeWorking = nativeSwitch.note?.state == .working || nativeSwitch.asking?.busy == true
        let nativeOwner = nativeSwitch.asking?.sessionId ?? nativeSwitch.note?.sessionId
        let tabSwitch = model.tabs?.accountSwitch
        let switching = requested?.kind == "session" &&
            ((tabSwitch?.state == .working && tabSwitch?.sessionId == requested?.id) ||
             (nativeWorking && nativeOwner == requested?.id))
        let screen = model.failure == nil && model.engineIsUp && !model.preparingSavedData
            ? (switching ? lastScreen ?? requested : requested) : nil
        let nativeScreen = screen.flatMap { nativeDetail(for: $0) }
        let fallbackNative = nativeScreen == nil ? emptyLayout(screen: screen) ?? emptyState(screen: screen) : nil
        let hasNative = nativeScreen != nil || fallbackNative != nil
        // A dialog the page opened (e.g. New Session from the native terminal) comes in
        // front of the native screen, which stays mounted underneath until it closes.
        let pageInFront = showsPage && (nativeScreen == nil && fallbackNative == nil || model.pageModalOpen)
        // Bounded root: a screen's content can never make the window taller (#95).
        DeckPage(deckContent: AnyView(ZStack {
            WebViewContainer(webView: model.web.webView, visible: pageInFront)
                .opacity(pageInFront ? 1 : 0)
                // Out of VoiceOver and hit-testing while a native screen is in front (walk 6).
                .accessibilityHidden(!pageInFront)
                .allowsHitTesting(pageInFront)
                .zIndex(hasNative && model.pageModalOpen ? 2 : 0)

            if model.preparingSavedData {
                LoadingView(message: "Preparing saved website sign-ins…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DeckGlassBackdrop()) // glass, never a white page
            } else if let failure = model.failure {
                FailureView(failure: failure,
                            logPath: model.engine.configuration.logFile.path,
                            tryAgain: model.tryAgain,
                            showLog: model.showLog)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
            } else if nativeScreen != nil, let screen {
                recentNativeStack(active: screen)
                    .zIndex(1)
            } else if let fallbackNative {
                fallbackNative
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped() // a screen's own paper must not run up under the toolbar either
                    .background(NativeChrome.page(screen), ignoresSafeAreaEdges: [.horizontal, .bottom]) // the colour the selected tab runs into; stops at the toolbar so the frame shows above it
                    .zIndex(1)
            } else if !showsPage {
                LoadingView(message: model.loadingMessage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DeckGlassBackdrop()) // glass, never a white page
                    .transition(.opacity)
            }
        }))
        // The page is a card set into the frame: rounded where it meets the side panel and the strip.
        .deckContentCorner()
        .allowsHitTesting(!switching)
        .animation(nil, value: showsPage)
        .onChange(of: screen.map { $0.kind + "/" + $0.id }, initial: true) {
            rememberNativeScreen(screen)
        }
        .onChange(of: NativeTerminalSessions.shared.gone) { _, gone in
            // A closed session's hidden screen goes; only the one on show keeps its ended card.
            let shown = screen.map(CachedNativeScreen.init)
            recentNativeScreens.removeAll { $0.kind == "session" && gone.contains($0.screenID) && $0 != shown }
        }
        .onChange(of: requested.map { $0.kind + "/" + $0.id }, initial: true) {
            if !switching, let requested { lastScreen = requested }
        }
        .onChange(of: switching) {
            if !switching, let requested { lastScreen = requested }
        }
        .onChange(of: hasNative && !pageInFront) { _, shown in model.nativeScreenShown(shown) }
        .nativePaneDragHost() // drag a pane / the simulator to rearrange or out to a window (NativePaneDrag)
    }
}

private struct CachedNativeScreen: Identifiable, Equatable {
    let kind: String
    let screenID: String
    var id: String { kind + "/" + screenID }
    var screen: (kind: String, id: String) { (kind, screenID) }

    init(_ screen: (kind: String, id: String)) {
        kind = screen.kind
        screenID = screen.id
    }

    /// Every screen the split or swarm shows is that one arrangement, kept once: a browser page (or a terminal)
    /// can be in one view only, and moving the focus between panes must not build the split again.
    static let layoutKind = "layout"
    @MainActor static func shown(_ screen: (kind: String, id: String)) -> CachedNativeScreen {
        NativeLayoutScreen.wants(kind: screen.kind, id: screen.id) ? CachedNativeScreen((layoutKind, "")) : CachedNativeScreen(screen)
    }
    var isLayout: Bool { kind == Self.layoutKind }
}

extension PageDetailView {
    private func nativeDetail(for screen: (kind: String, id: String)) -> AnyView? {
        if screen.kind == CachedNativeScreen.layoutKind { return AnyView(NativeLayoutScreen(kind: "session", id: screen.id)) }
        return featureOffer(for: screen) ?? uiTestDetail(for: screen)
            ?? SHELLRoutes.detail(kind: screen.kind, id: screen.id)
            ?? NativeScreens.detail(kind: screen.kind, id: screen.id)
    }

    @ViewBuilder private func recentNativeStack(active: (kind: String, id: String)) -> some View {
        let activeEntry = CachedNativeScreen.shown(active)
        // The recent screens as they show now (split and swarm screens folded into one), the latest last.
        let entries = (recentNativeScreens + [CachedNativeScreen(active)]).reversed()
            .reduce(into: [CachedNativeScreen]()) { kept, raw in
                let entry = CachedNativeScreen.shown(raw.screen)
                if !kept.contains(entry) { kept.insert(entry, at: 0) }
            }
            .suffix(6)
        ZStack {
            ForEach(Array(entries)) { entry in
                if let native = nativeDetail(for: entry.screen) {
                    let shown = entry == activeEntry
                    native
                        .id(entry.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .background(NativeChrome.page(entry.isLayout ? active : entry.screen), ignoresSafeAreaEdges: [.horizontal, .bottom])
                        .opacity(shown ? 1 : 0)
                        .accessibilityHidden(!shown)
                        .environment(\.nativeScreenActive, shown)
                        .allowsHitTesting(shown)
                        .zIndex(shown ? 1 : 0)
                }
            }
        }
    }

    private func rememberNativeScreen(_ screen: (kind: String, id: String)?) {
        guard let screen, nativeDetail(for: screen) != nil else { return }
        let entry = CachedNativeScreen(screen)
        let gone = NativeTerminalSessions.shared.gone
        recentNativeScreens.removeAll { $0 == entry || ($0.kind == "session" && gone.contains($0.screenID)) }
        recentNativeScreens.append(entry)
        if recentNativeScreens.count > 6 { recentNativeScreens.removeFirst(recentNativeScreens.count - 6) }
    }

    /// The actual Receiver with one injected model. No section ID or forced remount.
    func uiTestDetail(for screen: (kind: String, id: String)) -> AnyView? {
        #if DEBUG
        if model.isUITestFixture, screen.kind == "panel", screen.id == "receiver",
           let receiver = model.receiverForUITests {
            return AnyView(NativeRCVScreen(model: receiver))
        }
        #endif
        return nil
    }

    /// FeatureOffer (lane S): the page says this screen's feature is off or not installed.
    func featureOffer(for screen: (kind: String, id: String)) -> AnyView? {
        guard let open = model.dialogs[NativeDialogName.featureOffer],
              let request = open.decode(FeatureOfferRequest.self), request.panel == screen.id else { return nil }
        let symbol = model.visibleSidebar?.item(id: screen.id)?.symbol
        return AnyView(NativeFeatureOffer(request: request, symbol: symbol, model: model))
    }

    /// An empty focused pane remains part of its split, even though no tab is selected.
    private func emptyLayout(screen: (kind: String, id: String)?) -> AnyView? {
        guard screen == nil, model.engineIsUp, model.failure == nil,
              let layout = model.tabs?.layout, layout.splitting || layout.swarm else { return nil }
        return AnyView(NativeLayoutScreen(kind: "session", id: ""))
    }

    /// Nothing selected: the app's own empty states, drawn natively (EmptyState.tsx when
    /// nothing is open at all, PageEmpty "Nothing in this pane yet" otherwise).
    func emptyState(screen: (kind: String, id: String)?) -> AnyView? {
        guard screen == nil, model.pageReady, model.failure == nil, model.engineIsUp else { return nil }
        if model.stripTabs?.tabs.isEmpty ?? true {
            return AnyView(NativeEmptyState(openProject: model.openProject))
        }
        return AnyView(NativePageEmpty(title: "Nothing in this pane yet",
                                       action: PageEmptyAction(label: "New session", perform: model.newSession)) {
            Text("Pick a session in the sidebar and it opens here.")
        })
    }
}

struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView
    let visible: Bool

    init(webView: WKWebView, visible: Bool = true) {
        self.webView = webView
        self.visible = visible
    }

    func makeNSView(context: Context) -> DeckWebViewport {
        let view = DeckWebViewport(frame: .zero)
        view.show(webView, visible: visible)
        return view
    }
    func updateNSView(_ view: DeckWebViewport, context: Context) {
        view.show(webView, visible: visible)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DeckWebViewport, context: Context) -> CGSize? {
        DeckWebViewport.proposedSize(width: proposal.width, height: proposal.height)
    }
    static func dismantleNSView(_ view: DeckWebViewport, coordinator: Void) { view.dismantle() }
}

struct LoadingView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

struct FailureView: View {
    let failure: EngineFailure
    let logPath: String?
    let tryAgain: () -> Void
    let showLog: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.secondary)

            Text(failure.title)
                .font(.title3.weight(.semibold))

            Text(failure.message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 560)

            if let detail = failure.detail {
                ScrollView {
                    Text(detail)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxWidth: 560, maxHeight: 110)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            }

            HStack(spacing: 10) {
                if let showLog {
                    Button("Show Log", action: showLog)
                        .help(logPath ?? "")
                }
                Button("Try Again", action: tryAgain)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(32)
    }
}
