import Foundation
import XCTest
@testable import TerminalDeckNative

@MainActor final class RichChatImageSourceTests: XCTestCase {
    func testImagePathsCannotEscapeTheSessionFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("render-mac-images-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        XCTAssertNil(NativeChatImageSource.resolve("../private.png", folder: root.path))
        XCTAssertNil(NativeChatImageSource.resolve("outside/hosts", folder: root.path))
        XCTAssertNil(NativeChatImageSource.resolve("file:///etc/hosts", folder: root.path))
        XCTAssertNil(NativeChatImageSource.resolve("javascript:alert(1)", folder: root.path))
        XCTAssertNotNil(NativeChatImageSource.resolve("chart.png", folder: root.path))
        XCTAssertNotNil(NativeChatImageSource.resolve("https://example.com/chart.png", folder: ""))
        XCTAssertNil(NativeChatImageSource.resolve("data:text/html,<script>", folder: ""))
    }
}
