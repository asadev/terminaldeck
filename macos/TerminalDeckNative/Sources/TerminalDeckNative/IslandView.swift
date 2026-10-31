import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// The island: one solid shape hanging from the top of the screen, a pill at rest
/// and the panel when grown — one outline that morphs, never two pieces.
///
/// Everything is drawn top-centre on a fixed canvas the size of the grown window,
/// so the window can change size (it does, at the start of a grow and the end of a
/// settle) without the shape moving a point. The canvas is exactly this view's size:
/// `IslandContainerView` sizes and places the hosting view (`canvasFrame`), so no
/// SwiftUI alignment rule decides where the pill lands.
@MainActor
struct IslandView: View {
    let model: IslandViewModel
    /// Alternate content lets isolated previews use the real shell without
    /// starting account, session or transcript readers.
    var suppliedContent: AnyView?
    var owlBoundsChanged: (@MainActor @Sendable (CGRect) -> Void)?
    @State private var resizeBase: CGSize?
    @State private var pendingSize: CGSize?

    private var paintedLayout: IslandLayout {
        var layout = model.layout
        if model.expanded, let pendingSize {
            layout.panel.width = pendingSize.width; layout.panel.height = pendingSize.height
            layout.contentSize = CGSize(width: max(1, pendingSize.width - 2 * IslandMetrics.contentInset),
                height: max(1, pendingSize.height - layout.contentTop - IslandMetrics.contentInset))
        }
        return layout
    }

    var body: some View {
        let layout = paintedLayout
        let expanded = model.expanded
        let shape = expanded ? layout.panel : layout.pill
        let canvas = layout.expandedFrame.size

        ZStack(alignment: .top) {
            IslandOutline(width: shape.width, height: shape.height, radius: shape.radius, shoulder: shape.shoulder)
                .fill(model.usesBlack ? Color.black : Color.white)
                .shadow(color: .black.opacity(expanded ? 0.4 : 0), radius: 14, x: 0, y: 8)

            // Open, the panel is only Hoot's chat (Asad, 10 Oct: "remove this all quiet too when opened").
            if !(expanded && NativeCompositionHootUI.shared.isBound) {
                IslandIndicators(state: model.state, layout: layout, quiet: model.quiet)
            }

            // Hoot's chat runs to the panel's top edge (Asad, 10 Oct): the scroll area starts under the
            // pill row and its first line sits just below it, so text scrolls all the way up.
            let fullHeight = NativeCompositionHootUI.shared.isBound && suppliedContent == nil && NativeIslandContent.isNative
            let top = fullHeight ? IslandMetrics.contentInset : layout.contentTop
            Group {
                if let suppliedContent { suppliedContent }
                else if NativeIslandContent.isNative {
                    NativeIslandContent(expanded: expanded, chatTopInset: fullHeight && layout.notched ? max(0, layout.contentTop - top) : 0)
                }
            }
                .frame(width: layout.contentSize.width,
                       height: layout.contentSize.height + (fullHeight ? layout.contentTop - top : 0))
                .clipShape(RoundedRectangle(cornerRadius: layout.panel.radius - IslandMetrics.contentInset,
                                            style: .continuous))
                .padding(.top, top)
                // In once the shape is most of the way there; out first when settling.
                .opacity(expanded && model.pageLoaded ? 1 : 0)
                .animation(expanded ? .easeOut(duration: 0.14).delay(0.12) : .easeIn(duration: 0.07), value: expanded)
                .allowsHitTesting(expanded)
            if NativeCompositionHootUI.shared.isBound && expanded {
                // No icons (Asad, 10 Oct): drag any side or bottom corner. Invisible 8 pt grips
                // under the edges; the bottom edge changes height only, the sides both ways.
                ZStack {
                    HStack(spacing: 0) {
                        resizeGrip(left: true, horizontal: true, vertical: true).frame(width: 8)
                        Spacer(minLength: 0)
                        resizeGrip(left: false, horizontal: true, vertical: true).frame(width: 8)
                    }
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        resizeGrip(left: false, horizontal: false, vertical: true).frame(height: 8).padding(.horizontal, 8)
                    }
                }
                .frame(width: shape.width, height: max(0, shape.height - layout.contentTop))
                .padding(.top, layout.contentTop)
                .frame(width: shape.width, height: shape.height, alignment: .top)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .top)
        .coordinateSpace(name: "FIXES-island-canvas")
        .onPreferenceChange(NativeFIXESIslandOwlFrameKey.self) { bounds in
            Task { @MainActor in owlBoundsChanged?(bounds) }
        }
        .transaction { if resizeBase != nil { $0.disablesAnimations = true; $0.animation = nil } }
        .opacity(model.hiddenWhileQuiet ? 0 : 1)
        .allowsHitTesting(!model.hiddenWhileQuiet)
        .environment(\.colorScheme, model.darkAppearance ? .dark : .light)
        .onChange(of: model.layout.panel) { _, _ in
            if resizeBase == nil { pendingSize = nil }
        }
        .onChange(of: expanded) { _, grown in
            if !grown { resizeBase = nil; pendingSize = nil }
        }
    }

    private func resizeGrip(left: Bool, horizontal: Bool, vertical: Bool) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .nativeHoverCursor(horizontal ? .resizeLeftRight : .resizeUpDown)
            .accessibilityLabel("Resize Hoot panel")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                NativeCompositionHootUI.shared.resizePanel(CGSize(width: model.layout.panel.width + 32,
                    height: model.layout.panel.height + 32))
            }
            // Measured in the fixed canvas, not the grip itself: the grip moves as the shape grows,
            // and measuring in its own space fed that motion back into the size (the flicker at the edges).
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("FIXES-island-canvas"))
                .onChanged { drag in
                    if resizeBase == nil { resizeBase = CGSize(width: model.layout.panel.width, height: model.layout.panel.height) }
                    guard let base = resizeBase else { return }
                    var still = Transaction(); still.disablesAnimations = true
                    withTransaction(still) {
                        pendingSize = NativeCompositionHootUI.shared.clampPanelSize(CGSize(
                            width: horizontal ? base.width + drag.translation.width * (left ? -2 : 2) : base.width,
                            height: vertical ? base.height + drag.translation.height : base.height))
                    }
                }
                .onEnded { _ in
                    if let pendingSize { NativeCompositionHootUI.shared.resizePanel(pendingSize) }
                    resizeBase = nil
                })
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
struct IslandIndicators: View {
    let state: IslandState?
    let layout: IslandLayout
    var quiet = false

    var body: some View {
        Group {
            if layout.notched {
                HStack(spacing: 0) {
                    // The owl in the left ear, the thinking/attention dots beside it; the badge keeps the right ear.
                    HStack(spacing: 3) { owl; status }.frame(width: layout.ear)
                    Color.clear.frame(width: layout.gap)
                    Group {
                        if quiet { Text("All quiet").font(.caption).foregroundStyle(.secondary) }
                        else { badge }
                    }.frame(width: layout.ear)
                }
            } else {
                HStack(spacing: 5) {
                    owl
                    Text(quiet ? "All quiet" : state?.line ?? "Hoot")
                        .font(.callout.weight(.medium)).lineLimit(1).truncationMode(.tail)
                    if state != nil { status }
                    if let state, state.badge > 0 { badge }
                }
            }
        }
        .frame(width: layout.pill.width, height: layout.row)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Terminal Deck")
        .accessibilityValue(state?.line ?? "")
        .help(state?.line ?? "")
    }

    /// Keep Hoot visible while stopped, starting, or waiting for its first snapshot.
    private var owl: some View {
        HootMark(size: max(10, layout.pill.height - 8))
            .background(GeometryReader { geometry in
                Color.clear.preference(key: NativeFIXESIslandOwlFrameKey.self,
                    value: geometry.frame(in: .named("FIXES-island-canvas")))
            })
            .accessibilityHidden(true)
    }

    @ViewBuilder private var status: some View {
        switch state?.status {
        // Quiet shows nothing: a lone dot reads as the camera (Asad, 2026-10-07).
        case nil, .idle:
            Color.clear.frame(width: 1, height: 1)
        case .working:
            HootStatusLine(state: .thinking, text: "")
        case .needsYou:
            Circle().fill(Color.orange).frame(width: 7, height: 7)
        case .offline:
            Circle().strokeBorder(Color.secondary, lineWidth: 1.2).frame(width: 7, height: 7)
        }
    }

    @ViewBuilder private var badge: some View {
        if let state, state.badge > 0 {
            Text(layout.notched ? (state.badge > 99 ? "99+ waiting" : "\(state.badge) waiting") : (state.badge > 99 ? "99+" : "\(state.badge)"))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, 5)
                .frame(minWidth: 16, minHeight: 16)
                .background(Capsule().fill(state.status == .needsYou ? Color.orange : Color.secondary.opacity(0.2)))
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
