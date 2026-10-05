import SwiftUI
import WebKit
import TerminalDeckNativeCore

/// The island: one black shape hanging from the top of the screen, a pill at rest
/// and the panel when grown — one outline that morphs, never two pieces.
///
/// Everything is drawn top-centre on a fixed canvas the size of the grown window,
/// so the window can change size (it does, at the start of a grow and the end of a
/// settle) without the shape moving a point.
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
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
        let w = max(0, width)
        let h = max(0, height)
        let r = max(0, min(radius, h, w / 2))
        let s = max(0, min(shoulder, h - r))
        let left = rect.midX - w / 2
        let right = rect.midX + w / 2
        let top = rect.minY
        let bottom = top + h
        // A quarter circle as a cubic.
        let k: CGFloat = 0.5523

        var path = Path()
        path.move(to: CGPoint(x: left - s, y: top))
        path.addCurve(to: CGPoint(x: left, y: top + s),
                      control1: CGPoint(x: left - s + s * k, y: top),
                      control2: CGPoint(x: left, y: top + s - s * k))
        path.addLine(to: CGPoint(x: left, y: bottom - r))
        path.addCurve(to: CGPoint(x: left + r, y: bottom),
                      control1: CGPoint(x: left, y: bottom - r + r * k),
                      control2: CGPoint(x: left + r - r * k, y: bottom))
        path.addLine(to: CGPoint(x: right - r, y: bottom))
        path.addCurve(to: CGPoint(x: right, y: bottom - r),
                      control1: CGPoint(x: right - r + r * k, y: bottom),
                      control2: CGPoint(x: right, y: bottom - r + r * k))
        path.addLine(to: CGPoint(x: right, y: top + s))
        path.addCurve(to: CGPoint(x: right + s, y: top),
                      control1: CGPoint(x: right, y: top + s - s * k),
                      control2: CGPoint(x: right + s - s * k, y: top))
        path.closeSubpath()
        return path
    }
}

/// The island page's web view, placed by SwiftUI. The controller owns it.
private struct IslandWebContent: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
