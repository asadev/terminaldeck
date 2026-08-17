/**
 * A page from the Mac, on the phone.
 *
 * A `WKWebView` pointed at `http://127.0.0.1:<port>/`, where `PortTunnel` is
 * listening. Not a custom URL scheme and not a string of HTML handed to
 * `loadHTMLString`, and the difference is the feature: on a real loopback origin
 * the page gets same-origin `fetch`, real cookies, service workers and —
 * critically — **WebSockets**, which is what a dev server's hot reload runs on.
 * A scheme handler gets none of that, and a site served through one is a
 * screenshot that stops updating the moment you save a file.
 *
 * ## What this screen owes the user
 *
 * That the page on screen is live, or that it plainly is not. A tunnel can end
 * for three reasons — this phone closed it, the Mac closed it, the connection
 * dropped — and all three leave a rendered page sitting there looking fine. So
 * the header carries the state, and when a tunnel ends the page is replaced
 * rather than left up with a warning over it.
 *
 * ## Inspect mode
 *
 * The other half of why this screen is worth having. Tapping an element while
 * inspecting describes it — a real CSS selector, its tag, whatever a human would
 * read off it — and a sheet takes one sentence about what should change and types
 * both into an agent on the Mac, as **one line**. See `Inspect` for why the line
 * is flattened rather than wrapped, and `InspectScript` for what runs inside the
 * page. It is the desktop's `CapturePanel` feature, from the sofa.
 *
 * ## It is pushed, and it wears exactly one bar
 *
 * This was a `fullScreenCover` and it rose from the bottom edge. Asad: *"it
 * should not come like this up. It should just move like this when we click on
 * localhost page. It comes like this, which is a bit different, feels like a
 * browser opens inside. So give it a native feel, not like this."* It is a
 * `navigationDestination` now — see `LocalhostListView` — so it slides in from
 * the trailing edge and the system's back-swipe pops it.
 *
 * Two bars follow from that and both are turned off:
 *
 *  - **The tab bar.** *"Pill should be on here… not inside the session and not
 *    also inside the localhost page."* A page is the whole reason you are here
 *    and it wants the height; the bar was sitting over the bottom of it pointing
 *    at somewhere else. That one is **not** turned off here: iOS 26 draws it as
 *    a floating pill owned by the `TabView` and ignores a `.toolbar` written on
 *    a pushed screen, so `DeckTabs` states it and this screen only reports that
 *    it is up — `DeckModel.localhostPageIsOpen`. `DeckChrome` holds the rule.
 *  - **The navigation bar.** The header below is already a browser's chrome —
 *    back, reload, where you are, inspect, Done — and he said of the last of
 *    those *"I think is on its correct place"*. A system bar above it would be
 *    94 points of chrome in two rows, and a second back button eleven points
 *    from the first one meaning something different. So this screen keeps its
 *    own bar and the system's is hidden.
 *
 * Losing the system bar does **not** lose the way out. Done pops the stack, and
 * `allowsBackForwardNavigationGestures` gives the left edge to the *page's*
 * history, which is what a browser does with that gesture and what the back
 * button beside reload does with a tap.
 */

import SwiftUI
import WebKit

struct LocalhostBrowser: View {
    let model: DeckModel
    let tunnel: PortTunnel
    let dismiss: () -> Void

    @State private var browser = BrowserBridge()
    @State private var toast: String?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().overlay(Theme.hairline)
                content
            }

            if let toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 28)
                        .accessibilityIdentifier("localhost.toast")
                        .accessibilityAddTraits(.updatesFrequently)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(.dark)
        // One bar on this screen, and it is the one below. See the header.
        .toolbar(.hidden, for: .navigationBar)
        // Presented off a flag rather than off the capture itself. `.sheet(item:)`
        // tears the sheet down and builds a new one whenever the identity changes,
        // and Wider/Narrower change the capture on every press — which would make
        // the correction control dismiss and re-present the sheet it lives in.
        .sheet(isPresented: Binding(get: { browser.capture != nil },
                                    set: { if !$0 { browser.clearCapture() } })) {
            if let capture = browser.capture {
                InspectSheet(
                    capture: capture,
                    targets: model.agentTargets,
                    target: Binding(get: { model.agentTarget }, set: { model.agentTarget = $0 }),
                    step: { browser.step($0) },
                    send: { line, session in
                        let sentence = model.sendToAgent(line, into: session)
                        show(sentence)
                        return sentence
                    },
                    dismiss: { browser.clearCapture() },
                )
            }
        }
        .onChange(of: tunnel.phase) { _, phase in
            // The load waits for the listener. Pointing a web view at a port
            // nothing is bound to yet gets a connection-refused page cached
            // against that URL, and the reload after it looks like the site is
            // broken rather than like it was early.
            if case let .live(url) = phase { browser.load(url) }
        }
        .onAppear {
            if case let .live(url) = tunnel.phase { browser.load(url) }
        }
        .onDisappear {
            // The handler holds the page's only way back into this app, and the
            // controller holds the handler. Neither should outlive the screen.
            browser.tearDown()
        }
        // No `.credentialPrompt` here any more, and its absence is the point.
        // This screen used to carry its own copy because a cover has no ancestor
        // that can present a sheet; a pushed screen is inside the hierarchy
        // `RootView` presents from, so the one copy up there reaches it. Two
        // copies of a sheet bound to the same optional is how one question gets
        // asked twice.
    }

    /// Copy, paste and "sent to an agent" are silent by nature; without this the
    /// buttons feel broken even when they worked. Two and a half seconds, the
    /// same as the terminal screen's.
    private func show(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { toast = nil }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                /*
                 * The page's own Back — and it works now.
                 *
                 * Asad: *"the back button here doesn't work at all next to
                 * refresh. So it should be working also."* The button was wired
                 * to `goBack()` the whole time and the wiring was never the
                 * problem: `canGoBack` was only ever re-read from the navigation
                 * delegate, which does not fire for a same-document
                 * navigation. Every dev server this feature exists to look at is
                 * a single-page app, every route change in one is `pushState`,
                 * and so on the pages he was testing this button was permanently
                 * disabled no matter how far into the site he had clicked. A
                 * disabled chevron and a dead one look identical.
                 *
                 * `BrowserBridge` watches the web view through KVO now, so this
                 * is live within a frame of the page's own history changing —
                 * and still genuinely disabled when there is nowhere to go,
                 * which is the honest state for the first page of a site.
                 */
                Button {
                    browser.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                }
                .disabled(!browser.canGoBack)
                .accessibilityLabel("Back")
                .accessibilityIdentifier("localhost.back")

                Button {
                    browser.reload()
                } label: {
                    Image(systemName: browser.loading ? "xmark" : "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                }
                .disabled(!isLive)
                .accessibilityLabel(browser.loading ? "Stop loading" : "Reload")
                .accessibilityIdentifier("localhost.reload")

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(subtitle)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                        // The interesting end of a URL is the path, not the
                        // scheme, and every one of these starts with the same
                        // eleven characters.
                        .truncationMode(.head)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                /*
                 * Inspect.
                 *
                 * A toggle rather than a mode you enter and leave through a
                 * menu, because it is the one control on this screen anybody
                 * reaches for twice in a row: tap an element, say what to change,
                 * tap the next one. Filled while it is on, so a tap that
                 * cancels a link instead of following it is explained by
                 * something visible rather than looking like a broken page.
                 */
                Button {
                    browser.setInspecting(!browser.inspecting)
                } label: {
                    Image(systemName: browser.inspecting
                          ? "square.dashed.inset.filled"
                          : "square.dashed")
                        .font(.system(size: 15, weight: .semibold))
                }
                .disabled(!isLive)
                .accessibilityLabel(browser.inspecting ? "Stop inspecting" : "Inspect an element")
                .accessibilityIdentifier("localhost.inspect")

                Button("Done") {
                    // Closing the view is the whole of the teardown: the
                    // listener goes, the Mac's socket goes, and the port is
                    // unreachable again until it is tapped.
                    dismiss()
                }
                .font(.system(size: 15, weight: .medium))
                .accessibilityIdentifier("localhost.done")
            }
            .tint(Theme.accent)

            if browser.inspecting {
                HStack(spacing: 6) {
                    Image(systemName: "hand.tap")
                        .font(.system(size: 10))
                    Text("Tap anything on the page to describe it.")
                        .font(.system(size: 11))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.accent)
                .accessibilityIdentifier("localhost.inspectHint")
            }

            if browser.loading {
                // A page over a phone connection to a laptop is not instant, and
                // a tap that shows nothing for two seconds reads as a dead tap.
                ProgressView().progressViewStyle(.linear).tint(Theme.accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, browser.loading ? 6 : 10)
        .background(Theme.surface)
    }

    @ViewBuilder
    private var content: some View {
        switch tunnel.phase {
        case .opening:
            waiting("Opening port \(tunnel.port) on the Mac…")
        case .live:
            ZStack {
                WebSurface(browser: browser)
                if let failure = browser.failure {
                    // The tunnel is up and the *page* failed, which is a
                    // different sentence from the tunnel having gone: the dev
                    // server may simply have restarted.
                    unavailable(title: "That page did not load", detail: failure) {
                        Button("Try again") { browser.reload() }
                    }
                }
            }
        case let .ended(detail):
            unavailable(title: "Port \(tunnel.port) is closed", detail: detail) {
                Button("Close") { dismiss() }
            }
        }
    }

    private func waiting(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().tint(Theme.accent)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unavailable(
        title: String,
        detail: String,
        @ViewBuilder actions: () -> some View,
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "bolt.horizontal.circle")
        } description: {
            Text(detail)
        } actions: {
            actions()
        }
        .background(Theme.background)
    }

    private var isLive: Bool {
        if case .live = tunnel.phase { return true }
        return false
    }

    private var title: String {
        // The page's own title once it has one; the port until then, because
        // "Untitled" tells nobody which of their servers they are looking at.
        browser.title.isEmpty ? "localhost:\(tunnel.port)" : browser.title
    }

    private var subtitle: String {
        switch tunnel.phase {
        case .opening:
            return "connecting…"
        case let .live(url):
            let address = browser.address.isEmpty ? url.absoluteString : browser.address
            // The stream count is the honest signal that something is still
            // talking — a hot-reload socket holds one open with nothing on
            // screen changing.
            return tunnel.streams > 1 ? "\(address)  ·  \(tunnel.streams) connections" : address
        case .ended:
            return "closed"
        }
    }
}

/* -------------------------------------------------------------------------- */
/* The web view                                                                */
/* -------------------------------------------------------------------------- */

/**
 * The `WKWebView` and everything it reports back.
 *
 * Held outside the SwiftUI view for the same reason `TerminalBridge` is: a
 * `UIViewRepresentable` is recreated on every state change, and a web view
 * rebuilt mid-load starts the page again from the top.
 *
 * ## The navigation delegate is not enough, and that was the Back button bug
 *
 * `WKNavigationDelegate` fires for **document** navigations. It does not fire
 * for a same-document one — a fragment, a `pushState`, a `replaceState` — and
 * those are not an edge case here, they are the normal case: the whole point of
 * this screen is looking at a dev server, every modern dev server serves a
 * single-page app, and every route change in one is `pushState`. Each of those
 * *does* add an entry to the back-forward list, so `webView.canGoBack` becomes
 * true — and this object never asked again, so its own `canGoBack` stayed false
 * and the button stayed disabled however deep into the site you clicked.
 *
 * `canGoBack`, `title` and `url` are all KVO-compliant on `WKWebView` and none
 * of the three is reliably delivered by the delegate for those navigations, so
 * all three are observed. The delegate callbacks stay: they carry `loading` and
 * the failures, which KVO does not, and they re-arm the inspect script on a new
 * document.
 */
@MainActor
@Observable
final class BrowserBridge: NSObject, WKNavigationDelegate {

    private(set) var title = ""
    private(set) var address = ""
    private(set) var loading = false
    private(set) var canGoBack = false
    /// A sentence for the failure overlay, or nil. Cleared on the next attempt.
    private(set) var failure: String?

    /// Whether taps describe elements instead of driving the page.
    private(set) var inspecting = false
    /// The element the last tap described, or nil. Drives the sheet.
    private(set) var capture: ElementCapture?

    let webView: WKWebView

    /**
     * The world the inspect script and its message handler live in.
     *
     * `.defaultClient` rather than `.page`, so the tunnelled site can neither
     * call `__terminaldeck` nor reach `webkit.messageHandlers` — in the page's
     * own world neither exists. See the header of `InspectScript`.
     */
    private static let world = WKContentWorld.defaultClient

    /**
     * The KVO registrations, held so they outlive `init` and die with this
     * object.
     *
     * `NSKeyValueObservation` unregisters itself when it is deallocated, which
     * is the whole reason this is the modern spelling rather than
     * `addObserver(_:forKeyPath:…)`: a `WKWebView` outliving an observer that
     * never removed itself is a crash, not a leak.
     */
    private var observations: [NSKeyValueObservation] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        // The default, persistent store, deliberately: a dev server that logs
        // you in with a cookie should keep you logged in between taps, and an
        // ephemeral store would make every open a fresh browser.
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black

        /*
         * Injected at document start on every page, including the ones a
         * single-page app pushes and the ones a redirect lands on. The script
         * defines its functions and stops; nothing observes the page until
         * `enable` is called, so the cost on a page nobody is inspecting is one
         * closure that ran once.
         */
        let controller = webView.configuration.userContentController
        controller.addUserScript(WKUserScript(source: InspectScript.source,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true,
                                              in: Self.world))
        // Weak, through a proxy. `WKUserContentController` retains its handlers,
        // and the controller belongs to the web view this object owns — so
        // registering `self` directly is a cycle that keeps a web view, its
        // process and its page alive for the life of the app.
        controller.add(ScriptRelay(self), contentWorld: Self.world, name: InspectScript.messageHandler)

        watchNavigationState()
    }

    /**
     * Watch the three things the navigation delegate cannot be trusted for.
     *
     * `canGoBack` is the one that was a bug — see the type's header — and
     * `title` and `url` are here because they go stale in exactly the same
     * moment and for exactly the same reason: a single-page app that routes with
     * `pushState` changes all three and tells the delegate nothing, so the
     * header would keep naming the page somebody left two taps ago.
     *
     * **Any of the three re-reads all three**, rather than each observer
     * updating only its own property. That is deliberate and it is what makes
     * this robust rather than merely correct-looking: these are three
     * notifications about one event, WebKit does not promise they arrive
     * together or in an order, and a `canGoBack` notification that is coalesced
     * away on some future release would otherwise silently bring back the exact
     * bug this exists to fix. Re-reading three properties is free; being wrong
     * about the Back button is what he noticed.
     *
     * `[weak self]` in every block. The observations are owned by this object
     * and observe a view this object owns, so a strong capture would be a cycle
     * holding a web content process open after the screen has gone.
     */
    private func watchNavigationState() {
        // `.initial` so the properties start out agreeing with a web view that
        // may already have been handed a page — not the case today, and a
        // cheaper guarantee than remembering it never will be.
        let options: NSKeyValueObservingOptions = [.initial, .new]
        observations = [
            webView.observe(\.canGoBack, options: options) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshNavigationState() }
            },
            webView.observe(\.title, options: options) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshNavigationState() }
            },
            webView.observe(\.url, options: options) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshNavigationState() }
            },
        ]
    }

    /**
     * Copy what the web view currently says into what this screen draws.
     *
     * Cheap enough to call on every signal — three property reads and three
     * assignments, and `@Observable` only publishes the ones that changed.
     *
     * The address falls back to what it was rather than to empty: `url` is nil
     * for the moment between a `stopLoading` and the next load, and a header
     * that blanked its own address in that window would read as the page having
     * gone when nothing has happened at all.
     */
    private func refreshNavigationState() {
        canGoBack = webView.canGoBack
        title = webView.title ?? ""
        address = webView.url?.absoluteString ?? address
    }

    /// Drop the page's only route back into this app. Called when the screen goes.
    func tearDown() {
        setInspecting(false)
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: InspectScript.messageHandler, contentWorld: Self.world)
        webView.stopLoading()
        // Before the web view is released rather than after: an observation left
        // registered against a deallocated object is the classic KVO crash, and
        // this screen is torn down every time somebody closes a page.
        observations = []
    }

    func load(_ url: URL) {
        failure = nil
        // No caching between opens. A dev server's whole job is to have changed
        // since last time, and a phone that shows yesterday's bundle because
        // `WKWebView` had it on disk is the single most confusing thing this
        // feature could do.
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    func reload() {
        failure = nil
        if loading {
            webView.stopLoading()
            return
        }
        webView.reloadFromOrigin()
    }

    func goBack() {
        if webView.canGoBack { webView.goBack() }
    }

    // MARK: - Inspecting

    func setInspecting(_ on: Bool) {
        inspecting = on
        if !on { capture = nil }
        run(on ? "window.__terminaldeck.enable()" : "window.__terminaldeck.disable()")
    }

    /// Walk the ancestor chain. +1 towards the document, -1 back to the tap.
    func step(_ delta: Int) {
        run("window.__terminaldeck.step(\(delta))")
    }

    /// The sheet was dismissed. The highlight goes with it, because a box left
    /// on an element nothing is asking about any more is a claim that it is.
    func clearCapture() {
        capture = nil
        run("window.__terminaldeck.clear()")
    }

    private func run(_ script: String) {
        // The script is defined at document start, so the only window in which
        // this can fail is a page mid-navigation — where the next `didFinish`
        // re-arms it anyway. Errors are dropped rather than surfaced: a page
        // that is being replaced is not a fault the user can act on.
        webView.evaluateJavaScript(script, in: nil, in: Self.world) { _ in }
    }

    /**
     * A payload from the page-side script.
     *
     * The URL is read off the web view rather than taken from the message, for
     * the same reason `browser-tab.ts` reads it off the `WebContents`: a payload
     * that could name its own page could tell the agent it is editing a different
     * site than it is. Everything else goes through `Inspect.parseCapture`, which
     * refuses rather than repairs.
     */
    fileprivate func received(_ body: Any) {
        guard inspecting else { return }
        guard let parsed = Inspect.parseCapture(body, url: webView.url?.absoluteString ?? address) else { return }
        capture = parsed
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        MainActor.assumeIsolated { sync(loading: true) }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            failure = nil
            sync(loading: false)
            // A new document is a new copy of the script, with `active` false and
            // no listeners. Without this, inspect mode silently stops working the
            // first time a dev server hot-reloads a route change — which is the
            // most common thing that happens on the page being inspected.
            if inspecting { run("window.__terminaldeck.enable()") }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { fail(error) }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error,
    ) {
        MainActor.assumeIsolated { fail(error) }
    }

    private func fail(_ error: Error) {
        sync(loading: false)
        let code = (error as NSError).code
        // -999 is "a load was replaced by another load", which happens on every
        // redirect and on `stopLoading`. Reporting it puts an error on screen
        // for a page that is working.
        guard code != NSURLErrorCancelled else { return }
        failure = sentence(for: error)
    }

    /**
     * A sentence, never `localizedDescription`.
     *
     * The failure that actually happens here is the dev server having
     * restarted, and Foundation calls that *"Could not connect to the
     * server"* — true, and it points at the wrong machine. Whoever reads it on
     * a phone has to know the tunnel is fine and the thing at the far end is
     * not.
     */
    private func sentence(for error: Error) -> String {
        switch (error as NSError).code {
        case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost:
            return "The server on the Mac did not answer. It may be restarting."
        case NSURLErrorTimedOut:
            return "The Mac took too long to answer."
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return "iOS refused to load this page over plain HTTP."
        default:
            return "The page could not be loaded."
        }
    }

    /// The delegate's half: whether a document navigation is in flight. The
    /// title, the address and `canGoBack` are not touched here any more — they
    /// are observed, because the delegate is silent for the same-document
    /// navigations a dev server makes constantly. See the type's header.
    private func sync(loading: Bool) {
        self.loading = loading
    }
}

private struct WebSurface: UIViewRepresentable {
    let browser: BrowserBridge

    func makeUIView(context: Context) -> WKWebView {
        browser.webView
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        // Nothing: every change goes through `BrowserBridge`, which owns the
        // view. Reloading from here would restart the page on every redraw.
    }
}

/**
 * The message handler, holding its owner weakly.
 *
 * `WKUserContentController` retains every handler added to it, and that
 * controller belongs to the `WKWebView` that `BrowserBridge` owns — so adding
 * the bridge itself makes a cycle, and the symptom is not a leak anybody
 * notices: it is a web content process still running, still holding the
 * tunnelled page, after the screen it belonged to has gone. `tearDown` removes
 * the handler as well; this is the half that survives a path that forgets to.
 */
private final class ScriptRelay: NSObject, WKScriptMessageHandler {
    private weak var bridge: BrowserBridge?

    init(_ bridge: BrowserBridge) {
        self.bridge = bridge
    }

    nonisolated func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage,
    ) {
        MainActor.assumeIsolated { bridge?.received(message.body) }
    }
}
