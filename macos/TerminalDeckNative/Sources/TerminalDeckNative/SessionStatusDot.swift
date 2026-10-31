import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// A session's status dot, the same everywhere a session is listed (side panel Running and Pinned).
/// Asad, 11 Oct: "when any session is working that grey dot is not blinking slowly so we get to know there is
/// something happening". While the session works (busy, thinking: StatusMeaning.working) the dot fades in and out
/// slowly, a 1.8 s cycle. The fade is one Core Animation on the dot's own layer, run by the window server: nothing
/// in the app redraws on a timer. With Reduce Motion it stays still, in the accent colour, so working still reads
/// apart from ready (grey). Ready, idle, done and stopped are steady.
struct SessionStatusDot: View {
    let status: String?
    /// On a blue selected row: white.
    var onAccent = false
    var size: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func colour(_ meaning: StatusMeaning, onAccent: Bool) -> NSColor {
        if onAccent { return .white }
        switch meaning {
        case .working: return .controlAccentColor
        case .needsInput: return .systemOrange
        case .failed: return .systemRed
        case .ready, .completed, .exited: return NSColor.secondaryLabelColor.withAlphaComponent(0.7)
        }
    }
    /// Pulses only while working, and never with Reduce Motion.
    static func pulses(_ meaning: StatusMeaning, reduceMotion: Bool) -> Bool { meaning == .working && !reduceMotion }

    var body: some View {
        let meaning = StatusMeaning(status)
        SessionStatusDotLayer(colour: Self.colour(meaning, onAccent: onAccent), pulsing: Self.pulses(meaning, reduceMotion: reduceMotion))
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel(meaning.label)
    }
}

/// The dot itself: drawn once; the pulse is a repeating opacity animation on its layer.
struct SessionStatusDotLayer: NSViewRepresentable {
    let colour: NSColor
    let pulsing: Bool
    func makeNSView(context: Context) -> DotView { DotView() }
    func updateNSView(_ view: DotView, context: Context) { view.set(colour: colour, pulsing: pulsing) }

    final class DotView: NSView {
        static let pulseKey = "session-dot-pulse"
        private var colour: NSColor = .secondaryLabelColor
        private(set) var pulsing = false
        override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
        required init?(coder: NSCoder) { super.init(coder: coder); wantsLayer = true }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // the row underneath keeps every click

        func set(colour: NSColor, pulsing: Bool) {
            if colour != self.colour { self.colour = colour; needsDisplay = true }
            guard pulsing != self.pulsing else { return }
            self.pulsing = pulsing
            applyPulse()
        }
        override func draw(_ dirtyRect: NSRect) {
            colour.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 0.25, dy: 0.25)).fill()
        }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
        // A layer loses its animations when the view leaves the window; put the pulse back when it returns.
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyPulse() }

        private func applyPulse() {
            guard let layer else { return }
            layer.removeAnimation(forKey: Self.pulseKey)
            layer.opacity = 1
            guard pulsing, window != nil else { return }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1; fade.toValue = 0.3
            fade.duration = 0.9                     // there and back: a 1.8 s cycle
            fade.autoreverses = true
            fade.repeatCount = .infinity
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fade.isRemovedOnCompletion = false
            layer.add(fade, forKey: Self.pulseKey)
        }
        var isAnimatingPulse: Bool { layer?.animation(forKey: Self.pulseKey) != nil }
    }
}
