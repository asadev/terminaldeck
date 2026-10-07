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

    var body: some View {
        let tabs = model.stripTabs
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 400)
        } detail: {
            PageDetailView(model: model)
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
                                                                 anchorMinX: anchor.minX),
                                     anchor: anchor,
                                     select: model.selectTab,
                                     close: model.closeTab,
                                     newTerminal: model.newTerminalTab,
                                     newBrowser: model.newBrowserTab,
                                     openInNewWindow: model.openTabInWindow)
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
        .navigationTitle(model.windowTitle)
        .navigationSubtitle(model.windowSubtitle)
        // The tabs name what is on show; with none (only the new-tab buttons) the title does.
        .toolbar(removing: tabs?.tabs.isEmpty == false ? .title : nil)
        .nativeAppDialogs(model) // the page's dialogs, drawn natively (lane S)
        // A page, channel or tool asking while the person is in another app waits
        // for them to come back; openWindow would pull the app in front (NativeFront).
        .onChange(of: model.settingsWindowRequest) {
            let open = openWindow
            NativeFront.whenPersonActs("settings") { open(id: SettingsWindow.sceneID) }
        }
        .onChange(of: model.screenWindowRequest) {
            let open = openWindow
            NativeFront.whenPersonActs("screens") { for ref in model.takePendingScreens() { open(value: ref) } }
        }
        .task {
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

    var body: some View {
        let showsPage = model.pageReady && model.failure == nil
        let screen = model.failure == nil && model.engineIsUp && !model.preparingSavedData ? model.currentScreen : nil
        let native = screen.flatMap { featureOffer(for: $0) ?? NativeScreens.detail(kind: $0.kind, id: $0.id) } ?? emptyState(screen: screen)
        // A dialog the page opened (e.g. New Session from the native terminal) comes in
        // front of the native screen, which stays mounted underneath until it closes.
        let pageInFront = showsPage && (native == nil || model.pageModalOpen)
        ZStack {
            WebViewContainer(webView: model.web.webView)
                .opacity(pageInFront ? 1 : 0)
                // Out of VoiceOver and hit-testing while a native screen is in front (walk 6).
                .accessibilityHidden(!pageInFront)
                .allowsHitTesting(pageInFront)
                .zIndex(native != nil && model.pageModalOpen ? 2 : 0)

            if model.preparingSavedData {
                LoadingView(message: "Preparing saved website sign-ins…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
            } else if let failure = model.failure {
                FailureView(failure: failure,
                            logPath: model.engine.configuration.logFile.path,
                            tryAgain: model.tryAgain,
                            showLog: model.showLog)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
            } else if let native {
                native
                    .id(screen.map { "\($0.kind)/\($0.id)" } ?? "empty") // its own state per screen; the empty states have none
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
                    .zIndex(1)
            } else if !showsPage {
                LoadingView(message: model.loadingMessage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: showsPage)
        .onChange(of: native != nil && !pageInFront) { _, shown in model.nativeScreenShown(shown) }
    }
}

extension PageDetailView {
    /// FeatureOffer (lane S): the page says this screen's feature is off or not installed.
    func featureOffer(for screen: (kind: String, id: String)) -> AnyView? {
        guard let open = model.dialogs[NativeDialogName.featureOffer],
              let request = open.decode(FeatureOfferRequest.self), request.panel == screen.id else { return nil }
        let symbol = model.visibleSidebar?.item(id: screen.id)?.symbol
        return AnyView(NativeFeatureOffer(request: request, symbol: symbol, model: model))
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

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
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
                if let showLog, failure.downloadURL == nil {
                    Button("Show Log", action: showLog)
                        .help(logPath ?? "")
                }
                if let download = failure.downloadURL {
                    Button("Try Again", action: tryAgain)
                    Button("Download Terminal Deck") { NSWorkspace.shared.open(download) }
                        .keyboardShortcut(.defaultAction)
                        .help(download.absoluteString)
                } else {
                    Button("Try Again", action: tryAgain)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(32)
    }
}
