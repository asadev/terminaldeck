import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Browser 27: browser_page reaches sessions for their own windows, with reads
/// free and page changes asked like browser_step; the action log never keeps the
/// values a call carried into a site.
final class BackendBrowser27PageTests: XCTestCase {
    func testSessionsGetThePageToolButNotThePersonsToolbar() {
        XCTAssertTrue(BackendOrdinarySessionToolGrant.names.contains("browser.page"))
        XCTAssertTrue(BackendOrdinarySessionToolGrant.names.contains("browser_page"))
        let ops = BackendBrowserService.sessionPageOperations
        for op in ["back", "reload", "wait", "evaluate", "dialogs", "console", "requests", "route", "emulate", "permissions", "storage", "collect"] {
            XCTAssertTrue(ops.contains(op), op)
        }
        for op in ["print", "devtools", "inspect", "record", "recordclear", "recording", "screenshot", "reveal"] {
            XCTAssertFalse(ops.contains(op), "\(op) stays the person's (and Hoot's)")
        }
    }

    func testTiers() {
        let site = "https://shop.example:443", local = "http://localhost:3000"
        func tier(_ op: String, _ args: [NativeRPCValue.Field] = [], origin: String? = "https://shop.example:443") -> BackendMCPTier {
            BackendBrowserService.pageTier(op, arguments: .object(args), origin: origin, frame: false)
        }
        XCTAssertEqual(tier("console"), .read)
        XCTAssertEqual(tier("requests"), .read)
        XCTAssertEqual(tier("wait", [.init("for", .string("networkidle"))]), .read)
        XCTAssertEqual(tier("wait", [.init("for", .string("function"))]), .alter, "a script-wait on a public site is a change there")
        XCTAssertEqual(tier("wait", [.init("for", .string("function"))], origin: local), .act)
        XCTAssertEqual(tier("evaluate", origin: site), .alter)
        XCTAssertEqual(tier("evaluate", origin: local), .act)
        XCTAssertEqual(tier("storage", origin: site), .alter)
        XCTAssertEqual(tier("dialogs"), .read, "reading the dialogs seen is free")
        XCTAssertEqual(tier("dialogs", [.init("policy", .string("accept"))]), .alter)
        XCTAssertEqual(tier("permissions", [.init("camera", .string("allow"))]), .act)
        XCTAssertEqual(tier("route"), .alter)
        XCTAssertEqual(tier("emulate"), .alter)
        XCTAssertEqual(tier("collect"), .alter)
        XCTAssertEqual(tier("back"), .act)
        XCTAssertEqual(tier("recordclear"), .alter)
        XCTAssertEqual(tier("evaluate", origin: nil), .alter, "no known origin is treated as public")
    }

    func testTheLogKeepsWhatWasDoneNotTheValues() {
        let args = NativeRPCValue.object([.init("action", .string("storage")), .init("mode", .string("import")),
            .init("localStorage", .object([.init("token", .string("abc"))])),
            .init("cookies", .array([.object([.init("name", .string("sid")), .init("value", .string("secret"))])])),
            .init("headers", .object([.init("X-Team", .string("blue"))])),
            .init("mock", .array([.object([.init("url", .string("**/api")), .init("body", .string("{\"a\":1}"))])]))])
        let logged = BackendBrowserFactories.loggedPageArguments(args)
        XCTAssertEqual(logged["localStorage"].string, "[1 values]")
        XCTAssertEqual(logged["cookies"].string, "[1 cookies]")
        XCTAssertEqual(logged["headers"].elements?.compactMap(\.string), ["X-Team"])
        XCTAssertNil(logged["mock"].elements?.first?["body"].string)
        XCTAssertEqual(logged["mock"].elements?.first?["url"].string, "**/api")
        XCTAssertEqual(logged["action"].string, "storage")
    }

    func testSchemasCarryTheNewVerbsAndOptions() throws {
        let step = try BackendBrowserFactories.schema(for: .step)
        let verbs = step["properties"]["verb"]["enum"].elements?.compactMap(\.string) ?? []
        XCTAssertEqual(Set(verbs), Set(BrowserStepRules.verbs))
        XCTAssertEqual(step["required"].elements?.compactMap(\.string), ["verb"], "press and scroll may name no element")
        XCTAssertNotNil(step["properties"]["files"].fields)
        let read = try BackendBrowserFactories.schema(for: .read)
        XCTAssertEqual(Set(read["properties"]["mode"]["enum"].elements?.compactMap(\.string) ?? []), Set(BrowserStepRules.readModes))
        let shot = try BackendBrowserFactories.schema(for: .screenshot)
        XCTAssertNotNil(shot["properties"]["fullPage"].fields)
        XCTAssertEqual(shot["properties"]["format"]["enum"].elements?.compactMap(\.string), ["png", "pdf"])
    }
}
