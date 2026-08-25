/**
 * Pointing at one thing inside a window **on the machine** — the half of item V9
 * that no unit test can see.
 *
 * ## What he was holding when he said it
 *
 * > *"the bottom and here we have flow, screenshot, and all of this stuff. But in
 * > the page, if I click on something, I don't have something to, some option to
 * > specifically inspect one piece. Here I also don't have. And then in the own,
 * > in the own this phone page, we have it, but we don't have the rest of the
 * > options here… So everything should, all of them should be identical, and all
 * > of them should have all the options. Should not be that much of difference in
 * > all of them."*
 *
 * `InspectUITests` proves the phone's own page: a real touch in a real
 * `WKWebView`, a real selector, a real line arriving in a session on the far
 * machine. This is the other browser, where none of that machinery exists — the
 * phone is watching pixels, so the tap is a point, the point crosses the wire as
 * `browser.window.pick`, and the machine's own browser answers.
 *
 * `MachinePickTests` covers the arithmetic and `ParityWireTests` covers the two
 * frames. What is left, and what only a running app can answer:
 *
 *  - the dashed-box Inspect control on a machine window is **live**, not greyed
 *    with an apology;
 *  - turning it on says what a tap will do, in the same place and the same shape
 *    the phone's own page says it;
 *  - a tap on the picture ends in **something on screen** — the sheet, or the
 *    machine's sentence about why not. Never in a wait that does not end, which
 *    is the one failure that looks identical to a hang;
 *  - the sheet is the same sheet: the same selector line, the same Wider and
 *    Narrower, the same preview of the exact string, the same Send-to picker.
 *
 * ## Nothing here changes anything on his machine
 *
 * This runs against a live host. A pick **reads** — it runs a hit test inside a
 * page the machine already has open and reports what it found; it presses
 * nothing, navigates nothing and types nothing. Send is deliberately never
 * pressed: that line would arrive in somebody's real agent. The preview is
 * opened and read instead, which is the string Send would have carried.
 *
 * ## Menu rows are pressed by their words
 *
 * An `accessibilityIdentifier` on a `Button` inside a SwiftUI `Menu` does not
 * reach the presented row — measured twice in this target. So the Send-to
 * picker's rows are found the only way they can be: everything that appeared
 * after the menu opened, minus everything that was on screen before it.
 *
 * ## It skips rather than fails, and each skip is a real state
 *
 *  - **nothing paired** — no machine to ask;
 *  - **no `browser.control`** — a guest device, or a host with no browser. Every
 *    per-window verb is correctly absent and Inspect with them;
 *  - **no window open, or a window the machine will not cast** — a window opened
 *    from the phone's own `+` is listed under `browser.window.rows` and **not**
 *    under `browser.surfaces`, so its screen is its settings rather than a
 *    picture. There is nothing to point at, which the bar says in its own
 *    sentence;
 *  - **a host whose browser cannot answer a pick** — the desktop, until its one
 *    line lands. That is not a skip: it is an assertion, because the sentence
 *    reaching the screen is exactly what stops it looking like a hang.
 */

import XCTest

final class MachineInspectUITests: XCTestCase {

    private var app: XCUIApplication!

    private var shots: String { ProcessInfo.processInfo.environment["TD_SHOTS"] ?? "" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()

        let paired = app.buttons["sessions.new"].waitForExistence(timeout: 20)
            || app.buttons["sessions.more"].exists
        try XCTSkipUnless(paired, Self.noMachine)

        XCTAssertTrue(app.openBrowserTab(), "the Browser tab should be reachable")
    }

    private static let noMachine =
        "This phone is not paired with a running host. Run ios/Harness/live-localhost.sh, "
        + "which starts one and pairs the Simulator."

    private static let noWindows =
        "This machine's browser has no window open. Every per-window control is correctly absent."

    private static let notCasting =
        "This machine is not showing this window, so there is no picture to point at — which is "
        + "the state BrowserChrome.inspectNeedsThePicture describes, not a failure."

    // MARK: - The control is there, and it is not an apology

    /**
     * **Inspect is in the row, on a machine window, and it is live.**
     *
     * The row is Back · Forward · Reload · Find · Inspect · More under every kind
     * of browser window in this app — *"it should be the same case, or all the
     * options should be available at least"* — and until this round the fifth of
     * those was greyed here with *"tapping into a window on the machine is not
     * ready yet"*. That sentence is gone from the app, so this asserts the two
     * halves of its going: the control exists, and where the window is being cast
     * it can be pressed.
     *
     * Where the window is **not** being cast the control is still there and still
     * greyed — that is the honest answer, and it is a different sentence about a
     * different thing (there is no picture), so that case skips rather than
     * failing.
     */
    func testInspectIsOnTheBarAndLiveOnAWindowBeingCast() throws {
        try openTheFirstWindow()

        let inspect = app.buttons["browser.machine.window.inspect"]
        XCTAssertTrue(inspect.waitForExistence(timeout: 15),
                      "every browser window in this app wears the same six controls, and Inspect "
                      + "is the fifth of them")
        capture("v9-01-window-bar")

        try XCTSkipUnless(inspect.isEnabled, Self.notCasting)
        XCTAssertTrue(app.staticTexts["Inspect"].exists || inspect.isEnabled,
                      "the control is drawn with its own name")
    }

    /**
     * Turning it on says what a tap will now do.
     *
     * The same row, the same glyph and the same place as the page on this phone —
     * under the header, at the top, because it is a sentence about the page and
     * the page is what the eye is on. *"Should not be that much of difference in
     * all of them."*
     *
     * The hint is queried across every element type rather than as a
     * `staticTexts`: the identifier sits on the row that holds the glyph and the
     * words, and what XCUITest classifies that as is not a thing to have an
     * opinion about — `BrowserPageBarUITests` measured an `otherElements` query
     * finding nothing and skipping silently, which is the shape of a test that
     * never runs.
     */
    func testTurningInspectOnSaysWhatATapWillDo() throws {
        try openTheFirstWindow()
        let inspect = app.buttons["browser.machine.window.inspect"]
        try XCTSkipUnless(inspect.waitForExistence(timeout: 15) && inspect.isEnabled, Self.notCasting)

        inspect.tap()
        let hint = any("browser.machine.window.inspectHint")
        XCTAssertTrue(hint.waitForExistence(timeout: 8),
                      "turning inspect on should say what a tap will now do, the way the page on "
                      + "this phone does")
        capture("v9-02-inspecting")

        // And off again, which is what makes it a mode rather than a one-way trip.
        inspect.tap()
        XCTAssertFalse(any("browser.machine.window.inspectHint").waitForExistence(timeout: 4),
                       "turning inspect off should take the hint with it")
    }

    // MARK: - A tap ends in something

    /**
     * **A tap on the picture ends on screen, one way or the other.**
     *
     * Two outcomes are correct and this asserts that one of them happened:
     *
     *  - the machine answered with an element, and the sheet is up carrying the
     *    selector it worked out;
     *  - the machine answered with a sentence — *"This machine's browser cannot
     *    point at one thing on a page."* on a host whose browser has no way to run
     *    a script inside itself, *"…has scrolled since that picture — tap the same
     *    thing again."*, *"There is nothing at that spot…"* — and the sentence is
     *    in the banner under the header.
     *
     * The third outcome is the one this exists to catch: **neither**. Every
     * refusal in this family comes back as the window list with a notice on it
     * rather than as an error frame, so a client that only ended its wait on
     * success would sit there with a spinner under a sentence explaining
     * everything. That is indistinguishable from a hang and it is what somebody
     * would report.
     *
     * The tap is at the middle of the picture. Not because the middle is
     * interesting — because it is the one point on any page that is certainly
     * inside the document rather than on the letterbox, and a tap on the letterbox
     * is correctly ignored.
     */
    func testATapWhileInspectingIsAnsweredRatherThanSwallowed() throws {
        try openTheFirstWindow()
        let inspect = app.buttons["browser.machine.window.inspect"]
        try XCTSkipUnless(inspect.waitForExistence(timeout: 15) && inspect.isEnabled, Self.notCasting)

        let stage = any("browser.machine.window.stage")
        try XCTSkipUnless(stage.waitForExistence(timeout: 25), Self.notCasting)

        inspect.tap()
        _ = any("browser.machine.window.inspectHint").waitForExistence(timeout: 8)

        // A beat for a frame to land: the canvas refuses a tap it has no picture
        // to measure against, which is the same guard that stops a finger on the
        // black bar pressing the top of the document.
        Thread.sleep(forTimeInterval: 4)
        stage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let selector = app.staticTexts["inspect.selector"]
        let notice = any("browser.machine.window.notice")
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline && !selector.exists && !notice.exists { usleep(300_000) }
        capture("v9-03-after-the-tap")

        XCTAssertTrue(selector.exists || notice.exists,
                      "a tap while inspecting has to end in the sheet or in the machine's own "
                      + "sentence. Ending in neither is the hang this assertion exists for — "
                      + "every refusal in this family arrives as the window list with a notice.")

        if !selector.exists {
            // The honest half. A host that cannot reach into its own browser says
            // so, and what matters is that the words are on the screen.
            XCTAssertFalse(notice.label.isEmpty,
                           "a refusal that draws an empty banner is a refusal nobody can read")
            capture("v9-03b-machine-said-no")
        }
    }

    /**
     * The sheet is the sheet — the same one the page on this phone opens.
     *
     * Every identifier below is `InspectSheet`'s own, and every one of them is
     * also what `InspectUITests` reaches for on the tunnel browser. That is the
     * proof that *"all of them should be identical"* was answered with one screen
     * rather than with two that look alike: there is no second set of names,
     * because there is no second sheet.
     *
     * Send is never pressed. The preview carries the exact string it would have
     * sent, which is the thing worth reading and costs somebody's agent nothing.
     */
    func testTheSheetIsTheOneBothBrowsersShare() throws {
        try XCTSkipUnless(try reachTheSheet(), Self.couldNotPick)

        let selector = app.staticTexts["inspect.selector"]
        XCTAssertFalse(selector.label.isEmpty, "an element with no selector is not an element")
        XCTAssertTrue(app.buttons["inspect.wider"].exists, "the correction is on this sheet too")
        XCTAssertTrue(app.buttons["inspect.narrower"].exists)

        let instruction = app.textFields["inspect.instruction"]
        XCTAssertTrue(instruction.waitForExistence(timeout: 8),
                      "there is somewhere to say what should change")
        instruction.tap()
        instruction.typeText("make this wider")

        let preview = app.staticTexts["inspect.preview"]
        if !preview.exists { app.staticTexts["What the agent will receive"].tap() }
        XCTAssertTrue(preview.waitForExistence(timeout: 10),
                      "the sheet shows the exact line before anything is sent")
        let line = preview.label
        capture("v9-04-sheet")

        // The same contract `composeSend` keeps on the other browser, because it
        // is the same function: one line, the instruction first, the context in
        // brackets after it. A newline in this string submits an agent's prompt
        // early — the first line would arrive as the whole instruction.
        XCTAssertFalse(line.contains("\n"), "the composed line must never contain a newline")
        XCTAssertTrue(line.hasPrefix("make this wider"), "the instruction goes first; line was: \(line)")
        XCTAssertTrue(line.contains("[browser: "), "the context is missing; line was: \(line)")
        XCTAssertTrue(line.contains("element `\(selector.label)`"),
                      "the line names the element the sheet is showing; line was: \(line)")

        app.buttons["inspect.done"].tap()
    }

    /**
     * Wider walks up, and it is greyed where there is nothing to walk up to.
     *
     * The correction, and on this browser it is a round trip: the same point,
     * asked again with `up + 1`. Both ends come off the answer — `maxUp` is how
     * many ancestors are left and `depth` is how far up this already is — so the
     * greying is exact rather than hopeful, and a press at the top of the document
     * is a press that never leaves the phone.
     *
     * That last part is not tidiness. The host checks `up` in its **parser**, and
     * a parse failure is answered by closing the socket — so a Wider that walked
     * past the ceiling would drop his terminals and his cast along with them.
     */
    func testWiderWalksUpAndIsDeadAtTheTopOfTheDocument() throws {
        try XCTSkipUnless(try reachTheSheet(), Self.couldNotPick)

        let selector = app.staticTexts["inspect.selector"]
        let tapped = selector.label
        let wider = app.buttons["inspect.wider"]
        let narrower = app.buttons["inspect.narrower"]

        // At the element the finger landed on there is nothing below it to come
        // back to, which is the first thing the sheet says about the chain.
        XCTAssertFalse(narrower.isEnabled,
                       "nothing has been walked up yet, so Narrower has nowhere to go back to")
        capture("v9-05-at-the-tap")

        try XCTSkipUnless(wider.isEnabled,
                          "this element is already the top of its document, so Wider is correctly "
                          + "dead — which is itself the assertion above.")
        wider.tap()

        let deadline = Date().addingTimeInterval(20)
        while selector.label == tapped && Date() < deadline { usleep(300_000) }
        XCTAssertNotEqual(selector.label, tapped,
                          "Wider should have selected the enclosing element")
        XCTAssertTrue(app.staticTexts["inspect.depth"].waitForExistence(timeout: 8),
                      "the sheet says how far up it has walked")
        capture("v9-06-wider")

        // And back again, which is the half that makes it a control rather than a
        // one-way trip.
        XCTAssertTrue(narrower.isEnabled, "one level up, so there is a way back down")
        narrower.tap()
        let back = Date().addingTimeInterval(20)
        while selector.label != tapped && Date() < back { usleep(300_000) }
        XCTAssertEqual(selector.label, tapped, "Narrower should come back to what was tapped")

        app.buttons["inspect.done"].tap()
    }

    /**
     * The Send-to picker offers the machine's sessions.
     *
     * **By set difference of labels, never by identifier.** An
     * `accessibilityIdentifier` on a `Button` inside a SwiftUI `Menu` does not
     * reach the presented row — measured twice in this target — so what a case has
     * to work with is the words. Session titles are somebody's own folder names
     * and nothing here can know them, so the rows are found the only way they can
     * be: everything that appeared, minus everything that was there before.
     *
     * A row is **tapped**, and that is safe: choosing where a line would go
     * changes nothing on the machine. Nothing is sent.
     */
    func testTheSendToPickerOffersTheMachinesSessions() throws {
        try XCTSkipUnless(try reachTheSheet(), Self.couldNotPick)

        let picker = app.buttons["inspect.target"]
        try XCTSkipUnless(picker.waitForExistence(timeout: 8) && picker.isEnabled,
                          "This machine has one session or none, so the target is a line rather "
                          + "than a picker — which is the sheet being honest about a choice that "
                          + "does not exist.")

        let before = labels()
        picker.tap()
        // The presentation animates; the rows are not queryable in the same frame
        // the tap lands in.
        _ = app.buttons.element(boundBy: 0).waitForExistence(timeout: 3)
        capture("v9-07-send-to")

        let rows = labels().subtracting(before)
        XCTAssertFalse(rows.isEmpty,
                       "this machine has more than one session, so the picker must list them — "
                       + "what appeared was \(labels().sorted())")
        for label in rows {
            XCTAssertTrue(app.buttons[label].firstMatch.isEnabled,
                          "“\(label)” is offered by the picker, so it has to be pressable")
        }

        if let first = rows.sorted().first { app.buttons[first].firstMatch.tap() }
        XCTAssertTrue(app.buttons["inspect.send"].waitForExistence(timeout: 8),
                      "choosing a session leaves the sheet up with somewhere to send to")
        // Deliberately not pressed. See the file header.
        app.buttons["inspect.done"].tap()
    }

    // MARK: - Getting there

    private static let couldNotPick =
        "This machine did not answer with an element — no window being cast, no browser.control, "
        + "or a host whose browser cannot run a hit test inside itself. The sentence it sent "
        + "instead is asserted by testATapWhileInspectingIsAnsweredRatherThanSwallowed."

    /// Open a window, turn inspecting on, tap the middle of the picture, and say
    /// whether the sheet came up. False is a real machine state and every caller
    /// skips on it rather than failing — the *sentence* case is asserted once, in
    /// its own test, rather than in four.
    private func reachTheSheet() throws -> Bool {
        try openTheFirstWindow()
        let inspect = app.buttons["browser.machine.window.inspect"]
        guard inspect.waitForExistence(timeout: 15), inspect.isEnabled else { return false }

        let stage = any("browser.machine.window.stage")
        guard stage.waitForExistence(timeout: 25) else { return false }

        inspect.tap()
        _ = any("browser.machine.window.inspectHint").waitForExistence(timeout: 8)
        Thread.sleep(forTimeInterval: 4)
        stage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        return app.staticTexts["inspect.selector"].waitForExistence(timeout: 25)
    }

    /// Push the first window's own screen, or skip. Nothing is opened on the
    /// machine to make one exist — this suite does not leave a window on
    /// somebody's real desktop behind every run.
    private func openTheFirstWindow() throws {
        if app.buttons["browser.machine.window.reload"].exists { return }
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'browser.machine.row.'")).firstMatch
        try XCTSkipUnless(row.waitForExistence(timeout: 20), Self.noWindows)
        row.tap()
        try XCTSkipUnless(app.buttons["browser.machine.window.reload"].waitForExistence(timeout: 15),
                          "the window's own screen never came up")
    }

    /**
     * Across every element type rather than as one.
     *
     * The identifiers this suite reaches for sit on SwiftUI containers — a row of
     * a glyph and some words, a stage whose child is a `UIViewRepresentable` — and
     * what XCUITest classifies those as is not a thing to have an opinion about.
     * `BrowserPageBarUITests` measured an `otherElements` query finding nothing
     * and skipping silently, which is the shape of a test that never runs.
     */
    private func any(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Every button label on screen right now, which is the before and after a
    /// menu is measured against.
    private func labels() -> Set<String> {
        Set(app.buttons.allElementsBoundByIndex.map(\.label))
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
