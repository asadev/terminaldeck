/**
 * The copilot screens, photographed, in the states a phone can be in.
 *
 * ## What this is, and what it is not
 *
 * `LiveCopilotUITests` is the one that runs against the product's own desktop.
 * This one runs against `ios/Harness/host-standin.ts` with `--copilot`, and
 * **the distinction the stand-in's own header draws applies here in full**: the
 * frames are the product's — `send` takes `ServerMessage`, inbound verbs go
 * through the real `parseClientMessage`, and the whole thing stops compiling if
 * `protocol.ts` renames a field — while the *behaviour* behind them is a fixed
 * script, because what produces it on a real Mac is a Claude CLI and no harness
 * can stand one of those in honestly.
 *
 * Which makes these frames evidence of exactly one thing: **the client draws
 * what the desktop's own types say it will be sent, and sends what it is
 * required to send.** They are not evidence that a real copilot sends it. That
 * is `copilot-frames.test.ts` on the desktop and `LiveCopilotUITests` here, and
 * neither is replaced by a screenshot.
 *
 * It earned its keep twice. On the first run the client had been written from
 * the design document rather than from `protocol.ts` and decoded a `status`
 * field against a report whose field is `desk`, so every real state frame would
 * have been refused — which looks exactly like a copilot that has not answered
 * yet. And on this pass the stand-in itself was the problem: it served every
 * `copilot.*` verb without ever requiring a `copilot.hello`, which is precisely
 * the permissive host that lets a client ship having never sent one.
 *
 * ## The ceremony is part of the walk
 *
 * A device does not arrive connected. `COPILOT-REMOTE.md` §6: the copilot is a
 * **separate connection** with its own six-digit code, minted at the machine —
 * so the walk mints one through the control server, types it into the phone, and
 * only then expects a screen. A test that started already connected would skip
 * the half of this feature that was built last.
 *
 * ## Running it
 *
 *     ios/Harness/run.sh host --port 8787 --copilot alter --folders /tmp/tdwork &
 *     TEST_RUNNER_TD_CONTROL=127.0.0.1:8788 \
 *     TEST_RUNNER_TD_COPILOT=alter \
 *     TEST_RUNNER_TD_SHOTS=/tmp/td/copilot-shots \
 *     xcodebuild test -project ios/TerminalDeck.xcodeproj -scheme TerminalDeck \
 *       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
 *       -only-testing:TerminalDeckUITests/CopilotScreensUITests
 *
 * `TD_COPILOT` says what a connect code from that host grants, so the walk
 * asserts what it should produce rather than photographing whatever appears.
 * The values are `absent`, `none` and `alter`, and each has its own case below.
 */

import XCTest

final class CopilotScreensUITests: XCTestCase {

    private var app: XCUIApplication!

    private func env(_ name: String) -> String {
        ProcessInfo.processInfo.environment[name] ?? ""
    }

    private var control: String { env("TD_CONTROL") }
    private var grant: String { env("TD_COPILOT") }
    private var shots: String { env("TD_SHOTS") }

    private static let notRunning =
        "No stand-in. Start ios/Harness/run.sh host --copilot <absent|none|alter> and pass "
        + "TEST_RUNNER_TD_CONTROL and TEST_RUNNER_TD_COPILOT — see this file's header."

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(control.isEmpty || grant.isEmpty, Self.notRunning)
        app = XCUIApplication()
        app.launch()
        // Pairings live in the Keychain and outlive the process, so a run that
        // did not clear them would start already paired to whatever the last one
        // left behind — a different host, with a different copilot connection.
        app.forgetEveryMachine()
        try pair(try mint("/pair"))
        // **Back to the sessions before waiting, not after.** Forgetting happens
        // on the Machines screen and pairing from there leaves the phone
        // standing on it — where the connection pill is not drawn at all, so a
        // wait for it there never ends and the walk never starts.
        app.openSessionsTab()
        try waitForConnected(timeout: 60)
    }

    // MARK: - The states

    /**
     * A machine whose capability list names `copilot` and which has none.
     *
     * The stand-in always advertises the name — it sends `CAPABILITIES`
     * verbatim — so `--copilot absent` is exactly the host whose advertisement
     * is ahead of what it can serve. Nothing about a copilot may appear: not the
     * row, and above all not a Connect screen, because that build has nothing to
     * mint a code with.
     */
    func testAMachineThatOnlyAdvertisesACopilotShowsNone() throws {
        try XCTSkipUnless(grant == "absent", "this case is for --copilot absent")

        // The pill is structure and is drawn for every machine; what must be
        // absent is anything *about a copilot* behind it, and above all a
        // Connect screen, because that build has nothing to mint a code with.
        XCTAssertTrue(app.openCopilotTab())
        XCTAssertFalse(app.textFields["copilot.connect.field"].waitForExistence(timeout: 8),
                       "the capability alone must not offer a code")
        XCTAssertFalse(app.textFields["copilot.composer"].exists)
        capture("absent-01-no-copilot")
    }

    /**
     * **What a device with no copilot connection sees.**
     *
     * The state every paired device starts in, and the headline of the whole
     * revision: pairing a phone for terminals grants it no copilot reach at all.
     * The row is drawn — this is a state a person can fix in thirty seconds —
     * and behind it is a six-digit field and a sentence naming where the code
     * comes from. Nothing that would be refused is drawn beside it.
     */
    func testADeviceWithNoConnectionIsOfferedACode() throws {
        try XCTSkipUnless(grant == "alter" || grant == "none",
                          "this case needs a host that has a copilot")

        XCTAssertTrue(app.openCopilotTab(), "the copilot has a pill of its own")
        capture("connect-01-tab-not-connected")

        XCTAssertTrue(app.textFields["copilot.connect.field"].waitForExistence(timeout: 10),
                      "an unconnected device is offered a code, not an empty conversation")
        capture("connect-02-connect-screen")

        // Nothing that would be refused. All of them absent rather than
        // disabled: a control drawn for something the far end will never allow
        // is a smaller lie, not a smaller feature.
        XCTAssertFalse(app.textFields["copilot.composer"].exists, "no composer")
        XCTAssertFalse(app.buttons["copilot.start"].exists, "no Start")
        XCTAssertFalse(app.buttons["copilot.more"].exists,
                       "every item behind it needs `read`, which needs a connection")
        // And the pill is **there**, which is the opposite of what this line
        // asserted while the copilot was a pushed screen. It is a tab now, and a
        // tab that hid its own bar would be a screen with no way out — see
        // `DeckChrome`.
        XCTAssertTrue(app.tabBars.firstMatch.exists, "a tab keeps the bar it is a tab of")
    }

    /**
     * A device connected with every box unticked.
     *
     * A real state — unticking them all leaves a working credential behind — and
     * its remedy is three checkboxes rather than a code, so it must not say the
     * same thing as the screen above. A phone that offered a code field here
     * would be sending somebody to mint one they do not need.
     */
    func testAConnectedDeviceWithNoTiersIsToldWhichBoxToTick() throws {
        try XCTSkipUnless(grant == "none", "this case is for --copilot none")

        XCTAssertTrue(app.openCopilotTab())
        try connectTheCopilot()

        XCTAssertTrue(app.otherElements["copilot.notGranted"].waitForExistence(timeout: 15)
                      || app.staticTexts["Connected, and given nothing"].waitForExistence(timeout: 5),
                      "it should say so rather than draw an empty conversation")
        capture("none-01-connected-and-given-nothing")
        XCTAssertFalse(app.textFields["copilot.connect.field"].exists,
                       "this device *is* connected — a code field here sends somebody to mint one "
                       + "they do not need")
        XCTAssertFalse(app.textFields["copilot.composer"].exists)
    }

    /**
     * A phone connected with all three tiers: the whole walk.
     *
     * Connect with a code, watch, start a run, ask it something, read the answer
     * and the tool row it caused, answer the confirmation it raises — with every
     * argument in front of you — and see where the answer landed. Then the other
     * kind of question: one raised at the desk, which this phone may watch and
     * must not be able to answer.
     */
    func testTheWholeCopilotWalk() throws {
        try XCTSkipUnless(grant == "alter", "this case is for --copilot alter")

        XCTAssertTrue(app.openCopilotTab(), "the copilot is the leftmost pill")
        try connectTheCopilot()

        // The state card, from the desktop's own report. The assertion is on the
        // *desk* line: it is the field the client used to decode under the wrong
        // name, and a screen with no state card looks identical to a copilot
        // that simply has not answered.
        let status = app.staticTexts["copilot.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 20),
                      "the state card should draw — if this fails, the state frame was refused")
        XCTAssertTrue(status.label.contains("Running"), "the stand-in reports a running desk")
        capture("alter-02-connected")

        // Starting is a button and says what it costs, because the tap is the
        // consent and the consent is about money.
        let start = app.buttons["copilot.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10),
                      "a connected phone with act and no run should be offered one")
        start.tap()

        let composer = app.textFields["copilot.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20),
                      "starting a run should replace the offer with a composer")
        capture("alter-03-run-started")

        composer.tap()
        composer.typeText("what happened overnight")
        app.buttons["copilot.send"].tap()

        XCTAssertTrue(app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS 'Two sessions ran overnight'"))
            .firstMatch.waitForExistence(timeout: 20),
                      "the answer should arrive as a bubble")
        capture("alter-04-answer-and-tool-rows")

        try theConsentSheetIsAnsweredHere()
        // The conversation underneath, once the sheet is out of the way. This is
        // the screen the feature is *for* — what it said and what it did, in one
        // list — and the consent sheet raises itself over it within a second of
        // the answer arriving, so it is only photographable afterwards.
        capture("alter-06b-timeline")
        try theDeskQuestionHasNoAnswerOnIt()

        // What it started.
        app.buttons["copilot.more"].tap()
        app.buttons["copilot.sessions"].tap()
        XCTAssertTrue(app.navigationBars["Sessions it started"].waitForExistence(timeout: 10))
        capture("alter-09-sessions-it-started")
        app.buttons["Done"].tap()

        // Everything it did, including the refusal.
        app.buttons["copilot.more"].tap()
        app.buttons["copilot.activity"].tap()
        XCTAssertTrue(app.navigationBars["Everything it did"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS 'not-granted'"))
            .firstMatch.waitForExistence(timeout: 10),
                      "a refused call is the row this screen exists for")
        capture("alter-10-everything-it-did")
        app.buttons["Done"].tap()
    }

    /**
     * **The consent sheet, and the two properties it lives or dies by.**
     *
     * *Everything needed to judge it* — the summary, the tool, the tier, who
     * asked, and every argument verbatim. A prompt without those is a reflex
     * Yes, and a gate that is always answered yes is worse than no gate because
     * it looks like protection.
     *
     * *Refusing is at least as easy as accepting* — asserted with geometry
     * rather than with a comment, because this is exactly the property a tidy
     * layout quietly takes away. The two buttons have to be the same size, at
     * the same height, both on screen, neither behind a confirmation.
     */
    private func theConsentSheetIsAnsweredHere() throws {
        let allow = app.buttons["copilot.consent.allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 25),
                      "the run's own alter call should raise a confirmation on this phone")
        let refuse = app.buttons["copilot.consent.refuse"]
        XCTAssertTrue(refuse.exists, "and it must offer both answers")

        XCTAssertTrue(app.staticTexts["copilot.consent.summary"].exists,
                      "the desktop's own sentence, never re-worded here")
        XCTAssertTrue(app.staticTexts["copilot.consent.countdown"].exists,
                      "and what happens if nobody answers")
        XCTAssertTrue(app.staticTexts["copilot.consent.countdown"].label.contains("refused"),
                      "the countdown has to say silence is a refusal, not a deferral")
        /*
         * Every argument the stand-in sent, **by its value**.
         *
         * Matched on the rendered text rather than on the accessibility
         * identifier, and the difference is not pedantry: an identifier proves a
         * row exists, and this has to prove the *value* reached the screen. A
         * client that drew the names with empty values, or that rendered a JSON
         * `true` as `1`, would pass an identifier check and would be misquoting
         * the request somebody is about to approve.
         *
         * `previous` and `claude` are the pair that matters most: a sheet that
         * showed only the new value would be asking somebody to approve half a
         * change.
         */
        for value in ["defaultProvider", "codex", "claude", "including yours"] {
            let shown = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
            XCTAssertTrue(shown.exists, "the sheet must show “\(value)” verbatim")
        }
        capture("alter-05-consent-sheet")

        // Geometry, not good intentions. `COPILOT-REMOTE.md` §4.3: not Allow
        // under the thumb and Refuse in a corner.
        XCTAssertEqual(refuse.frame.width, allow.frame.width, accuracy: 1,
                       "refusing must not be a smaller target than allowing")
        XCTAssertEqual(refuse.frame.height, allow.frame.height, accuracy: 1)
        XCTAssertEqual(refuse.frame.minY, allow.frame.minY, accuracy: 1,
                       "and not further from the thumb")
        XCTAssertTrue(refuse.isHittable && allow.isHittable, "both are one tap")

        refuse.tap()

        let settled = app.otherElements["copilot.consent.settled"]
        XCTAssertTrue(settled.waitForExistence(timeout: 15)
                      || app.staticTexts["Refused"].waitForExistence(timeout: 5),
                      "the sheet says where the answer landed rather than vanishing")
        capture("alter-06-consent-answered")
        app.buttons["copilot.consent.close"].tap()
    }

    /**
     * A confirmation raised **at the desk**, which this phone may watch and must
     * not be able to answer.
     *
     * `mine: false`, so the desktop sends no arguments with it and this client
     * draws no Allow. A button there would be a control whose only possible
     * outcome is a refusal — the defect this repository has paid for twice — and
     * the enumeration below is deliberately over *every* button on the sheet,
     * because the failure to guard against is somebody adding one under another
     * name.
     */
    private func theDeskQuestionHasNoAnswerOnIt() throws {
        let card = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'copilot.question.q-desk'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20),
                      "the stand-in has one confirmation waiting at the desk")
        capture("alter-07-desk-question-card")
        card.tap()

        XCTAssertTrue(app.navigationBars["Needs you"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["copilot.question.countdown"].exists,
                      "go and look is worthless without how long have I got")
        // Matched on the sentence rather than on a container's identifier: what
        // has to be true is that the screen *says* where this is answered, and a
        // container that exists while saying nothing would pass an identifier
        // check.
        XCTAssertTrue(app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS 'answered at'")).firstMatch.exists,
                      "it has to say where it is answered")
        capture("alter-08-desk-question-sheet")

        let buttons = (0 ..< app.buttons.count).map { app.buttons.element(boundBy: $0).label }
        for word in ["Allow", "Approve", "Refuse", "Deny", "Snooze", "Remind", "Nudge"] {
            XCTAssertFalse(buttons.contains { $0.localizedCaseInsensitiveContains(word) },
                           "found a “\(word)” control on somebody else's question — it would be "
                           + "refused every time, and COPILOT-REMOTE.md §4.2 is why")
        }
        XCTAssertTrue(buttons.contains("Done"), "the only control is the one that closes it")
        app.buttons["copilot.question.done"].tap()
    }

    // MARK: - Getting there

    /// Mint a code at the "machine" and type it into the phone, which is the
    /// whole ceremony. A person does this by pressing a button in Settings →
    /// Remote; a script cannot press it, which is what the control server is for.
    private func connectTheCopilot() throws {
        let field = app.textFields["copilot.connect.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), "the Connect screen should be up")
        let code = try mint("/copilot-code")
        field.tap()
        field.typeText(code)
        if app.buttons["copilot.connect.submit"].exists && app.buttons["copilot.connect.submit"].isHittable {
            app.buttons["copilot.connect.submit"].tap()
        }
    }

    private func pair(_ code: String) throws {
        let field = app.textFields["pairing.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the pairing screen should be up")
        field.tap()
        field.typeText(code)
        if app.buttons["pairing.submit"].exists { app.buttons["pairing.submit"].tap() }
    }

    /**
     * Wait for the pill to say Connected, **and keep asking to be on the screen
     * that has one.**
     *
     * The approval is not instant — the stand-in approves after eight seconds,
     * the way a person would after a few — so the phone spends the first
     * attempts being refused, and where it lands afterwards is not always the
     * session list. The pill is not drawn on the Machines screen at all, so a
     * wait that only looked for it there would never end, and the failure it
     * reported would be "never connected" about a phone that had connected
     * perfectly. Re-tapping the tab costs nothing and removes the whole class.
     */
    private func waitForConnected(timeout: TimeInterval) throws {
        let pill = app.descendants(matching: .any).matching(identifier: "connection.pill").firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        var lastNudge = Date.distantPast
        while Date() < deadline {
            if pill.exists && pill.label.contains("Connected") { return }
            // The tab bar's own button, not `openSessionsTab()`: that helper
            // falls back to `buttons["Sessions"]` anywhere on screen, and
            // "Sessions" is a word this app uses in more than one place — the
            // query then throws *Multiple matching elements found* and fails the
            // run at the nudge rather than at anything being wrong.
            if Date().timeIntervalSince(lastNudge) > 8 {
                lastNudge = Date()
                let tab = app.tabBars.firstMatch.buttons["Sessions"]
                if tab.exists { tab.tap() }
            }
            usleep(500_000)
        }
        capture("zz-never-connected")
        XCTFail("never reached Connected; the pill said \(pill.exists ? pill.label : "nothing")")
    }

    /// A six-digit code from the harness's control server, minted **now**,
    /// because both kinds are good for sixty seconds and a Simulator takes
    /// longer than that to arrive.
    private func mint(_ path: String) throws -> String {
        guard let url = URL(string: "http://\(control)\(path)") else {
            throw XCTSkip("\(control) is not an address")
        }
        var answer: String?
        let done = expectation(description: "minted")
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                answer = json["code"] as? String
            }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 20)
        guard let answer, !answer.isEmpty else {
            throw XCTSkip("\(Self.notRunning) (\(control) did not answer \(path))")
        }
        return answer
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard !shots.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: "\(shots)/\(name).png"))
    }
}
