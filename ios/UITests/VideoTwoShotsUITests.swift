/**
 * A photograph of every screen the 2026-08-25 6:42 PM recording named, and
 * nothing else.
 *
 * The nine requirements are written down in `.review/2026-08-25-video-2.md`.
 * Six of them are things a person can only judge by looking — which edge a pill
 * sits on, whether a title is centred, whether a control is gone, whether a
 * black band is gone — so this suite exists to produce the frames rather than to
 * assert on them. The assertions it does make are the weak kind on purpose:
 * *this control is no longer on the screen*, which is exactly what was asked for
 * and the one thing a screenshot cannot state.
 *
 * ## It is READ ONLY, and that is not a style choice
 *
 * The Simulator this runs on is paired with a **real** machine of his, with real
 * sessions on it. `SessionPageUITests` may open and bind a window because it owns
 * what it opens; this suite owns nothing. So it navigates and photographs and
 * does no more: it never types, never sends, never opens or closes a browser
 * window, never binds or detaches one, never creates or ends a session. Tapping a
 * session row attaches a viewer to a session that is already running, which is
 * what looking at it means; nothing here writes to the far end.
 *
 * ## It skips rather than fails
 *
 * No paired machine, no sessions, no browser windows, no artifacts panel — every
 * one of those is the product working and none of them is this suite's business.
 *
 *     TEST_RUNNER_TD_SHOTS=/tmp/video2 xcodebuild test \
 *       -only-testing:TerminalDeckUITests/VideoTwoShotsUITests …
 */

import XCTest

final class VideoTwoShotsUITests: XCTestCase {

    private var app: XCUIApplication!

    /// Where the frames land, so they can be looked at outside the result
    /// bundle. Silent when unset — a photograph is a deliverable, not a
    /// condition of the run.
    private var shots: String { ProcessInfo.processInfo.environment["TD_SHOTS"] ?? "" }

    private static let noMachine =
        "This phone is not paired with a running host, so there is nothing to photograph."

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()

        let paired = app.buttons["sessions.new"].waitForExistence(timeout: 25)
            || app.buttons["sessions.more"].exists
        try XCTSkipUnless(paired, Self.noMachine)
    }

    /**
     * R2, R3, R4 — the session header in both modes.
     *
     * > *"switch this button and these three dots — I ask you to keep these two
     * > in the right side, on top right corner, not in one pill with the go
     * > back… it should stay centralized. It should not move according to the
     * > buttons top of it."*
     */
    func testTheSessionHeaderInBothModes() throws {
        capture("01-sessions-home")

        let row = firstSessionRow()
        try XCTSkipUnless(row.waitForExistence(timeout: 10), "no session to open")
        row.tap()

        let actions = app.buttons["terminal.actions"]
        try XCTSkipUnless(actions.waitForExistence(timeout: 20), "the session never drew its header")
        capture("02-session-terminal-header")

        // R2/R3: both controls are on the trailing half of the bar now, and Back
        // is not sharing a pill with them. Measured rather than eyeballed,
        // because "on the right" is the whole requirement.
        let width = app.frame.width
        XCTAssertGreaterThan(actions.frame.midX, width / 2,
                             "the … should be on the trailing edge, not beside Back")

        let mode = app.buttons["terminal.mode"]
        guard mode.waitForExistence(timeout: 10) else {
            capture("03-session-no-chat-offered")
            return
        }
        XCTAssertGreaterThan(mode.frame.midX, width / 2,
                             "the mode switch should be on the trailing edge, not beside Back")

        mode.tap()
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: 10)
        capture("04-session-chat-header")

        // R1, when the far session happens to be in a state a sentence cannot
        // reach. Photographed when it is there; not a failure when it is not,
        // because a healthy session is the common case.
        if app.descendants(matching: .any).matching(identifier: "chat.notready").firstMatch.exists {
            capture("05-chat-not-ready")
        }

        leave()
    }

    /**
     * R8 — the Browser tab, which must not lead anywhere near a terminal.
     *
     * > *"this page should be purely for only browser, not for terminal too…
     * > here I should be able to see all the browsing windows. That's all, very
     * > simple."*
     *
     * And R5/R6 on the window itself: no keyboard verb, no expand verb.
     */
    func testTheBrowserTabIsOnlyBrowser() throws {
        try XCTSkipUnless(app.openBrowserTab(), "the Browser tab was not reachable")
        capture("06-browser-home")

        let rows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'browser.machine.row.'"))
        try XCTSkipUnless(rows.count > 0, "this machine is casting no windows")
        rows.element(boundBy: 0).tap()

        let stage = app.descendants(matching: .any)
            .matching(identifier: "browser.machine.window.stage").firstMatch
        try XCTSkipUnless(stage.waitForExistence(timeout: 20), "the window never drew a page")
        capture("07-browser-window")

        // The three things the recording asked to be gone.
        XCTAssertFalse(app.buttons["browser.machine.window.session"].exists,
                       "the Browser tab must not route into a terminal session")
        XCTAssertFalse(app.buttons["browser.machine.window.keyboard"].exists,
                       "no separate keyboard button in the browser window")
        XCTAssertFalse(app.buttons["browser.machine.window.size"].exists,
                       "no expand verb, and so no black band under the page")

        leave()
    }

    /**
     * R9 — Artifacts, which must be prototypes rather than a file browser.
     *
     * > *"artifact should not show the MD files. It should be only for purely the
     * > prototypes."*
     *
     * Photographed rather than asserted: whether a given machine has any
     * prototype in the folder it is pointed at is not this suite's business, and
     * the rule itself is pinned by `artifacts.test.ts` at the end that decides it.
     */
    func testTheArtifactsPanel() throws {
        try XCTSkipUnless(app.openSettingsTab(), "Settings was not reachable")
        let row = app.descendants(matching: .any)
            .matching(identifier: "machine.tools.artifacts").firstMatch
        try XCTSkipUnless(row.waitForExistence(timeout: 10), "this machine offers no Artifacts panel")
        row.tap()
        _ = app.buttons["panel.artifacts.refresh"].waitForExistence(timeout: 20)
        capture("08-artifacts")
    }

    // MARK: - Getting about

    /// The first session on the list, by identifier rather than by position:
    /// `session.details` and the archived row are buttons on this screen too.
    private func firstSessionRow() -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'session.' AND identifier != 'session.details'")
        ).element(boundBy: 0)
    }

    /// Back out of whatever was pushed, so the next case starts on a tab rather
    /// than inside the last one's screen.
    private func leave() {
        for _ in 0 ..< 3 {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            guard back.exists else { return }
            back.tap()
            if app.buttons["sessions.new"].waitForExistence(timeout: 3) { return }
        }
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
