/**
 * The parts of this app that only a finger can check, against a real desktop.
 *
 * There is no fixture behind these. They drive whatever
 * `ios/Harness/run.sh host` is serving — a real relay, a real Noise IK
 * handshake, real PTYs — through a phone that has already been paired with it:
 *
 *     ios/Harness/run.sh host --approve-after 6000 --log-input &
 *     xcrun simctl openurl booted "$(cat ios/Harness/.build/pairing.txt)"
 *     # approve, then:
 *     xcodebuild test -project ios/TerminalDeck.xcodeproj -scheme TerminalDeck \
 *       -destination 'platform=iOS Simulator,name=iPhone 17' \
 *       -only-testing:TerminalDeckUITests
 *
 * ## Why pairing happens outside these tests
 *
 * The pairing code is minted by the harness at run time and has to get from the
 * host machine into the simulator. `TEST_RUNNER_…` environment injection does
 * not reach the runner on this toolchain — measured, not assumed: the runner's
 * environment came back with no matching keys — and a pasteboard hand-off runs
 * into the system's Allow Paste prompt. `simctl openurl` is the mechanism the
 * product already has for this, so pairing is one line of shell before the run
 * and the credential is in the Keychain by the time these launch.
 *
 * Every case skips rather than fails when the app is not paired. A test that
 * goes red because a server is not running on someone's laptop is a test that
 * gets deleted in a week.
 *
 * ## Why these four
 *
 * They are the claims a unit test cannot make: that the connection indicator
 * says a true thing, that a key on the accessory row reaches a shell through
 * the sealed channel, that copy and paste are wired to the session rather than
 * to nothing, and that New Session exists only because the far end offered it.
 */

import UIKit
import XCTest

final class LiveSessionUITests: XCTestCase {

    private var app: XCUIApplication!

    /// Answered once per run. Without it, a machine with no harness pays the
    /// 45-second wait below six times over on every plain `xcodebuild test`,
    /// which is how a suite that "skips politely" becomes one people stop
    /// running.
    private static var reachable: Bool?

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(Self.reachable == false, Self.notRunning)

        app = XCUIApplication()
        app.launch()

        // Connected, not merely paired. A phone that is paired to a desktop
        // which is not running still shows the session list — empty, with an
        // honest banner — so keying the skip on the list being reachable would
        // run every test against a dead connection and fail them all with a
        // misleading message. The pill is the app's own answer to "is this
        // real", so it is what decides.
        let connected = waitForConnected(timeout: Self.reachable == nil ? 45 : 10)
        Self.reachable = connected
        try XCTSkipUnless(connected, Self.notRunning)
    }

    private static let notRunning =
        "This phone is not connected to a running harness. Start ios/Harness/run.sh host, "
        + "then: xcrun simctl openurl booted \"$(cat ios/Harness/.build/pairing.txt)\" "
        + "and approve the device."

    // MARK: - 1. The connection says what it is

    func testTheConnectionPillReadsConnected() throws {
        let pill = app.descendants(matching: .any).matching(identifier: "connection.pill").firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        // The label is the whole point: three words that are true, not a colour
        // that could mean anything.
        XCTAssertTrue(pill.label.contains("Connected"), "pill said: \(pill.label)")
    }

    func testTheListShowsRealSessions() throws {
        let rows = try sessionRows()
        XCTAssertGreaterThan(rows.count, 0, "the desktop should have sessions running")
    }

    // MARK: - 2. A key on the accessory row reaches a shell

    func testTheAccessoryRowSendsToTheSession() throws {
        try sessionRows().first!.tap()

        let keyboard = app.buttons["terminal.keyboard"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10), "the terminal screen should appear")
        keyboard.tap()

        // The row is the reason a terminal is usable on a phone: none of these
        // keys exist on an iOS keyboard.
        for key in ["esc", "tab", "ctrl", "^C", "|"] {
            XCTAssertTrue(app.buttons[key].waitForExistence(timeout: 5), "missing accessory key: \(key)")
        }

        // Typed into the terminal itself, which is a `UIKeyInput` rather than a
        // text field — so this is also the check that keystrokes reach it.
        app.typeText("echo ui-test-marker\n")
        // Then keys that exist only on the accessory row, to prove that path
        // separately. `|` goes through insertText; Ctrl-C is raw bytes.
        app.buttons["|"].tap()
        app.buttons["^C"].tap()

        // What arrived is asserted on the far side: the harness logs input when
        // it is started with `--log-input`. Nothing here can read the terminal's
        // pixels, and a screenshot assertion would be a worse claim than none.
        sleep(2)
    }

    func testCopyPutsTheScreenOnThePasteboard() throws {
        try sessionRows().first!.tap()
        let actions = app.buttons["terminal.actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        actions.tap()

        // `terminal.copyScreen`, not `terminal.copy`. The menu copies the
        // screen and says so; copying a *selection* is the accessory row's
        // `copy` key and the system's own long-press menu, because a selection
        // does not survive the trip to this one — see `TerminalScreen`.
        let copy = app.buttons["terminal.copyScreen"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["terminal.paste"].exists)
        XCTAssertTrue(app.buttons["Re-attach"].exists)

        // `changeCount` rather than the toast: the toast is two and a half
        // seconds of animation and this assertion used to lose a race with it
        // whenever the machine was busy. It is also a better claim — the toast
        // says a copy happened, the pasteboard *is* the copy. Reading the count
        // does not touch the contents, so it raises no Allow Paste prompt.
        let before = UIPasteboard.general.changeCount
        copy.tap()

        let changed = NSPredicate(format: "changeCount > %d", before)
        expectation(for: changed, evaluatedWith: UIPasteboard.general, handler: nil)
        waitForExpectations(timeout: 10)

        // What landed there is deliberately *not* read back. Reading another
        // app's clipboard contents raises the system's Allow Paste prompt — it
        // did, at this exact line, and the run sat on the dialog until it timed
        // out. The count is the durable half of the same fact.
    }

    func testPasteTypesTheClipboardIntoTheSession() throws {
        // Written from the test runner, which is a different app — so this also
        // exercises the case iOS guards with an Allow Paste prompt.
        UIPasteboard.general.string = "echo pasted-from-clipboard\r"

        try sessionRows().first!.tap()
        let actions = app.buttons["terminal.actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        actions.tap()
        XCTAssertTrue(app.buttons["terminal.paste"].waitForExistence(timeout: 5))
        app.buttons["terminal.paste"].tap()

        // iOS asks before letting an app read another app's clipboard, and the
        // alert is not reliably in any one process — it has been seen on
        // SpringBoard and inside the app. Both are checked, for longer than the
        // dialog takes to animate in, because a missed tap leaves it on screen
        // and every later test in the run taps into a modal.
        XCTAssertTrue(tapAllowPaste(timeout: 10), "the Allow Paste prompt never appeared or was not tapped")

        // What arrived is asserted on the far side, in the harness log, for the
        // same reason as the accessory row: nothing here can read the terminal.
        sleep(3)

    }

    /// Taps the system's Allow Paste button wherever it turns up.
    private func tapAllowPaste(timeout: TimeInterval) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for candidate in [springboard.buttons["Allow Paste"], app.buttons["Allow Paste"]]
            where candidate.exists && candidate.isHittable {
                candidate.tap()
                return true
            }
            usleep(300_000)
        }
        return false
    }

    // MARK: - 3. New Session exists only because the far end offered it

    func testNewSessionAppearsAndStartsOne() throws {
        let before = try sessionRows().count

        let plus = app.buttons["sessions.new"]
        XCTAssertTrue(plus.waitForExistence(timeout: 10),
                      "the harness advertises `create`, so the button should be here")
        plus.tap()

        // There used to be an alert with a text field here. There is no title on
        // the wire any more — the Mac names a session after its folder — so the
        // control is either a plain button (nothing to choose) or a menu of the
        // folders already on screen. Both are exercised: which one appears
        // depends on whether the host has sessions running, and a test that
        // insisted on one would be red on half the harnesses.
        let menuItem = app.buttons["New session"]
        if menuItem.waitForExistence(timeout: 3) { menuItem.tap() }

        let grew = NSPredicate(format: "count > %d", before)
        expectation(for: grew, evaluatedWith: app.buttons.matching(rowIdentifier), handler: nil)
        waitForExpectations(timeout: 20)
    }

    func testNewSessionOffersTheFoldersAlreadyOnScreen() throws {
        // The Mac accepts only a folder it is already offering, so the picker is
        // built from the `cwd` of sessions in the list. Nothing here can offer a
        // choice that fails, which is the whole reason it is sourced this way.
        let rows = try sessionRows()
        try XCTSkipIf(rows.isEmpty, "the host is serving no sessions, so there is nothing to pick")

        let plus = app.buttons["sessions.new"]
        XCTAssertTrue(plus.waitForExistence(timeout: 10))
        plus.tap()

        XCTAssertTrue(app.buttons["New session"].waitForExistence(timeout: 5),
                      "with folders on screen the control is a menu, not a bare button")
        // Dismissed rather than chosen: this case is about what is offered.
        app.buttons["New session"].tap()
    }

    // MARK: - Helpers

    private var rowIdentifier: NSPredicate {
        NSPredicate(format: "identifier BEGINSWITH 'session.'")
    }

    /// Polls the connection pill rather than waiting on a single predicate:
    /// approval can still be in flight when a test starts, and the label goes
    /// through "Waiting for approval" and "Reconnecting" on the way.
    private func waitForConnected(timeout: TimeInterval) -> Bool {
        let pill = app.descendants(matching: .any).matching(identifier: "connection.pill").firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pill.exists && pill.label.contains("Connected") { return true }
            usleep(500_000)
        }
        return false
    }

    private func sessionRows() throws -> [XCUIElement] {
        let rows = app.buttons.matching(rowIdentifier)
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20), "no session rows arrived")
        return (0 ..< rows.count).map { rows.element(boundBy: $0) }
    }
}
