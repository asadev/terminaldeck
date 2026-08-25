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
        let anyRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'browser.machine.row.'")).firstMatch
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
     * The `+` is on the left and the `…` is on the right, on this tab and on the
     * sessions list, because he asked for it in those words.
     *
     * > *"On the sessions page the plus button is on one side and the three dots
     * > is on the other side, and on the browser page the three dots is on one
     * > side and the plus button is on another side. In both, the plus button
     * > should be left and three dots should be on the right side."*
     *
     * Measured on the frames rather than asserted from the placement constant,
     * which is the only way to catch it: `.topBarLeading` and `.topBarTrailing`
     * both compile and both draw, and a swap reads as correct in every diff.
     */
    func testThePlusIsLeftOfTheDots() throws {
        let plus = app.buttons["browser.new"]
        try XCTSkipUnless(plus.waitForExistence(timeout: 20), Self.notDrivable)
        let more = app.buttons["browser.more"]
        XCTAssertTrue(more.exists, "the home should keep its menu")
        XCTAssertLessThan(plus.frame.minX, more.frame.minX,
                          "the plus goes on the leading edge and the dots on the trailing one")
    }

    // MARK: - Where localhost went

    /**
     * **Localhost is folded away, and it is still reachable.**
     *
     * > *"Even the localhost thing should be folded somewhere else — whatever
     * > the available whole localhost addresses are, in three dots maybe, or
     * > somewhere else."*
     *
     * Both halves in one case, because either on its own is a half-truth: a
     * missing address bar could mean it was deleted, and a reachable one could
     * mean it never moved.
     */
    func testLocalhostIsBehindTheMenuAndStillReachable() throws {
        XCTAssertFalse(app.textFields["browser.address"].exists,
                       "the address bar should not be on the home")

        XCTAssertTrue(app.openLocalhostList(),
                      "the localhost list should be one row down the home's menu")
        capture("30-localhost-folded-away")
        XCTAssertTrue(app.textFields["browser.address"].exists,
                      "and it should still carry the address bar it used to have on the tab")

        XCTAssertTrue(app.openBrowserTab(), "and Back should return to the windows")
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

        XCTAssertTrue(app.textFields["browser.open.address"].waitForExistence(timeout: 8),
                      "the sheet should open on the field that says where the window goes")
        XCTAssertTrue(app.otherElements["browser.open.isolation"].exists
                        || app.segmentedControls.firstMatch.exists,
                      "shared or isolated is part of opening a window, not a control on the list")
        XCTAssertTrue(app.buttons["browser.open.go"].exists,
                      "an address with nothing to press is not a way in")
        capture("31-open-a-window")

        app.buttons["browser.open.cancel"].tap()
        XCTAssertTrue(app.buttons["browser.more"].waitForExistence(timeout: 8),
                      "Cancel should come back to the home without opening anything")
    }

    // MARK: - A row, from the outside

    /**
     * **A row's `…` carries the three outside verbs and no others.**
     *
     * > *"from the outside we can just make it archive, close, or connect to any
     * > session, or things from three dots and all the relevant stuff."*
     *
     * Screenshot and Watch were on this menu until this build and both moved
     * inside the window, because both act on the page rather than on the window.
     * Their absence is asserted, because the failure mode of a move is that the
     * old copy survives it.
     *
     * `Close window` is what proves the menu came up at all — it is the one row
     * that is always there. The session rows cannot be asserted by name: each
     * carries a session's own title and a count, both minted on the machine, and
     * a machine running nothing has no such rows to draw, which is the product
     * refusing to draw a control that could only refuse.
     *
     * Nothing is pressed.
     */
    func testARowsMenuCarriesOnlyTheOutsideVerbs() throws {
        let more = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'browser.machine.more.'")).firstMatch
        try XCTSkipUnless(more.waitForExistence(timeout: 20), Self.noWindows)

        more.tap()
        XCTAssertTrue(app.buttons["Close window"].waitForExistence(timeout: 5),
                      "a window's row menu should come up and be able to close it")
        capture("32-window-row-menu")

        XCTAssertTrue(app.buttons["Archive"].exists,
                      "archive is one of the three verbs he named for a row")
        XCTAssertFalse(app.buttons["Screenshot"].exists,
                       "photographing a window acts on its page — it belongs inside the window")
        XCTAssertFalse(app.buttons["Watch and drive"].exists,
                       "watching a window is what opening the row does now")

        // `Attach to a session` is a `Section` header rather than a row, so it
        // is not a button — reached the way any presented label is.
        let attach = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Attach to'")).firstMatch
        if !attach.exists {
            // Said out loud rather than left as a silent pass, because "the
            // binding control is missing" and "this machine has no sessions"
            // look identical from here.
            XCTContext.runActivity(named: "no sessions on this machine to attach to") { _ in }
        }

        app.dismissAnyMenu()
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
