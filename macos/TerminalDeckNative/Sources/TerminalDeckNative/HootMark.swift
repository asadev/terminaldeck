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

    var body: some View {
        Canvas { context, canvasSize in
            context.withCGContext { cg in
                // Canvas is y-down; HootArt expects a y-up context.
                cg.translateBy(x: 0, y: canvasSize.height)
                cg.scaleBy(x: 1, y: -1)
                HootArt.draw(in: cg, rect: CGRect(origin: .zero, size: canvasSize))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
