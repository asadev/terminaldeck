/**
 * The copilot screens, on a phone, against the **product's own desktop**.
 *
 * ## Why not the stand-in
 *
 * `ios/Harness/host-standin.ts` sends `CAPABILITIES` — the desktop's list of
 * *every extension this build knows how to serve* — verbatim, and implements a
 * subset of them. It has since grown a real copilot connection (a code, a
 * credential, a hello that is actually checked), which makes it a much better
 * harness than it was; it is still a second implementation, and a stand-in and
 * its client can agree with each other forever. That is not hypothetical in this
 * repository: Electron's missing ChaCha stayed hidden for weeks while 3,628 Node
 * tests passed.
 *
 * So this file stands nothing in. It runs against a desktop assembled by the
 * product's own code — the same `registerRemoteIpc`, the same `CopilotLinks`
 * with its scrypt-hashed credential, the same `CopilotRuns`, the same sealed
 * channel — on the deployed relay.
 *
 * ## Two desktops, two expectations, and the absence is an assertion too
 *
 * `TD_COPILOT_EXPECTED` says which desktop is on the other end:
 *
 *  - **`no`** — a host with no copilot layer, which is what
 *    `out/headless/host.mjs` still is: `src/headless/host.ts` does not inject
 *    `CopilotRuns`. The correct behaviour of a phone carrying this build is to
 *    show **nothing** — no row, no screen, no explanation of a control that does
 *    not exist on that machine. That is worth a test rather than a shrug,
 *    because *is that row missing because the feature is off, or because the app
 *    crashed drawing it* is not a question a screenshot answers.
 *  - **`yes`** — the window build, which does inject it. Then the phone has to
 *    walk the ceremony: an unconnected device is offered a six-digit field, a
 *    code redeemed over the sealed channel opens the connection, and the screen
 *    behind it fills with what that machine's copilot is actually doing.
 *
 * ## The two codes, and why both arrive through a file
 *
 * Each lives sixty seconds and a Simulator takes longer than that to build,
 * install and launch — so the phone says when it is standing at a field and the
 * Mac answers with six digits. That is the handshake `LiveTransferUITests` and
 * `ReleaseShotsUITests` already use; this needs it twice, because **connecting
 * the copilot is a separate act of authorisation from pairing** and the second
 * code is minted by a different button on a different panel.
 *
 * ## Running it
 *
 * The desktop half is a window build with its own scratch user-data directory —
 * never the copy somebody is working in, which `CLAUDE.md` is explicit about:
 *
 *     mkdir -p /tmp/td-live && cd <repo>
 *     ./node_modules/electron/dist/Electron.app/Contents/MacOS/Electron . \
 *       --user-data-dir=/tmp/td-live --remote-debugging-port=9377 --remote-allow-origins='*'
 *
 * then, with the phone's ready-file watched from a shell that mints
 * `window.deck.startRemotePairing()` and `window.deck.copilotConnectCode(...)`
 * over CDP into the two code files:
 *
 *     TEST_RUNNER_TD_READY_FILE=/tmp/td/ready.txt \
 *     TEST_RUNNER_TD_CODE_FILE=/tmp/td/pair-code.txt \
 *     TEST_RUNNER_TD_COPILOT_CODE_FILE=/tmp/td/copilot-code.txt \
 *     TEST_RUNNER_TD_COPILOT_EXPECTED=yes \
 *     TEST_RUNNER_TD_SHOTS=/tmp/td/live-shots \
 *     xcodebuild test … -only-testing:TerminalDeckUITests/LiveCopilotUITests
 */

import XCTest

final class LiveCopilotUITests: XCTestCase {

    private var app: XCUIApplication!

    private func env(_ name: String) -> String {
        ProcessInfo.processInfo.environment[name] ?? ""
    }

    private var readyFile: String { env("TD_READY_FILE") }
    private var codeFile: String { env("TD_CODE_FILE") }
    private var copilotCodeFile: String { env("TD_COPILOT_CODE_FILE") }
    private var expectsCopilot: Bool { env("TD_COPILOT_EXPECTED") == "yes" }
    private var shots: String { env("TD_SHOTS") }

    private static let notRunning =
        "No live desktop. See this file's header — the stand-in will not do, and the two codes "
        + "arrive through files because each lives sixty seconds."

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(readyFile.isEmpty, Self.notRunning)

        app = XCUIApplication()
        app.launch()
        try connect()
    }

    // MARK: - The walk

    func testTheCopilotAgainstARealDesktop() throws {
        try theTabsAreFourWithTheCopilotFirst()
        if expectsCopilot {
            try theCeremonyIsWalkedAgainstARealDesktop()
        } else {
            try theCopilotIsDrawnOnlyWhenTheMachineHasOne()
        }
    }

    /**
     * Four tabs, with the copilot the first of them.
     *
     * This asserted the opposite a day ago — *"three tabs, the copilot did not
     * add a fourth"* — and the sentence it was written from has been superseded
     * by one he said with the copilot built and in front of him: *"a fourth
     * pill, and the copilot goes leftmost: Copilot · Sessions · Localhost ·
     * Settings."* The later statement wins; `DeckModel.Tab` carries the whole
     * argument.
     *
     * The **order** is asserted as well as the membership, by frame rather than
     * by label, because that is the half a screenshot answers worst and the half
     * a thumb notices first.
     */
    private func theTabsAreFourWithTheCopilotFirst() throws {
        let bar = app.tabBars.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 20), "the tab bar should be on the session list")
        for name in ["Copilot", "Sessions", "Localhost", "Settings"] {
            XCTAssertTrue(bar.buttons[name].exists, "\(name) should be a tab")
        }
        XCTAssertEqual(bar.buttons.count, 4, "four tabs — no more, and no fewer")
        let copilot = bar.buttons["Copilot"].frame
        for name in ["Sessions", "Localhost", "Settings"] {
            XCTAssertLessThan(copilot.minX, bar.buttons[name].frame.minX,
                              "the copilot should be to the left of \(name)")
        }
        capture("01-four-tabs-copilot-leftmost")
    }

    /**
     * On a desktop with no copilot layer, the phone draws no copilot.
     *
     * **Not** a Connect screen, which names a panel in that machine's Settings:
     * on a build that has no copilot there is no such panel, and sending
     * somebody to look for one is worse than saying nothing. The capability
     * alone does not open this screen — see `CopilotConnection` — so this
     * assertion holds against a host that advertises the name as well as against
     * one that does not.
     */
    private func theCopilotIsDrawnOnlyWhenTheMachineHasOne() throws {
        // The pill is always drawn now — it is structure — so what must be
        // absent is the *screen* offering a code. A short wait rather than none:
        // `welcome` arrives on connection, and asserting absence the instant the
        // list draws would pass for the wrong reason on any machine, including
        // one that does have a copilot.
        XCTAssertTrue(app.openCopilotTab(), "the pill is drawn for every machine")
        let row = app.textFields["copilot.connect.field"]
        XCTAssertFalse(row.waitForExistence(timeout: 8),
                       "this desktop has no copilot layer, so nothing about one belongs on screen")
        capture("02-session-list-no-copilot")
    }

    /**
     * The ceremony, against the machine that actually enforces it.
     *
     * What this proves that the stand-in cannot: the code was minted by
     * `CopilotLinks.mintCode` and hashed by it, the credential this phone stores
     * is 32 real bytes whose scrypt hash is on that Mac's disk, the `copilot.hello`
     * on the next socket is checked against that hash, and the grant drawn on
     * screen is the one the panel wrote. Every one of those is a place a client
     * can be wrong in a way a permissive harness would forgive.
     */
    private func theCeremonyIsWalkedAgainstARealDesktop() throws {
        XCTAssertTrue(app.openCopilotTab(), "the copilot has a pill of its own")
        XCTAssertTrue(app.textFields["copilot.connect.field"].waitForExistence(timeout: 25),
                      "a desktop with a copilot offers an unconnected device a code")
        capture("02-connect-unconnected")

        let field = app.textFields["copilot.connect.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 15),
                      "a paired device has no copilot reach until a code is redeemed")
        capture("03-connect-screen")

        // The second code, through the same file handshake as the first and for
        // the same reason. Written only now, because it dies in sixty seconds.
        try? "copilot\n".write(toFile: readyFile, atomically: true, encoding: .utf8)
        let code = waitForCode(at: copilotCodeFile, timeout: 240)
        XCTAssertEqual(code.count, 6, "the harness never wrote six digits to TD_COPILOT_CODE_FILE")
        field.tap()
        field.typeText(code)

        let status = app.staticTexts["copilot.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 30),
                      "redeeming should open the connection and fill the screen — if this fails, "
                      + "either the credential was not stored or the hello was refused")
        capture("04-connected-to-a-real-desktop")

        // The grant line is drawn from `welcome`/`copilot.grant` rather than
        // from anything this phone decided, so it is the cheapest proof that the
        // tiers on screen are the tiers that machine wrote.
        XCTAssertTrue(app.staticTexts["copilot.grantLine"].exists,
                      "the screen should say what this connection may do")
        XCTAssertTrue(app.staticTexts["copilot.grantLine"].label.hasPrefix("Connected"))
        capture("05-what-this-connection-may-do")
    }

    // MARK: - Getting there

    private func connect() throws {
        let field = app.textFields["pairing.field"]
        if field.waitForExistence(timeout: 25) {
            capture("00-pairing")
            try? "pairing\n".write(toFile: readyFile, atomically: true, encoding: .utf8)
            let code = waitForCode(at: codeFile, timeout: 240)
            XCTAssertEqual(code.count, 6, "the harness never wrote six digits to TD_CODE_FILE")
            field.tap()
            field.typeText(code)
        }

        let pill = app.descendants(matching: .any).matching(identifier: "connection.pill").firstMatch
        let deadline = Date().addingTimeInterval(180)
        var lastNudge = Date.distantPast
        while Date() < deadline {
            if pill.exists && pill.label.contains("Connected") { return }
            // The pill is not drawn on every screen, and approval is a person
            // pressing a button — so where the phone is standing when that
            // happens is not guaranteed. Asking for the session list costs
            // nothing and removes a whole class of "never connected" failures
            // about phones that had connected perfectly.
            //
            // Through the tab bar's own button rather than `openSessionsTab()`,
            // which falls back to `buttons["Sessions"]` anywhere on screen —
            // and "Sessions" is a word this app puts in more than one place, so
            // that query threw *Multiple matching elements found* and failed the
            // run at the nudge rather than at anything being wrong.
            if Date().timeIntervalSince(lastNudge) > 10 {
                lastNudge = Date()
                let tab = app.tabBars.firstMatch.buttons["Sessions"]
                if tab.exists {
                    tab.tap()
                } else {
                    // No tab bar means a pushed screen is on top — a terminal
                    // restored from the last run, most often, which is a real
                    // thing this app does and which has no pill on it. Popping
                    // is the only way back to a screen that answers the question
                    // this loop is asking.
                    let back = app.navigationBars.buttons.element(boundBy: 0)
                    if back.exists { back.tap() }
                }
            }
            usleep(500_000)
        }
        capture("zz-never-connected")
        XCTFail("never reached Connected; the pill said \(pill.exists ? pill.label : "nothing")")
    }

    private func waitForCode(at path: String, timeout: TimeInterval) -> String {
        guard !path.isEmpty else { return "" }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let raw = try? String(contentsOfFile: path, encoding: .utf8) {
                let digits = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if digits.count == 6 { return digits }
            }
            usleep(400_000)
        }
        return ""
    }

    /// A frame, written where a person can open it. Attached to the result
    /// bundle as well, so a run with no `TD_SHOTS` still leaves something to
    /// look at.
    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard !shots.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: shots,
                                                 withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: "\(shots)/\(name).png"))
    }
}
