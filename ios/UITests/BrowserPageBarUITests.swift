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

    /// The one bar there is. `MachineWindowView` names it, and every control
    /// below hangs off it — the address, the three page verbs, the `…`, and the
    /// typing row that replaces the address while the canvas holds the keyboard.
    private static let bar = "browser.machine.window"

    private static let noMachine =
        "This phone is not paired with a running host. Run ios/Harness/live-localhost.sh, "
        + "which starts one and pairs the Simulator."

    private static let noPage =
        "No row on the Browser home opens onto a page — this machine offers neither its browser "
        + "nor a cast, or has nothing open. Both are the product working."

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
     * `browser.machine.page.` is deliberately **not** in the query. That row is a
     * page this phone is holding over a tunnel, it opens in this app's own web
     * view, and it has none of the controls below because it is not a page on the
     * machine at all.
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
     * **The same three verbs under every page, and the dead ones say why.**
     *
     * > *"In iMatch, one of them has different menu options here in the bottom,
     * > the tab menu, and this one has different only reload, nothing else. So
     * > why they are two different type… **it should be the same case, or all the
     * > options should be available at least.**"*
     *
     * Back, Forward and Reload are on the bar under every page this screen shows,
     * and that is asserted first and unconditionally, because it is his sentence:
     * the bar under one page is the same bar as under any other. A verb that
     * genuinely cannot be put on the wire is **drawn in its place and greyed**,
     * never left out — `BrowserPageBar.slot` draws the dead glyph, and the row
     * that used to be shorter on some pages is the defect this whole round is
     * about.
     *
     * Which of them can act is then read off the page rather than off the row it
     * came from, and the reading is exact: `BrowserPageBar` draws the ⓘ in the
     * address row's leading slot — `info.this-page` — if and only if
     * `unavailable` is set, and `unavailable` is set if and only if `nil` verbs
     * are being drawn dead. So the ⓘ is the discriminator, and it is the one the
     * app itself uses.
     *
     *  - **ⓘ on the bar** — Back and Forward are `nil` for this page in every
     *    case that sets it, so both must be present and **disabled**, and the
     *    sentence behind the ⓘ must actually say why. Reload is deliberately not
     *    asserted either way: the machine's own front tab reloads through
     *    `web.open` and is live there while Back and Forward are dead.
     *  - **No ⓘ** — this page can be asked for everything, so all three act.
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

        let back = app.buttons["\(Self.bar).back"]
        let forward = app.buttons["\(Self.bar).forward"]
        XCTAssertTrue(back.waitForExistence(timeout: 20),
                      "Back belongs on the bar under every page, greyed where it cannot act — "
                      + "a shorter bar on some pages is what he counted as two products (\(row))")
        XCTAssertTrue(forward.exists, "and Forward beside it")
        XCTAssertTrue(app.buttons["\(Self.bar).reload"].exists, "and Reload beside that")

        let why = app.buttons["info.this-page"]
        if why.exists {
            XCTAssertFalse(back.isEnabled,
                           "this page has no window id to address `browser.window.act` to, so Back "
                           + "is drawn and does nothing rather than being left out")
            XCTAssertFalse(forward.isEnabled, "and the same for Forward")

            why.tap()
            let reason = app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@",
                            "cannot be addressed to it",
                            "nothing on this bar can be sent to it")).firstMatch
            XCTAssertTrue(reason.waitForExistence(timeout: 6),
                          "a greyed verb with no reason behind it is the dead control this round "
                          + "is about — the ⓘ should open on the sentence that names the machine "
                          + "and says what cannot be sent")
            capture("66-why-the-verbs-are-dead")
            app.dismissAnyMenu()
        } else {
            XCTAssertTrue(back.isEnabled,
                          "a bar with nothing to explain is a page that can be asked for "
                          + "everything, so none of its verbs may be drawn dead")
            XCTAssertTrue(forward.isEnabled)
        }

        XCTAssertFalse(app.buttons["\(Self.bar).keyboard"].exists,
                       "the keyboard verb is deleted; the page raises the keyboard when it is "
                       + "tapped, and the keyboard's own accessory puts it away")
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
