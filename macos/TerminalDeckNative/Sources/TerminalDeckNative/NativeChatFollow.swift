import AppKit
import SwiftUI
import TerminalDeckNativeCore

@MainActor @Observable final class NativeChatFollowViewport {
    let id = UUID()
    var position = ScrollPosition(edge: .bottom)
    private(set) var state = ChatFollowState()
    var interacting = false
    var expandedCards: Set<String> = []
    @ObservationIgnored var latestLine = CGRect.zero
    @ObservationIgnored var composer = CGRect.zero
    @ObservationIgnored var pin: (() -> Void)?
    @ObservationIgnored var move: ((CGFloat) -> Void)?
    var following: Bool { state.following }

    func latest() {
        state.resume()
        // Pin the native clip now; the next document/viewport layout pins again if the message arrives later.
        pin?()
        position.scrollTo(edge: .bottom)
    }
    func pause() { state.pause() }
    func measure(offset: CGFloat, viewport: CGFloat, content: CGFloat) -> Bool {
        state.measure(offset: offset, viewport: viewport, content: content, interacting: interacting)
    }
    func page(_ direction: CGFloat) {
        state.pause()
        move?(direction * CGFloat(max(40, state.viewport * 0.8)))
    }
    var receipt: NativeRPCValue {
        .object([.init("viewId", .string(id.uuidString)), .init("following", .bool(following)), .init("atBottom", state.viewport > 0 ? .bool(state.atBottom) : .null),
                 .init("distanceToBottom", state.viewport > 0 ? .number(max(0, state.maximumOffset - state.offset)) : .null),
                 .init("viewportHeight", .number(state.viewport)),
                 .init("lineGap", latestLine.isEmpty || composer.isEmpty ? .null : .number(composer.minY - latestLine.maxY)),
                 .init("composerHeight", .number(composer.height))])
    }
}

/// SwiftUI's scroll position alone can miss height changes inside an expanded tool card.
/// Observe the actual document and clip, and disallow rubber-band space beyond their real end.
struct NativeChatFollowScroll: NSViewRepresentable {
    let viewport: NativeChatFollowViewport
    func makeNSView(context: Context) -> Probe { Probe(viewport) }
    func updateNSView(_ view: Probe, context: Context) { view.attach() }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.detach() }

    @MainActor final class Probe: NSView {
        let viewport: NativeChatFollowViewport
        private weak var scroll: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        private var adjusting = false
        init(_ viewport: NativeChatFollowViewport) { self.viewport = viewport; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("Not used") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            Task { @MainActor [weak self] in self?.attach() }
        }
        override func layout() { super.layout(); attach(); measure() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func attach() {
            guard let next = enclosingScrollView, let document = next.documentView else { return }
            guard scroll !== next else { return }
            detach(); scroll = next
            next.verticalScrollElasticity = .none
            next.horizontalScrollElasticity = .none
            next.contentView.postsBoundsChangedNotifications = true
            next.contentView.postsFrameChangedNotifications = true
            document.postsFrameChangedNotifications = true
            for (name, object) in [(NSView.boundsDidChangeNotification, next.contentView),
                                    (NSView.frameDidChangeNotification, next.contentView),
                                    (NSView.frameDidChangeNotification, document)] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.measure() }
                })
            }
            viewport.pin = { [weak self] in self?.pin() }
            viewport.move = { [weak self] delta in self?.move(delta) }
            measure()
        }
        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver); observers = []
            viewport.pin = nil; viewport.move = nil; scroll = nil
        }
        private func offset(_ scroll: NSScrollView, _ document: NSView) -> CGFloat {
            document.isFlipped ? scroll.contentView.bounds.minY - document.bounds.minY
                : document.bounds.maxY - scroll.contentView.bounds.maxY
        }
        func measure() {
            guard !adjusting, let scroll, let document = scroll.documentView else { return }
            if viewport.measure(offset: offset(scroll, document), viewport: scroll.contentView.bounds.height, content: document.bounds.height) { pin() }
        }
        private func pin() { moveToEndOrOffset(nil) }
        private func move(_ delta: CGFloat) {
            guard let scroll, let document = scroll.documentView else { return }
            moveToEndOrOffset(offset(scroll, document) + delta)
        }
        private func moveToEndOrOffset(_ requested: CGFloat?) {
            guard !adjusting, let scroll, let document = scroll.documentView else { return }
            let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
            let distance = min(maximum, max(0, requested ?? maximum))
            let y = document.isFlipped ? document.bounds.minY + distance : document.bounds.maxY - scroll.contentView.bounds.height - distance
            adjusting = true
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            _ = viewport.measure(offset: offset(scroll, document), viewport: scroll.contentView.bounds.height, content: document.bounds.height)
            adjusting = false
        }
        isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

extension NativeHootChatModel {
    func followTool(_ action: String) throws -> NativeRPCValue {
        guard ["read", "latest", "earlier", "later"].contains(action) else { throw NativeRPCError.invalidArguments("Choose read, latest, earlier or later.") }
        for viewport in chatViewports.values {
            if action == "latest" { viewport.latest() }
            if action == "earlier" { viewport.page(-1) }
            if action == "later" { viewport.page(1) }
        }
        return .object([.init("behavior", .string("Follow newest; pause while reading; send or scroll to the end to resume.")),
                        .init("views", .array(chatViewports.values.map(\.receipt)))])
    }
}
