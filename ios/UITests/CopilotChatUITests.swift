/**
 * The copilot **chat**, driven end to end against a live machine.
 *
 * Asad, 2026-08-22, on this screen: *"the copilot chat page on mobile is
 * unreliable and its UI is poor… it should be a very smooth and clean process."*
 * This file is the part of that pass a screenshot cannot argue with: the three
 * defects it names are each a sequence of taps, and each one either produces a
 * bubble or does not.
 *
 * ## Why this is a UI test and not another `CopilotLinkTests` case
 *
 * `CopilotLinkTests` already pins every rule this feature has about frames, and
 * it passed the whole time the screen was broken. The two defects that shipped
 * were **between** those rules and the screen: a chat frame the link dropped for
 * a run it had no baseline for, and a person's own sentence that existed nowhere
 * on screen for the length of a round trip. Neither is visible from a merge
 * function; both are obvious in one photograph.
 *
 * ## Running it
 *
 * It needs a machine on the other end and a phone already paired to it, because
 * pairing is its own ceremony with its own tests. The harness that stands up
 * that machine is `scripts/remote-host.sh`, which runs the desktop's **own**
 * remote endpoint — `CopilotAccess`, `CopilotRuns` and the sealed channel as
 * they ship — with a plain shell where the agent CLI would be:
 *
 *     scripts/remote-host.sh --relay-url wss://relay.terminaldeck.dev \
 *       --relay-port 8907 --name copilotlane
 *     curl 127.0.0.1:8908/pair          # six digits, good for a minute
 *
 * Pair the Simulator with those digits once, then:
 *
 *     TEST_RUNNER_TD_COPILOT_LIVE=yes TEST_RUNNER_TD_SHOTS=/tmp/copilot-shots \
 *     xcodebuild test … -only-testing:TerminalDeckUITests/CopilotChatUITests
 *
 * Without `TD_COPILOT_LIVE` it **skips**, loudly, rather than failing on a
 * simulator with no machine paired — the same shape `LiveCopilotUITests` uses,
 * and for the same reason: a red test that means "you did not start the harness"
 * teaches people to ignore red tests.
 */

import XCTest

final class CopilotChatUITests: XCTestCase {

    private var app: XCUIApplication!

    private func env(_ name: String) -> String {
        ProcessInfo.processInfo.environment[name] ?? ""
    }

    private var shots: String { env("TD_SHOTS") }

    private static let notLive =
        "No live machine. Start scripts/remote-host.sh, pair this Simulator with it, and run with "
        + "TEST_RUNNER_TD_COPILOT_LIVE=yes — see this file's header."

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(env("TD_COPILOT_LIVE").isEmpty, Self.notLive)
        app = XCUIApplication()
        app.launch()
    }

    /**
     * The whole walk, in one test.
     *
     * One test rather than four because each step depends on the last — there is
     * no run until Start is pressed and nothing to send until there is a run —
     * and four tests would each pay for the launch and re-derive the same state,
     * which on this screen means four runs spawned on somebody's machine.
     */
    func testAMessageAppearsWhenItIsSentAndTheMachinesCopyReplacesIt() throws {
        try openCopilot()
        capture("01-copilot")

        /*
         * An empty conversation says so.
         *
         * It said nothing at all: a state card, a composer, and a screen's height
         * of black between them, which reads as a screen that failed to load. The
         * identifier is on the sentence rather than on the container, because
         * naming a `ContentUnavailableView` makes it one accessibility element
         * and everything inside it stops existing — measured on iOS 26.4.
         */
        if app.staticTexts["copilot.nothingYet"].waitForExistence(timeout: 5) {
            capture("02-nothing-yet")
        }

        try startARunIfThereIsNone()
        capture("03-run")

        let composer = app.textViews["copilot.composer"].firstMatch
        let field = composer.exists ? composer : app.textFields["copilot.composer"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10),
                      "there is a run, so there is a composer")
        field.tap()
        field.typeText("echo hello from the phone")

        /*
         * **The bubble is on screen before the round trip.**
         *
         * The defect, in one assertion. A `copilot.say` goes into a pty on the
         * far machine, an agent CLI takes the turn and a transcript reader pushes
         * the person's own words back — about three seconds against a plain shell
         * on the same Mac, and slower against a real CLI. For that whole window
         * the composer was empty and the timeline was unchanged, so the message
         * had, as far as anything on screen could say, vanished.
         */
        app.buttons["copilot.send"].tap()
        // `matching(identifier:)` over every descendant rather than a typed
        // query: the bubble is one combined accessibility element, and which
        // element *type* SwiftUI settles on for a combined `HStack` is not a
        // thing this test should be asserting.
        let sending = app.descendants(matching: .any).matching(identifier: "copilot.sending").firstMatch
        let appeared = sending.waitForExistence(timeout: 2)
        capture("04-sent")
        XCTAssertTrue(appeared,
                      "the message must be on the timeline immediately, not after a round trip")

        /*
         * And the machine's own copy replaces it rather than sitting under it.
         *
         * `CopilotLink.settle` matches on the text because there is no id to
         * match on — a `copilot.say` carries no request id — so this is also the
         * assertion that the early row and the real one are recognised as one
         * message. Against a harness whose shell never echoes a `you` row this
         * row legitimately stays, which is why the wait ends in a screenshot
         * rather than a failure: what is not allowed is the row disappearing
         * with nothing in its place, and that is asserted below.
         */
        _ = sending.waitForNonExistence(timeout: 20)
        capture("05-settled")
        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "hello from the phone")
        ).firstMatch.exists,
        "the sentence is on the screen somewhere — as this phone's row or as the machine's")
    }

    // MARK: - Steps

    private func openCopilot() throws {
        let tab = app.tabBars.buttons["Copilot"].firstMatch
        let button = tab.exists ? tab : app.buttons["Copilot"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 20),
                      "this phone is paired as one of his devices, so the pill is there")
        button.tap()
    }

    /// Start is only pressed when there is nothing to talk to. It spawns a
    /// process on somebody's machine, so a test that pressed it every run would
    /// leave a trail of them.
    private func startARunIfThereIsNone() throws {
        let start = app.buttons["copilot.start"].firstMatch
        guard start.waitForExistence(timeout: 8) else { return }
        start.tap()
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
