/**
 * The screens the 2026-08-17 review changed, photographed in both appearances
 * and driven rather than described.
 *
 * `AppearanceShotsUITests` walks the app as it was and measures whether each
 * frame followed the appearance. This is the same apparatus pointed at what
 * moved: the four pills with the copilot leftmost, the swipe actions on a
 * session row, the archive they put things into, and the `+` that opens an
 * address on the machine.
 *
 * ## Why a suite of its own rather than four more stops on that tour
 *
 * Because the two need different hosts and the split is not arbitrary. The
 * product's own headless host serves sessions, folders and — critically — real
 * ports, which is what the localhost half needs; it has no copilot layer at all,
 * because `src/headless/host.ts` injects no `CopilotRuns`. The stand-in has the
 * opposite shape: it will hand out a copilot code and implements no `ports`
 * handler. One tour against one host would be photographs of empty screens
 * either way, so there are two cases and each skips when its host is absent,
 * which is this target's standing rule.
 *
 * ## What a photograph proves and what it does not
 *
 * The frames are the deliverable — somebody looks at them before deciding to
 * ship — and the assertions beside them are what stops a green run from meaning
 * nothing. Each frame is measured for mean luminance against the appearance it
 * was supposed to be taken in, exactly as the other suite does, because a screen
 * that did not change sides is the failure that looks like success in a log. The
 * swipe cases assert on the *buttons the gesture revealed*, because a swipe that
 * scrolled the list instead would photograph a list that looks perfectly fine.
 */

import UIKit
import XCTest

/// Long enough for the app's own give-up deadline to have fired, plus room for a
/// simulator under load. `PortTunnel.openTimeout` is twenty seconds and this
/// target cannot import it — a UI test runs in a different process from the app
/// — so the number is written here with the reason rather than shared, and the
/// unit suite is what pins the app's side of it.
private let PortTunnelSettleTimeout: TimeInterval = 45

final class ReviewScreensUITests: XCTestCase {

    private var app: XCUIApplication!

    private func env(_ name: String) -> String {
        ProcessInfo.processInfo.environment[name] ?? ""
    }

    private var readyFile: String { env("TD_READY_FILE") }
    private var codeFile: String { env("TD_CODE_FILE") }
    private var control: String { env("TD_CONTROL") }
    private var shots: String { env("TD_SHOTS") }

    private var expecting: Scheme = .dark

    private enum Scheme: String {
        case dark
        case light

        var segment: String { self == .dark ? "Dark" : "Light" }

        /// The same bands `AppearanceShotsUITests` measured, and for the same
        /// reason: the point is not to grade the palette — `AppearanceTests`
        /// does that arithmetically — it is to catch a screen that did not
        /// change sides at all.
        var luminanceRange: ClosedRange<Double> { self == .dark ? 0.0 ... 0.42 : 0.58 ... 1.0 }
    }

    private static let noLiveHost =
        "No live desktop. Run the review-shots runner, which starts out/headless/host.mjs under "
        + "its own HOME and passes TD_READY_FILE / TD_CODE_FILE."

    private static let noStandIn =
        "No stand-in. Start ios/Harness/run.sh host --copilot alter --approve-after 3000 and pass "
        + "TEST_RUNNER_TD_CONTROL=127.0.0.1:8788."

    // MARK: - Against the product's own headless host

    /**
     * The session list, its two swipes, the archive, and the Localhost tab's `+`.
     *
     * Every one of these is a thing he asked for by name and every one of them
     * had to be looked at rather than compiled: a swipe action that is declared
     * but sits under a row that is not in a `List` simply does not appear, and
     * nothing in a build log says so.
     */
    func testTheSwipeTheArchiveAndTheAddressField() throws {
        try XCTSkipIf(readyFile.isEmpty, Self.noLiveHost)
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        try connectToTheLiveHost()
        try ensureThereIsSomethingToSwipe()

        for scheme in [Scheme.dark, Scheme.light] {
            try choose(scheme)
            try theFourPills(scheme)
            try theSwipeOnASession(scheme)
            try theArchive(scheme)
            try theAddressField(scheme)
        }
    }

    /**
     * The `+` all the way through to a rendered page, in one case of its own.
     *
     * Separate from the tour above because it is the one claim here that depends
     * on the **machine** rather than on the phone: a typed port becomes
     * `tunnel.open`, and the desktop answers it only after a fresh port scan
     * that it may decline. The tour's version photographs the sheet and the
     * refusal, which are entirely this app's own behaviour; this one waits for
     * bytes to come back from the far end, which is a slower and more fragile
     * thing to assert and deserves to fail on its own rather than take nine
     * frames down with it.
     *
     * Written against `TD_PAGE_PORT`, which the runner serves on the loopback.
     */
    func testTypingAnAddressOpensThatPageFromTheMachine() throws {
        try XCTSkipIf(readyFile.isEmpty, Self.noLiveHost)
        let port = env("TD_PAGE_PORT")
        try XCTSkipIf(port.isEmpty, "no TD_PAGE_PORT — nothing is being served to open")
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        try connectToTheLiveHost()

        XCTAssertTrue(app.openLocalhostList())
        /*
         * The bar is on the screen now — there is no `+` to press first and no
         * Go button to press after. It was a sheet behind a `+` until
         * 2026-08-24: *"we should have only one which will be called browser…
         * where we can browse the localhost, we can type."* Typing and a return
         * key is the whole interaction, which is what `onSubmit` is.
         */
        let field = app.textFields["browser.address"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("localhost:\(port)/index.html\n")

        /*
         * The page's own `<title>`, in the navigation bar.
         *
         * That string is the proof and nothing weaker will do. The name at the
         * top falls back to the address, and to `localhost:<port>` before there
         * is even that, so waiting for the screen — or for any control on its bar,
         * every one of which is drawn in all three phases of a tunnel, greyed
         * until it can act — would pass over a tunnel that never opened. This is
         * bytes from the machine, rendered.
         */
        let title = app.staticTexts["Basket"]
        XCTAssertTrue(title.waitForExistence(timeout: 60),
                      "the machine never served the page — the tunnel stayed in `opening`")
        expecting = .dark
        capture("page-from-the-machine", measured: false)
        // Out by the chevron. Leaving the screen is the teardown — it always was,
        // which is why the verb could move into the `…` as `Close this window`.
        leaveThePage()
    }

    /**
     * The same journey through the **list** instead of the field, as a control.
     *
     * It exists to answer one question and it is the question a failure of the
     * case above immediately raises: *did the address field break this, or was
     * tunnelling already like that here?* Tapping a row is the path that has
     * shipped for weeks and touches none of this round's code, so the two
     * together separate "the parse is wrong" from "the tunnel does not open on
     * this machine".
     *
     * Deliberately asserts nothing about which port. Whatever the machine is
     * serving, the first row of the first group is a real one.
     */
    func testTappingAListedPortReachesTheSamePlace() throws {
        try XCTSkipIf(readyFile.isEmpty, Self.noLiveHost)
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        try connectToTheLiveHost()

        XCTAssertTrue(app.openLocalhostList())
        let headers = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'localhost.section.'"))
        XCTAssertTrue(headers.firstMatch.waitForExistence(timeout: 30),
                      "the machine's ports should arrive and be grouped")
        for index in 0 ..< headers.count where headers.element(boundBy: index).label.contains("Folded") {
            headers.element(boundBy: index).tap()
        }
        expecting = .dark
        capture("control-01-localhost-list", measured: false)

        let row = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'port.' AND NOT identifier CONTAINS 'more'"))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "something should be listening")
        row.tap()
        // Reload rather than Done, which no longer exists: the bar under a page
        // on this phone is the same six controls as the bar under every other
        // browser window, and it is drawn as soon as the screen is.
        XCTAssertTrue(app.buttons["localhost.reload"].waitForExistence(timeout: 30))
        sleep(20)
        capture("control-02-localhost-page", measured: false)
        leaveThePage()
    }

    /// The tab bar itself, which is the change he stated most plainly.
    private func theFourPills(_ scheme: Scheme) throws {
        app.openSessionsTab()
        XCTAssertTrue(app.buttons["sessions.more"].waitForExistence(timeout: 20),
                      "the session list should be on screen")

        let bar = app.tabBars.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "there should be a tab bar")
        for name in ["Copilot", "Sessions", "Localhost", "Settings"] {
            XCTAssertTrue(bar.buttons[name].exists, "\(name) should be a pill")
        }
        XCTAssertEqual(bar.buttons.count, 4, "four pills, and only four")

        // Leftmost, which is the half of the instruction a membership check
        // would miss. The frames are compared rather than the labels: a bar with
        // the right four pills in the wrong order is a bar somebody's thumb has
        // to relearn.
        let copilot = bar.buttons["Copilot"].frame
        for name in ["Sessions", "Localhost", "Settings"] {
            XCTAssertLessThan(copilot.minX, bar.buttons[name].frame.minX,
                              "the copilot should be to the left of \(name)")
        }
        capture("\(scheme.rawValue)-01-four-pills")
    }

    /**
     * Swipe a session row both ways and photograph what appears.
     *
     * The assertion is on the revealed buttons rather than on the frame,
     * because the failure this is written against is silent: `.swipeActions`
     * outside a `List` compiles, draws nothing, and leaves a horizontal drag
     * scrolling — which is exactly the *"swipe currently just opens the session,
     * which tapping already does"* state he objected to.
     */
    private func theSwipeOnASession(_ scheme: Scheme) throws {
        app.openSessionsTab()
        let row = firstSessionRow()
        XCTAssertTrue(row.waitForExistence(timeout: 30), "there should be a session to swipe")

        row.swipeLeft()
        let archive = app.buttons.matching(NSPredicate(format: "label == %@", "Archive")).firstMatch
        XCTAssertTrue(archive.waitForExistence(timeout: 5),
                      "a left swipe should reveal Archive, not scroll the list")
        /*
         * And Close, which is the third of the three he asked for and the one
         * that spent a week absent because no verb on the wire could perform it.
         *
         * Asserted here rather than in a case of its own because it is a
         * property of *this gesture*: `closeAction` is drawn only when the
         * machine advertised `close`, so a swipe with no Close on it is either a
         * host that cannot end a session or a capability that stopped being
         * read — and both of those look like a perfectly ordinary swipe in a
         * screenshot. The headless host this suite runs against can, so its
         * absence is a failure.
         */
        let close = app.buttons.matching(NSPredicate(format: "label == %@", "Close")).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5),
                      "the trailing swipe should offer Close against a host that advertises it")
        // SwiftUI lays a trailing swipe out from the edge inwards, so the
        // first-declared action is the one furthest right — the one a thumb
        // reaches first coming off the edge, and the one that has to be the most
        // deliberate. Measured rather than assumed: the declaration order and
        // the drawn order are opposite, which is exactly the kind of thing a
        // reader of the view code gets backwards.
        XCTAssertGreaterThan(close.frame.minX, archive.frame.minX,
                             "Close is the outermost action, with the reversible one inside it")
        capture("\(scheme.rawValue)-02-swipe-trailing")
        /*
         * The confirmation, opened and then declined.
         *
         * *"Close the session (with a confirmation)."* Photographed because the
         * sentence in it is the last thing a person reads before work stops, and
         * **declined** because the assertion worth making here is that Cancel
         * leaves the session alone — a confirmation whose Cancel still closed
         * the row would pass every test that only checked the alert appeared.
         * Closing for real is a different case; this tour is nine frames long
         * and must not end by destroying the row the rest of it needs.
         */
        close.tap()
        let confirm = app.buttons.matching(identifier: "close.confirm").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5),
                      "Close should ask before it does anything")
        capture("\(scheme.rawValue)-02b-close-confirmation")
        app.buttons["Cancel"].tap()
        sleep(1)
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "declining the confirmation should leave the session exactly where it was")
        // Put the row back before the next gesture: a row left open swallows the
        // swipe that follows it and the next frame is of the same buttons.
        row.swipeRight()
        sleep(1)

        row.swipeRight()
        let pin = app.buttons.matching(NSPredicate(format: "label == 'Pin' OR label == 'Unpin'")).firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 5), "a right swipe should reveal Pin")
        capture("\(scheme.rawValue)-03-swipe-leading")
        pin.tap()
        sleep(1)
        capture("\(scheme.rawValue)-04-pinned")

        // And unpin it, so the next appearance's pass starts where this one did.
        row.swipeRight()
        let unpin = app.buttons.matching(NSPredicate(format: "label == 'Unpin'")).firstMatch
        if unpin.waitForExistence(timeout: 5) { unpin.tap() }
        sleep(1)
    }

    /**
     * Archive a row, look at where it went, and put it back.
     *
     * The round trip is the assertion. An archive that could not be undone is a
     * delete with a friendlier word on it, and this app cannot delete a session
     * at all — so the important frame is not the archived list, it is the
     * session list afterwards with the row back on it.
     */
    private func theArchive(_ scheme: Scheme) throws {
        app.openSessionsTab()
        let row = firstSessionRow()
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        let identifier = row.identifier

        row.swipeLeft()
        let archive = app.buttons.matching(NSPredicate(format: "label == %@", "Archive")).firstMatch
        XCTAssertTrue(archive.waitForExistence(timeout: 5))
        archive.tap()
        sleep(1)
        XCTAssertFalse(app.buttons[identifier].exists, "the archived row should leave the list")
        capture("\(scheme.rawValue)-05-list-after-archiving")

        app.buttons["sessions.more"].tap()
        let entry = app.buttons["sessions.archived"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "the menu should offer the archive")
        entry.tap()
        XCTAssertTrue(app.buttons["archived.done"].waitForExistence(timeout: 10),
                      "the archived screen should open")
        sleep(1)
        capture("\(scheme.rawValue)-06-archived")

        let archivedRow = app.buttons["archived.session.\(identifier.replacingOccurrences(of: "session.", with: ""))"]
        XCTAssertTrue(archivedRow.waitForExistence(timeout: 5), "the row should be in here")
        archivedRow.swipeLeft()
        let back = app.buttons.matching(NSPredicate(format: "label == %@", "Put back")).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "the same gesture should undo it")
        back.tap()
        sleep(1)
        capture("\(scheme.rawValue)-07-archive-emptied")
        app.buttons["archived.done"].tap()

        XCTAssertTrue(app.buttons[identifier].waitForExistence(timeout: 10),
                      "and the row should be back on the list")
    }

    /**
     * The address bar, and where a real site goes.
     *
     * **The assertion here changed on 2026-08-24 and the safety property did
     * not.** A site on the internet used to be *refused*, with a paragraph
     * explaining that it would otherwise load on the phone rather than on the
     * machine. That was true and it was the wrong conclusion — the machine has a
     * browser, this app can open a page in it and can cast it back — so it is
     * opened **there** now and appears under Windows on this same screen.
     *
     * What must still never happen is the thing the old assertion was guarding:
     * the page loading *on the phone*. That would come up looking perfectly
     * correct and be a lie about which computer it ran on. So the proof is
     * two-sided — the app says it went to the machine, and no local page screen
     * opened.
     */
    private func theAddressField(_ scheme: Scheme) throws {
        XCTAssertTrue(app.openLocalhostList(),
                      "the localhost list is one row down the Browser tab's menu — see TabNavigation")
        let field = app.textFields["browser.address"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the bar should be on the screen")
        capture("\(scheme.rawValue)-08-open-address")

        field.tap()
        field.typeText("example.com\n")
        let toast = app.staticTexts["localhost.list.toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 5),
                      "a site on the internet should open on the machine, and be said to")
        /*
         * Nothing opened on this phone.
         *
         * Asked of Reload on the page's own bar, which is drawn in every phase of
         * a tunnel — greyed while the port is opening, live once it is — so this
         * is false whether a page half-opened or never started. The line it
         * replaces asked for `localhost.page.done`, an identifier that never
         * existed in this app at all, which meant this assertion had been passing
         * unconditionally since it was written.
         */
        XCTAssertFalse(app.buttons["localhost.reload"].exists,
                       "and it must not have loaded on the phone")
        capture("\(scheme.rawValue)-09-open-address-refused")

        // Now a real one, on the port this run's own page is served from, at a
        // path — which is the thing that was unreachable from this app before
        // the field existed.
        let port = env("TD_PAGE_PORT")
        // Nothing to dismiss any more — the bar is the screen, not a sheet over
        // it — so a run with no page to serve simply stops here.
        guard !port.isEmpty else { return }
        field.tap()
        // The bar clears itself on a send that went somewhere, so there is
        // usually nothing to select; the long press stays for the run where the
        // previous line was refused and left its text standing.
        field.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 3) { app.menuItems["Select All"].tap() }
        field.typeText("localhost:\(port)/index.html\n")

        /*
         * Photographed **settled**, whichever way it settles.
         *
         * Three outcomes are possible here and only one of them is this app's
         * doing: the machine serves the page, the machine refuses the port, or
         * the machine says nothing at all — which is what a desktop with the
         * `localhost` capability but no tunnel hub does, and which used to leave
         * this screen spinning indefinitely. `PortTunnel.openTimeout` is the fix
         * and it takes twenty seconds to fire, so a frame taken four seconds in
         * is a photograph of a spinner in every one of the three cases and
         * proves nothing about any of them.
         *
         * So this waits for a settled screen rather than a fixed number of
         * seconds, and it asserts only that one arrives. Which of the three it
         * is belongs to the machine; that the phone reaches an end state at all
         * belongs here.
         */
        XCTAssertTrue(app.buttons["localhost.reload"].waitForExistence(timeout: 40),
                      "the browser screen should open")
        let settled = NSPredicate(format: "exists == true")
        let outcome = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Basket' OR label CONTAINS 'is closed' "
                        + "OR label CONTAINS 'did not answer'")).firstMatch
        expectation(for: settled, evaluatedWith: outcome)
        waitForExpectations(timeout: PortTunnelSettleTimeout)
        capture("\(scheme.rawValue)-10-typed-address-settled", measured: false)
        leaveThePage()
        sleep(1)
    }

    /**
     * Start a couple of sessions, because a fresh host has none.
     *
     * Two rather than one, and the second is what makes the pin frame worth
     * taking: pinning the only row in a list moves nothing, so a screenshot of
     * it would prove exactly as much as a screenshot of the list.
     *
     * Each is started and then **left**, through the navigation bar's own back
     * button. Leaving a terminal pushed would put the rest of the tour inside
     * it, which is how the other suite's first run ended up photographing a web
     * page nine times.
     */
    private func ensureThereIsSomethingToSwipe() throws {
        app.openSessionsTab()
        while sessionRowCount() < 2 {
            let new = app.buttons["sessions.new"]
            XCTAssertTrue(new.waitForExistence(timeout: 30),
                          "the host granted folders, so New Session should be offered")
            new.tap()
            let inMenu = app.buttons["sessions.newDefault"]
            if inMenu.waitForExistence(timeout: 4) { inMenu.tap() }

            let terminal = app.descendants(matching: .any)["terminal.view"]
            XCTAssertTrue(terminal.waitForExistence(timeout: 60), "the session should open its terminal")
            sleep(2)
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists { back.tap() }
            XCTAssertTrue(app.buttons["sessions.more"].waitForExistence(timeout: 20),
                          "and leaving it should land back on the list")
            sleep(1)
        }
    }

    private func sessionRowCount() -> Int {
        app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'session.' AND NOT identifier CONTAINS 'swipe'"))
            .count
    }

    /// The first session card on the list. By prefix, because a session id is
    /// minted by the machine and is not knowable from a test.
    /**
     * How many session rows the list is drawing, counted strictly.
     *
     * `sessionRowCount()` above matches everything whose identifier starts with
     * `session.` and is not a swipe, which is right for the tour and was wrong
     * the moment a *modal* went up over the list: an alert's own button and the
     * long-press menu's item are both named for the session they are about, and
     * both were counted as rows. This matches a row and nothing else — an id
     * with no further dots in it, which is what `session.<uuid>` is and what
     * `session.swipe.close.<uuid>` and `session.details` are not.
     */
    private func openableRows() -> Int {
        app.buttons
            .matching(NSPredicate(format: "identifier MATCHES %@", "session\\.[^.]+"))
            .count
    }

    private func firstSessionRow() -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'session.' AND NOT identifier CONTAINS 'swipe'"))
            .firstMatch
    }

    /**
     * Leave a page this phone is holding open, and take its tunnel with it.
     *
     * Three cases in this file used to tap `localhost.done`, and there is no
     * Done: the row under a page on this phone is now the same six controls as
     * the row under every other browser window — *"top, header and footer, tab
     * bar should be same in all type of browsing windows"* — and the verb that
     * tore the tunnel down is `Close this window` inside the `…`.
     *
     * The chevron rather than that menu item, because none of the three cases is
     * **about** closing: all three photograph a page and then need to be off it
     * before the next frame is taken. Popping the screen is the whole
     * teardown — the listener goes, the machine's socket goes — which is exactly
     * why the verb could move into a menu without anybody losing a one-tap way
     * out. `LocalhostUITests` is where the menu item itself is walked.
     */
    private func leaveThePage() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 10),
                      "a page from the machine keeps the system navigation bar, so there is always "
                      + "a chevron out of it")
        back.tap()
    }

    // MARK: - Against the stand-in, which is the only host with a copilot

    /**
     * Closing a session from the swipe, for real, all the way to the row going.
     *
     * ## Why this is a case of its own and against the stand-in
     *
     * The tour above opens the confirmation and **cancels** it, because it has
     * seven frames left to take and the row is what they are of. The half that
     * matters most is the one it cannot make: that pressing through actually
     * ends the session on the machine and that the list stops drawing it.
     *
     * Against the stand-in because that host is the one this suite may destroy
     * something on — it is a throwaway process holding throwaway shells, and it
     * implements `close` by genuinely killing the pty rather than answering that
     * it did. A host that reported a close it had not performed would let this
     * case pass over a session that quietly stayed alive, which is precisely the
     * false verification this whole file's header is about.
     *
     * ## What is asserted, in order
     *
     * The button exists (the capability crossed the wire), the alert appears
     * (nothing is destroyed by one tap), the row is *still there* while the
     * question is up, and only then — after the confirmation — does the count
     * drop by one. The count rather than the identifier, because the identifier
     * of the first row changes when the list reorders and a test that watched
     * one row could pass on a list that had simply been sorted.
     */
    func testClosingASessionEndsItOnTheMachine() throws {
        try XCTSkipIf(control.isEmpty, Self.noStandIn)
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        app.forgetEveryMachine()
        // The pairing screen, before a code is typed into it, because that is
        // where the two device kinds are now explained — *"My device"* and
        // *"Guest — You choose what they can reach. The copilot is never
        // shared."* The choice is made on the other machine and this phone
        // cannot influence it, which is exactly why the person typing the code
        // has to be able to read it before they hand it over.
        XCTAssertTrue(app.reachPairingField(timeout: 30))
        // `.any` rather than a type: the cards are `.accessibilityElement
        // (children: .combine)`, which collapses each into a single element
        // whose type is UIKit's business and not this test's.
        let mine = app.descendants(matching: .any).matching(identifier: "pairing.kind.mine").firstMatch
        let guest = app.descendants(matching: .any).matching(identifier: "pairing.kind.guest").firstMatch
        XCTAssertTrue(mine.waitForExistence(timeout: 10),
                      "the pairing screen should say what My device means")
        XCTAssertTrue(guest.exists,
                      "and what Guest means, including that the copilot is never shared")
        XCTAssertTrue(guest.label.contains("never shared"),
                      "the sentence that is not derivable from anything else on either screen")
        // The keypad covers the lower half of this screen, and the cards live
        // under the field. Dismissing it is what makes the frame a photograph of
        // the thing being asserted.
        app.swipeDown()
        sleep(1)
        _ = capture("standin-pairing-kinds", measured: false)

        try pairWithTheStandIn()
        // Dark, chosen through the app's own control rather than the phone's.
        //
        // Both appearances matter for a destructive confirmation more than for
        // most screens — red on a dark sheet is the one colour pair that can go
        // wrong — and the app's setting is sticky across runs, so a case that
        // did not choose would photograph whatever the last one left behind.
        // The light frames of the same screens are the tour's, which walks both.
        try choose(.dark)
        try ensureThereIsSomethingToSwipe()

        let before = openableRows()
        XCTAssertGreaterThanOrEqual(before, 2, "there should be more than one session to close one")

        let row = firstSessionRow()
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.swipeLeft()

        let close = app.buttons.matching(NSPredicate(format: "label == %@", "Close")).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5),
                      "the stand-in advertises `close`, so the swipe should offer it")
        _ = capture("standin-swipe-with-close", measured: false)
        close.tap()

        let confirm = app.buttons.matching(identifier: "close.confirm").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Close should ask first")
        XCTAssertEqual(openableRows(), before,
                       "nothing may be closed while the question is still on screen")
        _ = capture("standin-close-confirmation", measured: false)

        confirm.tap()
        // The row goes on the machine's answer, not on the tap — so this waits
        // for a round trip rather than asserting immediately. Three seconds is
        // generous for a relay on the loopback and short enough that a `closed`
        // that never arrives fails rather than hangs.
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline && openableRows() >= before { usleep(300_000) }
        XCTAssertEqual(openableRows(), before - 1,
                       "the machine ended the session, so the list should have one row fewer")
        _ = capture("standin-close-after", measured: false)
    }

    /**
     * The copilot as a tab: its own pill, its own title with the machine on it,
     * and the tab bar still under it.
     *
     * That last assertion is the one worth having. While the copilot was a
     * pushed screen it hid the bar, correctly — it ends in a composer and that
     * is the pill complaint exactly. As a tab it cannot: there is no chevron
     * over a tab's root and no gesture that pops one, so a copilot tab that hid
     * the bar would be a screen with no way out of it.
     */
    func testTheCopilotIsATabAndHasItsOwnWayHome() throws {
        try XCTSkipIf(control.isEmpty && readyFile.isEmpty, Self.noStandIn)
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        // Either host will do for this one, and the difference only decides
        // which of the eight access states the screen is in — all of which are
        // real screens worth photographing. The stand-in hands out a copilot
        // code; a live desktop may already have granted this phone one. What is
        // being asserted is the *pill*, which is the same either way.
        if readyFile.isEmpty {
            app.forgetEveryMachine()
            try pairWithTheStandIn()
        } else {
            try connectToTheLiveHost()
        }

        for scheme in [Scheme.dark, Scheme.light] {
            try choose(scheme)
            /*
             * **Whichever of the two shapes this phone is in, photograph the
             * copilot.**
             *
             * The pill exists only for a machine whose copilot this phone has
             * connected — *"if the copilot is not connecting, this icon should
             * not be inside the pill"* — and which of those two this run is in
             * depends on the host it was pointed at. So it takes the pill when
             * there is one and the Settings row when there is not, and both are
             * a real screen worth a frame.
             */
            if app.openCopilotTab() {
                sleep(2)
                // The bar is **not** over the composer, and the way home is the
                // chevron this screen draws for itself: *"pill should not be
                // inside the chat box — there should be a back button to go back
                // on home."*
                XCTAssertFalse(app.tabBars.firstMatch.exists,
                               "either we will type or we will use the pill")
                XCTAssertTrue(app.buttons["copilot.back"].exists,
                              "hiding the bar is only safe while this button is here")
                capture("\(scheme.rawValue)-11-copilot-tab")
                app.buttons["copilot.back"].tap()
            } else {
                /*
                 * **No pill, and nothing behind it — which is the whole answer
                 * for a machine whose copilot is not this phone's.**
                 *
                 * This branch used to photograph the connect screen in Settings.
                 * There is no such screen: *"if we are connecting as my device
                 * copilot automatically comes, if we connect as guest then
                 * copilot don't come."* So the frame worth taking is the bar
                 * itself, with three pills on it, and the assertion is that
                 * nothing anywhere offers to connect the thing.
                 */
                XCTAssertFalse(app.buttons["settings.copilot"].exists,
                               "there is nothing in Settings left to connect")
                sleep(1)
                capture("\(scheme.rawValue)-11-three-pills-no-copilot")
            }

            // And nothing about the copilot is left on the session list, which
            // is the duplication the pill replaced.
            app.openSessionsTab()
            sleep(1)
            XCTAssertFalse(app.buttons["copilot.row"].exists,
                           "the pinned row went out with the pill coming in")
            capture("\(scheme.rawValue)-12-sessions-without-the-copilot-row")
        }
    }

    // MARK: - Arriving

    private func connectToTheLiveHost() throws {
        let field = app.textFields["pairing.field"]
        if field.waitForExistence(timeout: 25) {
            expecting = .dark
            try? "ready\n".write(toFile: readyFile, atomically: true, encoding: .utf8)
            let code = waitForCode(timeout: 240)
            XCTAssertEqual(code.count, 6, "the harness never wrote six digits to TD_CODE_FILE")
            field.tap()
            field.typeText(code)
        }
        try waitForConnected(timeout: 240)
    }

    private func pairWithTheStandIn() throws {
        let field = app.textFields["pairing.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "the app should be at the pairing screen")
        field.tap()
        field.typeText(try freshCode())
        // The pairing and approval screens have no tab bar at all, so waiting
        // for one is how a test knows the machine approved the device rather
        // than merely accepting its code.
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 120),
                      "the machine never approved this device")
        app.openSessionsTab()
        try waitForConnected(timeout: 90)
    }

    private func freshCode() throws -> String {
        guard let url = URL(string: "http://\(control)/pair") else { throw XCTSkip(Self.noStandIn) }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            throw XCTSkip("\(Self.noStandIn) (\(control) did not answer /pair)")
        }
        let digits = text.trimmingCharacters(in: .whitespacesAndNewlines).filter { $0.isNumber }
        guard digits.count >= 6 else { throw XCTSkip("\(control) answered \(text)") }
        return String(digits.prefix(6))
    }

    private func waitForCode(timeout: TimeInterval) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let raw = try? String(contentsOfFile: codeFile, encoding: .utf8) {
                let digits = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if digits.count == 6 { return digits }
            }
            usleep(400_000)
        }
        return ""
    }

    private func waitForConnected(timeout: TimeInterval) throws {
        let pill = app.descendants(matching: .any).matching(identifier: "connection.pill").firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // The pill is only drawn while the connection is worth mentioning —
            // see `ConnectionGrace` — so a list with rows on it is the other way
            // of knowing, and on a fast connection it is the only one.
            if pill.exists && pill.label.contains("Connected") { return }
            if firstSessionRow().exists { return }
            if app.buttons["sessions.new"].exists { return }
            usleep(500_000)
        }
        XCTFail("never connected to the machine")
    }

    private func choose(_ scheme: Scheme) throws {
        XCTAssertTrue(app.openSettingsTab(), "Settings should be reachable")
        let picker = app.segmentedControls["settings.appearance"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        let segment = picker.buttons[scheme.segment]
        XCTAssertTrue(segment.waitForExistence(timeout: 5))
        segment.tap()
        expecting = scheme
        // One frame's worth of settling: the window's interface style changes on
        // the next run loop pass, and a screenshot taken inside the same one
        // catches the previous appearance and blames the wrong thing.
        sleep(1)
    }

    /**
     * Sweep away a notification banner before it can be tapped.
     *
     * XCUITest dismisses an "interrupting element" by **tapping** it, and a
     * banner covers the top of the screen where the first row of a list is —
     * which on the other suite's first run opened a page nobody had asked for
     * and made the remaining nine frames photographs of it. A swipe up is how a
     * person puts a banner away and is the one gesture that cannot reach the app
     * underneath.
     */
    private func clearBanners() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for identifier in ["NotificationShortLookView", "BannerWindow"] {
            let banner = springboard.otherElements[identifier]
            if banner.exists {
                banner.swipeUp()
                sleep(1)
            }
        }
    }

    @discardableResult
    private func capture(_ name: String, measured: Bool = true) -> Double {
        clearBanners()
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        if !shots.isEmpty {
            try? FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png"))
        }

        let luminance = AppearanceShotsUITests.averageLuminance(of: shot.image)
        add(XCTAttachment(string: "\(name): mean luminance \(luminance), expecting \(expecting.rawValue)"))
        guard measured else { return luminance }
        XCTAssertTrue(expecting.luminanceRange.contains(luminance),
                      "\(name) was photographed in \(expecting.rawValue) mode but its mean luminance "
                      + "is \(String(format: "%.3f", luminance)), outside \(expecting.luminanceRange) "
                      + "— this screen did not follow the appearance")
        return luminance
    }
}
