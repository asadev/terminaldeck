import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

/// Asad's quick fixes, drawn in a real but never-shown window, light and dark: the chat sits
/// inside the box's width, short permission/model+effort choices under the box, and the
/// simulator button in Hoot's header with its device list. No app, engine, device or AI.
@MainActor final class L6HootQuickFixRenderTests: XCTestCase {
    private static let conversation = "L6-quick"
    private static var chat: NativeRPCValue {
        let events = (1...40).map { index in
            HootChatEvent(conversationID: conversation, turnID: "t\((index + 1) / 2)", sequence: index, provider: .claude,
                record: index % 2 == 1 ? .text(.user, id: "u\(index)", "Question \(index): why does the sign-in page fail?")
                                       : .text(.message, id: "m\(index)", "Answer \(index). " + String(repeating: "The sign-in check runs before the password. ", count: 4)))
        }
        return .object([.init("conversationId", .string(conversation)), .init("sequence", .number(40)),
            .init("events", .array(events.map(\.wireValue))), .init("ready", .bool(true)), .init("alive", .bool(true)),
            .init("busy", .bool(false)), .init("pending", .array([])),
            .init("options", .object([.init("permissionMode", .string("ask")), .init("model", .string("claude:opus")),
                .init("effort", .string("high")), .init("efforts", .array(["low", "medium", "high", "xhigh", "max"].map(NativeRPCValue.string))),
                .init("ready", .bool(true)), .init("models", .array([
                    .object([.init("id", .string("claude:default")), .init("provider", .string("Claude Code")), .init("name", .string("Default"))]),
                    .object([.init("id", .string("claude:opus")), .init("provider", .string("Claude Code")), .init("name", .string("Opus 5"))])]))]))])
    }
    private func shot<V: View>(_ view: V, size: CGSize, dark: Bool, name: String) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.agkitOffscreenSolid, true).frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.12)) }
        XCTAssertFalse(window.isVisible)
        guard let path = ProcessInfo.processInfo.environment["HOOTSIM_RENDER_OUTPUT"], path.hasSuffix(".noindex") else { return }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: path).appendingPathComponent("L6-HOOT-quick-\(name)-\(dark ? "dark" : "light").png"))
    }
    func testShortChoicesInsideBoxAndSimulatorButton() throws {
        XCTAssertFalse(EngineBridge.shared.isReady)
        NSApplication.shared.setActivationPolicy(.prohibited)
        // Bypass joined the choices on 10 Oct (owner only; it lives in the quick settings popover with the other three).
        XCTAssertEqual(HootPermissionMode.allCases.map(\.short), ["Ask first", "Plan only", "Auto", "Bypass permissions"] /* R5 */)
        XCTAssertEqual(HootComposerModel.effortName("xhigh"), "Extra")
        XCTAssertEqual(HootComposerModel.effortName("high"), "High")
        let devices = DeviceList(available: true, devices: [
            DeviceEntry(id: "ios:L6-1", platform: "ios", kind: "simulator", state: "ready", available: true, name: "iPhone 17 Pro", runtime: "iOS 27.0", canShutDown: true),
            DeviceEntry(id: "android:emulator-5554", platform: "android", kind: "emulator", state: "ready", available: true, name: "Pixel 9", runtime: "Android 16", canShutDown: true),
            DeviceEntry(id: "ios:L6-2", platform: "ios", kind: "simulator", state: "shutdown", available: false, name: "iPad Air 13-inch", runtime: "iPadOS 27.0", canBoot: true)])
        for dark in [false, true] {
            let page = NativeHootChatModel(fixture: Self.chat)
            XCTAssertEqual(page.composerDraft.effort, "high")
            XCTAssertEqual(page.catalogue.efforts.count, 5)
            try shot(NativeHootScreen(fixture: Self.chat), size: CGSize(width: 1000, height: 700), dark: dark, name: "page")
            try shot(NativeHootChat(model: NativeHootChatModel(fixture: Self.chat), compact: true), size: CGSize(width: 480, height: 420), dark: dark, name: "island-chat")
            _ = devices
        }
        XCTAssertFalse(EngineBridge.shared.isReady)
    }
}
