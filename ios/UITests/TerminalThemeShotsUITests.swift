/**
 * The colour picker, on a phone, with a real session behind it.
 *
 * Asad asked for the terminal's colour to be choosable everywhere — *"phone
 * also, for Windows, for MacBook, all of them"* — and named **pure black**,
 * which on a phone is the one that matters: an OLED panel switches a `#000000`
 * pixel off rather than lighting it.
 *
 * ## Why this is a walk and not an assertion suite
 *
 * The arithmetic is asserted in `TerminalSchemeTests` — the table matches the
 * shared TypeScript, a chosen scheme ignores the appearance, the notification
 * repaints an open session. None of that answers the only question worth asking
 * about a colour picker, which is *does it look right*, and no test can. So this
 * walks the screens and photographs them into `TD_SHOTS` for somebody to open.
 *
 * It does make one measurement, and it is the one a screenshot cannot be faked
 * past: after Pure Black is chosen, the frame containing the session is sampled
 * at its centre and asserted to be **actually black**. A picker whose row is
 * ticked over a `#191919` terminal is exactly the failure this is for, and it
 * would photograph as a success.
 *
 * ## What it runs against
 *
 * `ios/Harness/run.sh host --approve-after 4000`, whose sessions are real
 * `node-pty` shells — so what is on screen under the colours is a real program's
 * real output, which is the whole point of photographing it. Skips when that is
 * not running, which is this target's standing rule.
 *
 *     ios/Harness/run.sh host --port 8791 --approve-after 4000 &
 *     TEST_RUNNER_TD_CONTROL=127.0.0.1:8792 \
 *     TEST_RUNNER_TD_SHOTS=/private/tmp/theme-shots \
 *     xcodebuild test -only-testing:TerminalDeckUITests/TerminalThemeShotsUITests …
 */

import UIKit
import XCTest

final class TerminalThemeShotsUITests: XCTestCase {

    private var app: XCUIApplication!

    private func env(_ name: String) -> String {
        ProcessInfo.processInfo.environment[name] ?? ""
    }

    private var control: String { env("TD_CONTROL") }
    /// Settings is passed through four times; its own frame is wanted once.
    private var settingsSeen = false
    private var shots: String { env("TD_SHOTS") }

    private static let notRunning =
        "No stand-in. Start ios/Harness/run.sh host --approve-after 4000 and pass "
        + "TEST_RUNNER_TD_CONTROL=127.0.0.1:<port+1>."

    // MARK: - The walk

    func testTheColourPickerAndPureBlackOnARealSession() throws {
        try XCTSkipIf(control.isEmpty, Self.notRunning)
        // A failure stops the walk, so the frames after it are not taken — the
        // right trade, because a set of photographs taken after an assertion
        // failed is a set of photographs of an app in a state nobody intended.
        continueAfterFailure = false

        app = XCUIApplication()
        app.launch()
        // A phone that is still paired from a previous run of this suite is
        // already past the door; asking it for a code would fail on a screen
        // that is not on screen. The stand-in keeps no identity between runs,
        // so a *stale* pairing cannot connect either — which `waitForConnected`
        // reports, rather than this line pretending to have paired.
        if !app.tabBars.firstMatch.waitForExistence(timeout: 8) {
            try pair(mint("/pair"))
        }
        capture("00-after-the-code")
        if !waitForConnected(timeout: 150) {
            capture("00-never-connected")
            XCTFail("never reached Connected")
        }

        // ---------------------------------------------------------------- 1 --
        // The picker, with the text size at the top of it — the two settings
        // that used to be a screen apart.
        try openTheTerminalScreen()
        capture("01-picker-top")
        XCTAssertTrue(app.otherElements["terminalTheme.scopeNote"].exists
                      || app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'stands alone'"))
                          .firstMatch.exists,
                      "the screen has to say whose choice this is")
        XCTAssertTrue(app.buttons["settings.textSize"].exists
                      || app.steppers["settings.textSize"].exists,
                      "the text size belongs on this screen now")

        app.swipeUp()
        capture("02-picker-scrolled")
        app.swipeUp()
        capture("03-picker-more")

        // ---------------------------------------------------------------- 2 --
        // Choose the one he named.
        try scrollTo(app.buttons["scheme.pure-black"])
        app.buttons["scheme.pure-black"].tap()
        capture("04-pure-black-chosen")

        // ---------------------------------------------------------------- 3 --
        // A real session, in it, with real output.
        try openASessionWithOutput()
        let black = capture("05-pure-black-session")
        XCTAssertLessThan(black, 0.06,
                          "a session on Pure Black should be very nearly black; this frame "
                          + "averages \(String(format: "%.3f", black)) — the picker is ticked "
                          + "and the terminal did not follow")

        // ---------------------------------------------------------------- 4 --
        // The same session, the same output, a different scheme — chosen while
        // it was open. This is *applies live* photographed rather than asserted.
        try openTheTerminalScreen()
        try scrollTo(app.buttons["scheme.solarized-light"])
        app.buttons["scheme.solarized-light"].tap()
        capture("06-solarized-chosen")

        app.openSessionsTab()
        try sessionRows().first!.tap()
        let solarized = capture("07-same-session-solarized")
        XCTAssertGreaterThan(solarized, 0.5,
                             "the session was on a light scheme and the frame averages "
                             + "\(String(format: "%.3f", solarized)) — it kept the old colours")

        // ---------------------------------------------------------------- 5 --
        // Editing. Tapping Edit on a shipped palette copies it first.
        try openTheTerminalScreen()
        try scrollTo(app.buttons["scheme.dracula.edit"])
        app.buttons["scheme.dracula.edit"].tap()
        XCTAssertTrue(app.otherElements["editor.preview"].waitForExistence(timeout: 10)
                      || app.staticTexts["Background"].waitForExistence(timeout: 10),
                      "the editor should be up")
        capture("08-editor-top")

        let name = app.textFields["editor.name"]
        XCTAssertTrue(name.exists, "a copy can be renamed")
        XCTAssertTrue(name.value as? String == "Dracula (yours)",
                      "editing a built-in makes a copy; the field said "
                      + "\(String(describing: name.value))")

        // Type a colour into the hex field beside Background and watch the
        // preview follow. The field is the second way into every colour and the
        // one somebody porting a scheme they already have will use.
        let hex = app.textFields.matching(NSPredicate(format: "value CONTAINS '#282a36'")).firstMatch
        if hex.waitForExistence(timeout: 5) {
            hex.tap()
            hex.press(forDuration: 1.2)
            if app.menuItems["Select All"].waitForExistence(timeout: 3) {
                app.menuItems["Select All"].tap()
            }
            hex.typeText("#101820\n")
            capture("09-editor-edited")
        }

        app.swipeUp()
        capture("10-editor-ansi")
        app.swipeUp()
        capture("11-editor-bright")

        // ---------------------------------------------------------------- 6 --
        // Back on the list, the copy is there beside the palette it came from,
        // and the original is untouched.
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
        try scrollTo(app.buttons["scheme.custom-1"])
        capture("12-copy-beside-the-original")

        // ---------------------------------------------------------------- 7 --
        // And the text size, in its new home, doing what it says.
        // The very bottom, because the floating tab pill floats *over* this
        // screen and the last card's verbs are the ones it would cover. A Delete
        // under the pill is a dead control, which is the one kind of defect this
        // app does not ship.
        for _ in 0 ..< 20 { app.swipeUp() }
        capture("16-the-bottom-of-the-list")
        let lastDelete = app.buttons["scheme.custom-1.delete"]
        XCTAssertTrue(lastDelete.exists && lastDelete.isHittable,
                      "the last card's Delete is under the tab pill")
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'stands alone'")).firstMatch.isHittable,
                      "the note saying whose choice this is ends up under the tab pill")

        try openTheTerminalScreen()
        capture("13-text-size-in-its-new-home")
        let stepper = app.steppers["settings.textSize"]
        if stepper.exists {
            stepper.buttons.element(boundBy: 1).tap()
            stepper.buttons.element(boundBy: 1).tap()
            stepper.buttons.element(boundBy: 1).tap()
            stepper.buttons.element(boundBy: 1).tap()
            capture("14-text-size-larger-previews-follow")
        }
    }

    // MARK: - Getting about

    private func openTheTerminalScreen() throws {
        // Leave the session first if one is open. Inside a terminal the tab bar
        // is deliberately not drawn — *"inside the session we don't need the
        // pill"* — so `openSettingsTab()` has no bar to tap and its own fallback
        // taps the navigation back button, which lands on Sessions rather than
        // Settings and then fails ten seconds later about the wrong thing.
        if app.buttons["terminal.keyboard"].exists {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists { back.tap() }
            _ = app.tabBars.firstMatch.waitForExistence(timeout: 10)
        }
        XCTAssertTrue(app.openSettingsTab(), "Settings should be reachable")
        let row = app.buttons["settings.terminalTheme"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Settings should have a Terminal row")
        // Settings itself, once, so the row's summary and the group it joined
        // are looked at rather than assumed. The Terminal *section* that used to
        // sit three groups below — one row, its own caption — is gone from this
        // screen, and a photograph is the only way to see that the hole closed.
        if !settingsSeen {
            settingsSeen = true
            capture("15-settings-with-the-terminal-row")
        }
        row.tap()
        XCTAssertTrue(app.buttons["scheme.follow-app"].waitForExistence(timeout: 10),
                      "the picker should be up, and Follow the app is its first row")
    }

    /**
     * Open a session and put something on its screen.
     *
     * The sessions the stand-in serves are real shells, so this types a real
     * command and photographs its real output — which is the only kind of frame
     * worth taking of a colour scheme. A fixture of coloured text would prove
     * that this app can draw coloured text.
     */
    private func openASessionWithOutput() throws {
        app.openSessionsTab()
        try sessionRows().first!.tap()
        let keyboard = app.buttons["terminal.keyboard"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 15), "the terminal screen should appear")
        keyboard.tap()
        // `ls` for the ordinary case and a colour test for the sixteen: a scheme
        // is judged on what an agent's output looks like, and an agent's output
        // is mostly ANSI-coloured status lines.
        // `ls` first and the coloured line last, so what is on screen when the
        // shutter goes is the part worth photographing. The other way round, a
        // directory listing of this worktree scrolled the colours off the top.
        app.typeText("ls\n")
        app.typeText("printf '\\033[32m\\u2713 PASS\\033[0m 12,415 tests   \\033[33m! 2 skipped\\033[0m   \\033[31m\\u2717 FAIL\\033[0m relay.test.ts\\n'\n")
        app.typeText("printf '\\033[34mblue\\033[0m \\033[35mmagenta\\033[0m \\033[36mcyan\\033[0m \\033[90mdim\\033[0m \\033[1;32mbright green\\033[0m\\n'\n")
        sleep(2)
        dismissTheKeyboardTutorial()
        if app.buttons["keys.dismiss"].exists { app.buttons["keys.dismiss"].tap() }
        sleep(1)
        dismissTheKeyboardTutorial()
    }

    /**
     * iOS's own *"Speed up your typing by sliding your finger"* card.
     *
     * It is shown once per simulator, over the bottom half of the screen, the
     * first time a keyboard is raised — and it is not the app's, so nothing in
     * the app can prevent it. It ate the `keys.dismiss` tap and then sat in the
     * frame: a photograph of a pure-black terminal under a white system card
     * measured 0.40 mean luminance and failed the assertion that the terminal
     * had gone black — about a terminal that had.
     */
    private func dismissTheKeyboardTutorial() {
        let cont = app.buttons["Continue"]
        if cont.exists && cont.isHittable {
            cont.tap()
            sleep(1)
        }
    }

    /**
     * Bring an element into view.
     *
     * Back to the top first, then down — rather than swiping up until something
     * appears, which is what the first version did and is why it failed on the
     * third card: `exists` stays true for a row that has scrolled *past* the top
     * of the screen, so every further swipe took it further away while the
     * condition it was waiting on could never come true again. Searching in one
     * direction from a known end cannot do that.
     */
    private func scrollTo(_ element: XCUIElement, tries: Int = 18) throws {
        if element.exists && element.isHittable { return }
        for _ in 0 ..< 12 {
            if element.exists && element.isHittable { return }
            app.swipeDown()
        }
        for _ in 0 ..< tries {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable,
                      "never reached \(element.identifier)")
    }

    private func sessionRows() throws -> [XCUIElement] {
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 25), "no session rows arrived")
        return (0 ..< rows.count).map { rows.element(boundBy: $0) }
    }

    // MARK: - Pairing

    /**
     * Pair with the stand-in.
     *
     * A fresh install does not open on the pairing screen any more — it opens on
     * the SSH login, and pairing with a computer is the door underneath it
     * (`serverLogin.pairingDoor`). That door is opened here rather than assumed
     * open, because the first version of this suite waited twenty-five seconds
     * for a field that was one tap away and then reported "the pairing screen
     * should be up" about an app that was working perfectly.
     */
    private func pair(_ code: String) throws {
        let field = app.textFields["pairing.field"]
        if !field.waitForExistence(timeout: 8) {
            let door = app.buttons["serverLogin.pairingDoor"]
            XCTAssertTrue(door.waitForExistence(timeout: 20),
                          "neither the pairing field nor the door to it is on screen")
            door.tap()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the pairing screen should be up")
        field.tap()
        field.typeText(code)
        if app.buttons["pairing.submit"].exists { app.buttons["pairing.submit"].tap() }
    }

    private func waitForConnected(timeout: TimeInterval) -> Bool {
        let pill = app.descendants(matching: .any).matching(identifier: "connection.pill").firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        var lastNudge = Date.distantPast
        while Date() < deadline {
            if pill.exists && pill.label.contains("Connected") { return true }
            if Date().timeIntervalSince(lastNudge) > 8 {
                lastNudge = Date()
                let tab = app.tabBars.firstMatch.buttons["Sessions"]
                if tab.exists { tab.tap() }
            }
            usleep(500_000)
        }
        return false
    }

    private func mint(_ path: String) throws -> String {
        guard let url = URL(string: "http://\(control)\(path)") else {
            throw XCTSkip("\(control) is not an address")
        }
        var answer: String?
        let done = expectation(description: "minted")
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                answer = json["code"] as? String
            }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 20)
        guard let answer, !answer.isEmpty else {
            throw XCTSkip("\(Self.notRunning) (\(control) did not answer \(path))")
        }
        return answer
    }

    // MARK: - Frames

    /// Photograph, keep, and hand back the frame's mean brightness so a caller
    /// can assert on what it just took. Same measurement `AppearanceShotsUITests`
    /// makes, and the same reason: a label is not a colour.
    @discardableResult
    private func capture(_ name: String) -> Double {
        // A quarter of a second before the shutter, and it is not politeness.
        // `tap()` returns as soon as the touch is delivered, so a frame taken on
        // the next line catches the button still in its pressed state — measured:
        // Pure Black's `#000000` preview photographed as `#3d3d3d`, which is
        // black composited at three-quarters over the card, and it made a
        // correct screen look like a scheme painting the wrong colour.
        usleep(400_000)
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if !shots.isEmpty {
            try? FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png"))
        }
        return AppearanceShotsUITests.averageLuminance(of: shot.image)
    }
}
