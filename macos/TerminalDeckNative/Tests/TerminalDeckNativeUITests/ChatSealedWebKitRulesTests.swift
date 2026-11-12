import Foundation
import WebKit
import XCTest
@testable import TerminalDeckNativeCore

@MainActor
final class ChatSealedWebKitRulesTests: XCTestCase {
    func testProductionContentRulesCompileInWebKit() async throws {
        // ICU accepts alternation; WebKit's restricted rule compiler does not.
        // Exercise the real compiler so rejected rules cannot blank every visual.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("td-chat-rule-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(WKContentRuleListStore(url: directory))
        let result = try await store.compileContentRuleList(forIdentifier: "sealed-production-rules", encodedContentRuleList: NativeChatSealedDocument.contentRules)
        let compiled = try XCTUnwrap(result)
        XCTAssertEqual(compiled.identifier, "sealed-production-rules")
    }

    // Release check, 6 Nov: in the background test window the chart box kept its starting height. A view in no
    // window paints no frame; the drawing must still report its full height.
    func testDrawingReportsItsHeightWhileOffScreen() async throws {
        let sizes = SealedSizes(), config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(sizes, name: "sealedChat")
        defer { config.userContentController.removeScriptMessageHandler(forName: "sealedChat") }
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 160), configuration: config)
        let colors = NativeChatSealedDocument.Colors(background: "rgb(30,30,30)", foreground: "rgb(240,240,240)", accent: "rgb(10,132,255)",
                                                     secondary: "rgb(150,150,150)", surface: "rgb(40,40,40)", dark: true)
        view.loadHTMLString(NativeChatSealedDocument.document(source: "<div style=\"height:640px\">Tall chart</div>", kind: "visual",
                                                              colors: colors, bridge: false), baseURL: nil)
        let deadline = Date().addingTimeInterval(15)
        while (sizes.heights.max() ?? 0) < 640, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNil(view.window)
        XCTAssertGreaterThanOrEqual(sizes.heights.max() ?? 0, 640, "reported: \(sizes.heights)")
    }
}

@MainActor
private final class SealedSizes: NSObject, WKScriptMessageHandler {
    var heights: [Double] = []
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], body["type"] as? String == "size", let height = body["height"] as? Double else { return }
        heights.append(height)
    }
}
