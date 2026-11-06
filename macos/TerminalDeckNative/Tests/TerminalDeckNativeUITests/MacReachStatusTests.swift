import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

final class MacReachStatusTests: XCTestCase {
    @MainActor func testStatusNeedsAConfirmedConnectionAndReleaseBundle() async {
        let model = NativeMacReach.fixture(registration: .enabled)
        let status = await model.status()
        XCTAssertEqual(status["helper"].string, MacReach.Registration.notBundled.rawValue)
        XCTAssertEqual(status["agentConnected"].bool, false)
        XCTAssertEqual(status["keepAwakeActive"].bool, false)
    }
    /// The complete existing Devices settings frame, beyond the earlier card-only renders. Offscreen, fixture data only.
    @MainActor func testCompleteSettingsFrameAcrossThemes() throws {
        let app = NSApplication.shared
        guard !app.isActive, app.windows.allSatisfy({ !$0.isVisible }) else { throw XCTSkip("Offscreen-only guard") }
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = package.deletingLastPathComponent().appendingPathComponent("night/codex/mac-reach-evidence")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, state, width) in [("setup", MacReach.Registration.notRegistered, 720.0), ("approval", .needsApproval, 480.0), ("enabled", .enabled, 720.0)] {
            for dark in [false, true] {
                let size = CGSize(width: width, height: 960)
                let view = MACHINESSettingsFrame(title: "Device access", switcher: {
                    MACHINESDevicesSettingsTabs(selection: .constant("General"))
                }, actions: { EmptyView() }) {
                    Form { NativeMacReachSettings(fixture: true, model: .fixture(registration: state)) }.formStyle(.grouped)
                }.background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, dark ? .dark : .light).frame(width: size.width, height: size.height)
                let host = NSHostingView(rootView: view)
                host.sizingOptions = []
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                host.layoutSubtreeIfNeeded()
                XCTAssertNil(host.window)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: output.appendingPathComponent("whole-\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
