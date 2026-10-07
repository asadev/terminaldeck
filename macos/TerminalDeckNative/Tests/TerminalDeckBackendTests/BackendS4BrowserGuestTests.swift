import Foundation
import Testing
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Ports of the TypeScript checks behind browser:bind-new-window and the six terminaldeck-browser:* messages
/// (browser-binding-ipc.ts L1120, browser-tab.ts L1700-1790, browser-annotate.ts, browser-seed-preload.ts,
/// browser-record-preload.ts). The page script's DOM behaviour needs a real WebKit page, so it is covered by
/// the visual walk; here every host-side rule and the script's channel contract are asserted.

@Suite("terminaldeck-browser:* host rules")
struct BackendS4BrowserGuestRulesTests {
    private func path(_ id: String? = "go") -> NativeRPCValue {
        var row: [NativeRPCValue.Field] = [.init("tag", .string("button")), .init("ofTypeCount", .number(1)), .init("nthOfType", .number(1))]
        if let id { row += [.init("id", .string(id)), .init("idUnique", .bool(true))] }
        return .array([.object(row)])
    }
    private func payload(v: Double = 1, text: String = "Go", rect: NativeRPCValue? = nil, attributes: NativeRPCValue = .object([])) -> NativeRPCValue {
        .object([.init("v", .number(v)), .init("path", path()), .init("text", .string(text)), .init("attributes", attributes),
                 .init("rect", rect ?? .object([.init("x", .number(1)), .init("y", .number(2)), .init("width", .number(30)), .init("height", .number(10))]))])
    }

    // browser-tab.ts L1700: only while inspecting, address from the view, parseCapture decides.
    @Test func elementNeedsInspectingAndTheViewsAddress() {
        #expect(BackendS4BrowserGuestRules.element(payload(), inspecting: false, viewURL: "https://x.test/") == nil)
        #expect(BackendS4BrowserGuestRules.element(payload(), inspecting: true, viewURL: nil) == nil)
        #expect(BackendS4BrowserGuestRules.element(payload(v: 2), inspecting: true, viewURL: "https://x.test/") == nil)
        let found = BackendS4BrowserGuestRules.element(payload(), inspecting: true, viewURL: "https://x.test/page")
        #expect(found?.capture.selector == "#go" && found?.capture.url == "https://x.test/page" && found?.capture.label == "Go")
        #expect(found?.context == BackendSharedSelector.composeAgentContext(found!.capture))
        #expect(found?.rect == BackendS4BrowserRect(x: 1, y: 2, width: 30, height: 10))
    }
    // The page can claim any address it likes; only the view's is used.
    @Test func aPagesClaimedURLIsIgnored() {
        let forged = payload().setting("url", .string("https://bank.test/"))
        #expect(BackendS4BrowserGuestRules.element(forged, inspecting: true, viewURL: "https://real.test/")?.capture.url == "https://real.test/")
    }
    // browser-tab.ts readCaptureRect
    @Test func rectNeedsFourFiniteNumbersAndIsClamped() {
        #expect(BackendS4BrowserGuestRules.rect(.null) == nil)
        #expect(BackendS4BrowserGuestRules.rect(.object([.init("x", .number(1)), .init("y", .number(2)), .init("width", .number(3))])) == nil)
        #expect(BackendS4BrowserGuestRules.rect(.object([.init("x", .string("1")), .init("y", .number(2)), .init("width", .number(3)), .init("height", .number(4))])) == nil)
        let wide = BackendS4BrowserGuestRules.rect(.object([.init("x", .number(-9e9)), .init("y", .number(9e9)), .init("width", .number(-5)), .init("height", .number(9e9))]))
        #expect(wide == BackendS4BrowserRect(x: -100_000, y: 100_000, width: 0, height: 100_000))
    }
    // A password field's value never rides along (parseCapture), so the capture cannot leak it.
    @Test func aPasswordFieldsValueIsNotCaptured() {
        let secret = payload(text: "", attributes: .object([.init("type", .string("password")), .init("value", .string("hunter2")), .init("placeholder", .string("Password"))]))
        let found = BackendS4BrowserGuestRules.element(secret, inspecting: true, viewURL: "https://x.test/")
        #expect(found?.capture.attributes["value"] == nil && found?.capture.label == "Password")
    }
    // browser-annotate.ts L51: the asked nonce, the asked view, the top frame.
    @Test func pickedAnswersOnlyTheAskedNonceFromTheAskedTopFrame() {
        let body = NativeRPCValue.object([.init("nonce", .string("n1"))])
        #expect(BackendS4BrowserGuestRules.answeredNonce(body, pending: ["n1"], isMainFrame: true, askedView: true) == "n1")
        #expect(BackendS4BrowserGuestRules.answeredNonce(body, pending: ["n2"], isMainFrame: true, askedView: true) == nil)
        #expect(BackendS4BrowserGuestRules.answeredNonce(body, pending: ["n1"], isMainFrame: false, askedView: true) == nil)
        #expect(BackendS4BrowserGuestRules.answeredNonce(body, pending: ["n1"], isMainFrame: true, askedView: false) == nil)
        #expect(BackendS4BrowserGuestRules.answeredNonce(.object([.init("nonce", .number(1))]), pending: ["1"], isMainFrame: true, askedView: true) == nil)
        #expect(BackendS4BrowserGuestRules.answeredNonce(.object([]), pending: ["n1"], isMainFrame: true, askedView: true) == nil)
    }
    // browser-annotate.ts L80-99
    @Test func pickResultIsNilForNoneAndBuiltFromTheViewsAddress() {
        #expect(BackendS4BrowserGuestRules.pickResult(.object([.init("v", .number(1)), .init("nonce", .string("n")), .init("none", .bool(true))]), viewURL: "https://x.test/") == nil)
        #expect(BackendS4BrowserGuestRules.pickResult(nil, viewURL: "https://x.test/") == nil)
        #expect(BackendS4BrowserGuestRules.pickResult(.object([.init("v", .number(3))]), viewURL: "https://x.test/") == nil)
        let result = BackendS4BrowserGuestRules.pickResult(payload(), viewURL: "https://real.test/p")
        #expect(result?["selector"].string == "#go" && result?["url"].string == "https://real.test/p" && result?["pageImage"].string == "")
        #expect(result?["context"].string?.contains("element `#go`") == true && result?["rect"]["width"].number == 30)
    }
    @Test func pickRequestDividesTheZoomOutAndNeverGoesNegative() {
        let request = BackendS4BrowserGuestRules.pickRequest(x: 300, y: -20, zoom: 2, nonce: "abc")
        #expect(request?["x"].number == 150 && request?["y"].number == 0 && request?["nonce"].string == "abc")
        #expect(BackendS4BrowserGuestRules.pickRequest(x: 10, y: 10, zoom: 0, nonce: "n")?["x"].number == 10)
        #expect(BackendS4BrowserGuestRules.pickRequest(x: .nan, y: 1, zoom: 1, nonce: "n") == nil)
    }
    // browser-tab.ts L1760: top frame only, never an isolated tab, origin from the view.
    @Test func loginReadyUsesTheViewsOriginTopFrameNotIsolated() {
        #expect(BackendS4BrowserGuestRules.loginReadyOrigin(viewURL: "https://app.test/login?x=1", isMainFrame: true, isolated: false) == "https://app.test")
        #expect(BackendS4BrowserGuestRules.loginReadyOrigin(viewURL: "https://app.test/", isMainFrame: false, isolated: false) == nil)
        #expect(BackendS4BrowserGuestRules.loginReadyOrigin(viewURL: "https://app.test/", isMainFrame: true, isolated: true) == nil)
        #expect(BackendS4BrowserGuestRules.loginReadyOrigin(viewURL: nil, isMainFrame: true, isolated: false) == nil)
        #expect(BackendS4BrowserGuestRules.loginReadyOrigin(viewURL: "about:blank", isMainFrame: true, isolated: false) == nil)
    }
    // browser-seed-preload.ts frameOrigin + put()
    @Test func frameOriginIsHttpOnlyAndSeedPairsMustBeStrings() {
        #expect(BackendS4BrowserGuestRules.frameOrigin("https://a.test/x?y#z") == "https://a.test")
        #expect(BackendS4BrowserGuestRules.frameOrigin("http://a.test:8080/") == "http://a.test:8080")
        #expect(BackendS4BrowserGuestRules.frameOrigin("https://a.test:443/") == "https://a.test")
        for bad in ["", "file:///etc/hosts", "data:text/html,x", "javascript:1", "not a url", "about:blank"] { #expect(BackendS4BrowserGuestRules.frameOrigin(bad) == "") }
        #expect(BackendS4BrowserGuestRules.frameOrigin(nil) == "")
        let pairs = NativeRPCValue.array([.array([.string("k"), .string("v")]), .array([.string("only")]), .array([.number(1), .string("v")]), .array([.string("k2"), .number(2)]), .string("x")])
        #expect(BackendS4BrowserGuestRules.seedPairs(pairs) == [["k", "v"]])
        #expect(BackendS4BrowserGuestRules.seedPairs(.null).isEmpty)
    }
    // browser-record-preload.ts: version 1, a known kind, notable keys only, secrets redacted.
    @Test func stepKeepsTheRecorderContract() {
        let click: [String: Any] = ["v": 1, "kind": "click", "target": ["selector": "#go", "tag": "button", "label": "Go", "type": ""]]
        #expect(BackendS4BrowserGuestRules.step(click, viewURL: "https://x.test/", at: 5)?.kind == .click)
        #expect(BackendS4BrowserGuestRules.step(["v": 2, "kind": "click", "target": ["selector": "#go"]], viewURL: "https://x.test/", at: 5) == nil)
        #expect(BackendS4BrowserGuestRules.step(["v": 1, "kind": "press", "key": "a", "target": ["selector": "#go"]], viewURL: "https://x.test/", at: 5) == nil)
        let secret = BackendS4BrowserGuestRules.step(["v": 1, "kind": "type", "secret": true, "value": "hunter2", "target": ["selector": "#pw", "tag": "input", "type": "password"]], viewURL: "https://x.test/", at: 5)
        #expect(secret?.redacted == true && secret?.value == "")
    }
}

@Suite("terminaldeck-browser:* page script contract")
struct BackendS4BrowserGuestScriptTests {
    private let script = BackendS4BrowserGuest.guestScript
    @Test func namesMatchTheElectronChannels() {
        #expect(BackendS4BrowserGuest.element == "terminaldeck-browser:element" && BackendS4BrowserGuest.inspectCancelled == "terminaldeck-browser:inspect-cancelled")
        #expect(BackendS4BrowserGuest.picked == "terminaldeck-browser:picked" && BackendS4BrowserGuest.loginReady == "terminaldeck-browser:login-ready")
        #expect(BackendS4BrowserGuest.seed == "terminaldeck-browser:seed" && BackendS4BrowserGuest.step == "terminaldeck-browser:step")
        for name in [BackendS4BrowserGuest.element, BackendS4BrowserGuest.inspectCancelled, BackendS4BrowserGuest.picked, BackendS4BrowserGuest.loginReady,
                     BackendS4BrowserGuest.setInspect, BackendS4BrowserGuest.pickAt] { #expect(script.contains("\"" + name + "\"")) }
        #expect(BackendS4BrowserGuest.seedScript.contains("terminaldeck-browser:seed"))
    }
    @Test func theScriptIsWebKitNotElectron() {
        for text in [script, BackendS4BrowserGuest.seedScript] { #expect(!text.contains("require('electron')") && !text.contains("ipcRenderer")) }
        #expect(script.contains("window.webkit.messageHandlers") && script.contains("__terminalDeckGuest"))
    }
    // Same payload shape as browser-preload.ts: v:1, path, text, attributes, rect; Esc cancels; secrets never read.
    @Test func payloadShapeAndSafetyMatchTheSource() {
        #expect(script.contains("v: 1,") && script.contains("path: pathFrom(el)") && script.contains("attributes: attributesOf(el)"))
        #expect(script.contains("event.key !== 'Escape'") && script.contains("ipc.send(CH_CANCEL)"))
        #expect(script.contains("isSecretField(el)") && script.contains("none: true"))
        #expect(script.contains("input[type=\"password\"]") && script.contains("window.top !== window") && script.contains("setTimeout(announce, 700)") && script.contains("setTimeout(announce, 2200)"))
        // Sign-in fill/offer stay with the native password feature: nothing here reads or sends a typed password.
        #expect(!script.contains("login-fill") && !script.contains("login-submit") && !script.contains("typed.password"))
        #expect(script.contains("data-terminaldeck-inspector"))
    }
    @Test func theSeedScriptWritesOnlyStringPairsAndIsAskedWithNoArguments() {
        let seed = BackendS4BrowserGuest.seedScript
        #expect(seed.contains("typeof pair[0] !== 'string' || typeof pair[1] !== 'string'") && seed.contains("postMessage(null)"))
        #expect(seed.contains("window.localStorage") && seed.contains("window.sessionStorage"))
    }
}

/// browser:bind-new-window (browser-binding-ipc.ts L1120): a new window, attached to the named session.
@MainActor
final class BackendS4BindNewWindowTests: XCTestCase {
    private let context = NativeRPCContext(caller: .nativeApp, ownerID: "window-1")
    /// The person's browser picker: a principal that manages windows (the shared fixture's resolver does not).
    private func service(_ fixture: BackendDeckCoreTestPortSessionsBrowserFixture) -> BackendBrowserService {
        BackendBrowserService(runtime: fixture.host, bindings: fixture.bindings, resolve: { context in .init(ownerID: context.ownerID, managesWindows: true) },
            resolveSession: { .init(sessionId: $0, machineId: "") }, resolveProfile: { _, _ in .init(id: "default", name: "Default", partition: "persist:default") },
            resolveCreationProfile: { _, _ in .init(id: "default", name: "Default", partition: "persist:default") },
            authorize: { _ in }, publish: { _, _, _ in }, reportEventFailure: { _ in })
    }
    func testNoSessionIdIsASilentNoOp() async throws {
        let fixture = BackendDeckCoreTestPortSessionsBrowserFixture()
        let none = try await service(fixture).bindNewWindow(context, arguments: .object([.init("machineId", .string(""))]))
        XCTAssertEqual(none, .null)
        let empty = try await service(fixture).bindNewWindow(context, arguments: .object([.init("sessionId", .string(""))]))
        XCTAssertEqual(empty, .null)
        XCTAssertTrue(fixture.host.urls.isEmpty)
    }
    func testOpensABlankWindowAttachedToTheSession() async throws {
        let fixture = BackendDeckCoreTestPortSessionsBrowserFixture()
        let answer = try await service(fixture).bindNewWindow(context, arguments: .object([.init("sessionId", .string("s1")), .init("machineId", .string(""))]))
        XCTAssertFalse((answer["window"].string ?? "").isEmpty)
        XCTAssertEqual(fixture.host.urls.count, 1)
        XCTAssertEqual(fixture.host.urls.values.first, "about:blank")
        let id = try XCTUnwrap(fixture.host.urls.keys.first)
        XCTAssertEqual(fixture.bindings.owner(of: id)?.sessionId, "s1")
    }
    func testAWrongMachineIsRefused() async throws {
        let fixture = BackendDeckCoreTestPortSessionsBrowserFixture()
        do { _ = try await service(fixture).bindNewWindow(context, arguments: .object([.init("sessionId", .string("s1")), .init("machineId", .string("other"))])); XCTFail("Bound across machines") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "not-permitted") }
        XCTAssertTrue(fixture.host.urls.isEmpty)
    }
}
