import AppKit
import WebKit
import TerminalDeckNativeCore

/// Forwards the island page's `tdNative` messages without WebKit retaining the owner.
@MainActor
private final class IslandMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: IslandWeb?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.receive(message)
    }
}

/// The island's expanded content: `<engine origin>/?island=1` in a transparent
/// web view, under the same rules as the main window's — only the engine's own
/// origin loads; http(s)/mailto links go to the default browser; nothing else.
@MainActor
final class IslandWeb: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private let log: EngineLog

    /// The page loaded (true) or went away (false).
    var onLoaded: ((Bool) -> Void)?

    private var origin: EngineOrigin?
    private(set) var requestedURL: URL?
    private(set) var loaded = false
    private var crashes = 0
    private var lastExternalOpen: (url: URL, at: Date)?

    init(log: EngineLog) {
        self.log = log
        let configuration = WKWebViewConfiguration()
        let proxy = IslandMessageProxy()
        configuration.userContentController.add(proxy, name: PageMessage.handlerName)
        configuration.applicationNameForUserAgent = "TerminalDeckNative/0.1"
        // The default website data store, shared with the main window: the bridge
        // cookie its first load set is what lets this page in without the token.
        webView = PageDropWebView(frame: .zero, configuration: configuration)
        super.init()

        proxy.target = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.underPageBackgroundColor = .clear
        // Transparent, so the island's black shape is the background. WebKit has no
        // public switch for this on macOS; the KVC key is used only if it exists.
        if webView.responds(to: NSSelectorFromString("_setDrawsBackground:"))
            || webView.responds(to: NSSelectorFromString("setDrawsBackground:")) {
            webView.setValue(false, forKey: "drawsBackground")
        }
    }

    // MARK: Loading

    /// Load the island page for this engine (a no-op if it is already the one loaded).
    func load(engineURL: URL) {
        guard let url = IslandLocation.url(engineURL: engineURL), let origin = EngineOrigin(url: url) else {
            log.note("island: refused engine address \(EngineLineParser.redacted(engineURL))")
            return
        }
        if url == requestedURL, loaded || webView.isLoading { return }
        self.origin = origin
        requestedURL = url
        crashes = 0
        setLoaded(false)
        webView.load(URLRequest(url: url))
    }

    /// The engine is gone: forget its page.
    func unload() {
        guard origin != nil || requestedURL != nil else { return }
        origin = nil
        requestedURL = nil
        setLoaded(false)
        webView.stopLoading()
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    func run(_ script: String) {
        guard loaded else { return }
        let log = self.log
        webView.evaluateJavaScript(script) { _, error in
            guard let error = error as NSError? else { return }
            if error.domain == WKErrorDomain, error.code == WKError.Code.javaScriptResultTypeIsUnsupported.rawValue { return }
            log.note("island: command failed: \(error.localizedDescription)")
        }
    }

    private func setLoaded(_ value: Bool) {
        guard loaded != value else { return }
        loaded = value
        onLoaded?(value)
    }

    // MARK: Messages from the page

    fileprivate func receive(_ message: WKScriptMessage) {
        guard let origin, message.frameInfo.isMainFrame else { return }
        let source = message.frameInfo.securityOrigin
        guard origin.matches(scheme: source.protocol, host: source.host, port: source.port) else {
            log.note("island: ignored a tdNative message from \(source.protocol)://\(source.host):\(source.port)")
            return
        }
        if IslandRelay.shared.accept(message.body) { return }
        if PageMessage.parse(message.body) == .ready { setLoaded(true) }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let decision: NavigationDecision
        if let origin {
            decision = NavigationPolicy.decide(url: url, isMainFrame: isMainFrame, origin: origin)
        } else {
            decision = url?.absoluteString == "about:blank" ? .allow : .block
        }
        switch decision {
        case .allow:
            decisionHandler(.allow)
        case .openExternally:
            decisionHandler(.cancel)
            if let url { openExternally(url) }
        case .block:
            decisionHandler(.cancel)
            if let url { log.note("island: blocked navigation to \(EngineLineParser.redacted(url))") }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let origin, let url = webView.url, origin.contains(url) else { return }
        setLoaded(true)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        loadFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        loadFailed(error)
    }

    private func loadFailed(_ error: any Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain", ns.code == 102 { return }
        guard origin != nil else { return }
        log.note("island: page load failed: \(ns.domain) \(ns.code) \(ns.localizedDescription)")
        setLoaded(false)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        crashes += 1
        log.note("island: web content process ended (\(crashes))")
        setLoaded(false)
        guard origin != nil, crashes <= 2 else { return }
        webView.reload()
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, let origin,
           NavigationPolicy.decide(url: url, isMainFrame: true, origin: origin) == .openExternally {
            openExternally(url)
        }
        return nil
    }

    private func openExternally(_ url: URL) {
        if let last = lastExternalOpen, last.url == url, Date().timeIntervalSince(last.at) < 1 { return }
        lastExternalOpen = (url, Date())
        log.note("island: opening in default app: \(EngineLineParser.redacted(url))")
        NSWorkspace.shared.open(url)
    }
}
