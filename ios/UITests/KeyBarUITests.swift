/**
 * The key bar and the key grid, on a real screen, against a real shell.
 *
 * The unit tests measure the bar in isolation and prove the arithmetic. What
 * they cannot prove is the thing the redesign is actually about: that on the
 * **narrowest phone this app supports** every key is reachable without a swipe,
 * that dismiss is one tap from anywhere, and that opening the grid does not move
 * the terminal above it. All three are facts about a running app on a specific
 * screen, and the first two were false in the build this replaces.
 *
 * ## Run it on a small phone, not on a Pro Max
 *
 *     xcrun simctl create "TD SE3" \
 *       com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation \
 *       com.apple.CoreSimulator.SimRuntime.iOS-26-5
 *     ios/Harness/run.sh host --approve-after 4000 &
 *     xcodebuild test -project ios/TerminalDeck.xcodeproj -scheme TerminalDeck \
 *       -destination 'platform=iOS Simulator,name=TD SE3' \
 *       -only-testing:TerminalDeckUITests/KeyBarUITests
 *
 * A 375-point screen is the whole point. On a 430-point one the old scrolling
 * bar looked nearly fine, which is how it shipped.
 *
 * ## Why this pairs itself
 *
 * Every other UI test in this target needs somebody to run `simctl openurl` and
 * answer a system prompt first. This one asks the harness for a pairing code
 * over its own control server — the Simulator shares the host's loopback, which
 * is the same reason the app can reach `ws://127.0.0.1:8787` — and types it in.
 * No environment injection, which does not reach the runner on this toolchain,
 * and no prompt to tap.
 *
 * It skips rather than fails when nothing is listening, for the reason the rest
 * of this target does: a test that goes red because a server is not running on
 * somebody's laptop is a test that gets deleted in a week.
 *
 * ## If every case skips, the phone is paired to a machine that has gone
 *
 * **A simulator's Keychain survives uninstalling the app.** So a phone that was
 * paired with yesterday's harness comes back paired to a host id nothing is
 * answering for: the app opens on the session list rather than the pairing
 * screen, this file never gets a chance to type a code, and all three cases skip
 * with a message about a harness that is in fact running. Reinstalling does not
 * clear it. This does:
 *
 *     xcrun simctl keychain <device> reset
 */

import XCTest

final class KeyBarUITests: XCTestCase {

    private var app: XCUIApplication!
    private static var reachable: Bool?

    /// Where `ios/Harness/run.sh host` puts its control server: the relay's port
    /// plus one.
    private static let control = URL(string: "http://127.0.0.1:8788")!

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(Self.reachable == false, Self.notRunning)

        app = XCUIApplication()
        app.launch()

        if app.reachPairingField(timeout: 5) {
            let code = try pairingCode()
            let field = app.textFields["pairing.field"]
            field.tap()
            field.typeText(code)
            app.buttons["pairing.submit"].tap()
        }

        let connected = waitForConnected(timeout: Self.reachable == nil ? 45 : 15)
        Self.reachable = connected
        try XCTSkipUnless(connected, Self.notRunning)
    }

    private static let notRunning =
        "No harness. Start ios/Harness/run.sh host --approve-after 4000 and run again."

    /// The six-digit pairing code, straight from the harness — or a skip, when
    /// there is no harness to ask. `/pair` answered with a `terminaldeck://pair?…`
    /// URI until the link was removed from the product; it answers with `code`
    /// now, and the code is typed rather than opened.
    private func pairingCode() throws -> String {
        guard let data = try? Data(contentsOf: Self.control.appendingPathComponent("pair")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? String else {
            Self.reachable = false
            throw XCTSkip(Self.notRunning)
        }
        return code
    }

    // MARK: - The bar

    /**
     * Every key on the bar is on screen at once, and dismiss is one of them.
     *
     * This is the bug, stated as a test. The bar this replaces held twenty-six
     * buttons in a horizontal scroll view and put dismiss **last**, so putting
     * the keyboard away meant scrolling past every symbol, every signal, home,
     * end, pgup, pgdn, copy and paste first. `isHittable` is the assertion that
     * matters: a button that exists but is scrolled off the edge is exactly what
     * the old bar had, and it is not hittable.
     */
    func testEveryKeyOnTheBarIsHittableWithoutScrolling() throws {
        try openSession()
        raiseTheKeyboard()

        for key in ["esc", "tab", "ctrl"] {
            let button = app.buttons[key]
            XCTAssertTrue(button.waitForExistence(timeout: 10), "missing key: \(key)")
            XCTAssertTrue(button.isHittable, "\(key) is on the bar but cannot be reached")
        }
        for identifier in ["keys.more", "keys.dismiss"] {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.exists, "missing pinned button: \(identifier)")
            XCTAssertTrue(button.isHittable, "\(identifier) must never need scrolling to")
        }

        // And inside the screen, measured. `isHittable` is about the hit test;
        // this is about the frame, and the two disagree at exactly the moment a
        // button is half off the edge.
        let screen = app.windows.firstMatch.frame
        for identifier in ["keys.more", "keys.dismiss"] {
            let frame = app.buttons[identifier].frame
            XCTAssertLessThanOrEqual(frame.maxX, screen.maxX + 0.5,
                                     "\(identifier) runs off the right-hand edge")
        }
        save("keybar-01-fixed-bar")
    }

    // MARK: - The grid

    /**
     * The trick the whole design turns on: the grid stands exactly where the
     * keyboard was, so the terminal does not move.
     *
     * Measured rather than looked at. The terminal's frame is read before and
     * after the swap, and if the two differ the person reading their output has
     * just had it jump under them for pressing a key button — which is what any
     * panel, sheet or overlay would have done.
     */
    func testTheGridStandsWhereTheKeyboardWasAndTheTerminalDoesNotMove() throws {
        try openSession()
        raiseTheKeyboard()

        let terminal = app.descendants(matching: .any).matching(identifier: "terminal.view").firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        let before = terminal.frame

        app.buttons["keys.more"].tap()
        sleep(1)
        save("keybar-02-grid-open")

        // The groups are labelled, which is the other half of the change: the
        // old row was a wall of identical squares in one line.
        for group in ["EDIT", "SIGNALS", "NAVIGATION"] {
            XCTAssertTrue(app.staticTexts[group].exists, "the grid should be labelled: \(group)")
        }
        for key in ["copy", "paste", "^C", "home", "|", "alt"] {
            XCTAssertTrue(app.buttons[key].exists, "the grid should carry \(key)")
        }

        let after = terminal.frame
        XCTAssertEqual(after.height, before.height, accuracy: 1,
                       "the terminal moved when the grid opened — the grid must be the same "
                       + "height as the keyboard it replaced")

        // And back. The same button closes it, and the keyboard returns to where
        // it was rather than leaving a grid standing over nothing.
        app.buttons["keys.more"].tap()
        sleep(1)
        XCTAssertFalse(app.buttons["^C"].exists, "the grid should be gone")
        XCTAssertTrue(app.buttons["esc"].isHittable, "the bar stays through both states")
        save("keybar-03-grid-closed")
    }

    /// Dismiss puts the keyboard away from either state, and it is always in the
    /// same place. The old bar's dismiss was the twenty-sixth item in a scroll
    /// view, which is the single defect this redesign started from.
    func testDismissIsAlwaysInTheSamePlace() throws {
        try openSession()
        raiseTheKeyboard()

        app.buttons["keys.more"].tap()
        sleep(1)
        XCTAssertTrue(app.buttons["keys.dismiss"].isHittable,
                      "dismiss must be reachable while the grid is open too")
        app.buttons["keys.dismiss"].tap()
        sleep(1)

        XCTAssertFalse(app.keyboards.firstMatch.exists, "the keyboard should be down")
        XCTAssertFalse(app.buttons["esc"].exists, "and the bar with it")
        save("keybar-04-dismissed")
    }

    // MARK: - Helpers

    /**
     * Raise the keyboard the only way there is now: by tapping the terminal.
     *
     * There was a keyboard button in the navigation bar and it was deleted at his
     * word — *"we don't need keyboard button also, even in terminal pages, even
     * on copilot pages, because when we click inside the chat keyboard comes
     * anyway."* The tap was always the primary way in and the button was the
     * second one: SwiftTerm's own tap recogniser is what makes the view first
     * responder, and `TerminalGestures` installs its own alongside that one
     * rather than in place of it, which is why this still works with the button
     * gone.
     *
     * A tap is not a toggle, which makes this simpler than it was: the guard is
     * about not raising a keyboard that is already up, not about not putting one
     * back down.
     */
    private func raiseTheKeyboard() {
        let terminal = app.descendants(matching: .any).matching(identifier: "terminal.view").firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 20), "the terminal screen should be up")
        if !app.buttons["keys.dismiss"].exists { terminal.tap() }
        // The QuickPath tutorial is put up by the system keyboard the first time
        // it appears on a fresh simulator, and it sits over the bar. Nothing to
        // do with this app; dismissed the way a person would.
        let continueButton = app.buttons["Continue"]
        if continueButton.waitForExistence(timeout: 3) { continueButton.tap() }
        XCTAssertTrue(app.buttons["keys.dismiss"].waitForExistence(timeout: 10),
                      "the key bar should come up with the keyboard")
    }

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

    /// A frame, attached to the result bundle and written where a person can
    /// open it. See `ClipboardAndTransferUITests.save`: the attachment is the
    /// tidy answer and the file is the one somebody actually looks at.
    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? shot.pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
