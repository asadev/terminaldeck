/**
 * The Back button beside Reload, and the reason it did nothing.
 *
 * Asad, on a page from his PC: *"the back button here doesn't work at all next to
 * refresh. So it should be working also."*
 *
 * The button was wired to `goBack()` the whole time, and the wiring was never the
 * problem. `BrowserBridge.canGoBack` — which is what disables it — was only ever
 * re-read from `WKNavigationDelegate` callbacks, and **those do not fire for a
 * same-document navigation**: a fragment, a `pushState`, a `replaceState`. That
 * is not an edge case on this screen, it is the normal case. The whole point of
 * the feature is looking at a dev server, every modern dev server serves a
 * single-page app, and every route change in one is `pushState`. So the
 * back-forward list filled up, `webView.canGoBack` went true, and this object
 * never asked again — the button stayed disabled however far into the site you
 * had clicked, which from a thumb is indistinguishable from a dead button.
 *
 * ## Why a real web view
 *
 * The bug lives precisely in the gap between what WebKit does and what it tells
 * its delegate, so a fake web view would be a fake of the thing that was wrong.
 * `loadHTMLString` needs no network and no server — the base URL only supplies an
 * origin — so this runs on a laptop with nothing listening.
 *
 * ## Knowing when the page is actually there — the trap, in full
 *
 * Three runs were spent on a `SecurityError: Blocked attempt to use
 * history.pushState() to change session history URL from  to ?p=2. URL is
 * invalid`, and the empty "from" is the whole diagnosis: the script was running
 * against `about:blank`, which has no URL to resolve `?p=2` against. Neither
 * obvious signal means *the page is here*:
 *
 *  - **`webView.url`** moves to the **provisional** URL the moment a load
 *    starts, so the address is already right while the committed document is
 *    still the previous one — which on a fresh web view is the empty document;
 *  - **`document.readyState`** is `"complete"` for that empty document before
 *    anything has been asked for.
 *
 * So `loadedBridge` waits on `document.URL` itself. Worth knowing generally:
 * it is the same reason `LocalhostBrowser.load` refuses to point the view at a
 * port before the tunnel is up.
 *
 * ## Two smaller ones
 *
 * **A `file://` page, not `loadHTMLString`.** A real document with a real URL,
 * no server, no origin questions. It also gives the pushed URL something
 * unambiguously same-origin to be.
 *
 * **`pushState`, not `location.hash`.** A hash change is only *sometimes* a new
 * history entry. `pushState` is what a router calls and it is unambiguous.
 *
 * ## And Forward, which is here for a reason of its own
 *
 * `allowsBackForwardNavigationGestures` is a single property buying two
 * gestures — back on the left edge, forward on the right. It was turned off so
 * that the left edge could go back to meaning *leave this pushed screen*, which
 * is what it means everywhere else on iOS, and that took the forward swipe with
 * it. Forward is a button in the bottom toolbar now, `canGoForward` is observed
 * beside `canGoBack`, and it would have had the identical same-document bug for
 * the identical reason had it been read off the delegate instead.
 * `LocalhostChromeTests` owns the rest of that decision.
 */

import UIKit
import WebKit
import XCTest
@testable import TerminalDeck

@MainActor
final class BrowserBackTests: XCTestCase {

    private var window: UIWindow?
    private var bridge: BrowserBridge?

    override func tearDown() {
        bridge?.tearDown()
        bridge?.webView.removeFromSuperview()
        bridge = nil
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    /**
     * A bridge with its web view in a real window, showing a finished document.
     *
     * In a window because a `WKWebView` that was never laid out has no size, and
     * WebKit defers work for a view with no size — including, intermittently, the
     * script evaluation both cases below depend on.
     */
    private func loadedBridge() async throws -> BrowserBridge {
        let bridge = BrowserBridge()
        self.bridge = bridge

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 640))
        let controller = UIViewController()
        controller.view.addSubview(bridge.webView)
        bridge.webView.frame = controller.view.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window

        // A real file, loaded from disk — see the header for the two ways of
        // faking one that both left the document with no URL of its own.
        let file = try Self.writePage()
        bridge.webView.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())

        /*
         * Ask the **document** what it is, not the web view.
         *
         * This is the whole trap, and it cost three runs. Neither of the two
         * obvious signals means "the page is here":
         *
         *  - `webView.url` moves to the *provisional* URL when a load starts, so
         *    the address bar is already right while the committed document is
         *    still the previous one;
         *  - `document.readyState` is `"complete"` on the **initial empty
         *    document** every `WKWebView` begins life showing.
         *
         * Wait on either and the script below runs against `about:blank`, which
         * has no URL — and every history call is then refused with
         * `SecurityError: … change session history URL from  to ?p=2. URL is
         * invalid`, an error that names the symptom and hides the cause.
         */
        try await waitUntil("the page's own document finished loading") {
            guard let url = try? await self.evaluate(bridge, "String(document.URL)"),
                  url.hasSuffix(Self.fileName) else { return false }
            return (try? await self.evaluate(bridge, "document.readyState")) == "complete"
        }
        return bridge
    }

    private static let fileName = "back-test.html"

    /// The document, on disk. A fresh directory per call so two cases cannot
    /// share a cached load.
    private static func writePage() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("td-back-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(fileName)
        try page.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private static let page = """
    <!doctype html><html><head><title>A page</title></head><body>
    <h1>A page</h1>
    </body></html>
    """

    private func evaluate(_ bridge: BrowserBridge, _ script: String) async throws -> String {
        let answer = try await bridge.webView.evaluateJavaScript(script)
        return answer as? String ?? ""
    }

    // MARK: - The two states the button has

    /**
     * The first page of a site has nowhere to go back to, and the button says so
     * by being disabled rather than by doing nothing when pressed.
     *
     * This is the half that was already correct and must stay correct: the fix
     * for "the button does nothing" must not be a button that is always enabled
     * and sometimes silently no-ops.
     */
    func testTheButtonIsDisabledWhenThereIsNoHistory() async throws {
        let bridge = try await loadedBridge()
        XCTAssertFalse(bridge.canGoBack,
                       "one document and no navigations — there is nowhere to go back to")
    }

    /**
     * **The bug, and its undo.** A `pushState` makes Back live, and pressing it
     * comes back and goes dead again.
     *
     * One case rather than two because the second half needs the first to have
     * happened to a live page, and because each of these costs a web content
     * process.
     *
     * `pushState` is exactly what a router does on a route change: WebKit pushes
     * an entry onto the back-forward list and tells the navigation delegate
     * **nothing**. Before the KVO observation in `BrowserBridge` the first
     * assertion failed, and it failed on every single-page app he could have
     * opened.
     *
     * The second half matters as much as the first: a `canGoBack` that only ever
     * ratcheted upwards would leave an enabled button on the first page of a
     * site, which is the same defect wearing the opposite face.
     */
    func testAPushStateMakesBackLiveAndGoingBackTurnsItOffAgain() async throws {
        let bridge = try await loadedBridge()
        XCTAssertFalse(bridge.canGoBack)

        // A query rather than a path, so the pushed URL is unambiguously the
        // same origin as a `file://` document — same scheme, same (empty) host.
        _ = try await bridge.webView.evaluateJavaScript("history.pushState({}, '', '?p=2'); 1")

        // The ground truth first, so a failure says which half broke: WebKit not
        // recording the entry is a different bug from this object not noticing.
        try await waitUntil("WebKit recorded the pushed entry") { bridge.webView.canGoBack }
        try await waitUntil("Back came alive after the page moved") { bridge.canGoBack }
        XCTAssertTrue(bridge.address.hasSuffix("?p=2"),
                      "the header followed the route too, address: \(bridge.address)")

        bridge.goBack()

        try await waitUntil("Back went dead again at the start of the history") {
            !bridge.canGoBack
        }
        XCTAssertFalse(bridge.address.hasSuffix("?p=2"),
                       "the address followed the history back, address: \(bridge.address)")
    }

    /**
     * **Forward, which exists because a gesture stopped existing.**
     *
     * `allowsBackForwardNavigationGestures` is one property and it buys two
     * gestures: back on the left edge and forward on the right. Turning it off
     * — so that the left edge means *leave this screen*, which is what it means
     * everywhere else on iOS — therefore took the only way forward with it. A
     * Back button with no Forward beside it strands somebody the first time they
     * press it by accident.
     *
     * So this walks the same history the case above does and then walks back up
     * it, and it asserts both halves of the state at every step. The `canGoBack`
     * assertions are not padding: `goForward` landing on the second entry is
     * only correct if there is now something *behind* it, and a forward that
     * quietly reloaded the first page instead would satisfy every assertion
     * about the address alone.
     *
     * Same file, same `pushState`, same reason as the case above — see the type
     * header for why a real web view and why `document.URL` is what tells us the
     * page is here.
     */
    func testForwardComesAliveAfterGoingBackAndWalksTheHistoryUpAgain() async throws {
        let bridge = try await loadedBridge()
        XCTAssertFalse(bridge.canGoForward, "a page nobody has left has nothing in front of it")

        _ = try await bridge.webView.evaluateJavaScript("history.pushState({}, '', '?p=2'); 1")
        try await waitUntil("Back came alive after the page moved") { bridge.canGoBack }
        XCTAssertFalse(bridge.canGoForward,
                       "pushing a new entry puts it *behind* nothing — forward is still empty")

        bridge.goBack()
        try await waitUntil("Forward came alive once there was a page ahead") { bridge.canGoForward }
        XCTAssertFalse(bridge.canGoBack, "back at the first entry, with nowhere further back to go")

        bridge.goForward()
        try await waitUntil("the page came forward again") { bridge.address.hasSuffix("?p=2") }
        try await waitUntil("Forward went dead at the end of the history") { !bridge.canGoForward }
        XCTAssertTrue(bridge.canGoBack,
                      "and Back is live again, because the first entry is behind this one")
    }

    // MARK: - Helpers

    /**
     * Poll until a condition holds, or fail saying what was being waited for.
     *
     * Polling rather than an `XCTestExpectation`, because what is being waited on
     * is an `@Observable` property mutated from a KVO callback rather than a
     * completion handler there is anywhere to hang a fulfil on.
     *
     * `Task.sleep` rather than `RunLoop.run(until:)`, and not only because the
     * latter is unavailable from an async context in Swift 6: awaiting yields
     * the main actor, which is exactly what lets WebKit's callbacks — and the
     * KVO notifications this whole file is about — land between polls.
     *
     * The timeout is generous because this suite shares a machine: measured, the
     * whole of it takes about two seconds when nothing else is running.
     */
    private func waitUntil(_ what: String,
                           timeout: TimeInterval = 20,
                           file: StaticString = #filePath,
                           line: UInt = #line,
                           _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out waiting for: \(what)", file: file, line: line)
    }
}
