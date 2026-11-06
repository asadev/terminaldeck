import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Offscreen only. No app launch, system Settings, service registration, live data, or window on the person's screen.
final class MacReachVisualTests: XCTestCase {
    @MainActor func testSetupFrames() throws {
        let app = NSApplication.shared
        guard !app.isActive, app.windows.allSatisfy({ !$0.isVisible }) else { throw XCTSkip("Offscreen-only guard: a test window is visible or active") }
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = package.deletingLastPathComponent().appendingPathComponent("night/codex/mac-reach-evidence")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, state, width) in [("setup", MacReach.Registration.notRegistered, 720.0), ("approval", .needsApproval, 480.0), ("enabled", .enabled, 720.0)] {
            for dark in [false, true] {
                let size = CGSize(width: width, height: 960)
                let view = VStack(spacing: 0) {
                    HStack { Text("Device access").font(.title2); Spacer(); Text("General").foregroundStyle(.secondary) }.padding(20)
                    Form { NativeMacReachSettings(fixture: true, model: .fixture(registration: state)) }.formStyle(.grouped)
                }.environment(\.colorScheme, dark ? .dark : .light).frame(width: size.width, height: size.height)
                let host = NSHostingView(rootView: view)
                host.sizingOptions = []
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(width))
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
