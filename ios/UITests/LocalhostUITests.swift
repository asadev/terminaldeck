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
        XCTAssertTrue(backOnTheBrowserList(), "leaving should come back to the Browser list")
        // And the bar comes back with it. A hidden tab bar that stays hidden
        // after the screen it belonged to has gone is the other half of the same
        // bug, and it strands somebody on one tab.
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5),
                      "the tab bar should be back on the list")
    }

    /**
     * **The chrome on a page is the platform's: five page controls along the
     * bottom, and the window's `…` in the header.**
     *
     * ## What this case used to claim, and why the claim had to change — twice
     *
     * It was called `testTheChromeIsThePlatformsAndDoneIsLast` and its third
     * assertion pinned **Done as the last control in the row** — *"last button I
     * think is on its correct place"*, said of a row that ended with it. Done
     * left for the `…`, and the case was rewritten to pin six controls in a row
     * instead.
     *
     * Then the `…` left the row too:
     *
     * > *"Maybe we can give some better one header also, not only the bottom, so
     * > we can have most of the important controls for the flow, for this kind of
     * > things and whatever we require to get the job done."*
     *
     * So the shape this measures is a **split**, and measuring it is the whole
     * point of the case: the verbs that act on the page, below the middle of the
     * screen where a thumb is; one control that acts on the window, in the header
     * where he asked for it. A case that only counted buttons would pass with all
     * six back in the row, which is the state his sentence rejects.
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
     *     Back · Forward · Reload · Find · Inspect · Size
     *
     * Done did not disappear: tearing the tunnel down is a thing you do to the
     * *window* rather than to the page, so it is the `Close this window` card on
     * this page's own settings screen, behind `localhost.settings` in the header
     * — and `testClosingTheViewLeavesNoPageBehind` walks it there. The chevron
     * top left does exactly the same thing in one tap and always did.
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
     *  2. every control that acts on the **page** is at the *bottom* of it, and
     *     the one that acts on the **window** is in the header — both measured
     *     against the middle of the screen, not asserted by looking at the
     *     source;
     *  3. the row reads left to right as the same controls, in the same order,
     *     that `BrowserPageBar` puts under every other kind of browser window.
     *
     * The order is measured off the real frames rather than read from the source,
     * which is the half of claim 3 that is worth having: a bar assembled in the
     * right order and laid out in the wrong one passes every existence check
     * anybody would think to write. Claim 2 is measured the same way and for a
     * sharper reason now — where a control *is* is the entire requirement, so a
     * `…` that had quietly slid back down into the row would pass every
     * existence check in this repository and fail his sentence.
     *
     * `LocalhostChromeTests` is the tripwire for the same three in the unit
     * suite, which runs on a laptop with nothing listening, and
     * `BrowserPageBarUITests` asserts the same controls exist on every kind of
     * window. Neither of those can say **where on the screen** they are. This is
     * the proof of that, and it is the only one, which is why the case was
     * rewritten rather than deleted with its name.
     */
    func testTheChromeIsThePlatformsAndTheRowIsTheSharedOne() throws {
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
         * 2. Every control that acts on the page, below the middle of the screen.
         *
         * A bar that had quietly gone back to the top would still pass an
         * existence check on all five buttons, which is how the first version of
         * this screen looked correct in a test and wrong in the hand.
         *
         * They are the shared row and they are listed in the order they are meant
         * to be read: Back · Forward · Reload · Find · Inspect · Size. The `…` is
         * not among them and is asserted separately, at the other end of the
         * screen, because that is the requirement rather than an accident of
         * layout — and Size is here rather than up there because how wide the
         * page is laid out is a thing done to the **page**, over and over, while
         * comparing one width against another.
         *
         * The length of the row is pinned by these five being present **and** by
         * Done being asserted absent below, rather than by counting the buttons
         * on screen: the bar's other half is up there too — the address field, its
         * Go, the ⓘ when there is something to explain — so a raw count would be
         * a number nobody could keep true.
         */
        let middle = app.frame.midY
        let controls = ["localhost.back", "localhost.forward", "localhost.reload",
                        "localhost.find", "localhost.inspect", "localhost.size"]
        for identifier in controls {
            // Across every element type: Size is a `Menu` where the other five
            // are `Button`s, and asking `buttons` for a SwiftUI menu is how an
            // assertion comes to pass by never running.
            let button = app.descendants(matching: .any)
                .matching(identifier: identifier).firstMatch
            XCTAssertTrue(button.exists,
                          "\(identifier) is missing from the bar — the row under a page on this "
                          + "phone is the same as the row under every other browser window, "
                          + "and a shorter one is what he counted as two products")
            XCTAssertGreaterThan(button.frame.minY, middle,
                                 "\(identifier) is in the top half of the screen; browser controls "
                                 + "belong at the bottom on iOS")
        }
        XCTAssertLessThan(bar.frame.maxY, middle, "the navigation bar should be above the page")

        /*
         * And the sixth control, at the other end of the screen, which is the
         * point of this half of the case.
         *
         * > *"Maybe we can give some better one header also, not only the bottom,
         * > so we can have most of the important controls for the flow, for this
         * > kind of things and whatever we require to get the job done."*
         *
         * `localhost.settings` is the `…`. It kept its name when it moved, so
         * nothing else in this repository had to move — and its **frame** is the
         * whole assertion, because a `…` back in the bottom row would pass every
         * existence check anybody would write and would be the state he rejected.
         * Inside the navigation bar's own rectangle rather than merely above the
         * middle: that is the difference between *it is in the header* and *it
         * happens to be drawn high up*.
         */
        let more = app.buttons["localhost.settings"]
        XCTAssertTrue(more.exists,
                      "the `…` is missing — the header is a chevron, one line of title and this, "
                      + "and \"not only the bottom\" is the sentence it answers")
        XCTAssertLessThan(more.frame.maxY, middle,
                          "the `…` is in the bottom half of the screen; it belongs in the header")
        XCTAssertTrue(bar.frame.contains(CGPoint(x: more.frame.midX, y: more.frame.midY)),
                      "the `…` should be inside the navigation bar itself, on the trailing side — "
                      + "drawn high on the page is not the same thing as being in the header")
        XCTAssertGreaterThan(more.frame.midX, bar.frame.midX,
                             "and on the trailing side of it, opposite the chevron")

        // And Done is gone from the row rather than merely unused. A Done left
        // standing in the row would make this bar one control longer than every
        // other one, which is where this round started.
        XCTAssertFalse(app.buttons["localhost.done"].exists,
                       "Done left the row; closing the window is a card on this page's own "
                       + "settings screen behind the `…` now")

        /*
         * 3. The order, left to right, read off the real frames rather than off
         *    the declaration — because a `Spacer` in the wrong place reorders
         *    what a thumb sees without touching what the source says.
         *
         * *"Last button I think is on its correct place"* was said of a row that
         * ended with Done. What ends the row now is Inspect, and the control that
         * used to end it is up in the header — asserted above.
         */
        let byPosition = controls
            .map { (id: $0,
                    x: app.descendants(matching: .any)
                        .matching(identifier: $0).firstMatch.frame.midX) }
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
     * **The page can be looked at at other widths, and the menu is names only.**
     *
     * > *"they can use the the mode currently we have this machine they can just
     * > browse as phone view and it should have all the by the way views also
     * > they can pinch and zoom also they can see all the different dimensions in
     * > responsive views how it will look like in mobile how it will look like on
     * > Windows so they can have different dimensions also in phone just like
     * > MacBook."*
     *
     * Two claims, and the second one is about him rather than about layout.
     *
     * **The widths are there and they work.** The control is in the bottom row
     * with the other page verbs, it opens onto the five widths, and choosing one
     * leaves the page on screen — which is the thing a re-layout can break and a
     * scaled screenshot cannot. What a test cannot honestly assert is what the
     * page *looks* like at 1280: that is a picture, and the picture is the
     * attachment. `LocalhostChromeTests` holds the claim underneath it — that the
     * width is the web view's own rather than a transform the document cannot
     * see — because that is the half that could be faked and still photograph
     * correctly.
     *
     * **Every row is a name.** *"you are also putting so much of a description
     * under the title of that thing under the title of the feature instead of
     * just i button or nothing maybe so they have becomes too big."* So the
     * labels are read off the real menu and checked for being names — the width
     * and nothing else, no sentence, nothing under them. A menu that grew an
     * explanation per row would pass every existence check anybody would write
     * and would be the thing he asked twice to have removed.
     *
     * Nothing is dismissed by hand: choosing a width closes the menu, which is
     * also what a person does. `dismissAnyMenu` taps low on the screen and this
     * menu is presented **from** the bottom bar, so a blind dismiss here would
     * land on the control that opened it.
     */
    func testThePageCanBeLookedAtAtOtherWidths() throws {
        let row = portRow()
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "no row for port \(Self.port) — is .harness/.devsite/server.mjs running?")
        row.tap()

        XCTAssertTrue(browserBar().waitForExistence(timeout: 15),
                      "the browser screen should open on the tap")
        XCTAssertTrue(app.staticTexts["Served from the Mac"].waitForExistence(timeout: 30),
                      "the page never rendered — the tunnel did not carry the document")
        add(screenshot(named: "the page at this phone's width"))

        let size = any("localhost.size")
        XCTAssertTrue(size.exists,
                      "Size is one of the page verbs and belongs in the bottom row with them")
        XCTAssertGreaterThan(size.frame.minY, app.frame.midY,
                             "it is pressed over and over while comparing one width against "
                             + "another, so it belongs under a thumb rather than in the header")
        size.tap()

        let widths = [("localhost.size.0", "This phone"),
                      ("localhost.size.390", "Phone 390"),
                      ("localhost.size.834", "Tablet 834"),
                      ("localhost.size.1280", "Laptop 1280"),
                      ("localhost.size.1440", "Desktop 1440")]
        for (identifier, name) in widths {
            let item = any(identifier)
            XCTAssertTrue(item.waitForExistence(timeout: 6),
                          "\(name) should be in the menu — \"different dimensions\" is five real "
                          + "ones, not a slider that asks him to know the answer")
            let label = item.label
            XCTAssertTrue(label.contains(name), "\(identifier) reads \"\(label)\"")
            XCTAssertFalse(label.contains("."),
                           "\"\(label)\" is a sentence. A menu row is a name he can point at, and "
                           + "the explanation goes on the ⓘ or nowhere")
            XCTAssertLessThan(label.count, name.count + 14,
                              "\"\(label)\" has grown a description under its title, which is the "
                              + "thing that made these lists too big to read")
        }

        // And the three that magnify rather than re-lay-out, which are the pinch
        // as buttons: a page laid out at 1440 on a phone needs a way back to a
        // readable scale that does not depend on landing a two-finger gesture.
        for (identifier, name) in [("localhost.size.in", "Zoom in"),
                                   ("localhost.size.out", "Zoom out"),
                                   ("localhost.size.actual", "Actual size")] {
            XCTAssertTrue(any(identifier).exists, "\(name) should be in the menu")
        }
        add(screenshot(named: "the widths on offer"))

        any("localhost.size.1280").tap()
        XCTAssertTrue(app.staticTexts["Served from the Mac"].waitForExistence(timeout: 20),
                      "the page should survive being laid out at 1280 — a width that loses the "
                      + "document is worse than no width at all")
        add(screenshot(named: "the page at laptop width"))

        // A pinch on the page itself, which is the half of his sentence that is
        // a gesture. What a test can hold on to is that it does not wedge the
        // page: the document is still there and the bar is still under it, on the
        // address row rather than swapped for something else.
        let page = app.webViews.firstMatch
        if page.exists {
            page.pinch(withScale: 2.2, velocity: 1.2)
            add(screenshot(named: "the page pinched"))
            page.pinch(withScale: 0.4, velocity: -1.2)
        }
        XCTAssertTrue(app.textFields["localhost.address"].exists,
                      "and the bar should still be under it with the address on it")

        size.tap()
        any("localhost.size.0").tap()
        XCTAssertTrue(app.staticTexts["Served from the Mac"].waitForExistence(timeout: 20),
                      "and back to this phone's own width, which is where it started")
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

        XCTAssertTrue(backOnTheBrowserList(),
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
     * the window rather than to the page, so it moved off the row and the row
     * became the same everywhere. Two taps instead of one, and the one-tap
     * way out — the chevron — is unchanged, so nothing anybody does got longer.
     *
     * ## Where it moved to, and why that changed again
     *
     * For one round it was the single item in a menu the `…` opened, because a
     * page over a tunnel had no settings screen anywhere. It has one now — the
     * same `MachineWindowSettingsView` a window on the machine opens, handed this
     * page's tab — and Close is a card on it:
     *
     * > *"all of them should have all the options. Should not be that much of
     * > difference in all of them."*
     *
     * So this walks the same two taps it always did, and the second one lands on
     * a screen instead of in a menu: `localhost.settings` in the header, then
     * `browser.phone.page.close`.
     *
     * The pop afterwards is worth a word, because nothing on that settings screen
     * dismisses itself — deliberately, so that a screen is never yanked out from
     * under a thumb. `LocalhostBrowser` watches the tab instead and leaves when
     * the store stops listing it, which takes the settings screen with it. That
     * is the same watcher a window on the machine has always had, and this case
     * is what proves it fires.
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
                      "the `…` is in this page's header and it is the way to everything this "
                      + "window can be asked for, closing it included")
        more.tap()
        let close = app.buttons["browser.phone.page.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 15),
                      "the `…` should open this page's own settings, and Close this window should "
                      + "be a card on it — the verb that used to be Done in this screen's own "
                      + "toolbar, on the same screen a window on the machine gets")
        close.tap()

        XCTAssertTrue(backOnTheBrowserList(), "closing should come back to the Browser list")
        XCTAssertFalse(app.staticTexts["Served from the Mac"].exists,
                       "the page is still on screen after the tunnel was closed")
    }

    // MARK: - Helpers

    private func portRow() -> XCUIElement {
        app.buttons["port.\(Self.port)"]
    }

    /**
     * One element by identifier, across every element type.
     *
     * Size is a SwiftUI `Menu` and its rows are `Toggle`s inside one; what
     * XCUITest classifies either of those as is not a thing to have an opinion
     * about. `BrowserPageBarUITests` learned this on the canvas — asking
     * `otherElements` for it found nothing and skipped a case silently, which is
     * the shape of a test that never runs.
     */
    private func any(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /**
     * Something that says the browser screen has arrived.
     *
     * `localhost.done` was this probe in five places in this file and there is no
     * Done any more: the row under a page on this phone is the same controls
     * as the row under any other browser window, and the verb that tore the
     * tunnel down is the `Close this window` card on this page's own settings
     * screen, behind the `…` in the header. See `BrowserChrome`.
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
    /**
     * Back on the Browser tab's own list.
     *
     * **Not** `portRow()`, and this is the mistake this replaced. The ports live
     * in the **New window** sheet, and opening a page from that sheet dismisses
     * it — so every way out of a page (the old Done, the chevron, the edge swipe,
     * closing the tunnel) lands on the Browser tab's *home*, where there is no
     * port row and never was one. Measured 2026-08-25 against a live host: all
     * three cases that asked for a port row after leaving failed on the commit
     * *before* the chrome was unified, and failed in exactly the same way after,
     * while the app was behaving perfectly on screen. A test that can only pass
     * where the app is wrong is worse than no test.
     *
     * The navigation bar is the honest question — *is the list on screen* — and
     * it is one query rather than a proxy for one.
     */
    private func backOnTheBrowserList() -> Bool {
        app.navigationBars["Browser"].waitForExistence(timeout: 10)
    }

    /**
     * Out by the chevron, which is what a thumb does.
     *
     * **The `…` is in this header too now**, so *the first button in the
     * navigation bar* stopped being a safe way to name the chevron: it is the
     * leading item and it does come first, but that is an ordering nothing in
     * this file controls, and a run that tapped the trailing item instead would
     * push the settings screen and then fail somewhere else entirely with a
     * message about a page that did not close.
     *
     * So it is named by what it is not. There is no identifier on a system back
     * button to ask for, and excluding the one control up there that *does* have
     * a name is the honest way to say *the other one*.
     */
    private func leaveTheBrowser() {
        let back = app.navigationBars.buttons
            .matching(NSPredicate(format: "NOT (identifier == %@)", "localhost.settings"))
            .element(boundBy: 0)
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
