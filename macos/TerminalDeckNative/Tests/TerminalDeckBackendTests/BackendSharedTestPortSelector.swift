import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendSharedTestPortSelector: XCTestCase {
    private func el(_ tag: String, _ id: String? = nil, unique: Bool = false, nth: Double = 1, count: Double = 1) -> BackendSharedElementDescriptor { .init(tag: tag, id: id, idUnique: unique, nthOfType: nth, ofTypeCount: count) }
    func testEveryEscapeStringExpectation() {
        for text in ["cta-primary", "save_button2", "café"] { XCTAssertEqual(BackendSharedSelector.escapeIdent(text), text) }
        XCTAssertEqual(BackendSharedSelector.escapeIdent("a b"), "a\\ b")
        XCTAssertEqual(BackendSharedSelector.escapeIdent("x\"]:hover"), "x\\\"\\]\\:hover")
        XCTAssertEqual(BackendSharedSelector.cssString("hello"), "\"hello\"")
        XCTAssertEqual(BackendSharedSelector.cssString("back\\slash"), "\"back\\\\slash\"")
    }
    func testEverySelectorFallbackAndAnchor() {
        let body = el("body"), html = el("html")
        XCTAssertEqual(BackendSharedSelector.computeSelector([el("button", "cta", unique: true), el("div"), body, html]), "#cta")
        let test = BackendSharedElementDescriptor(tag: "button", id: "row", testAttr: "data-testid", testValue: "row-delete", testUnique: true)
        XCTAssertEqual(BackendSharedSelector.computeSelector([test, body, html]), "[data-testid=\"row-delete\"]")
        XCTAssertEqual(BackendSharedSelector.computeSelector([el("div", "3col", unique: true), body]), "#\\33 col")
        let ancestor = BackendSharedElementDescriptor(tag: "button", testAttr: "data-cy", testValue: "close", testUnique: true)
        XCTAssertEqual(BackendSharedSelector.computeSelector([el("svg"), ancestor, body]), "[data-cy=\"close\"] > svg")
        XCTAssertEqual(BackendSharedSelector.computeSelector([el("span"), el("div", nth: 2, count: 4), body, html]), "body > div:nth-of-type(2) > span")
        XCTAssertEqual(BackendSharedSelector.computeSelector([el("div"), html]), "div")
        XCTAssertEqual(BackendSharedSelector.computeSelector([el("td", nth: 2, count: 2), el("tr"), body]), "body > tr > td:nth-of-type(2)")
        XCTAssertEqual(BackendSharedSelector.computeSelector([el("clipPath"), el("svg"), body]), "body > svg > clipPath")
        XCTAssertEqual(BackendSharedSelector.computeSelector([el("div", "a\nb", unique: true), body]), "body > div")
        XCTAssertEqual(BackendSharedSelector.computeSelector([]), "")
    }
    func testEveryLineSanitizerExampleAndBoundedPrefix() {
        for (raw, expected) in [("first\nsecond", "first second"), ("a\r\nb", "a b"), ("\u{1b}]0;pwned\u{7}hello", "]0;pwned hello"), ("\u{1b}[2Jwiped", "[2Jwiped"), ("safe\u{202e}degrofnu", "safedegrofnu")] { XCTAssertEqual(BackendSharedSelector.sanitizeLine(.string(raw), max: 100), expected) }
        XCTAssertEqual(BackendSharedSelector.sanitizeLine(.missing, max: 10), "")
        XCTAssertEqual(BackendSharedSelector.sanitizeLine(.object([.init("toString", .string("nope"))]), max: 10), "")
        let bounded = BackendSharedSelector.sanitizeLine(.string(String(repeating: " a", count: 8192)), max: 150)
        XCTAssertLessThanOrEqual(bounded.utf16.count, 151); XCTAssertTrue(bounded.hasSuffix("…"))
        // Faked adversarial input, no wall-clock measurement. A tail beyond
        // scanLimit must stay unread even when the head is all whitespace.
        XCTAssertEqual(BackendSharedSelector.sanitizeLine(.string(String(repeating: " ", count: 150 * 32 + 1024) + "unread tail"), max: 150), "")
    }
    private func good() -> NativeRPCValue {
        .object([.init("v", .number(1)), .init("path", .array([.object([.init("tag", .string("button")), .init("id", .string("buy")), .init("idUnique", .bool(true)), .init("nthOfType", .number(1)), .init("ofTypeCount", .number(1))]), .object([.init("tag", .string("body")), .init("nthOfType", .number(1)), .init("ofTypeCount", .number(1))])])), .init("text", .string("Start free trial")), .init("attributes", .object([.init("aria-label", .string("Buy now")), .init("type", .string("submit"))]))])
    }
    func testEveryCapturePayloadAndLabelSource() throws {
        let valid = try XCTUnwrap(BackendSharedSelector.parseCapture(good(), url: "http://localhost:3000/pricing"))
        XCTAssertEqual(valid.selector, "#buy"); XCTAssertEqual(valid.tag, "button"); XCTAssertEqual(valid.label, "Start free trial"); XCTAssertEqual(valid.labelSource, "text"); XCTAssertEqual(valid.url, "http://localhost:3000/pricing")
        XCTAssertEqual(valid.attributes, ["aria-label": "Buy now", "type": "submit"])
        let aria = good().setting("text", .string("")).setting("attributes", .object([.init("aria-label", .string("Close dialog"))]))
        XCTAssertEqual(BackendSharedSelector.parseCapture(aria, url: "http://localhost:3000/")?.label, "Close dialog")
        XCTAssertEqual(BackendSharedSelector.parseCapture(aria, url: "http://localhost:3000/")?.labelSource, "aria-label")
        let forged = good().setting("url", .string("https://bank.example.com"))
        XCTAssertEqual(BackendSharedSelector.parseCapture(forged, url: "http://localhost:3000/")?.url, "http://localhost:3000/")
        let allowed = good().setting("attributes", .object([.init("onclick", .string("steal()")), .init("__proto__", .object([.init("polluted", .bool(true))])), .init("alt", .string("ok"))]))
        XCTAssertEqual(BackendSharedSelector.parseCapture(allowed, url: "http://x/")?.attributes, ["alt": "ok"])
        for bad in [NativeRPCValue.null, .string("nope"), .object([.init("v", .number(2)), .init("path", .array([.object([.init("tag", .string("div"))])]))]), .object([.init("v", .number(1)), .init("path", .array([]))]), .object([.init("v", .number(1)), .init("path", .array([.object([.init("nope", .bool(true))])]))])] { XCTAssertNil(BackendSharedSelector.parseCapture(bad, url: "http://x/")) }
        let ordinary = good().setting("text", .string("")).setting("attributes", .object([.init("type", .string("email")), .init("value", .string("asad@example.com"))]))
        XCTAssertEqual(BackendSharedSelector.parseCapture(ordinary, url: "http://localhost:3000/login")?.attributes["value"], "asad@example.com")
        XCTAssertEqual(BackendSharedSelector.parseCapture(ordinary, url: "http://localhost:3000/login")?.labelSource, "value")
        let password = good().setting("text", .string("")).setting("attributes", .object([.init("type", .string("password")), .init("value", .string("hunter2")), .init("placeholder", .string("Password"))]))
        let withheld = try XCTUnwrap(BackendSharedSelector.parseCapture(password, url: "http://localhost:3000/login"))
        XCTAssertEqual(withheld.attributes, ["type": "password", "placeholder": "Password"]); XCTAssertEqual(withheld.label, "Password")
        XCTAssertFalse(String(describing: withheld).contains("hunter2"))
        let hostile = NativeRPCValue.object([.init("v", .number(1)), .init("path", .array([.object([.init("tag", .string("div")), .init("nthOfType", .number(-5)), .init("ofTypeCount", .number(.nan)), .init("idUnique", .string("yes"))])])), .init("text", .number(12345)), .init("attributes", .string("not-an-object"))])
        let safe = try XCTUnwrap(BackendSharedSelector.parseCapture(hostile, url: "http://localhost:3000/"))
        XCTAssertEqual(safe.selector, "div"); XCTAssertEqual(safe.label, ""); XCTAssertEqual(safe.attributes, [:])
    }
    func testEveryContextOmissionAndAlternateLabel() {
        let capture = BackendSharedElementCapture(selector: "#cta-primary", tag: "button", label: "Start free trial", labelSource: "text", url: "http://localhost:3000/pricing", attributes: [:])
        XCTAssertEqual(BackendSharedSelector.composeAgentContext(capture), "[browser: on http://localhost:3000/pricing, element `#cta-primary`, <button>, text \"Start free trial\"]")
        let icon = BackendSharedElementCapture(selector: capture.selector, tag: capture.tag, label: "Close", labelSource: "aria-label", url: capture.url, attributes: [:])
        XCTAssertTrue(BackendSharedSelector.composeAgentContext(icon).contains("aria-label \"Close\""))
        let bare = BackendSharedElementCapture(selector: "body > div", tag: "", label: "", labelSource: "none", url: "", attributes: [:])
        XCTAssertEqual(BackendSharedSelector.composeAgentContext(bare), "[browser: element `body > div`]")
    }
}
