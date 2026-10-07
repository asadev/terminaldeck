import AppKit
import SwiftUI
import TerminalDeckNativeCore

// What a tour draws: the dim with the box cut out (FocusOverlay.tsx), the scan
// field around it (ScanField.tsx), and the drive panel over the side panel
// (DrivePanel.tsx with its composer) — in two windows attached to the main one.

/// The two overlay windows: the drawing (takes no clicks) and the panel.
@MainActor
final class DriveOverlay {
    private var drawing: NSPanel?
    private(set) var panelWindow: NSPanel?
    private weak var main: NSWindow?
    private var frameObserver: [NSObjectProtocol] = []
    /// The rail's width the panel covers (`--rail-width`).
    static let panelWidth: CGFloat = 264

    /// The main window's content area, in its own top-left coordinates.
    var viewport: DriveRect {
        guard let content = main?.contentView else { return DriveRect(x: 0, y: 0, width: 0, height: 0) }
        return DriveRect(x: 0, y: 0, width: content.bounds.width, height: content.bounds.height)
    }

    static func mainWindow() -> NSWindow? {
        NSApplication.shared.windows.first { ($0.identifier?.rawValue ?? "").hasPrefix("main") && $0.isVisible }
    }

    /// With `panel: false` only the box is drawn (TourRecap's "Take me there").
    func show(host: DriveHost, panel withPanel: Bool = true) {
        guard let main = Self.mainWindow() else { return }
        self.main = main
        if drawing == nil {
            let draw = Self.panel(clicks: false)
            draw.contentView = NSHostingView(rootView: DriveDrawing(host: host))
            drawing = draw
            let panel = Self.panel(clicks: true)
            panel.contentView = NSHostingView(rootView: DrivePanelView(host: host))
            panelWindow = panel
        }
        place()
        if let drawing, drawing.parent == nil { main.addChildWindow(drawing, ordered: .above) }
        if withPanel {
            if let panelWindow, panelWindow.parent == nil { main.addChildWindow(panelWindow, ordered: .above) }
            if NSApp.isActive { panelWindow?.orderFront(nil) } // front-ok: only while the app is already in front
        } else if let panelWindow {
            panelWindow.parent?.removeChildWindow(panelWindow)
            panelWindow.orderOut(nil)
        }
        if NSApp.isActive { drawing?.orderFront(nil) } // front-ok: only while the app is already in front
        frameObserver.forEach { NotificationCenter.default.removeObserver($0) }
        frameObserver = [NSWindow.didResizeNotification, NSWindow.didMoveNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: main, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            }
        }
    }

    func hide() {
        frameObserver.forEach { NotificationCenter.default.removeObserver($0) }
        frameObserver = []
        for window in [drawing, panelWindow].compactMap({ $0 }) {
            window.parent?.removeChildWindow(window)
            window.orderOut(nil)
        }
    }

    /// Over the main window's content; the panel over the side panel, below the toolbar.
    private func place() {
        guard let main, let content = main.contentView else { return }
        let frame = main.convertToScreen(content.convert(content.bounds, to: nil))
        drawing?.setFrame(frame, display: true)
        let top = main.contentLayoutRect.maxY
        let panelFrame = NSRect(x: frame.minX, y: frame.minY, width: Self.panelWidth, height: max(0, top))
        panelWindow?.setFrame(panelFrame, display: true)
    }

    private static func panel(clicks: Bool) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: clicks ? [.borderless, .nonactivatingPanel] : [.borderless],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = !clicks
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        return panel
    }
}

// MARK: - The dim, the box and the scan field

private struct DriveDrawing: View {
    let host: DriveHost

    var body: some View {
        ZStack(alignment: .topLeading) {
            if host.playing { ScanFieldView(host: host) }
            if case .drawn(let rect, let edges, let radius)? = host.resolution {
                FocusBox(rect: rect, edges: edges, radius: radius, lit: host.lit)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// `FocusOverlay`: everything dimmed but the box, and a ring around it (open on a cut side).
private struct FocusBox: View {
    let rect: DriveRect
    let edges: DriveEdges
    let radius: Double
    let lit: Bool

    var body: some View {
        let hole = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        let (tl, tr, br, bl) = DriveGeometry.corners(edges, radius: radius)
        let shape = UnevenRoundedRectangle(cornerRadii: .init(topLeading: tl, bottomLeading: bl, bottomTrailing: br, topTrailing: tr))
        Canvas { context, size in
            var dim = Path(CGRect(origin: .zero, size: size))
            dim.addPath(shape.path(in: hole))
            context.fill(dim, with: .color(.black.opacity(0.26)), style: FillStyle(eoFill: true))
        }
        .opacity(lit ? 1 : 0)
        .animation(.easeOut(duration: 0.18), value: lit)
        shape
            .stroke(Color.accentColor, lineWidth: 1)
            .shadow(color: Color.accentColor.opacity(0.3), radius: 3)
            .frame(width: hole.width + 2, height: hole.height + 2)
            .offset(x: hole.minX - 1, y: hole.minY - 1)
            .opacity(lit ? 1 : 0.55)
            .animation(.easeOut(duration: 0.18), value: hole)
    }
}

/// `ScanField`: drifting dots and their links around the box, lit in proportion to
/// the stops seen, drawn inward toward the box at each arrival.
private struct ScanFieldView: View {
    let host: DriveHost
    @State private var dots: [Dot] = []
    @State private var lastPulse = 0
    @State private var pulseAt = Date.distantPast
    @Environment(\.accessibilityReduceMotion) private var reduced

    struct Dot { var x, y, vx, vy, rank, radius: Double }

    static let areaPerDot = 14_000.0, minDots = 60, maxDots = 250, linkDist = 130.0, pulseMs = 220.0

    var body: some View {
        TimelineView(.animation(paused: reduced)) { timeline in
            Canvas { context, size in
                draw(context, size: size, at: timeline.date)
            }
        }
    }

    private func draw(_ context: GraphicsContext, size: CGSize, at date: Date) {
        guard let view = host.view else { return }
        var field = dots
        let want = min(Self.maxDots, max(Self.minDots, Int((size.width * size.height / Self.areaPerDot).rounded())))
        while field.count < want {
            field.append(Dot(x: .random(in: 0...max(1, size.width)), y: .random(in: 0...max(1, size.height)),
                             vx: .random(in: -0.055...0.055), vy: .random(in: -0.055...0.055),
                             rank: .random(in: 0...1), radius: 1.1 + .random(in: 0...1.3)))
        }
        if field.count > want { field.removeLast(field.count - want) }
        let arrivals = view.scan.arrivals
        var pulseStart = pulseAt
        if arrivals != lastPulse { pulseStart = date }
        let surge = reduced ? 0 : pow(max(0, 1 - date.timeIntervalSince(pulseStart) * 1000 / Self.pulseMs), 2)
        let hole = host.resolution?.rect
        let centre = hole.map { CGPoint(x: $0.x + $0.width / 2, y: $0.y + $0.height / 2) }
        if !reduced {
            for i in field.indices {
                field[i].x += field[i].vx * 16
                field[i].y += field[i].vy * 16
                if surge > 0, let c = centre {
                    let dx = c.x - field[i].x, dy = c.y - field[i].y
                    let pull = surge * 16 * 0.06 / max(24, (dx * dx + dy * dy).squareRoot())
                    field[i].x += dx * pull
                    field[i].y += dy * pull
                }
                if field[i].x < -20 { field[i].x = size.width + 20 }
                if field[i].x > size.width + 20 { field[i].x = -20 }
                if field[i].y < -20 { field[i].y = size.height + 20 }
                if field[i].y > size.height + 20 { field[i].y = -20 }
            }
        }
        var ctx = context
        if let hole {
            var clip = Path(CGRect(origin: .zero, size: size))
            clip.addRect(CGRect(x: hole.x - 10, y: hole.y - 10, width: hole.width + 20, height: hole.height + 20))
            ctx.clip(to: clip, style: FillStyle(eoFill: true))
        }
        let lit = view.scan.count == 0 ? 0 : min(1, Double(view.scan.seen.count) / Double(view.scan.count))
        for a in field.indices {
            for b in (a + 1)..<field.count where b < field.count {
                let dx = field[a].x - field[b].x, dy = field[a].y - field[b].y
                let distance = (dx * dx + dy * dy).squareRoot()
                if distance > Self.linkDist { continue }
                let alpha = (1 - distance / Self.linkDist) * (0.17 + surge * 0.28)
                if alpha < 0.02 { continue }
                let colour: Color = field[a].rank < lit && field[b].rank < lit ? .accentColor : .gray
                var line = Path()
                line.move(to: CGPoint(x: field[a].x, y: field[a].y))
                line.addLine(to: CGPoint(x: field[b].x, y: field[b].y))
                ctx.stroke(line, with: .color(colour.opacity(alpha)), lineWidth: 1)
            }
        }
        for dot in field {
            let isLit = dot.rank < lit
            let r = dot.radius + surge * 0.7
            ctx.fill(Path(ellipseIn: CGRect(x: dot.x - r, y: dot.y - r, width: r * 2, height: r * 2)),
                     with: .color((isLit ? Color.accentColor : .gray).opacity(min(1, (isLit ? 0.66 : 0.4) + surge * 0.34))))
        }
        DispatchQueue.main.async {
            dots = field
            if arrivals != lastPulse {
                lastPulse = arrivals
                pulseAt = pulseStart
            }
        }
    }
}

// MARK: - The drive panel

private struct DrivePanelView: View {
    let host: DriveHost

    var body: some View {
        if let view = host.view, !host.copilotFront {
            DrivePanelBody(host: host, view: view)
        } else {
            Color.clear
        }
    }
}

private struct DrivePanelBody: View {
    let host: DriveHost
    let view: TourView
    @State private var text = ""

    var body: some View {
        let scan = view.scan
        let dropped = DriveTour.droppedSentence(view.record.dropped)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HootMark(size: 24)
                    Text("Hoot").font(.callout.weight(.semibold))
                    Spacer()
                    Button(action: host.fold) {
                        Circle().fill(Color.accentColor).frame(width: 8, height: 8).padding(6)
                    }
                    .buttonStyle(.plain)
                    .help("Open Hoot’s own window")
                    .accessibilityLabel("Open Hoot’s own window")
                }
                Text(view.record.question).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)

            ProgressView(value: Scan.progress(scan)).progressViewStyle(.linear).tint(.accentColor).padding(.horizontal, 14)

            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(view.stops.enumerated()), id: \.offset) { index, stop in
                            StopRow(view: view, index: index, stop: stop) { host.jump(index) }.id(index)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: scan.index) { _, index in withAnimation { reader.scrollTo(index) } }
            }

            if !dropped.isEmpty || !view.droppedHere.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if !dropped.isEmpty { Text(dropped) }
                    if let first = view.droppedHere.first {
                        Text("\(view.droppedHere.count) more went while it was held — \(DriveTour.degradeSentence(first.why))")
                    }
                }
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 8)
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(Scan.statusSentence(scan)).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Button { host.command(.back) } label: { Text("←") }.help("Back one").accessibilityLabel("Back one")
                    Button { host.command(.toggle) } label: { Text(scan.status == .paused ? "▶" : "❙❙") }
                        .help(scan.status == .paused ? "Carry on" : "Hold")
                        .accessibilityLabel(scan.status == .paused ? "Carry on" : "Hold")
                    Button { host.command(.next) } label: { Text("→") }.help("Forward one").accessibilityLabel("Forward one")
                    Spacer()
                    Button(Scan.isScanning(scan) ? "Stop" : "Close") { host.command(.stop) }
                }
                Button("Don’t show me next time", action: host.quiet).buttonStyle(.link).font(.caption)
            }
            .padding(14)

            if host.canSay {
                HStack(spacing: 6) {
                    TextField("Ask while it works…", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Say something to Hoot")
                        .onSubmit(send)
                    Button(action: send) { Image(systemName: "arrow.up") }.accessibilityLabel("Send")
                }
                .padding([.horizontal, .bottom], 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hoot")
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        host.say(trimmed)
        text = ""
    }
}

private struct StopRow: View {
    let view: TourView
    let index: Int
    let stop: TourStop
    let jump: () -> Void

    var body: some View {
        let current = index == view.scan.index
        let seen = view.scan.seen.contains(index)
        Button(action: jump) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(view.sessionTitle(at: index)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(DriveTour.reasonLabel(stop.why)).font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15), in: .capsule)
                }
                Text(stop.note).font(.callout).multilineTextAlignment(.leading)
                if current, !stop.quote.isEmpty {
                    Text(stop.quote).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(4)
                }
                if current, let degraded = view.degraded, degraded.index == index {
                    Text(DriveTour.degradeSentence(degraded.why)).font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(current ? Color.accentColor.opacity(0.14) : .clear, in: .rect(cornerRadius: 8))
            .opacity(!current && seen ? 0.7 : 1)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
