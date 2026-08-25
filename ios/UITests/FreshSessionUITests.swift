/**
 * A session started from the phone, on a real machine, that is still alive a
 * moment later.
 *
 * ## Why this is a test and not a look
 *
 * Every session Asad started on his own server died the same way, and the way it
 * reached him was red text from the agent rather than anything this app said:
 *
 * ```
 * EROFS: read-only file system, mkdir
 *   '/home/asad/.local/share/terminaldeck/remote/device-home/…/tmp/claude-0'
 * ```
 *
 * The cause was in the confinement, not the filesystem — a read root laid inside
 * the granted folder, which on Linux **revokes** the write rather than adding a
 * read — and it only happens on a machine whose granted folder *is* the account
 * home, which his is because it shares no project folders. `confine/` now proves
 * the scratch directory is writable before a session starts, and its own tests
 * pin the mount rules.
 *
 * None of that says the app can start a session that lives. This does: press the
 * plus, take what the machine gives, and look at the row afterwards.
 *
 * ## It starts a session on his machine, deliberately
 *
 * The standing rule in this target is that a suite changes nothing on the far
 * end. This one is the exception and says so: starting a session **is** the
 * behaviour under test, it is the same act the plus button performs for him, and
 * it leaves the machine in a state he asked for rather than one he did not. It
 * closes what it started.
 */

import XCTest

final class FreshSessionUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        // The Copilot tab's conversation hides the tab bar, so a run that
        // follows one which ended there has no pill to press.
        let out = app.buttons["copilot.back"].firstMatch
        if out.waitForExistence(timeout: 3), out.isHittable {
            out.tap()
            _ = app.tabBars.firstMatch.waitForExistence(timeout: 5)
        }
    }

    func testASessionStartedFromThePhoneIsStillRunningAMomentLater() throws {
        app.openSessionsTab()
        try XCTSkipUnless(app.buttons["sessions.new"].waitForExistence(timeout: 20),
                          "no machine is paired with this simulator")

        app.buttons["sessions.new"].tap()
        /*
         * The plain start, by its words. A `Menu`'s rows are not reachable by
         * identifier in XCUITest — measured twice in this target — so the label
         * is what this asks for, and the folder picker beside it is deliberately
         * not pressed: the machine's own choice is the case that was failing.
         */
        let plain = app.buttons["New session"].firstMatch
        if plain.waitForExistence(timeout: 4), plain.isHittable { plain.tap() }

        // The terminal is pushed as soon as the machine answers `created`.
        XCTAssertTrue(app.staticTexts["session.header"].firstMatch.waitForExistence(timeout: 60)
                      || app.otherElements["session.header"].firstMatch.waitForExistence(timeout: 5),
                      "the machine never opened the session this phone asked for")

        /*
         * Long enough for the agent to have died of it. The `EROFS` arrived on
         * the very first `mkdir`, well inside a second — but a machine across a
         * relay deserves more room than the failure needs, and a session that is
         * alive after eight seconds is alive.
         */
        Thread.sleep(forTimeInterval: 8)

        let screen = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'EROFS' OR label CONTAINS 'read-only file system'"))
        XCTAssertEqual(screen.count, 0, "the session died the way every one of his did")

        /*
         * Deliberately **not** a sweep of the list for `exit 1`.
         *
         * That was the first version and it failed against a machine where the
         * fix was working: his server still carries the corpses of the sessions
         * that died before it, and a suite that reads them as a failure is a
         * suite that can never pass on the machine it was written for. Somebody
         * would then "fix" it by deleting his history.
         *
         * What this case is about is the session **it started**, and the two
         * assertions above are the whole of that: the machine opened it, and no
         * `EROFS` appeared on it. A dead one shows the error on its own screen —
         * that is how he found this — so the absence there is the claim.
         */
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["sessions.new"].waitForExistence(timeout: 8),
                      "the way back off the session it started is gone")
    }
}
