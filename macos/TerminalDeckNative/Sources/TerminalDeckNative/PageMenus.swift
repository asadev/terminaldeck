import AppKit
import WebKit
import TerminalDeckNativeCore

/// Remembers which row of a shown menu was chosen.
@MainActor
private final class PageMenuTarget: NSObject {
    private(set) var chosen: String?

    @objc func choose(_ sender: NSMenuItem) {
        chosen = sender.representedObject as? String
    }
}

/// `{type:'context-menu', …}`: a native menu at the page's point, answered with
/// `context-menu-result` — the chosen row's id, or null when dismissed.
@MainActor
enum PageMenus {
    static func show(_ parsed: ContextMenuRequest.Parsed?, in webView: WKWebView) {
        switch parsed {
        case nil:
            AppModel.shared.engine.log.note("context-menu: ignored a request without an id")
        case .dismissOnly(let id):
            reply(id: id, itemId: nil, to: webView)
        case .show(let request):
            // Let the message handler return before the menu's tracking loop starts.
            Task { @MainActor in present(request, in: webView) }
        }
    }

    private static func present(_ request: ContextMenuRequest, in webView: WKWebView) {
        guard webView.window != nil else {
            reply(id: request.id, itemId: nil, to: webView)
            return
        }
        let target = PageMenuTarget()
        let menu = build(request.items, target: target)
        let zoom = webView.pageZoom > 0 ? webView.pageZoom : 1
        let x = request.x * zoom
        let y = request.y * zoom
        let point = NSPoint(x: x, y: webView.isFlipped ? y : webView.bounds.height - y)
        menu.popUp(positioning: nil, at: point, in: webView)
        // The chosen row's action has run by the time this is reached.
        Task { @MainActor in reply(id: request.id, itemId: target.chosen, to: webView) }
    }

    private static func build(_ items: [ContextMenuItem], target: PageMenuTarget) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            if item.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let row = NSMenuItem(title: item.label, action: nil, keyEquivalent: "")
            row.isEnabled = item.enabled
            row.state = item.checked ? .on : .off
            if let children = item.submenu {
                row.submenu = build(children, target: target)
            } else {
                row.action = #selector(PageMenuTarget.choose(_:))
                row.target = target
                row.representedObject = item.id
            }
            menu.addItem(row)
        }
        return menu
    }

    private static func reply(id: String, itemId: String?, to webView: WKWebView) {
        let log = AppModel.shared.engine.log
        webView.evaluateJavaScript(ContextMenuRequest.resultScript(id: id, itemId: itemId)) { _, error in
            guard let error = error as NSError? else { return }
            if error.domain == WKErrorDomain, error.code == WKError.Code.javaScriptResultTypeIsUnsupported.rawValue { return }
            log.note("context-menu-result failed: \(error.localizedDescription)")
        }
    }
}
