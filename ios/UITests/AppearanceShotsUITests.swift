/**
 * Every screen, in both appearances, photographed — and the one assertion that
 * makes the photographs mean something.
 *
 * Asad: *"mobile iOS is only dark mode — it should have both, in settings."*
 * This app was pinned dark in three places (see `Theme.swift`), and the failure
 * mode of unpinning it is not a crash: it is a screen that is *technically* in
 * light mode and unreadable — a white band where a grey one should be, a card
 * lighter than the pane it sits on, ink that stayed light because the colour it
 * came from was resolved once and frozen. None of that fails a build and none of
 * it fails a unit test. It is only visible.
 *
 * So this suite is two things at once:
 *
 *  1. **A photograph of every screen in both schemes**, written where a person
 *     can open them (`TD_SHOTS`). That is the deliverable; it is not an
 *     assertion and it is not pretending to be one.
 *  2. **A measurement of the frame it just took.** `capture` decodes the
 *     screenshot and averages its luminance, and the walk asserts that a screen
 *     photographed in Light is actually light and one photographed in Dark is
 *     actually dark. That is the assertion a label cannot make: a picker reading
 *     "Light" over a black screen is exactly the bug, and it is the state this
 *     app would have been left in by removing the `Info.plist` pin and nothing
 *     else.
 *
 * The relaunch case is the third claim in the brief — that the setting survives
 * one — and it is proved the same way: choose Light, kill the process, launch it
 * again, and measure the first screen. A `UserDefaults` round trip that only
 * checked the picker's label would pass on an app that had saved the preference
 * and stopped applying it.
 *
 * ## Two hosts, because no single one serves everything
 *
 * `testEveryScreenInBothSchemes` needs the product's own headless host — the
 * stand-in implements no `ports` handler at all, so the Localhost tab is
 * permanently empty against it and three of the stops would be photographs of an
 * empty screen. `ios/Harness/appearance-shots.sh` is that whole arrangement in
 * one command.
 *
 * `testTheCopilotScreensInBothSchemes` needs the opposite: the stand-in with
 * `--copilot alter`. The window build does have a copilot now, but the headless
 * host this suite's other case runs against does not — `src/headless/host.ts`
 * injects no `CopilotRuns` — so against *that* host the copilot screens do not
 * exist to photograph.
 *
 * Note what the stand-in will draw: a device arrives **unconnected**, because
 * the copilot is a separate connection and nothing has redeemed a code. That is
 * a real screen and a fine one to photograph; a walk that wanted the timeline
 * would have to mint a code through `/copilot-code` first, which is what
 * `CopilotScreensUITests` does.
 *
 * Both skip when their host is absent, which is this target's standing rule.
 */

import UIKit
import XCTest

final class AppearanceShotsUITests: XCTestCase {

    private var app: XCUIApplication!

    private func env(_ name: String) -> String {
        ProcessInfo.processInfo.environment[name] ?? ""
    }

    private var readyFile: String { env("TD_READY_FILE") }
    private var codeFile: String { env("TD_CODE_FILE") }
    private var control: String { env("TD_CONTROL") }
    private var shots: String { env("TD_SHOTS") }

    /// Which scheme the frames being taken are supposed to be in. Read by
    /// `capture`, which is where the measurement happens, so that every single
    /// frame is checked rather than the two somebody remembered to assert about.
    private var expecting: Scheme = .dark

    private enum Scheme: String {
        case dark
        case light

        /// The name of the segment in Settings.
        var segment: String { self == .dark ? "Dark" : "Light" }

        /**
         * What an average frame's luminance may be, 0…1.
         *
         * Wide bands rather than tight ones, and measured rather than guessed:
         * a dark session list is around 0.10 and a light one around 0.90, so the
         * gap being tested for is enormous. The point is not to grade the
         * palette — the palette's own contrast is asserted arithmetically in
         * `AppearanceTests` — it is to catch a screen that did not change at
         * all, which is the failure that looks like success in a log.
         *
         * The terminal is the reason the dark ceiling is not tighter: a light
         * terminal is `#e8e8e8` paper under a navigation bar, and a dark one is
         * near-black, so both ends of this range have a screen that sits close
         * to it.
         */
        var luminanceRange: ClosedRange<Double> { self == .dark ? 0.0 ... 0.42 : 0.58 ... 1.0 }
    }

    private static let noLiveHost =
        "No live desktop. Run ios/Harness/appearance-shots.sh, which starts out/headless/host.mjs "
        + "under its own HOME, grants it a folder and passes TD_READY_FILE / TD_CODE_FILE."

    private static let noStandIn =
        "No stand-in. Start ios/Harness/run.sh host --copilot act --approve-after 3000 and pass "
        + "TEST_RUNNER_TD_CONTROL=127.0.0.1:8788."

    // MARK: - The tour

    func testEveryScreenInBothSchemes() throws {
        try XCTSkipIf(readyFile.isEmpty, Self.noLiveHost)
        // A failure stops the walk, so the frames after it are not taken. That
        // is the right trade: the frames exist to be looked at by somebody
        // deciding whether to ship, and a set taken after an assertion failed is
        // a set of photographs of an app in a state nobody intended. The first
        // run of this suite proved the point — a stray tap opened a web page at
        // stop three and the remaining nine frames were all of that page.
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        try connectToTheLiveHost()

        // Dark first, because that is what the app shipped as: the first pass is
        // "nothing regressed" and the second is the new half.
        for scheme in [Scheme.dark, Scheme.light] {
            try choose(scheme)
            try settingsAndMachines(scheme)
            try localhost(scheme)
            try sessionsAndATerminal(scheme)
            try theSheets(scheme)
        }

        try theChoiceSurvivesARelaunch()
    }

    func testTheCopilotScreensInBothSchemes() throws {
        try XCTSkipIf(control.isEmpty, Self.noStandIn)
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        app.forgetEveryMachine()
        try pairWithTheStandIn()

        for scheme in [Scheme.dark, Scheme.light] {
            try choose(scheme)
            /*
             * The pill, when there is one — and the bar itself when there is not.
             *
             * The copilot was pinned above the sessions until *"a fourth pill,
             * and the copilot goes leftmost"*, and the pill itself is now
             * conditional: *"if the copilot is not connecting, this icon should
             * not be inside the pill."* A stand-in started without `--copilot`
             * draws three pills, and there is nothing behind that any more —
             * *"if we connect as guest then copilot don't come"* deleted the
             * connect screen along with the ceremony. So the frame worth taking
             * in that case is the three-pill bar.
             */
            guard app.openCopilotTab() else {
                sleep(2)
                capture("\(scheme.rawValue)-21-three-pills-no-copilot")
                continue
            }
            /*
             * Photographed in whatever state it is in, rather than waited on for
             * one particular control.
             *
             * The copilot's *client* half is the part of `COPILOT-REMOTE.md` §8
             * that is not built yet, so which of the screen's states a phone
             * reaches against the stand-in is a moving target — connect, not
             * granted, watching, or the full thing. Waiting for the toolbar
             * button specifically failed here on a screen that was drawing perfectly
             * well, which is a test asserting the feature's roadmap rather than
             * its appearance. The frame is still measured, so the claim this
             * suite makes about it — that it followed the scheme — still holds.
             */
            sleep(3)
            capture("\(scheme.rawValue)-21-copilot")

            /*
             * The controls, and the two sheets on them.
             *
             * This used to walk a `…` menu; that menu is gone, folded into
             * `CopilotControlView` — *"all the control about copilot, all the
             * settings of the copilot… whatever, three dots, maybe your settings
             * button, whatever it is."* So the gear is the single top-right control
             * on every screen this tab can show, and this photographs the screen
             * behind it and then each sheet, dismissing each by its own Done so
             * that a sheet which fails to open is one missing frame rather than a
             * tour that ends here.
             */
            let controls = app.buttons["copilot.controls"]
            if controls.exists {
                controls.tap()
                _ = app.navigationBars["Copilot"].waitForExistence(timeout: 5)
                capture("\(scheme.rawValue)-22-copilot-controls")
                // Waited on by the sheet's own navigation title rather than by
                // an identifier on the row that opened it. The old walk waited
                // on the menu item's id, which is not in the hierarchy once the
                // menu has closed — so it spent its whole timeout and
                // photographed whatever happened to be on screen.
                for (row, title, name) in [("copilot.controls.sessions", "Sessions it started",
                                            "23-copilot-sessions"),
                                           ("copilot.controls.activity", "Everything it did",
                                            "24-copilot-log")] {
                    if app.buttons[row].waitForExistence(timeout: 3) {
                        app.buttons[row].tap()
                        _ = app.navigationBars[title].waitForExistence(timeout: 10)
                        capture("\(scheme.rawValue)-\(name)")
                        dismissASheet()
                    }
                }
                // Out of the controls, back to the conversation under them.
                let up = app.navigationBars.buttons.element(boundBy: 0)
                if up.exists { up.tap() }
            }
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists { back.tap() }
        }
    }

    // MARK: - The stops

    /**
     * Choose an appearance the way a person does — Settings → **Appearance** →
     * the picker — and prove the choice landed before photographing anything by
     * it.
     *
     * Not a launch argument and not `overrideUserInterfaceStyle` from the test
     * process. Both would prove that the palette can render light and neither
     * would prove that the *setting* does anything, which is the whole of what
     * was asked for.
     *
     * **It is a push now, and it walks back out.** The picker used to sit inline
     * on the Settings screen; it is the first group on the Appearance page, with
     * the terminal text size and colours under it — *"overall appearance page
     * should be there in the settings and from there we can change colors text
     * size and everything for all of them."* Coming back out matters: every
     * caller expects to be handed the Settings root, and the frames taken after
     * this are of screens reached from there.
     */
    private func choose(_ scheme: Scheme) throws {
        XCTAssertTrue(app.openSettingsTab(), "Settings should be reachable")
        try openTheAppearancePage()
        let picker = app.segmentedControls["appearance.theme"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10),
                      "the Appearance page should hold the appearance picker")
        let segment = picker.buttons[scheme.segment]
        XCTAssertTrue(segment.waitForExistence(timeout: 5),
                      "the picker should offer \(scheme.segment)")
        segment.tap()
        XCTAssertTrue(segment.isSelected, "\(scheme.segment) should be the chosen segment")
        expecting = scheme
        // One frame's worth of settling. The window's interface style changes on
        // the next run loop pass and a screenshot taken inside the same one
        // catches the previous appearance — which would fail `capture`'s own
        // measurement and blame the wrong thing.
        sleep(1)
        leaveTheAppearancePage()
    }

    /// Settings → Appearance, from the Settings root this suite always leaves
    /// itself on.
    private func openTheAppearancePage() throws {
        let row = app.buttons["settings.appearance"]
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "Settings should have an Appearance row")
        row.tap()
    }

    /// Back to the Settings root, and waits for it — a screenshot taken during
    /// the pop catches the page sliding off and measures the wrong frame.
    private func leaveTheAppearancePage() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
        _ = app.buttons["settings.appearance"].waitForExistence(timeout: 10)
    }

    /**
     * Sweep away a notification banner before it can be tapped.
     *
     * XCUITest dismisses an "interrupting element" by **tapping** it, and a
     * banner covers the top of the screen where the first row of a list is. On
     * the first run of this suite a freshly erased Simulator fired *"Ready for
     * Apple Intelligence"* over the port list, the runner tapped it to get it out
     * of the way, the tap reached the row underneath, and the remaining nine
     * frames were photographs of a web page nobody had asked to open.
     *
     * `appearance-shots.sh` stops erasing the device for the same reason, so this
     * is the second line of defence rather than the only one — and it is a swipe
     * up, which is how a person puts a banner away and the one gesture that
     * cannot reach the app underneath.
     */
    private func clearBanners() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for identifier in ["NotificationShortLookView", "BannerWindow"] {
            let banner = springboard.otherElements[identifier]
            if banner.exists {
                banner.swipeUp()
                sleep(1)
            }
        }
    }

    private func settingsAndMachines(_ scheme: Scheme) throws {
        capture("\(scheme.rawValue)-01-settings")

        XCTAssertTrue(app.openMachinesTab(), "Machines should push from Settings")
        capture("\(scheme.rawValue)-02-machines")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        _ = app.buttons["settings.alerts"].waitForExistence(timeout: 10)
    }

    private func localhost(_ scheme: Scheme) throws {
        XCTAssertTrue(app.openLocalhostList(),
                      "the localhost list is one row down the Browser tab's menu — see TabNavigation")
        // One list, no groups: *"this other services and web services should not
        // be like separate lists, it should be one list."* What is waited for is
        // the first port row, which is the thing that used to be behind a header.
        let firstPort = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'port.' AND NOT identifier CONTAINS 'more'"))
            .firstMatch
        XCTAssertTrue(firstPort.waitForExistence(timeout: 30), "the machine's ports should arrive")
        capture("\(scheme.rawValue)-03-localhost")

        // A page from the machine. The port is whatever the runner told us to
        // open — a page this repository serves rather than somebody else's dev
        // server, because a tunnel is a real request to a real program.
        let port = env("TD_PAGE_PORT")
        if !port.isEmpty {
            let row = app.buttons["port.\(port)"]
            if row.waitForExistence(timeout: 20) {
                row.tap()
                if app.buttons["localhost.back"].waitForExistence(timeout: 60) {
                    sleep(3)
                    /*
                     * Photographed but **not measured**, and this is the one
                     * exemption in the suite.
                     *
                     * Most of this frame is a page from somebody's dev server,
                     * rendered by WebKit from that page's own CSS. A page with a
                     * white background stays white in the dark appearance and
                     * that is correct — the app does not get to restyle content
                     * from the machine, and a "dark mode" that inverted a
                     * customer's site would be a bug rather than a feature. What
                     * has to follow the appearance here is the chrome around it,
                     * which is a bar at each end and too little of the frame for
                     * a mean to say anything about. So this one is for the eye.
                     */
                    capture("\(scheme.rawValue)-05-localhost-page", measured: false)
                }
                /*
                 * **The inspect sheet is not photographed here, and it cannot
                 * be on a Simulator.**
                 *
                 * Inspect is a tap on an element of a page from the machine, so
                 * it needs a page that rendered — and against a host on this
                 * same Mac, one never will. `PortTunnel` deliberately binds the
                 * *same port number* on the phone so that the absolute links a
                 * dev server writes into its own pages resolve; the Simulator
                 * has no network stack of its own, so that number is already
                 * taken by the very server being tunnelled to.
                 * `PortTunnel.swift` says so in as many words, and the app's own
                 * refusal — "Port 4399 is already in use on this phone" — is
                 * what these two frames photograph instead.
                 *
                 * That is a property of the harness rather than of the app: on a
                 * real phone the two ends are two machines and the number is
                 * free. A frame of the inspect sheet needs a device, and writing
                 * a tap here that can never fire would be worse than leaving the
                 * gap named.
                 */
                /*
                 * Off the page again, by the chevron top left.
                 *
                 * This tapped `localhost.done` until this round, and there is no
                 * Done: the row under a page on this phone is the same six
                 * controls as the row under every other browser window, and the
                 * verb that tears the tunnel down is `Close this window` inside
                 * the `…`. Popping the screen does exactly the same thing in one
                 * tap, which is why the verb could move at all.
                 *
                 * Still guarded, and guarded on **the page's own bar** rather
                 * than on a chevron: the tap above may have been refused before
                 * anything opened — see the note below on why it is, on this
                 * harness — and pressing whatever back button happens to be on
                 * screen would then walk the tour off the Browser tab entirely.
                 * Reload is drawn in every phase of a tunnel, greyed until it can
                 * act, so it is the honest answer to *is the page screen up*.
                 */
                if app.buttons["localhost.reload"].exists {
                    app.navigationBars.buttons.element(boundBy: 0).tap()
                }
                // The bar, not the `+` — the always-on control on this tab
                // since the two became one Browser screen.
                _ = app.textFields["browser.address"].waitForExistence(timeout: 15)
                // The tunnel binds the same port number on the phone so that the
                // page's own absolute links resolve, and closing the page hands
                // that socket back a moment later. Opening the same port again
                // inside that moment is refused — with a clear sentence, but a
                // photograph of a sentence is not a photograph of a page, which
                // is what the second pass got the first time this ran.
                sleep(3)
            }
        }
    }

    /**
     * The session list, a live terminal, and the terminal's own surfaces.
     *
     * The terminal prints an ANSI ruler before it is photographed, deliberately.
     * A light terminal showing a shell prompt proves the paper changed and
     * nothing else; the sixteen ANSI colours are the part of a light terminal
     * that is easy to get wrong and impossible to notice on an empty screen —
     * see `Ink.ansi` for what they are and why the light half is not the dark
     * half.
     */
    private func sessionsAndATerminal(_ scheme: Scheme) throws {
        app.openSessionsTab()
        XCTAssertTrue(app.buttons["sessions.more"].waitForExistence(timeout: 20),
                      "the session list should be on screen")
        capture("\(scheme.rawValue)-06-sessions")

        let new = app.buttons["sessions.new"]
        XCTAssertTrue(new.waitForExistence(timeout: 30),
                      "the host has granted a folder, so New Session should be offered")
        new.tap()
        let inMenu = app.buttons["sessions.newDefault"]
        if inMenu.waitForExistence(timeout: 4) { inMenu.tap() }

        let terminal = app.descendants(matching: .any)["terminal.view"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 60), "the session should open its terminal")
        sleep(4)

        // The sixteen, each as its own name, and then a line of the default
        // foreground so the two can be compared in one frame.
        try type("printf '\\033[%sm %s \\033[0m' 30 black 31 red 32 green 33 yellow 34 blue "
                 + "35 magenta 36 cyan 37 white; echo\n")
        sleep(1)
        try type("printf '\\033[%sm %s \\033[0m' 90 black 91 red 92 green 93 yellow 94 blue "
                 + "95 magenta 96 cyan 97 white; echo\n")
        sleep(1)
        try type("echo 'default foreground — the colour ESC[39m means'; ls -la | head -6\n")
        sleep(2)
        capture("\(scheme.rawValue)-07-terminal-keyboard")

        if app.buttons["keys.dismiss"].exists { app.buttons["keys.dismiss"].tap() }
        sleep(2)
        capture("\(scheme.rawValue)-08-terminal")

        // The key grid, which is the one UIKit surface in this app that draws its
        // own fills rather than taking a system material. Raised by tapping the
        // terminal now that the toolbar's keyboard button is gone.
        if terminal.exists {
            terminal.tap()
            if app.buttons["Continue"].exists { app.buttons["Continue"].tap() }
            if app.buttons["keys.more"].waitForExistence(timeout: 10) {
                app.buttons["keys.more"].tap()
                sleep(1)
                capture("\(scheme.rawValue)-09-key-grid")
                app.buttons["keys.more"].tap()
            }
            if app.buttons["keys.dismiss"].exists { app.buttons["keys.dismiss"].tap() }
        }

        // The find bar floats over the terminal on a material, so it is the one
        // place a light theme could put a light bar over light paper.
        if app.buttons["terminal.actions"].exists {
            app.buttons["terminal.actions"].tap()
            if app.buttons["terminal.find"].waitForExistence(timeout: 5) {
                app.buttons["terminal.find"].tap()
                if app.textFields["find.field"].waitForExistence(timeout: 5) {
                    app.textFields["find.field"].typeText("line")
                    sleep(1)
                    capture("\(scheme.rawValue)-10-terminal-find")
                    if app.buttons["find.done"].exists { app.buttons["find.done"].tap() }
                }
            } else {
                dismissASheet()
            }
        }

        // The session's own detail sheet. It lives *inside* the actions menu, so
        // the menu has to be opened again — the find stop above closed it. The
        // first run of this suite checked `terminal.details.exists` with no menu
        // on screen, found nothing, and skipped the frame in both schemes
        // without failing, which is the quiet way a screenshot suite lies.
        if app.buttons["terminal.actions"].exists {
            app.buttons["terminal.actions"].tap()
            XCTAssertTrue(app.buttons["terminal.details"].waitForExistence(timeout: 10),
                          "the actions menu should hold Session details")
            app.buttons["terminal.details"].tap()
            XCTAssertTrue(app.buttons["detail.done"].waitForExistence(timeout: 10),
                          "Session details should raise its sheet")
            capture("\(scheme.rawValue)-11-session-detail")
            app.buttons["detail.done"].tap()
        }

        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
        _ = app.buttons["sessions.more"].waitForExistence(timeout: 15)
    }

    /// The two sheets raised from Settings, both of which used to state `.dark`
    /// for themselves.
    private func theSheets(_ scheme: Scheme) throws {
        if app.openAlerts() {
            capture("\(scheme.rawValue)-12-alerts")
            app.buttons["alerts.done"].tap()
        }
        // The pairing sheet, which is the same screen the app opens on when
        // nothing is paired — and the one screen `RootView` used to state a
        // scheme for twice.
        if app.beginPairingAnotherMachine() {
            capture("\(scheme.rawValue)-14-pairing")
            if app.buttons["pairing.cancel"].exists {
                app.buttons["pairing.cancel"].tap()
            } else {
                dismissASheet()
            }
        }
        _ = app.openSettingsTab()
    }

    /**
     * The claim that the setting is a setting.
     *
     * Light is chosen, the process is killed, and the app is launched again. Two
     * things are then true or the feature does not work: the picker still reads
     * Light, and the screen is still light. The second is the one that matters —
     * a preference that is stored and not applied reads back perfectly.
     */
    private func theChoiceSurvivesARelaunch() throws {
        try choose(.light)
        app.terminate()
        app.launch()

        // Measured before anything is tapped: this is the first frame of a cold
        // launch, which is where a flash of the wrong scheme would show.
        // Any of the three first frames counts as "up": the session list for a
        // paired phone, the pairing field, or — since the login became the first
        // screen — the address field in front of it.
        XCTAssertTrue(app.buttons["sessions.more"].waitForExistence(timeout: 60)
                      || app.textFields["pairing.field"].waitForExistence(timeout: 5)
                      || app.textFields["serverLogin.address"].waitForExistence(timeout: 5),
                      "the app should come back up")
        expecting = .light
        capture("relaunch-01-light-on-launch")

        XCTAssertTrue(app.openSettingsTab(), "Settings should be reachable after a relaunch")
        try openTheAppearancePage()
        let picker = app.segmentedControls["appearance.theme"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertTrue(picker.buttons["Light"].isSelected,
                      "the stored choice should still be the chosen segment")
        capture("relaunch-02-settings-still-light")
        // Back to the Settings root before `choose`, which starts from there.
        leaveTheAppearancePage()

        // And back to System, which is what a fresh install has and what the
        // next run should start from. `choose` walks in and back out again, so
        // the last leg opens the page one more time rather than reaching for a
        // picker that is no longer on screen.
        try choose(.dark)
        try openTheAppearancePage()
        let system = app.segmentedControls["appearance.theme"].buttons["System"]
        if system.waitForExistence(timeout: 5) { system.tap() }
        leaveTheAppearancePage()
    }

    // MARK: - Arriving

    private func connectToTheLiveHost() throws {
        let field = app.textFields["pairing.field"]
        if field.waitForExistence(timeout: 25) {
            expecting = .dark
            try? "ready\n".write(toFile: readyFile, atomically: true, encoding: .utf8)
            let code = waitForCode(timeout: 240)
            XCTAssertEqual(code.count, 6, "the harness never wrote six digits to TD_CODE_FILE")
            field.tap()
            field.typeText(code)
        }
        try waitForConnected(timeout: 240)
    }

    private func pairWithTheStandIn() throws {
        let field = app.textFields["pairing.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "the app should be at the pairing screen")
        field.tap()
        field.typeText(try freshCode())
        /*
         * Wait for the tab bar before touching a tab.
         *
         * Redeeming a code is not arriving: the machine refuses the device until
         * a human approves it, which the stand-in does after `--approve-after`
         * milliseconds, and the pairing and approval screens have no tab bar at
         * all. Reaching for "Sessions" in that gap does not fail with "no tab
         * bar" — the label matches something else on the screen and the failure
         * reads *"Multiple matching elements found"*, which describes the query
         * rather than the state and sent this looking in the wrong place once.
         */
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 120),
                      "the machine never approved this device")
        app.openSessionsTab()
        try waitForConnected(timeout: 90)
    }

    /// Mint a code on the stand-in, now. Its control server is the human at the
    /// Mac; approval is deliberately not something software does for itself.
    private func freshCode() throws -> String {
        guard let url = URL(string: "http://\(control)/pair") else {
            throw XCTSkip(Self.noStandIn)
        }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            throw XCTSkip("\(Self.noStandIn) (\(control) did not answer /pair)")
        }
        let digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { $0.isNumber }
        guard digits.count >= 6 else { throw XCTSkip("\(control) answered \(text)") }
        return String(digits.prefix(6))
    }

    private func waitForConnected(timeout: TimeInterval) throws {
        let pill = app.descendants(matching: .any).matching(identifier: "connection.pill").firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // The pill is only drawn while the connection is worth mentioning —
            // see `ConnectionGrace`. A session list with rows on it is the other
            // way of knowing, and on a fast connection it is the only one.
            if pill.exists && pill.label.contains("Connected") { return }
            if app.buttons["sessions.new"].exists || app.buttons["sessions.more"].exists { return }
            usleep(500_000)
        }
        capture("zz-never-connected")
        XCTFail("never reached Connected; the pill said \(pill.exists ? pill.label : "nothing")")
    }

    private func waitForCode(timeout: TimeInterval) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let raw = try? String(contentsOfFile: codeFile, encoding: .utf8) {
                let digits = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if digits.count == 6 { return digits }
            }
            usleep(400_000)
        }
        return ""
    }

    private func type(_ text: String) throws {
        // Tapping the terminal, which is the only way in since the toolbar's
        // keyboard button was deleted — *"we don't need keyboard button also,
        // even in terminal pages, even on copilot pages."*
        let terminal = app.descendants(matching: .any).matching(identifier: "terminal.view").firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 30), "the terminal screen should be up")
        if !app.keyboards.firstMatch.exists {
            terminal.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 20),
                          "tapping the terminal should raise a keyboard")
        }
        if app.buttons["Continue"].exists { app.buttons["Continue"].tap() }
        app.typeText(text)
    }

    /// Put a sheet away when it has no Done of its own reachable — a swipe from
    /// the middle of the screen downwards, which is what a person does.
    private func dismissASheet() {
        let window = app.windows.element(boundBy: 0)
        let top = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let bottom = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        top.press(forDuration: 0.05, thenDragTo: bottom)
        sleep(1)
    }

    // MARK: - The frames, and the measurement

    /**
     * A frame, saved where a person can open it — and checked.
     *
     * The check is the reason this is not `ReleaseShotsUITests.capture`. It
     * decodes the PNG the Simulator just produced and averages the relative
     * luminance of its pixels, then asserts that the number is on the right side
     * of the gap for the scheme the walk believes it is in. That is a weak claim
     * about design and a very strong claim about the thing being tested: it
     * fails, by name, on any screen that did not change appearance with the rest
     * of the app.
     *
     * Every eighth pixel in each direction, which is 64× less work and — on a
     * 1206×2622 frame — still nineteen thousand samples. The number being
     * measured is a mean over a whole screen; sampling it changes the third
     * decimal place and not the verdict.
     */
    @discardableResult
    private func capture(_ name: String, measured: Bool = true) -> Double {
        clearBanners()
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        if !shots.isEmpty {
            try? FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png"))
        }

        let luminance = Self.averageLuminance(of: shot.image)
        add(XCTAttachment(string: "\(name): mean luminance \(luminance), expecting \(expecting.rawValue)"))
        guard measured else { return luminance }
        XCTAssertTrue(expecting.luminanceRange.contains(luminance),
                      "\(name) was photographed in \(expecting.rawValue) mode but its mean "
                      + "luminance is \(String(format: "%.3f", luminance)), outside "
                      + "\(expecting.luminanceRange) — this screen did not follow the appearance")
        return luminance
    }

    /**
     * Mean brightness of an image, 0…1.
     *
     * The luma weights, applied to the **gamma-encoded** channels rather than to
     * linearised ones — so this is perceived brightness, not the relative
     * luminance the contrast arithmetic in `AppearanceTests` computes. That is
     * deliberate and it is why the two are not shared: linearising would push
     * every dark screen into the third decimal place and cluster the light ones
     * near 1, which makes a threshold harder to state and no more meaningful.
     * The question here is only "did this screen change sides".
     */
    static func averageLuminance(of image: UIImage) -> Double {
        guard let cgImage = image.cgImage else { return -1 }
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return -1 }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var total = 0.0
        var count = 0
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                let index = (y * width + x) * 4
                let red = Double(pixels[index]) / 255
                let green = Double(pixels[index + 1]) / 255
                let blue = Double(pixels[index + 2]) / 255
                total += 0.2126 * red + 0.7152 * green + 0.0722 * blue
                count += 1
            }
        }
        return count == 0 ? -1 : total / Double(count)
    }
}
