import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class ChatDevicePanelsTests: XCTestCase {
    final class Owner: NativeUIGSimulatorOwner {
        let sessionId: String
        var ended = false, removed = false
        init(_ id: String) { sessionId = id }
    }
    func testHootAndChatShareTwoIndependentSlotsAndChatOwnershipNeedsNoPTY() throws {
        let suite = "td-par-device-panels-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        for id in ["hoot", "chat-fixture"] {
            let owner = Owner(id), store = NativeUIGSessionSimulatorStore(defaults: defaults, lifecycleEnabled: false)
            store.addSecond(owner); XCTAssertEqual(store.openEntries(owner).map(\.slot), [0])
            store.addSecond(owner); XCTAssertEqual(store.openEntries(owner).map(\.slot), [0, 1])
            store.addSecond(owner); XCTAssertEqual(store.openEntries(owner).count, 2)
            XCTAssertFalse(store.entry(owner).key == store.entry(owner, slot: 1).key)
            store.close(store.entry(owner, slot: 1)); XCTAssertEqual(store.openEntries(owner).map(\.slot), [0])
            store.closeAll(owner); XCTAssertTrue(store.openEntries(owner).isEmpty)
        }
        XCTAssertTrue(NativeDevicePanelSurface.permitsOwner(chat: true, hasPTY: false, ended: false))
        XCTAssertFalse(NativeDevicePanelSurface.permitsOwner(chat: false, hasPTY: false, ended: false))
        XCTAssertFalse(NativeDevicePanelSurface.permitsOwner(chat: true, hasPTY: true, ended: true))
        XCTAssertEqual(try NativeDevicePanelSurface.slot(1), 1)
        XCTAssertThrowsError(try NativeDevicePanelSurface.slot(2))
        XCTAssertThrowsError(try NativeDevicePanelSurface.slot(.nan))
    }
    func testFirstFrameHootAndChatOneAndTwoDevicesInBothThemesOffscreen() throws {
        guard let directory = ProcessInfo.processInfo.environment["PAR_DEVICE_RENDER_OUTPUT"], directory.hasSuffix(".noindex") else { throw XCTSkip("Explicit offscreen device-panel render run only.") }
        XCTAssertFalse(EngineBridge.shared.isReady)
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "td-par-device-render-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let picture = NSImage(size: NSSize(width: 240, height: 480))
        picture.lockFocus(); NSColor.systemTeal.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 240, height: 480)).fill(); picture.unlockFocus()
        let size = CGSize(width: 1400, height: 820)
        for hoot in [true, false] { for count in [1, 2] { for dark in [false, true] { for existing in [false, true] {
            let owner = Owner(hoot ? "hoot" : "chat-render-" + UUID().uuidString)
            let devices = [DeviceEntry(id: "SIM-PAR-0", name: "iPhone fixture"), DeviceEntry(id: "SIM-PAR-1", platform: "android", kind: "emulator", name: "Android fixture")]
            let panels = (0..<count).map { slot -> NativeUIGSessionSimulatorController in
                let panel = NativeUIGSessionSimulatorController(session: owner, slot: slot, defaults: defaults, lifecycleEnabled: false)
                panel.layout = .init(isOpen: true, width: 360)
                panel.model.installDevicePanelRenderFixture(devices)
                if existing {
                    panel.model.installHOOTSIMRenderFixture(.object([.init("sessionId", .string(owner.sessionId)), .init("device", .object([.init("id", .string(devices[slot].id)), .init("name", .string(devices[slot].name)), .init("platform", .string(devices[slot].platform))]))]), image: picture)
                    panel.ticket = UIGSessionSimulatorTicket(value: ["sessionId": owner.sessionId, "slot": slot, "attachmentToken": UUID().uuidString, "deviceId": devices[slot].id], for: owner.sessionId)
                }
                return panel
            }
            let fixture = NativeRPCValue.object([.init("conversationId", .string("panel-render")), .init("events", .array([])), .init("alive", .bool(true))])
            let rail = AnyView(VStack { ForEach(0..<8) { _ in Capsule().fill(.pink).frame(width: 18, height: 24); Spacer() } }.frame(width: 18))
            let content: AnyView
            if hoot { content = AnyView(NativeHootScreen(fixture: fixture, phonePanels: panels, trailing: rail)) }
            else {
                let chat = NativeHootChatModel(fixture: fixture, source: .session(owner.sessionId, provider: "codex"))
                content = AnyView(VStack(spacing: 0) { Text("Chat session").frame(height: 52); NativeUIGSessionSimulatorHost(session: owner, content: { HStack(spacing: 0) { NativeHootChat(model: chat); rail } }, panels: panels) })
            }
            let host = NSHostingView(rootView: content.environment(\.colorScheme, dark ? .dark : .light).environment(\.agkitOffscreenSolid, true).transaction { $0.disablesAnimations = true }.frame(width: size.width, height: size.height))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); host.frame = NSRect(origin: .zero, size: size); host.wantsLayer = true
            host.layoutSubtreeIfNeeded()
            XCTAssertNil(host.window)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
            let name = "\(hoot ? "hoot" : "chat")-\(count)-\(dark ? "dark" : "light")-\(existing ? "existing" : "choose")-first"
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
            for y in [220, 440, 680] {
                let colour = try XCTUnwrap(bitmap.colorAt(x: 1397, y: y)?.usingColorSpace(.sRGB))
                let luminance = NativeChrome.luminance(colour)
                if dark { XCTAssertLessThan(luminance, 0.22, name) } else { XCTAssertGreaterThan(luminance, 0.88, name) }
            }
            if let crop = bitmap.cgImage?.cropping(to: CGRect(x: 1040, y: 52, width: 360, height: 768)) {
                let data = NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:])
                try data?.write(to: output.appendingPathComponent(name + "-panel.png"))
            }
        } } } }
        XCTAssertFalse(EngineBridge.shared.isReady)
    }
}
