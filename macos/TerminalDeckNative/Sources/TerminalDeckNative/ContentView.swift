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
                    MainToolbar(canRun: model.canRun,
                                newSession: model.newSession,
                                openSettings: model.requestSettings)
                }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
            windowWidth = width
            anchor.remeasureSoon()
        }
        .frame(minWidth: 820, minHeight: 500)
        .navigationTitle(model.windowTitle)
        .navigationSubtitle(model.windowSubtitle)
        .toolbar(removing: tabs != nil ? .title : nil)
        .onChange(of: model.settingsWindowRequest) {
            openWindow(id: SettingsWindow.sceneID)
        }
        .onChange(of: model.screenWindowRequest) {
            for ref in model.takePendingScreens() { openWindow(value: ref) }
        }
        .task {
            // Screens that had their own windows when the app last quit.
            guard !restored else { return }
            restored = true
            for ref in model.takeScreensToRestore() { openWindow(value: ref) }
        }
    }
}

// MARK: Toolbar — only what the sidebar doesn't already offer. The system toolbar
// draws these as Liquid Glass itself on macOS 26+.

struct MainToolbar: ToolbarContent {
    let canRun: Bool
    let newSession: () -> Void
    let openSettings: () -> Void

    var body: some ToolbarContent {
        ToolbarItem {
            Button(action: newSession) {
                Label("New Session", systemImage: "plus")
            }
            .help("Start a new session (⌘T)")
            .disabled(!canRun)
        }

        ToolbarSpacer(.fixed)

        ToolbarItem {
            Button(action: openSettings) {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Open Settings (⌘,)")
            .disabled(!canRun)
        }
    }
}

// MARK: Main page

/// The page, or — when the screen on show has one — its native version on top.
/// The page stays alive underneath (hidden, never torn down), so switching back is
/// instant and it keeps its state; it still hears every `select` / `select-tab`.
struct PageDetailView: View {
    let model: AppModel

    var body: some View {
        let showsPage = model.pageReady && model.failure == nil
        let screen = model.failure == nil && model.engineIsUp ? model.currentScreen : nil
        let native = screen.flatMap { NativeScreens.detail(kind: $0.kind, id: $0.id) }
        // A dialog the page opened (e.g. New Session from the native terminal) comes in
        // front of the native screen, which stays mounted underneath until it closes.
        let pageInFront = showsPage && (native == nil || model.pageModalOpen)
        ZStack {
            WebViewContainer(webView: model.web.webView)
                .opacity(pageInFront ? 1 : 0)
                .zIndex(native != nil && model.pageModalOpen ? 2 : 0)

            if let failure = model.failure {
                FailureView(failure: failure,
                            logPath: model.engine.configuration.logFile.path,
                            tryAgain: model.tryAgain,
                            showLog: model.showLog)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
            } else if let native, let screen {
                native
                    .id("\(screen.kind)/\(screen.id)") // its own state per screen
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
