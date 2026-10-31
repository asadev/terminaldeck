import Foundation
import WebKit
import XCTest
@testable import TerminalDeckNative

/// Page pictures grey out only password and card fields (Asad, decision 11), not forms or page sections.
@MainActor
final class BrowserShotMaskTests: XCTestCase {
    func testOnlyPasswordAndCardFieldsAreMasked() async throws {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 900))
        let html = """
        <body style="margin:0">
        <form style="height:60px"><input id="search" type="search"><button>Go</button></form>
        <x-panel style="display:block;height:60px">GitHub-style section</x-panel>
        <input type="file"><input type="password"><input autocomplete="cc-number"><input name="cardNumber">
        <iframe id="same" style="position:absolute;left:300px;top:400px;width:300px;height:200px;border:0"
          srcdoc="<body style='margin:0'><input type='password' style='margin-left:50px'><input type='text'></body>"></iframe>
        <iframe id="other" style="position:absolute;left:0;top:700px;width:200px;height:100px;border:0" src="data:text/html,x"></iframe>
        </body>
        """
        view.loadHTMLString(html, baseURL: URL(string: "https://example.test/"))
        for _ in 0..<500 {
            let ready = try? await view.evaluateJavaScript("document.readyState==='complete'&&!!document.getElementById('same').contentDocument.querySelector('input[type=password]')")
            if ready as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let raw = try await view.evaluateJavaScript(NativeSafariRuntime.secretRectangles, in: nil, contentWorld: .defaultClient)
        let rects = try XCTUnwrap((raw as? [String: Any])?["rects"] as? [[String: Double]])
        XCTAssertEqual(rects.count, 5, "password, card number by autocomplete, card number by name, the password in the same-site frame, the unreadable frame: \(rects)")
        XCTAssertFalse(rects.contains { $0["y"] == 0 }, "the form and the custom element stay visible")
        XCTAssertTrue(rects.contains { $0["x"] == 350 && $0["y"] == 400 }, "the frame's password sits inside the frame: \(rects)")
        XCTAssertTrue(rects.contains { $0["x"] == 0 && $0["y"] == 700 && $0["width"] == 200 }, "a frame it cannot read stays masked")
    }
}
