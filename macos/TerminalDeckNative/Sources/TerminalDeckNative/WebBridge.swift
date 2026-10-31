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
    /// Only several ends in a short time mean "keeps crashing"; one every few hours over days
    /// of use is simply reloaded (it used to add up for the app's whole life, RETRY 11 Oct).
    private var crashWindow = DeckCrashWindow()
    /// Automatic reloads already spent on the load that is failing (DeckRetryRules.pauses).
    private var loadRetries = 0
    private var loadRetry: Task<Void, Never>?
    private var lastExternalOpen: (url: URL, at: Date)?

    /// If the page loads but never says `ready`, show it anyway after this long
    /// (and note it in engine.log) rather than leaving a spinner over a working page.
    private static let readyFallbackDelay: Duration = .seconds(10)

    init(log: EngineLog, revealOnLoad: Bool = false, websiteDataStore: WKWebsiteDataStore? = nil) {
        self.log = log
        self.revealOnLoad = revealOnLoad

        let configuration = WKWebViewConfiguration()
        #if DEBUG
        if ProcessInfo.processInfo.environment[NativeLaunchSwitches.uiTest] == "1" {
            configuration.websiteDataStore = .nonPersistent()
        }
        #endif
        let proxy = ScriptMessageProxy()
        configuration.userContentController.add(proxy, name: PageMessage.handlerName)
        // TRUTH-B: the app plays the finish sound itself (NativeFinishSound); the hidden page's WebAudio copy, its
        // only use of audio, is switched off so a finished session is never heard twice.
        configuration.userContentController.addUserScript(WKUserScript(source: "try { window.AudioContext = undefined; window.webkitAudioContext = undefined; } catch (_) {}",
                                                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if let websiteDataStore { configuration.websiteDataStore = websiteDataStore }
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
        crashWindow.reset(); loadRetries = 0; loadRetry?.cancel()
        readyFallback?.cancel()
        webView.load(URLRequest(url: url))
    }

    /// Forget the old engine's page (before a restart).
    func reset() {
        readyFallback?.cancel()
        loadRetry?.cancel(); loadRetries = 0
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

    /// The same command, with the page's own answer: false when it did not take it (or the page is not there), so a
    /// control can say so instead of doing nothing (Asad, 12 Oct: commands the page dropped looked like dead buttons).
    func ask(_ command: PageCommand) async -> Bool {
        await withCheckedContinuation { done in
            webView.evaluateJavaScript(command.script) { result, _ in
                done.resume(returning: (result as? Bool) == true || (result as? NSNumber)?.boolValue == true)
            }
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
        let source = message.frameInfo.securityOrigin
        receive(message.body, isMainFrame: message.frameInfo.isMainFrame,
                scheme: source.protocol, host: source.host, port: source.port)
    }

    /// Keep origin checks on the same path for WebKit messages and protocol fixtures.
    func receive(_ body: Any, isMainFrame: Bool, scheme: String, host: String, port: Int) {
        guard let origin, isMainFrame else { return }
        guard origin.matches(scheme: scheme, host: host, port: port) else {
            log.note("ignored a tdNative message from \(scheme)://\(host):\(port)")
            return
        }
        // The island's state goes to the native island (IslandPanel.swift), not to this window.
        if PageRequests.accept(body, from: self) { return } // lane I: context-menu, open-link (PageLinks.swift)
        if NativeNewSession.accept(body, from: self) { return } // lane B: the New session dialog (NativeNewSessionDialog.swift; page side native-new-session.ts)
        NativeCodingAIStore.noteSettingsRequest(body) // lane G: open-settings `action: 'add-account'` → native Add-account sheet (NativeCodingAIStore.swift)
        switch PageMessage.parse(body) {
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
        loadRetries = 0; loadRetry?.cancel()
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
        // The engine's page not answering once is asked again by itself, twice, with a short
        // pause, before the person is shown "couldn't load" and a Try Again button.
        if !pageIsReady, let url = requestedURL, let pause = DeckRetryRules.pause(beforeAutomaticTry: loadRetries) {
            loadRetries += 1
            log.note("page load failed: \(ns.domain) \(ns.code) \(ns.localizedDescription); loading again by itself (\(loadRetries))")
            loadRetry?.cancel()
            loadRetry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(pause))
                guard !Task.isCancelled, let self, self.requestedURL == url, !self.pageIsReady else { return }
                self.webView.load(URLRequest(url: url))
            }
            return
        }
        log.note("page load failed: \(ns.domain) \(ns.code) \(ns.localizedDescription)")
        onLoadFailed?("Couldn't load Terminal Deck from the engine at \(origin.display): \(ns.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webProcessCrashes += 1
        let reload = crashWindow.reloadAfterEnd(at: Date().timeIntervalSinceReferenceDate)
        log.note("web content process ended (\(webProcessCrashes), \(crashWindow.recentEnds) in the last minute)")
        guard origin != nil else { return }
        if reload {
            pageIsReady = false
            onReloading?()
            webView.reload()
        } else {
            onLoadFailed?("The page's web process keeps crashing (\(crashWindow.recentEnds) times in a minute).")
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
            // A page with no window (a hidden page) never runs an app-modal panel: that took the
            // front and blocked quitting (walk 2). TS's hidden pages had no chooser either.
            AppModel.shared.engine.log.note("page chooser refused: the page has no window")
            completionHandler(nil)
        }
    }

    // MARK: Helpers

    private func present(_ alert: NSAlert, then done: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        if let window = webView.window {
            alert.beginSheetModal(for: window) { response in done(response) }
        } else {
            AppModel.shared.engine.log.note("page dialog answered Cancel: the page has no window")
            done(.cancel)
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
