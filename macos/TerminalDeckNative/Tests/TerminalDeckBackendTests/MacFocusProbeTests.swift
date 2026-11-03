import Foundation
import Testing
import TerminalDeckNativeCore

/// 1 Nov hotfix (install #18 crash, EXC_BREAKPOINT on the "mac-focus" queue in DeviceScreenNSView.isAccessibilityElement):
/// an Accessibility question about Terminal Deck itself is answered in this process by AppKit walking our own views, so
/// it must be asked on the main thread; only other apps are asked off it.
@Suite("Where this Mac's focus is asked")
struct MacFocusProbeTests {
    @Test func ownAppIsAskedOnTheMainThreadOthersOffIt() {
        let own = getpid()
        #expect(MacFocusProbe.mustAskOnMain(focusedPID: own, ownPID: own), "Terminal Deck itself: main thread")
        #expect(MacFocusProbe.mustAskOnMain(focusedPID: 0, ownPID: own), "unknown: main thread (never risk our own views off it)")
        #expect(MacFocusProbe.mustAskOnMain(focusedPID: -1, ownPID: own))
        #expect(!MacFocusProbe.mustAskOnMain(focusedPID: own + 1, ownPID: own), "another app: off the main thread")
    }

    /// The source itself: no Accessibility question in the focus probe or the element reader reaches this process off
    /// the main thread (every in-process path goes through `MacFocusProbe` and `MainActor`).
    @Test func theFocusProbeAndElementReaderRouteThisProcessToTheMainThread() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TerminalDeckNative")
        let screen = try String(contentsOf: root.appendingPathComponent("NativeMacScreen.swift"), encoding: .utf8)
        let elements = try String(contentsOf: root.appendingPathComponent("NativeMacScreenElements.swift"), encoding: .utf8)
        // 11:18 crash after #18a: even asking the system-wide element WHICH app is in front is answered by that app — by
        // AppKit in this process when it is Terminal Deck. The app in front comes from NSWorkspace; no system-wide element.
        let native = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        for file in native {
            #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("AXUIElementCreateSystemWide("), "\(file.lastPathComponent) asks the system-wide element")
        }
        #expect(screen.contains("NSWorkspace.shared.frontmostApplication?.processIdentifier"))
        #expect(screen.contains("MacFocusProbe.mustAskOnMain(focusedPID: front, ownPID: getpid())"))
        #expect(screen.contains("report(Self.focusTakesText(of: AXUIElementCreateApplication(getpid())), again: again)"),
                "this process's focus is read on the main thread (evaluate is MainActor)")
        #expect(screen.contains("otherAppFocusTakesText(pid: front)"))
        #expect(elements.contains("collect(display: display, own: false) }.value") && elements.contains("MainActor.run { collect(display: display, own: true) }"))
    }

    /// Hotfix 2: whatever thread AppKit's Accessibility walk comes from, the phone screen view answers without touching
    /// main-actor state (its overrides are nonisolated), so it can never trap there again.
    @Test func theScreenViewsAccessibilityAnswersNeverTrap() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TerminalDeckNative")
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for name in ["isAccessibilityElement()", "accessibilityRole()", "accessibilityLabel()"] {
                for line in text.components(separatedBy: "\n") where line.contains("override func \(name)") {
                    #expect(line.contains("nonisolated override"), "\(file.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
    }
}
