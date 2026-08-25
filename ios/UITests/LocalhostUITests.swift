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
 * and the real tunnel hub in a plain Node process, and the harness dev server.
 * It is deliberately **not** `ios/Harness/run.sh host`: that stand-in implements
 * no `ports` frame and no `tunnel` verb at all, so a suite about tunnelled pages
 * run against it proves nothing — an earlier localhost pass was reported as
 * verified against a screen that could not have shown a port.
 *
 *     ios/Harness/live-localhost.sh
 *
 * ## This suite pairs itself now, and why it could not before
 *
 * It used to say pairing happened elsewhere — *"`InspectUITests` does exactly
 * that against the same control server, so running it first leaves this suite a
 * paired app to work with"*. That was not true, and it could not have been:
 *
 *  - every self-pairing suite in this target reads `code` out of the control
 *    server's `/pair`, and **`scripts/remote-host.ts` still answers
 *    `{ uri: "terminaldeck://pair?…&t=406403" }`** — the shape from back when
 *    pairing was a link, which the product has since removed;
 *  - and even with the digits in hand it would still fail, because **six digits
 *    do not carry an address**. `Rendezvous.swift` derives a relay slot from the
 *    code and expects the machine showing it to be *sitting in that slot*, and
 *    the thing that puts it there is `startBeacon` in
 *    `src/main/remote/machines/rendezvous.ts` — which `remote-host.ts` never
 *    calls. Measured: a code minted by that script, typed correctly, inside its
 *    sixty seconds, on the deployed relay, answers *"No machine is showing that
 *    code."*
 *
 * So the host this runs against is the **product's own headless host**, whose
 * codes are minted through the same `machines:code` IPC the desktop's Pair
 * button calls — beacon and all. `ios/Harness/live-localhost.sh` starts it under
 * its own `HOME`, serves the dev site, erases and boots a Simulator, and answers
 * this suite's pairing handshake. Two variables carry that handshake, and they
 * are files because the code is minted *after* the phone reaches the field: see
 * `readyFile` and `codeFile` below.
 *
 * `TD_CONTROL` still works and is still read, for the day `remote-host.ts` grows
 * a beacon and for `host-standin.ts`, which answers `{ code }`. `freshCode()`
 * accepts either shape.
 *
 * Pairing happens **once**, in the first case that finds the app asking for a
 * code, because a code is worth sixty seconds and one redemption — a second case
 * that unpaired and asked again would be typing a code already spent. Making
 * sure it is the *right* machine is the script's job rather than this file's: it
 * erases the Simulator, because a pairing lives in the Simulator's keychain and
 * survives an uninstall, so without an erase a run finds the phone still holding
 * whichever host it met last — Connected, cheerful, and serving no ports.
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

        /*
         * Paired here, once, and only while the app is asking to be.
         *
         * `setUp` runs per case, and a pairing code is worth **sixty seconds and
         * one redemption** — so a second case that unpaired and asked again
         * would be typing a code that had already been spent. The first case
         * pairs; the ones after it find the host still trusted and come straight
         * up, which is that claim holding rather than a convenience.
         *
         * Nothing is unpaired here for the same reason. Making "which machine is
         * this" answerable is the *harness's* job and it does it properly:
         * `live-localhost.sh` erases the Simulator, because a pairing lives in
         * the Simulator's keychain and survives an uninstall — so without an
         * erase a run finds the phone still holding whichever host it met last,
         * Connected, cheerful, and serving no ports.
         */
        if canPairItself && !Self.paired {
            try pairIfTheAppIsAsking()
        }

        // Long: the device has to redeem its code, be refused because a code
        // alone admits nobody, and then be approved on the host before the pill
        // can go green. That refusal is the product declining, not a fault.
        let connected = waitForConnected(timeout: Self.reachable == nil ? 180 : 60)
        Self.reachable = connected
        try XCTSkipUnless(connected, Self.notRunning)

        // The ports are their own tab now rather than a second list under the
        // sessions — *"Sessions separately and local host separately in the pill
        // side"*. Every case below starts here.
        XCTAssertTrue(app.openLocalhostList(),
                      "the localhost list is one row down the Browser tab's menu — see TabNavigation")
    }

    /// The skip, and it names both halves of the setup — the host *and* the dev
    /// server — because the two failures look identical from here and the fix
    /// for one is not the fix for the other.
    private static let notRunning =
        "This phone is not paired with a running host serving a page on 3210. "
        + "Run ios/Harness/live-localhost.sh, which starts both and pairs the Simulator — "
        + "and see the header for why a code from scripts/remote-host.sh cannot work."

    // MARK: - Pairing

    /// The harness control server, e.g. `127.0.0.1:8798`. An address rather than
    /// a pairing link, because **a pairing token is worth sixty seconds** and one
    /// redemption: a link handed in when the run started is expired by the time a
    /// case reaches it, and worse, the pairing desk is only open while a token is
    /// live — so the refusal reads as a crypto failure and is not one.
    private var control: String { ProcessInfo.processInfo.environment["TD_CONTROL"] ?? "" }

    /**
     * The other handshake, and it is the one that works against the real host.
     *
     * `live-localhost.sh` runs the **product's own headless host**, whose codes
     * are minted through the same `machines:code` IPC the desktop's Pair button
     * calls — which is what publishes the rendezvous beacon a typed code is
     * looked up at. Nothing else does: a control server can hand out a token all
     * day and the phone will still say *"no machine is showing that code"*,
     * because six digits name a relay slot rather than carrying an address.
     *
     * It is a pair of files rather than one variable because the code is minted
     * **after** this test reaches the pairing screen. A code is good for sixty
     * seconds and a Simulator takes longer than that to build, install and
     * launch, so one minted before `xcodebuild` started would already be dead.
     * This test writes `readyFile` when it is standing at the field; the script
     * answers with six digits in `codeFile`.
     */
    private var readyFile: String { ProcessInfo.processInfo.environment["TD_READY_FILE"] ?? "" }
    private var codeFile: String { ProcessInfo.processInfo.environment["TD_CODE_FILE"] ?? "" }

    /// Whether this run was given any way at all to pair itself.
    private var canPairItself: Bool { !control.isEmpty || !readyFile.isEmpty }

    /// Set once the phone has been through the field, so the cases after the
    /// first do not spend eight seconds each looking for a screen that is not
    /// coming back. Static because XCTest builds a fresh instance per case and
    /// the app process outlives all of them.
    private static var paired = false

    /**
     * Six digits in the field, if the field is what is on screen.
     *
     * Typed rather than opened: `simctl openurl` raises a SpringBoard *"Open in
     * Terminal Deck?"* alert that nothing in XCUITest can reach, and six digits
     * in a field is the only door the product has anyway. The field submits
     * itself on the sixth digit, which is why Pair is tapped only when it is
     * still there — tapping a button that has already gone is a failure, not a
     * no-op.
     *
     * An already-paired phone falls straight through. The short wait is enough:
     * the pairing screen needs no network to draw, so it is up within a second
     * of launch on a phone that has nothing stored.
     */
    private func pairIfTheAppIsAsking() throws {
        // The door first, if the login is in front of the field — see
        // `XCUIApplication.reachPairingField`.
        let field = app.textFields["pairing.field"]
        guard app.reachPairingField(timeout: 8) else {
            Self.paired = true
            return
        }

        let code = try freshCode()
        field.tap()
        field.typeText(code)
        let submit = app.buttons["pairing.submit"]
        if submit.exists && submit.isHittable { submit.tap() }
        Self.paired = true
    }

    /**
     * A code from the host, now, in whichever shape that host answers in.
     *
     * `code` is what every self-pairing suite in this target expects and what
     * `ios/Harness/host-standin.ts` sends. `scripts/remote-host.ts` — the real
     * desktop endpoint, and the only host worth pointing this suite at — still
     * answers `{ uri: "terminaldeck://pair?…&t=406403" }`, the shape from back
     * when pairing was a link. Reading both is what makes the real desktop
     * reachable in one command; see the header. The `t` parameter is not a guess
     * at a format, it is what `PairingCode.swift` parses in the app.
     */
    private func freshCode() throws -> String {
        if !readyFile.isEmpty { return try codeFromTheScript() }
        guard let url = URL(string: "http://\(control)/pair") else {
            throw XCTSkip("\(control) is not an address")
        }
        var answer: String?
        let done = expectation(description: "minted")
        URLSession.shared.dataTask(with: url) { data, _, _ in
            defer { done.fulfill() }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            if let code = json["code"] as? String, !code.isEmpty {
                answer = code
                return
            }
            guard let uri = json["uri"] as? String,
                  let components = URLComponents(string: uri) else { return }
            answer = components.queryItems?.first { $0.name == "t" }?.value
        }.resume()
        wait(for: [done], timeout: 20)
        guard let answer, !answer.isEmpty else {
            Self.reachable = false
            throw XCTSkip("\(Self.notRunning) (\(control) did not answer /pair)")
        }
        return answer
    }

    /**
     * Say we are at the field, then wait for the script's six digits.
     *
     * The whitespace is stripped rather than trusted: a trailing newline typed
     * into a `.numberPad` field is a character the parser refuses, and that
     * failure reads as the code being wrong.
     *
     * Generous, because the wait is for a person-shaped sequence happening on
     * the Mac — mint a code, publish a rendezvous beacon, wait for the phone to
     * redeem it — and the alternative to polling a file is a `DispatchSource` on
     * a file that does not exist yet.
     */
    private func codeFromTheScript() throws -> String {
        try? "ready\n".write(toFile: readyFile, atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            if let raw = try? String(contentsOfFile: codeFile, encoding: .utf8) {
                let digits = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if digits.count == 6 { return digits }
            }
            usleep(400_000)
        }
        Self.reachable = false
        throw XCTSkip("\(Self.notRunning) (nothing wrote six digits to TD_CODE_FILE)")
    }

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

        XCTAssertTrue(browserBar().waitForExistence(timeout: 15),
                      "the browser screen should open on the tap")

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
        XCTAssertTrue(back.exists, "the page's own Back button should be in the bar under it")
        XCTAssertFalse(back.isEnabled, "one page in, there is no history to go back to")
        // And its new neighbour, for the same reason: nothing has been left, so
        // there is nothing in front of this page either.
        XCTAssertFalse(app.buttons["localhost.forward"].isEnabled,
                       "one page in, there is nothing to go forward to")

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

        leaveTheBrowser()
        XCTAssertTrue(portRow().waitForExistence(timeout: 10), "leaving should come back to the list")
        // And the bar comes back with it. A hidden tab bar that stays hidden
        // after the screen it belonged to has gone is the other half of the same
        // bug, and it strands somebody on one tab.
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5),
                      "the tab bar should be back on the list")
    }

    /**
     * **The chrome on a page is the platform's, and the row is the same six
     * controls that every other browser window wears.**
     *
     * ## What this case used to claim, and why the claim had to change
     *
     * It was called `testTheChromeIsThePlatformsAndDoneIsLast` and its third
     * assertion pinned **Done as the last control in the row** — *"last button I
     * think is on its correct place"*, said of a row that ended with it. That
     * sentence is still true of where the sixth control sits; the control is no
     * longer Done.
     *
     * > *"So top, header and footer, tab bar should be same in all type of
     * > browsing windows, including on this phone, including isolated, including
     * > the server."*
     *
     * This screen drew its own system toolbar — Back, Forward, Reload, Find,
     * Inspect, Done — and that made it one control longer, and one control
     * different, from the bar under a window on the machine. It mounts the shared
     * `BrowserPageBar` now, so the row is:
     *
     *     Back · Forward · Reload · Find · Inspect · More
     *
     * Done did not disappear: tearing the tunnel down is a thing you do to the
     * *window* rather than to the page, so it is `Close this window` inside the
     * `…` — `localhost.settings` then `localhost.close` — and
     * `testClosingTheViewLeavesNoPageBehind` walks it there. The chevron top left
     * does exactly the same thing in one tap and always did.
     *
     * ## The three claims this case makes, none of which a unit test can
     *
     * Asad, after the screen had already been changed from a `fullScreenCover`
     * into a push: *"Localhost browsing is still not native on iOS."* The
     * remaining half was that this screen had hidden the system navigation bar
     * in order to draw its own row of browser controls at the top — which cost
     * the chevron, the standard title and the interactive pop, all three of
     * which somebody's thumb expects without being told. The resolution is
     * Safari's: the navigation bar stays and the browser's controls live along
     * the bottom. So:
     *
     *  1. a system navigation bar is on this screen;
     *  2. every browser control is at the *bottom* of it — measured against the
     *     middle of the screen, not asserted by looking at the source;
     *  3. the row reads left to right as the same six, in the same order, that
     *     `BrowserPageBar` puts under every other kind of browser window.
     *
     * The order is measured off the real frames rather than read from the source,
     * which is the half of claim 3 that is worth having: a bar assembled in the
     * right order and laid out in the wrong one passes every existence check
     * anybody would think to write.
     *
     * `LocalhostChromeTests` is the tripwire for the same three in the unit
     * suite, which runs on a laptop with nothing listening, and
     * `BrowserPageBarUITests` asserts the same six exist on all three kinds of
     * window. Neither of those can say **where on the screen** they are. This is
     * the proof of that, and it is the only one, which is why the case was
     * rewritten rather than deleted with its name.
     */
    func testTheChromeIsThePlatformsAndTheRowIsTheSameSix() throws {
        let row = portRow()
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "no row for port \(Self.port) — is .harness/.devsite/server.mjs running?")
        row.tap()

        XCTAssertTrue(browserBar().waitForExistence(timeout: 15),
                      "the browser screen should open on the tap")
        XCTAssertTrue(app.staticTexts["Served from the Mac"].waitForExistence(timeout: 30),
                      "the page never rendered — the tunnel did not carry the document")

        // 1. The bar the screen used to hide.
        let bar = app.navigationBars.firstMatch
        XCTAssertTrue(bar.exists,
                      "the system navigation bar is gone again — with it go the chevron, the "
                      + "standard title and the swipe that pops this screen")

        /*
         * 2. Every control below the middle of the screen.
         *
         * A bar that had quietly gone back to the top would still pass an
         * existence check on all six buttons, which is how the first version of
         * this screen looked correct in a test and wrong in the hand.
         *
         * The six are the shared row and they are listed in the order they are
         * meant to be read: Back · Forward · Reload · Find · Inspect · More. The
         * sixth is `localhost.settings` — the `…` — which is where Done went;
         * see this case's header.
         *
         * The length of the row is pinned by these six being present **and** by
         * Done being asserted absent below, rather than by counting the buttons
         * on screen: the bar's other half is up there too — the address field, its
         * Go, the ⓘ when there is something to explain — so a raw count would be
         * a number nobody could keep true.
         */
        let middle = app.frame.midY
        let controls = ["localhost.back", "localhost.forward", "localhost.reload",
                        "localhost.find", "localhost.inspect", "localhost.settings"]
        for identifier in controls {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.exists,
                          "\(identifier) is missing from the bar — the row under a page on this "
                          + "phone is the same six as the row under every other browser window, "
                          + "and a shorter one is what he counted as two products")
            XCTAssertGreaterThan(button.frame.minY, middle,
                                 "\(identifier) is in the top half of the screen; browser controls "
                                 + "belong at the bottom on iOS")
        }
        XCTAssertLessThan(bar.frame.maxY, middle, "the navigation bar should be above the page")

        // And Done is gone from the row rather than merely unused. A Done left
        // standing beside the `…` would make this bar one control longer than
        // every other one, which is where this round started.
        XCTAssertFalse(app.buttons["localhost.done"].exists,
                       "Done left the row; closing the window is inside the `…` now")

        /*
         * 3. The order, left to right, read off the real frames rather than off
         *    the declaration — because a `Spacer` in the wrong place reorders
         *    what a thumb sees without touching what the source says.
         *
         * *"Last button I think is on its correct place"* was said of the sixth
         * slot, and the sixth slot is unchanged. What is in it is the `…`.
         */
        let byPosition = controls
            .map { (id: $0, x: app.buttons[$0].frame.midX) }
            .sorted { $0.x < $1.x }
            .map(\.id)
        XCTAssertEqual(byPosition, controls,
                       "the bottom bar reads left to right as \(byPosition.joined(separator: ", "))")

        add(screenshot(named: "system bar and the shared bar"))

        /*
         * The control that moved furthest still drives the thing it names, and
         * its notice moved to the other end of the screen.
         *
         * Inspect was in a custom header at the top with its sentence directly
         * underneath it; it is in the bar under the page now and the sentence is
         * a strip under the navigation bar. That is deliberate — it is a sentence
         * about *the page*, and the page is where the eye is — but it means the
         * control and its explanation are as far apart as two things on one
         * screen can be, so both halves are worth asserting rather than assuming.
         */
        let inspect = app.buttons["localhost.inspect"]
        inspect.tap()
        let hint = app.staticTexts["localhost.inspectHint"]
        XCTAssertTrue(hint.waitForExistence(timeout: 5),
                      "turning inspect on from the bar should say what it is waiting for")
        XCTAssertLessThan(hint.frame.maxY, middle,
                          "the notice belongs under the navigation bar, above the page it is about")
        add(screenshot(named: "inspecting"))

        inspect.tap()
        XCTAssertFalse(hint.exists,
                       "turning it off should take the notice with it — a sentence left on screen "
                       + "for a mode nobody is in is a claim that they are")
    }

    /**
     * **The left-edge swipe pops the screen — it does not walk the page.**
     *
     * This is the other half of *"still not native"*, and it was the more
     * confusing half. `allowsBackForwardNavigationGestures` handed the standard
     * back gesture to the web view's own history, so the one gesture nobody has
     * to be taught quietly did something else on this screen and there was no
     * way to leave with a thumb at all.
     *
     * A drag from `dx: 0` rather than `swipeRight()`, which starts in the middle
     * of the element and is a page scroll: the interactive pop is a
     * `UIScreenEdgePanGestureRecognizer` and it only arms within a few points of
     * the edge.
     *
     * The last assertion matters as much as the first. Popping by gesture has to
     * take the tunnel down exactly as `Close this window` does — see the
     * `onChange` in `MachineBrowserView` — because a page left half-closed leaves
     * the machine serving a port to a phone that stopped looking. Leaving the
     * screen **is** the teardown, which is the whole reason the verb could move
     * off the row and into the `…` without anything being lost.
     */
    func testTheLeftEdgeSwipePopsTheScreen() throws {
        let row = portRow()
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "no row for port \(Self.port) — is .harness/.devsite/server.mjs running?")
        row.tap()

        XCTAssertTrue(browserBar().waitForExistence(timeout: 15),
                      "the browser screen should open on the tap")
        XCTAssertTrue(app.staticTexts["Served from the Mac"].waitForExistence(timeout: 30),
                      "the page never rendered — the tunnel did not carry the document")
        add(screenshot(named: "before the edge swipe"))

        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
        let across = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: across)

        XCTAssertTrue(portRow().waitForExistence(timeout: 10),
                      "the edge swipe did not pop the screen — the web view is taking the gesture "
                      + "again, which is what \"still not native\" was about")
        XCTAssertFalse(app.staticTexts["Served from the Mac"].exists,
                       "the page is still on screen after the swipe")
        // The tab bar belongs to the list, and it comes back with it. A pill
        // that stayed hidden after the page had gone would strand somebody on
        // one tab.
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5),
                      "the tab bar should be back on the list")
        add(screenshot(named: "after the edge swipe"))
    }

    /**
     * Closing the window ends the tunnel — through the verb, where it lives now.
     *
     * This is the one case in this file that is **about** the closing verb rather
     * than about leaving the page, so it is the one that walks to it: the `…` at
     * the end of the bar, then `Close this window`. Everything else here leaves
     * by the chevron, which does the same job in one tap.
     *
     * It used to be a button of its own in this screen's own toolbar — Done, the
     * seventh control that made the phone's row different from every other
     * browser window's. *"So top, header and footer, tab bar should be same in
     * all type of browsing windows."* Tearing a tunnel down is a thing you do to
     * the window rather than to the page, so it moved into the menu and the row
     * became the same six everywhere. Two taps instead of one, and the one-tap
     * way out — the chevron — is unchanged, so nothing anybody does got longer.
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

        XCTAssertTrue(browserBar().waitForExistence(timeout: 15),
                      "the browser screen should open on the tap")
        XCTAssertTrue(app.staticTexts["Served from the Mac"].waitForExistence(timeout: 30),
                      "the page never rendered — the tunnel did not carry the document")

        let more = app.buttons["localhost.settings"]
        XCTAssertTrue(more.waitForExistence(timeout: 10),
                      "the `…` is the sixth control on the bar and it is where closing this "
                      + "window lives")
        more.tap()
        let close = app.buttons["localhost.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10),
                      "the menu behind the `…` should offer Close this window — the verb that used "
                      + "to be Done in this screen's own toolbar")
        close.tap()

        XCTAssertTrue(portRow().waitForExistence(timeout: 10), "closing should come back to the list")
        XCTAssertFalse(app.staticTexts["Served from the Mac"].exists,
                       "the page is still on screen after the tunnel was closed")
    }

    // MARK: - Helpers

    private func portRow() -> XCUIElement {
        app.buttons["port.\(Self.port)"]
    }

    /**
     * Something that says the browser screen has arrived.
     *
     * `localhost.done` was this probe in five places in this file and there is no
     * Done any more: the row under a page on this phone is the same six controls
     * as the row under any other browser window, and the verb that tore the
     * tunnel down is `Close this window` inside the `…`. See `BrowserChrome`.
     *
     * **Reload rather than the address**, and the difference matters at exactly
     * the moment this is called. The bar draws Reload in every phase of a tunnel
     * — greyed while the port is still opening, live once it is — so this asks
     * *has the screen arrived*, which is the question the old Done answered and
     * the only question that can honestly be asked before any bytes have crossed.
     * The address is a **field** only once the page can be navigated, so waiting
     * on it would quietly be waiting for the tunnel as well; every case here
     * waits for the page's own text a line or two later, with a sentence saying
     * that is what it is doing.
     */
    private func browserBar() -> XCUIElement {
        app.buttons["localhost.reload"]
    }

    /**
     * Leave the page the way a thumb does, and take the tunnel with it.
     *
     * The chevron top left, which is the system's: this screen keeps the
     * navigation bar, and popping it **is** the teardown — the listener goes, the
     * Mac's socket goes, and the port is unreachable again until it is tapped.
     * That was already true when Done was a button, which is why the verb could
     * move into the `…` without the one-tap way out being lost.
     *
     * `testClosingTheViewLeavesNoPageBehind` deliberately does not come through
     * here. It is the case *about* the verb, so it walks the menu to it; this is
     * for the cases that were only ever getting off the screen.
     */
    private func leaveTheBrowser() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 10),
                      "the page keeps the system navigation bar, so there is always a chevron out "
                      + "of it")
        back.tap()
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
