/**
 * Watching the machine's browser from a phone — the surface list, and the frame
 * routing behind the live view.
 *
 * The client half of `watch`, reached over the capability the host advertises
 * only to one of the owner's own devices (watching a signed-in browser is an
 * owner act). This holds the shared part — the tab strip, the capability, and
 * the frames as they arrive — and `WatchView` holds the per-surface part: the
 * paint/ack loop and the gestures, because the ack has to fire from the draw
 * callback and a gesture is measured against the frame currently on screen.
 *
 * ## One surface at a time, on purpose
 *
 * The PWA mounts a canvas per watched window because a browser tab can hold
 * several at once. A phone screen is one surface: opening a tab from the strip
 * casts it full-screen, and closing the viewer stops the cast. So a single frame
 * sink is enough, and `frameHandler` is it — set by the viewer on appear,
 * cleared on disappear. A frame for a window nothing is showing is dropped, not
 * buffered: a live frame is stale before anything could catch up on it.
 */

import Foundation

@MainActor
@Observable
final class WatchLink {
    /// The watchable surfaces — the browser's tab strip — or empty until asked.
    private(set) var surfaces: [BrowserSurfaceRow] = []
    /// The window currently being cast to the viewer, or nil when none is open.
    private(set) var watching: String?

    private var capabilities: Set<String> = []
    private var requested = false
    private let wire: CopilotWire
    private var counter = 0

    /// The viewer's frame sink. Set on appear, cleared on disappear. Not
    /// observed — the viewer needs the frame in a callback it can ack from, not a
    /// property change it re-renders on.
    var frameHandler: ((BrowserFrame) -> Void)?

    init(wire: CopilotWire) {
        self.wire = wire
    }

    var offered: Bool { capabilities.contains(WireCapability.watch) }

    /// A new welcome: forget the last machine's strip. The surfaces belong to
    /// whichever machine this connection reaches, and a guest is not told the
    /// capability exists.
    func welcomed(capabilities: Set<String>) {
        self.capabilities = capabilities
        surfaces = []
        watching = nil
        requested = false
        frameHandler = nil
    }

    /// Ask for the tab strip once, when the screen opens. The pushed
    /// `browser.surfaces.rows` keeps it fresh after that.
    func ensureRead() {
        guard offered, !requested else { return }
        ask()
    }

    private func ask() {
        guard offered else { return }
        let rid = nextRid()
        guard wire.send(.browserSurfaces(rid: rid)) else { return }
        requested = true
    }

    /// Start (or renegotiate) the cast of one surface to the viewer. `window` is
    /// `""` for the front tab or a slot name. Idempotent host-side — re-sending
    /// it is how a resize renegotiates. Returns whether the frame left.
    @discardableResult
    func watch(window: String, maxWidth: Int, quality: Int) -> Bool {
        guard offered else { return false }
        watching = window
        return wire.send(.browserWatch(window: window, maxWidth: maxWidth, quality: quality))
    }

    /// Stop the cast of the window being shown. Called when the viewer closes.
    func unwatch(window: String) {
        _ = wire.send(.browserUnwatch(window: window))
        if watching == window { watching = nil }
    }

    /// Rendered — send the next frame. The one-in-flight backpressure.
    func ack(window: String, seq: Int) {
        _ = wire.send(.browserFrameAck(window: window, seq: seq))
    }

    /// A gesture aimed at the frame named by `seq`.
    func input(window: String, seq: Int, input: BrowserInput) {
        _ = wire.send(.browserInput(window: window, seq: seq, input: input))
    }

    @discardableResult
    func receive(_ message: ServerMessage) -> Bool {
        switch message {
        case let .browserSurfaces(_, surfaces):
            // Answer or unsolicited push — the strip is the whole list either
            // way, so the rid is not matched (there is nothing to resolve).
            self.surfaces = surfaces
            return true
        case let .browserFrame(frame):
            // Routed to the open viewer, or dropped. A frame for a surface
            // nothing is showing is stale the instant it is not drawn.
            frameHandler?(frame)
            return true
        default:
            return false
        }
    }

    private func nextRid() -> String {
        counter += 1
        return "wch-\(counter)-\(UUID().uuidString.prefix(6))"
    }
}
