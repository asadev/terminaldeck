import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest
@testable import TerminalDeckNative

/// Mac to Mac (31 Oct): the Devices window's "Other Macs" card and the viewer window's content, light and dark, from
/// fixture data and a fake picture; and how this Mac's keys cross to the other Mac.
final class MacToMacRenderTests: XCTestCase {
    @MainActor static func fakeDesktop(width: Int = 2400, height: Int = 1500) -> CGImage {
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { rect in
            NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.2, blue: 0.42, alpha: 1), ending: NSColor(calibratedRed: 0.55, green: 0.33, blue: 0.62, alpha: 1))?
                .draw(in: rect, angle: 30)
            NSColor.black.withAlphaComponent(0.25).setFill(); NSRect(x: 0, y: 0, width: rect.width, height: 44).fill()
            ("  Finder    File    Edit    View    Go    Window    Help" as NSString).draw(at: NSPoint(x: 16, y: 10), withAttributes: [.font: NSFont.systemFont(ofSize: 22, weight: .medium), .foregroundColor: NSColor.white])
            let window = NSRect(x: 330, y: 170, width: 1740, height: 1020)
            NSColor(white: 0.97, alpha: 1).setFill(); NSBezierPath(roundedRect: window, xRadius: 20, yRadius: 20).fill()
            for (index, line) in ["Studio Mac — Terminal Deck", "", "❯ swift build -j 8", "Building for debugging...", "[412/412] Linking TerminalDeck",
                                  "Build complete! (41.2s)", "", "❯ git status", "On branch lane/mac-to-mac", "nothing to commit, working tree clean"].enumerated() {
                (line as NSString).draw(at: NSPoint(x: window.minX + 50, y: window.minY + 60 + CGFloat(index) * 46),
                    withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 28, weight: .regular), .foregroundColor: NSColor(white: 0.15, alpha: 1)])
            }
            NSColor.white.withAlphaComponent(0.35).setFill(); NSBezierPath(roundedRect: NSRect(x: 720, y: rect.height - 130, width: 960, height: 110), xRadius: 30, yRadius: 30).fill()
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    @MainActor func testOtherMacsAndViewerRender() throws {
        guard let dir = ProcessInfo.processInfo.environment["TD_MAC_TO_MAC_FRAMES"] else { throw XCTSkip("Set TD_MAC_TO_MAC_FRAMES") }
        let out = URL(fileURLWithPath: dir)
        let studio = OtherMacDisplay(id: "mac:2", name: "Studio Display", pixels: "5120 × 2880", canWatch: true, canControl: true, note: "")
        let side = OtherMacDisplay(id: "mac:3", name: "LG UltraFine", pixels: "3840 × 2160", canWatch: true, canControl: true, note: "")
        let macs = OtherMacsModel(fixture: [
            OtherMac(id: "m1", name: "Studio Mac", phase: .online, displays: [studio, side]),
            OtherMac(id: "m2", name: "Office MacBook", phase: .online, displays: [OtherMacDisplay(id: "mac:1", name: "Built-in Retina Display", pixels: "3024 × 1964",
                canWatch: true, canControl: false, note: "This Mac needs a one-time permission to be clicked and typed on: System Settings → Privacy & Security → Accessibility → Terminal Deck.")]),
            OtherMac(id: "m3", name: "Home iMac", phase: .offline),
        ])
        let viewer = RemoteMacViewerModel(machine: "m1", machineName: "Studio Mac", display: "mac:2", displays: [studio, side], fixtureImage: Self.fakeDesktop())
        for dark in [false, true] {
            try MACHINESHiddenRender.render(MACHINESCard { NativeOtherMacsCard(model: macs, open: { _, _ in }) }.padding(20), dark: dark,
                size: CGSize(width: 720, height: 360), to: out.appendingPathComponent("MACHINES-other-macs-\(dark ? "dark" : "light").png"))
            try MACHINESHiddenRender.render(NativeRemoteMacViewer(model: viewer), dark: dark,
                size: CGSize(width: 1200, height: 790), to: out.appendingPathComponent("MACHINES-remote-mac-viewer-\(dark ? "dark" : "light").png"))
        }
    }

    @MainActor func testKeysCrossAsTextOrAsKeys() {
        // Text in any language crosses as text: the other Mac's keyboard layout does not matter.
        XCTAssertEqual(RemoteMacScreenView.keySend(code: UInt16(kVK_ANSI_A), characters: "ش", flags: []), .text("ش"))
        XCTAssertEqual(RemoteMacScreenView.keySend(code: UInt16(kVK_ANSI_E), characters: "é", flags: [.option]), .text("é"))
        // Shortcuts and special keys cross as the key itself with its modifiers.
        XCTAssertEqual(RemoteMacScreenView.keySend(code: UInt16(kVK_ANSI_C), characters: "c", flags: [.command]), .code(Int(kVK_ANSI_C), mods: ["command"]))
        XCTAssertEqual(RemoteMacScreenView.keySend(code: UInt16(kVK_LeftArrow), characters: "\u{F702}", flags: [.shift, .function]), .code(Int(kVK_LeftArrow), mods: ["shift", "fn"]))
        XCTAssertEqual(RemoteMacScreenView.keySend(code: UInt16(kVK_Return), characters: "\r", flags: []), .code(Int(kVK_Return), mods: []))
    }
}
