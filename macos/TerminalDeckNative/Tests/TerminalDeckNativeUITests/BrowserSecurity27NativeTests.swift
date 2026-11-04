import Foundation
import WebKit
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor
final class BrowserSecurity27NativeTests: XCTestCase {
    private func page() async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        view.loadHTMLString("""
        <div id="fixture"><input id="pw" type="password" value="dummy-password">
        <input id="card" autocomplete="cc-number" value="dummy-card">
        <input id="cardname" autocomplete="cc-name" value="dummy-name">
        <textarea id="code" autocomplete="one-time-code">dummy-code</textarea>
        <input id="ordinary" value="ordinary-value"></div>
        """, baseURL: nil)
        for _ in 0..<200 {
            if (try? await view.evaluateJavaScript("!!document.getElementById('ordinary')")) as? Bool == true { return view }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The local fixture did not load")
        return view
    }

    func testScreenshotsMaskPasswordPaymentAndCodeFieldsAtBothSizes() async throws {
        let view = try await page()
        defer { view.stopLoading() }
        for script in [NativeSafariRuntime.secretRectangles, NativeSafariRuntime.secretDocumentRectangles] {
            let raw = try await view.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient)
            let rects = try XCTUnwrap((raw as? [String: Any])?["rects"] as? [[String: Any]])
            XCTAssertEqual(rects.count, 4, "Only the four protected fields are masked")
        }
    }

    func testHTMLAndRequestedAttributesCannotReturnSecretValues() async throws {
        let view = try await page()
        defer { view.stopLoading() }
        let requests: [[String: Any]] = [
            ["mode": "matches", "selector": "input,textarea", "attributes": ["value", "type"]],
            ["mode": "html", "selector": "#pw"],
            ["mode": "html", "selector": "#fixture"],
            ["mode": "extract", "rows": "#fixture", "fields": ["html": "@html"]]
        ]
        for args in requests {
            let raw = try await view.evaluateJavaScript(BrowserDriverScripts.with(BrowserDriverScripts.readMode, args: args), in: nil, contentWorld: .defaultClient)
            let json = String(decoding: try JSONSerialization.data(withJSONObject: XCTUnwrap(raw), options: [.sortedKeys]), as: UTF8.self)
            for secret in ["dummy-password", "dummy-card", "dummy-name", "dummy-code"] { XCTAssertFalse(json.contains(secret), json) }
        }
        let normal = try await view.evaluateJavaScript(BrowserDriverScripts.with(BrowserDriverScripts.readMode, args: ["mode": "matches", "selector": "#ordinary", "attributes": ["value"]]), in: nil, contentWorld: .defaultClient)
        XCTAssertTrue(String(describing: normal).contains("ordinary-value"))
    }

    func testFocusedSecretGuardLooksThroughShadowRoots() async throws {
        let view = try await page()
        defer { view.stopLoading() }
        for id in ["pw", "card", "code", "ordinary"] {
            _ = try await view.evaluateJavaScript("document.getElementById('\(id)').focus()")
            let raw = try await view.evaluateJavaScript(BrowserDriverScripts.activeSecret, in: nil, contentWorld: .defaultClient)
            XCTAssertEqual((raw as? [String: Any])?["secret"] as? Bool, id != "ordinary")
        }
        _ = try await view.evaluateJavaScript("var host=document.createElement('div');document.body.append(host);host.attachShadow({mode:'open'}).innerHTML='<input type=password>';host.shadowRoot.firstChild.focus()")
        let raw = try await view.evaluateJavaScript(BrowserDriverScripts.activeSecret, in: nil, contentWorld: .defaultClient)
        XCTAssertEqual((raw as? [String: Any])?["secret"] as? Bool, true)
    }
}
