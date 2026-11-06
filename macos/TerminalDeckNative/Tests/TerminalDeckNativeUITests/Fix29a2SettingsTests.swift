import AppKit
import CoreVideo
import SwiftUI
import XCTest
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

private final class Fix29a2Lock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    func read() -> Bool { lock.withLock { value } }
}
private actor Fix29a2Picture: BackendPhoneDeviceStream {
    var stopped = 0
    var reads = 0
    var opens = 0
    var ended = false
    let buffer: CVPixelBuffer
    init() throws {
        var value: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &value) == kCVReturnSuccess,
              let value else { throw NativeRPCError(code: "fixture", message: "No test picture") }
        buffer = value
    }
    func open() -> Fix29a2Picture { opens += 1; return self }
    func end() { ended = true }
    func endReason() -> String { "Capture stopped" }
    func stop() { stopped += 1 }
    func pixels(within seconds: Double) -> BackendPhoneDevicePixelsAnswer {
        reads += 1
        return ended ? .ended : .pixels(.init(buffer, capturedAt: 1))
    }
}

final class Fix29a2SettingsTests: XCTestCase {
    func testWorkingLocalPictureSurvivesLockWithoutHelper() async throws {
        let state = Fix29a2Lock(), local = try Fix29a2Picture(), helper = try Fix29a2Picture()
        let stream = NativeMacReachSwitchingStream(display: "mac:main", local: { _ in await local.open() },
            helper: { _ in await helper.open() }, isLocked: { state.read() }, helperApproved: { false })
        guard case .pixels = await stream.pixels(within: 0) else { return XCTFail("Initial picture missing") }
        state.set()
        guard case .pixels = await stream.pixels(within: 0) else { return XCTFail("Lock discarded a working picture") }
        let stops = await local.stopped, opens = await helper.opens
        XCTAssertEqual(stops, 0); XCTAssertEqual(opens, 0)
        await stream.stop()
    }
    func testAlreadyLockedLocalCaptureWorksWithoutApprovedHelper() async throws {
        let local = try Fix29a2Picture(), helper = try Fix29a2Picture()
        let stream = NativeMacReachSwitchingStream(display: "mac:main", local: { _ in await local.open() },
            helper: { _ in await helper.open() }, isLocked: { true }, helperApproved: { false })
        guard case .pixels = await stream.pixels(within: 0) else { return XCTFail("Lock screen picture missing") }
        let opens = await helper.opens
        XCTAssertEqual(opens, 0)
        await stream.stop()
    }
    func testFailedLocalCaptureFallsBackToApprovedHelper() async throws {
        let helper = try Fix29a2Picture()
        let stream = MacScreenAvailability.$mayWake.withValue(true) {
            NativeMacReachSwitchingStream(display: "mac:main", local: { _ in throw NativeRPCError(code: "unavailable", message: "Empty after retry") },
                helper: { _ in await helper.open() }, isLocked: { true }, helperApproved: { true })
        }
        guard case .pixels = await stream.pixels(within: 0) else { return XCTFail("Helper picture missing") }
        let opens = await helper.opens
        XCTAssertEqual(opens, 1)
        await stream.stop()
    }
    @MainActor func testOneSettingAndMCPUseGeneralPowerChannel() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ name: String) throws -> String {
            try String(contentsOf: package.appendingPathComponent("Sources/TerminalDeckNative/" + name + ".swift"), encoding: .utf8)
        }
        XCTAssertFalse(try source("NativeMacReachSettings").contains("Toggle("))
        XCTAssertFalse(try source("NativeMacReach").contains("remote.keepAwakeOnPower"))
        XCTAssertTrue(try source("NativeMacReach").contains("invoke(\"power:lid-awake:set\", [enabled])"))
        XCTAssertTrue(try source("NativeMacReachTools").contains("NativeMacReach.shared.setKeepAwake(on)"))
        XCTAssertTrue(try source("NativeGeneralSettings").contains("NativeMacAwakeSetting(fixtureState: power)"))
        XCTAssertNotNil(PowerWords.caution(hasLid: true))
    }
    @MainActor func testGeneralAndDevicesFramesBothThemes() throws {
        let app = NSApplication.shared
        guard !app.isActive, app.windows.allSatisfy({ !$0.isVisible }) else { throw XCTSkip("Offscreen-only guard") }
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = package.deletingLastPathComponent().appendingPathComponent("night/codex/fix-29a2-evidence")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let power = try XCTUnwrap(LidAwakeState.decode(["supported": true, "known": true, "on": true, "idleBlocked": true,
            "battery": ["present": false]]))
        for dark in [false, true] {
            let general = NativeSettingsShell(selection: .constant("general")) { _ in NativeGeneralSettings(fixtureState: power) }
            try render(general, name: "general", dark: dark, output: output)
            let devices = MACHINESSettingsFrame(title: "Device access", switcher: {
                MACHINESDevicesSettingsTabs(selection: .constant("General"))
            }, actions: { EmptyView() }) {
                Form { NativeMacReachSettings(fixture: true) }.formStyle(.grouped)
            }
            try render(devices, name: "devices", dark: dark, output: output)
        }
    }
    @MainActor func testPowerExplanationWrapsAtSettingsWidth() throws {
        let app = NSApplication.shared
        guard !app.isActive, app.windows.allSatisfy({ !$0.isVisible }) else { throw XCTSkip("Offscreen-only guard") }
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = package.deletingLastPathComponent().appendingPathComponent("night/codex/fix-29a2-evidence")
        let power = try XCTUnwrap(LidAwakeState.decode(["supported": true, "known": true, "on": true, "idleBlocked": true,
            "battery": ["present": false]]))
        // The complete explanation needs multiple lines at the actual settings column width.
        let row = NSHostingView(rootView: NativeMacAwakeSetting(fixtureState: power).frame(width: 560))
        row.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(row.fittingSize.height, 70)
        for dark in [false, true] {
            let general = NativeSettingsShell(selection: .constant("general")) { _ in NativeGeneralSettings(fixtureState: power) }
            try render(general, name: "general-wrapped", dark: dark, output: output)
        }
    }
    @MainActor private func render<V: View>(_ view: V, name: String, dark: Bool, output: URL) throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let size = CGSize(width: 900, height: 960)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height))
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
            .write(to: output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }
}
