import AppKit
import WebKit

/// A retained web document can keep working while its native input subtree is outside
/// the keyboard's window. Attaching a document never claims focus on its behalf.
@MainActor
final class NativeSessionWebSlot: NSView, NativeSessionInputProtected {
    let inputRule = NativeSessionInputRule()
    private(set) var page: WKWebView?
    private var keyObserver: NSObjectProtocol?
    private var visible = true
    private var selected = true
    private var interactionEnabled = true
    private weak var scope: NativeSessionInputScope?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        inputRule.owner = self
        inputRule.onScopeWillDeactivate = { [weak self] in
            guard let self else { return }
            if !self.visible || self.scope?.active == false || !self.interactionEnabled { self.detachPage() }
            else { self.releaseKeyboard() }
        }
        inputRule.onScopeChanged = { [weak self] in self?.refreshAttachment() }
    }
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
    }

    func show(_ page: WKWebView, active: Bool, enabled: Bool = true, selected: Bool = true,
              scope: NativeSessionInputScope? = nil) {
        visible = active
        self.selected = selected
        interactionEnabled = enabled
        self.scope = scope
        if self.page !== page {
            detachPage()
            self.page = page
        }
        inputRule.bind(to: scope)
        inputRule.update(active: active, enabled: enabled && selected)
        refreshAttachment()
    }

    func deactivate() {
        visible = false
        inputRule.update(active: false, enabled: false)
        detachPage()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { detachPage() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver); self.keyObserver = nil }
        if let window {
            keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                                  object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshAttachment() }
            }
        }
        refreshAttachment()
    }

    private func refreshAttachment() {
        guard visible, scope?.active != false, interactionEnabled, window != nil, let page else { detachPage(); return }
        if !selected { releaseKeyboard() }
        if page.superview === self { return }
        // A restored background window must not remove the very same page from the
        // window the person is using. Its own key-window event can attach it later.
        if let currentWindow = page.window, currentWindow !== window, currentWindow.isKeyWindow,
           window?.isKeyWindow != true { return }
        if let previous = page.superview as? NativeSessionWebSlot, previous !== self {
            previous.detachPage()
        }
        page.frame = bounds
        page.autoresizingMask = [.width, .height]
        addSubview(page)
    }

    private func releaseKeyboard() {
        guard let page, page.superview === self else { return }
        let oldWindow = page.window ?? window
        if let responder = oldWindow?.firstResponder as? NSView,
           responder === page || responder.isDescendant(of: page) {
            responder.inputContext?.discardMarkedText()
            oldWindow?.makeFirstResponder(nil)
        }
        if let oldWindow { DeckTerminalSlot.restoreFocus(in: oldWindow, request: false) }
    }

    private func detachPage() {
        guard let page, page.superview === self else { return }
        let oldWindow = page.window ?? window
        releaseKeyboard()
        page.removeFromSuperview()
        if let oldWindow { DeckTerminalSlot.restoreFocus(in: oldWindow, request: false) }
    }
}
