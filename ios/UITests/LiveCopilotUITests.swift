/**
 * The copilot screens, on a phone, against the **product's own desktop**.
 *
 * ## Why not the stand-in
 *
 * `ios/Harness/host-standin.ts` sends `CAPABILITIES` — the desktop's list of
 * *every extension this build knows how to serve* — verbatim, and implements a
 * subset of them. It does check a `copilot.hello` and does refuse one from a
 * device it does not count as its owner's, which makes it a much better harness
 * than it was; it is still a second implementation, and a stand-in and its
 * client can agree with each other forever. That is not hypothetical in this
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
 *    show **nothing** — no pill, no screen, no explanation of a control that
 *    does not exist on that machine. That is worth a test rather than a shrug,
 *    because *is that pill missing because the feature is off, or because the
 *    app crashed drawing it* is not a question a screenshot answers.
 *  - **`yes`** — the window build, which does inject it, with this phone
 *    approved at pairing time as **My device**. Then the copilot is simply
 *    **there**: four pills the moment the welcome lands, and a screen filled
 *    with what that machine's copilot is actually doing.
 *
 * ## There is no second code any more, and its absence is the headline
 *
 * This file used to walk a ceremony: a six-digit copilot code minted by a
 * different button on a different panel, redeemed over the sealed channel, in
 * exchange for a credential the phone kept in its Keychain. Asad deleted it on
 * 2026-08-19:
 *
 * > *"Instead of giving mobile app separate connection for copilot just make it
 * > like if we are connecting as my device copilot automatically comes, if we
 * > connect as guest then copilot don't come — that's all we need to do instead
 * > of two different connections."*
 *
 * So the strongest thing this file can now prove against a real desktop is a
 * **negative plus an immediacy**: the phone is offered nothing to connect
 * anywhere in the app, and the copilot is nevertheless up, against a Mac that
 * really enforces the rule — `server.ts` writes `welcome.copilot` only for a
 * device whose kind is `mine`, and refuses `copilot.hello` from anything else.
 * A stand-in and its client can agree with each other forever; this cannot.
 *
 * One code still arrives through a file, because pairing still has one: it lives
 * sixty seconds and a Simulator takes longer than that to build, install and
 * launch, so the phone says when it is standing at the field and the Mac answers
 * with six digits. That is the handshake `LiveTransferUITests` and
 * `ReleaseShotsUITests` already use.
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
 * `window.deck.startRemotePairing()` over CDP into the code file. **Approve the
 * phone as "My device"** when the request appears — that approval is the whole
 * of the copilot's authorisation now, and approving it as a guest is the `no`
 * expectation rather than a failure:
 *
 *     TEST_RUNNER_TD_READY_FILE=/tmp/td/ready.txt \
 *     TEST_RUNNER_TD_CODE_FILE=/tmp/td/pair-code.txt \
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
    private var expectsCopilot: Bool { env("TD_COPILOT_EXPECTED") == "yes" }
    private var shots: String { env("TD_SHOTS") }

    private static let notRunning =
        "No live desktop. See this file's header — the stand-in will not do, and the pairing code "
        + "arrives through a file because it lives sixty seconds."

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(readyFile.isEmpty, Self.notRunning)

        app = XCUIApplication()
        app.launch()
        try connect()
    }

    // MARK: - The walk

    func testTheCopilotAgainstARealDesktop() throws {
        if expectsCopilot {
            try theCopilotIsThereWithNothingPressed()
            try theBarIsFourPillsAndTheCopilotIsLeftmost()
        } else {
            try theCopilotIsDrawnOnlyWhenTheMachineHasOne()
        }
        try nothingAnywhereOffersToConnectACopilot()
    }

    /**
     * **The copilot is up, and nobody typed anything.**
     *
     * The single assertion this file exists for since 2026-08-19. This phone
     * paired, was approved at the machine as *My device*, and that is the whole
     * of it — *"if we are connecting as my device copilot automatically comes."*
     *
     * What makes it worth running against a real desktop rather than the
     * stand-in: `server.ts` writes `welcome.copilot` only for a device whose
     * kind is `mine`, and `copilot.hello` is authorised against that same kind
     * on the socket's already-authenticated identity. A phone that got here by
     * guessing — drawing the tab off the capability name, say — would be
     * refused every frame behind it, and the state card is the thing that cannot
     * appear unless the hello was actually accepted.
     */
    private func theCopilotIsThereWithNothingPressed() throws {
        XCTAssertTrue(app.openCopilotTab(),
                      "a phone paired as his own device has a copilot with nothing to press")
        capture("01-copilot-with-nothing-pressed")

        let status = app.staticTexts["copilot.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 30),
                      "the state card should draw — if this fails, the hello was refused, which "
                      + "is what a phone the machine does not count as his would see")
        capture("02-connected-to-a-real-desktop")

        // The grant line is drawn from `welcome`/`copilot.grant` rather than
        // from anything this phone decided, so it is the cheapest proof that
        // what is on screen is what that machine wrote.
        XCTAssertTrue(app.staticTexts["copilot.grantLine"].exists,
                      "the screen should say what this connection may do")
        XCTAssertTrue(app.staticTexts["copilot.grantLine"].label.hasPrefix("Connected"))
        capture("03-what-this-connection-may-do")
    }

    /**
     * **Four pills, and the copilot the first of them.**
     *
     * The **order** is asserted as well as the membership, by frame rather than
     * by label, because that is the half a screenshot answers worst and the half
     * a thumb notices first: *"a fourth pill, and the copilot goes leftmost —
     * Copilot · Sessions · Localhost · Settings."*
     *
     * Reached by going **home from the copilot**, which is the other half of the
     * review this began as: that screen draws no bar of its own, so the only way
     * to be looking at the bar from here is the back button. *"Pill should not
     * be inside the chat box — there should be a back button to go back on
     * home."*
     */
    private func theBarIsFourPillsAndTheCopilotIsLeftmost() throws {
        XCTAssertTrue(app.buttons["copilot.back"].waitForExistence(timeout: 15),
                      "the copilot's only way home")
        XCTAssertFalse(app.tabBars.firstMatch.exists,
                       "the pill must not sit over the chat box")
        app.buttons["copilot.back"].tap()

        let bar = app.tabBars.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 15))
        for name in ["Copilot", "Sessions", "Localhost", "Settings"] {
            XCTAssertTrue(bar.buttons[name].waitForExistence(timeout: 10),
                          "\(name) should be a tab")
        }
        XCTAssertEqual(bar.buttons.count, 4, "four pills on his own machine")
        let copilot = bar.buttons["Copilot"].frame
        for name in ["Sessions", "Localhost", "Settings"] {
            XCTAssertLessThan(copilot.minX, bar.buttons[name].frame.minX,
                              "the copilot should be to the left of \(name)")
        }
        capture("04-four-pills-copilot-leftmost")
    }

    /**
     * On a desktop with no copilot layer, the phone draws no copilot.
     *
     * Three pills, and nothing behind them. **Not** a screen naming a panel in
     * that machine's Settings: on a build that has no copilot there is no such
     * panel, and sending somebody to look for one is worse than saying nothing.
     * The capability alone does not open this screen — see `CopilotConnection` —
     * so this holds against a host that advertises the name as well as against
     * one that does not.
     *
     * It is also, from this end, exactly what a phone paired as a **guest**
     * sees, because `server.ts` strips the capability for a guest rather than
     * merely refusing the verbs.
     */
    private func theCopilotIsDrawnOnlyWhenTheMachineHasOne() throws {
        let bar = app.tabBars.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 20), "the tab bar should be on the session list")
        for name in ["Sessions", "Localhost", "Settings"] {
            XCTAssertTrue(bar.buttons[name].exists, "\(name) should be a tab")
        }
        XCTAssertFalse(app.openCopilotTab(), "no copilot on that machine, no fourth pill")
        XCTAssertEqual(bar.buttons.count, 3, "three pills — no more, and no fewer")
        capture("01-three-pills-no-copilot")
    }

    /**
     * **Nothing anywhere offers to connect a copilot.**
     *
     * Run in both expectations, because it is the deletion itself rather than a
     * property of either desktop. There is no Settings row, no code field and no
     * button that reaches one; the answer to *may this phone use that copilot*
     * is decided once, at the machine, on the approval screen.
     *
     * Asserted by walking Settings rather than by trusting that the view was
     * deleted, because the failure this guards against is a build where somebody
     * put the row back to be helpful — which would be a phone asking for a code
     * that nothing on that machine can mint.
     */
    private func nothingAnywhereOffersToConnectACopilot() throws {
        XCTAssertTrue(app.openSettingsTab(), "Settings should be reachable")
        XCTAssertFalse(app.buttons["settings.copilot"].waitForExistence(timeout: 5),
                       "there is nothing left in Settings to connect")
        XCTAssertFalse(app.textFields["copilot.connect.field"].exists,
                       "there is no copilot code, anywhere, on any screen")
        capture("05-settings-has-nothing-to-connect")
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
