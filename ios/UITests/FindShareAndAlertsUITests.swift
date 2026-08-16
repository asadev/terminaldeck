/**
 * The three things this phone could not do, on a real screen against a real
 * shell: **find a line in the scrollback**, **change the text size**, and **be
 * told when a machine needs you**.
 *
 * The unit tests prove the rules — that typing searches backwards, that a
 * transition into `waiting` is an alert and starting work is not, that a smaller
 * font is more columns. What they cannot prove is the half these features live
 * or die on: whether the find bar comes up with a keyboard under it, whether it
 * covers the output instead of pushing it, whether the counter is legible, and
 * whether the alerts screen says what it can actually promise. Those are facts
 * about a running app.
 *
 * ## Running it
 *
 *     ios/Harness/run.sh host --approve-after 3000 &
 *     xcodebuild test -project ios/TerminalDeck.xcodeproj -scheme TerminalDeck \
 *       -destination 'platform=iOS Simulator,name=iPhone 17' \
 *       -only-testing:TerminalDeckUITests/FindShareAndAlertsUITests
 *
 * It pairs itself from the harness's control server, the way `KeyBarUITests`
 * does, and skips rather than fails when nothing is listening — a test that goes
 * red because a server is not running on somebody's laptop is a test that gets
 * deleted in a week.
 *
 * ## It never taps "Turn on alerts"
 *
 * Deliberately. That button raises the **system** permission prompt, which can
 * be answered exactly once per install, and a test that spends it would leave
 * every later run looking at a screen no user would see. The screen is
 * photographed in the state a person meets it in, and the posting path is proved
 * in `SessionAlertsTests` with a recorder instead of `UNUserNotificationCenter`.
 */

import XCTest

final class FindShareAndAlertsUITests: XCTestCase {

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
        dismissLeftoverOpenPrompt()

        if app.textFields["pairing.field"].waitForExistence(timeout: 5) {
            let code = try pairingCode()
            let field = app.textFields["pairing.field"]
            field.tap()
            /*
             * The QuickPath tutorial, dismissed before the first character.
             *
             * On a simulator that has just been erased, the very first time the
             * system keyboard appears it puts a full-screen "Swipe to type"
             * card over everything with a Continue button. `typeText` then
             * types into that card: the pairing field stays empty, Pair does
             * nothing, and every case in this file skips with a message about a
             * harness that is in fact running. Measured, on this file's first
             * run against a fresh device.
             */
            let continueButton = app.buttons["Continue"]
            if continueButton.waitForExistence(timeout: 3) { continueButton.tap() }
            field.typeText(code)
            app.buttons["pairing.submit"].tap()
        }

        let connected = waitForConnected(timeout: Self.reachable == nil ? 45 : 15)
        Self.reachable = connected
        try XCTSkipUnless(connected, Self.notRunning)
    }

    private static let notRunning =
        "No harness. Start ios/Harness/run.sh host --approve-after 3000 and run again."

    // MARK: - Find

    /**
     * Type a term and land on the newest match, with the output still visible
     * behind the bar.
     *
     * The frame check is the one that matters and it is why the bar floats: a
     * find bar that took rows off the session would be a `resize` on the wire,
     * and the program on the far end would repaint in the middle of somebody
     * reading it.
     */
    func testFindingALineInTheScrollback() throws {
        try openSession()
        raiseTheKeyboard()
        app.typeText("echo find-me-alpha; echo find-me-beta\n")
        sleep(2)
        app.buttons["keys.dismiss"].tap()
        sleep(1)

        let terminal = app.descendants(matching: .any).matching(identifier: "terminal.view").firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))

        openFind()
        save("find-01-open")

        let field = app.textFields["find.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the find bar should be up")
        // Focused already: the bar exists because somebody chose Find, and
        // making them tap the field they just asked for is a tap for nothing.
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "the find field should already have the keyboard")

        field.typeText("find-me")
        sleep(1)

        let counter = app.descendants(matching: .any).matching(identifier: "find.count").firstMatch
        XCTAssertTrue(counter.waitForExistence(timeout: 5), "the match counter should be on the bar")
        XCTAssertTrue(counter.label.contains(" of "), "counter said: \(counter.label)")
        save("find-02-matches")

        /*
         * The bar is **over** the terminal, not above it.
         *
         * Measured as an overlap rather than as "the terminal did not move",
         * because the terminal does move: raising a keyboard for the find field
         * shrinks it exactly as raising one to type does, and that is correct —
         * rows hidden behind a keyboard would be rows nobody can read. What must
         * not happen is the *bar* taking rows of its own, and the shape of that
         * is unmistakable: an inset bar would push the terminal's top edge below
         * the bar's bottom edge.
         */
        let bar = field.frame
        XCTAssertLessThan(terminal.frame.minY, bar.minY,
                          "the find bar pushed the terminal down instead of floating over it")
        XCTAssertTrue(terminal.frame.intersects(bar),
                      "the bar and the terminal should overlap — that is what floating means")
    }

    /// A term that is not there says so, rather than leaving two arrows that do
    /// nothing and no explanation.
    func testATermThatIsNotThereSaysSo() throws {
        try openSession()
        openFind()

        let field = app.textFields["find.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("zzz-not-in-this-buffer")
        sleep(1)

        let counter = app.descendants(matching: .any).matching(identifier: "find.count").firstMatch
        XCTAssertTrue(counter.waitForExistence(timeout: 5))
        XCTAssertEqual(counter.label, "No matches")
        XCTAssertFalse(app.buttons["find.earlier"].isEnabled,
                       "an arrow that cannot move must not look pressable")
        save("find-03-no-matches")

        app.buttons["find.done"].tap()
        sleep(1)
        XCTAssertFalse(app.textFields["find.field"].exists, "Done should put the bar away")
    }

    // MARK: - Text size

    /**
     * The menu says what size the terminal is at, and a step really changes it.
     *
     * ## Why the direction is worked out rather than fixed
     *
     * The size is a **persisted** setting, so this test is not idempotent by
     * nature: a version that always pressed Smaller walked the size down one
     * point per run, reached the nine-point floor on the fourth, and then
     * pressed a control that is correctly disabled there — reporting a failure
     * for a size change that had not happened. The bug was in the test, and the
     * shape of it is worth keeping in mind: any test that presses a stepper has
     * to know where the stepper already is.
     *
     * ## Why there is no toast assertion here
     *
     * There is no toast on this path, and that is deliberate rather than a gap.
     * A `Button` inside a menu `Section` runs its action — the size really
     * changes, and the header below proves it — but any **view-state** change
     * the same action makes does not reach the screen on iOS 26.5. That was
     * measured twice, first with a `@State` and then with an `@Observable`
     * object, and once with the action doing nothing but raise the message.
     *
     * It costs nothing here, which is why the fight was abandoned rather than
     * won: the confirmation for a size change *is the size changing*, in front
     * of you, on the whole screen. The toast earns its place on the pinch —
     * where the number and the end of the range are worth saying — and the case
     * below is the one that proves it appears.
     */
    func testTheTextSizeIsInTheMenuAndSaysWhatItIs() throws {
        try openSession()

        app.buttons["terminal.actions"].tap()
        // The size is in the item's own label — "Bigger text — 12 pt" — because
        // a menu can say it there without offering a row that does nothing.
        let bigger = app.buttons["terminal.textLarger"]
        XCTAssertTrue(bigger.waitForExistence(timeout: 5), "the menu should offer the text size")
        XCTAssertTrue(bigger.label.contains("pt"), "it should say the size: \(bigger.label)")
        save("size-01-menu")

        let before = try points(in: bigger.label)
        // The bounds are `TextSize.minimum` and `.maximum` in the app; a UI test
        // target cannot import them, so they are written out and named here.
        let step = before > 9 ? "terminal.textSmaller" : "terminal.textLarger"
        let back = before > 9 ? "terminal.textLarger" : "terminal.textSmaller"

        let stepButton = app.buttons[step]
        XCTAssertTrue(stepButton.isEnabled, "\(step) should be available at \(before) pt")
        // Tapping an item closes the menu; every step below opens it again.
        stepButton.tap()
        /*
         * A picture rather than an assertion, and the reason is worth writing
         * down because it cost hours.
         *
         * The message this raises — "10 pt" — **is on screen**; the screenshot
         * below shows it every run. `XCUIApplication` cannot see it: for a
         * short while after a menu is dismissed, an element that appears in
         * that same turn is missing from the accessibility tree the runner
         * queries, while a screenshot taken at the same instant has it. That
         * looked exactly like a state update being swallowed, and two tidy
         * refactors were done and undone chasing it. The toast **is** asserted
         * in the pinch case below, where no menu was involved.
         */
        usleep(600_000)
        save("size-02-stepped-and-said")
        sleep(1)


        // It stuck: the menu now says the size it is drawing at, which is the
        // difference between a setting and a message.
        app.buttons["terminal.actions"].tap()
        XCTAssertTrue(bigger.waitForExistence(timeout: 5))
        let after = try points(in: bigger.label)
        XCTAssertNotEqual(after, before, "the menu should report the size it is now drawing at")

        // Put it back, from the menu that is already open.
        app.buttons[back].tap()
        sleep(1)
    }

    /**
     * Pinching the terminal changes the size, and says what it changed to.
     *
     * The gesture is the fast path and the menu is the discoverable one; this is
     * the gesture, driven as a finger drives it. The toast matters here in a way
     * it does not in the menu: a pinch that has reached the end of the range
     * looks exactly like a pinch the app ignored, and the number is the only
     * thing that tells the two apart.
     *
     * ## Both directions, and no menu at all
     *
     * The size is persisted, so this case inherits whatever the last run left —
     * possibly an end of the range, where a pinch that way correctly does
     * nothing. An earlier version tried to make room by stepping the size down
     * through the menu first and turned into a mess of menu bookkeeping: a
     * disabled item swallowed a tap, the menu stayed open, and the next tap
     * landed on Find. Pinching **both ways** needs none of that. A size cannot
     * be at the top *and* the bottom of the range, so at least one of the two
     * has somewhere to go, and one toast is the proof.
     */
    func testPinchingTheTerminalChangesTheTextSize() throws {
        try openSession()

        let terminal = app.descendants(matching: .any).matching(identifier: "terminal.view").firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        let toast = app.descendants(matching: .any).matching(identifier: "terminal.toast").firstMatch

        terminal.pinch(withScale: 0.6, velocity: -1.5)
        sleep(1)
        let afterPinchIn = toast.exists ? toast.label : ""
        if !afterPinchIn.isEmpty { save("size-03-pinched-in") }
        // Long enough for the first message to have gone, so a toast seen after
        // the second pinch is the second pinch's.
        sleep(3)

        terminal.pinch(withScale: 1.6, velocity: 1.5)
        sleep(1)
        let afterPinchOut = toast.exists ? toast.label : ""
        if !afterPinchOut.isEmpty { save("size-04-pinched-out") }

        let said = [afterPinchIn, afterPinchOut].filter { !$0.isEmpty }
        XCTAssertFalse(said.isEmpty,
                       "neither pinch said anything — a gesture with no confirmation is "
                       + "indistinguishable from one the app ignored")
        for message in said {
            XCTAssertTrue(message.contains("pt"), "a size message should carry the size: \(message)")
        }
    }

    /// "Bigger text — 11 pt" → 11.
    private func points(in label: String) throws -> Int {
        let digits = label.split(separator: " ").compactMap { Int($0) }
        return try XCTUnwrap(digits.first, "no size in the menu label: \(label)")
    }

    // MARK: - Share

    /// Share is in the menu and reaches the system sheet with a file behind it.
    /// The sheet itself belongs to iOS; what is being checked is that this app
    /// wrote something and handed it over rather than presenting an empty one.
    func testSharingTheOutputReachesTheSystemSheet() throws {
        try openSession()

        app.buttons["terminal.actions"].tap()
        let share = app.buttons["terminal.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        share.tap()
        sleep(3)

        // The share sheet names what is being shared. A `.txt` named after the
        // session is what `ShareOutput` writes.
        let sheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "the system share sheet should be up")
        save("share-01-sheet")

        // Out again, without sending anything anywhere.
        if app.buttons["Close"].exists {
            app.buttons["Close"].tap()
        } else {
            app.swipeDown(velocity: .fast)
        }
    }

    // MARK: - Alerts

    /**
     * The alerts screen, in the state a person meets it in.
     *
     * The paragraph at the bottom is the point of the screen and the reason it
     * is not two switches in a menu: a phone that has been asleep for an hour
     * cannot be woken by a machine, and somebody deciding whether to rely on
     * this deserves to be told before they do rather than after a two-hour wait
     * for a buzz that was never coming.
     */
    func testTheAlertsScreenSaysWhatItCanAndCannotDo() throws {
        backToTheList()
        XCTAssertTrue(app.openAlerts(),
                      "Settings should offer Alerts, and the alerts screen should open")
        // Never tapped — see the header. Its presence is the assertion.
        XCTAssertTrue(app.buttons["alerts.turnOn"].exists || app.buttons["alerts.openSettings"].exists
                      || app.switches["alerts.needsYou"].exists,
                      "the screen must offer a real next step in every permission state")
        XCTAssertTrue(app.staticTexts["alerts.limits"].exists
                      || app.descendants(matching: .any)["alerts.limits"].exists,
                      "the honest paragraph must be on the screen")
        save("alerts-01-screen")

        app.buttons["alerts.done"].tap()
        // Closing the sheet leaves the Settings tab showing, so this screenshot
        // is of the sessions only if it is asked for.
        app.openSessionsTab()
        sleep(1)
        save("alerts-02-list")
    }

    /**
     * The whole chain, once: a session ends on the machine, and this phone puts
     * a notification on the screen.
     *
     * ## Why it is gated behind an environment variable
     *
     * It answers the **system** permission prompt, and that prompt can be
     * answered exactly once per install. A case that spent it on every run would
     * leave every later run — including the one above, which photographs the
     * alerts screen in the state a person meets it in — looking at a screen no
     * new user would ever see. So it is opt-in:
     *
     *     TEST_RUNNER_TD_SPEND_NOTIFICATION_PERMISSION=1 xcodebuild test …
     *
     * (The `TEST_RUNNER_` prefix is not decoration: without it the assignment is
     * parsed as a build setting and never reaches the runner. See `project.yml`.)
     *
     * ## Why the session that ends is not the one on screen
     *
     * Because a session being watched deliberately does **not** interrupt — see
     * `DeckModel.alertsChanged`. So this starts something that will end after we
     * have looked away, and waits on the list. That is exactly the shape of the
     * thing the feature is for: you set something going and stop watching.
     */
    func testASessionEndingRaisesARealNotification() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TD_SPEND_NOTIFICATION_PERMISSION"] == "1",
                          "opt-in: this spends the one system permission prompt this install has")

        // 1. Ask for permission, and answer it.
        backToTheList()
        XCTAssertTrue(app.openAlerts(), "Settings should offer Alerts")
        let turnOn = app.buttons["alerts.turnOn"]
        XCTAssertTrue(turnOn.waitForExistence(timeout: 10),
                      "permission has already been answered on this install — reinstall to run this")
        turnOn.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10), "the system prompt should have appeared")
        allow.tap()
        sleep(2)
        save("alerts-03-permitted")
        app.buttons["alerts.done"].tap()
        app.openSessionsTab()

        // 2. Set something going that will finish after we have looked away.
        try openSession()
        raiseTheKeyboard()
        app.typeText("sleep 6; exit\n")
        app.buttons["keys.dismiss"].tap()
        sleep(1)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["sessions.more"].waitForExistence(timeout: 10),
                      "should be back on the session list")

        // 3. The notification, drawn by the system over this app.
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'Finished on' OR label CONTAINS[c] "
                                  + "'Ended on' OR label CONTAINS[c] 'Stopped on'"))
            .firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 30),
                      "no notification arrived when the session ended")
        save("alerts-04-notification")
    }

    // MARK: - Helpers

    /**
     * The "Open in …?" alert `simctl openurl` leaves behind.
     *
     * The documented way to pair a simulator by hand is `xcrun simctl openurl`,
     * which puts a **SpringBoard** confirmation over the app. Unanswered, it
     * survives the app being killed and relaunched — and because it belongs to
     * SpringBoard rather than to this app, every `typeText` in this file goes
     * into a void behind it. That looked exactly like a harness that was not
     * running: the pairing field stayed empty, Pair did nothing, and all five
     * cases skipped with a message about a server that was in fact listening.
     *
     * So it is answered here rather than diagnosed again in six months.
     */
    private func dismissLeftoverOpenPrompt() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 2) {
            open.tap()
            sleep(2)
        }
    }

    private func pairingCode() throws -> String {
        guard let data = try? Data(contentsOf: Self.control.appendingPathComponent("pair")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? String else {
            Self.reachable = false
            throw XCTSkip(Self.notRunning)
        }
        return code
    }

    private func openFind() {
        let actions = app.buttons["terminal.actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 15), "the terminal screen should be open")
        actions.tap()
        let find = app.buttons["terminal.find"]
        XCTAssertTrue(find.waitForExistence(timeout: 5), "Find should be the first item in the menu")
        find.tap()
        sleep(1)
    }

    /**
     * Stand on the session list, whatever is on top of it.
     *
     * The tab bar is not reachable from a pushed terminal — a `NavigationStack`
     * inside a tab hides it — so anything that wants Settings has to come back
     * to the root of the Sessions tab first. `sessions.more` is the sentinel for
     * "the list is showing" and is still there, holding Refresh and Reconnect.
     */
    private func backToTheList() {
        let more = app.buttons["sessions.more"]
        if !more.waitForExistence(timeout: 10) {
            // A terminal is open on top of the list; back out to it.
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(more.waitForExistence(timeout: 10), "the session list should be showing")
    }

    private func raiseTheKeyboard() {
        let keyboard = app.buttons["terminal.keyboard"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 20), "the terminal toolbar should be up")
        if !app.buttons["keys.dismiss"].exists { keyboard.tap() }
        // The QuickPath tutorial the system keyboard puts up on a fresh
        // simulator sits over the bar. Nothing to do with this app.
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
    /// open it — the same arrangement the rest of this target uses.
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
