/**
 * The page that comes to the session, the way in for one that has not arrived
 * yet, and the fold that has to work both ways.
 *
 * > *"Let's give terminal here in black area available down here, to watch what
 * > the session is doing… But generally, whenever we are talking to terminal,
 * > terminal will directly open it up in there inside the session… and the person
 * > can just minimize it from some button and it will go back to the browser
 * > page."*
 *
 * ## Why every question here needs a running machine
 *
 * None of it can be established by reading either end. Whether the letterbox is
 * gone depends on a frame arriving and the canvas reporting its height back
 * (`WatchSurface.onPageHeight`); whether a page reaches a session depends on the
 * machine pushing `browser.surfaces.rows` when a binding changes and this phone
 * asking `browser.windows` in answer; whether folding stops the cast is two
 * photographs a second apart. The unit tests pin the arithmetic —
 * `WatchTests` owns `fit`, `clampDrawn` and `imageCoords`, `SessionPageTests`
 * owns the height the pane settles at — and everything below is about a running
 * app against a machine that is really casting.
 *
 * ## The strip has one control and three things it can be
 *
 * > *"When we are inside here to a terminal where we have the window. So if we
 * > close it, we cannot open it. If I click on it, it is not opening. So this
 * > should be working properly, so I can at least open it."*
 *
 * He was looking at a strip whose chevron pointed **down** — the pane believed it
 * was showing something — over an empty space, because this pane owns the fold
 * and does not own the cast. So `session.page.fold` is now one identifier
 * carrying whichever of three acts is true, and the **label** is what says which:
 * *Fold the page away* only while a picture is really arriving, *Show the page*
 * on a folded pane, *Ask for the page again* on a pane that is shown with nothing
 * under it. Where no cast can be had at all there is no control and the sentence
 * under the strip is the whole answer.
 *
 * Every case below therefore reads the label before it presses, and asserts the
 * label it becomes. A case that pressed a chevron and asserted the strip survived
 * would pass against exactly the screen he photographed.
 *
 * ## This suite **does** change the machine, which is unlike its neighbours
 *
 * `MachineBrowserUITests` refuses to press a session row because *"pressing a
 * session row would attach a real window to a real agent."* This suite is about
 * that attachment, so it cannot refuse it. What it does instead is own everything
 * it touches: it opens a window of its own at `example.com`, binds **that**
 * window, and detaches and closes it in `tearDown` whatever the case did — so a
 * failure halfway through still leaves the machine as it found it. It never
 * touches a window it did not open, and it never creates or closes a session.
 *
 * The binding does put one line into that session's next turn — *"Browser windows
 * attached to this session (this just changed)"* — and there is no way to have
 * the feature without it. The session is left with no window attached at the end,
 * which is the other line the same mechanism prints.
 *
 * The rows it will **not** press are the ones that borrow a window: the machine's
 * own open windows, listed on the session row's `…` and inside the session's own
 * `…`. They are named by their pages' titles and there is no way from here to
 * tell which of them is the one this suite opened, so pressing one would be
 * binding a stranger's window to a stranger's agent. That case proves both doors
 * are there and offer something, and the bind itself is walked from the window's
 * own end, where the window is named.
 *
 * The row it **does** press is the one that makes a new window —
 * *Open a window for this session* — because that row touches nothing that
 * existed before the press. `testOnePressInsideASessionLeavesItHoldingAWindow`
 * walks it and records what it made in `mine`, so `tearDown` takes it back like
 * everything else.
 *
 * ## The `…` had nothing in it, which is the same complaint from inside
 *
 * > *"here we also don't have anything, like inside here, in the three dots, we
 * > should have the options to click on something, and then all the folders will
 * > come up, maybe here also. So we can connect the browser, whichever browser we
 * > want to connect into the session."*
 *
 * Both attach sections shipped drawn `if !windows.isEmpty`, so a machine whose
 * browser simply had no window open — an ordinary laptop, and what he was looking
 * at — put nothing at all under either `…`, and the only route back was the
 * Browser tab. Every case below that opens one of those menus now asserts the two
 * rows that make a window as well as the ones that borrow one; see
 * `assertOffersANewWindow`, which is the check that would have failed against
 * what shipped.
 *
 * ## The session screen itself has to stay clean
 *
 * > *"So now if I enter into any session, this comes here that on top the attach
 * > window is coming. If it is not connected to anyone, so it should stay clean.
 * > Even if I go to Copilot, which has no browser window attached, it is also
 * > showing something attached."*
 *
 * There was a bar across the top of every session that held no window, offering
 * to go and get one. It is deleted, and the assertion that it is absent is made
 * in **both** cases below rather than only on the session that holds a page: the
 * defect he filmed was on the sessions that hold nothing, which is nearly all of
 * them.
 *
 * ## It skips rather than fails, and each skip is a real state
 *
 * No machine paired; a machine that offers no `browser.control`, so there is no
 * `+` and no window to open; a machine that offers no `watch`, so the window
 * opens and nothing is cast; a machine with no sessions to attach to. Every one
 * is the product working rather than a fault.
 */

import XCTest

final class SessionPageUITests: XCTestCase {

    private var app: XCUIApplication!

    /// Where the frames land, so they can be looked at outside the result
    /// bundle. Silent when unset — a photograph is a deliverable, not a
    /// condition of the run.
    private var shots: String { ProcessInfo.processInfo.environment["TD_SHOTS"] ?? "" }

    /// The window this suite opened, so `tearDown` can take it away again. Nil
    /// when nothing was opened, which is every skipped case.
    private var mine: String?

    /// The three things the one control on the strip can be, verbatim from
    /// `SessionPageView.strip`. They are `accessibilityLabel`s rather than
    /// identifiers because there is one identifier and three acts — see the file
    /// header for why it is that way round.
    private static let foldAway = "Fold the page away"
    private static let showIt = "Show the page"
    private static let askAgain = "Ask for the page again"

    private static let noMachine =
        "This phone is not paired with a running host. Run ios/Harness/live-localhost.sh, "
        + "which starts one and pairs the Simulator."

    private static let noControl =
        "This machine does not offer `browser.control`, so there is no way to open a window "
        + "and nothing to bind. That is the product working."

    private static let noWindow =
        "The window this suite opened never appeared in the machine's list."

    private static let noSessions =
        "This machine is running no sessions, so there is no terminal to bring a page to."

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()

        let paired = app.buttons["sessions.new"].waitForExistence(timeout: 20)
            || app.buttons["sessions.more"].exists
        try XCTSkipUnless(paired, Self.noMachine)
        XCTAssertTrue(app.openBrowserTab(), "the Browser tab should be reachable")
    }

    /**
     * Take back everything this suite put on the machine.
     *
     * Unconditional and forgiving: it runs after a passing case and after a case
     * that stopped in the middle, and either of those can leave the app on any
     * screen. So it walks back to the Browser tab first and then asks for the two
     * swipe actions by name, each guarded on existing — Detach is absent on a
     * window that was never bound, and both are absent if the window has already
     * gone.
     */
    override func tearDownWithError() throws {
        guard let id = mine, let app else { return }
        mine = nil
        guard app.openBrowserTab() else { return }
        let row = app.buttons["browser.machine.row.\(id)"]
        guard row.waitForExistence(timeout: 10) else { return }

        row.swipeLeft()
        let detach = app.buttons["browser.machine.swipe.detach.\(id)"]
        if detach.waitForExistence(timeout: 3) { detach.tap() }

        let again = app.buttons["browser.machine.row.\(id)"]
        guard again.waitForExistence(timeout: 10) else { return }
        again.swipeLeft()
        let close = app.buttons["browser.machine.swipe.close.\(id)"]
        if close.waitForExistence(timeout: 3) { close.tap() }
    }

    // MARK: - The walk

    /**
     * A window, bound to a session, seen from both ends — and folded away and
     * brought back.
     *
     * One case rather than five, because every step is the previous step's
     * precondition on a live machine and five cases would each have to open and
     * bind a window of their own. The photographs are the deliverable: what is on
     * the screen under the page, what is on the session screen when the page
     * arrives there, and what a fold looks like.
     */
    func testAPageBoundToASessionArrivesInThatSession() throws {
        let opened = try openAWindow()

        // 1. The window's own screen. Under the page is the page and nothing
        //    else — see `bindThroughTheWindowsOwnSettings` for what used to be
        //    in that space and why it is not a route any more.
        let row = app.buttons["browser.machine.row.\(opened)"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), Self.noWindow)
        row.tap()
        capture("80-the-window")

        // 2. Bind it, through the control the window's own settings carry.
        let session = try bindThroughTheWindowsOwnSettings()
        capture("81-window-bound")

        /*
         * 3. To the session — **from the Sessions tab**, which is the only door
         *    into a terminal there is.
         *
         * This step used to be one tap on a row under the page that named the
         * window's session and pushed into it. He walked that loop and called it
         * *"too complicated"*:
         *
         * > *"if we go to browser and if we go back, it is giving like this now.
         * > See, inside, it is taking me to directly terminal. So this page should
         * > be purely for only browser, not for terminal too. Terminal is only
         * > here, and only terminal is giving the browser window too. But browser
         * > side, it should not give the terminal window too."*
         *
         * So the walk is the one a person now has: the Browser tab is left the
         * way any tab is left, and the session is opened from the list it lives
         * in. Nothing about the *claim* changed — the page is not carried over by
         * the tap, `SessionPageView` opens it because the window it finds is
         * bound to the session it is on, and that is as true arriving from the
         * Sessions tab as it was arriving from the window.
         *
         * The row is found by the session's own title because that is all the
         * attach menu gives back: its rows are a SwiftUI `Menu`, and an
         * identifier on a `Button` inside one does not reach the presented row.
         * Both lists are the same machine's sessions — `state.sessions` off
         * `browser.windows` and `RemoteSession` off the session list — so a title
         * on one is a title on the other.
         *
         * Back to the Browser tab's root before the tab is changed at all, and
         * that is not tidiness: a window's page sets `localhostPageIsOpen`, which
         * is what hides the floating tab bar so the pill does not sit over the
         * page's own bar. Standing on that screen there is no tab to press.
         * `openBrowserTab` walks the chevrons back to the root, which is a screen
         * with the tab bar on it.
         */
        XCTAssertTrue(app.openBrowserTab(), "the Browser tab's root should be reachable again")
        app.openSessionsTab()
        let terminal = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'session.' AND label CONTAINS %@",
                                  session))
            .firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 20),
                      "the window was attached to “\(session)”, so the Sessions tab should list it")
        terminal.tap()

        let strip = any("session.page.title")
        XCTAssertTrue(strip.waitForExistence(timeout: 25),
                      "the session should show the window it is holding")
        /*
         * And there is **no bar**, which is now an *always* rather than a
         * *once a window is bound*.
         *
         * > *"If it is not connected to anyone, so it should stay clean."*
         *
         * The bar this asserts the absence of used to be drawn on every session
         * that held no window, on any machine with a window open — so it was on
         * the Copilot tab too, over a conversation that has never had a page in
         * it. The pane draws the window a session holds and nothing else, and the
         * case below makes the same assertion from the other side, on a session
         * that holds nothing.
         */
        XCTAssertFalse(any("session.page.attach").exists,
                       "the session screen shows the page it holds and nothing else — there is no "
                       + "attach bar on it any more, whether or not a window is bound")
        capture("82-session-split")

        // 4. And the one control on the strip, whichever of its three acts this
        //    machine has made true.
        walkTheStripsOneControl(strip)

        // Out of the session before the teardown goes looking for the Browser
        // tab, so the phone is left on the list it was found on. Everything this
        // suite touched on the machine is taken back over there.
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /**
     * **A session that holds no window shows nothing — and the two ways in are
     * the two `…` menus.**
     *
     * > *"So now if I enter into any session, this comes here that on top the
     * > attach window is coming. If it is not connected to anyone, so it should
     * > stay clean… If something is attached, then we can open it here also, so
     * > which doesn't make any sense because it does not have anything to do with
     * > this specific browser. It is not even linked to it."*
     *
     * > *"since we have this, when we flip, we drag it. So maybe we should not
     * > have this arrow. Instead, this arrow, we can have three dots, and we can
     * > have more options like the way we have inside… Or maybe the ones that
     * > more suits outside, like connecting with the browser and kind of stuff."*
     *
     * > *"here we also don't have anything, like inside here, in the three dots,
     * > we should have the options to click on something, and then all the folders
     * > will come up, maybe here also."*
     *
     * Three sentences, one walk, because the second two are what makes the first
     * one safe to do: the bar came off the session screen, so the verb it carried
     * had to be somewhere a person would look for it. It is on the session row's
     * `…` on the list, and on the session's own `…` inside. This case opens both
     * and asserts each of them offers a window this machine really has open —
     * and, in between, that the screen the bar was on is clean.
     *
     * **No row inside either menu is pressed.** The rows are every window the
     * machine has open, named by their own page titles, and nothing here can tell
     * which of them is the one this suite opened — pressing one would bind a
     * stranger's window to a stranger's agent. The bind itself is walked in the
     * case above, from the end where the window is named. So what is asserted is
     * that the section is there and has something pressable in it, which is
     * exactly the claim *"there is a way in"*.
     *
     * The `…` is also asserted **not to open the session**, which is the one way
     * this feature could be worse than the arrow it replaced.
     */
    func testTheWaysInAreTheTwoDotsMenusAndTheSessionScreenStaysClean() throws {
        let opened = try openAWindow()
        XCTAssertTrue(app.buttons["browser.machine.row.\(opened)"].waitForExistence(timeout: 20),
                      Self.noWindow)

        XCTAssertTrue(app.openBrowserTab(), "the Browser tab's root should be reachable again")
        app.openSessionsTab()

        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session.'"
                                                  + " AND NOT identifier CONTAINS 'swipe'"))
            .firstMatch
        try XCTSkipUnless(row.waitForExistence(timeout: 20), Self.noSessions)
        let rowID = row.identifier

        /*
         * 1. **The row's `…`, which is what the arrow became.**
         *
         * Found by prefix, because the identifier carries a session id no test
         * can know — the same shape `SwipeActionsUITests` uses for the machines
         * list's own `…`. `descendants(matching: .any)` rather than `buttons`
         * for the reason the menu helpers in `TabNavigation.swift` give.
         *
         * `sessions.row.more.` rather than `session.more.`, and the identifier is
         * that way round on purpose: sixteen suites in this target find a row
         * with `BEGINSWITH 'session.'` and take element zero, and a control that
         * sits on every row for ever under that prefix would quietly become the
         * element some of them pressed. `SessionListView` carries the note.
         */
        let dots = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'sessions.row.more.'"))
            .firstMatch
        XCTAssertTrue(dots.waitForExistence(timeout: 10),
                      "a session row carries a `…` now, in the corner the chevron used to be in")

        let beforeRow = labels()
        dots.tap()
        // The presentation animates; the rows are not queryable in the same frame
        // the tap lands in.
        _ = app.buttons.element(boundBy: 0).waitForExistence(timeout: 3)
        capture("87-the-rows-dots")

        let rowMenu = labels().subtracting(beforeRow)
        XCTAssertTrue(rowMenu.contains("Session details"),
                      "the row's menu carries the things you do to a session without opening it")
        XCTAssertTrue(rowMenu.contains("Archive"), "including the one the swipe carries")
        assertOffersAWindow(rowMenu, fixed: Self.rowMenuItems,
                            where_: "the session row's `…`")
        assertOffersANewWindow(rowMenu, where_: "the session row's `…`")

        app.dismissAnyMenu()

        /*
         * And it did **not** open the session, which is the whole risk of putting
         * a second control inside a card that is itself one big button. The list
         * is still on screen and the row is still on it.
         */
        XCTAssertTrue(app.buttons[rowID].waitForExistence(timeout: 8),
                      "the `…` opens a menu — a `…` that also opened the session would be worse "
                      + "than the arrow it replaced")

        // 2. Into the session. The screen the bar used to be across is clean.
        app.buttons[rowID].tap()
        try XCTSkipUnless(app.buttons["terminal.actions"].waitForExistence(timeout: 25),
                          "the session screen never came up, so there is nothing to look at")
        capture("88-session-clean")
        XCTAssertFalse(any("session.page.attach").exists,
                       "a session that holds no window shows nothing above the terminal — "
                       + "“if it is not connected to anyone, so it should stay clean”")

        // 3. And the same way in, inside the session's own `…`.
        let beforeSession = labels()
        app.buttons["terminal.actions"].tap()
        _ = app.buttons.element(boundBy: 0).waitForExistence(timeout: 3)
        capture("89-the-sessions-dots")

        let sessionMenu = labels().subtracting(beforeSession)
        XCTAssertTrue(sessionMenu.contains("Find in output"),
                      "this is the terminal's own menu, so its own items are still in it")
        assertOffersAWindow(sessionMenu, fixed: Self.sessionMenuItems,
                            where_: "the session's own `…`")
        assertOffersANewWindow(sessionMenu, where_: "the session's own `…`")

        app.dismissAnyMenu()
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /**
     * **One press from inside a session, and that session is holding a window.**
     *
     * > *"here we also don't have anything, like inside here, in the three dots,
     * > we should have the options to click on something, and then all the
     * > folders will come up, maybe here also. So we can connect the browser,
     * > whichever browser we want to connect into the session."*
     *
     * The case above proves both `…` menus **contain** the way in. This one
     * presses it, and it is the only case in this suite that walks the whole
     * sentence: a person sitting in a session, with no browser window open
     * anywhere, ending up with one attached — without leaving for the Browser
     * tab, which is the walk the menus were added to delete.
     *
     * ## Why this one is allowed to press where the case above is not
     *
     * That case refuses to press a row because the rows are the machine's own
     * windows and *"pressing a row it cannot name would be binding a stranger's
     * window to a stranger's agent."* This row names nothing of anybody's: it
     * makes a **new** window, blank, and binds that. Nothing that existed before
     * the press is touched, which is the same standard `openAWindow` already
     * meets. And what it makes is recorded in `mine`, so `tearDown` detaches and
     * closes it exactly as it does the one opened from the `+`.
     *
     * ## No address, on purpose
     *
     * `browser.window.open` with an empty `url` is a real ask — the New window
     * sheet's Open is not disabled for an empty field either. A blank window is
     * the browser, waiting, on the machine, already belonging to this session,
     * and wherever the agent sends it next is one `go` away. It also means this
     * case loads nothing off the network, so it cannot fail because a site was
     * slow.
     *
     * ## What is asserted, in the order the app answers
     *
     *  1. **The strip**, on the session screen. `SessionPageView` draws it for
     *     the window this session *holds*, so its arrival is the bind — the host
     *     binds before it answers, which is why one press is enough and there is
     *     no second round trip to wait through.
     *  2. **A real window on the machine**, found on the Browser home by
     *     difference against the rows that were there before. The strip alone
     *     would be satisfied by a phone that believed something; a row on the
     *     machine's own list is the machine agreeing.
     */
    func testOnePressInsideASessionLeavesItHoldingAWindow() throws {
        /*
         * The baseline, on the Browser home, where `setUp` leaves the app.
         *
         * A settle first: `browser.window.rows` is answer-only and the list is
         * asked for on arrival, so a snapshot taken in the first frame would be
         * empty on a machine that has four windows — and every one of them would
         * then look like the one this case made. An empty baseline after the
         * wait is the honest answer and the ordinary one.
         */
        _ = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'browser.machine.row.'"))
            .firstMatch
            .waitForExistence(timeout: 8)
        let before = rowIDs()

        app.openSessionsTab()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session.'"
                                                  + " AND NOT identifier CONTAINS 'swipe'"))
            .firstMatch
        try XCTSkipUnless(row.waitForExistence(timeout: 20), Self.noSessions)
        row.tap()
        try XCTSkipUnless(app.buttons["terminal.actions"].waitForExistence(timeout: 25),
                          "the session screen never came up, so there is nothing to press")

        app.buttons["terminal.actions"].tap()
        _ = app.buttons.element(boundBy: 0).waitForExistence(timeout: 3)
        capture("90-inside-the-sessions-dots")

        let make = app.buttons[Self.openForThisSession].firstMatch
        try XCTSkipUnless(make.waitForExistence(timeout: 5), Self.noControl)
        make.tap()

        // 1. The session is holding something. The bind happens on the machine
        //    before it answers, so this is the first thing that changes here.
        let strip = any("session.page.title")
        XCTAssertTrue(strip.waitForExistence(timeout: 30),
                      "one press from inside the session should leave it holding a window — "
                      + "“so we can connect the browser… into the session”")
        capture("91-the-session-is-holding-it")

        // 2. And the machine agrees: a row that was not on the Browser home
        //    before. Recorded first, so a failure after this line still hands the
        //    window back in tearDown.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.openBrowserTab(), "the Browser tab's root should be reachable")

        var found: String?
        for _ in 0 ..< 60 {
            if let id = rowIDs().subtracting(before).first {
                found = id
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        let id = try XCTUnwrap(found, Self.noWindow)
        mine = id
        XCTAssertTrue(app.buttons["browser.machine.row.\(id)"].exists,
                      "the window the session was given is a window on the machine's own list")
        capture("92-the-window-it-made")
    }

    /**
     * A page with a password box on it, from the phone.
     *
     * **This is the secret-field curtain, which is not the handover** — the two
     * look identical on screen and come from different places, so it is worth
     * being exact about which one this photographs. `PageCast.maskFor`
     * withholds the pixels of **any** frame whose viewport contains a secret
     * field (`SECRET_RECTS_SCRIPT` calls `input[type=password]` one), whether or
     * not anybody has been asked about it. Nothing is outstanding, there is no
     * baton, and there is nothing to take: the honest drawing is the lock card
     * and a bar that does not claim a password could be typed, which is what is
     * asserted below.
     *
     * The **handover** — *"Claude can ask for the input to put password and put
     * email and then he can continue"* — is the agent's own question, it arrives
     * as `browser.handover.state`, and `SessionPageView` answers it with a bar
     * carrying the claim and the two ways to hand back. It is not exercised
     * here, and not because it is untested: `HandoverUITests` walks all four
     * states against a host that really asks. `WatchTests` owns which frame each
     * state sends.
     */
    func testASignInPageIsCurtainedRatherThanTypedInto() throws {
        let opened = try openAWindow(at: "https://github.com/login")
        let row = app.buttons["browser.machine.row.\(opened)"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), Self.noWindow)
        row.tap()

        /*
         * Across every element type rather than as an `otherElements`. The
         * identifier is on a SwiftUI container whose child is a
         * `UIViewRepresentable`, and what XCUITest classifies that as is not a
         * thing to have an opinion about — `BrowserPageBarUITests` measured
         * `otherElements` finding nothing and skipping silently, which is the
         * shape of a test that never runs.
         */
        let stage = any("browser.machine.window.stage")
        try XCTSkipUnless(stage.waitForExistence(timeout: 25),
                          "This machine is not casting the window, so there is nothing to curtain.")
        // The scan runs on load and on every settle, so the curtain can arrive a
        // moment after the first frame does. Nothing to wait *for* — the lock
        // card is a `UILabel` inside the canvas and carries no identifier — so
        // the beat is a beat, and what it buys is a photograph of the settled
        // screen rather than of the frame before the scan.
        Thread.sleep(forTimeInterval: 6)
        capture("86-sign-in-page")

        /*
         * **The bar belongs to the page whether or not there are pixels in it.**
         *
         * A window this suite opened through `browser.window.open` has a real
         * window id, so its address is a field and not the read-only line
         * `BrowserPageBar` draws for a page nothing can be sent to. Both shapes
         * are accepted here anyway: the claim is *"this one is the one that
         * should be everywhere"* — the address is on the bar under every page —
         * and which shape a given machine produces is `MachineWindowView`'s
         * business and is pinned in `BrowserPageBarUITests`.
         *
         * The keyboard verb is asserted absent beside it. A curtained page is
         * still a page you can type an address into and still a page with no
         * keyboard button on it: *"I should not have to have this separate button
         * of keyboard. It should just come up from down."*
         *
         * Whether the tap itself is refused while the curtain is up is
         * `WatchView.page(at:)`'s guard on `lastFrame.masked` and is not asked
         * here: a sign-in page that failed to load has no secret field on it, so
         * a case that tapped and demanded no keyboard would be asserting the
         * network between his machine and GitHub.
         */
        XCTAssertTrue(app.textFields["browser.machine.window.address"].exists
                        || any("browser.machine.window.address.readOnly").exists,
                      "a masked page is still a browser, so the address stays on its bar")
        XCTAssertFalse(app.buttons["browser.machine.window.keyboard"].exists,
                       "and there is no keyboard verb on it, on this screen or any other")
    }

    // MARK: - The strip

    /**
     * Press the one control on the strip and assert what it becomes.
     *
     * > *"The person can just minimize it… and then it will fold back and then it
     * > can keep going."*
     *
     * > *"So if we close it, we cannot open it. If I click on it, it is not
     * > opening. So this should be working properly, so I can at least open it."*
     *
     * Three shapes, because the strip has three and each of them is a real state
     * of a real machine rather than a branch to hedge with:
     *
     *  - **A picture is arriving** — the control folds, and a fold must leave the
     *    strip standing and turn into the way back up. Pressed twice, so the
     *    round trip is walked rather than the way down only.
     *  - **The pane is shown and nothing is arriving** — the control asks for the
     *    page again instead of offering to fold an empty space, which is exactly
     *    the screen he photographed. Pressing it must not take the strip away.
     *  - **No cast can be had at all** — there is no control, and the sentence
     *    under the strip is the whole answer. Asserted, because a strip with
     *    neither a control nor a sentence is a header nobody can get past.
     *
     * The label is read before every press. A case that pressed by identifier and
     * asserted the strip survived would pass against the chevron pointing down
     * over nothing, which is the defect this walk exists for.
     */
    private func walkTheStripsOneControl(_ strip: XCUIElement) {
        let control = app.buttons["session.page.fold"]

        guard control.waitForExistence(timeout: 10) else {
            XCTAssertTrue(any("session.page.nocast").waitForExistence(timeout: 10),
                          "a strip with no control on it owes the sentence that says why there is "
                          + "no picture — a header with no way to find out is the dead end this "
                          + "screen is meant to stop being")
            capture("83-session-no-cast")
            return
        }

        /*
         * Which of the two the pane settled on, rather than which it was in the
         * frame the screen appeared in. The pane arrives `.split` and the verb
         * only becomes *fold* once a frame has really landed — `showing` is
         * `WatchLink.isCasting`, not *is there a row for it* — so a label read
         * straight after arrival can be *ask again* on a machine that is about to
         * send a picture. Twelve seconds is the same order as the canvas's own
         * wait for a first frame elsewhere in this suite.
         */
        let settled = stripControl(becomesOneOf: [Self.foldAway], within: 12)
        guard settled == Self.foldAway else {
            XCTAssertEqual(settled, Self.askAgain,
                           "the pane is shown, so its one control is either the fold over a "
                           + "picture or the way to ask for one — never anything else")
            control.tap()
            XCTAssertTrue(strip.waitForExistence(timeout: 5),
                          "asking for the page again must not take the strip away with it")
            capture("83-session-asked-again")
            return
        }

        control.tap()
        XCTAssertTrue(strip.waitForExistence(timeout: 5),
                      "folding must not take the page away entirely")
        XCTAssertEqual(stripControl(becomesOneOf: [Self.showIt]), Self.showIt,
                       "a folded pane's one control is the way back up, and it has to say so — "
                       + "a chevron that goes on offering to fold is the screen he photographed")
        capture("83-session-minimised")

        /*
         * And back. The same control, and the picture is the current one rather
         * than a renegotiated cast where one is still arriving — see
         * `SessionPageView` on why the canvas is kept mounted at zero height, and
         * why showing *asks* where it is not.
         *
         * **And that is the end of the pane's controls.** There was a sixth step
         * here — `session.page.size`, the expand verb, photographed as
         * `85-session-full` — and both the verb and the photograph are gone:
         *
         * > *"this button is like not working the way I was expecting. This is
         * > something else. We don't need actually this part. We don't need this
         * > to be coming down like with black page."*
         *
         * > *"Only this drop-down is required, like which can bring it to this
         * > state with the back panel, but this black area thing is not required.
         * > So just keep it simple."*
         */
        control.tap()
        XCTAssertTrue(strip.waitForExistence(timeout: 5),
                      "and bringing it back must leave the strip where it was")
        XCTAssertNotEqual(stripControl(becomesOneOf: [Self.foldAway, Self.askAgain]), Self.showIt,
                          "the pane is open again, so the control must have moved off *show* — to "
                          + "the fold where the picture came back, or to *ask again* where the "
                          + "machine has stopped sending one")
        capture("84-session-restored")
    }

    /**
     * What the strip's one control is carrying, once it has stopped moving.
     *
     * Every press here changes the label with an animation, and one of them —
     * *show* becoming *fold* — waits on a frame from the machine as well, because
     * `SessionPageView.show()` asks for the cast again rather than assuming one.
     * A label read in the frame after a tap is a race and not an answer, so this
     * polls for one of the labels the caller is expecting and hands back what it
     * found either way: the current label makes a far better failure message than
     * a bare false.
     */
    private func stripControl(becomesOneOf labels: [String],
                              within seconds: TimeInterval = 6) -> String? {
        let control = app.buttons["session.page.fold"]
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if control.exists, labels.contains(control.label) { return control.label }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return control.exists ? control.label : nil
    }

    // MARK: - Machinery

    /**
     * Open a window of this suite's own and answer with its id.
     *
     * The id is worked out by difference — the row that was not on the home
     * before — because nothing on this wire hands back the id of the window a
     * `browser.window.open` created. It is also what makes `tearDown` safe:
     * every window this suite touches is one it can name and prove it opened.
     */
    private func openAWindow(at address: String = "https://example.com") throws -> String {
        let before = rowIDs()

        let plus = app.buttons["browser.new"]
        try XCTSkipUnless(plus.waitForExistence(timeout: 20), Self.noControl)
        plus.tap()

        let field = app.textFields["browser.address"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), "the new-window sheet should have a field")
        field.tap()
        field.typeText(address)

        /*
         * **Isolated, which is tidier and is no longer load-bearing.**
         *
         * Both segments mint a real window now. `MachineBrowserView.openWindow`
         * sends `browser.window.open` whichever is lit — the sheet's *Machine*
         * used to route through `web.open` instead, which on a headless host is
         * `browserDrive.open({ isolate: false })` and lands in the drive's **own
         * front slot**: a `browser.surfaces` row under an empty window name, in
         * no `browser.window.rows` entry, with no id for `browser.window.bind` to
         * address. The first run of this suite photographed exactly that — one
         * row on the home, `example.com`, and no window in the list — and it is
         * the same defect he filmed from the other side, one row that could be
         * attached to a session beside one that could not.
         *
         * What is left is a preference, and it is kept for what it does to
         * somebody's live machine: an isolated window gets a partition of its
         * own and the partition is thrown away when the window closes, so a run
         * of this suite leaves nothing behind in his browser's real profile.
         */
        let isolated = app.buttons["Isolated"]
        if isolated.waitForExistence(timeout: 5) { isolated.tap() }
        capture("79a-sheet-filled")
        app.buttons["browser.open.go"].tap()
        capture("79b-after-go")

        // The sheet dismisses itself on a successful open; the row arrives with
        // the next `browser.window.rows`, which the open's own answer carries.
        var found: String?
        for _ in 0 ..< 60 {
            let now = rowIDs().subtracting(before)
            if let id = now.first {
                found = id
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard let id = found else {
            capture("79c-no-window")
            throw XCTSkip(Self.noWindow)
        }
        mine = id
        return id
    }

    /**
     * Bind through the control the window's own settings carry, and answer with
     * the title of the session it was bound to.
     *
     * ## It is the only way to bind a window from the Browser tab, on either
     * shape of host
     *
     * This used to be the fallback for a host that was not casting — the shape
     * where the settings *are* the body of the screen — while a cast window was
     * bound from an attach list drawn under its page, with a row per session and
     * a caption over them. That list is deleted along with the row that named the
     * window's owner and pushed into it:
     *
     * > *"this page should be purely for only browser, not for terminal too…
     * > It should be just when I come to this browser page, here I should be able
     * > to see all the browsing windows. That's all, very simple."*
     *
     * The *fact* was not deleted with the route. Which session owns a window is a
     * window setting and it was always in this card, next to Detach; what went is
     * the second copy of it that had a chevron on it. So there is one control on
     * one screen, and this walks to it either way: behind the `…` on the bar when
     * the machine is casting the window, and already on the screen when it is
     * not. `MachineBrowserUITests.testAWindowsSettingsAreInsideTheWindow` pins
     * that exactly one of those two is ever true.
     *
     * The other end of the same verb — a session going and getting a window it
     * does not have — is the *Attach a browser window* section on the session
     * row's `…` and on the session's own, and both are walked by
     * `testTheWaysInAreTheTwoDotsMenusAndTheSessionScreenStaysClean`. One verb,
     * `HostLink.bindMachineWindow`, reachable from every end.
     *
     * ## Why the row is found by difference and the title is read off it
     *
     * The rows inside are a SwiftUI `Menu`, and *"an `accessibilityIdentifier` on
     * a `Button` inside a SwiftUI `Menu` does not reach the presented row"* —
     * measured twice in this target. Every other suite answers that by pressing
     * a row whose words it knows in advance; these are session titles off a live
     * machine and nothing here knows them. So the rows are found by difference:
     * what is a button after the menu opens and was not one before.
     *
     * Which also means the label is the only thing this ever learns about the
     * session it bound to — there is no id — and the caller needs it to find the
     * same session in the Sessions tab. `MachineBrowserText.sessionRow` builds
     * that label as the title, then `·` and the window count where there is one,
     * so the title is what stands before the first separator.
     */
    private func bindThroughTheWindowsOwnSettings() throws -> String {
        let menu = app.buttons["browser.machine.window.attach"]
        if !menu.waitForExistence(timeout: 12) {
            let dots = app.buttons["browser.machine.window.settings"]
            try XCTSkipUnless(dots.waitForExistence(timeout: 10),
                              "This window has neither its settings on screen nor a `…` leading to "
                              + "them, so the machine is offering no browser at all.")
            dots.tap()
            try XCTSkipUnless(menu.waitForExistence(timeout: 20),
                              "This machine lists no session to attach a window to.")
        }

        let before = Set(app.buttons.allElementsBoundByIndex.map(\.label))
        menu.tap()
        // The presentation animates; the rows are not queryable in the same
        // frame the tap lands in.
        _ = app.buttons.element(boundBy: 0).waitForExistence(timeout: 3)
        capture("80b-attach-menu")

        let row = app.buttons.allElementsBoundByIndex.first { !before.contains($0.label) }
        let session = try XCTUnwrap(row, "the attach menu opened with no session in it")
        let label = session.label
        session.tap()

        let title = label.components(separatedBy: " · ").first ?? ""
        // An unnamed row is not a session this suite can go and look for, and it
        // would make the caller's `CONTAINS ""` match every row on the phone.
        try XCTSkipUnless(!title.isEmpty,
                          "The session this window was bound to has no title on the wire, so "
                          + "there is nothing to find it by in the Sessions tab.")
        return title
    }

    /**
     * A menu that was opened offers a window to attach, and not only its own
     * fixed items.
     *
     * **By set difference of labels, never by identifier.** An
     * `accessibilityIdentifier` on a `Button` inside a SwiftUI `Menu` does not
     * reach the presented row — measured twice in this target — so what a case
     * has to work with is the words. The window rows are named by their pages'
     * own titles and nothing here knows them, so they are found the only way they
     * can be: everything that appeared, minus the items this menu always has.
     *
     * `isEnabled` is asserted rather than mere existence, because a window
     * another session holds is still one this session can be handed, and a menu
     * whose rows were all dead would be a picker that cannot pick.
     *
     * **One thing it cannot tell apart, written down rather than worked around.**
     * These menus now also list the pages *this phone* is showing, under their
     * own header, and those rows are named by the page's title — as unknowable
     * from here as a window's. So a phone with a localhost page open and a
     * machine with no window open would satisfy this check on the strength of
     * that page alone. Nothing in this suite opens a localhost page and its
     * teardown closes what it opens, so the situation does not arise here; the
     * two fixed rows are asserted by name in `assertOffersANewWindow` precisely
     * because they are the only ones whose words are known in advance.
     */
    private func assertOffersAWindow(_ appeared: Set<String>, fixed: Set<String>, where_: String) {
        let windows = appeared.filter { label in
            !fixed.contains(label) && !Self.fixedPrefixes.contains { label.hasPrefix($0) }
        }
        XCTAssertFalse(windows.isEmpty,
                       "this suite has a window open on the machine, so \(where_) must offer it — "
                       + "what appeared was \(appeared.sorted())")
        for label in windows {
            XCTAssertTrue(app.buttons[label].firstMatch.isEnabled,
                          "“\(label)” is offered by \(where_), so it has to be pressable")
        }
    }

    /**
     * A menu offers the way to **make** a window, not only to borrow one.
     *
     * This is the assertion that would have failed against what shipped. Both
     * sections were drawn `if !windows.isEmpty`, so on a machine whose browser
     * had no window open the `…` opened onto nothing — which is the ordinary
     * state of a laptop, and the state he was sitting in:
     *
     * > *"here we also don't have anything, like inside here, in the three dots,
     * > we should have the options to click on something, and then all the
     * > folders will come up, maybe here also. So we can connect the browser,
     * > whichever browser we want to connect into the session."*
     *
     * By **label** and not by identifier, like every other check in this file:
     * an `accessibilityIdentifier` on a `Button` inside a SwiftUI `Menu` does not
     * reach the presented row, measured twice in this target. These two rows are
     * the only ones in either menu whose words are fixed and known in advance,
     * which is what makes them assertable at all.
     *
     * Both are pressed for, not just the first: the isolated one is a **second
     * named row** rather than a switch, because a `Toggle` in a `Menu` closes the
     * menu on the press and choosing would have cost one opening of the `…` and
     * acting a second. A build that quietly turned it back into a flag would
     * still pass a check that only looked for the first row.
     */
    private func assertOffersANewWindow(_ appeared: Set<String>, where_: String) {
        XCTAssertTrue(appeared.contains(Self.openForThisSession),
                      "\(where_) has to offer a window even when the machine has none open — "
                      + "what appeared was \(appeared.sorted())")
        XCTAssertTrue(appeared.contains(Self.openSignedIntoNothing),
                      "and the isolated choice beside it, as words rather than a switch")
        XCTAssertTrue(app.buttons[Self.openForThisSession].firstMatch.isEnabled,
                      "a row that cannot be pressed is the same dead end in a different shape")
    }

    /// Every button label on screen right now, which is the before and after a
    /// menu is measured against.
    private func labels() -> Set<String> {
        Set(app.buttons.allElementsBoundByIndex.map(\.label))
    }

    /**
     * The two rows that make a window rather than borrow one, verbatim from
     * `SessionWindowPicker`.
     *
     * They are the answer to *"we should have the options to click on something"*
     * on a machine with nothing open, and they are in **both** menus. They are
     * also why the two fixed sets below had to grow: `assertOffersAWindow` calls
     * everything it does not recognise a window, so a menu that offered only
     * these two would have passed a check that means *the machine's own windows
     * are offered here*. They are named rather than folded into the sets so the
     * cases can assert their presence directly.
     */
    private static let openForThisSession = "Open a window for this session"
    private static let openSignedIntoNothing = "Open one signed into nothing"

    /// What the session row's `…` always carries, whatever machine it is against.
    /// Anything else that appears with it is a window — see `assertOffersAWindow`.
    private static let rowMenuItems: Set<String> = [
        "Session details", "Model & effort", "Pin", "Unpin", "Archive", "Close",
        openForThisSession, openSignedIntoNothing,
    ]

    /// And the terminal's own menu, verbatim from `TerminalScreen`. The two
    /// text-size items carry the current size in their labels, so they are
    /// matched by prefix below rather than listed here.
    private static let sessionMenuItems: Set<String> = [
        "Find in output", "Session details", "Model & effort",
        "Copy Screen", "Paste", "Share output",
        "Send Photo or Video", "Send File", "Re-attach",
        openForThisSession, openSignedIntoNothing,
    ]

    private static let fixedPrefixes = ["Bigger text", "Smaller text"]

    /// Every window row currently on the Browser home, by window id.
    private func rowIDs() -> Set<String> {
        let prefix = "browser.machine.row."
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
        var out: Set<String> = []
        for index in 0 ..< rows.count {
            let id = rows.element(boundBy: index).identifier
            guard id.hasPrefix(prefix) else { continue }
            out.insert(String(id.dropFirst(prefix.count)))
        }
        return out
    }

    /**
     * One element by identifier, across every element type.
     *
     * The strip's title, the canvas and the no-cast sentence all carry their
     * identifier on a SwiftUI container, and what XCUITest classifies one of
     * those as is not a thing to have an opinion about: asking `otherElements`
     * for the canvas found nothing and skipped a case silently, which is the
     * shape of a test that never runs. `HandoverUITests` reaches the same three
     * the same way, measured against the screens it photographed.
     */
    private func any(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func capture(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        guard !shots.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png"))
    }
}
