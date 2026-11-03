// #90 "Do it and tell me" card, rendered offscreen inside XCTest. No application,
// window, engine or AI. PNGs go only to a .noindex folder (item 118).
import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class L6RouteNotifyRenderTests: XCTestCase {
    private static func route(_ status: String, extra: [NativeRPCValue.Field] = []) -> NativeRPCValue {
        .object([.init("id", .string("8c1b8a4e-5f7e-4c1c-9a53-0f1d2c3b4a5e")), .init("revision", .string("0b5e8f0e-2f8b-4b52-8e40-3f0a6f1c2d3e")),
                 .init("status", .string(status)), .init("state", .string(status)), .init("problem", .string("Sign-in button does nothing on the CRM login page")),
                 .init("reason", .string("Owns the CRM portal sign-in.")), .init("undoSeconds", .number(10)),
                 .init("target", .object([.init("id", .string("portal-mechanic")), .init("kind", .string("agent")), .init("name", .string("portal-mechanic")),
                    .init("role", .string("Keeps the CRM portal working")), .init("projectId", .string("crm")), .init("projectName", .string("CRM")),
                    .init("folder", .string("/Users/fixture/ClaudeCRM")), .init("icon", .string("wrench.and.screwdriver"))]))] + extra)
    }
    func testAutoApprovedCardRendersLightAndDark() throws {
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("design-2026-10-10/built.noindex", isDirectory: true)
        XCTAssertTrue(output.path.hasSuffix(".noindex"))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let cards = VStack(alignment: .leading, spacing: 16) {
            Text("Do it and tell me · waiting").font(.caption).foregroundStyle(.secondary)
            NativeHOOTSIMRoutingCard(route: Self.route("scheduled"), fixtureMode: true) { _, _ in }
            Text("After Undo").font(.caption).foregroundStyle(.secondary)
            NativeHOOTSIMRoutingCard(route: Self.route("dismissed", extra: [.init("undone", .bool(true))]), fixtureMode: true) { _, _ in }
            Text("After 10 s").font(.caption).foregroundStyle(.secondary)
            NativeHOOTSIMRoutingCard(route: Self.route("sent", extra: [.init("taskId", .string("CRM-41")), .init("automatic", .bool(true))]), fixtureMode: true) { _, _ in }
            Text("Outside the switches: still asks").font(.caption).foregroundStyle(.secondary)
            NativeHOOTSIMRoutingCard(route: Self.route("pending"), fixtureMode: true) { _, _ in }
        }.padding(24).frame(width: 760, alignment: .topLeading)
        for dark in [false, true] {
            let file = output.appendingPathComponent("L6-ROUTE-notify-card-\(dark ? "dark" : "light").png")
            try Self.render(cards, size: CGSize(width: 760, height: 520), dark: dark, to: file)
        }
    }
    static func render<V: View>(_ content: V, size: CGSize, dark: Bool, to output: URL) throws {
        let host = NSHostingView(rootView: content.environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.agkitOffscreenSolid, true)
            .frame(width: size.width, height: size.height, alignment: .topLeading).background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.wantsLayer = true
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(host.window)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: output)
        XCTAssertEqual(bitmap.pixelsWide, Int(size.width))
    }
}
