import AppKit
import WebKit
import TerminalDeckNativeCore

/// Forwards `tdNative` messages without WebKit retaining the bridge (no retain cycle).
@MainActor
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WebBridge?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.receive(message)
    }
}

/// Owns the one WKWebView and enforces the bridge rules:
/// only the engine's own origin loads; everything else goes to the default browser.
@MainActor
final class WebBridge: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private let log: EngineLog

    /// The page posted `{type:'ready'}` (or loaded, for pages that reveal on load).
    var onReady: (() -> Void)?
    /// Every other message the page posts (sidebar, title, open-settings, settings-sections).
    var onMessage: ((PageMessage) -> Void)?
    /// The page went away and is loading again (web process crash).
    var onReloading: (() -> Void)?
    /// The page couldn't be loaded from the engine.
    var onLoadFailed: ((String) -> Void)?

    private(set) var origin: EngineOrigin?
    /// The last address loaded on purpose (not the page's own in-app navigation).
    private(set) var requestedURL: URL?
    /// Show the page as soon as it has loaded, without waiting for `{type:'ready'}`.
    private let revealOnLoad: Bool
    private var pageIsReady = false
    private var readyFallback: Task<Void, Never>?
    private var webProcessCrashes = 0
    private var lastExternalOpen: (url: URL, at: Date)?

    /// If the page loads but never says `ready`, show it anyway after this long
    /// (and note it in engine.log) rather than leaving a spinner over a working page.
    private static let readyFallbackDelay: Duration = .seconds(10)

    init(log: EngineLog, revealOnLoad: Bool = false) {
        self.log = log
        self.revealOnLoad = revealOnLoad

        let configuration = WKWebViewConfiguration()
        let proxy = ScriptMessageProxy()
        configuration.userContentController.add(proxy, name: PageMessage.handlerName)
        configuration.applicationNameForUserAgent = "TerminalDeckNative/0.1"

        webView = PageDropWebView(frame: .zero, configuration: configuration) // lane I: Finder drops → drop-paths (PageDrops.swift)
        super.init()

        proxy.target = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isInspectable = true // Safari ▸ Develop ▸ <this Mac> ▸ Terminal Deck
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.underPageBackgroundColor = .windowBackgroundColor
    }

    // MARK: Loading

    func load(_ url: URL) {
        guard let origin = EngineOrigin(url: url) else {
            onLoadFailed?("The engine's address isn't a local http address.")
            return
        }
        self.origin = origin
        requestedURL = url
        pageIsReady = false
        webProcessCrashes = 0
        readyFallback?.cancel()
        webView.load(URLRequest(url: url))
    }

    /// Forget the old engine's page (before a restart).
    func reset() {
        readyFallback?.cancel()
        pageIsReady = false
        origin = nil
        requestedURL = nil
        webView.stopLoading()
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    /// Keyboard focus into the page, so typing goes straight to the terminal.
    func focus() {
        webView.window?.makeFirstResponder(webView)
    }

    // MARK: Commands into the page

    func run(_ command: PageCommand) {
        let log = self.log
        let name = command.name
        webView.evaluateJavaScript(command.script) { _, error in
            guard let error = error as NSError? else { return }
            // A non-serialisable return value (e.g. a Promise) is not a failure.
            if error.domain == WKErrorDomain, error.code == WKError.Code.javaScriptResultTypeIsUnsupported.rawValue { return }
            log.note("command \(name) failed: \(error.localizedDescription)")
        }
    }

    /// The answer to one of the page's dialogs (NativeDialogs.swift).
    func run(_ command: DialogCommand) {
        let log = self.log
        let name = command.name
        webView.evaluateJavaScript(command.script) { _, error in
            guard let error = error as NSError? else { return }
            if error.domain == WKErrorDomain, error.code == WKError.Code.javaScriptResultTypeIsUnsupported.rawValue { return }
            log.note("dialog \(name) answer failed: \(error.localizedDescription)")
        }
    }

    // MARK: Messages from the page

    fileprivate func receive(_ message: WKScriptMessage) {
        guard let origin, message.frameInfo.isMainFrame else { return }
        let source = message.frameInfo.securityOrigin
        guard origin.matches(scheme: source.protocol, host: source.host, port: source.port) else {
            log.note("ignored a tdNative message from \(source.protocol)://\(source.host):\(source.port)")
            return
        }
        // The island's state goes to the native island (IslandPanel.swift), not to this window.
        if IslandRelay.shared.accept(message.body) { return }
        if NativeIslandFeed.shared.accept(message.body) { return } // lane B: the island's session list (NativeIslandContent.swift)
        if PageRequests.accept(message.body, from: self) { return } // lane I: context-menu, open-link (PageLinks.swift)
        if NativeNewSession.accept(message.body, from: self) { return } // lane B: the New session dialog (NativeNewSessionDialog.swift; page side native-new-session.ts)
        NativeCodingAIStore.noteSettingsRequest(message.body) // lane G: open-settings `action: 'add-account'` → native Add-account sheet (NativeCodingAIStore.swift)
        switch PageMessage.parse(message.body) {
        case .ready:
            markReady()
        case let other?:
            onMessage?(other)
        case nil:
            break
        }
    }

    private func markReady() {
        readyFallback?.cancel()
        guard !pageIsReady else { return }
        pageIsReady = true
        onReady?()
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        // targetFrame is nil for a link that asks for a new window: treat as top level.
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
            if let url { log.note("blocked navigation to \(EngineLineParser.redacted(url))") }
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // A reload this bridge didn't start (the page's own location.reload(), or
        // webView.reload()) is a new page: it must say `ready` again, so it gets told
        // everything again (`native-screens` first). Same-page navigations never commit.
        guard origin != nil, pageIsReady else { return }
        readyFallback?.cancel()
        pageIsReady = false
        onReloading?()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard origin != nil, webView.url?.scheme == "http", !pageIsReady else { return }
        if revealOnLoad { markReady(); return }
        readyFallback?.cancel()
        readyFallback = Task { [weak self] in
            try? await Task.sleep(for: Self.readyFallbackDelay)
            guard !Task.isCancelled, let self, !self.pageIsReady, self.origin != nil else { return }
            self.log.note("page loaded but never sent {type:'ready'} — showing it anyway")
            self.markReady()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        reportLoadError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        reportLoadError(error)
    }

    private func reportLoadError(_ error: any Error) {
        let ns = error as NSError
        // Cancelled loads and policy cancellations are ours, not failures.
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain", ns.code == 102 { return } // frame load interrupted by policy change
        guard let origin else { return }
        log.note("page load failed: \(ns.domain) \(ns.code) \(ns.localizedDescription)")
        onLoadFailed?("Couldn't load Terminal Deck from the engine at \(origin.display): \(ns.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webProcessCrashes += 1
        log.note("web content process ended (\(webProcessCrashes))")
        guard origin != nil else { return }
        if webProcessCrashes <= 2 {
            pageIsReady = false
            onReloading?()
            webView.reload()
        } else {
            onLoadFailed?("The page's web process keeps crashing (\(webProcessCrashes) times).")
        }
    }

    // MARK: WKUIDelegate — new windows, dialogs, file pickers

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // window.open(): external addresses go to the default browser; the proof has
        // no second native window, so engine pop-outs are noted and ignored.
        if let url = navigationAction.request.url, let origin {
            switch NavigationPolicy.decide(url: url, isMainFrame: true, origin: origin) {
            case .openExternally: openExternally(url)
            case .allow: log.note("ignored a request to open a new window at \(EngineLineParser.redacted(url))")
            case .block: log.note("blocked a new window to \(EngineLineParser.redacted(url))")
            }
        }
        return nil
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Terminal Deck"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        present(alert) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Terminal Deck"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert) { response in completionHandler(response == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Terminal Deck"
        alert.informativeText = prompt
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        present(alert) { response in
            completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        if let window = webView.window {
            panel.beginSheetModal(for: window) { response in
                completionHandler(response == .OK ? panel.urls : nil)
            }
        } else {
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
        }
    }

    // MARK: Helpers

    private func present(_ alert: NSAlert, then done: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        if let window = webView.window {
            alert.beginSheetModal(for: window) { response in done(response) }
        } else {
            done(alert.runModal())
        }
    }

    private func openExternally(_ url: URL) {
        // A target=_blank link can reach us twice (policy + new-window); open it once.
        if let last = lastExternalOpen, last.url == url, Date().timeIntervalSince(last.at) < 1 { return }
        lastExternalOpen = (url, Date())
        log.note("opening in default app: \(EngineLineParser.redacted(url))")
        NSWorkspace.shared.open(url)
    }
}
