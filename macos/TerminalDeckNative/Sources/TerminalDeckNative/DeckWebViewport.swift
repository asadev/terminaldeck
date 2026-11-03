import AppKit
import WebKit

/// Finite native viewport shared by the engine page and browser pages. The owner
/// retains its WKWebView; changing screens never reloads its document or history.
@MainActor
final class DeckWebViewport: NSView {
    private(set) var page: WKWebView?
    private var originalTop: CGFloat = 0
    private var layoutObservation: NSKeyValueObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = true
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    func show(_ page: WKWebView?, visible: Bool = true) {
        isHidden = !visible
        if self.page !== page || (page != nil && page?.superview !== self) {
            detach()
            if let page {
                // Restore the old host's base inset before this host captures it.
                if let old = page.superview as? DeckWebViewport, old !== self { old.detach() }
                self.page = page
                originalTop = page.obscuredContentInsets.top
                page.removeFromSuperview()
                page.translatesAutoresizingMaskIntoConstraints = true
                page.autoresizingMask = [.width, .height]
                addSubview(page)
            }
        }
        needsLayout = true
    }
    func detach() {
        if let page, page.superview === self {
            var insets = page.obscuredContentInsets
            insets.top = originalTop
            page.obscuredContentInsets = insets
            page.removeFromSuperview()
        }
        page = nil
        originalTop = 0
    }
    func dismantle() {
        detach()
        stopObservingWindow()
    }
    override func layout() {
        super.layout()
        guard let page, page.superview === self else { return }
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.width >= 0, bounds.height >= 0 else { return }
        page.frame = bounds
        var insets = page.obscuredContentInsets
        // Measure actual overlap, avoiding a second toolbar inset when SwiftUI
        // has already placed this viewport below the toolbar's safe area.
        let overlap = window.map {
            Self.topOverlap(pageTop: convert(bounds, to: nil).maxY,
                            layoutTop: $0.contentLayoutRect.maxY, height: bounds.height)
        } ?? 0
        insets.top = max(originalTop, overlap)
        if page.obscuredContentInsets.top != insets.top { page.obscuredContentInsets = insets }
    }
    static func topOverlap(pageTop: CGFloat, layoutTop: CGFloat, height: CGFloat) -> CGFloat {
        guard pageTop.isFinite, layoutTop.isFinite, height.isFinite else { return 0 }
        return min(max(0, height), max(0, pageTop - layoutTop))
    }
    /// A fill viewport has no document-driven ideal/minimum size. Layout probes
    /// with missing or nonfinite dimensions are neutral; real finite proposals pass through.
    static func proposedSize(width: CGFloat?, height: CGFloat?) -> CGSize {
        func dimension(_ value: CGFloat?) -> CGFloat {
            guard let value, value.isFinite else { return 0 }
            return max(0, value)
        }
        return CGSize(width: dimension(width), height: dimension(height))
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObservingWindow()
        if let window {
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification,
                         NSWindow.didEndLiveResizeNotification,
                         NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowGeometryChanged(_:)), name: name, object: window)
            }
            // Toolbar/title-area changes can alter the safe layout without resizing the window.
            layoutObservation = window.observe(\.contentLayoutRect, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.needsLayout = true }
            }
        }
        needsLayout = true
    }
    @objc private func windowGeometryChanged(_ notification: Notification) { needsLayout = true }
    private func stopObservingWindow() {
        layoutObservation?.invalidate()
        layoutObservation = nil
        NotificationCenter.default.removeObserver(self)
    }
}
