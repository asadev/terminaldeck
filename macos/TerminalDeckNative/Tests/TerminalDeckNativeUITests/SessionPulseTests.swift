import AppKit
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// SESSION-PULSE (Asad, 11 Oct): a working session's dot fades in and out slowly; ready, idle and stopped stay still.
@Suite("Session dot pulse", .serialized)
@MainActor
struct SessionPulseTests {
    @Test func onlyAWorkingSessionPulsesAndNeverWithReduceMotion() {
        for word in ["working", "busy", "thinking", "running"] {
            #expect(SessionStatusDot.pulses(StatusMeaning(word), reduceMotion: false), "\(word) pulses")
            #expect(!SessionStatusDot.pulses(StatusMeaning(word), reduceMotion: true), "\(word) is still with Reduce Motion")
        }
        for word in ["idle", "waiting", nil, "exited", "completed", "failed", "input"] as [String?] {
            #expect(!SessionStatusDot.pulses(StatusMeaning(word), reduceMotion: false), "\(word ?? "nil") is steady")
        }
        // With Reduce Motion, working still reads apart from ready by its colour.
        #expect(SessionStatusDot.colour(.working, onAccent: false) != SessionStatusDot.colour(.ready, onAccent: false))
        #expect(SessionStatusDot.colour(.working, onAccent: true) == .white)
    }

    @Test func thePulseIsOneLayerAnimationThatStopsWhenTheSessionStops() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless], backing: .buffered, defer: true)
        let dot = SessionStatusDotLayer.DotView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
        window.contentView?.addSubview(dot)
        dot.set(colour: .controlAccentColor, pulsing: true)
        #expect(dot.isAnimatingPulse)
        #expect(dot.layer?.animationKeys()?.count == 1)
        dot.set(colour: .controlAccentColor, pulsing: true)            // the same state again adds nothing
        #expect(dot.layer?.animationKeys()?.count == 1)
        dot.set(colour: .secondaryLabelColor, pulsing: false)
        #expect(!dot.isAnimatingPulse)
        #expect(dot.hitTest(NSPoint(x: 4, y: 4)) == nil)              // clicks go to the row
    }
}
