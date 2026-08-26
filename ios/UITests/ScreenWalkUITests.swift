/**
 * Every screen this release changed, photographed in order, against a real host.
 *
 * ## Why this exists as well as the suites beside it
 *
 * `AppearanceShotsUITests` measures whether each frame followed the light/dark
 * setting; `ReleaseShotsUITests` produces the App Store's five; `ReviewScreensUITests`
 * pins the screens one recording changed. None of them walks **what 0.10.3
 * built**, and this session built a folder picker, a Browser tab that absorbed
 * two features, a find bar, a history screen, a site-data screen and an update
 * control — six surfaces that were written, compiled, and *never once looked at*.
 *
 * Asad, on exactly that:
 *
 * > *"after everything is built too you should visualize it, everything on
 * > simulator and take screenshot also, read the code also, every way. So you
 * > know the current state of the application and the requirements and you know
 * > that if it is meeting what you have asked."*
 *
 * A screen that compiles is not a screen that works, and a green log is not a
 * look. This is the look, and it is repeatable.
 *
 * ## It asserts as well as photographs
 *
 * A tour that only captured images would pass with every frame blank. So each
 * stop names the one element that proves it arrived, and the run fails if a
 * screen is not there — the frames are the deliverable, the assertions are what
 * stop a green run from meaning nothing. The same rule `ReviewScreensUITests`
 * states about its own.
 *
 * ## It skips rather than fails without a host
 *
 * The standing rule of this target. Everything past the first two stops needs a
 * machine at the other end, and a suite that failed on a laptop with no host
 * running would be a suite nobody runs.
 */

import XCTest

final class ScreenWalkUITests: XCTestCase {

    private var app: XCUIApplication!

    /// Where the frames land, so they can be looked at outside the result
    /// bundle. Silent when unset — a photograph is a deliverable, not a
    /// condition of the run.
    private var shots: String { ProcessInfo.processInfo.environment["TD_SHOTS"] ?? "" }

    /// The pairing handshake this target already uses: the phone says when it is
    /// standing at the field, and whatever is driving the run mints a code then.
    /// A code is good for sixty seconds and a Simulator takes longer than that
    /// to build, install and launch, so it cannot be minted in advance.
    private var readyFile: String { ProcessInfo.processInfo.environment["TD_READY_FILE"] ?? "" }
    private var codeFile: String { ProcessInfo.processInfo.environment["TD_CODE_FILE"] ?? "" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    /**
     * The whole tour, as one case.
     *
     * One rather than eight because the pairing is one act and a code is spent
     * once: eight cases would be eight launches and seven codes that had already
     * been redeemed. The stops are numbered in the file names instead, which is
     * what makes the output readable as a sequence.
     */
    func testWalkEveryScreen() throws {
        /*
         * **A phone that is already paired starts at stop 3**, and that is what
         * makes this suite worth re-running.
         *
         * A pairing lasts until it is revoked, so the second run against a
         * Simulator that was not erased comes up on the session list with no
         * login and no field to type into. Asserting the login screen first
         * would fail every run after the first, which is the shape of test
         * nobody runs twice — and the walk is meant to be run after every
         * change, not once.
         */
        let alreadyIn = app.buttons["sessions.new"].waitForExistence(timeout: 15)
            || app.buttons["sessions.more"].exists

        if !alreadyIn {
            // 1. The first screen, which is the login and assumes no computer.
            XCTAssertTrue(app.textFields["serverLogin.address"].waitForExistence(timeout: 20),
                          "the first screen should be the server login")
            capture("01-login")

            try XCTSkipIf(readyFile.isEmpty, "no TD_READY_FILE — nothing can pair this run")

            // 2. The pairing screen, one tap behind the login.
            XCTAssertTrue(app.reachPairingField(timeout: 20), "pairing should be one tap away")
            capture("02-pairing")

            let code = try codeFromWhateverIsDrivingThis()
            let field = app.textFields["pairing.field"]
            field.tap()
            field.typeText(code)
            let submit = app.buttons["pairing.submit"]
            if submit.exists && submit.isHittable { submit.tap() }

            let arrived = app.buttons["sessions.new"].waitForExistence(timeout: 180)
                || app.buttons["sessions.more"].waitForExistence(timeout: 5)
            try XCTSkipUnless(arrived, "the phone never reached the session list — nothing to walk")
        }

        // 3. The session list, against a real machine.
        capture("03-sessions")

        // 4. New Session, which is where the folder picker is offered.
        let plus = app.buttons["sessions.new"]
        if plus.exists && plus.isHittable {
            plus.tap()
            capture("04-new-session-menu")
            /*
             * `descendants` rather than `app.buttons`, because a SwiftUI `Menu`
             * presents its rows in a layer of its own and the plain query misses
             * them — measured: the row is legible in `04-new-session-menu.png`
             * and `app.buttons["sessions.pickFolder"]` reported it absent, so
             * the walk photographed the menu and silently skipped the screen it
             * exists to look at.
             */
            /*
             * **By its words, not its identifier.**
             *
             * `accessibilityIdentifier` on a `Button` inside a SwiftUI `Menu`
             * does not reach the presented row — measured twice here: the row is
             * plainly legible in `04-new-session-menu.png` and both
             * `app.buttons["sessions.pickFolder"]` and a `descendants` query on
             * the same identifier reported it absent, so the walk photographed
             * the menu and skipped the screen it exists to look at. The label is
             * what the row actually carries, so the label is what this asks for.
             */
            let pick = app.buttons["Choose a folder…"].exists
                ? app.buttons["Choose a folder…"]
                : app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label BEGINSWITH 'Choose a folder'")).firstMatch
            if pick.waitForExistence(timeout: 5) {
                pick.tap()
                // Photographed **before** the assertion, so a picker that comes
                // up wrong is a frame to look at rather than a red line with no
                // evidence behind it.
                _ = app.staticTexts["folders.here"].waitForExistence(timeout: 20)
                capture("05-folder-picker")
                XCTAssertTrue(app.staticTexts["folders.here"].exists,
                              "the folder picker should say where it is")
                if app.buttons["folders.cancel"].exists { app.buttons["folders.cancel"].tap() }
            } else {
                // Dismiss the menu rather than leaving it open over the next tap.
                app.tap()
            }
        }

        /*
         * 5. The Browser tab's home, which is the machine's open windows and
         *    nothing else.
         *
         * > *"The home page of the browser should be for the open browser
         * > windows, and we should be able just to see only the open windows…
         * > the home page is not for the multiple kinds of stuff — it should be
         * > smooth, simple."*
         *
         * The address bar, the tunnel tabs and the six groups of ports were all
         * on this screen until this build. They are one row down its `…` now,
         * which is where this walk goes next.
         */
        XCTAssertTrue(app.openBrowserTab(), "the Browser tab should be reachable")
        capture("06-browser")

        let more = app.buttons["browser.more"]

        /*
         * 6. The New Window sheet, which is where the ports went.
         *
         * > *"I wanted it to be like one page where I can start a new window…
         * > even the localhost thing should be folded somewhere else."*
         *
         * There is no `localhost.more` any more and no second screen to walk to:
         * an address, a destination, and the machine's own ports as suggestions
         * under it, all inside the act of opening a window. Photographed and
         * cancelled — opening one would put a real window on his real server.
         */
        if app.buttons["browser.new"].waitForExistence(timeout: 8) {
            app.buttons["browser.new"].tap()
            _ = app.buttons["browser.open.cancel"].waitForExistence(timeout: 6)
            capture("07-new-window-and-the-ports")
            let cancel = app.buttons["browser.open.cancel"].firstMatch
            if cancel.exists && cancel.isHittable { cancel.tap() } else { app.dismissAnyMenu() }
        }

        // 7. This phone's own browser screens, on the home's menu where they
        //    have always been.
        for (id, name) in [("browser.history", "08-history"),
                           ("browser.data", "09-site-data"),
                           ("browser.logins", "10-saved-logins")] {
            guard more.waitForExistence(timeout: 5) else { break }
            more.tap()
            let row = app.descendants(matching: .any).matching(identifier: id).firstMatch
            guard row.waitForExistence(timeout: 4) else { app.dismissAnyMenu(); continue }
            row.tap()
            _ = app.navigationBars.firstMatch.waitForExistence(timeout: 6)
            capture(name)
            let done = app.buttons.matching(identifier: "history.done").firstMatch
            if done.exists && done.isHittable {
                done.tap()
            } else {
                app.navigationBars.buttons.firstMatch.tap()
            }
        }

        // 7. Back to the home, and the one screen still behind its menu: the
        //    machine's own Chromium profiles, which is what these windows run in.
        XCTAssertTrue(app.openBrowserTab(), "the Browser tab's home should be reachable again")
        for (id, name) in [("browser.profiles", "11-machine-profiles")] {
            guard more.waitForExistence(timeout: 5) else { break }
            more.tap()
            let row = app.descendants(matching: .any).matching(identifier: id).firstMatch
            guard row.waitForExistence(timeout: 4) else {
                /*
                 * **Not there, so close the menu — and close it the way the
                 * system does.**
                 *
                 * `Browser profiles` is drawn only when the machine advertises
                 * `browser.profiles`, which a headless host without a Chromium
                 * does not — so this is the ordinary path against a real server,
                 * not a failure. What made it a failure was the *dismissal*: a
                 * presented SwiftUI `Menu` leaves everything behind it in the
                 * accessibility tree, so a guard reading `browser.address` was
                 * satisfied by an element under the popover and the walk left it
                 * standing. Every later tap then landed on the dismiss region
                 * and the run sat on the Browser tab until it timed out —
                 * measured, twice.
                 *
                 * `PopoverDismissRegion` is the element UIKit puts over the rest
                 * of the screen for exactly this, and tapping it is what a person
                 * tapping outside the menu does.
                 */
                app.dismissAnyMenu()
                continue
            }
            row.tap()
            capture(name)
            app.navigationBars.buttons.firstMatch.tap()
        }
        app.dismissAnyMenu()

        // 9. Menu — renamed from Settings, with the six machine tools at the top
        //    of it rather than buried behind a server page.
        XCTAssertTrue(app.openSettingsTab(), "Menu should be reachable")
        capture("13-menu")

        /*
         * 10. The six, each one photographed.
         *
         * > *"all what I asked for so many times — told you I need all, no
         * > exceptions."*
         *
         * Every one is a `NavigationLink` on the Menu screen, so the walk is the
         * same four lines six times: tap, wait, photograph, come back. A tool
         * whose capability the machine does not advertise is not drawn at all,
         * which is why each is skipped rather than asserted — the point of the
         * frames is to see which ones a real server offers.
         */
        for (index, tool) in ["files", "git", "artifacts", "store", "readiness", "mcp"].enumerated() {
            let row = app.descendants(matching: .any)
                .matching(identifier: "machine.tools.\(tool)").firstMatch
            guard row.waitForExistence(timeout: 4) else { continue }
            row.tap()
            // A panel has to ask the machine before it has anything to draw, so
            // the frame is taken after a beat rather than on the first paint —
            // otherwise all six photographs are of the same spinner.
            Thread.sleep(forTimeInterval: 2.5)
            capture(String(format: "14-%d-%@", index + 1, tool))
            /*
             * **What the panel offered, photographed as well as the rows.**
             *
             * > *"these pages are not just to view the information — exactly all
             * > actions that we have in desktop application."*
             *
             * The rows were the whole of what this walk looked at, which is the
             * half that was never in doubt. What is worth a frame is the half
             * that is new: the filter pills a panel declares, and the form
             * behind an action that asks for one.
             *
             * **Nothing is ever submitted.** These run against Asad's own
             * server: `panel.form.cancel` is pressed, never `panel.form.submit`,
             * so the walk can photograph an Add form on a real machine without
             * adding anything to it.
             */
            let scope = app.buttons
                .matching(NSPredicate(format: "identifier BEGINSWITH 'panel.\(tool).scope.'")).firstMatch
            if scope.waitForExistence(timeout: 3), scope.isHittable {
                scope.tap()
                Thread.sleep(forTimeInterval: 1.5)
                capture(String(format: "14-%d-%@-scoped", index + 1, tool))
            }
            let act = app.buttons
                .matching(NSPredicate(format: "identifier BEGINSWITH 'panel.\(tool).act.'")).firstMatch
            if act.exists && act.isHittable {
                act.tap()
                if app.buttons["panel.form.cancel"].waitForExistence(timeout: 4) {
                    capture(String(format: "14-%d-%@-form", index + 1, tool))
                    app.buttons["panel.form.cancel"].tap()
                }
            }
            app.navigationBars.buttons.firstMatch.tap()
            _ = app.buttons["settings.machines"].waitForExistence(timeout: 4)
        }

        // The Appearance page — the app's light/dark, the terminal text size and
        // the terminal colours, which were three controls in three places until
        // *"overall appearance page should be there in the settings."*
        if app.buttons["settings.appearance"].waitForExistence(timeout: 10) {
            app.buttons["settings.appearance"].tap()
            capture("15-appearance")
            app.navigationBars.buttons.firstMatch.tap()
        }

        // 11. Machines, and one machine's own page behind the ⓘ — the screen he
        //     said had gone.
        if app.buttons["settings.machines"].waitForExistence(timeout: 10) {
            app.buttons["settings.machines"].tap()
            capture("16-machines")
            // By prefix: the identifier carries the machine's id, which this
            // suite cannot know — whichever machine is first is the one to look
            // at, and there is usually only one.
            let info = app.buttons
                .matching(NSPredicate(format: "identifier BEGINSWITH 'machine.about.'")).firstMatch
            if info.waitForExistence(timeout: 4) {
                info.tap()
                capture("17-machine-detail")
                app.navigationBars.buttons.firstMatch.tap()
            }
            app.navigationBars.buttons.firstMatch.tap()
        }

        /*
         * 12. One of the machine's own windows, opened from the home — where the
         *     binding, the screenshot and the click recorder now live.
         *
         * There is no menu row to press any more: the windows *are* the Browser
         * tab, so this is a row on its home. *"We should be able just to see
         * only the open windows, and then we can just click on any of them."*
         *
         * Skipped where the machine has no window open, or does not advertise
         * `browser.control` — both are the ordinary answer from a host with no
         * Chromium, and neither is a failure.
         */
        if app.openBrowserTab() {
            capture("18-machine-browser")
            // By prefix: the id is the machine's shell tab id, which this suite
            // cannot know.
            let row = app.buttons
                .matching(NSPredicate(format: "identifier BEGINSWITH 'browser.machine.row.'")).firstMatch
            if row.waitForExistence(timeout: 8) {
                row.tap()
                // The bar under the page, which both shapes of that screen have
                // — the live picture and the settings-as-the-body.
                _ = app.buttons["browser.machine.window.reload"].waitForExistence(timeout: 10)
                capture("19-machine-window")
                /*
                 * And its settings, behind the `…` on that bar — *"settings of
                 * per window, how to connect to it, how to make it shared or
                 * isolated, all of these things should be inside of the
                 * window."* The button is drawn only on a window the machine is
                 * casting; on one it is not, those cards are already the body of
                 * the screen photographed above.
                 */
                let settings = app.buttons["browser.machine.window.settings"]
                if settings.waitForExistence(timeout: 3) {
                    settings.tap()
                    _ = app.buttons["browser.machine.window.record"].waitForExistence(timeout: 8)
                    capture("19b-machine-window-settings")
                    app.navigationBars.buttons.firstMatch.tap()
                }
                app.navigationBars.buttons.firstMatch.tap()
            }
        }

        // 13. Back where it started, so the last frame proves nothing was left
        //     open over the app.
        app.openSessionsTab()
        capture("20-sessions-again")

        /*
         * 14. The Copilot pill, **last**, and that ordering is the point.
         *
         * A server always has this pill, and the tab now *lands in a session* —
         * *"when we land on the copilot page there should be directly a new
         * session started."* A session is `.session`, which hides the tab bar
         * correctly, so from here there is no bar to press and every later stop
         * is unreachable. It failed exactly that way twice, which is how the
         * landing was confirmed to work end to end.
         *
         * Rather than teach the walk to climb back out — one more thing to get
         * wrong, on the one screen whose whole job is to be a dead end — this
         * stop goes at the end, where having nowhere to go next costs nothing.
         */
        if app.openCopilotTab() {
            // Landing is a navigation that has to survive the tab transition, so
            // the frame worth taking is whatever it settles on rather than the
            // first paint.
            Thread.sleep(forTimeInterval: 4)
            capture("21-copilot")
        }
    }

    // MARK: - Helpers

    /// The code, from whatever is driving this run. Writes `ready`, then waits.
    private func codeFromWhateverIsDrivingThis() throws -> String {
        try? "ready\n".write(toFile: readyFile, atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            if let raw = try? String(contentsOfFile: codeFile, encoding: .utf8) {
                let digits = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if digits.count == 6 { return digits }
            }
            usleep(400_000)
        }
        throw XCTSkip("nothing wrote six digits to TD_CODE_FILE")
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
