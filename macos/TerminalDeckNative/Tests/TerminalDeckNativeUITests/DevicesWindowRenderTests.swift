import SwiftUI
import XCTest
import TerminalDeckNativeCore
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
            // The window's smallest width: the header buttons still keep their whole labels (review install-24).
            try MACHINESHiddenRender.render(MACHINESDevicesScreen(model: remote, fixture: true), dark: dark,
                size: CGSize(width: 680, height: 440), to: out.appendingPathComponent("MACHINES-devices-window-680-\(dark ? "dark" : "light").png"))
        }
        XCTAssertEqual(NativeSettingsNavigation.devicesID, "devices") // no Devices window: Settings → Devices (14 Nov)
    }

    /// Review install-24 follow-up: a server's address link (`terminaldeck://server?…`, what a phone pastes under Add a
    /// server) clicked on this Mac opens Servers with one line saying where it goes, instead of vanishing.
    @MainActor func testServerAddressLinkOpensServersWithOneLine() throws {
        XCTAssertTrue(NativeWidgetNavigation.isServerAddressLink(URL(string: "terminaldeck://server?r=wss%3A%2F%2Fexample.invalid&h=FIXTURE&k=abc")!))
        XCTAssertFalse(NativeWidgetNavigation.isServerAddressLink(URL(string: "terminaldeck://pair?x=y")!))
        XCTAssertFalse(NativeWidgetNavigation.isServerAddressLink(URL(string: "https://server.example.invalid/")!))
        XCTAssertTrue(SHELLRoutes.isAction(SHELLRoutes.serverAddressAction))
        XCTAssertEqual(SHELLRoutes.resolve(SHELLRoutes.serverAddressAction), SHELLRoutes.servers)
        XCTAssertTrue(SHELLRoutes.asked(SHELLRoutes.serverAddressAction))
        XCTAssertFalse(SHELLRoutes.asked("servers:add"), "the list opens, not Add a server")
        XCTAssertEqual(SHELLRoutes.resolve(SHELLRoutes.servers), SHELLRoutes.servers)
        XCTAssertTrue(SHELLRoutes.asked(SHELLRoutes.serverAddressAction), "Servers echoed back keeps the line")
        if let dir = ProcessInfo.processInfo.environment["TD_DEVICES_WINDOW_FRAMES"] {
            let out = URL(fileURLWithPath: dir)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let model = MACHINESRenderEvidence.fixtureModel()
            for dark in [false, true] {
                try MACHINESHiddenRender.render(NativeMACHINESServersDashboard(model: model, route: .constant(.list), live: false,
                    fixtureProjects: MACHINESFixtures.projects), dark: dark, size: CGSize(width: 1120, height: 640),
                    to: out.appendingPathComponent("MACHINES-servers-address-link-\(dark ? "dark" : "light").png"))
            }
        }
        XCTAssertEqual(SHELLRoutes.resolve("tasks"), "tasks")
        XCTAssertFalse(SHELLRoutes.asked(SHELLRoutes.serverAddressAction), "another place ends the line")
    }

    /// Review install-24 S5: an old phone link clicked on this Mac is recognised (it opens the Devices window, nothing more).
    @MainActor func testOldPhoneLinkIsRecognised() {
        XCTAssertTrue(NativeWidgetNavigation.isPairingLink(URL(string: "terminaldeck://pair?v=1&r=wss://example.invalid&h=fixture&t=123456")!))
        XCTAssertTrue(NativeWidgetNavigation.isPairingLink(URL(string: "terminaldeck://pair?x=y")!))
        XCTAssertFalse(NativeWidgetNavigation.isPairingLink(URL(string: "terminaldeck://session/abc")!))
        XCTAssertFalse(NativeWidgetNavigation.isPairingLink(URL(string: "terminaldeck://widget/tasks")!))
        XCTAssertFalse(NativeWidgetNavigation.isPairingLink(URL(string: "https://pair.example.invalid/")!))
    }
}
