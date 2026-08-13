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
 */

import SwiftUI
import WebKit

struct LocalhostBrowser: View {
    let model: DeckModel
    let tunnel: PortTunnel
    let dismiss: () -> Void

    @State private var browser = BrowserBridge()

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().overlay(Theme.hairline)
                content
            }
        }
        .preferredColorScheme(.dark)
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
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Button {
                    browser.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                }
                .disabled(!browser.canGoBack)
                .accessibilityLabel("Back")

                Button {
                    browser.reload()
                } label: {
                    Image(systemName: browser.loading ? "xmark" : "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                }
                .disabled(!isLive)
                .accessibilityLabel(browser.loading ? "Stop loading" : "Reload")

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
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

    let webView: WKWebView

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

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        MainActor.assumeIsolated { sync(loading: true) }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            failure = nil
            sync(loading: false)
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

    private func sync(loading: Bool) {
        self.loading = loading
        title = webView.title ?? ""
        address = webView.url?.absoluteString ?? address
        canGoBack = webView.canGoBack
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
