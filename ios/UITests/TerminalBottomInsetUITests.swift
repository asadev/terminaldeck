/**
 * The bottom of a session, photographed in both keyboard states.
 *
 * Asad: *"when we are inside the terminal page on iOS, at the bottom we cannot
 * see some stuff because of the mobile's round corners and the running-agents
 * things — whatever is at the most bottom is less visible. So leave a little
 * space when the keyboard is off."*
 *
 * ## What is actually along the bottom of that screen
 *
 * Three things, and only one of them belongs to this app:
 *
 *  - **The terminal's own last rows.** This is what he cannot read. An agent
 *    paints its status on the last row by convention — the spinner, the token
 *    count, the "esc to interrupt" line — so the rows worth watching are exactly
 *    the ones the indicator crosses.
 *  - **The key bar**, but only with the keyboard up, and it is above the unsafe
 *    region rather than in it.
 *  - **The home indicator and the display's corner radius**, which are the
 *    system's and are the thing doing the obscuring.
 *
 * The floating tab pill used to be a fourth and is gone — `DeckChrome` decides
 * that and `DeckTabs` states it at the `TabView`. Its absence is asserted here as
 * well as in `ReleaseShotsUITests`, because the fix for the inset and the fix for
 * the pill act on the same sixty points of screen and a regression in either one
 * looks identical in a screenshot.
 *
 * ## Why this pairs itself
 *
 * The same reason `KeyBarUITests` does: it asks the harness for a code over its
 * own control server rather than needing somebody to tap a prompt. It skips
 * rather than fails when nothing is listening, which is this target's standing
 * rule — a suite that goes red on a laptop with nothing running is a suite that
 * gets deleted in a week.
 *
 *     ios/Harness/run.sh host --approve-after 4000 &
 *     xcodebuild test -project ios/TerminalDeck.xcodeproj -scheme TerminalDeck \
 *       -destination 'platform=iOS Simulator,name=iPhone 17' \
 *       -only-testing:TerminalDeckUITests/TerminalBottomInsetUITests
 *
 * **Run it on a phone with a home indicator.** On an iPhone SE the bottom safe
 * area is zero, the correct behaviour and the broken behaviour are the same
 * layout, and every measurement below passes without proving anything. That is
 * not a reason to skip there — a zero inset is a real device configuration and
 * `TerminalContainerTests` covers it — it is a reason not to *believe* a green
 * run from one.
 *
 * ## And why the numbers are one-sided
 *
 * The exact inset is pinned by `TerminalContainerTests`, on a real layout with a
 * stated safe area, where it can be checked to half a point. What a screen test
 * adds is the thing a unit test cannot see: that the inset on the real device is
 * the *hardware's* and not the tab pill's. Those two differ by about forty
 * points, so telling them apart is all the precision needed here.
 */

import XCTest

final class TerminalBottomInsetUITests: XCTestCase {

    private var app: XCUIApplication!
    private static var reachable: Bool?

    /// Where `ios/Harness/run.sh host` puts its control server: the relay's port
    /// plus one.
    private static let control = URL(string: "http://127.0.0.1:8788")!

    private static let notRunning =
        "No harness. Start ios/Harness/run.sh host --approve-after 4000 and run again."

    /**
     * Roughly how much the floating tab pill takes off the bottom on iOS 26:
     * about fifty points of pill sitting about twenty above the safe-area edge.
     *
     * Written down as the thing being *excluded*. Every phone's home indicator
     * inset is 34, so a gap anywhere near this number means the pill's band has
     * come back — which is the regression `DeckChrome` exists to prevent and the
     * one that is invisible in a screenshot, because a reserved band with nothing
     * drawn in it just looks like a slightly short terminal.
     */
    private static let pillBand: CGFloat = 60

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(Self.reachable == false, Self.notRunning)

        app = XCUIApplication()
        app.launch()

        if app.textFields["pairing.field"].waitForExistence(timeout: 5) {
            let code = try pairingCode()
            let field = app.textFields["pairing.field"]
            field.tap()
            field.typeText(code)
            if app.buttons["pairing.submit"].exists { app.buttons["pairing.submit"].tap() }
        }

        let connected = waitForConnected(timeout: Self.reachable == nil ? 45 : 15)
        Self.reachable = connected
        try XCTSkipUnless(connected, Self.notRunning)
    }

    // MARK: - Keyboard down

    /**
     * The frame he complained about: sixty lines of output, keyboard down.
     *
     * Two claims, and they are deliberately separate because the pass this fixes
     * ran them together. **The pill is absent** — said as the pill's absence,
     * which is a question about the accessibility tree and has one answer. And
     * **the terminal stops short of the physical bottom**, which is the inset
     * being respected.
     *
     * The old test made the second claim stand in for the first, as "the gap is
     * under forty points". That is true of a screen with no pill *and* true of a
     * screen with a correct 34-point inset *and* true of a terminal drawn flat
     * onto the home indicator, so it could not tell the fix from the bug — and
     * when the inset came back the assertion that was supposed to protect the
     * pill's absence had nothing to say about it.
     */
    func testTheLastLineIsClearOfTheHomeIndicatorWithTheKeyboardDown() throws {
        try openSession()
        try fillTheScreen()
        putTheKeyboardDown()

        XCTAssertFalse(app.tabBars.firstMatch.exists,
                       "the tab pill should be gone inside a session — DeckChrome's rule")

        let window = app.windows.element(boundBy: 0).frame
        let terminal = app.descendants(matching: .any)["terminal.view"].frame
        let gap = window.maxY - terminal.maxY
        report("keyboard down — window \(window)  terminal \(terminal)  gap \(gap)")
        // Photographed before anything is asserted. The frame is the evidence
        // whether the run is green or red, and a screenshot taken after a failed
        // assertion is a screenshot that does not exist — `continueAfterFailure`
        // is false in this target, which is what makes a failure name its stop.
        save("bottom-01-keyboard-down")

        XCTAssertGreaterThan(gap, 0,
                             "the terminal is drawn to the physical bottom edge — its last line "
                             + "is under the home indicator, which is the complaint")
        XCTAssertLessThan(gap, Self.pillBand,
                          "the terminal stops \(gap) points short, which is the tab pill's band "
                          + "rather than the home indicator's inset — something is reserving "
                          + "space for a bar this screen does not have")
    }

    // MARK: - Keyboard up

    /**
     * With the keyboard up the terminal runs right down to the key bar.
     *
     * The inset belongs to the keyboard-down state and to nothing else: the
     * keyboard covers the indicator anyway, so holding an inset on top of it
     * would cost a line of output for as long as somebody is typing — on the
     * screen where the space is scarcest, because the keyboard has already taken
     * half of it.
     *
     * Measured against the key bar rather than against the window, because the
     * key bar is what the terminal's bottom edge has to meet. `keys.dismiss` sits
     * four points below the top of the bar; the tolerance below is that plus room
     * for the layout to round.
     */
    func testTheKeyboardUpWastesNoBandAboveTheKeyBar() throws {
        try openSession()
        raiseTheKeyboard()

        let terminal = app.descendants(matching: .any)["terminal.view"].frame
        let dismiss = app.buttons["keys.dismiss"].frame
        let gap = dismiss.minY - terminal.maxY
        report("keyboard up — terminal \(terminal)  keys.dismiss \(dismiss)  gap \(gap)")
        save("bottom-02-keyboard-up")

        XCTAssertGreaterThanOrEqual(gap, -1,
                                    "the key bar is drawn over the last row of the terminal")
        XCTAssertLessThan(gap, 12,
                          "there are \(gap) points of nothing between the terminal and the key "
                          + "bar — the bottom inset is being held while the keyboard is up, and "
                          + "the keyboard already covers what it is avoiding")
    }

    // MARK: - Arriving

    private func openSession() throws {
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session.'"))
        if rows.count == 0 {
            let plus = app.buttons["sessions.new"]
            XCTAssertTrue(plus.waitForExistence(timeout: 15), "no sessions and no way to start one")
            plus.tap()
            let menuItem = app.buttons["sessions.newDefault"]
            if menuItem.waitForExistence(timeout: 3) { menuItem.tap() }
        }
        let first = rows.element(boundBy: 0)
        if first.waitForExistence(timeout: 25), !app.buttons["terminal.actions"].exists {
            first.tap()
        }
        XCTAssertTrue(app.buttons["terminal.actions"].waitForExistence(timeout: 20),
                      "the terminal screen should be open")
        XCTAssertTrue(app.descendants(matching: .any)["terminal.view"].waitForExistence(timeout: 20))
        sleep(2)
    }

    /**
     * Enough output that "the last line" is a claim about something visible.
     *
     * The last thing printed is a rule and a status line in the shape an agent
     * draws one, because that is the content he was actually failing to read —
     * a coding agent's status sits on the bottom row and is the reason anybody
     * opens a session on a phone rather than reading it later.
     */
    private func fillTheScreen() throws {
        try type("for i in $(seq 1 60); do echo \"line $i · terminal deck\"; done\n")
        sleep(1)
        try type("printf '%s\\n' '────────────────────────────' "
                 + "'⏵ running · 42.1k tokens · esc to interrupt'\n")
        sleep(2)
    }

    /// Put text into the session, raising the keyboard if it is down.
    private func type(_ text: String) throws {
        raiseTheKeyboard()
        app.typeText(text)
    }

    /**
     * Raise the keyboard, and try twice.
     *
     * The toolbar button is a *toggle* — `TerminalScreen` blurs on it when the
     * terminal already has focus — so a tap that arrives while the screen is
     * still settling can be swallowed, and a second tap on the same button would
     * then be the one that puts it back down. Waiting for the key bar between the
     * two attempts is what keeps this from oscillating: the second tap only
     * happens if the first produced nothing at all. Measured on this simulator,
     * one run in three needed it.
     */
    private func raiseTheKeyboard() {
        let keyboard = app.buttons["terminal.keyboard"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 20), "the terminal toolbar should be up")
        for attempt in 1 ... 2 {
            if app.buttons["keys.dismiss"].exists { break }
            keyboard.tap()
            // The QuickPath tutorial is put up by the system keyboard the first
            // time it appears on a fresh simulator and it sits over the bar.
            // Nothing to do with this app; dismissed the way a person would.
            let continueButton = app.buttons["Continue"]
            if continueButton.waitForExistence(timeout: 3) { continueButton.tap() }
            if app.buttons["keys.dismiss"].waitForExistence(timeout: 10) { break }
            XCTAssertLessThan(attempt, 2, "the key bar never came up with the keyboard")
        }
        sleep(1)
    }

    private func putTheKeyboardDown() {
        if app.buttons["keys.dismiss"].exists { app.buttons["keys.dismiss"].tap() }
        XCTAssertFalse(app.buttons["keys.dismiss"].waitForExistence(timeout: 3),
                       "the key bar should have gone with the keyboard")
        sleep(2)
    }

    /// The six-digit pairing code, straight from the harness — or a skip, when
    /// there is no harness to ask.
    private func pairingCode() throws -> String {
        guard let data = try? Data(contentsOf: Self.control.appendingPathComponent("pair")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? String else {
            Self.reachable = false
            throw XCTSkip(Self.notRunning)
        }
        return code
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

    // MARK: - The frames

    /**
     * The measurement, in the run log as well as in the result bundle.
     *
     * Printed rather than only attached, because the number is the point of this
     * file and a green run that keeps its evidence inside an `.xcresult` is a
     * green run nobody reads. `xcresulttool export attachments` hands back the
     * screenshots and drops plain-text ones, which is how this was found.
     */
    private func report(_ measurement: String) {
        add(XCTAttachment(string: measurement))
        print("[bottom-inset] \(measurement)")
    }

    /// A frame, attached to the result bundle *and* written where a person can
    /// open it — `TD_SHOTS` when the run names a directory on the Mac, and the
    /// runner's own Documents otherwise. These frames are the deliverable: the
    /// whole point of this file is that the bottom of a screen has to be looked
    /// at, not reasoned about.
    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        if let shots = ProcessInfo.processInfo.environment["TD_SHOTS"], !shots.isEmpty {
            try? FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png"))
        }
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        try? shot.pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
