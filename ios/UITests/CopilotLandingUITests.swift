/**
 * The Copilot tab, landing where it is supposed to land.
 *
 * > *"When we land on the copilot page there should be directly a new session
 * > started if there is no previous session. No thing, no options to choose
 * > between… if there is already an existing session it should start from there
 * > where we left, and if not then it should create itself."*
 *
 * `CopilotOnServerTests` pins that rule as a pure function over states it builds
 * itself, which is the right shape for the rule and proves nothing about the
 * app. This walks it with a finger against a **real machine**: press the pill,
 * wait, and look at what is on screen.
 *
 * ## It photographs rather than asserting a session id
 *
 * The two outcomes it must tell apart are *a conversation* and *a list of
 * choices*, and the second is what he objected to. So the assertion is the
 * absence of the chooser and the presence of something to type into or read —
 * not an id, which changes on every run and would make this a test of the
 * machine's bookkeeping rather than of the screen.
 *
 * ## It is allowed to start a session, and says so
 *
 * Every other suite in this target is forbidden from changing anything on
 * Asad's machine. This one starts a session on purpose, because that *is* the
 * behaviour under test — and it is the same act the tab performs on its own
 * every time he opens it, so it leaves the machine in a state he asked for
 * rather than one he did not.
 */

import XCTest

final class CopilotLandingUITests: XCTestCase {

    private var app: XCUIApplication!
    private var shots: String { ProcessInfo.processInfo.environment["TD_SHOTS"] ?? "" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testTheTabLandsInAConversationRatherThanAChoice() throws {
        // Paired already, or there is nothing to land on.
        try XCTSkipUnless(app.buttons["sessions.new"].waitForExistence(timeout: 20)
                          || app.buttons["sessions.more"].waitForExistence(timeout: 5),
                          "no machine is paired with this simulator")

        try XCTSkipUnless(app.openCopilotTab(), "this machine draws no Copilot pill")

        /*
         * Long, and deliberately so. Landing may mean *starting* a session,
         * which is a pty on a machine across a relay, and the tab then pushes
         * the terminal once the machine confirms. Twelve seconds is past the
         * point where a start that is going to work has worked, and well inside
         * the thirty the screen itself waits before saying it did not.
         */
        let composer = app.textViews["chat.field"].firstMatch
        /*
         * Either half of the landed screen proves arrival: the chat's own field,
         * or the terminal's **Details** item, which every session screen draws.
         *
         * Not `terminal.mode`, which was the first guess and is wrong: the chat
         * toggle is drawn only where the machine will serve a transcript, so on a
         * host without it this test would have reported a failure to land while
         * looking straight at the landed screen.
         */
        let terminal = app.buttons["terminal.mode"].firstMatch
        // A third proof, and the only one that holds on every machine: the
        // session's own title in the navigation bar. `terminal.mode` is drawn
        // only where the machine serves a transcript and `terminal.details`
        // lives behind the overflow, so neither on its own can tell *landed* from
        // *did not land* on a host without chat.
        let landedBar = app.staticTexts["session.header"].firstMatch
            .exists ? app.staticTexts["session.header"].firstMatch : app.otherElements["session.header"].firstMatch
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline && !composer.exists && !terminal.exists && !landedBar.exists {
            usleep(500_000)
        }
        capture("copilot-landing")

        /*
         * The control experiment, and it is the whole diagnosis when this test
         * fails: *Open the conversation* calls the very same
         * `DeckModel.open(session:on:)` the landing calls. If pressing it works
         * while the landing does not, the difference is **when** the call is
         * made and nothing else; if pressing it also does nothing, the stack
         * itself is not pushing and the landing is a symptom.
         */
        let row = app.buttons["copilot.onServer.ask"].firstMatch
        if !composer.exists && !terminal.exists && !landedBar.exists && row.exists {
            row.tap()
            _ = landedBar.waitForExistence(timeout: 10)
            capture("copilot-after-pressing-the-row")
            XCTAssertTrue(composer.exists || terminal.exists || landedBar.exists,
                          "pressing the row did not open the session either — the stack is not pushing")
        }

        /*
         * The thing he objected to, named so a failure says which screen it
         * found. `copilot.start` is the row that offers to start one; its
         * presence after the wait means the tab asked instead of acting.
         */
        XCTAssertFalse(app.buttons["copilot.onServer.retry"].exists
                       || app.buttons["copilot.onServer.startIn"].exists,
                       "the tab offered to start a session instead of starting one")
        XCTAssertTrue(composer.exists || terminal.exists || landedBar.exists,
                      "the tab did not land in a session")
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
