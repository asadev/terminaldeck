/**
 * Chat mode surviving the thing that broke it: leaving the screen and coming
 * back.
 *
 * > *"Make sure chat mode is properly working. Most of the time when we switch
 * > between chat mode and terminal — when we switch in terminal we can see the
 * > whole chat; when we switch on chat mode we don't see the chat. So this
 * > happens a lot, on all the versions."*
 *
 * `SessionChatTests` pins the model and it would have passed the whole time this
 * was broken, because the defect is not in the model — it is in *which screen
 * the model is pointed at*, and that is decided by SwiftUI's lifecycle across a
 * `TabView` of two `NavigationStack`s. The order was measured on a Simulator and
 * is written down in `SessionBarLink.release`; this file is the same sequence
 * driven through the app's own controls, where the only thing being asserted is
 * what a person would see.
 *
 * ## It never sends anything
 *
 * Read-only, and deliberately: the sessions on a real desktop belong to somebody
 * and a test that typed into one would be typing at a live agent. Every step
 * here is a tab, a row or the mode toggle. The composer is looked at and never
 * touched.
 *
 * ## Running it
 *
 * It needs a machine on the other end and a phone already paired to it — the
 * same harness `LiveSessionUITests` documents, and the same reason pairing
 * happens outside the test:
 *
 *     ios/Harness/run.sh host --approve-after 6000 &
 *     # type the six digits in ios/Harness/.build/pairing.txt into the field
 *     xcodebuild test … -only-testing:TerminalDeckUITests/ChatModeUITests
 *
 * Without a connected machine it **skips**, loudly. A red test that means "you
 * did not start the harness" is a red test people learn to ignore.
 *
 * ## Why the assertions are conditional on the toggle being there
 *
 * The toggle is absent when the machine cannot serve a transcript and absent
 * again when it has looked and found none — both real states, and both what a
 * harness running a plain shell produces. So the shape is: *if the conversation
 * was reachable before the round trip, it is reachable after, with at least what
 * it had.* That is exactly the claim the defect broke, and it degrades to a
 * skip rather than to a false pass.
 */

import XCTest

final class ChatModeUITests: XCTestCase {

    private var app: XCUIApplication!

    /// Answered once per run, for the reason `LiveSessionUITests` gives: a
    /// machine with no harness must not pay the long wait once per case.
    private static var reachable: Bool?

    private static let notRunning =
        "This phone is not connected to a running machine. Start ios/Harness/run.sh host, "
        + "pair this Simulator with it, and run again — see this file's header."

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(Self.reachable == false, Self.notRunning)
        app = XCUIApplication()
        app.launch()
        let connected = waitForConnected(timeout: Self.reachable == nil ? 45 : 10)
        Self.reachable = connected
        try XCTSkipUnless(connected, Self.notRunning)
    }

    /**
     * The whole sequence, in one case.
     *
     * One case rather than three because every step depends on the last — there
     * is no conversation until a session is open and nothing to come back to
     * until the conversation has been read once — and three cases would each pay
     * for the launch and re-derive the same state against somebody's real
     * desktop.
     */
    func testTheConversationIsStillThereAfterLeavingTheScreenAndComingBack() throws {
        try openTheFirstSession()

        let toggle = app.buttons["terminal.mode"]
        try XCTSkipUnless(toggle.waitForExistence(timeout: 15),
                          "this session has no transcript, so there is no conversation to lose")

        toggle.tap()
        let conversation = app.descendants(matching: .any).matching(identifier: "session.chat").firstMatch
        XCTAssertTrue(conversation.waitForExistence(timeout: 10), "the toggle opens the conversation")
        // Give the read a moment to land before counting, so the "before" figure
        // is the conversation rather than the frame before it arrived.
        _ = app.buttons["chat.copy"].firstMatch.waitForExistence(timeout: 10)
        let before = app.buttons.matching(identifier: "chat.copy").count

        /*
         * Away and back, which is the whole of the defect.
         *
         * The Copilot tab when there is one, because that is the arrangement
         * that produced it: the copilot's own terminal claims the machine's one
         * bar on its `onAppear`, and coming back here fires no callback at all in
         * which this screen could claim it back. Any other tab is a weaker
         * version of the same round trip and is still worth making when the
         * copilot is not on this machine.
         */
        let copilot = app.tabBars.buttons["Copilot"]
        if copilot.exists {
            copilot.tap()
        } else {
            app.openTab("Localhost")
        }
        // Long enough for the other tab's screen to appear and ask its own
        // questions; the defect is a race and hurrying past it hides it.
        _ = app.buttons["terminal.mode"].waitForExistence(timeout: 5)
        app.openSessionsTab()

        XCTAssertTrue(toggle.waitForExistence(timeout: 15),
                      "the session is still open and the toggle is still offered")

        /*
         * The press he was making when the screen came up empty.
         *
         * The screen may still be in chat mode — nothing resets it on a tab
         * round trip, which is deliberate — so the toggle is only pressed when
         * the conversation is not already on screen. Pressing it regardless
         * would leave the terminal showing and assert nothing.
         */
        if !conversation.exists { toggle.tap() }
        XCTAssertTrue(conversation.waitForExistence(timeout: 10),
                      "the conversation must be on screen, not an empty view")

        let after = app.buttons.matching(identifier: "chat.copy").count
        XCTAssertGreaterThanOrEqual(after, before,
                                    "coming back must not lose turns that were already read")
    }

    /**
     * The `i`, and what is behind it.
     *
     * Not decoration: a transcript view that shows an agent's prose and none of
     * its tool calls looks like one that has lost half the conversation, and the
     * reason — the desktop's parser removes them before the frame is built —
     * exists nowhere else on screen. This asserts it is reachable and that it
     * says something, which is the whole of what a test can claim about a
     * sentence.
     */
    func testTheNoteAboutWhatThisViewShowsIsReachable() throws {
        try openTheFirstSession()
        let toggle = app.buttons["terminal.mode"]
        try XCTSkipUnless(toggle.waitForExistence(timeout: 15),
                          "no transcript on this session, so no chat mode to explain")
        toggle.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "session.chat")
            .firstMatch.waitForExistence(timeout: 10))

        let note = app.buttons["chat.note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5), "the i is next to the mode toggle")
        note.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "chat.note.body")
            .firstMatch.waitForExistence(timeout: 5))
    }

    // MARK: - Steps

    private func openTheFirstSession() throws {
        app.openSessionsTab()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session.'"))
        try XCTSkipUnless(rows.firstMatch.waitForExistence(timeout: 20),
                          "this machine has no sessions to read")
        rows.firstMatch.tap()
    }

    /// Polls rather than waiting on one predicate: approval can still be in
    /// flight when a run starts, and the label passes through "Waiting for
    /// approval" and "Reconnecting" on the way. The same walk
    /// `LiveSessionUITests` makes, for the same reason.
    private func waitForConnected(timeout: TimeInterval) -> Bool {
        let pill = app.descendants(matching: .any).matching(identifier: "connection.pill").firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pill.exists && pill.label.contains("Connected") { return true }
            usleep(500_000)
        }
        return false
    }
}
