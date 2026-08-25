/**
 * The iOS release gate, walked once end to end, with a photograph at every stop.
 *
 * `RELEASE-CHECK.md` lists six things about this app that have to be true before
 * anything ships: the tab bar with Machines inside Settings, the tab pill hidden
 * inside a session and inside a localhost page, a Back button that is live after
 * a same-document navigation, GitHub sign-in, no notification spam, and a
 * localhost list that folds, groups and renames. Five of those six had never been
 * looked at on a screen — the pass that built them was written, reported as
 * verified, and never compiled. This file is the answer to *"verify in the
 * simulator, and screenshot"* being a sentence somebody has to be awake for.
 *
 * ## Why one case rather than six
 *
 * Because the expensive part is not the assertion, it is arriving. Pairing takes
 * a code the host mints on demand and a device it then approves, and a fresh
 * `XCUIApplication` per case would pay that four times and hand three of the four
 * a phone whose state the previous case left behind. The tour is written in the
 * order a person would walk it — list, machines, localhost, a page, a session —
 * and each stop asserts what it came for before moving on, so a failure names the
 * stop rather than "the tour".
 *
 * The single-case shape has one real cost and it is worth stating: a failure
 * stops the walk, so the frames after it are not taken. That is the right trade
 * here. The frames exist to be *looked at* by somebody deciding whether to ship,
 * and a set of frames taken after an assertion failed is a set of frames of an
 * app in a state nobody intended.
 *
 * ## What it needs, and why it skips without it
 *
 * A real desktop. Not `ios/Harness/run.sh host` — that stand-in answers `list`,
 * `attach`, `create` and the dev-server verbs and implements **no** `ports` or
 * `tunnel` handler at all, so the Localhost tab is permanently empty against it
 * and three of the five stops below would be photographs of an empty screen.
 * What this needs is the product's own host:
 *
 *     HOME=/private/tmp/tdios2 node out/headless/host.mjs &
 *     ios/Harness/run.sh live folder --state "$HOME/Library/Application Support/terminaldeck" \
 *         --path /private/tmp/tdios2/work
 *     node /tmp/pushstate-server.mjs &      # any page whose links are pushState
 *     TEST_RUNNER_TD_READY_FILE=… TEST_RUNNER_TD_CODE_FILE=… TEST_RUNNER_TD_SHOTS=… \
 *       xcodebuild test … -only-testing:TerminalDeckUITests/ReleaseShotsUITests
 *
 * The ready-file/code-file handshake is `LiveTransferUITests`', for its reason: a
 * pairing code lives sixty seconds and a Simulator takes longer than that to
 * build, install and launch, so the code cannot be minted before the run — the
 * phone says when it is standing at the field and the Mac answers with six
 * digits.
 *
 * Without `TD_READY_FILE` every case skips, which is this target's standing rule.
 * A suite that goes red on a laptop with nothing listening is a suite that gets
 * deleted in a week.
 *
 * ## The one thing it deliberately does not prove
 *
 * That a long press still selects. `TerminalScrollUITests` records the
 * measurements: XCUITest cannot synthesise a stationary hold longer than about
 * six tenths of a second, and `TerminalGestures.selectionHold` is 0.7. That
 * gesture is on `ios/WhatToTest.md` for a person with a real thumb, and writing a
 * green test for it here by lowering the constant until the tool could reach it
 * would be testing the tool.
 */

import XCTest

final class ReleaseShotsUITests: XCTestCase {

    /**
     * The page the Back-button stop navigates. Any port will do — the number is
     * read back off the row rather than assumed — but it has to be a page whose
     * links call `pushState`, because that is the navigation the bug was about.
     * `.harness/.devsite` is not it: its nav is three real `href`s, which fire
     * `WKNavigationDelegate` and would have made the button work all along.
     */
    private static let pushStatePort = "4321"

    private var app: XCUIApplication!

    private func env(_ name: String) -> String {
        ProcessInfo.processInfo.environment[name] ?? ""
    }

    private var readyFile: String { env("TD_READY_FILE") }
    private var codeFile: String { env("TD_CODE_FILE") }
    private var shots: String { env("TD_SHOTS") }

    private static let notRunning =
        "No live desktop. Start out/headless/host.mjs under its own HOME, grant it a folder, "
        + "and run with TEST_RUNNER_TD_READY_FILE / TD_CODE_FILE set — see this file's header."

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(readyFile.isEmpty, Self.notRunning)

        app = XCUIApplication()
        app.launch()
        try connect()
    }

    // MARK: - The tour

    func testTheReleaseGateOnARealDesktop() throws {
        try fourTabsAndMachinesIsNotOneOfThem()
        try machinesPushesFromSettings()
        try localhostGroupsAndFolds()
        try theBackButtonIsLiveAfterAPushState()
        try aSessionHasNoPillOverItsOutput()
    }

    /**
     * Four tabs, and Machines is not among them.
     *
     * Two of his decisions in one assertion, and they are from different
     * recordings. *"Maybe this machines thing can go inside the settings this
     * page overall"* took Machines off the bar; *"a fourth pill, and the copilot
     * goes leftmost"* put the copilot on it. The count was three between those
     * two moments and this file asserted three; it is four now, which is the
     * later answer and the one that ships.
     *
     * The assertion that matters is still the **absence** of Machines, because
     * a pill that came back would look like a design decision rather than a
     * regression — and "is that four or is that three" is exactly the question a
     * small frame answers badly, which is why the count is here rather than left
     * to the screenshot beside it.
     */
    private func fourTabsAndMachinesIsNotOneOfThem() throws {
        let bar = app.tabBars.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 20), "the tab bar should be on the session list")
        for name in ["Copilot", "Sessions", "Localhost", "Settings"] {
            XCTAssertTrue(bar.buttons[name].exists, "\(name) should be a tab")
        }
        XCTAssertEqual(bar.buttons.count, 4, "four tabs, no more")
        XCTAssertFalse(bar.buttons["Machines"].exists, "Machines moved into Settings")
        capture("01-four-tabs")
    }

    /**
     * Machines is a push, and it **keeps** the tab bar.
     *
     * The rule in `DeckChrome` is not "hide the bar on anything pushed" — it is
     * "hide it on a screen that is the whole thing you came for". Machines is a
     * place you pass through, so it keeps the bar, and a test that only checked
     * the two screens that lose it would let that half rot.
     */
    private func machinesPushesFromSettings() throws {
        XCTAssertTrue(app.openMachinesTab(), "Settings should hold a Machines row that pushes")
        XCTAssertTrue(app.navigationBars.buttons.element(boundBy: 0).exists,
                      "a push, not a sheet — there should be a Back button")
        XCTAssertTrue(app.tabBars.firstMatch.exists,
                      "Machines is a place you pass through; it keeps the bar")
        capture("02-settings-machines-pushed")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["settings.github"].waitForExistence(timeout: 10),
                      "Back should return to Settings")
    }

    /**
     * The localhost list is grouped, and the noise starts folded.
     *
     * Both halves are asserted because either alone is satisfiable by an accident:
     * a screen with one section is "grouped" and a screen with everything folded
     * is not a list. What is checked is that there is more than one section and
     * that at least one of them opens on a tap and says so afterwards — the header
     * carries its own state in its label, which is what makes the fold readable
     * from outside the app at all.
     */
    private func localhostGroupsAndFolds() throws {
        XCTAssertTrue(app.openLocalhostList(),
                      "the localhost list is one row down the Browser tab's menu — see TabNavigation")

        let headers = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'localhost.section.'"))
        XCTAssertTrue(headers.firstMatch.waitForExistence(timeout: 30),
                      "the machine's ports should arrive and be grouped")
        XCTAssertGreaterThan(headers.count, 1, "one section is not a grouping")
        capture("03-localhost-grouped")

        let folded = (0 ..< headers.count)
            .map { headers.element(boundBy: $0) }
            .first { $0.label.contains("Folded") }
        let header = try XCTUnwrap(folded, "nothing on this machine landed in a folded group")
        header.tap()
        XCTAssertTrue(header.label.contains("Open"), "tapping a folded header should open it")
        capture("04-localhost-unfolded")
        header.tap()
    }

    /**
     * The Back button, after a navigation WebKit never told its delegate about.
     *
     * The whole bug: `canGoBack` was only re-read from `WKNavigationDelegate`
     * callbacks, and those do not fire for a `pushState` — which is every route
     * change in every single-page app, i.e. the normal case on a dev server. So
     * the sequence is the assertion. Disabled on arrival, one tap on a link that
     * only pushes history, enabled. Checking the end state alone would pass on a
     * button that had been enabled since the screen opened.
     *
     * `BrowserBackTests` pins the same thing against a real `WKWebView` with no
     * desktop at all. This is here because that one cannot see the button.
     */
    private func theBackButtonIsLiveAfterAPushState() throws {
        let row = app.buttons["port.\(Self.pushStatePort)"]
        try XCTSkipUnless(row.waitForExistence(timeout: 20),
                          "nothing is serving a pushState page on \(Self.pushStatePort)")
        row.tap()

        let back = app.buttons["localhost.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 60), "the page should open with a Back button")
        XCTAssertFalse(app.tabBars.firstMatch.exists,
                       "a page from the machine is the whole thing you came for — no pill")
        // The page has to be *there* before its state means anything: a web view
        // reports the address of a load that has only been started.
        XCTAssertTrue(app.staticTexts["Basket"].waitForExistence(timeout: 30),
                      "the tunnelled page should render")
        XCTAssertFalse(back.isEnabled, "nothing has been navigated yet")

        // By prefix: the anchor's label comes out of the document, and the
        // guillemet in it is one character to WebKit and three to a shell that
        // wrote the page. Matching the words avoids a query that fails on
        // punctuation.
        let link = app.links.matching(NSPredicate(format: "label BEGINSWITH 'Go to Delivery'")).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 15), "the page should offer its pushState link")
        link.tap()
        XCTAssertTrue(app.staticTexts["Delivery"].waitForExistence(timeout: 15),
                      "the link should have changed the route")
        XCTAssertTrue(back.isEnabled,
                      "pushState left a history entry — this is the bug he reported")
        capture("05-back-live-after-pushstate")

        back.tap()
        XCTAssertTrue(app.staticTexts["Basket"].waitForExistence(timeout: 15),
                      "Back should actually go back")
        /*
         * Out by the chevron top left, which is where this case's last claim
         * lives now.
         *
         * It tapped `localhost.done` until this round. There is no Done: the row
         * under a page on this phone is the same six controls as the row under
         * every other browser window — *"top, header and footer, tab bar should
         * be same in all type of browsing windows"* — and closing the tunnel is
         * `Close this window` inside the `…`. Nothing about this case is about
         * that verb; it is about the Back button after a `pushState`, and it
         * needs to get off the page afterwards. Popping the screen is the whole
         * teardown and always was.
         */
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.textFields["browser.address"].waitForExistence(timeout: 15),
                      "leaving the page should return to the list")
    }

    /**
     * A session, with no pill over the bottom of its output.
     *
     * *"when this keyboard is down, see the pill is still there. So inside the
     * session we don't need the pill."* The keyboard is put away first,
     * deliberately — it is the exact frame he was looking at when he said it, and
     * it is the state in which the pill used to be drawn over the last three rows
     * of output.
     *
     * ## What this used to assert, and why the number came out
     *
     * There were two assertions here and the second one was a measurement: the
     * gap between the bottom of the window and the bottom of the terminal had to
     * be **under 40 points**, on the reasoning that the pill's band is about
     * sixty, so anything smaller proved the band was not being reserved.
     *
     * It was the wrong instrument, because a *correct* screen also changes that
     * distance. A phone with a home indicator owes the system the last 34 points,
     * and a terminal that respects them measures 34 — inside the same window the
     * old assertion allowed, and indistinguishable from a terminal drawn flat onto
     * the indicator, which measures 0. So the check could not tell the fix from
     * the bug, and when the safe-area inset went missing — which is what
     * `.ignoresSafeArea(.container, edges: .bottom)` did to it while it was
     * removing the pill's band — this assertion had nothing to say. He reported
     * it instead: *"at the bottom we cannot see some stuff… leave a little space
     * when the keyboard is off."*
     *
     * So the pill's absence is now stated as the pill's absence, which is a
     * question about the accessibility tree with exactly one answer, and the
     * distance is left to the two places that can say something true about it:
     * `TerminalContainerTests`, which measures the inset on a real layout against
     * a stated safe area, and `TerminalBottomInsetUITests`, which photographs it
     * on a running phone in both keyboard states.
     */
    private func aSessionHasNoPillOverItsOutput() throws {
        app.openSessionsTab()

        let new = app.buttons["sessions.new"]
        XCTAssertTrue(new.waitForExistence(timeout: 30),
                      "the host has granted a folder, so New Session should be offered")
        new.tap()
        let inMenu = app.buttons["sessions.newDefault"]
        if inMenu.waitForExistence(timeout: 4) { inMenu.tap() }

        let terminal = app.descendants(matching: .any)["terminal.view"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 60), "the session should open its terminal")
        sleep(4)

        // Enough output to fill the screen, so "reaches the bottom" is a claim
        // about something visible rather than about an empty view's frame.
        try type("for i in $(seq 1 60); do echo \"line $i · terminal deck\"; done\n")
        sleep(3)
        if app.buttons["keys.dismiss"].exists { app.buttons["keys.dismiss"].tap() }
        sleep(2)

        /*
         * The pill, said as the pill.
         *
         * `tabBars` is the whole claim and it does catch the original regression:
         * when `.toolbar(.hidden, for: .tabBar)` was written on the screen rather
         * than on the `TabView`, the bar was still drawn — so it was still in the
         * tree, and this line would have gone red. Nothing here measures a
         * distance any more; see the header for what that measurement could and
         * could not tell apart.
         */
        XCTAssertFalse(app.tabBars.firstMatch.exists, "the pill should be gone inside a session")

        // The frame, for the person deciding whether to ship — with the numbers
        // beside it, because "is the bottom of that terminal in the right place"
        // is a question a small screenshot answers badly.
        let window = app.windows.element(boundBy: 0).frame
        add(XCTAttachment(string: "window \(window)  terminal \(terminal.frame)  "
                          + "gap \(window.maxY - terminal.frame.maxY)"))
        capture("06-session-no-pill")
    }

    // MARK: - Arriving

    /**
     * Pair if this phone has never seen this host, and come straight up if it has.
     *
     * Nothing is unpaired here: a pairing lasts until it is revoked, and a second
     * run finding the host still trusted is that claim holding rather than a
     * convenience.
     */
    private func connect() throws {
        let field = app.textFields["pairing.field"]
        if field.waitForExistence(timeout: 25) {
            capture("00-pairing")
            try? "ready\n".write(toFile: readyFile, atomically: true, encoding: .utf8)
            let code = waitForCode(timeout: 240)
            XCTAssertEqual(code.count, 6, "the harness never wrote six digits to TD_CODE_FILE")
            field.tap()
            field.typeText(code)
            // No tap on a submit button: the field submits itself on the sixth
            // digit, which is behaviour worth proving rather than working around.
        }

        // Long, because a device has to redeem its code, be refused for not being
        // approved yet, and then be approved on the host before the pill can turn
        // green. That refusal is the product declining to let anything in on a
        // code alone.
        let pill = app.descendants(matching: .any).matching(identifier: "connection.pill").firstMatch
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if pill.exists && pill.label.contains("Connected") { return }
            usleep(500_000)
        }
        capture("zz-never-connected")
        XCTFail("never reached Connected; the pill said \(pill.exists ? pill.label : "nothing")")
    }

    /// Wait for the Mac to write six digits. A poll, for the reason
    /// `LiveTransferUITests` gives: there is no event to subscribe to across a
    /// process boundary that is a file on somebody else's filesystem.
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

    /// Put text into the session, raising the keyboard if it is down. The
    /// QuickPath tutorial the system keyboard shows on a fresh Simulator sits
    /// over the key bar, so it is dismissed the way a person would.
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

    // MARK: - The frames

    /**
     * A frame, saved where a person can open it.
     *
     * Attached to the result bundle *and* written to a directory on the Mac, the
     * way `LiveTransferUITests` does it: the attachment is tidy and needs
     * `xcresulttool` to get at, and the file is the one somebody actually looks
     * at. These frames are the deliverable — the whole reason this suite exists is
     * that "verified in the simulator" had been claimed about a target that had
     * never been compiled.
     */
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
