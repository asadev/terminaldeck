import SwiftUI
import XCTest
@testable import TerminalDeckNative

/// The Devices window's content at its Settings-sized frame, light and dark, with inert fixture data only.
final class DevicesWindowRenderTests: XCTestCase {
    @MainActor func testDevicesWindowContentRenders() throws {
        guard let dir = ProcessInfo.processInfo.environment["TD_DEVICES_WINDOW_FRAMES"] else { throw XCTSkip("Set TD_DEVICES_WINDOW_FRAMES") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let remote = MACHINESFixtures.remoteModel()
        for dark in [false, true] {
            try MACHINESHiddenRender.render(MACHINESDevicesScreen(model: remote, fixture: true), dark: dark,
                size: CGSize(width: 760, height: 560), to: out.appendingPathComponent("MACHINES-devices-window-\(dark ? "dark" : "light").png"))
        }
        XCTAssertEqual(DevicesWindow.sceneID, "devices")
    }
}
