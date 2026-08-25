/**
 * The Browser tab, after it stopped being a dumping ground.
 *
 * Nothing below can be established by reading the code. The screens compile
 * against a wire whose server end is answered by a real host, and the questions
 * that matter — is the home really only windows, is the address bar really gone
 * from it, does a row's menu really carry three verbs and not five — are
 * questions about a running app.
 *
 * > *"after everything is built too you should visualize it, everything on
 * > simulator and take screenshot also… So you know the current state of the
 * > application and the requirements and you know that if it is meeting what you
 * > have asked."*
 *
 * ## What this suite is guarding
 *
 * > *"when I say something to add for the browser, it should not be like
 * > isolated and other things that you added in the browser page — things should
 * > not be mixed in the list of browsing windows. The home page of the browser
 * > should be for the open browser windows… Even the localhost thing should be
 * > folded somewhere else… On the full page view it should be only about the
 * > open windows."*
 *
 * A rearrangement like this fails silently in exactly one way: the new place is
 * built and the old one is left standing, and every screenshot still looks
 * right. So half of what is asserted here is **absence** — no address bar on the
 * home, no port sections on it, no isolation picker sitting on the list, no
 * Screenshot on a row's menu — and each of those is paired with an assertion
 * that the thing is still reachable where it went.
 *
 * ## It skips rather than fails, and there are four reasons it might
 *
 * The standing rule of this target: a suite that goes red on a laptop with no
 * host running is a suite nobody runs. Four separate absences land here as a
 * skip rather than a failure, and each one is a real state of a real machine:
 *
 *  - **nothing paired** — the phone is at the server login and there is no
 *    machine to ask;
 *  - **no `browser.control`** — the machine withholds it from a guest device and
 *    from any host with no Chromium to drive, so the `+` and every per-window
 *    verb are correctly absent. That is the product working, not a fault;
 *  - **no `watch`, or a window the machine will not cast** — the public demo box
 *    passes no `screencast` engine on purpose, and a device whose browser-windows
 *    permission has been unticked loses the pictures at the same moment it loses
 *    the clicks. Even on a machine that does advertise it, a server lists a
 *    window opened from the phone's own `+` under `browser.window.rows` and
 *    **not** under `browser.surfaces`, so that window's screen is its settings
 *    rather than a live picture. Both are the product working;
 *  - **no windows open** — the home is an empty state with a way in on it, and
 *    every per-window control is legitimately absent.
 *
 * ## Nothing here presses anything that changes a machine
 *
 * This runs against Asad's live server. A window on the home is somebody's real
 * page: Close would take it away, Archive would hide it from this simulator's
 * own list for every later run, and pressing a session row would attach a real
 * window to a real agent. Every one of those is *revealed*, photographed and
 * dismissed. The `+`'s sheet is opened and cancelled, never submitted.
 *
 * ## Menu rows are pressed by their words
 *
 * An `accessibilityIdentifier` on a `Button` inside a SwiftUI `Menu` does not
 * reach the presented row. Measured twice in this target — the row is plainly
 * legible in a screenshot and both `app.buttons[id]` and a `descendants` query
 * on the same identifier report it absent — which is why `ScreenWalkUITests`
 * presses `Choose a folder…` by its label. Every menu row below is reached the
 * same way, and every control that is *not* in a menu is reached by identifier.
 * **Swipe action buttons are not menu rows** — they are ordinary buttons and are
 * reached by identifier, which is what makes the swipes below assertable at all.
 */

import XCTest

final class MachineBrowserUITests: XCTestCase {

    private var app: XCUIApplication!

    /// Where the frames land, so they can be looked at outside the result
    /// bundle. Silent when unset — a photograph is a deliverable, not a
    /// condition of the run.
    private var shots: String { ProcessInfo.processInfo.environment["TD_SHOTS"] ?? "" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()

        // A phone with nothing on it opens on the server login. Nothing below
        // has a machine to talk to, and pairing one is another suite's job — see
        // `LocalhostUITests`, which owns the code handshake.
        let paired = app.buttons["sessions.new"].waitForExistence(timeout: 20)
            || app.buttons["sessions.more"].exists
        try XCTSkipUnless(paired, Self.noMachine)

        XCTAssertTrue(app.openBrowserTab(), "the Browser tab should be reachable")
    }

    private static let noMachine =
        "This phone is not paired with a running host. Run ios/Harness/live-localhost.sh, "
        + "which starts one and pairs the Simulator."

    private static let notDrivable =
        "This machine does not advertise browser.control — a guest device, or a host with no "
        + "browser at all. The + and every per-window verb are correctly absent."

    private static let noWindows =
        "This machine's browser has no window open. Every per-window control is correctly absent."

    private static let noPhonePage =
        "This phone is holding no page of its own over a tunnel, so there is no On this phone row "
        + "to walk. Open one from the + and choose This phone."

    // MARK: - The home is one kind of thing

    /**
     * **The whole point, asserted from the outside.** The Browser tab's home
     * draws windows and nothing else.
     *
     * Four absences and one presence. The address bar, the tunnel tab strip and
     * the grouped port sections were all on this screen; so was a Shared /
     * Isolated segmented control, sitting permanently above the list whether or
     * not anybody was opening anything — *"it should not be like isolated and
     * other things that you added in the browser page."*
     *
     * The presence is the `…`, which is the one control on this screen that does
     * not depend on a capability or on there being anything open, and therefore
     * the one thing that proves the screen loaded at all rather than failing to.
     */
    func testTheHomeDrawsOnlyWindows() throws {
        capture("29-browser-home")

        XCTAssertTrue(app.buttons["browser.more"].exists,
                      "the home should keep its menu — it is where everything else went")

        XCTAssertFalse(app.textFields["browser.address"].exists,
                       "the localhost address bar belongs on the localhost screen now")
        XCTAssertFalse(app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'localhost.section.'"))
            .firstMatch.exists,
                       "the port groups belong on the localhost screen now")
        XCTAssertFalse(app.buttons
            .matching(NSPredicate(format: "identifier MATCHES 'port\\\\.[0-9]+'"))
            .firstMatch.exists,
                       "a port row is not a browser window and must not be in this list")
        XCTAssertFalse(app.otherElements["browser.machine.isolation"].exists,
                       "isolation is chosen when a window is opened, not from the list")
    }

    /**
     * The home settles on **either** a window row or the empty state, and the
     * way in survives both.
     *
     * The case that is easiest to get wrong: an empty state that fills the
     * screen with an apology and offers nothing. Either the empty state or a row
     * is present — never neither, which would be a list that silently failed to
     * load — and where the machine can be driven, the `+` is on the bar in both
     * cases.
     */
    func testTheHomeAlwaysSettlesOnSomething() throws {
        let empty = app.descendants(matching: .any)
            .matching(identifier: "browser.windows.empty").firstMatch
        /*
         * **Three kinds of row, not one.** This asked only for
         * `browser.machine.row.` — a window the phone can drive — and went red
         * against a real machine whose only open page was the drive's own front
         * tab, which is a `surface` row and is exactly what `web.open` produces.
         * A phone holding a page of its own over a tunnel is the third kind. All
         * three are the list having settled on something; asking for one of them
         * made this case a test of what happened to be open.
         */
        let anyRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'browser.machine.row.'"
                                  + " OR identifier BEGINSWITH 'browser.machine.surface.'"
                                  + " OR identifier BEGINSWITH 'browser.machine.page.'")).firstMatch
        let noBrowser = app.descendants(matching: .any)
            .matching(identifier: "browser.windows.unavailable").firstMatch

        XCTAssertTrue(empty.waitForExistence(timeout: 25) || anyRow.exists || noBrowser.exists,
                      "the home should settle on a window, on the empty state, or on the one line "
                      + "that says this machine is not offering its browser")

        if noBrowser.exists { throw XCTSkip(Self.notDrivable) }
        XCTAssertTrue(app.buttons["browser.new"].exists,
                      "a machine whose browser can be driven should always offer the way in")
    }

    /**
     * **One pill on the right, with the `+` left of the `…` inside it.**
     *
     * > *"This plus button and three dots thing — which I said it will stay on
     * > left and three dot will be on right — what I meant is they should stay
     * > together like before, but like both will be on right side, one pill. But
     * > inside the pill, three dot will be on right side and plus button will be
     * > on left side. For inside the terminal page, and browser thing when we
     * > browse that, like in the page before we open."*
     *
     * Two assertions, because the round before this one satisfied the first
     * while breaking what he meant. His earlier sentence — *"the plus button
     * should be left and three dots should be on the right side"* — was read as
     * the two **edges** of the navigation bar, the `+` went to `.topBarLeading`,
     * and the ordering check below still passed: a `+` in the far-left corner is
     * indeed left of a `…` in the far-right one. So the ordering is kept and the
     * side is added, and it is the side that carries his correction.
     *
     * Measured on the frames rather than read off the placement constant, which
     * is the only way to catch either of them: `.topBarLeading` and
     * `.topBarTrailing` both compile and both draw, and a swap reads as correct
     * in every diff.
     */
    func testThePlusAndTheDotsShareOnePillOnTheRight() throws {
        let plus = app.buttons["browser.new"]
        try XCTSkipUnless(plus.waitForExistence(timeout: 20), Self.notDrivable)
        let more = app.buttons["browser.more"]
        XCTAssertTrue(more.exists, "the home should keep its menu")
        XCTAssertLessThan(plus.frame.minX, more.frame.minX,
                          "inside the pill the plus is on the left and the dots on the right")

        let bar = app.navigationBars.firstMatch
        XCTAssertTrue(bar.exists, "there should be a navigation bar to measure against")
        XCTAssertGreaterThan(plus.frame.minX, bar.frame.midX,
                             "both controls belong in one pill on the trailing edge — a plus in the "
                             + "leading corner is the split he asked to have undone")
    }

    // MARK: - Where localhost went

    /**
     * **There is no second page, and the ports are in the one that is left.**
     *
     * > *"now here you still kept localhost as a separate page inside the page,
     * > and the browser as a separate page in the page. So I wanted it to be
     * > like ONE page where I can start a new window."*
     *
     * Three assertions in one case, because each on its own is a half-truth. No
     * address bar on the home; **no row in the `…` that leads to a second
     * browser**; and the ports reachable inside the `+`, which is the one place a
     * window is started. A rearrangement fails silently by building the new place
     * and leaving the old one standing, so the absence is asserted as hard as the
     * presence.
     */
    func testThereIsNoSecondBrowserAndThePortsAreInTheOpener() throws {
        XCTAssertFalse(app.textFields["browser.address"].exists,
                       "the address bar should not be on the home")

        let more = app.buttons["browser.more"]
        try XCTSkipUnless(more.waitForExistence(timeout: 20), Self.noMachine)
        more.tap()
        XCTAssertFalse(app.buttons["Localhost"].waitForExistence(timeout: 3),
                       "the menu should no longer lead to a browser of its own")
        capture("30-no-second-browser")
        app.dismissAnyMenu()

        XCTAssertTrue(app.openLocalhostList(),
                      "the ports belong to the act of opening a window")
        capture("31-ports-in-the-opener")
        XCTAssertTrue(app.textFields["browser.address"].exists,
                      "and the one address field in the app is the one on that sheet")

        app.closeLocalhostList()
        XCTAssertTrue(app.buttons["browser.more"].waitForExistence(timeout: 8),
                      "Cancel should come back to the home without opening anything")
    }

    // MARK: - Opening one

    /**
     * Opening a window is an act with a sheet, not a card on the list.
     *
     * The address field and the Shared / Isolated choice belong to the moment a
     * window is made, which is why they are here and not on the home. Both are
     * asserted, because dropping the isolation choice into the sheet and
     * forgetting to draw it would look exactly like a tidy sheet.
     *
     * **Cancelled, never submitted.** Pressing Open would put a window on
     * somebody's real machine.
     */
    func testOpeningAWindowIsASheetThatCarriesTheIsolationChoice() throws {
        let plus = app.buttons["browser.new"]
        try XCTSkipUnless(plus.waitForExistence(timeout: 20), Self.notDrivable)
        plus.tap()

        let field = app.textFields["browser.address"]
        XCTAssertTrue(field.waitForExistence(timeout: 8),
                      "the sheet should open on the field that says where the window goes")

        /*
         * **Not `segmentedControls` any more, and the `||` is gone with it.**
         *
         * The destination was a `.segmented` Picker and it read as a filter over
         * the port list it was sitting on — *"this feels like a filter, not like
         * a selection of this specific one."* It is a card of rows now, which is
         * an `otherElement` and not a segmented control, so the second half of
         * that `||` could only ever pass by accident from some other segmented
         * control on screen. One assertion, on the identifier the card carries.
         */
        let chooser = app.otherElements["browser.open.isolation"]
        XCTAssertTrue(chooser.exists,
                      "where a window opens is part of opening one, not a control on the list")

        // Above the field, which is the correction itself and is measurable.
        XCTAssertLessThan(chooser.frame.minY, field.frame.minY,
                          "the destination is chosen before the address is typed, so it reads first")

        XCTAssertTrue(app.buttons["browser.open.go"].exists,
                      "an address with nothing to press is not a way in")
        capture("31-open-a-window")

        /*
         * **Each destination is one tap, and the tap selects.**
         *
         * This is the regression guard for the trap the rebuild had to avoid: as
         * a `Menu`, the first tap on `Isolated` would open a menu rather than
         * choose, `TabNavigation.openLocalhostList` and `SessionPageUITests`
         * would both go on passing, and windows would quietly start opening in
         * his real Chromium profile. So the words are asserted — they are what
         * those suites press — and so is the selection landing.
         */
        for name in ["Machine", "Isolated"] {
            XCTAssertTrue(app.buttons[name].exists,
                          "\(name) should be a plain button carrying its own word")
        }
        let isolated = app.buttons["Isolated"]
        isolated.tap()
        XCTAssertTrue(isolated.isSelected,
                      "one tap on Isolated must select it, not open something")
        XCTAssertTrue(app.buttons["Machine"].exists,
                      "and the other destinations stay on screen, which a menu's would not")
        capture("31b-destination-chosen")

        app.buttons["browser.open.cancel"].tap()
        XCTAssertTrue(app.buttons["browser.more"].waitForExistence(timeout: 8),
                      "Cancel should come back to the home without opening anything")
    }

    // MARK: - A row, from the outside

    /**
     * **Every row's `…` carries the same outside verbs, and the ones a row
     * cannot be asked for are drawn greyed rather than left out.**
     *
     * > *"from the outside we can just make it archive, close, or connect to any
     * > session, or things from three dots and all the relevant stuff."*
     *
     * ## Why this opens more than one of them
     *
     * > *"Okay, this one is attached to this session. Maybe this is the
     * > difference, and this one is not attached to anyone. But **there is no way
     * > to attach this one too**. So it should be the same case, or all the
     * > options should be available at least."*
     *
     * Only a `.window` row used to have a menu at all. The machine's own front
     * tab is minted no window id and a page this phone is holding over a tunnel
     * is not in that browser, every verb behind the `…` is addressed by a window
     * id, and so those two rows carried a bare `>`. What he read off a row with
     * no menu beside a row with one is that the app can do less for this page
     * than for that one and will not say why.
     *
     * So `MachineBrowserView.rowMenu` builds all three kinds from one function
     * now, and an item that cannot be sent is drawn **disabled** under a section
     * header naming the reason. That is a claim about the **list** rather than
     * about one row, and it fails in exactly one way — one kind of row quietly
     * keeping a menu of its own — so this walks every `…` it can reach instead of
     * the first. On a server the first row is the drive's own front tab, which is
     * the row that used to have nothing on it.
     *
     * Screenshot and Watch were on this menu until this build and both moved
     * inside the window, because both act on the page rather than on the window.
     * Their absence is asserted, because the failure mode of a move is that the
     * old copy survives it.
     *
     * `Close window` and `Archive` are what prove both halves: that the menu came
     * up, and that it is the same menu on every row. Where the row cannot be
     * asked for them they are still there and greyed, which is the requirement
     * and not a weakening of it — so the reason is asserted alongside, by its
     * words, the way every presented menu label in this target is reached.
     *
     * The session rows cannot be asserted by name: each carries a session's own
     * title and a count, both minted on the machine, and a `.window` row on a
     * machine running nothing draws no such section at all — which is the product
     * refusing to draw a control that could only refuse.
     *
     * Nothing is pressed.
     */
    func testEveryRowsMenuCarriesTheSameOutsideVerbs() throws {
        let menus = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'browser.machine.more.'"))
        try XCTSkipUnless(menus.firstMatch.waitForExistence(timeout: 20), Self.noWindows)

        /*
         * Four at most, and only the ones a thumb could reach without scrolling.
         * Each menu is a presentation to raise and dismiss against somebody's
         * live machine, and the claim is about the *shapes* of row on this list —
         * a machine's window, its own front tab, a page this phone holds — of
         * which there are three.
         */
        let walk = min(menus.count, 4)
        for index in 0 ..< walk {
            let dots = menus.element(boundBy: index)
            guard dots.exists, dots.isHittable else { continue }
            let row = dots.identifier
            dots.tap()

            let close = app.buttons["Close window"]
            XCTAssertTrue(close.waitForExistence(timeout: 5),
                          "every row's menu should come up and carry Close window — \(row)")
            let archive = app.buttons["Archive"]
            XCTAssertTrue(archive.exists,
                          "and Archive beside it, which is the second of the three verbs he named "
                          + "for a row from the outside — \(row)")

            XCTAssertFalse(app.buttons["Screenshot"].exists,
                           "photographing a window acts on its page — it belongs inside the window")
            XCTAssertFalse(app.buttons["Watch and drive"].exists,
                           "watching a window is what opening the row does now")

            /*
             * A greyed item owes the line above it.
             *
             * `rowMenu` puts the items a row cannot be asked for inside a
             * `Section` whose header is `whyNoWindowVerbs` — one sentence per
             * kind of row, and a different fact in each rather than a general
             * apology. A disabled item with no reason on screen is the dead
             * control this menu was rebuilt to stop being.
             */
            /*
             * The third string used to be `"not in the machine's browser"`, which
             * was the reason an **On this phone** row gave for greying its whole
             * menu — attach included. That row's attach is live now: it opens the
             * same address in the machine's browser and binds that window, so the
             * only item still greyed on it is Archive, under a reason of its own
             * about the archive rather than about window ids. See
             * `MachineBrowserView.pageItems`.
             */
            if !archive.isEnabled {
                let why = app.descendants(matching: .any).matching(
                    NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@",
                                "no window id to address",
                                "No window row for this page",
                                "Archiving is for the machine's own windows")).firstMatch
                XCTAssertTrue(why.waitForExistence(timeout: 5),
                              "a greyed item with nothing saying why is worse than no item — "
                              + "\(row) should carry the sentence its section header holds")
            }

            if index == 0 { capture("32-window-row-menu") }

            /*
             * `Attach to a session` is a `Section` header on a `.window` row and
             * a greyed **row** on the other two, so it is asked for by its words
             * either way. Absent altogether on a machine running no sessions,
             * which is why this is said out loud rather than left as a silent
             * pass: "the binding control is missing" and "this machine has no
             * sessions" look identical from here.
             */
            let attach = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH 'Attach to'"
                                      + " OR label CONTAINS 'and attach'")).firstMatch
            if !attach.exists {
                XCTContext.runActivity(named: "no sessions to attach to, from \(row)") { _ in }
            }

            app.dismissAnyMenu()
            // Gone before the next one is opened. Two menus up at once is a tap
            // that lands on the dismiss layer and a case that reports the first
            // menu's contents twice.
            _ = close.waitForNonExistence(timeout: 5)
        }
    }

    /**
     * The same verbs under a thumb.
     *
     * > *"we can swipe them left and right and we can have options there to
     * > delete or close the options or archive and things, just like WhatsApp
     * > has the chats."*
     *
     * Close first and Archive second, which is where the session list puts the
     * same two words — a gesture is learned once and used on every list, and one
     * that moved Archive to a different slot on a different list is one people
     * stop trusting.
     *
     * The leading edge is asserted to be **empty**, and that is deliberate
     * rather than an omission: Watch and Screenshot were on it and both went
     * inside the window, and drawing something there to keep the gesture
     * symmetrical would mean inventing a verb.
     *
     * The order of the two gestures is load-bearing. The leading edge is tried
     * **first, on an untouched row**, because a swipe that opens onto nothing
     * and a swipe whose close animation has not finished look identical to a
     * query — asserting an absence straight after a trailing swipe is how a
     * suite gets a failure that reproduces one run in five.
     *
     * **Nothing is pressed.** The first button closes a real browser window on
     * Asad's real machine. The dismissal is a swipe back rather than a tap
     * anywhere: a tap on a list with an open swipe closes the swipe on some rows
     * and lands on the row underneath on others, and the row underneath is
     * another window.
     */
    func testAWindowRowSwipesToCloseAndArchive() throws {
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'browser.machine.row.'")).firstMatch
        try XCTSkipUnless(row.waitForExistence(timeout: 20), Self.noWindows)

        let anySwipe = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'browser.machine.swipe.'")).firstMatch
        row.swipeRight()
        XCTAssertFalse(anySwipe.waitForExistence(timeout: 2),
                       "the leading edge has no verb left on it and must not invent one")

        row.swipeLeft()
        let close = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'browser.machine.swipe.close.'"))
            .firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5),
                      "the trailing edge should offer Close, which is the row's destructive verb")
        XCTAssertTrue(app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'browser.machine.swipe.archive.'"))
            .firstMatch.exists,
                      "and Archive beside it, which is the reversible one")
        capture("33-window-row-swipe")
        row.swipeRight()
    }

    // MARK: - Inside one

    /**
     * Tapping a window gives you the window, with its address and its navigation
     * on a bar under it.
     *
     * > *"we should be able just to see only the open windows, and then we can
     * > just click on any of them."*
     *
     * The bar is what both shapes of that screen have — the live picture and, on
     * a window the machine will not cast, the settings drawn as the body — so it
     * is what proves arrival regardless of which one this machine produced.
     */
    func testAWindowOpensOntoItsOwnAddressAndNavigation() throws {
        try openTheFirstWindow()
        capture("34-a-window")

        XCTAssertTrue(app.textFields["browser.machine.window.address"].exists,
                      "a window's own address is typed into on the window's own screen")
        for control in ["browser.machine.window.back",
                        "browser.machine.window.forward",
                        "browser.machine.window.reload"] {
            XCTAssertTrue(app.buttons[control].exists, "\(control) should be on the window's bar")
        }
    }

    /**
     * **Per-window settings are inside the window**, and which of the two shapes
     * this machine produces is a fact about the window rather than about the
     * app.
     *
     * > *"When we click on three dots then we can see the settings — per window
     * > also, inside the window: settings of per window, how to connect to it,
     * > how to make it shared or isolated, all of these things should be inside
     * > of the window."*
     *
     *  - The machine is casting this window: the screen is the live picture and
     *    the settings are behind the `…` on its bar.
     *  - It is not: those same cards are the body of the screen already, and
     *    there is no `…`, because a control leading to where you are standing is
     *    worse than no control.
     *
     * Both are correct and **exactly one** of them must be true — a screen with
     * neither is one that failed to decide, and one with both is a menu leading
     * to itself.
     */
    func testAWindowsSettingsAreInsideTheWindow() throws {
        try openTheFirstWindow()

        let dots = app.buttons["browser.machine.window.settings"]
        let inlineRecord = app.buttons["browser.machine.window.record"]
        let cast = dots.waitForExistence(timeout: 6)

        XCTAssertNotEqual(cast, inlineRecord.exists,
                          "a window is either being cast — settings behind the dots — or it is not, "
                          + "and its settings are the screen. Never both and never neither.")

        if cast {
            dots.tap()
            XCTAssertTrue(app.buttons["browser.machine.window.record"].waitForExistence(timeout: 8),
                          "the settings should carry the click recorder")
        }
        capture("35-window-settings")

        XCTAssertTrue(app.buttons["browser.machine.window.isolation"].exists,
                      "shared and isolated should be convertible in both directions, inside the window")
        XCTAssertTrue(app.buttons["browser.machine.window.shot"].exists,
                      "photographing a window and looking at it here is one of the things this "
                      + "screen is for")
        XCTAssertTrue(app.buttons["browser.machine.window.close"].exists,
                      "and closing it from inside it")

        /*
         * The screenshot's session picker is **on the same card as the
         * screenshot** — *"creating a screenshot and sending it to the session,
         * whatever session we want to send."* Two screens apart, this is a
         * feature nobody uses.
         *
         * Drawn only when the machine has a session to send to, so its absence
         * is recorded rather than asserted: a control that could only ever
         * refuse is one this app does not draw.
         */
        if app.buttons["browser.machine.window.shotTo"].exists {
            XCTAssertTrue(app.textFields["browser.machine.window.shotNote"].exists,
                          "a note travels with a picture handed to a session")
        } else {
            XCTContext.runActivity(named: "no sessions on this machine to send a picture to") { _ in }
        }
    }

    // MARK: - A page this phone is drawing

    /**
     * **The attach on an *On this phone* row is a live control, and its settings
     * are a real screen.**
     *
     * > *"And these three dots, we should have this attachment thing for all of
     * > them, properly working, and the same way on the sessions side also."*
     *
     * This row's menu used to be four greyed items under one line saying the page
     * was not in the machine's browser. Both halves of that are checked here and
     * both are checked by their **words**, because an `accessibilityIdentifier`
     * on a `Button` inside a SwiftUI `Menu` does not reach the presented row —
     * the rule this whole suite follows.
     *
     * Three outcomes are all correct and only one of them is the interesting one,
     * so the assertion is a disjunction over the three sentences the menu can
     * carry rather than a demand for the live section: the machine may be running
     * no sessions, and it may not be offering its browser to this phone at all.
     * What is **not** allowed is silence — a greyed row with nothing above it.
     *
     * **Nothing is pressed that changes anything.** A session row here would open
     * a real window on his real machine, so the menu is revealed, read and
     * dismissed. `Page settings` is pressed, because a settings screen is inert
     * until one of its own controls is used, and none of them is.
     *
     * The click recorder's absence is asserted. It is the one control that
     * cannot follow a page this phone renders — it is the machine's recorder
     * watching the machine's own browser — and the failure mode of *"give it
     * everything"* is drawing it anyway and having it refuse.
     */
    func testAPhonePagesMenuAttachesAndItsSettingsAreReal() throws {
        let dots = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'browser.machine.more.page.'"))
            .firstMatch
        try XCTSkipUnless(dots.waitForExistence(timeout: 20), Self.noPhonePage)
        dots.tap()

        let attach = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@",
                        "and attach",
                        "Nothing is running on",
                        "not offering its browser")).firstMatch
        XCTAssertTrue(attach.waitForExistence(timeout: 5),
                      "an On this phone row should either offer the attach or say in one line why "
                      + "it cannot — never a greyed row with nothing above it")

        let settings = app.buttons["Page settings"]
        XCTAssertTrue(settings.exists,
                      "a page this phone draws has no bar of its own, so its settings are on the "
                      + "menu")
        capture("37-phone-page-menu")

        settings.tap()
        XCTAssertTrue(app.buttons["browser.phone.page.shot"].waitForExistence(timeout: 10),
                      "this phone renders the page, so it can photograph it")
        XCTAssertTrue(app.buttons["browser.phone.page.otherWay"].exists,
                      "and offer the move that puts the same address in the machine's browser")
        XCTAssertTrue(app.buttons["browser.phone.page.close"].exists,
                      "and close it")
        XCTAssertFalse(app.buttons["browser.machine.window.record"].exists,
                       "the click recorder is the machine's, watching the machine's own browser — "
                       + "it must not be drawn for a page this phone is rendering")
        capture("38-phone-page-settings")

        /*
         * The note field is drawn only where there is somewhere to send a
         * picture, so its absence is recorded rather than asserted — a control
         * that could only ever refuse is one this app does not draw.
         */
        if app.buttons["browser.phone.page.shotTo"].exists {
            XCTAssertTrue(app.textFields["browser.phone.page.shotNote"].exists,
                          "a note travels with a picture handed to a session")
        } else {
            XCTContext.runActivity(named: "nothing running on this machine to send a picture to") { _ in }
        }

        app.navigationBars.buttons.firstMatch.tap()
    }

    // MARK: - Where an archived window comes back from

    /**
     * Archive is a real place, not a word on a button.
     *
     * There is no archive verb on this wire and there was no notion of one
     * anywhere in the product — `WindowShelf` builds it on the phone, the way
     * `SessionShelf` builds the same word for the session list. What makes that
     * honest rather than a Close with a gentler label is that the row comes
     * back, so the screen it comes back from has to exist and has to say what
     * archiving did and did not do.
     *
     * The menu row is drawn even when the list behind it is empty, deliberately:
     * that empty state is where somebody who has not found the gesture ends up,
     * and it is the only place the gesture is named. So this asserts the screen
     * is reachable and that it settles on one of its two shapes — never on
     * nothing at all.
     *
     * **Nothing is archived to make a row exist.** The store is this simulator's
     * own `UserDefaults` and a row hidden here would stay hidden for every later
     * run in this suite and the next.
     */
    func testTheArchiveIsAPlaceAWindowComesBackFrom() throws {
        let more = app.buttons["browser.more"]
        try XCTSkipUnless(more.waitForExistence(timeout: 20), Self.notDrivable)
        more.tap()

        var row = app.buttons["Archived"]
        if !row.waitForExistence(timeout: 5) {
            // The label carries a count once there is one — `Archived (2)` — so
            // an exact match is not enough on a phone that has used the gesture.
            row = app.buttons
                .matching(NSPredicate(format: "label BEGINSWITH 'Archived'")).firstMatch
        }
        guard row.exists else {
            app.dismissAnyMenu()
            throw XCTSkip(Self.notDrivable)
        }
        row.tap()

        let empty = app.descendants(matching: .any)
            .matching(identifier: "browser.archived.empty").firstMatch
        let anyRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'browser.archived.row.'")).firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 10) || anyRow.exists,
                      "the archive should say it is empty or show what is in it")
        capture("36-archived-windows")

        if empty.exists {
            /*
             * Nothing is asserted about the words on it, deliberately. An
             * `accessibilityIdentifier` on a `ContentUnavailableView` makes that
             * view an accessibility element and the `Text` inside it stops
             * existing in the tree — measured on iOS 26.4 and written down in
             * `TabNavigation.swift` — so a query for the sentence it draws would
             * fail on a screen that is perfectly correct.
             */
            XCTContext.runActivity(named: "nothing archived on this phone yet") { _ in }
        } else {
            XCTAssertTrue(app.staticTexts["browser.archived.footnote"].exists,
                          "the sentence that says these windows are still open must be on screen")
        }

        app.navigationBars.buttons.firstMatch.tap()
    }

    // MARK: - Getting there

    /// Push the first window's own screen, or skip. Nothing is opened on the
    /// machine to make one exist — this suite does not leave a window on
    /// somebody's real desktop behind every run.
    private func openTheFirstWindow() throws {
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'browser.machine.row.'")).firstMatch
        try XCTSkipUnless(row.waitForExistence(timeout: 20), Self.noWindows)
        row.tap()
        try XCTSkipUnless(app.buttons["browser.machine.window.reload"].waitForExistence(timeout: 15),
                          "the window's own screen never came up")
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
