import AppKit
import ObjectiveC
import TerminalDeckNativeCore

@MainActor
enum NativeScrollbars {
    private static var installed = false
    private static var observerKey: UInt8 = 0
    private static var pointerMonitor: Any?
    private static var windowObserver: (any NSObjectProtocol)?
    private static weak var hovered: ScrollbarHover?
    private static let views = NSHashTable<NSView>.weakObjects()

    static func install() {
        // SwiftUI must retain automatic indicators: .never suppresses the scroller
        // before this shared overlay/hover policy can reveal it.
        guard !installed else { return }
        installed = true
        exchange(NSScrollView.self, #selector(setter: NSScrollView.scrollerStyle), #selector(NSScrollView.deckScrollerStyle(_:)))
        exchange(NSScrollView.self, #selector(setter: NSScrollView.hasVerticalScroller), #selector(NSScrollView.deckVerticalScroller(_:)))
        exchange(NSScrollView.self, #selector(setter: NSScrollView.hasHorizontalScroller), #selector(NSScrollView.deckHorizontalScroller(_:)))
        exchange(NSScrollView.self, #selector(setter: NSScrollView.autohidesScrollers), #selector(NSScrollView.deckAutohidesScrollers(_:)))
        exchange(NSScrollView.self, #selector(NSScrollView.tile), #selector(NSScrollView.deckTile))
        exchange(NSScroller.self, #selector(setter: NSScroller.isHidden), #selector(NSScroller.deckHidden(_:)))
        exchange(NSScroller.self, #selector(setter: NSScroller.alphaValue), #selector(NSScroller.deckAlpha(_:)))
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                if let window, !window.acceptsMouseMovedEvents { window.acceptsMouseMovedEvents = true }
            }
        }
        for window in NSApp.windows { window.acceptsMouseMovedEvents = true }
        // Leave tracking-area ownership to SwiftUI; a scroll-wide mouseMoved area
        // takes movement delivery away from the message rows underneath it.
        pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseEntered, .mouseExited, .scrollWheel]) { event in
            if let window = event.window { followPointer(window: window, point: event.locationInWindow, scrolling: event.type == .scrollWheel) }
            return event
        }
    }

    private static func exchange(_ cls: AnyClass, _ original: Selector, _ replacement: Selector) {
        guard let first = class_getInstanceMethod(cls, original), let second = class_getInstanceMethod(cls, replacement) else { return }
        // Do not exchange an inherited NSView method on NSView itself.
        if class_addMethod(cls, original, method_getImplementation(second), method_getTypeEncoding(second)) {
            class_replaceMethod(cls, replacement, method_getImplementation(first), method_getTypeEncoding(first))
        } else { method_exchangeImplementations(first, second) }
    }

    static func attach(to view: NSView) {
        if let scroll = view as? NSScrollView {
            if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
            if !scroll.autohidesScrollers { scroll.autohidesScrollers = true }
        } else if let terminal = view as? DeckTerminalView { terminal.scrollerStyle = .overlay }
        if objc_getAssociatedObject(view, &observerKey) == nil {
            let observer = ScrollbarHover(view: view)
            objc_setAssociatedObject(view, &observerKey, observer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            views.add(view)
        }
        view.window?.acceptsMouseMovedEvents = true
    }

    private static func followPointer(window: NSWindow, point: NSPoint, scrolling: Bool) {
        guard let content = window.contentView else { return }
        var hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
        while let view = hit {
            if view is NSScrollView || view is DeckTerminalView {
                attach(to: view)
                if let observer = objc_getAssociatedObject(view, &observerKey) as? ScrollbarHover {
                    reveal(observer, scrolling: scrolling); return
                }
            }
            hit = view.superview
        }
        // SwiftUI may hit its drawing host instead of the underlying AppKit scroll view.
        let candidate = views.allObjects.filter { view in
            view.window === window && !view.isHiddenOrHasHiddenAncestor && view.alphaValue > 0 &&
                view.visibleRect.contains(view.convert(point, from: nil))
        }.min { $0.visibleRect.width * $0.visibleRect.height < $1.visibleRect.width * $1.visibleRect.height }
        if let candidate, let observer = objc_getAssociatedObject(candidate, &observerKey) as? ScrollbarHover {
            reveal(observer, scrolling: scrolling)
        } else { hovered?.leave(); hovered = nil }
    }

    fileprivate static func reveal(_ observer: ScrollbarHover, scrolling: Bool = false) {
        if hovered !== observer { hovered?.leave(); hovered = observer }
        observer.reveal(scrolling: scrolling)
    }

    fileprivate static func pinned(_ scroller: NSScroller) -> Bool {
        var ancestor = scroller.superview
        while let view = ancestor {
            if let observer = objc_getAssociatedObject(view, &observerKey) as? ScrollbarHover {
                return observer.pinned && observer.shown.contains(ObjectIdentifier(scroller)) && scroller.isEnabled
            }
            ancestor = view.superview
        }
        return false
    }
    fileprivate static func alpha(_ scroller: NSScroller, requested: CGFloat) -> CGFloat {
        var ancestor = scroller.superview
        while let view = ancestor {
            if let observer = objc_getAssociatedObject(view, &observerKey) as? ScrollbarHover {
                if observer.faded { return 0 }
                return pinned(scroller) ? 1 : requested
            }
            ancestor = view.superview
        }
        return requested
    }
    static func snapshot() -> NativeRPCValue {
        .array(views.allObjects.prefix(100).compactMap { view in
            guard let window = view.window, window.isVisible, !view.isHiddenOrHasHiddenAncestor else { return nil }
            let scroll = view as? NSScrollView
            let bars = scroll.map { [$0.verticalScroller, $0.horizontalScroller].compactMap { $0 } } ?? view.subviews.compactMap { $0 as? NSScroller }
            let observer = objc_getAssociatedObject(view, &observerKey) as? ScrollbarHover
            return .object([.init("windowId", .number(Double(window.windowNumber))), .init("class", .string(String(describing: type(of: view)))),
                .init("width", .number(view.visibleRect.width)), .init("height", .number(view.visibleRect.height)),
                .init("documentHeight", .number(Double(scroll?.contentView.documentRect.height ?? 0))), .init("pinned", .bool(observer?.pinned == true)),
                .init("bars", .array(bars.map { .object([.init("alpha", .number($0.alphaValue)), .init("hidden", .bool($0.isHidden)), .init("enabled", .bool($0.isEnabled))]) }))])
        })
    }
}

extension NSScrollView {
    @objc fileprivate func deckScrollerStyle(_ style: NSScroller.Style) { deckScrollerStyle(.overlay) }
    @objc fileprivate func deckVerticalScroller(_ value: Bool) { deckVerticalScroller(true) }
    @objc fileprivate func deckHorizontalScroller(_ value: Bool) { deckHorizontalScroller(true) }
    @objc fileprivate func deckAutohidesScrollers(_ value: Bool) { deckAutohidesScrollers(true) }
    @objc fileprivate func deckTile() { deckTile(); NativeScrollbars.attach(to: self) }
}

extension NSScroller {
    @objc fileprivate func deckHidden(_ hidden: Bool) { deckHidden(NativeScrollbars.pinned(self) ? false : hidden) }
    @objc fileprivate func deckAlpha(_ alpha: CGFloat) { deckAlpha(NativeScrollbars.alpha(self, requested: alpha)) }
}

@MainActor
private final class ScrollbarHover: NSObject {
    private weak var view: NSView?
    private var fade: DispatchWorkItem?
    private var boundsObserver: (any NSObjectProtocol)?
    private var lastOrigin: NSPoint = .zero
    fileprivate var faded = true
    fileprivate var pinned = false
    fileprivate var shown: Set<ObjectIdentifier> = []

    init(view: NSView) {
        self.view = view
        super.init()
        if let scroll = view as? NSScrollView {
            lastOrigin = scroll.contentView.bounds.origin
            scroll.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let scroll = self.view as? NSScrollView else { return }
                    let origin = scroll.contentView.bounds.origin
                    guard origin != self.lastOrigin else { return }
                    self.lastOrigin = origin
                    self.reveal(scrolling: true)
                }
            }
        }
    }
    isolated deinit {
        fade?.cancel()
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }

    private var bars: [NSScroller] {
        if let scroll = view as? NSScrollView { return [scroll.verticalScroller, scroll.horizontalScroller].compactMap { $0 } }
        return view?.subviews.compactMap { $0 as? NSScroller } ?? []
    }

    func reveal(scrolling _: Bool) {
        fade?.cancel()
        faded = false
        pinned = true
        let eligible: [NSScroller]
        if let scroll = view as? NSScrollView {
            let document = scroll.contentView.documentRect, viewport = scroll.contentView.bounds
            eligible = [document.height > viewport.height + 1 ? scroll.verticalScroller : nil,
                        document.width > viewport.width + 1 ? scroll.horizontalScroller : nil].compactMap { $0 }
            shown = Set(eligible.map(ObjectIdentifier.init))
            scroll.flashScrollers()
        } else {
            eligible = bars.filter { $0.isEnabled }
            shown = Set(eligible.map(ObjectIdentifier.init))
        }
        for scroller in eligible {
            scroller.scrollerStyle = .overlay
            scroller.isEnabled = true
            scroller.isHidden = false
            scroller.alphaValue = 1
            scroller.needsDisplay = true
        }
        // Titlebar/outside-window moves can omit mouseExited. Never leave a bar
        // pinned forever when AppKit does not deliver that final event.
        scheduleFade()
    }

    func leave() { pinned = false; scheduleFade() }

    private func scheduleFade() {
        fade?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pinned = false
            // AppKit can restore overlay alpha after its own flash timer expires.
            // Keep that late write hidden until the next hover or actual scroll.
            self.faded = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                for scroller in self.bars { scroller.animator().alphaValue = 0 }
            }
        }
        fade = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}
