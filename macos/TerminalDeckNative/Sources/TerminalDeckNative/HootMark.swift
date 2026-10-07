import AppKit
import SwiftUI
import TerminalDeckNativeCore

// Hoot's owl for the native app — the sidebar row, Hoot tabs, Hoot's own window,
// and anything else (the island) that shows Hoot. Real brand colours in light and
// dark; vector, so it redraws crisply at every size and screen scale.
//
//   SwiftUI:  HootMark(size: 16)
//   AppKit:   NSImage.hootMark(size: 16)

extension NSImage {
    /// The owl as a resolution-independent image (redrawn for each backing scale).
    /// Not a template: it keeps its own colours on any background.
    static func hootMark(size: CGFloat = 16) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            HootArt.draw(in: context, rect: rect)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Hoot"
        return image
    }
}

/// The owl as a SwiftUI view. Decorative by default (Hoot's name is usually beside it).
struct HootMark: View {
    var size: CGFloat = 16
    /// False keeps the eyes open and still, like the web mark's `animated={false}`.
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lid: CGFloat = 0

    var body: some View {
        Canvas { context, canvasSize in
            context.withCGContext { cg in
                // Canvas is y-down; HootArt expects a y-up context.
                cg.translateBy(x: 0, y: canvasSize.height)
                cg.scaleBy(x: 1, y: -1)
                HootArt.draw(in: cg, rect: CGRect(origin: .zero, size: canvasSize))
            }
        }
        .overlay(alignment: .topLeading) { if blinks { lids } }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: blinks) { if blinks { await blinkNowAndThen() } }
    }

    private var blinks: Bool { animated && !reduceMotion }

    /// The lids, in the body's orange, closing from their top edge (the web mark's `hoot-lid`).
    private var lids: some View {
        let scale = size / HootArt.viewBox.width
        let c = HootArt.Colour.body
        return ZStack(alignment: .topLeading) {
            ForEach(HootArt.lids.indices, id: \.self) { i in
                let eye = HootArt.lids[i]
                Circle()
                    .fill(Color(.sRGB, red: c.red, green: c.green, blue: c.blue))
                    .frame(width: eye.r * 2 * scale, height: eye.r * 2 * scale)
                    .scaleEffect(x: 1, y: lid, anchor: .top)
                    .offset(x: (eye.cx - eye.r) * scale, y: (eye.cy - eye.r) * scale)
            }
        }
        .allowsHitTesting(false)
    }

    /// The web mark's rhythm: a quick blink every 7–9.5 s, now and then a softer second one,
    /// each owl starting at its own moment so a screen of owls never blinks in lock-step.
    private func blinkNowAndThen() async {
        try? await Task.sleep(for: .seconds(Double.random(in: 0...5)))
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 7...9.5)))
            guard !Task.isCancelled else { return }
            await blinkOnce()
            if Bool.random() {
                try? await Task.sleep(for: .milliseconds(150))
                await blinkOnce()
            }
        }
    }

    private func blinkOnce() async {
        withAnimation(.easeIn(duration: 0.07)) { lid = 1 }
        try? await Task.sleep(for: .milliseconds(110))
        withAnimation(.easeOut(duration: 0.1)) { lid = 0 }
        try? await Task.sleep(for: .milliseconds(100))
    }
}
