import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// browser-control.test.ts case ports. All browser, process and time work is fake.
@MainActor
final class BackendRemoteServeBrowserPortTests: XCTestCase {
    private func notice(_ answer: NativeRPCValue) -> String { answer["notice"].string ?? "" }
    private func rows(_ answer: NativeRPCValue) throws -> [NativeRPCValue] {
        XCTAssertEqual(answer["t"].string, "browser.window.rows"); return try XCTUnwrap(answer["windows"].elements)
    }
    private func row(_ answer: NativeRPCValue, _ id: String) throws -> NativeRPCValue { try XCTUnwrap(try rows(answer).first { $0["id"].string == id }) }
    private func rig(_ title: String = "Stripe", _ url: String = "https://stripe.com/") -> BackendRemoteServeBrowserPortRig {
        let rig = BackendRemoteServeBrowserPortRig(); rig.add(.init(id: "w1", title: title, url: url)); return rig
    }
    private func session(_ rig: BackendRemoteServeBrowserPortRig) { rig.hostSessions = [.init(id: "s1", title: "Session 1")] }
    private func bind(_ rig: BackendRemoteServeBrowserPortRig, id: String = "w1") async -> NativeRPCValue { await rig.answer("browser.window.bind", [.init("id", .string(id)), .init("session", .string("s1"))]) }
    private func act(_ rig: BackendRemoteServeBrowserPortRig, _ action: String, id: String = "w1") async -> NativeRPCValue { await rig.answer("browser.window.act", [.init("id", .string(id)), .init("action", .string(action))]) }
    private func pick(_ rig: BackendRemoteServeBrowserPortRig, id: String = "w1", x: Double = 1, y: Double = 1, up: Int? = nil) async -> NativeRPCValue {
        var fields: [NativeRPCValue.Field] = [.init("id", .string(id)), .init("x", .number(x)), .init("y", .number(y))]
        if let up { fields.append(.init("up", .number(Double(up)))) }; return await rig.answer("browser.window.pick", fields)
    }

    func testListsWindowPageFactsAndSessionCountWithNoNotice() async throws {
        let rig = BackendRemoteServeBrowserPortRig()
        rig.add(.init(id: "w1", title: "Example Domain", url: "https://example.com/", loading: true))
        rig.hostSessions = [.init(id: "s1", title: "terminaldeck · Session 1")]
        let answer = await rig.answer("browser.windows")
        XCTAssertEqual(try rows(answer), [.object([.init("id", .string("w1")), .init("title", .string("Example Domain")), .init("url", .string("https://example.com/")), .init("loading", .bool(true))])])
        XCTAssertEqual(notice(answer), "")
        XCTAssertEqual(answer["sessions"], .array([.object([.init("id", .string("s1")), .init("title", .string("terminaldeck · Session 1")), .init("windows", .number(0))])]))
    }
    func testGoogleHardSignInRefusalNamesPracticalAlternatives() async {
        let answer = await rig("Sign in - Google Accounts", "https://accounts.google.com/v3/signin/rejected?dsh=1").answer("browser.windows")
        XCTAssertTrue(notice(answer).contains("Google will not sign in in this machine's browser")); XCTAssertTrue(notice(answer).contains("already signed in"))
    }
    func testOrdinaryAndRestrictedGoogleWindowsStaySilent() async {
        let rig = rig("Example", "https://example.com/"); rig.add(.init(id: "w2", title: "Sign in", url: "https://accounts.google.com/v3/signin/identifier?flowName=GeneralOAuthLite"))
        let answer = await rig.answer("browser.windows"); XCTAssertEqual(notice(answer), "")
    }
    func testBoundRowsCarrySlotSessionTitleAndSharedSessionCount() async throws {
        let rig = rig(); rig.hostSessions = [.init(id: "s1", title: "terminaldeck · Session 1")]
        _ = try rig.bindings.attach("w1", to: .init(sessionId: "s1"))
        let answer = await rig.answer("browser.windows"), bound = try row(answer, "w1")
        XCTAssertEqual(bound["slot"].string, "B1"); XCTAssertEqual(bound["session"].string, "s1"); XCTAssertEqual(bound["sessionTitle"].string, "terminaldeck · Session 1")
        XCTAssertEqual(answer["sessions"].elements?.first?["windows"].number, 1)
    }
    func testWindowListTruncationHasExactNotice() async throws {
        let rig = BackendRemoteServeBrowserPortRig()
        for index in 0..<41 { rig.add(.init(id: "w\(index)", title: "Window \(index)", url: "https://example.com/")) }
        let answer = await rig.answer("browser.windows"); XCTAssertEqual(try rows(answer).count, BackendRemoteServeBrowserLimits.windowRows)
        XCTAssertEqual(notice(answer), "Listing 32 of 41 windows.")
    }
    func testLongTitleKeepsEllipsisAndURLHasLongerBudget() async throws {
        let rig = rig(String(repeating: "T", count: 400), "https://example.com/" + String(repeating: "a", count: 400))
        let answer = await rig.answer("browser.windows"), listed = try row(answer, "w1")
        XCTAssertEqual(listed["title"].string?.utf16.count, BackendRemoteServeBrowserLimits.rowText + 1)
        XCTAssertTrue(listed["title"].string?.hasSuffix("…") == true)
        XCTAssertGreaterThan(listed["url"].string?.utf16.count ?? 0, BackendRemoteServeBrowserLimits.rowText)
    }
    func testExitedSessionRetainsPickerRowAndSuffix() async {
        let rig = BackendRemoteServeBrowserPortRig(); rig.hostSessions = [.init(id: "s1", title: "terminaldeck · Session 1", ended: true)]
        let answer = await rig.answer("browser.windows"); XCTAssertEqual(answer["sessions"].elements?.first?["title"].string, "terminaldeck · Session 1 (exited)")
    }
    func testOpeningRedrawsNewWindowWithoutChoosingASession() async throws {
        let rig = BackendRemoteServeBrowserPortRig(), answer = await rig.answer("browser.window.open", [.init("url", .string("https://example.com/"))])
        let windows = try rows(answer); XCTAssertEqual(windows.count, 1); XCTAssertEqual(windows[0]["url"].string, "https://example.com/")
        XCTAssertEqual(notice(answer), "Opened a window."); XCTAssertFalse(windows[0].has("slot"))
    }
    func testOpeningIsolationCarriesFlagAndKindNotice() async throws {
        let rig = BackendRemoteServeBrowserPortRig(), answer = await rig.answer("browser.window.open", [.init("url", .string("https://example.com/")), .init("isolated", .bool(true))])
        XCTAssertEqual(try rows(answer).first?["isolated"].bool, true); XCTAssertEqual(notice(answer), "Opened an isolated window.")
    }
    func testNavigationUpdatesURLAndRecordsExactMove() async throws {
        let rig = rig("", "https://example.com/")
        let answer = await rig.answer("browser.window.go", [.init("id", .string("w1")), .init("url", .string("https://example.com/pricing"))])
        XCTAssertEqual(rig.did, ["go w1 https://example.com/pricing"]); XCTAssertEqual(try row(answer, "w1")["url"].string, "https://example.com/pricing")
    }
    func testBackForwardReloadAlwaysRedraw() async throws {
        let rig = rig("", "https://example.com/")
        for action in ["back", "forward", "reload"] { let answer = await act(rig, action); XCTAssertEqual(try rows(answer).count, 1) }
        XCTAssertEqual(rig.did, ["back w1", "forward w1", "reload w1"])
    }
    func testClosingAlsoReleasesSharedBinding() async throws {
        let rig = rig(); session(rig); _ = try rig.bindings.attach("w1", to: .init(sessionId: "s1")); XCTAssertEqual(rig.held("s1").count, 1)
        let answer = await act(rig, "close"); XCTAssertEqual(try rows(answer), []); XCTAssertEqual(notice(answer), "Closed Stripe."); XCTAssertEqual(rig.held("s1"), [])
    }
    func testActingOnGoneWindowHasNoSideEffects() async {
        let rig = BackendRemoteServeBrowserPortRig(), answer = await act(rig, "reload", id: "ghost")
        XCTAssertEqual(notice(answer), "That window is not open any more."); XCTAssertEqual(rig.did, [])
    }
    func testBindingMintsB1AndKeepsTheDrivingView() async throws {
        let rig = BackendRemoteServeBrowserPortRig(); rig.add(.init(id: "w1", title: "Stripe", url: "https://stripe.com/", viewID: "view-1")); session(rig)
        let answer = await bind(rig), bound = try row(answer, "w1")
        XCTAssertEqual(notice(answer), "Stripe is B1 in Session 1.")
        XCTAssertEqual(bound["slot"].string, "B1"); XCTAssertEqual(bound["session"].string, "s1"); XCTAssertEqual(bound["sessionTitle"].string, "Session 1")
        XCTAssertEqual(rig.held("s1").first?.n, 1); XCTAssertEqual(rig.held("s1").first?.tabID, "w1"); XCTAssertEqual(rig.bindings.window("w1")?.viewID, "view-1")
    }
    func testUnbindingRemovesSlotButLeavesPageOpen() async throws {
        let rig = rig(); session(rig); _ = await bind(rig)
        let answer = await rig.answer("browser.window.bind", [.init("id", .string("w1"))]), after = try row(answer, "w1")
        XCTAssertEqual(notice(answer), "Stripe is no longer attached to a session.")
        XCTAssertFalse(after.has("slot")); XCTAssertFalse(after.has("session")); XCTAssertEqual(try rows(answer).count, 1); XCTAssertEqual(rig.held("s1"), [])
    }
    func testSecondBoundWindowUsesB2() async throws {
        let rig = rig("One", "https://one.example/"); rig.add(.init(id: "w2", title: "Two", url: "https://two.example/")); session(rig)
        _ = await bind(rig); let answer = await bind(rig, id: "w2")
        XCTAssertEqual(try row(answer, "w1")["slot"].string, "B1"); XCTAssertEqual(try row(answer, "w2")["slot"].string, "B2")
    }
    func testBindingUnknownSessionRefusesWithoutSlot() async throws {
        let rig = rig(), answer = await rig.answer("browser.window.bind", [.init("id", .string("w1")), .init("session", .string("from-an-old-transcript"))])
        XCTAssertEqual(notice(answer), "No session by that name is running here."); XCTAssertFalse(try row(answer, "w1").has("slot"))
    }
    func testOpenAndAttachUsesBindNoticeAndTheExactCreatedWindow() async throws {
        let rig = BackendRemoteServeBrowserPortRig(); session(rig)
        let answer = await rig.answer("browser.window.open", [.init("url", .string("http://localhost:3000/admin")), .init("session", .string("s1"))])
        let windows = try rows(answer); XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0]["slot"].string, "B1"); XCTAssertEqual(windows[0]["session"].string, "s1"); XCTAssertEqual(windows[0]["sessionTitle"].string, "Session 1")
        XCTAssertEqual(notice(answer), "http://localhost:3000/admin is B1 in Session 1.")
        XCTAssertEqual(rig.held("s1").first?.tabID, windows[0]["id"].string); XCTAssertEqual(rig.held("s1").first?.n, 1)
    }
    func testOpenAndAttachCarriesTheNewDrivingView() async throws {
        let rig = BackendRemoteServeBrowserPortRig(); session(rig)
        let answer = await rig.answer("browser.window.open", [.init("url", .string("https://example.com/")), .init("session", .string("s1"))])
        let id = try XCTUnwrap(try rows(answer).first?["id"].string); XCTAssertEqual(rig.bindings.window(id)?.viewID, "view-\(id)")
    }
    func testSecondOpenAndAttachAlsoUsesB2() async throws {
        let rig = BackendRemoteServeBrowserPortRig(); session(rig)
        _ = await rig.answer("browser.window.open", [.init("url", .string("https://one.example/")), .init("session", .string("s1"))])
        let answer = await rig.answer("browser.window.open", [.init("url", .string("https://two.example/")), .init("session", .string("s1"))])
        XCTAssertEqual(try rows(answer).map { $0["slot"].string }, ["B1", "B2"])
    }
    func testUnknownSessionPreventsOpeningAnything() async throws {
        let rig = BackendRemoteServeBrowserPortRig(), answer = await rig.answer("browser.window.open", [.init("url", .string("https://example.com/")), .init("session", .string("from-an-old-transcript"))])
        XCTAssertEqual(notice(answer), "No session by that name is running here."); XCTAssertEqual(try rows(answer), [])
    }
    func testNoSessionOpenDoesNotChooseTheOnlyListedSession() async throws {
        let rig = BackendRemoteServeBrowserPortRig(); session(rig)
        let answer = await rig.answer("browser.window.open", [.init("url", .string("https://example.com/"))])
        XCTAssertEqual(notice(answer), "Opened a window."); XCTAssertFalse(try rows(answer)[0].has("slot")); XCTAssertEqual(rig.held("s1"), [])
    }
    func testIsolatedOpenCanAttachAndUsesBindNotice() async throws {
        let rig = BackendRemoteServeBrowserPortRig(); session(rig)
        let answer = await rig.answer("browser.window.open", [.init("url", .string("https://example.com/")), .init("isolated", .bool(true)), .init("session", .string("s1"))])
        XCTAssertEqual(try rows(answer)[0]["isolated"].bool, true); XCTAssertEqual(try rows(answer)[0]["slot"].string, "B1")
        XCTAssertEqual(notice(answer), "https://example.com/ is B1 in Session 1.")
    }
    func testPickedElementCarriesTrustedHostURLAndOriginalPoint() async {
        let rig = rig("Admin", "http://localhost:3000/admin"), answer = await pick(rig, x: 120, y: 1200)
        XCTAssertEqual(answer, .object([.init("t", .string("browser.window.picked")), .init("id", .string("w1")), .init("tag", .string("button")), .init("selector", .string("#save")), .init("label", .string("Save changes")), .init("labelSource", .string("text")), .init("url", .string("http://localhost:3000/admin")), .init("rect", .object([.init("x", .number(24)), .init("y", .number(1180)), .init("w", .number(128)), .init("h", .number(40))])), .init("depth", .number(0)), .init("maxUp", .number(6))]))
        XCTAssertEqual(rig.pickedAt, [.init(id: "w1", x: 120, y: 1200, up: 0)])
    }
    func testWiderAncestorCountCrossesUnchanged() async {
        let rig = rig("", "https://example.com/"); _ = await pick(rig, x: 8, y: 8, up: 3)
        XCTAssertEqual(rig.pickedAt, [.init(id: "w1", x: 8, y: 8, up: 3)])
    }
    func testPickedPasswordHasLabelAndNeverAValueField() async {
        let rig = rig("", "https://bank.example/")
        rig.picked = .init(found: true, tag: "input", selector: "#password", label: "Password", labelSource: "label", x: 0, y: 0, width: 240, height: 32, depth: 0, maxUp: 4)
        let answer = await pick(rig, x: 10, y: 10); XCTAssertEqual(answer["t"].string, "browser.window.picked"); XCTAssertEqual(answer["label"].string, "Password"); XCTAssertFalse(answer.has("value"))
    }
    func testLongSelectorUsesDriveBudgetAndEllipsis() async {
        let rig = rig("", "https://example.com/"); rig.picked = .init(found: true, selector: "#" + String(repeating: "a", count: 600))
        let answer = await pick(rig); XCTAssertEqual(answer["t"].string, "browser.window.picked")
        XCTAssertEqual(answer["selector"].string?.utf16.count, BackendRemoteServeBrowserLimits.pickSelector + 1)
        XCTAssertTrue(answer["selector"].string?.hasSuffix("…") == true); XCTAssertGreaterThan(answer["selector"].string?.utf16.count ?? 0, BackendRemoteServeBrowserLimits.rowText)
    }
    func testPickedGeometryIsFiniteAndAncestorCountsAreWholeAndNonnegative() async {
        let rig = rig("", "https://example.com/"); rig.picked = .init(found: true, x: .nan, y: 12, width: .infinity, height: 40, depth: -3, maxUp: 2.7)
        let answer = await pick(rig); XCTAssertEqual(answer["t"].string, "browser.window.picked")
        XCTAssertEqual(answer["rect"], .object([.init("x", .number(0)), .init("y", .number(12)), .init("w", .number(0)), .init("h", .number(40))]))
        XCTAssertEqual(answer["depth"].number, 0); XCTAssertEqual(answer["maxUp"].number, 2)
    }
    func testScrolledPageAndEmptySpotHaveDifferentActionableNotices() async {
        let rig = rig("Admin", "http://localhost:3000/admin"); rig.picked = .init(found: false, moved: true)
        let moved = await pick(rig, y: 90_000); XCTAssertEqual(notice(moved), "Admin has scrolled since that picture — tap the same thing again.")
        rig.picked = .init(found: false, moved: false)
        let empty = await pick(rig); XCTAssertEqual(notice(empty), "There is nothing at that spot on Admin.")
    }
    func testGoneWindowDoesNotReachPicker() async {
        let rig = BackendRemoteServeBrowserPortRig(), answer = await pick(rig, id: "ghost")
        XCTAssertEqual(notice(answer), "That window is not open any more."); XCTAssertEqual(rig.pickedAt, [])
    }
    func testAbsentPickerHasExplicitCapabilityNotice() async {
        let rig = rig("", "https://example.com/"); rig.without.insert("pick")
        let answer = await pick(rig); XCTAssertEqual(notice(answer), "This machine's browser cannot point at one thing on a page.")
    }
    func testPickerFailureStillRedrawsWindowWithExactReason() async throws {
        let rig = rig("Admin", "http://localhost:3000/admin"); rig.breaks.insert("pick")
        let answer = await pick(rig); XCTAssertEqual(notice(answer), "Admin could not be looked at: the pick dep is unwell."); XCTAssertEqual(try rows(answer).count, 1)
    }
    func testIsolationRoundTripKeepsWindowIDSlotAndUpdatesDrivingView() async throws {
        let rig = BackendRemoteServeBrowserPortRig(); rig.add(.init(id: "w1", title: "Stripe", url: "https://stripe.com/", viewID: "view-1")); session(rig); _ = await bind(rig)
        let isolated = await act(rig, "isolate"); XCTAssertEqual(notice(isolated), "Stripe is isolated."); XCTAssertEqual(try row(isolated, "w1")["isolated"].bool, true)
        XCTAssertEqual(try row(isolated, "w1")["slot"].string, "B1"); XCTAssertEqual(rig.held("s1").first?.n, 1); XCTAssertEqual(rig.bindings.window("w1")?.viewID, "view-w1-iso")
        let shared = await act(rig, "share"); XCTAssertEqual(notice(shared), "Stripe is shared."); XCTAssertFalse(try row(shared, "w1").has("isolated"))
        XCTAssertEqual(try row(shared, "w1")["slot"].string, "B1"); XCTAssertEqual(rig.held("s1").first?.n, 1); XCTAssertEqual(rig.bindings.window("w1")?.viewID, "view-w1-shared")
    }
    func testAlreadyIsolatedWindowDoesNothing() async {
        let rig = BackendRemoteServeBrowserPortRig(); rig.add(.init(id: "w1", title: "Stripe", url: "https://stripe.com/", isolated: true))
        let answer = await act(rig, "isolate"); XCTAssertEqual(notice(answer), "Stripe is already isolated."); XCTAssertEqual(rig.did, [])
    }
    func testMissingSecondCookieJarHasExactNotice() async {
        let rig = rig(); rig.without.insert("repartition"); let answer = await act(rig, "isolate")
        XCTAssertEqual(notice(answer), "This machine's browser has one cookie jar and cannot isolate a window.")
    }
    func testScreenshotPreviewReturnsWholePNGWithFakeClockAndNoTyping() async {
        let rig = rig(), answer = await rig.answer("browser.window.shot", [.init("id", .string("w1"))])
        XCTAssertEqual(answer["t"].string, "browser.shot"); XCTAssertEqual(answer["id"].string, "w1")
        XCTAssertEqual(Data(base64Encoded: answer["png"].string ?? ""), BackendRemoteServeBrowserPortRig.png)
        XCTAssertEqual(answer["at"].number, 1_700_000_000_000); XCTAssertEqual(rig.typed, [])
    }
    func testScreenshotToSessionTypesExactCaptionThenBareReturn() async {
        let rig = rig("Stripe", "https://stripe.com/pricing"); session(rig)
        let answer = await rig.answer("browser.window.shot", [.init("id", .string("w1")), .init("session", .string("s1")), .init("note", .string("the header is wrong here"))])
        XCTAssertEqual(answer["t"].string, "browser.window.rows"); XCTAssertEqual(notice(answer), "Sent Stripe to Session 1.")
        XCTAssertEqual(rig.typed.count, 2); XCTAssertEqual(rig.typed.first?.session, "s1")
        XCTAssertEqual(rig.typed[1], .init(session: "s1", data: "\r"))
        XCTAssertEqual(rig.typed[0].data, "the header is wrong here [browser screenshot of https://stripe.com/pricing: /Pictures/Terminal Deck/example.com-20260823-120000.png (1280 x 800)]")
        XCTAssertEqual(rig.waited, [50]); XCTAssertFalse(answer.has("png"))
    }
    func testOversizeScreenshotNamesSizeCeilingPathAndAlternateRoute() async {
        let rig = rig(); rig.shot = .init(path: BackendRemoteServeBrowserPortRig.shotPath, width: 1280, height: 800, preview: Data(repeating: 0, count: BackendRemoteServeBrowserLimits.shotBytes + 1024))
        let answer = await rig.answer("browser.window.shot", [.init("id", .string("w1"))]); XCTAssertEqual(answer["t"].string, "browser.window.rows")
        XCTAssertTrue(notice(answer).contains("48 KB, over the 47 KB this link carries")); XCTAssertTrue(notice(answer).contains("example.com-20260823-120000.png")); XCTAssertTrue(notice(answer).contains("send it to a session instead"))
    }
    func testUnknownScreenshotSessionIsRefusedBeforeCapture() async {
        let rig = rig(), answer = await rig.answer("browser.window.shot", [.init("id", .string("w1")), .init("session", .string("from-an-old-transcript"))])
        XCTAssertEqual(notice(answer), "No session by that name is running here."); XCTAssertEqual(rig.did, [])
    }
    func testScreenshotCaptionMatchesRendererContractAndFoldsNewlines() throws {
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<5 { root.deleteLastPathComponent() }
        let source = try String(contentsOf: root.appendingPathComponent("src/renderer/browser/ScreenshotPopup.tsx"), encoding: .utf8)
        XCTAssertTrue(source.contains("`[browser screenshot")); XCTAssertTrue(source.contains("` of ${")); XCTAssertTrue(source.contains("(${shot.width} x ${shot.height})]`"))
        XCTAssertEqual(BackendRemoteServeBrowserText.shotLine(.init(path: "/p/shot.png", width: 1280, height: 800, preview: Data()), url: "https://stripe.com/", note: ""), "[browser screenshot of https://stripe.com/: /p/shot.png (1280 x 800)]")
        XCTAssertEqual(BackendRemoteServeBrowserText.shotLine(.init(path: "/p/shot.png", width: 1, height: 1, preview: Data()), url: "", note: "look\nat this"), "look at this [browser screenshot: /p/shot.png (1 x 1)]")
    }
    func testRecorderOnListsExactDescriptionsRedactsPasswordAndTurnsOff() async throws {
        let rig = rig(); rig.steps = [rig.step(kind: .navigate, selector: "", label: "", tag: "", url: "https://stripe.com/"), rig.step(), rig.step(kind: .type, selector: "#password", label: "Password", value: "hunter2", redacted: true)]
        let on = await act(rig, "record.on"); XCTAssertEqual(notice(on), "Recording Stripe."); XCTAssertEqual(try row(on, "w1")["recording"].bool, true)
        let listed = await rig.answer("browser.window.steps", [.init("id", .string("w1"))]); XCTAssertEqual(listed["t"].string, "browser.record.rows"); XCTAssertEqual(listed["id"].string, "w1")
        let steps = try XCTUnwrap(listed["steps"].elements); XCTAssertEqual(steps.map { $0["kind"].string }, ["navigate", "click", "type"])
        XCTAssertEqual(steps[1]["detail"].string, "Click \"Sign in\" (`#submit`)"); XCTAssertEqual(steps[2]["detail"].string, "Type the password into \"Password\" (`#password`)"); XCTAssertFalse(steps[2].has("value"))
        let off = await act(rig, "record.off"); XCTAssertEqual(notice(off), "Stopped recording Stripe."); XCTAssertFalse(try row(off, "w1").has("recording"))
    }
    func testRecorderTruncationKeepsFirst60AndReportsSevenMore() async throws {
        let rig = rig(); rig.steps = (0..<67).map { rig.step(at: 1_700_000_000_000 + Double($0)) }
        let answer = await rig.answer("browser.window.steps", [.init("id", .string("w1"))]); XCTAssertEqual(answer["t"].string, "browser.record.rows")
        let steps = try XCTUnwrap(answer["steps"].elements); XCTAssertEqual(steps.count, BackendRemoteServeBrowserLimits.wireSteps + 1)
        XCTAssertEqual(steps[60]["kind"].string, "truncated"); XCTAssertEqual(steps[60]["detail"].string, "7 more steps recorded — the whole flow is on this machine.")
        XCTAssertEqual(steps[0]["at"].number, 1_700_000_000_000)
    }
    func testAbsentRecorderRefusesActAndRead() async {
        let rig = rig(); rig.without.insert("recorder")
        let acted = await act(rig, "record.on"), asked = await rig.answer("browser.window.steps", [.init("id", .string("w1"))])
        XCTAssertEqual(notice(acted), "This machine's browser cannot record a click flow."); XCTAssertEqual(asked["t"].string, "browser.window.rows"); XCTAssertEqual(notice(asked), "This machine's browser cannot record a click flow.")
    }
    func testListDependencyFailureIsAnEmptyScreenWithReason() async throws {
        let rig = BackendRemoteServeBrowserPortRig(); rig.breaks.insert("list"); let answer = await rig.answer("browser.windows")
        XCTAssertEqual(try rows(answer), []); XCTAssertEqual(notice(answer), "This machine's browser could not be listed: the list dep is unwell.")
    }
    func testCaptureDependencyFailureReturnsRowsRatherThanPixels() async {
        let rig = rig(); rig.breaks.insert("capture"); let answer = await rig.answer("browser.window.shot", [.init("id", .string("w1"))])
        XCTAssertEqual(answer["t"].string, "browser.window.rows"); XCTAssertEqual(notice(answer), "Stripe could not be photographed: the capture dep is unwell.")
    }
    func testOpenNilPassesThroughTheDependencyOwnWords() async {
        // The Chromium text is an opaque fake reason, not a Chrome dependency.
        let rig = BackendRemoteServeBrowserPortRig(); rig.openReturnsNil = true; rig.openReason = "Chromium is not installed on this server. Run: apt-get install chromium."
        let answer = await rig.answer("browser.window.open"); XCTAssertEqual(notice(answer), "Chromium is not installed on this server. Run: apt-get install chromium.")
    }
    func testOpenNilWithoutReasonUsesFixedSentence() async {
        let rig = BackendRemoteServeBrowserPortRig(); rig.openReturnsNil = true
        let answer = await rig.answer("browser.window.open"); XCTAssertEqual(notice(answer), "This machine's browser did not open a window.")
    }
    func testSessionDependencyFailureStillDrawsTheWindows() async throws {
        let rig = rig(); rig.breaks.insert("sessions"); let answer = await rig.answer("browser.windows")
        XCTAssertEqual(try rows(answer).count, 1); XCTAssertEqual(notice(answer), "This machine could not list its sessions: the sessions dep is unwell.")
    }
    func testEveryBrokenDependencyAndEverySourceVerbReturnsAWireReply() async throws {
        let requests: [(String, [NativeRPCValue.Field])] = [
            ("browser.windows", []), ("browser.window.open", [.init("url", .string("https://example.com/"))]),
            ("browser.window.go", [.init("id", .string("w1")), .init("url", .string("https://example.com/"))]),
            ("browser.window.act", [.init("id", .string("w1")), .init("action", .string("reload"))]),
            ("browser.window.act", [.init("id", .string("w1")), .init("action", .string("close"))]),
            ("browser.window.act", [.init("id", .string("w1")), .init("action", .string("record.on"))]),
            ("browser.window.act", [.init("id", .string("w1")), .init("action", .string("isolate"))]),
            ("browser.window.open", [.init("url", .string("https://example.com/")), .init("session", .string("s1"))]),
            ("browser.window.bind", [.init("id", .string("w1")), .init("session", .string("s1"))]), ("browser.window.bind", [.init("id", .string("w1"))]),
            ("browser.window.shot", [.init("id", .string("w1"))]), ("browser.window.shot", [.init("id", .string("w1")), .init("session", .string("s1"))]),
            ("browser.window.steps", [.init("id", .string("w1"))]),
            ("browser.window.pick", [.init("id", .string("w1")), .init("x", .number(4)), .init("y", .number(4))]),
            ("browser.window.pick", [.init("id", .string("w1")), .init("x", .number(4)), .init("y", .number(4)), .init("up", .number(2))])]
        let tags = ["browser.window.rows", "browser.shot", "browser.record.rows", "browser.window.picked"]
        for broken in ["list", "open", "go", "history", "close", "capture", "sessions", "write", "recorder", "pick"] {
            for (tag, fields) in requests {
                // Each request starts from the source's bound w1/s1 state, so a
                // prior close cannot hide the broken dependency in a later verb.
                let rig = rig(); session(rig); _ = try rig.bindings.attach("w1", to: .init(sessionId: "s1")); rig.breaks.insert(broken)
                let answer = await rig.answer(tag, fields); XCTAssertTrue(tags.contains(answer["t"].string ?? ""), "\(broken) produced \(answer["t"].string ?? "missing")")
            }
        }
    }
}
