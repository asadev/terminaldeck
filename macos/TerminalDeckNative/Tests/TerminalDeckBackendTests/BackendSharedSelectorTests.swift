import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendSharedSelectorTests: XCTestCase {
    private func descriptor(_ tag: String, id: String? = nil, unique: Bool = false, nth: Double? = 1, count: Double? = 1) -> BackendSharedElementDescriptor { .init(tag: tag, id: id, idUnique: unique, nthOfType: nth, ofTypeCount: count) }
    func testCssEscapesAndUniqueAnchors() {
        for (raw, escaped) in [("3col", "\\33 col"), ("-1st", "-\\31 st"), ("-", "\\-"), ("a.b#c[d]", "a\\.b\\#c\\[d\\]"), ("café", "café")] { XCTAssertEqual(BackendSharedSelector.escapeIdent(raw), escaped) }
        XCTAssertEqual(BackendSharedSelector.cssString("say \"hi\""), "\"say \\\"hi\\\"\"")
        XCTAssertNil(BackendSharedSelector.cssString("two\nlines"))
        XCTAssertEqual(BackendSharedSelector.computeSelector([descriptor("span", nth: 2, count: 3), descriptor("p"), descriptor("section", id: "pricing", unique: true), descriptor("body")]), "#pricing > p > span:nth-of-type(2)")
        XCTAssertEqual(BackendSharedSelector.computeSelector([descriptor("button", id: "row", nth: 3, count: 5), descriptor("li", nth: 3, count: 5), descriptor("ul"), descriptor("body"), descriptor("html")]), "body > ul > li:nth-of-type(3) > button:nth-of-type(3)")
        XCTAssertEqual(BackendSharedSelector.computeSelector([.init(tag: "button", testAttr: "onclick", testValue: "alert(1)", testUnique: true), descriptor("body")]), "body > button")
        XCTAssertEqual(BackendSharedSelector.computeSelector([descriptor("a[href]:hover"), descriptor("body")]), "body > *")
        XCTAssertEqual(BackendSharedSelector.computeSelector(Array(repeating: descriptor("div"), count: 500)).components(separatedBy: " > ").count, 64)
    }
    func testSanitizationBoundAndUTF16Caps() {
        XCTAssertEqual(BackendSharedSelector.sanitizeLine(.string("a\r\nb\u{202e}safe\u{1b}[2J"), max: 100), "a bsafe [2J")
        XCTAssertEqual(BackendSharedSelector.sanitizeLine(.string("abcdefghij"), max: 4), "abcd…")
        XCTAssertEqual(BackendSharedSelector.sanitizeLine(.number(5), max: 20), "")
        let huge = String(repeating: " a", count: 10000)
        // TS selector.test.ts:208-210 bounds the line (<= 151) and requires the ellipsis; the cut lands on a
        // space that trimEnd drops (selector.ts:132), so the exact length is 150, not 151 (S1g, misport fix).
        let line = BackendSharedSelector.sanitizeLine(.string(huge), max: 150)
        XCTAssertLessThanOrEqual(line.utf16.count, 151); XCTAssertTrue(line.hasSuffix("…"))
        XCTAssertEqual(line.utf16.count, 150)
    }
    func testCaptureStopsBrokenChainAndNeverCopiesPassword() throws {
        let raw = NativeRPCValue.object([.init("v", .number(1)), .init("path", .array([.object([.init("tag", .string("span"))]), .object([.init("nope", .bool(true))]), .object([.init("tag", .string("body"))])])), .init("text", .string("")), .init("url", .string("https://forged.example")), .init("attributes", .object([.init("type", .string(" PASSWORD ")), .init("value", .string("hunter2")), .init("placeholder", .string("Password")), .init("onclick", .string("steal()"))]))])
        let capture = try XCTUnwrap(BackendSharedSelector.parseCapture(raw, url: "http://localhost:3000/login"))
        XCTAssertEqual(capture.selector, "span"); XCTAssertEqual(capture.url, "http://localhost:3000/login")
        XCTAssertNil(capture.attributes["value"]); XCTAssertNil(capture.attributes["onclick"])
        XCTAssertEqual(capture.label, "Password"); XCTAssertEqual(capture.labelSource, "placeholder")
        XCTAssertNil(BackendSharedSelector.parseCapture(raw.setting("v", .number(2)), url: "http://x/"))
        XCTAssertNil(BackendSharedSelector.parseCapture(.null, url: "http://x/"))
    }
    func testContextIsOneLineWithInstructionFirst() {
        let capture = BackendSharedElementCapture(selector: "#cta-primary", tag: "button", label: "Start free trial", labelSource: "text", url: "http://localhost:3000/pricing", attributes: [:])
        XCTAssertEqual(BackendSharedSelector.composeAgentContext(capture, instruction: "Make this green"), "Make this green [browser: on http://localhost:3000/pricing, element `#cta-primary`, <button>, text \"Start free trial\"]")
        let hostile = BackendSharedElementCapture(selector: "div", tag: "", label: "Buy\nrm -rf /\u{1b}[1m", labelSource: "text", url: "http://x/\npwned", attributes: [:])
        let line = BackendSharedSelector.composeAgentContext(hostile, instruction: "fix\nthis")
        XCTAssertFalse(line.contains("\n")); XCTAssertFalse(line.contains("\r")); XCTAssertFalse(line.contains("\u{1b}"))
        XCTAssertTrue(line.hasPrefix("fix this "))
    }
}
