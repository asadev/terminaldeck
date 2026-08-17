/**
 * Tapping a port on the Mac and getting a live page, checked with a finger.
 *
 * Nothing below can be established by a unit test, and one of the claims cannot
 * even be established by looking at a screenshot: that the page's own
 * *WebSocket* is open. A tunnel that carries the HTML and drops the socket looks
 * completely correct in a picture and is useless in practice, because a dev
 * server without its socket has no hot reload — which is most of the reason to
 * look at one from a phone at all.
 *
 * These drive `scripts/remote-host.sh`, which is the **real** desktop endpoint
 * and the real tunnel hub in a plain Node process, and the harness dev server:
 *
 *     node .harness/.devsite/server.mjs &     # serves on 127.0.0.1:3210
 *     scripts/remote-host.sh --fresh --approve-after 2000 &
 *     # pair the Simulator with that host, then:
 *     xcodebuild test -project ios/TerminalDeck.xcodeproj -scheme TerminalDeck \
 *       -destination 'platform=iOS Simulator,name=iPhone 17' \
 *       -only-testing:TerminalDeckUITests/LocalhostUITests
 *
 * The pairing is not done here, and that is the one awkward thing about this
 * file: `simctl openurl` raises a system *Open in …?* confirmation that nothing
 * in XCUITest can reach, so the code has to be typed into the pairing field.
 * `InspectUITests` does exactly that against the same control server, so running
 * it first leaves this suite a paired app to work with — and it wants the same
 * dev server, which is the other reason the two now name one port:
 *
 *     TEST_RUNNER_TD_CONTROL=127.0.0.1:8788 xcodebuild test … \
 *       -only-testing:TerminalDeckUITests/InspectUITests \
 *       -only-testing:TerminalDeckUITests/LocalhostUITests
 *
 * ## The port used to be 3000, and that was the bug
 *
 * The instructions above used to read `npx vite <some site> --port 3000`, from
 * back when this file only checked that *a* page rendered. They stopped being
 * true the moment the assertions were tightened onto this repository's own dev
 * server — every string checked below (`Served from the Mac`, `HMR socket OPEN`,
 * `OK,`) is printed by `.harness/.devsite/index.html` and by nothing else — and
 * that page is served by `server.mjs`, which listens on **3210** and cannot be
 * told otherwise.
 *
 * So the file asked for a port nothing in this repository binds. Every case
 * failed at its first assertion, and the first one alphabetically —
 * `testClosingTheViewLeavesNoPageBehind` — failed with a bare *"XCTAssertTrue
 * failed"*, which reads like a broken app and is a missing dev server. The
 * number is now the one number, and the assertions that were silent now say what
 * they were looking for.
 *
 * Every case skips rather than fails when there is nothing to talk to, for the
 * same reason as `LiveSessionUITests`: a suite that goes red on a laptop with no
 * server running is a suite that gets deleted. A *missing dev server* is
 * deliberately not one of those cases — it is a failure, because the whole
 * subject of this file is a page crossing the tunnel and there is nothing to
 * check without one.
 *
 * ## The Simulator serves the page on `[::1]`, and that is expected
 *
 * The Simulator has no network stack of its own — `127.0.0.1` inside it is the
 * Mac's loopback — so the dev server being tunnelled is already holding the
 * address the app would bind. `PortTunnel` falls back to the IPv6 loopback there
 * and nowhere else; see the comment on `bind`. It means the origin under test is
 * `http://[::1]:3000` rather than `http://127.0.0.1:3000`, which changes nothing
 * about what is being proved: the bytes still cross the sealed channel, because
 * the only thing listening on `[::1]` is the app itself.
 */

import XCTest

final class LocalhostUITests: XCTestCase {

    /**
     * The port the dev server is on. One number, in one place, because it has
     * to be the same on both sides of the tunnel — that is the feature.
     *
     * `.harness/.devsite/server.mjs`, the same server `InspectUITests` names and
     * for the same reason: the assertions below are about *that page*, not about
     * any page, and `server.mjs` binds this port and no other. A number chosen
     * independently of the thing that serves it is a suite that fails on a
     * machine where everything works.
     */
    private static let port = 3210

    private var app: XCUIApplication!
    private static var reachable: Bool?

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(Self.reachable == false, Self.notRunning)

        app = XCUIApplication()
        app.launch()

        let connected = waitForConnected(timeout: Self.reachable == nil ? 45 : 10)
        Self.reachable = connected
        try XCTSkipUnless(connected, Self.notRunning)

        // The ports are their own tab now rather than a second list under the
        // sessions — *"Sessions separately and local host separately in the pill
        // side"*. Every case below starts here.
        XCTAssertTrue(app.openLocalhostTab(), "the Localhost tab should be reachable")
    }

    /// The skip, and it names both halves of the setup — the host *and* the dev
    /// server — because the two failures look identical from here and the fix
    /// for one is not the fix for the other.
    private static let notRunning =
        "This phone is not paired with a running host. Start scripts/remote-host.sh and "
        + "node .harness/.devsite/server.mjs, then pair the Simulator — running "
        + "InspectUITests against the same control server does it, and see the header."

    // MARK: - The list

    /**
     * The port is on screen without anyone typing it.
     *
     * The whole shape of this feature is that the desktop already knows what is
     * listening, so the phone shows it. A row that had to be configured, or a
     * field to type a port into, would be the same feature with the seamlessness
     * taken out.
     */
    func testTheMacsPortsAppearOnTheirOwn() throws {
        let row = portRow()
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "the desktop is serving on \(Self.port); the phone should be offering it")
        XCTAssertTrue(row.label.contains(String(Self.port)), "row said: \(row.label)")
    }

    // MARK: - The tap

    /**
     * One tap, and a real page — with its `fetch` and its WebSocket working.
     *
     * The markers come from the page itself. `Same-origin fetch` proves the
     * document's own origin resolves back through the tunnel rather than to
     * nothing, and `HMR socket OPEN` proves the WebSocket upgrade survived it,
     * which is the claim a screenshot cannot make on its own.
     */
    func testTappingAPortOpensItInABrowser() throws {
        let row = portRow()
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no port row arrived")
        // The tap is the consent: if a confirmation sheet ever appears between
        // here and the page, this line stops finding what it expects next.
        row.tap()

        let done = app.buttons["localhost.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 15), "the browser screen should open on the tap")

        /*
         * The pill is gone in here, and this is the only place it can be
         * checked.
         *
         * *"Pill should be on here only on the homepage or machines or settings,
         * but not inside the session and not also inside the localhost page."*
         * `DeckChromeTests` pins the rule; nothing but a running app can say
         * whether the modifier that enforces it is on the right screen.
         */
        XCTAssertFalse(app.tabBars.firstMatch.exists,
                       "the tab bar must not be drawn over a page from the machine")

        let heading = app.staticTexts["Served from the Mac"]
        XCTAssertTrue(heading.waitForExistence(timeout: 30),
                      "the page never rendered — the tunnel did not carry the document")

        // Nowhere to go back to on the first page of a site, so the control says
        // so by being disabled. The half of "the back button does nothing" that
        // was always correct and has to stay correct.
        let back = app.buttons["localhost.back"]
        XCTAssertTrue(back.exists, "the page's own Back button should be on the header")
        XCTAssertFalse(back.isEnabled, "one page in, there is no history to go back to")

        // A dev server's socket is the difference between a page and a
        // screenshot. Given a little longer than the document, because it opens
        // after the page has run its scripts.
        XCTAssertTrue(waitForText(containing: "HMR socket OPEN", timeout: 25),
                      "the page's WebSocket did not open through the tunnel")
        XCTAssertTrue(waitForText(containing: "OK,", timeout: 15),
                      "the page's same-origin fetch did not come back")

        // Held on screen long enough for `xcrun simctl io booted screenshot` to
        // catch it from outside, and attached from inside so the run is
        // self-contained when nobody is watching.
        add(screenshot(named: "tunnelled page"))
        sleep(6)

        done.tap()
        XCTAssertTrue(portRow().waitForExistence(timeout: 10), "closing should come back to the list")
        // And the bar comes back with it. A hidden tab bar that stays hidden
        // after the screen it belonged to has gone is the other half of the same
        // bug, and it strands somebody on one tab.
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5),
                      "the tab bar should be back on the list")
    }

    /**
     * Closing the view ends the tunnel.
     *
     * Asserted on this side by the page being gone and the list being back; the
     * other half — that the Mac's socket went with it — is asserted by whoever
     * runs this, against `curl 127.0.0.1:8788/state`, because a phone cannot see
     * the desktop's own bookkeeping and pretending otherwise would be a weaker
     * claim dressed as a stronger one.
     */
    func testClosingTheViewLeavesNoPageBehind() throws {
        // Every assertion here says what it was looking for. They used to say
        // nothing, and the first one is alphabetically the first assertion in
        // the whole suite — so a dev server that was not running reported itself
        // as a bare "XCTAssertTrue failed" on a line that reads like the app is
        // broken. See the header.
        let row = portRow()
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "no row for port \(Self.port) — is .harness/.devsite/server.mjs running?")
        row.tap()

        let done = app.buttons["localhost.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 15), "the browser screen should open on the tap")
        XCTAssertTrue(app.staticTexts["Served from the Mac"].waitForExistence(timeout: 30),
                      "the page never rendered — the tunnel did not carry the document")
        done.tap()

        XCTAssertTrue(portRow().waitForExistence(timeout: 10), "closing should come back to the list")
        XCTAssertFalse(app.staticTexts["Served from the Mac"].exists,
                       "the page is still on screen after the tunnel was closed")
    }

    // MARK: - Helpers

    private func portRow() -> XCUIElement {
        app.buttons["port.\(Self.port)"]
    }

    /**
     * True once any static text on screen contains this.
     *
     * Asked as one predicated query rather than by walking the elements. A web
     * view rebuilds its accessibility tree on every render, so a loop that reads
     * `count` and then indexes into it is indexing a snapshot that no longer
     * exists — which fails with *"No matches found for Element at index 32"*
     * rather than with a false negative, and looks exactly like the page not
     * having loaded.
     */
    private func waitForText(containing needle: String, timeout: TimeInterval) -> Bool {
        let matching = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", needle))
        return matching.firstMatch.waitForExistence(timeout: timeout)
    }

    private func screenshot(named name: String) -> XCTAttachment {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }

    private func waitForConnected(timeout: TimeInterval) -> Bool {
        let pill = app.descendants(matching: .any).matching(identifier: "connection.pill").firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pill.exists && pill.label.contains("Connected") { return true }
            usleep(500_000)
        }
        return false
    }
}
