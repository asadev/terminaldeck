import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class ChatRenderTests: XCTestCase {
    static let message = """
    ### Chat layout fixture
    Tables keep every cell visible at the current message width.

    | Job | Where | Rules it follows |
    | --- | --- | --- |
    | Continue project merge | Codex, detached from this chat so a crash cannot kill it | Your rules remain attached to the complete job. |
    | Check long cells | https://example.com/averylongunbrokentoken1234567890abcdefghijk | Every part wraps within its own column. |

    | Name | Owner | State | Place | Time | Notes |
    | --- | --- | --- | --- | --- | --- |
    | Layout | Commander | Ready for review | Local fixture | Today | All six values stay readable, including this longer final cell. |

    - A list uses the same slightly larger body text.
    - Long items wrap comfortably within the message column.

    ```swift
    let originalLine = "Code stays on one unbroken line even when the chat becomes narrow."
    ```
    """
    func testRuntimeErrorsUsePlainLanguageAndCancellationsAreSilent() {
        XCTAssertEqual(NativeChatDisplayError.text("The operation couldn’t be completed. (Swift.CancellationError error 1.)"), "")
        XCTAssertNil(NativeChatDisplayError.message(CancellationError()))
        XCTAssertNil(NativeChatDisplayError.message(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
        XCTAssertEqual(NativeChatDisplayError.text("The operation couldn’t be completed. (Swift.TestError error 1.)"), "Couldn’t complete that chat action. Please try again.")
        XCTAssertEqual(NativeChatDisplayError.text("Connection lost. Try again."), "Connection lost. Try again.")
    }
    func testRenderingIsReadableThroughTheExistingChatTool() async throws {
        let model = NativeHootChatModel(fixture: .object([]))
        let state = try await model.featureTool("rendering", action: "read", args: .object([.init("request", .string("360"))]))
        XCTAssertEqual(state["bodyPoints"].number, 14)
        XCTAssertEqual(state["avatar"].string, "inline-with-name")
        XCTAssertEqual(state["tableSidewaysScroll"].bool, false)
        XCTAssertEqual(state["codeWrap"].bool, false)
        XCTAssertThrowsError(try model.renderingTool(width: "nan"))
    }
    func testFixtureDrawsNarrowWideLightDarkWithoutHorizontalOverflow() throws {
        XCTAssertFalse(EngineBridge.shared.isReady)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = ProcessInfo.processInfo.environment["CHAT_RENDER_OUTPUT"] ?? "/tmp/chat-render-proof.noindex"
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        for width in [360.0, 900.0] {
            for dark in [false, true] {
                let content = VStack(alignment: .leading, spacing: 12) {
                    NativeChatSenderLine(name: "Commander") { Image(systemName: "person.crop.circle.fill").resizable().frame(width: 26, height: 26) }
                    NativeChatMarkdown(text: Self.message)
                }.padding(20)
                    .environment(\.nativeChatFindQuery, "originalLine")
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .frame(width: width, alignment: .leading)
                    .background(dark ? Color(nsColor: .windowBackgroundColor) : Color.white)
                let host = NSHostingView(rootView: content)
                let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: width, height: 2200), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.isReleasedWhenClosed = false
                window.contentView = host
                for _ in 0..<8 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
                let height = host.fittingSize.height
                XCTAssertLessThanOrEqual(host.fittingSize.width, width + 1)
                XCTAssertGreaterThan(height, 400)
                window.setContentSize(NSSize(width: width, height: height))
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output).appendingPathComponent("mac-\(Int(width))-\(dark ? "dark" : "light").png"))
                window.contentView = nil; window.close()
            }
        }
        XCTAssertFalse(EngineBridge.shared.isReady)
    }
}
