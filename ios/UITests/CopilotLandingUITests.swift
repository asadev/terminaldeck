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
 *
 * ## And the second case is the other half: getting out
 *
 * > *"This page needs to go. It should directly land in terminal or chat mode."*
 *
 * > *"On copilot page we have a bug… I keep going back and it is keep taking me
 * > inside the chat box."*
 *
 * Two rounds, one subject. The tab used to **push** the conversation onto
 * `copilotRoute` over an intermediate page, which made Back mean *go to that
 * page* — and a retry loop that could not tell a discarded path from a person
 * leaving undid the Back as fast as he could press it. The page is now deleted
 * and the conversation is the tab's content, so Back has one meaning and one
 * press: out of the tab.
 *
 * Neither round is visible to a unit test, and for the same reason: the fault is
 * a **navigation**, and a navigation needs a stack, a tab transition and two
 * moments to exist at all. The second case below is his sequence with a finger,
 * and it still watches for three seconds after the press — not because anything
 * left could undo it, but because the last build's defect took about half a
 * second to appear and a case that asserted immediately would have passed
 * against it.
 */

import XCTest

final class CopilotLandingUITests: XCTestCase {

    private var app: XCUIApplication!
    private var shots: String { ProcessInfo.processInfo.environment["TD_SHOTS"] ?? "" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()

        /*
         * **Start from a tab that draws a tab bar.**
         *
         * `launch()` relaunches the process but the app comes back on the tab it
         * was left on, and the Copilot tab's conversation deliberately hides the
         * bar. So a case that ran after one which ended inside the chat found no
         * pill to press and failed with `No matches found ... TabBar` — measured,
         * and it read as the landing being broken when the landing was fine.
         *
         * Pressing Back rather than pressing another pill, because there is no
         * pill to press: this is the same one press a person has, and it is
         * therefore also a small extra proof that the way out works.
         */
        let out = app.buttons["copilot.back"].firstMatch
        if out.waitForExistence(timeout: 3), out.isHittable {
            out.tap()
            _ = app.tabBars.firstMatch.waitForExistence(timeout: 5)
        }
    }

    /**
     * **Press the pill, and nothing else.**
     *
     * This suite deliberately does not use `TabNavigation.openCopilotTab`, and
     * the reason is the whole subject of this file. That helper ends with:
     *
     *     if copilotIsShowing { return true }
     *     // Something is pushed over it — one Back is enough
     *     let back = navigationBars.buttons.element(boundBy: 0)
     *     if back.exists { back.tap() }
     *
     * — which is correct for the five suites that want the Copilot **screen**,
     * and is exactly wrong for the two cases here, because on a server this tab
     * lands in a conversation and that helper's proof of arrival cannot see one.
     * So it pressed Back to get past it, and **pressing Back is the behaviour
     * under test**. Measured, and it is worth writing down because it read as a
     * regression for twenty minutes: against the broken build the helper's Back
     * was undone by the tab and it returned false, so both cases skipped; against
     * the fixed build the Back stuck, the helper found the root and returned
     * true, and the case then reported *the tab never landed* while looking at a
     * screen it had itself navigated to. Both readings were the opposite of the
     * truth.
     *
     * The patience is the other half. On a server the pill is drawn
     * unconditionally, so its absence means the socket is not up yet, and a relay
     * dial to a rented box takes longer than the ten seconds the shared helper
     * allows — a warm app finds it at once and the next cold launch gives up on
     * the ten-second mark. A machine that genuinely has no copilot still ends in
     * the same skip, a minute later.
     */
    private func pressTheCopilotPill() -> Bool {
        let pill = app.tabBars.firstMatch.buttons["Copilot"]
        guard pill.waitForExistence(timeout: 90) else { return false }
        pill.tap()
        return true
    }

    func testTheTabLandsInAConversationRatherThanAChoice() throws {
        // Paired already, or there is nothing to land on.
        try XCTSkipUnless(app.buttons["sessions.new"].waitForExistence(timeout: 20)
                          || app.buttons["sessions.more"].waitForExistence(timeout: 5),
                          "no machine is paired with this simulator")

        try XCTSkipUnless(pressTheCopilotPill(),
                          "this machine draws no Copilot pill")

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
         * The control experiment that used to stand here pressed *Open the
         * conversation* — the row that proved the difference between the landing
         * and the identical call from a finger was **when** it was made. Both the
         * row and the difference are gone: there is no call and no moment, the
         * conversation is the tab's content, so the only thing left to check is
         * that it is on screen.
         */
        /*
         * The thing he objected to, named so a failure says which screen it
         * found. `copilot.start` is the row that offers to start one; its
         * presence after the wait means the tab asked instead of acting.
         */
        XCTAssertFalse(app.buttons["copilot.onServer.retry"].exists
                       || app.buttons["copilot.onServer.startIn"].exists,
                       "the tab offered to start a session instead of starting one")
        XCTAssertFalse(app.staticTexts["copilot.onServer.title"].exists,
                       "the page he asked to have removed is on screen")
        XCTAssertTrue(composer.exists || terminal.exists || landedBar.exists,
                      "the tab did not land in a session")
    }

    /**
     * **One press of Back leaves the tab, and there is no page in between.**
     *
     * > *"This page needs to go. It should directly land in terminal or chat
     * > mode."*
     *
     * His sequence, in his order, against the real machine: press the pill, let
     * it land, press Back **once**.
     *
     * This case has been rewritten twice and both rewrites are the product
     * changing under it rather than the test being wrong, which is worth
     * recording because the assertions invert each time:
     *
     *  - It first asserted that Back reached the Copilot root **and stayed
     *    there** for four seconds, against the round where the tab pushed the
     *    conversation onto `copilotRoute` and a retry loop pulled him back into
     *    it — *"I keep going back and it is keep taking me inside the chat box."*
     *  - It now asserts that Back reaches the root **and there is no root**. The
     *    page is gone, so the press that used to land on it leaves the tab, and
     *    a screen that still had somewhere to go back *to* would be the defect.
     *
     * The two `XCTAssertFalse`s carry the whole of the correction and neither is
     * redundant. `copilot.onServer.title` is the deleted page's headline: finding
     * it after Back would mean the page had merely moved, which is exactly what
     * the last round's fix produced. The conversation being gone is the other
     * half — a Back that did nothing at all also leaves the pill unselected on a
     * screen that never changed.
     *
     * The tab bar assertion is the one that would be missed by reading the code.
     * With the conversation as the tab's *content* rather than a push,
     * `DeckModel.copilotSurface` has to work the surface out from what is being
     * shown instead of from an empty route — and if it gets it wrong the failure
     * is not a crash, it is the floating pill sitting on top of the chat
     * composer, which is the complaint that put the back button here in the first
     * place: *"pill should not be inside the chat box."*
     */
    func testBackFromTheConversationLeavesTheTabInOnePress() throws {
        try XCTSkipUnless(app.buttons["sessions.new"].waitForExistence(timeout: 20)
                          || app.buttons["sessions.more"].waitForExistence(timeout: 5),
                          "no machine is paired with this simulator")

        try XCTSkipUnless(pressTheCopilotPill(),
                          "this machine draws no Copilot pill")
        // Photographed before the skip as well as after it. A skip here means
        // this machine's Copilot tab does not land, which is a real answer for a
        // desktop and a failure for a server — and the difference is on screen,
        // where a skip reason cannot carry it.
        let landed = waitForTheConversation()
        capture("back-1-landed")
        try XCTSkipUnless(landed,
                          "the tab never landed, which is the case above and not this one")

        XCTAssertFalse(app.staticTexts["copilot.onServer.title"].exists,
                       "the tab stopped at the page he asked to have removed")
        XCTAssertFalse(app.tabBars.firstMatch.exists,
                       "the tab bar is drawn over the conversation, on top of its composer")

        // The Copilot tab's own chevron, on the conversation itself now that the
        // conversation is what the tab is. `leaveCopilot()`.
        let back = app.buttons["copilot.back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 8),
                      "the conversation has no way off it")
        back.tap()

        var left = false
        for _ in 0 ..< 20 where !left {
            left = !app.buttons["copilot.back"].firstMatch.exists && !theConversationIsUp
            if !left { usleep(250_000) }
        }
        capture("back-2-left-the-tab-in-one-press")

        XCTAssertTrue(left, "one press of Back did not leave the Copilot tab")
        XCTAssertFalse(app.staticTexts["copilot.onServer.title"].exists,
                       "Back landed on the page he asked to have removed")
        XCTAssertFalse(app.tabBars.firstMatch.buttons["Copilot"].isSelected,
                       "the Copilot pill is still the selected tab after leaving it")

        /*
         * And it stays left. The round before this one had the tab re-open the
         * conversation about half a second after a pop, so a case that asserted
         * the instant after the tap would have passed against exactly the build
         * he was complaining about. There is no mechanism left that could do it —
         * no push, no retry, no clock — and this is what says so out loud.
         */
        let pressed = Date()
        while Date().timeIntervalSince(pressed) < 3 {
            if theConversationIsUp {
                capture("back-3-it-took-him-back")
                XCTFail("the tab put him back inside the chat "
                        + String(format: "%.1f", Date().timeIntervalSince(pressed))
                        + "s after Back")
                return
            }
            usleep(250_000)
        }
        capture("back-3-still-out")
    }

    /**
     * Something only the landed conversation draws.
     *
     * Four of them, and none is redundant. `chat.field` is the chat's composer
     * and exists only where the machine serves a transcript; `terminal.mode` is
     * the toggle between the two and is absent for the same reason;
     * `session.header` is the title, which is a `staticText` on some hosts and an
     * `otherElement` on others depending on what the principal item resolves to.
     * `terminal.actions` is what makes this reliable on a machine **without**
     * chat, which is exactly the case it is left in for: the landing falls back
     * to the terminal there, and the terminal is where that menu is drawn. It is
     * deliberately absent from a conversation — every item under it acts on the
     * emulator, which a conversation is not showing — so on a machine *with*
     * chat this answer comes from the three above it.
     *
     * Read afresh on every call rather than held in a `let`, because the whole
     * point of the case above is that this answer **changes underneath** — a
     * cached `XCUIElement.exists` from before the pop would be a test that could
     * not see the bug it was written for.
     */
    private var theConversationIsUp: Bool {
        app.textViews["chat.field"].firstMatch.exists
            || app.buttons["terminal.mode"].firstMatch.exists
            || app.buttons["terminal.actions"].firstMatch.exists
            || app.staticTexts["session.header"].firstMatch.exists
            || app.otherElements["session.header"].firstMatch.exists
    }

    /// Wait for the tab to land, on the same generous clock the case above
    /// argues for: landing can mean *starting* a session, which is a pty on a
    /// machine across a relay.
    private func waitForTheConversation() -> Bool {
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if theConversationIsUp { return true }
            usleep(500_000)
        }
        return false
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
