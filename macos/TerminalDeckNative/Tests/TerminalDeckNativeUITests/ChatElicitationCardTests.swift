import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class ChatElicitationCardTests: XCTestCase {
    func testFormAndAuthCardsFitNarrowChatInBothThemes() throws {
        let inputs = [
            #"{"mode":"form","serverName":"Calendar","message":"Choose the calendar and maximum number of events.","requestedSchema":{"type":"object","required":["calendar","count"],"properties":{"calendar":{"title":"Calendar","type":"string","enum":["Work","Personal"]},"count":{"type":"integer","minimum":1},"private":{"type":"boolean"}}}}"#,
            #"{"mode":"url","serverName":"Calendar","message":"Sign in to connect your calendar.","url":"https://example.com/auth"}"#
        ]
        for (index, input) in inputs.enumerated() {
            let request = NativeRPCValue.object([.init("subtype", .string("mcpServer/elicitation/request")),
                .init("input", try .parseJSON(Data(input.utf8)))])
            for dark in [false, true] {
                let host = NSHostingView(rootView: NativeChatElicitationCard(request: request, disabled: false, answer: { _, _ in })
                    .frame(width: 340).environment(\.colorScheme, dark ? .dark : .light))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: 340, height: 420)
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.fittingSize.width, 340, accuracy: 1)
                XCTAssertGreaterThan(host.fittingSize.height, 100)
                XCTAssertLessThan(host.fittingSize.height, 600)
                if let directory = ProcessInfo.processInfo.environment["TD_CONN_RENDER_DIR"] {
                    host.frame.size.height = host.fittingSize.height
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let folder = URL(fileURLWithPath: directory)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: folder.appendingPathComponent("elicitation-\(index)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }
}
