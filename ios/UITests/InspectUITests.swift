/**
 * Tap an element on the Mac's dev server, say what should change, and have it
 * arrive in an agent's terminal — with a finger, against a real page.
 *
 * `ElementCaptureTests` proves the composition: that a payload becomes the same
 * one line the desktop's `CapturePanel` would produce, byte for byte. What it
 * cannot prove is any of the parts that only exist when there is a page, a
 * tunnel and a socket:
 *
 *  - that the script is actually *in* the tunnelled document, in the client
 *    content world, at document start;
 *  - that a touch — which is not a mouse, has no hover, and lands on whatever is
 *    topmost — produces a capture at all;
 *  - that the tap is cancelled rather than followed, so inspecting a link does
 *    not navigate away from the thing being inspected;
 *  - that the line reaches a **session on the far machine** rather than a
 *    text field on this one.
 *
 * The last of those is the claim worth the most and the one this file can least
 * prove on its own — a phone showing a line has only shown its own screen. So it
 * types a marker that nothing else would produce and leaves the app up long
 * enough for whoever is running it to check the other end:
 *
 *     curl '127.0.0.1:8921/input' | grep TD-INSPECT
 *
 * `/input`, **not** `/scrollback`, and the difference cost an hour to learn.
 * `/scrollback` is what the shell *echoed*, which sounds like the same thing and
 * is not: `zle` repaints its input line, and when the line is wider than the
 * terminal — a phone's terminal, and this line is 120 characters — it shows a
 * moving window into the buffer rather than the whole thing. No rendering width
 * reconstructs it, so a literal check against the echo fails for text that
 * unquestionably arrived. `/input` records the bytes where the desktop hands
 * them to the PTY, after the sealed channel and after `server.ts` authorised
 * them, and nothing the shell does can flatter or hide it.
 *
 * ## Running it
 *
 *     node .harness/.devsite/server.mjs &          # serves on 127.0.0.1:3210
 *     TD_FORCE_SHELL=1 scripts/remote-host.sh --name inspect --relay-port 8920 \
 *       --approve-after 2000 --fresh &
 *     TEST_RUNNER_TD_CONTROL=127.0.0.1:8921 TEST_RUNNER_TD_SHOTS=/tmp/td/shots \
 *     xcodebuild test -project ios/TerminalDeck.xcodeproj -scheme TerminalDeck \
 *       -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
 *       -only-testing:TerminalDeckUITests/InspectUITests
 *
 * `TD_FORCE_SHELL=1` matters: with an agent CLI installed the session lands in a
 * TUI, where the line goes into a prompt box rather than to a shell that echoes
 * it — and the echo is what makes "this reached the far machine" checkable.
 *
 * ## Why the code is typed rather than opened as a link
 *
 * `xcrun simctl openurl` raises a system *Open in "Terminal Deck"?* confirmation.
 * That is a real iOS behaviour, not something the app can or should suppress, and
 * nothing in XCUITest can reach it before the app is running. Typing the link
 * into the pairing field is the same code path from `pair(with:)` onwards and
 * needs no dialog dismissed. `MultiHostUITests` came to the same conclusion.
 *
 * Skips rather than fails when there is nothing to talk to, like every other UI
 * suite here: one that goes red on a laptop with no host running is one that
 * gets deleted.
 */

import XCTest

final class InspectUITests: XCTestCase {

    /// The harness dev server's port — `.harness/.devsite/server.mjs`. It is that
    /// page rather than any page because the assertions name its elements.
    private static let port = 3210

    /**
     * The marker typed as the instruction.
     *
     * Unique enough that finding it in a PTY's scrollback is proof rather than
     * coincidence, and shaped like something a person would actually say, because
     * the string being checked is the one an agent has to read.
     */
    private static let marker = "TD-INSPECT-MARKER"
    private static var instruction: String { "make \(marker) the primary colour" }

    private var app: XCUIApplication!

    /**
     * The harness control server, e.g. `127.0.0.1:8921`.
     *
     * An address rather than a pairing link, and that is not a convenience: **a
     * pairing token is worth sixty seconds**, and a link handed in when the
     * process started is a link that expired while the Simulator was booting. The
     * symptom is not "expired" — it is the relay refusing the *sealed handshake*,
     * because the pairing desk is only open while a token is live — which reads
     * as a crypto failure. So the code is minted at the moment it is used.
     */
    private var control: String { ProcessInfo.processInfo.environment["TD_CONTROL"] ?? "" }
    private var shots: String? { ProcessInfo.processInfo.environment["TD_SHOTS"] }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(control.isEmpty, Self.notRunning)

        app = XCUIApplication()
        app.launch()
        // Pairings live in the Keychain and outlive the process, so without this
        // a second case in the same run starts against whatever the first left —
        // or against a machine from last night that is no longer listening.
        // Through the app's own Forget item rather than a test-only back door.
        forgetEverything()

        try pair(freshCode())
        try XCTSkipUnless(waitForConnected(timeout: 60), "\(Self.notRunning) (never reached Connected)")
    }

    /// The port rows are on the Localhost tab now rather than under the sessions
    /// — see `DeckModel.Tab`. Called by each case rather than from `setUp`,
    /// because one of them starts a session first and that is on the other tab.
    private func openLocalhost() {
        XCTAssertTrue(app.openLocalhostList(),
                      "the localhost list is one row down the Browser tab's menu — see TabNavigation")
    }

    private static let notRunning =
        "A host and a dev server on \(port) are needed. Start them as described at the top of this "
        + "file and pass TEST_RUNNER_TD_CONTROL."

    /// Tap Forget until the pairing screen is what is on screen. The item lives
    /// on the Machines tab now — see `TabNavigation.swift`.
    private func forgetEverything() {
        app.forgetEveryMachine()
    }

    /// Mint a code on the host, now. `/pair` calls the pairing desk's own
    /// `create` — the same call the desktop's panel makes.
    private func freshCode() throws -> String {
        guard let url = URL(string: "http://\(control)/pair") else {
            throw XCTSkip("\(control) is not an address")
        }
        var answer: String?
        let done = expectation(description: "minted")
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                answer = json["code"] as? String
            }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 20)
        guard let answer, !answer.isEmpty else {
            throw XCTSkip("\(Self.notRunning) (\(control) did not answer /pair)")
        }
        return answer
    }

    private func pair(_ code: String) throws {
        let field = app.textFields["pairing.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the pairing screen should be up")
        field.tap()
        field.typeText(code)
        app.buttons["pairing.submit"].tap()
    }

    // MARK: - The whole path

    /**
     * A tap on the page becomes a described element, and the description becomes
     * one line in a terminal on the other machine.
     *
     * Written as one case rather than four because every step needs the one
     * before it to have happened to a *live* page: there is no way to arrive at
     * "the sheet is up" without having tapped something in a tunnelled document,
     * and re-establishing the tunnel per assertion would take four times as long
     * to prove the same thing once.
     */
    func testTappingAnElementSendsOneLineToTheAgent() throws {
        // A session for the line to land in. The button only exists when the host
        // advertises `create`, which the harness does.
        try ensureASessionExists()

        openLocalhost()
        let row = app.buttons["port.\(Self.port)"]
        XCTAssertTrue(row.waitForExistence(timeout: 25),
                      "the dev server on \(Self.port) should be offered without anyone typing a port")
        row.tap()

        // The screen has arrived. Reload rather than Done, which no longer
        // exists — the row under a page on this phone is the same six controls
        // as the row under every other browser window, and the verb that tore
        // the tunnel down is `Close this window` inside the `…`. The next line is
        // what says the page itself is really there.
        XCTAssertTrue(app.buttons["localhost.reload"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Served from the Mac"].waitForExistence(timeout: 30),
                      "the page never rendered — the tunnel did not carry the document")
        capture("10-page-loaded")

        // Inspect on. The hint is the visible half of the mode, and the reason a
        // cancelled tap does not read as a broken page.
        let inspect = app.buttons["localhost.inspect"]
        XCTAssertTrue(inspect.waitForExistence(timeout: 10))
        inspect.tap()
        XCTAssertTrue(app.staticTexts["localhost.inspectHint"].waitForExistence(timeout: 5),
                      "turning inspect on should say what a tap will now do")
        capture("11-inspecting")

        // Tap the page's own button. A real touch through the web view, which is
        // the only way to exercise the click-capture path the script installs.
        let payNow = app.webViews.buttons["Pay now"]
        XCTAssertTrue(payNow.waitForExistence(timeout: 15), "the page's button should be reachable")
        payNow.tap()

        // The sheet, and the selector it worked out.
        let selector = app.staticTexts["inspect.selector"]
        XCTAssertTrue(selector.waitForExistence(timeout: 15),
                      "tapping an element while inspecting should describe it")
        capture("12-sheet-open")

        // `#pay-now` is unique in that document, so the id wins outright — which
        // is `computeSelector`'s first preference and the most stable answer.
        XCTAssertEqual(selector.label, "#pay-now",
                       "a unique id should win over a positional path")

        // Still on the page it was tapped on: the click was cancelled rather than
        // followed. A `<button>` in a form would otherwise have submitted.
        XCTAssertTrue(app.staticTexts["Served from the Mac"].exists,
                      "the tap navigated instead of being captured")

        // What the agent will receive, before it is sent. This is the string the
        // desktop would produce for the same element, and the reason `oneLine`
        // was ported rather than approximated.
        let instructionField = app.textFields["inspect.instruction"]
        XCTAssertTrue(instructionField.waitForExistence(timeout: 5))
        instructionField.tap()
        instructionField.typeText(Self.instruction)

        let preview = app.staticTexts["inspect.preview"]
        if !preview.exists {
            app.staticTexts["What the agent will receive"].tap()
        }
        XCTAssertTrue(preview.waitForExistence(timeout: 10),
                      "the sheet should show the exact line before it is sent")
        let line = preview.label
        capture("13-preview")

        // One line, and the instruction leads. Both are `composeSend`'s contract.
        XCTAssertFalse(line.contains("\n"), "the composed line must never contain a newline")
        XCTAssertTrue(line.hasPrefix(Self.instruction), "the instruction goes first; line was: \(line)")
        XCTAssertTrue(line.contains("[browser: "), "the context is missing; line was: \(line)")
        XCTAssertTrue(line.contains("element `#pay-now`"), "line was: \(line)")
        XCTAssertTrue(line.contains("<button>"), "the tag should be named; line was: \(line)")
        XCTAssertTrue(line.contains("text \"Pay now\""), "the label should be named; line was: \(line)")

        app.buttons["inspect.send"].tap()

        // The toast is the app's own word for it. The claim that matters is
        // checked on the host, against /input, while this is still up.
        XCTAssertTrue(app.staticTexts["localhost.toast"].waitForExistence(timeout: 10),
                      "sending should say where it went")
        capture("14-sent")
        sleep(10)
    }

    /**
     * Wider walks up the ancestor chain.
     *
     * The correction, and the one part of this screen with no counterpart on the
     * desktop: a fingertip lands on whatever wrapper is topmost and there is no
     * second, more precise gesture to offer. Without this the recourse is to tap
     * again and hope.
     */
    func testWiderSelectsTheEnclosingElement() throws {
        openLocalhost()
        let row = app.buttons["port.\(Self.port)"]
        XCTAssertTrue(row.waitForExistence(timeout: 25))
        row.tap()
        XCTAssertTrue(app.staticTexts["Served from the Mac"].waitForExistence(timeout: 30))
        app.buttons["localhost.inspect"].tap()

        // A row inside a card inside <main>: something with somewhere to go up to.
        let total = app.webViews.staticTexts["Total"]
        XCTAssertTrue(total.waitForExistence(timeout: 15))
        total.tap()

        let selector = app.staticTexts["inspect.selector"]
        XCTAssertTrue(selector.waitForExistence(timeout: 15))
        let tapped = selector.label
        capture("15-narrow")

        let wider = app.buttons["inspect.wider"]
        XCTAssertTrue(wider.waitForExistence(timeout: 5))
        XCTAssertTrue(wider.isEnabled, "there are ancestors above this, so Wider should be live")
        wider.tap()

        // The selector changes, and it changes towards the document: the new one
        // is the old one's parent, so the old path is longer than the new.
        let deadline = Date().addingTimeInterval(10)
        while selector.label == tapped && Date() < deadline { usleep(200_000) }
        XCTAssertNotEqual(selector.label, tapped, "Wider should have selected the enclosing element")
        capture("16-wider")

        // And back again, which is the half that makes it a control rather than a
        // one-way trip.
        app.buttons["inspect.narrower"].tap()
        let back = Date().addingTimeInterval(10)
        while selector.label != tapped && Date() < back { usleep(200_000) }
        XCTAssertEqual(selector.label, tapped, "Narrower should come back to what was tapped")
    }

    /**
     * A password field's value never leaves the page.
     *
     * The guest script withholds it and `sanitizeAttributes` withholds it again,
     * and this is the only place both halves are exercised at once against a real
     * DOM. It matters more here than on the desktop: the line this produces is
     * typed into an agent's prompt, which is written to that agent's transcript
     * on somebody's disk.
     */
    func testInspectingIsOffUntilItIsTurnedOn() throws {
        openLocalhost()
        let row = app.buttons["port.\(Self.port)"]
        XCTAssertTrue(row.waitForExistence(timeout: 25))
        row.tap()
        XCTAssertTrue(app.staticTexts["Served from the Mac"].waitForExistence(timeout: 30))

        // No hint, because the mode is off.
        XCTAssertFalse(app.staticTexts["localhost.inspectHint"].exists)

        // A tap on the page with inspect off must do nothing of ours at all —
        // no sheet. The page's own handlers are untouched, which is the point:
        // the browser is a browser until somebody says otherwise.
        let payNow = app.webViews.buttons["Pay now"]
        XCTAssertTrue(payNow.waitForExistence(timeout: 15))
        payNow.tap()
        XCTAssertFalse(app.staticTexts["inspect.selector"].waitForExistence(timeout: 4),
                       "an element was described without inspect mode being on")
    }

    // MARK: - Steps

    /**
     * Make sure the machine has at least one session, so there is somewhere for
     * the line to go. Reuses one when there is one: this suite is about
     * inspecting, not about creating sessions.
     *
     * The insistent loop back to the list is not defensiveness for its own sake.
     * A created session **opens itself** — the tap that starts one is the tap
     * that opens it — so this always ends up on a terminal, and the port list is
     * a screen behind it. The first version tapped back once and trusted it; when
     * that tap missed, the next assertion looked for a port row on a terminal
     * screen and reported *"the dev server should be offered"*, which sent the
     * failure in entirely the wrong direction.
     */
    private func ensureASessionExists() throws {
        if app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session.'")).count > 0 { return }

        let new = app.buttons["sessions.new"]
        XCTAssertTrue(new.waitForExistence(timeout: 30),
                      "the harness advertises `create`, so the button should be there")
        new.tap()
        // By identifier: the toolbar button is *labelled* "New session" too, so
        // a query on the words matches two elements once the menu is open.
        if app.buttons["sessions.newDefault"].waitForExistence(timeout: 3) {
            app.buttons["sessions.newDefault"].tap()
        }

        _ = app.otherElements["terminal.view"].waitForExistence(timeout: 30)
        try returnToTheList()
    }

    /// Back to the session list, however many screens deep this is.
    private func returnToTheList() throws {
        for _ in 0 ..< 4 {
            if app.buttons["sessions.more"].exists && !app.otherElements["terminal.view"].exists { return }
            let bar = app.navigationBars.firstMatch
            let back = bar.buttons.matching(
                NSPredicate(format: "identifier != 'terminal.actions' AND identifier != 'terminal.mode'")).firstMatch
            if back.exists { back.tap() } else { app.swipeRight() }
            _ = app.buttons["sessions.more"].waitForExistence(timeout: 8)
        }
        XCTAssertTrue(app.buttons["sessions.more"].exists, "never got back to the session list")

        // Creating a session churns the connection, and the port list is cleared
        // when a connection drops — so the list has to be *back* before a missing
        // port row means anything at all.
        XCTAssertTrue(waitForConnected(timeout: 45), "the connection did not come back after starting a session")
    }

    // MARK: - Helpers

    private func waitForConnected(timeout: TimeInterval) -> Bool {
        let pill = app.descendants(matching: .any).matching(identifier: "connection.pill").firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pill.exists && pill.label.contains("Connected") { return true }
            usleep(500_000)
        }
        return false
    }

    /// Attached to the result bundle, and written out to a folder when one is
    /// named — because nobody opens an `.xcresult` to look at a picture.
    private func capture(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        guard let shots else { return }
        try? FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png"))
    }
}
