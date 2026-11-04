import Foundation
import WebKit
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor
final class BrowserSecurity27NamedPaymentTests: XCTestCase {
    func testNamedPaymentFieldsUseTheSameInputAndScreenshotFence() async throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        defer { view.stopLoading() }
        view.loadHTMLString("<input id='ccNum'><input id='cardNum'><input id='cvv'><input id='ordinary'>", baseURL: nil)
        for _ in 0..<200 {
            if (try? await view.evaluateJavaScript("!!document.getElementById('ordinary')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        for id in ["ccNum", "cardNum", "cvv", "ordinary"] {
            let raw = try await view.evaluateJavaScript(BrowserDriverScripts.with(BrowserDriverScripts.probe, args: ["selector": "#" + id]), in: nil, contentWorld: .defaultClient)
            XCTAssertEqual((raw as? [String: Any])?["secret"] as? Bool, id != "ordinary")
        }
        for script in [NativeSafariRuntime.secretRectangles, NativeSafariRuntime.secretDocumentRectangles] {
            let raw = try await view.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient)
            XCTAssertEqual(((raw as? [String: Any])?["rects"] as? [Any])?.count, 3)
        }
    }
}
