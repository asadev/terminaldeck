import AppKit
import WebKit
import TerminalDeckNativeCore

/// The page requests lane I answers, reached from the one marked line in
/// `WebBridge.receive`: context menus (PageMenus.swift) and links (below).
@MainActor
enum PageRequests {
    /// True when `body` was one of ours (taken here, well-formed or not).
    static func accept(_ body: Any, from bridge: WebBridge) -> Bool {
        if ContextMenuRequest.isContextMenuMessage(body) {
            PageMenus.show(ContextMenuRequest.parse(body), in: bridge.webView)
            return true
        }
        if LinkRequest.isLinkMessage(body) {
            PageLinks.open(LinkRequest.parse(body), engineOrigin: bridge.origin, from: bridge.webView)
            return true
        }
        return false
    }
}

/// `{type:'open-link', url, disposition}`: a native browser tab, the default
/// browser, or — for a file or another app's link — only after asking.
@MainActor
enum PageLinks {
    private static var lastOpen: (url: String, at: Date)?

    private static var log: EngineLog { AppModel.shared.engine.log }

    static func open(_ request: LinkRequest?, engineOrigin: EngineOrigin?, from webView: WKWebView) {
        guard let request else {
            log.note("open-link: ignored a request without a usable url")
            return
        }
        // One click can arrive twice (a press and a fallback); open it once.
        if let last = lastOpen, last.url == request.url, Date().timeIntervalSince(last.at) < 1 { return }
        lastOpen = (request.url, Date())

        switch LinkPolicy.decide(request, engineOrigin: engineOrigin) {
        case .tab(let url):
            log.note("open-link: tab \(EngineLineParser.redacted(url))")
            NativeBrowserTabs.shared.create(url: url)
        case .external(let url):
            log.note("open-link: default app \(EngineLineParser.redacted(url))")
            NSWorkspace.shared.open(url)
        case .askFile(let url):
            askToShowFile(url, from: webView)
        case .askApp(let url):
            askToOpenInApp(url, from: webView)
        case .refuse(let reason):
            log.note("open-link: refused \(EngineLineParser.redacted(request.url)) (\(reason))")
            NSSound.beep()
        }
    }

    /// A file is shown in Finder, never opened or run from a page's say-so.
    private static func askToShowFile(_ url: URL, from webView: WKWebView) {
        let alert = NSAlert()
        alert.messageText = "Show “\(url.lastPathComponent)” in Finder?"
        alert.informativeText = "Terminal Deck was asked to open a file on this Mac:\n\(url.path)"
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Cancel")
        present(alert, over: webView) { response in
            guard response == .alertFirstButtonReturn else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private static func askToOpenInApp(_ url: URL, from webView: WKWebView) {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            log.note("open-link: no app opens \(url.scheme ?? "?"): links")
            NSSound.beep()
            return
        }
        let name = FileManager.default.displayName(atPath: app.path)
            .replacingOccurrences(of: ".app", with: "")
        let alert = NSAlert()
        alert.messageText = "Open this link in \(name)?"
        alert.informativeText = String(EngineLineParser.redacted(url).prefix(400))
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        present(alert, over: webView) { response in
            guard response == .alertFirstButtonReturn else { return }
            log.note("open-link: \(name) \(url.scheme ?? "?"):")
            NSWorkspace.shared.open(url)
        }
    }

    private static func present(_ alert: NSAlert, over webView: WKWebView,
                                then done: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        if let window = webView.window {
            alert.beginSheetModal(for: window) { response in done(response) }
        } else {
            // No window to ask over: not an app-modal alert that takes the front (walk 2).
            done(.cancel)
        }
    }
}

// MARK: Microphone for dictation

extension WebBridge {
    /// The engine's own page may use the microphone (the system still asks the person
    /// once, with Info.plist's NSMicrophoneUsageDescription). Nothing else may, and
    /// nothing may use the camera. (The selector is spelled out: this lives in an
    /// extension in another file, and WebKit finds it only by that exact name.)
    @objc(webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:)
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        let kind: MediaCapturePolicy.Kind
        switch type {
        case .microphone: kind = .microphone
        case .camera: kind = .camera
        case .cameraAndMicrophone: kind = .cameraAndMicrophone
        @unknown default:
            decisionHandler(.deny)
            return
        }
        let decision = MediaCapturePolicy.decide(kind: kind, scheme: origin.protocol, host: origin.host,
                                                 port: origin.port, engineOrigin: self.origin)
        decisionHandler(decision == .grant ? .grant : .deny)
    }
}
