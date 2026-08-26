/**
 * The live page, and whether it behaves like a browser or like a video.
 *
 * > *"if I open a browser window it feels like a streaming, exactly — and if I
 * > open any one it feels like just like a video. I cannot click inside, I cannot
 * > touch the URL and things. I mean I need it should be feeling like a neat
 * > native browser."*
 *
 * ## There is one screen now, and that is what this suite walks
 *
 * There were two screens showing a live page with two different amounts of
 * browser on them, and he put them side by side and counted them:
 *
 * > *"this one is the one with the full view. But with the full view, at least it
 * > should have all the options. If I am even opening this one here, look, now
 * > here it is different. Now we have two windows. In iMatch, one of them has
 * > different menu options here in the bottom, the tab menu, and this one has
 * > different only reload, nothing else. So why they are two different type…
 * > **it should be the same case, or all the options should be available at
 * > least.**"*
 *
 * Every row on the Browser tab that is a page in the machine's browser — a
 * window the phone can drive, the machine's own front tab, a cast that no window
 * row claims — pushes `MachineWindowView`, whose bar is `BrowserPageBar` under
 * the single identifier `browser.machine.window`. So there is one screen to
 * reach and one set of names to reach it by, and what separates two pages is
 * held one control at a time on that bar rather than by which screen a tap
 * landed on.
 *
 * `WatchViewerScreen` draws the same bar under `browser.watch` and is reached
 * only from Settings → Watch browser, where there is a `WatchLink` and no model
 * behind the surface. Nothing on the Browser tab reaches it, so nothing in this
 * suite does either.
 *
 * ## And the third kind: a page this phone is holding open
 *
 * There is one more row on that home — `browser.machine.page.`, a port on the
 * machine tunnelled to this phone and shown in this app's own web view. It is a
 * different screen (`LocalhostBrowser`) and a different type behind it, and this
 * suite used to leave it alone on the grounds that it had none of the controls
 * below. That *was* the defect:
 *
 * > *"So top, header and footer, tab bar should be same in all type of browsing
 * > windows, including on this phone, including isolated, including the server."*
 *
 * > *"if it is in this phone, I cannot edit the link and make a change and search
 * > it again."*
 *
 * It mounts the same `BrowserPageBar` now, under the prefix `localhost`, so one
 * case here opens one and puts it through the same assertion the machine's
 * windows go through — the verbs in the row, and the door to the window's own
 * things. Everything else in this file still stays on the machine's side.
 *
 * ## And on that one screen the two ends have since swapped
 *
 * > *"this link should be on the top header instead of bottom just like the
 * > normal browsers. I think on top you should have back button and link only,
 * > and then in the bottom you should have the rest of the options and three dot
 * > in the right side which will open the rest of the options, not upside here.
 * > Three dot should be here where we have right now size, so it can bring the
 * > options from up to down down to up."*
 *
 * So the shared assertion below takes a **place** now. On a window on the machine
 * the address is on the bar and the `…` is a trailing item in the navigation bar;
 * on the page this phone is holding open the address is *in* the navigation bar
 * and the `…` is the last slot of the row. The verbs are identical either way and
 * that is still asserted unconditionally — what is asserted per screen is where
 * the two movable things ended up, because *where* is the entire requirement and
 * a case that could not tell the two apart would pass with either screen wearing
 * the other's chrome.
 *
 * ## Why this is a suite and not a unit test
 *
 * The geometry is unit-tested — `WatchTests` pins `fit`, `clampDrawn` and
 * `imageCoords`, which is where the letterbox defect lived. What cannot be
 * unit-tested is the half of the complaint that is about *controls*: whether the
 * screen a cast page lands on has an address you can put a cursor in, whether a
 * tap on the page raises a keyboard, whether Done gives you the address back,
 * and whether a verb this page cannot be asked for is **drawn dead in its place
 * with the reason one tap away**. Those are questions about a running app
 * against a machine that is really casting, and the answer to the first of them
 * was **no** on the screen he was looking at.
 *
 * And one thing here can only be looked at: a pinch. This suite performs one and
 * photographs the result, then asserts what a test can honestly assert — that the
 * canvas is still there, still taking gestures, and the bar is still on it. A
 * magnification is a picture, and the picture is the attachment.
 *
 * ## It skips rather than fails, and each skip is a real state
 *
 * The standing rule of this target. No machine paired; a machine that is
 * offering neither its browser nor a cast, so no row on the home opens onto a
 * page at all; a machine with nothing open. Every one of those is the product
 * working.
 *
 * ## What this does to the machine, which is now one click
 *
 * The address field is **focused and cleared of nothing** — never submitted, and
 * Go is never pressed. Reload is never pressed either: this runs against Asad's
 * live server and the page on the front tab is a page somebody was looking at.
 * The pinch and the drag are this viewer's own magnification and never leave the
 * phone. The ⓘ beside the address opens a popover on this phone and is closed
 * again.
 *
 * The **tap** does leave the phone, and that is not an oversight in a suite that
 * used to say it changed nothing. There is no longer a control that raises the
 * keyboard without touching the page — *"I should not have to have this separate
 * button of keyboard. It should just come up from down"* — so `WatchView.onTap`
 * sends move/down/up at the point struck and takes first responder afterwards.
 * A test that wants to prove the keyboard comes up has to click the page, in the
 * middle of it: once, or up to three times where the canvas is still waiting for
 * its first frame and is refusing touches. Nothing is typed after it and Done
 * resigns the canvas, so no keystroke ever reaches the far side.
 */

import XCTest

final class BrowserPageBarUITests: XCTestCase {

    private var app: XCUIApplication!

    private var shots: String { ProcessInfo.processInfo.environment["TD_SHOTS"] ?? "" }

    /// The one prefix there is. `MachineWindowView` names it, and every control
    /// below hangs off it — the address, the page verbs, the typing row that
    /// replaces the address while the canvas holds the keyboard, and the `…`,
    /// which kept this same name when it moved up into the header.
    private static let bar = "browser.machine.window"

    private static let noMachine =
        "This phone is not paired with a running host. Run ios/Harness/live-localhost.sh, "
        + "which starts one and pairs the Simulator."

    private static let noPage =
        "No row on the Browser home opens onto a page — this machine offers neither its browser "
        + "nor a cast, or has nothing open. Both are the product working."

    /**
     * Which end of the phone a screen's `…` is at.
     *
     * Spelled out here rather than imported: a UI test drives the app through
     * accessibility and cannot see `BrowserMorePlace`, and a `Bool` called
     * `moreIsInTheHeader` would read as a thing switched off when it is a place.
     * The two cases are the two arrangements the app actually has, and the
     * assertion below is different for each — not stricter for one of them.
     */
    private enum MorePlace {
        /// A trailing item in the navigation bar, on a screen whose address is on
        /// the bar under the page. Every window on the machine.
        case header
        /// The last slot of the verb row, on a screen that has given its header
        /// to the address. The page this phone is holding open.
        case row
    }

    private static let noLocalPage =
        "No page is open on this phone. Those rows exist once a port on the machine has been "
        + "opened here through a tunnel; a Browser home with none is the product working."

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
     * Open the first page on the machine, and answer with the row it came from.
     *
     * **A surface row and a window row are the same destination now**, which is
     * the whole of *"it should be the same case"*: `MachineBrowserView` pushes
     * `MachineWindowView` for both and hands it the surface's own name, `""` and
     * all. So one query takes either, and the first row on a server is the front
     * tab — the screen that had no address bar on it, and the one he was holding
     * when he said a window *"feels like just like a video."*
     *
     * `browser.machine.page.` is deliberately **not** in this query. That row is
     * a page this phone is holding over a tunnel and it opens on a different
     * screen with a different model behind it — it wears the same bar now, and it
     * has its own case below rather than being folded in here, because the two
     * screens have to be reached separately for *"it should be the same case"* to
     * mean anything.
     *
     * Arrival is the bar or the canvas, in that order, because a window the
     * machine will not cast has a bar and no picture and is still this screen.
     */
    @discardableResult
    private func openAPage() throws -> String {
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'browser.machine.surface.'"
                                  + " OR identifier BEGINSWITH 'browser.machine.row.'"))
            .firstMatch
        guard row.waitForExistence(timeout: 25) else { throw XCTSkip(Self.noPage) }
        let name = row.identifier
        row.tap()

        let arrived = app.textFields["\(Self.bar).address"].waitForExistence(timeout: 20)
            || any("\(Self.bar).address.readOnly").exists
            || any("\(Self.bar).stage").exists
        guard arrived else { throw XCTSkip(Self.noPage) }
        return name
    }

    // MARK: - The bar

    /**
     * **The address he could not touch.**
     *
     * > *"So we go inside, we see, and this is working. This one should be
     * > editable. I should be able to change whatever which is working, I guess.
     * > But just fix this. **This one is the one that should be everywhere.**"*
     *
     * The line is on the bar under every page this screen shows, and it is a
     * field wherever the page can be navigated: it takes a cursor, and what is in
     * it is the page's own address rather than a placeholder. The last of those
     * is the one that would pass without meaning anything if it were left out: a
     * field that is always empty is a field nobody would call an address bar.
     *
     * A page that can be navigated by neither door draws the same line read-only
     * under `\(bar).address.readOnly` — a separate identifier on purpose, because
     * *"a test asking for `\(id).address` is asking whether this page can be typed
     * into, and a label wearing the field's name is exactly the pass that would
     * mean nothing."* That branch is asserted for what it owes instead: the
     * address is still on screen, and the ⓘ that says why nothing can be sent is
     * beside it.
     *
     * Nothing is submitted. Focus is taken and given back.
     */
    func testTheLivePageHasAnAddressFieldYouCanPutACursorIn() throws {
        let row = try openAPage()
        let address = app.textFields["\(Self.bar).address"]
        let readOnly = any("\(Self.bar).address.readOnly")
        XCTAssertTrue(address.waitForExistence(timeout: 20) || readOnly.exists,
                      "a live page with no address on it is a video of a browser — \(row)")
        capture("60-page-bar")

        guard address.exists else {
            XCTAssertTrue(app.buttons["info.this-page"].exists,
                          "an address drawn read-only owes the reason it cannot be typed into, "
                          + "and the ⓘ in its own row is where that sentence lives")
            return
        }

        let shown = (address.value as? String) ?? ""
        XCTAssertFalse(shown.isEmpty,
                       "the field should be seeded from the page, not left blank")

        address.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8),
                      "tapping the address should raise a keyboard — it is a field, not a label")
        capture("61-address-editing")
    }

    /**
     * **The same verbs under every page, the `…` above them, and the dead
     * ones say why.**
     *
     * > *"In iMatch, one of them has different menu options here in the bottom,
     * > the tab menu, and this one has different only reload, nothing else. So
     * > why they are two different type… **it should be the same case, or all the
     * > options should be available at least.**"*
     *
     * > *"So top, header and footer, tab bar should be same in all type of
     * > browsing windows, including on this phone, including isolated, including
     * > the server."*
     *
     * Back · Forward · Reload · Find · Inspect · Size is the row, and all six are
     * asserted first and unconditionally, because that is his sentence: the bar
     * under one page is the same bar as under any other. A verb that genuinely
     * cannot be put on the wire is **drawn in its place and greyed**, never left
     * out — `BrowserPageBar.slot` draws the dead glyph — and the row that used to
     * be shorter on some pages is the defect this whole round is about.
     *
     * The sixth control is not in the row any more:
     *
     * > *"Maybe we can give some better one header also, not only the bottom, so
     * > we can have most of the important controls for the flow."*
     *
     * The `…` is a trailing item in the navigation bar, under the same
     * identifier it always had, and it is asserted on its own terms below —
     * because unlike them it is drawn only where it opens something.
     *
     * Which of them can act is then read off the page rather than off the row it
     * came from, and `info.this-page` — the ⓘ that stands where the globe does —
     * is the app's own discriminator: `BrowserPageBar` draws it if and only if
     * something on this bar is greyed for a reason.
     *
     *  - **ⓘ on the bar** — at least one control must be disabled, and the
     *    popover must actually carry a sentence about it. Which one is disabled
     *    is not pinned here, because it differs honestly by page: a window this
     *    phone can drive greys only Find and Inspect, the machine's own front tab
     *    greys Back and Forward as well, and a cast with no control behind it
     *    greys everything.
     *  - **No ⓘ** — this page can be asked for everything, so Reload, Find and
     *    Inspect all act. Back and Forward are deliberately exempt from that: on
     *    a page this phone holds open they are the page's real history and are
     *    honestly disabled at the start of a site.
     *
     * The keyboard verb was the one thing every one of these bars drew, and it is
     * gone from all of them:
     *
     * > *"I should not have to have this separate button of keyboard. It should
     * > just come up from down, and the original native button should be there to
     * > move it down if I want, not a separate keyboard here inside the browser
     * > window."*
     *
     * Asserted as an absence rather than dropped, because an absence is the whole
     * requirement: a bar that grew the verb back would pass every other case in
     * this file.
     */
    func testTheSameVerbsAreOnEveryPageAndTheDeadOnesSayWhy() throws {
        let row = try openAPage()
        // `.header`: this screen's address is on the bar under the page, so its
        // `…` is still the trailing item up top. Nothing he said in the round
        // that moved the phone page's chrome was about this screen — *"same way
        // here it is fine because it is terminal, it should be the way I said."*
        try assertTheRowAndTheMenu(on: Self.bar, page: row, moreIn: .header)

        XCTAssertFalse(app.buttons["\(Self.bar).keyboard"].exists,
                       "the keyboard verb is deleted; the page raises the keyboard when it is "
                       + "tapped, and the keyboard's own accessory puts it away")
    }

    /**
     * **The page on this phone: the link on top, the verbs and the `…` below.**
     *
     * > *"if it is in this phone, I cannot edit the link and make a change and
     * > search it again."*
     *
     * > *"this link should be on the top header instead of bottom just like the
     * > normal browsers. I think on top you should have back button and link only,
     * > and then in the bottom you should have the rest of the options and three
     * > dot in the right side which will open the rest of the options, not upside
     * > here. Three dot should be here where we have right now size, so it can
     * > bring the options from up to down down to up."*
     *
     * This is the kind of window the rest of this suite deliberately skips —
     * `browser.machine.page.` is a port on the machine held open through a tunnel
     * and shown in this app's own web view, which for two rounds meant it had a
     * different bar and no address anywhere. It mounts `BrowserPageBar` now under
     * the prefix `localhost`, so the row is asserted by the same function every
     * other page's row goes through.
     *
     * ## What this case measures that no unit test can: which end things are at
     *
     * The address is still `localhost.address` and still a **field** rather than a
     * line — that is the whole of what he could not do, and it did not stop being
     * true when the field moved. What is new is *where*: it is asserted to be
     * inside the navigation bar's own rectangle, not merely high on the screen.
     * Those are different claims and only the first is his sentence; a field
     * floated at the top of the page would pass the second and be the wrong thing.
     *
     * The `…` is asserted at the other end, on the same three terms: below the
     * middle, on the same line as the verbs, and to the right of Size. *"Three dot
     * should be here where we have right now size"* is a claim about the row's
     * right-hand end, and a `…` merely *somewhere* at the bottom of the screen
     * would pass an existence check and read as a floating button.
     *
     * Done is still asserted **gone**. It closed the tunnel, which is a thing you
     * do to the window rather than to the page, so it is the `Close this window`
     * card on this page's own settings screen behind that `…`.
     */
    func testThePageOnThisPhoneHasTheLinkOnTopAndTheMenuAtTheEndOfTheRow() throws {
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'browser.machine.page.'"))
            .firstMatch
        guard row.waitForExistence(timeout: 25) else { throw XCTSkip(Self.noLocalPage) }
        let name = row.identifier
        row.tap()

        let address = app.textFields["localhost.address"]
        guard address.waitForExistence(timeout: 30) else { throw XCTSkip(Self.noLocalPage) }

        let shown = (address.value as? String) ?? ""
        XCTAssertFalse(shown.isEmpty,
                       "the field should be seeded from the page it is showing, not left blank — "
                       + "an address bar that is always empty is not one (\(name))")

        /*
         * And it is **in the header**, which is the requirement rather than a
         * detail of layout. Inside the navigation bar's own rectangle, not merely
         * above the middle of the screen: an address floated at the top of the
         * page would pass *above the middle* and be exactly the thing that was
         * moved.
         */
        let header = app.navigationBars.firstMatch
        XCTAssertTrue(header.exists,
                      "the page keeps the system navigation bar — the chevron, the title and the "
                      + "interactive pop all live on it")
        XCTAssertTrue(header.frame.contains(CGPoint(x: address.frame.midX, y: address.frame.midY)),
                      "the address is not in the header. \"This link should be on the top header "
                      + "instead of bottom just like the normal browsers\" (\(name))")
        capture("67-phone-page-bar")

        try assertTheRowAndTheMenu(on: "localhost", page: name, moreIn: .row)

        XCTAssertFalse(app.buttons["localhost.done"].exists,
                       "Done left the row; closing the window is inside the `…`, so the row under "
                       + "this page is the six page verbs and the door, like every other")

        address.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8),
                      "and the address takes a cursor — \"I cannot edit the link and make a "
                      + "change\" is the sentence this case exists for")
        capture("68-phone-address-editing")
    }

    /**
     * The row under whichever page is on screen — its controls, with a reason
     * behind every greyed one — and the door to the window's own things, at
     * whichever end of the phone this screen keeps it.
     *
     * Shared by both cases above rather than written twice, because *"it should
     * be the same case"* is a claim about two screens and a claim asserted by two
     * different functions is two claims.
     *
     * ## Why the `…` is asserted differently from the verbs
     *
     * The six are unconditional: they are the verbs that act on the page, the row
     * is the same under every page, and a missing one is always a defect.
     *
     * The `…` is not, in two different ways.
     *
     * **Where it is** depends on where that screen's address is, and the two are
     * one decision rather than two:
     *
     * > *"I think on top you should have back button and link only, and then in
     * > the bottom you should have the rest of the options and three dot in the
     * > right side which will open the rest of the options, not upside here."*
     *
     * A window on the machine keeps its address on the bar, so its header is free
     * and the `…` is up there. The page this phone holds open has given its header
     * to the address, so the `…` is the last slot of the row. `moreIn` is which,
     * and it is passed by the caller rather than sniffed, because a helper that
     * worked out where the control *happened* to be and then asserted that it was
     * there would assert nothing at all.
     *
     * **Whether it is drawn** is the older rule and it survives: it is drawn where
     * it **opens** something, and there is one honest shape of the machine's
     * screen where it opens nothing — a window the machine refuses to cast draws
     * `MachineWindowSettingsView` as its own body, so a `…` there would lead to
     * where you are already standing. That state is visible from out here — the
     * settings cards are on screen, and the click recorder is one of them — so the
     * two are asserted as an exclusive pair, exactly the way `MachineBrowserUITests`
     * asserts it: *"a window is either being cast — settings behind the dots — or
     * it is not, and its settings are the screen. Never both and never neither."*
     *
     * On a page this phone is holding open there is no such shape and no such
     * recorder, so the pair collapses to *the `…` is there*.
     */
    private func assertTheRowAndTheMenu(on bar: String, page: String,
                                        moreIn: MorePlace) throws {
        let back = app.buttons["\(bar).back"]
        XCTAssertTrue(back.waitForExistence(timeout: 20),
                      "Back belongs on the bar under every page, greyed where it cannot act — "
                      + "a shorter bar on some pages is what he counted as two products (\(page))")
        let forward = app.buttons["\(bar).forward"]
        let reload = app.buttons["\(bar).reload"]
        let find = app.buttons["\(bar).find"]
        let inspect = app.buttons["\(bar).inspect"]
        /*
         * Size is queried across every element type rather than as a button: it
         * is a `Menu` where the other five are `Button`s, and what XCUITest
         * classifies a SwiftUI menu as is not a thing to have an opinion about.
         * Asking `buttons` for it and getting nothing would skip the claim
         * silently, which is the shape of an assertion that never runs.
         */
        let size = any("\(bar).size")
        XCTAssertTrue(forward.exists, "and Forward beside it")
        XCTAssertTrue(reload.exists, "and Reload beside that")
        XCTAssertTrue(find.exists, "Find is on every one of these bars now, greyed where the page "
                      + "is not on this phone to be searched")
        XCTAssertTrue(inspect.exists, "and Inspect, on the same terms")
        XCTAssertTrue(size.exists,
                      "Size is on every one of these bars, and greyed on a window the machine is "
                      + "only sending pictures of — \"it should be the same case, or all the "
                      + "options should be available at least\"")

        /*
         * The `…`, at whichever end of the phone this screen keeps it.
         *
         * Across every element type rather than as a button, for the reason the
         * Size slot is: it is a `Menu` on the one route that has no settings
         * screen behind it and a `Button` everywhere else, and asking `buttons`
         * for it would skip the claim silently on the shape that is a menu.
         */
        let more = any("\(bar).settings")

        switch moreIn {
        case .header:
            // The one state where it is honestly not drawn.
            // `browser.machine.window.record` is the click recorder, which is only
            // ever on screen when the settings *are* the body of this screen.
            let settingsAreTheBody = app.buttons["browser.machine.window.record"].exists
            XCTAssertNotEqual(more.exists, settingsAreTheBody,
                              "a browser window either has its `…` in the header or has its "
                              + "settings as the body of the screen. Never both — that is a "
                              + "control leading to where you are standing — and never neither "
                              + "(\(page))")
            if more.exists {
                XCTAssertGreaterThan(app.frame.midY, more.frame.maxY,
                                     "the `…` belongs in this screen's header — \"not only the "
                                     + "bottom, so we can have most of the important controls "
                                     + "for the flow\" is a sentence about the top of the screen")
                XCTAssertTrue(more.isEnabled,
                              "the `…` is drawn only where it opens something, so a greyed one "
                              + "is a control that should not have been there at all")
            }

        case .row:
            /*
             * > *"in the bottom you should have the rest of the options and three
             * > dot in the right side which will open the rest of the options,
             * > not upside here. Three dot should be here where we have right now
             * > size, so it can bring the options from up to down down to up."*
             *
             * Three claims, and the first on its own would be nearly worthless: a
             * `…` floated anywhere over the bottom of the page passes *below the
             * middle* and is not in the row. So it is also asserted to be on the
             * **same line** as Back — which is what makes it a slot rather than a
             * button somebody dropped there — and to the **right of Size**, which
             * is the position he named.
             */
            XCTAssertTrue(more.exists,
                          "the `…` is missing from the end of the row. It is the way to "
                          + "everything this window can be asked for, closing it included "
                          + "(\(page))")
            XCTAssertTrue(more.isEnabled,
                          "the `…` is drawn only where it opens something, so a greyed one is a "
                          + "control that should not have been there at all")
            XCTAssertGreaterThan(more.frame.minY, app.frame.midY,
                                 "the `…` is in the top half of the screen. On this page the "
                                 + "header is the chevron and the link only — \"not upside "
                                 + "here\"")
            XCTAssertLessThan(abs(more.frame.midY - back.frame.midY), 8,
                              "the `…` is at the bottom of the screen but not in the row. It is "
                              + "the seventh slot beside the six verbs, not a button floating "
                              + "over the page")
            XCTAssertGreaterThan(more.frame.midX, size.frame.midX,
                                 "the `…` is not at the right-hand end of the row — \"three dot "
                                 + "in the right side… here where we have right now size\"")
        }

        let why = app.buttons["info.this-page"]
        if why.exists {
            let greyed = [back, forward, reload, find, inspect, size].filter { !$0.isEnabled }
            XCTAssertFalse(greyed.isEmpty,
                           "the ⓘ is drawn if and only if something on this bar is greyed for a "
                           + "reason — a bar with the reason and nothing greyed is an explanation "
                           + "of nothing")

            why.tap()
            let reason = app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@",
                            "cannot be addressed to it",
                            "nothing on this bar can be sent to it",
                            "is on the machine")).firstMatch
            XCTAssertTrue(reason.waitForExistence(timeout: 6),
                          "a greyed verb with no reason behind it is the dead control this round "
                          + "is about — the ⓘ should open on the sentence that says what cannot "
                          + "be done here and why")
            capture("66-why-the-verbs-are-dead")
            app.dismissAnyMenu()
        } else {
            // Back and Forward are exempt: on a page this phone holds open they
            // carry real history and start out with nowhere to go, which is an
            // honest disabled rather than a dead control.
            XCTAssertTrue(reload.isEnabled,
                          "a bar with nothing to explain is a page that can be asked for "
                          + "everything, so none of its verbs may be drawn dead")
            XCTAssertTrue(find.isEnabled)
            XCTAssertTrue(inspect.isEnabled)
            XCTAssertTrue(size.isEnabled)
        }
    }

    /**
     * **A tap on the page puts the keyboard up, and Done takes it down.**
     *
     * > *"This keyboard should not be working like this. If we just click inside
     * > and type from our keyboard, it should work… I should not have to have
     * > this separate button of keyboard. It should just come up from down, and
     * > the original native button should be there to move it down if I want, not
     * > a separate keyboard here inside the browser window."*
     *
     * This case is the same three claims it always made, entered through the
     * canvas instead of through a verb. The keyboard is raised on the **canvas**
     * — not on a field in the app's own chrome, which is what the bar did two
     * rounds ago and why nothing reached the page until Send was pressed. While
     * it is up the bar says so and offers Done; Done gives the address row back.
     *
     * The tap is the point of the case rather than a way of getting to one. What
     * makes the keyboard appear is `WatchView.onTap` taking first responder after
     * it has sent the click, and the only way to ask whether that happened is to
     * click. See the file header for what that costs the machine.
     *
     * Done is still asserted even though it is no longer the only way out — the
     * keyboard now carries `browser.page.keys.dismiss` on its own accessory — for
     * the same reason `BrowserPageBar` kept `stopTyping` and dropped
     * `startTyping`: where the keystrokes are going is worth a line, and a second
     * way out of them costs nothing.
     *
     * The address is asserted gone in **both** of its shapes while the page is
     * being typed into, because one bar with two jobs is the claim: a read-only
     * line left standing over a live keyboard would be the same defect as a field
     * left standing.
     *
     * What is *not* asserted here is that a keystroke arrives, because a page is a
     * picture and no query can read it. That was measured by hand against his
     * server and written down in `BrowserPageBar` — characters and Return arrive,
     * Backspace and the arrows do not, and the reason is a missing virtual key
     * code on the host. Nothing is typed by this case at all.
     */
    func testATapOnThePageRaisesAKeyboardAndDoneEndsIt() throws {
        try openAPage()
        // Across every element type rather than as an `otherElements`: see the
        // pinch case below for the measurement behind that.
        let stage = any("\(Self.bar).stage")
        try XCTSkipUnless(stage.waitForExistence(timeout: 20), Self.noPage)

        /*
         * Up to three taps, and the reason is the guard rather than a hedge.
         *
         * `WatchView.onTap` asks `page(at:)` where the touch landed, and that
         * refuses every touch until an **unmasked frame has arrived** — there is
         * no picture yet, so there is no pixel to name and no click to send, and
         * the responder is never taken either. A canvas that exists is not yet a
         * canvas that has been painted: the stage is mounted the moment the
         * screen is, and the first frame comes over the wire after it.
         *
         * So a single tap here is a race against the machine's first frame. Three
         * seconds apart rather than in a burst, which is also what keeps them
         * three separate clicks on the page rather than a double-click.
         */
        var raised = false
        for _ in 0 ..< 3 {
            stage.tap()
            if app.keyboards.firstMatch.waitForExistence(timeout: 3) {
                raised = true
                break
            }
        }
        XCTAssertTrue(raised, "a tap on the page should raise a keyboard")
        XCTAssertTrue(app.staticTexts["\(Self.bar).keys.label"].waitForExistence(timeout: 8),
                      "and the bar should say where the keystrokes are going")
        XCTAssertFalse(app.textFields["\(Self.bar).address"].exists,
                       "one bar with two jobs — the address and the page are never both live")
        XCTAssertFalse(any("\(Self.bar).address.readOnly").exists,
                       "and the read-only shape of that same line goes with it")
        capture("62-typing-into-the-page")

        app.buttons["\(Self.bar).keys.done"].tap()
        XCTAssertTrue(app.textFields["\(Self.bar).address"].waitForExistence(timeout: 8)
                        || any("\(Self.bar).address.readOnly").exists,
                      "Done should give the address back rather than leaving a dead end")
    }

    // MARK: - The gestures

    /**
     * **A pinch, and the canvas survives it.**
     *
     * The magnification itself is a picture and the picture is the attachment —
     * there is no query that reads how big a `CALayer`'s contents are drawn. What
     * a test can hold on to is that the gesture does not wedge the canvas: the
     * stage is still there afterwards, a two-finger drag is taken, and the bar is
     * still on the screen with its verbs on it.
     *
     * That is not a nothing assertion. The failure this guards against is real and
     * was the reason the pinch handler was written carefully: a magnification that
     * clamps wrongly leaves the picture parked off screen, and a `pan` written
     * against the wrong rectangle leaves it there for good.
     */
    func testPinchingMagnifiesTheCanvasWithoutWedgingIt() throws {
        try openAPage()
        /*
         * Queried across every element type rather than as an `otherElements`.
         * The identifier is on a SwiftUI `ZStack` whose only child is a
         * `UIViewRepresentable`, and what XCUITest classifies that as is not a
         * thing to have an opinion about — asking `otherElements` for it found
         * nothing and skipped this case silently, which is the shape of a test
         * that never runs.
         */
        let stage = any("\(Self.bar).stage")
        try XCTSkipUnless(stage.waitForExistence(timeout: 20), Self.noPage)

        capture("63-page-before-pinch")
        stage.pinch(withScale: 2.4, velocity: 1.4)
        capture("64-page-after-pinch")

        // Two fingers, which is what pans a magnified picture. It must not throw
        // the picture out of the view: the bar and the stage are both still here.
        stage.swipeUp(velocity: .slow)
        XCTAssertTrue(stage.exists, "the canvas should survive a pinch and a drag")
        /*
         * The bar, by the address row — in whichever of its two shapes this page
         * draws it.
         *
         * The sharper of the two things that could stand for *the bar is still
         * here*: a bar showing the address row is a bar that did not mistake this
         * pinch for a tap on the page and swap itself for the typing row. The
         * verbs cannot make that claim — they are drawn under the typing row too.
         */
        XCTAssertTrue(app.textFields["\(Self.bar).address"].exists
                        || any("\(Self.bar).address.readOnly").exists,
                      "and the bar should still be under it, on the address row")

        stage.pinch(withScale: 0.3, velocity: -1.4)
        capture("65-page-after-pinch-out")
        XCTAssertTrue(stage.exists)
    }

    // MARK: - Machinery

    /**
     * One element by identifier, across every element type.
     *
     * The canvas is a SwiftUI container around a `UIViewRepresentable` and the
     * read-only address is a `Text` in a row with a button in it; what XCUITest
     * classifies either of those as is not a thing to have an opinion about.
     * Asking `otherElements` for the stage found nothing and skipped a case
     * silently, which is the shape of a test that never runs.
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
