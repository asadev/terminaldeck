import SwiftUI
import TerminalDeckNativeCore

/// One screen (a panel or a session) in its own window, with its own page.
/// Closing the window only drops this view of it; the session keeps running in the engine.
@MainActor
@Observable
final class ScreenModel {
    let ref: ScreenRef
    @ObservationIgnored let web: WebBridge

    var ready = false
    /// The page has a dialog open: it shows in front of a native screen.
    var modalOpen = false
    var title: String?
    var subtitle: String?
    var failure: String?

    init(ref: ScreenRef, log: EngineLog) {
        self.ref = ref
        self.web = WebBridge(log: log)
    }
}

struct ScreenWindow: View {
    let ref: ScreenRef?
    let model: AppModel
    @State private var screen: ScreenModel?
    @State private var window: NSWindow?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            if let screen {
                ScreenDetailView(screen: screen, model: model)
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        .toolbarBackground(terminalWindow ? NativeSessionChrome.ground : Color.clear, for: .windowToolbar)
        .toolbarBackgroundVisibility(terminalWindow ? .visible : .automatic, for: .windowToolbar)
        .background(NativeTerminalWindowChrome(enabled: terminalWindow))
        .toolbar {
            // The screen's own icon beside its title (Hoot's owl for Hoot). It also
            // gives every screen window the same slim 40 pt toolbar, title on the left.
            ToolbarItem(placement: .navigation) {
                Group {
                    if ref?.isHoot == true {
                        HootMark(size: 18)
                    } else if let ref {
                        Image(systemName: ref.kind == .browser ? "globe"
                              : SymbolName.resolve(model.knownSymbol(for: ref), fallback: ref.kind == .session ? "terminal" : "square.grid.2x2"))
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 2)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                Button(action: moveBack) {
                    Label("Move back to main window", systemImage: "arrow.down.left.square")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .help("Move back to main window")
                .accessibilityLabel("Move back to main window")
                .accessibilityAction { moveBack() }
                .disabled(ref == nil)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .background(NativeWindowReader { window = $0 })
        .onAppear {
            if let ref, screen == nil { screen = model.attachScreen(ref) }
        }
        .onDisappear {
            if let ref { model.detachScreen(ref) }
            screen = nil
        }
        // A pop-out asked for from this window's page (or while the main window is closed).
        .onChange(of: model.screenWindowRequest) {
            let open = openWindow
            NativeFront.whenPersonActs("screens") { for next in model.takePendingScreens() { open(value: next) } }
        }
    }

    private func moveBack() {
        guard let ref else { return }
        let close = dismiss
        let open = openWindow
        model.returnScreenToMain(ref, from: window,
                                 openMain: { NativeFront.whenPersonActs("return-screen-main") { open(id: "main") } }, closeWindow: { close() })
    }

    private var windowTitle: String {
        if let title = screen?.title, !title.isEmpty { return title }
        if let ref, let known = model.knownTitle(for: ref) { return known }
        return "Terminal Deck"
    }

    private var terminalWindow: Bool {
        ref?.kind == .session && ref.map { NativeTerminalScreen.handles($0.id) } == true
    }

    /// The page's subtitle when there is one; otherwise real progress only.
    private var windowSubtitle: String {
        guard let screen else { return "" }
        if screen.ref.kind == .browser { return "" } // no page; the tab's title says it
        if model.failure != nil || screen.failure != nil { return "Not running" }
        if !screen.ready { return model.engineIsUp ? "Loading…" : "Starting…" }
        return screen.subtitle ?? ""
    }
}

/// Let a popped-out terminal's paper continue through its AppKit titlebar.
struct NativeTerminalWindowChrome: NSViewRepresentable {
    var enabled: Bool

    func makeNSView(context: Context) -> ChromeView { ChromeView() }

    func updateNSView(_ view: ChromeView, context: Context) {
        let scheme = NativeSessionChrome.scheme
        view.ground = enabled ? scheme.colour(scheme.background, fallback: .windowBackgroundColor) : nil
        view.terminalAppearance = enabled ? NSAppearance(named: scheme.isLight ? .aqua : .darkAqua) : nil
        view.apply()
    }

    final class ChromeView: NSView {
        var ground: NSColor?
        var terminalAppearance: NSAppearance?

        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }

        func apply() {
            guard let window, let ground else { return }
            window.titlebarAppearsTransparent = true
            window.backgroundColor = ground
            window.appearance = terminalAppearance
            window.titlebarSeparatorStyle = .none
        }
    }
}

private struct ScreenDetailView: View {
    let screen: ScreenModel
    let model: AppModel

    var body: some View {
        let engineDown = model.failure != nil
        let showsPage = screen.ready && screen.failure == nil && !engineDown
        // A screen with a native version shows it here too (the page stays underneath
        // for the window's title).
        let ref = screen.ref
        let kind = ref.screenKind
        let native = engineDown || !model.engineIsUp ? nil : NativeScreens.detail(kind: kind, id: ref.id)
        ZStack {
            let pageInFront = showsPage && (native == nil || screen.modalOpen)
            WebViewContainer(webView: screen.web.webView)
                .opacity(pageInFront ? 1 : 0)
                .accessibilityHidden(!pageInFront)
                .allowsHitTesting(pageInFront)
                .zIndex(native != nil && screen.modalOpen ? 2 : 0)

            if let native {
                native
                    .id("\(kind)/\(ref.id)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
                    .zIndex(1)
            } else if ref.kind == .browser {
                ContentUnavailableView("This browser tab isn't available",
                                       systemImage: "globe",
                                       description: Text("It may have been closed."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
            } else if !showsPage {
                Group {
                    if engineDown {
                        ContentUnavailableView("Terminal Deck isn't running",
                                               systemImage: "exclamationmark.triangle",
                                               description: Text("Use Try Again in the main window."))
                    } else if let message = screen.failure {
                        FailureView(failure: EngineFailure(title: "This window couldn't load", message: message, detail: nil),
                                    logPath: nil,
                                    tryAgain: { model.reloadScreen(screen) },
                                    showLog: nil)
                    } else {
                        LoadingView(message: model.engineIsUp ? "Loading…" : "Starting the engine…")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
            }
        }
        .animation(.easeOut(duration: 0.2), value: showsPage)
        .onChange(of: native != nil && !(showsPage && screen.modalOpen)) { _, shown in
            model.nativeScreenShown(shown, page: screen.web, pageReady: screen.ready)
        }
    }
}
