import AppKit
import SwiftUI
import WebKit
import TerminalDeckNativeCore

/// The island: one black shape hanging from the top of the screen, a pill at rest
/// and the panel when grown — one outline that morphs, never two pieces.
///
/// Everything is drawn top-centre on a fixed canvas the size of the grown window,
/// so the window can change size (it does, at the start of a grow and the end of a
/// settle) without the shape moving a point. The canvas is exactly this view's size:
/// `IslandContainerView` sizes and places the hosting view (`canvasFrame`), so no
/// SwiftUI alignment rule decides where the pill lands.
struct IslandView: View {
    let model: IslandViewModel
    let webView: WKWebView

    var body: some View {
        let layout = model.layout
        let expanded = model.expanded
        let shape = expanded ? layout.panel : layout.pill
        let canvas = layout.expandedFrame.size

        ZStack(alignment: .top) {
            IslandOutline(width: shape.width, height: shape.height, radius: shape.radius, shoulder: shape.shoulder)
                .fill(Color.black)
                .shadow(color: .black.opacity(expanded ? 0.4 : 0), radius: 14, x: 0, y: 8)

            IslandIndicators(state: model.state, layout: layout)

            IslandWebContent(webView: webView)
                .frame(width: layout.contentSize.width, height: layout.contentSize.height)
                .clipShape(RoundedRectangle(cornerRadius: IslandMetrics.panelRadius - IslandMetrics.contentInset,
                                            style: .continuous))
                .padding(.top, layout.contentTop)
                // In once the shape is most of the way there; out first when settling.
                .opacity(expanded && model.pageLoaded ? 1 : 0)
                .animation(expanded ? .easeOut(duration: 0.14).delay(0.12) : .easeIn(duration: 0.07), value: expanded)
                .allowsHitTesting(expanded)
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

/// The panel's content: hosts the SwiftUI island on its canvas — sized and placed
/// here, top-centre, whatever size the window is — and watches the pointer over the
/// shape itself (not the shadow around it), even while another app is in front.
@MainActor
final class IslandContainerView: NSView {
    /// The shape's box in this view's coordinates, for the current state.
    var trackingBox: (NSRect) -> NSRect = { $0 }
    /// Where the canvas goes in a view of this size (`IslandLayout.canvasFrame`).
    var canvasFrame: (NSSize) -> NSRect = { NSRect(origin: .zero, size: $0) }
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var area: NSTrackingArea?
    private var canvas: NSView?

    /// Hosts `content` on the canvas.
    func host(_ content: NSView) {
        canvas?.removeFromSuperview()
        content.autoresizingMask = []
        addSubview(content)
        canvas = content
        placeCanvas()
    }

    /// After a size change of this view or of the canvas (a display change).
    func placeCanvas() {
        canvas?.frame = canvasFrame(bounds.size)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        placeCanvas()
    }

    func refreshTracking() {
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: trackingBox(bounds), options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(next)
        area = next
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshTracking()
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

/// Beside a notch: the status in the left ear, the badge in the right one. Without
/// a notch: the two side by side, centred in the compact pill — no gap standing in
/// for a notch that is not there. They never move while the shape morphs.
private struct IslandIndicators: View {
    let state: IslandState?
    let layout: IslandLayout

    var body: some View {
        Group {
            if layout.notched {
                HStack(spacing: 0) {
                    status.frame(width: layout.ear)
                    Color.clear.frame(width: layout.gap)
                    badge.frame(width: layout.ear)
                }
            } else {
                HStack(spacing: 5) {
                    if state != nil { status }
                    if let state, state.badge > 0 { badge }
                }
            }
        }
        .frame(height: layout.row)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Terminal Deck")
        .accessibilityValue(state?.line ?? "")
        .help(state?.line ?? "")
    }

    @ViewBuilder private var status: some View {
        switch state?.status {
        case nil:
            Color.clear.frame(width: 1, height: 1)
        case .idle:
            Circle().fill(Color.white.opacity(0.4)).frame(width: 6, height: 6)
        case .working:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.mini)
        case .needsYou:
            Circle().fill(Color.orange).frame(width: 7, height: 7)
        case .offline:
            Circle().strokeBorder(Color.white.opacity(0.45), lineWidth: 1.2).frame(width: 7, height: 7)
        }
    }

    @ViewBuilder private var badge: some View {
        if let state, state.badge > 0 {
            Text(state.badge > 99 ? "99+" : "\(state.badge)")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 5)
                .frame(minWidth: 16, minHeight: 16)
                .background(Capsule().fill(state.status == .needsYou ? Color.orange : Color.white.opacity(0.2)))
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }
}

/// The island's outline, top-centre in its rect: a concave shoulder flaring out
/// into the menu bar at each top corner, straight sides, round bottom corners.
/// Every number animates, so the pill and the panel are one shape in motion.
struct IslandOutline: Shape {
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat
    var shoulder: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(width, height), AnimatablePair(radius, shoulder)) }
        set {
            width = newValue.first.first
            height = newValue.first.second
            radius = newValue.second.first
            shoulder = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let shape = IslandShapeSize(width: width, height: height, radius: radius, shoulder: shoulder)
        return Path(IslandGeometry.outline(shape, centreX: rect.midX, top: rect.minY))
    }
}

/// The island page's web view, placed by SwiftUI. The controller owns it.
private struct IslandWebContent: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
