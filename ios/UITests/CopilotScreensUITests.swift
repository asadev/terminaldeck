/**
 * The copilot screens, photographed, in the three states a phone can be in.
 *
 * ## What this is, and what it is not
 *
 * `LiveCopilotUITests` is the one that runs against the product's own desktop,
 * and against a real desktop today the honest answer is *there is no copilot
 * layer wired in yet*, so it can only prove the absence. That is the important
 * assertion and it is not enough to look at: nobody can decide whether a screen
 * reads well from a photograph of the screen not being there.
 *
 * So this one runs against `ios/Harness/host-standin.ts` with `--copilot`, and
 * **the distinction the stand-in's own header draws applies here in full**: the
 * frames are the product's — `send` takes `ServerMessage`, inbound verbs go
 * through the real `parseClientMessage`, and the whole thing stops compiling if
 * `protocol.ts` renames a field — while the *behaviour* behind them is a fixed
 * script, because what produces it on a real Mac is a Claude CLI and no harness
 * can stand one of those in honestly.
 *
 * Which makes these frames evidence of exactly one thing: **the client draws
 * what the desktop's own types say it will be sent.** They are not evidence that
 * a real copilot sends it. That is `copilot-frames.test.ts` on the desktop and
 * `LiveCopilotUITests` here, and neither is replaced by a screenshot.
 *
 * It earned its keep on the first run: the client had been written from the
 * design document rather than from `protocol.ts` and decoded a `status` field
 * against a report whose field is `desk`, so every real state frame would have
 * been refused and the screen would have drawn with no state card, no run line
 * and no Start button — which looks exactly like a copilot that has not answered
 * yet.
 *
 * ## Running it
 *
 *     ios/Harness/run.sh host --port 8787 --copilot act --folders /tmp &
 *     TEST_RUNNER_TD_CONTROL=127.0.0.1:8788 \
 *     TEST_RUNNER_TD_COPILOT=act \
 *     TEST_RUNNER_TD_SHOTS=/tmp/td/copilot-shots \
 *     xcodebuild test -project ios/TerminalDeck.xcodeproj -scheme TerminalDeck \
 *       -destination 'platform=iOS Simulator,name=iPhone 17' \
 *       -only-testing:TerminalDeckUITests/CopilotScreensUITests
 *
 * `TD_COPILOT` says which grant the host was started with, so the walk asserts
 * what that grant should produce rather than photographing whatever appears.
 * The three values are `absent`, `none` and `act`, and each one has its own
 * case below.
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
        "No stand-in. Start ios/Harness/run.sh host --copilot <absent|none|act> and pass "
        + "TEST_RUNNER_TD_CONTROL and TEST_RUNNER_TD_COPILOT — see this file's header."

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(control.isEmpty || grant.isEmpty, Self.notRunning)
        app = XCUIApplication()
        app.launch()
        // Pairings live in the Keychain and outlive the process, so a run that
        // did not clear them would start already paired to whatever the last one
        // left behind — a different host, with a different copilot grant.
        app.forgetEveryMachine()
        try pair(freshCode())
        // **Back to the sessions before waiting, not after.** Forgetting happens
        // on the Machines screen and pairing from there leaves the phone
        // standing on it — where the connection pill is not drawn at all, so a
        // wait for it there never ends and the walk never starts. It cost two
        // runs: the first looked for the copilot row on a screen it is not on,
        // and the second sat waiting for a pill on a screen that has none.
        app.openSessionsTab()
        try waitForConnected(timeout: 60)
    }

    // MARK: - The three states

    /**
     * A machine whose capability list names `copilot` and which has none.
     *
     * The stand-in always advertises the name — it sends `CAPABILITIES`
     * verbatim — so `--copilot absent` is exactly the host whose advertisement
     * is ahead of what it can serve. Nothing about a copilot may appear: not the
     * row, and above all not the row that names a switch in that machine's
     * Settings, because that build has no such switch.
     */
    func testAMachineThatOnlyAdvertisesACopilotShowsNone() throws {
        try XCTSkipUnless(grant == "absent", "this case is for --copilot absent")

        XCTAssertFalse(app.buttons["copilot.row"].waitForExistence(timeout: 8),
                       "the capability alone must not draw a copilot")
        capture("absent-01-no-row")
    }

    /**
     * A machine that **has** a copilot and has given this phone none of it.
     *
     * The ordinary case, because copilot access is off for every device until
     * somebody turns it on. The row is drawn — this is the one state a person
     * can fix — and the screen behind it says where, and offers nothing else.
     */
    func testAPhoneWithNoGrantIsToldWhereTheSwitchIs() throws {
        try XCTSkipUnless(grant == "none", "this case is for --copilot none")

        let row = app.buttons["copilot.row"]
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "a machine with a copilot draws the row even for a phone with no grant")
        capture("none-01-row-on-the-session-list")

        row.tap()
        XCTAssertTrue(app.otherElements["copilot.notGranted"].waitForExistence(timeout: 10)
                      || app.staticTexts["Not shared with this phone"].waitForExistence(timeout: 5),
                      "it should say so rather than draw an empty conversation")
        capture("none-02-not-shared")

        // Nothing that would be refused. All of them absent rather than
        // disabled: a control drawn for something the far end will never allow
        // is a smaller lie, not a smaller feature.
        XCTAssertFalse(app.textFields["copilot.composer"].exists, "no composer")
        XCTAssertFalse(app.buttons["copilot.start"].exists, "no Start")
        // The overflow too, and this one is here because it shipped in the
        // screenshot: "Everything it did" and "Sessions it started" are both
        // read-tier, so on this screen they were two taps that could only open
        // an empty sheet, beside a sentence saying this phone has been given
        // nothing.
        XCTAssertFalse(app.buttons["copilot.more"].exists,
                       "both overflow items need `read`, which this phone does not have")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "and the pill is gone, like a terminal")
    }

    /**
     * A phone that may watch and direct: the whole walk.
     *
     * Start, ask, read the answer and the tool row it caused, look at what it
     * started, look at everything it has ever done, and read the confirmation
     * waiting at the desk — which has no Allow on it and must not grow one.
     */
    func testTheWholeCopilotWalk() throws {
        try XCTSkipUnless(grant == "act", "this case is for --copilot act")

        let row = app.buttons["copilot.row"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the row should be above the sessions")
        capture("act-01-row-with-badge")
        row.tap()

        // The state card, from the desktop's own report. The assertion is on the
        // *desk* line: it is the field the client used to decode under the wrong
        // name, and a screen with no state card looks identical to a copilot
        // that simply has not answered.
        let status = app.staticTexts["copilot.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 20),
                      "the state card should draw — if this fails, the state frame was refused")
        XCTAssertTrue(status.label.contains("Running"), "the stand-in reports a running desk")
        capture("act-02-before-a-run")

        // Starting is a button and says what it costs, because the tap is the
        // consent and the consent is about money.
        let start = app.buttons["copilot.start"]
        XCTAssertTrue(start.exists, "a phone with act and no run should be offered one")
        start.tap()

        let composer = app.textFields["copilot.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20),
                      "starting a run should replace the offer with a composer")
        capture("act-03-run-started")

        composer.tap()
        composer.typeText("what happened overnight")
        app.buttons["copilot.send"].tap()

        XCTAssertTrue(app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS 'Two sessions ran overnight'"))
            .firstMatch.waitForExistence(timeout: 20),
                      "the answer should arrive as a bubble")
        capture("act-04-answer-and-tool-rows")

        // What it started.
        app.buttons["copilot.more"].tap()
        app.buttons["copilot.sessions"].tap()
        XCTAssertTrue(app.navigationBars["Sessions it started"].waitForExistence(timeout: 10))
        capture("act-05-sessions-it-started")
        app.buttons["Done"].tap()

        // Everything it did, including the refusal.
        app.buttons["copilot.more"].tap()
        app.buttons["copilot.activity"].tap()
        XCTAssertTrue(app.navigationBars["Everything it did"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS 'not-granted'"))
            .firstMatch.waitForExistence(timeout: 10),
                      "a refused call is the row this screen exists for")
        capture("act-06-everything-it-did")
        app.buttons["Done"].tap()

        try theWaitingQuestionHasNoAnswerOnIt()
    }

    /**
     * **The consent card, and the assertion that it is not a control.**
     *
     * Per §4.2 the phone may see a question waiting at the desk, with the
     * summary and the countdown, and must offer no Allow, no Refuse, no nudge
     * and no snooze. This is where that is checked with a thumb rather than in a
     * type: the sheet is opened and every button on it is enumerated, because
     * the failure to guard against is somebody adding one — a notification
     * action, a "remind me" — and a test that only looked for a button called
     * "Allow" would miss it under any other name.
     */
    private func theWaitingQuestionHasNoAnswerOnIt() throws {
        let card = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'copilot.question.'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20),
                      "the stand-in has one confirmation waiting at the desk")
        capture("act-07-question-card")
        card.tap()

        XCTAssertTrue(app.navigationBars["Needs you"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["copilot.question.countdown"].exists,
                      "go and look is worthless without how long have I got")
        XCTAssertTrue(app.otherElements["copilot.question.where"].exists
                      || app.staticTexts.containing(
                          NSPredicate(format: "label CONTAINS 'answered at'")).firstMatch.exists,
                      "it has to say where it is answered")
        capture("act-08-question-sheet")

        let buttons = (0 ..< app.buttons.count).map { app.buttons.element(boundBy: $0).label }
        for word in ["Allow", "Approve", "Refuse", "Deny", "Snooze", "Remind", "Nudge", "Yes", "No"] {
            XCTAssertFalse(buttons.contains { $0.localizedCaseInsensitiveContains(word) },
                           "found a “\(word)” control on the consent sheet — COPILOT-REMOTE.md §4 "
                           + "forbids every one of these, and §4.6 is what to read before adding one")
        }
        XCTAssertTrue(buttons.contains("Done"), "the only control is the one that closes it")
    }

    // MARK: - Getting there

    private func pair(_ code: String) throws {
        let field = app.textFields["pairing.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the pairing screen should be up")
        field.tap()
        field.typeText(code)
        if app.buttons["pairing.submit"].exists { app.buttons["pairing.submit"].tap() }
    }

    private func waitForConnected(timeout: TimeInterval) throws {
        let pill = app.descendants(matching: .any).matching(identifier: "connection.pill").firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pill.exists && pill.label.contains("Connected") { return }
            usleep(500_000)
        }
        capture("zz-never-connected")
        XCTFail("never reached Connected; the pill said \(pill.exists ? pill.label : "nothing")")
    }

    /// Minted now, through the harness's own control server, because a code is
    /// good for sixty seconds and a Simulator takes longer than that to arrive.
    private func freshCode() throws -> String {
        guard let url = URL(string: "http://\(control)/pair") else {
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
            throw XCTSkip("\(Self.notRunning) (\(control) did not answer /pair)")
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
