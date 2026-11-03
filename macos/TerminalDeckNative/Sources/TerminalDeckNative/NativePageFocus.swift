import AppKit
import WebKit

/// SETTINGS-TRUTH row 59 (TRUTH-A2): "Only when the app is in the background" is judged by the hidden page with
/// `document.hasFocus()`, which is false whenever a native screen has the focus, so session banners fired while
/// the person was looking at the app. The page is told the app's real state instead: Terminal Deck in front
/// (NSApp.isActive) is "looking"; another app in front is "in the background".
@MainActor
enum NativePageFocus {
    private static var observers: [NSObjectProtocol] = []
    static let script = "try { if (window.__tdAppActive === undefined) { window.__tdAppActive = true; } Document.prototype.hasFocus = function () { return window.__tdAppActive === true; }; } catch (_) {}"
    static func line(active: Bool) -> String { "window.__tdAppActive = \(active ? "true" : "false");" }

    static func install(on webView: WKWebView) {
        guard observers.isEmpty else { return }
        webView.configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView.evaluateJavaScript(script + " " + line(active: NSApp?.isActive ?? true), completionHandler: nil)
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                let active = note.name == NSApplication.didBecomeActiveNotification
                MainActor.assumeIsolated { AppModel.shared.web.webView.evaluateJavaScript(script + " " + line(active: active), completionHandler: nil) }
            })
        }
    }
}
