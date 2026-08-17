/**
 * The copilot screens, on a phone, against the **product's own desktop**.
 *
 * ## Why not the stand-in
 *
 * `ios/Harness/host-standin.ts` sends `CAPABILITIES` — the desktop's list of
 * *every extension this build knows how to serve* — verbatim, and implements a
 * handful of them. So it advertises `copilot` and answers no `copilot.*` frame
 * at all. A pass run against it would photograph an empty Copilot screen and
 * report the feature verified, which is exactly what happened to an earlier
 * localhost pass and is the reason `ReleaseShotsUITests` carries the same
 * warning in its own header.
 *
 * What this runs against is `out/headless/host.mjs`: the same `registerRemoteIpc`,
 * `PtyManager`, folder grants and sealed channel the window build links,
 * assembled by `src/headless/host.ts` with no window around it, on the deployed
 * relay. `ios/Harness/live-copilot.sh` stands one up and drives this.
 *
 * ## What it asserts, and why the *absence* is the assertion
 *
 * The desktop half of this feature — `CopilotRuns` injected into the remote
 * server — is not wired into `createHostCore` yet. So a real desktop today
 * advertises no `copilot` capability and sends no `copilot` field in its
 * `welcome`, and the correct behaviour of a phone carrying this build is to show
 * **nothing**: no row on the session list, no screen, no explanation of a switch
 * that does not exist on that machine.
 *
 * That is worth a test rather than a shrug, because it is the property the whole
 * "honest degradation" requirement turns on, and it is the one a screenshot
 * cannot settle on its own — *is that row missing because the feature is off, or
 * because the app crashed drawing it* is not a question a frame answers.
 *
 * When the desktop lands its half, this file is where the other two states go:
 * a machine with a copilot and no grant (the row appears, the screen explains
 * where the switch is), and a machine with `read` (the timeline draws). Both are
 * pinned in `CopilotLinkTests` against the frames; what cannot be pinned there
 * is that the row is reachable with a thumb.
 */

import XCTest

final class LiveCopilotUITests: XCTestCase {

    private var app: XCUIApplication!

    private func env(_ name: String) -> String {
        ProcessInfo.processInfo.environment[name] ?? ""
    }

    private var readyFile: String { env("TD_READY_FILE") }
    private var codeFile: String { env("TD_CODE_FILE") }
    private var shots: String { env("TD_SHOTS") }

    private static let notRunning =
        "No live desktop. Run ios/Harness/live-copilot.sh, which stands one up — see this "
        + "file's header for why the stand-in will not do."

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(readyFile.isEmpty, Self.notRunning)

        app = XCUIApplication()
        app.launch()
        try connect()
    }

    // MARK: - The walk

    func testTheCopilotAgainstARealDesktop() throws {
        try theTabsAreStillThree()
        try theCopilotIsDrawnOnlyWhenTheMachineHasOne()
    }

    /**
     * Three tabs, still, with the copilot in the build.
     *
     * The first thing this feature could have cost. He reconsidered a four-pill
     * bar once already and settled on three — *"maybe this machines thing can go
     * inside the settings"* — so the copilot went onto the Sessions stack rather
     * than onto the bar, and the absence of a fourth pill is the assertion a
     * small screenshot answers worst.
     */
    private func theTabsAreStillThree() throws {
        let bar = app.tabBars.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 20), "the tab bar should be on the session list")
        for name in ["Sessions", "Localhost", "Settings"] {
            XCTAssertTrue(bar.buttons[name].exists, "\(name) should be a tab")
        }
        XCTAssertEqual(bar.buttons.count, 3, "three tabs — the copilot did not add a fourth")
        XCTAssertFalse(bar.buttons["Copilot"].exists, "and it is not one of them")
        capture("01-three-tabs-with-copilot-in-the-build")
    }

    /**
     * On a desktop with no copilot layer, the phone draws no copilot.
     *
     * **Not** the "not shared with this phone" row, which names a switch in that
     * machine's Settings: on a build that has no copilot there is no such switch,
     * and sending somebody to look for one is worse than saying nothing. The
     * capability alone does not open this screen — see `CopilotOffer` — so this
     * assertion holds against a host that advertises the name as well as against
     * one that does not.
     */
    private func theCopilotIsDrawnOnlyWhenTheMachineHasOne() throws {
        let row = app.buttons["copilot.row"]
        // A short wait rather than none: `welcome` arrives on connection, and
        // asserting absence the instant the list draws would pass for the wrong
        // reason on any machine, including one that does have a copilot.
        XCTAssertFalse(row.waitForExistence(timeout: 8),
                       "this desktop has no copilot layer, so nothing about one belongs on screen")
        capture("02-session-list-no-copilot")
    }

    // MARK: - Getting there

    /// The pairing handshake `LiveTransferUITests` and `ReleaseShotsUITests` both
    /// use, for their reason: a code lives sixty seconds and a Simulator takes
    /// longer than that to build, install and launch, so the phone says when it
    /// is standing at the field and the Mac answers with six digits.
    private func connect() throws {
        let field = app.textFields["pairing.field"]
        if field.waitForExistence(timeout: 25) {
            capture("00-pairing")
            try? "ready\n".write(toFile: readyFile, atomically: true, encoding: .utf8)
            let code = waitForCode(timeout: 240)
            XCTAssertEqual(code.count, 6, "the harness never wrote six digits to TD_CODE_FILE")
            field.tap()
            field.typeText(code)
        }

        let pill = app.descendants(matching: .any).matching(identifier: "connection.pill").firstMatch
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if pill.exists && pill.label.contains("Connected") { return }
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
