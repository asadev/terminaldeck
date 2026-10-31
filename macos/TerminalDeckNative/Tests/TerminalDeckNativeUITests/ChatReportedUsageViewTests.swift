import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class ChatReportedUsageViewTests: XCTestCase {
    func testSnapshotReadingAndConversationResetDoNotReuseAnotherReport() throws {
        let model = NativeHootChatModel(fixture: .object([]))
        let report = NativeRPCValue.object([.init("provider", .string("claude")), .init("costUSD", .number(0.25))])
        model.acceptFixtureUpdate(.object([.init("conversationId", .string("one")), .init("sequence", .number(1)), .init("events", .array([])), .init("cliUsage", report)]))
        XCTAssertEqual(model.chatReportedUsage["provider"].string, "claude")
        XCTAssertEqual(model.chatReportedUsage["costUSD"].number, 0.25)
        model.acceptFixtureUpdate(.object([.init("conversationId", .string("two")), .init("sequence", .number(1)), .init("events", .array([]))]))
        XCTAssertEqual(model.chatReportedUsage, .null)
    }
    func testProviderReportsFitBothThemesWithReportedAndUnknownCost() throws {
        for provider in ["claude", "codex", "gemini"] {
            let report = NativeRPCValue.object([.init("provider", .string(provider)), .init("scope", .string("Latest provider report")),
                .init("inputTokens", .number(12_345)), .init("outputTokens", .number(120)), .init("totalTokens", .number(12_465)),
                .init("costUSD", provider == "claude" ? .number(0.012345) : .null), .init("reportedAt", .number(1_700_000_000_000))])
            for dark in [false, true] {
                let host = NSHostingView(rootView: NativeChatReportedUsagePanel(reading: report)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, dark ? .dark : .light))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: 372, height: 400)
                host.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(host.fittingSize.width, 372)
                XCTAssertLessThan(host.fittingSize.height, 420)
                if let directory = ProcessInfo.processInfo.environment["TD_CONN_RENDER_DIR"] {
                    host.frame.size.height = host.fittingSize.height
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let folder = URL(fileURLWithPath: directory)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: folder.appendingPathComponent("usage-\(provider)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }
}
